#!/usr/bin/env python3
"""Join independently computed single-range plans into shared story vectors."""
import json
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
SHARED = ROOT / 'shared/fixtures'


def vector(identity, project_path, ranges, cuts, edges=False, reject=False, voice=False):
    project = json.loads((SHARED / project_path).read_text())
    words = project['transcript']['words']
    ids = [word['id'] for word in words]
    if edges:
        words[0]['start'] = 0
        words[-1]['end'] = project['media']['source']['durationSeconds']
    parts = [dict(id=f'part-{index}', startWordId=start, endWordId=end) for index, (start, end) in enumerate(ranges, 1)]
    clip = {**project['edits']['clips'][0], 'startWordId': min((start for start, end in ranges), key=ids.index),
            'endWordId': max((end for start, end in ranges), key=ids.index), 'parts': parts}
    row = dict(id=identity, base=project_path, clip=clip, cuts=cuts, edges=edges, reject=reject)
    if reject:
        return row
    project['edits'].update(clips=parts, cutWordIds=cuts, cutPauseIds=[])
    plans = json.loads(subprocess.run(['node', '--input-type=module', '-e', '''
import { projectPlans } from './tools/fixtures/editing/lib/voxclip.mjs'
import { timelineWith } from './tools/fixtures/editing/lib/reference.mjs'
import { readFileSync } from 'node:fs'
console.log(JSON.stringify(await projectPlans(JSON.parse(readFileSync(0)), timelineWith)))
'''], input=json.dumps(project), text=True, capture_output=True, cwd=ROOT, check=True).stdout)
    rate = plans['sampleRate']
    total = int(plans['sourceDurationSeconds'] * rate)
    offset, kept, captions, seams, probes, fades = 0, [], [], [], [], []
    for part in plans['clips']:
        if not part['kept']:
            continue
        if offset:
            seams.append(offset)
        for caption in part['captions']:
            captions.append([caption['id'], round(caption['start'] * rate) + offset, round(caption['end'] * rate) + offset])
        for start, end in part['kept']:
            length = end - start
            kept.append([start, end])
            probes.append([start + length // 2, offset + length // 2])
            fade = min(int(rate * 0.005 + 0.5), length // 2)
            fades.append([offset, fade if start else 0, fade if end < total else 0])
            offset += length
    cursor, complement = 0, []
    for start, end in sorted(kept):
        if cursor < start:
            complement.append([cursor, start])
        cursor = end
    if cursor < total:
        complement.append([cursor, total])
    row.update(rate=rate, kept=kept, complement=complement, captions=captions, seams=seams, probes=probes, fades=fades)
    if voice:
        segment = project['voiceLab']['segments'][0]
        start = round(segment['replace']['start'] * rate)
        part = plans['clips'][1]
        output = plans['clips'][0]['outputSamples'] + start - part['kept'][0][0]
        row['voice'] = dict(segmentId=segment['id'], source=start, output=output)
    return row


base = 'story-clips/story-project.voxclip'
vectors = [
    vector('out-of-order-with-cuts-and-source-edges', base, [('w9', 'w9'), ('w1', 'w3'), ('w5', 'w7')], ['w2', 'w6'], edges=True),
    vector('adjacent-but-disjoint', base, [('w3', 'w4'), ('w1', 'w2')], []),
    vector('overlapping-parts', base, [('w3', 'w5'), ('w1', 'w3')], [], reject=True),
    vector('voice-patch-in-part-two', 'voice-lab/passage-render-v3.voxclip', [('w9', 'w9'), ('w3', 'w7'), ('w1', 'w1')], [], voice=True),
]
(SHARED / 'story-clips/plan-vectors.json').write_text(json.dumps(vectors, indent=2) + '\n')
