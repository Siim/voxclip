#!/usr/bin/env python3
"""Write portable recording examples and derive plans from the single-take oracle."""
import json
import subprocess
from copy import deepcopy
from fractions import Fraction
from math import ceil, floor
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
OUTPUT = ROOT / 'shared/fixtures/recordings'
RATE = 48_000
NATIVE_RATE = 44_100


def write(name, data):
    (OUTPUT / name).write_text(json.dumps(data, indent=2, ensure_ascii=False) + '\n')


def word(identifier, text, start, end, raw_start=None, raw_end=None):
    return {'id': identifier, 'text': text, 'kind': 'word', 'start': start, 'end': end,
            'rawStart': raw_start, 'rawEnd': raw_end, 'conf': None, 'speaker': None, 'timing': 'native'}


def samples(seconds):
    return floor(seconds * RATE + 0.5)


def plan_vectors(mixed_rate):
    reference = deepcopy(mixed_rate)
    primary = reference['media']['source']
    primary.update(durationSeconds=5)
    companion = reference['media']['additionalSources'][0]
    companion.update(durationSeconds=3, audio=deepcopy(primary['audio']))
    spoken = reference['media']['spokenSources'][0]
    spoken.update(offsetSeconds=ceil(primary['durationSeconds']) + 1)

    def sentence_words(sentences):
        words = []
        for text, start, end in sentences:
            tokens = text.split()
            step = (end - start) / len(tokens)
            for index, token in enumerate(tokens):
                words.append(word(f'w{len(words) + 1}', token, start + index * step,
                                  end if index == len(tokens) - 1 else start + (index + 0.8) * step))
        return words

    reference['transcript'].update(durationSeconds=5, words=sentence_words([
        ('I started Superscribe as a dictation tool.', 0, 0.9),
        ('It grew from my own notes.', 1.1, 1.65),
        ('Sorry, where was I?', 1.85, 2.15),
        ('It became my personal time tracker.', 2.35, 3.35),
        ('Now it does both.', 4.5, 5),
    ]))
    spoken['transcript'].update(durationSeconds=3, words=sentence_words([
        ('I started Superscribe as a dictation tool that supports time tracking.', 0, 1.2),
        ('It became my personal time tracker.', 1.35, 1.65),
        ("It's a reporting tool.", 2.5, 3),
    ]))
    ranges = [('A1', 'r2.w1', 'r2.w11'), ('B1', 'w8', 'w13'), ('B2', 'w18', 'w23'),
              ('A2', 'r2.w18', 'r2.w21'), ('B3', 'w24', 'w27')]

    def case(identity, base, edits, parts=None, story=False, lead_in=None):
        media = base['media']
        second = media['spokenSources'][0]
        regions = [(media['source'], base['transcript'], '', 0),
                   (media['additionalSources'][0], second['transcript'], second['wordIdPrefix'], second['offsetSeconds'])]
        all_ids = [prefix + item['id'] for _, transcript, prefix, _ in regions for item in transcript['words']]
        clip = None
        if parts:
            clip = dict(id='clip-recordings', startWordId=min((start for _, start, _ in parts), key=all_ids.index),
                        endWordId=max((end for _, _, end in parts), key=all_ids.index), title=None, origin='manual',
                        aiResultId=None, aiClipIndex=None, selected=True)
            if story:
                clip['kind'] = 'story'
                clip['parts'] = [dict(id=label, startWordId=start, endWordId=end) for label, start, end in parts]
            if lead_in is not None:
                assert parts[0][1] == 'r2.w1' and second['transcript']['words'][0]['start'] == 0
                clip['leadInSeconds'] = lead_in
        locals_ = []
        for media_ref, transcript, prefix, offset in regions:
            local_words = deepcopy(transcript['words'])
            for item in local_words:
                item['id'] = prefix + item['id']
                if prefix:
                    for key in ('start', 'end'):
                        item[key] = samples(item[key]) / RATE
            ids = {item['id'] for item in local_words}
            local_clips = [dict(id=label, startWordId=start, endWordId=end) for label, start, end in parts or [] if start in ids]
            local_duration = samples(media_ref['durationSeconds']) / RATE
            locals_.append(dict(media={'source': dict(media_ref, audio={'sampleRate': RATE}, durationSeconds=local_duration)},
                                transcript=dict(transcript, words=local_words), edits=dict(edits, clips=local_clips)))
        oracle = json.loads(subprocess.run(['node', '--input-type=module', '-e', '''
import { projectPlans } from './tools/fixtures/editing/lib/voxclip.mjs'
import { timelineWith } from './tools/fixtures/editing/lib/reference.mjs'
import { readFileSync } from 'node:fs'
console.log(JSON.stringify(await Promise.all(JSON.parse(readFileSync(0)).map(project => projectPlans(project, timelineWith)))))
'''], input=json.dumps(locals_), text=True, capture_output=True, cwd=ROOT, check=True).stdout)
        if parts:
            local_plans = {plan['id']: (index, plan) for index, region in enumerate(oracle) for plan in region['clips']}
            sequence = [(label, *local_plans[label]) for label, _, _ in parts]
        else:
            sequence = [(None, index, region['take']) for index, region in enumerate(oracle)]
        output, kept, fades, part_seams, recording_seams, captions, sources, expected_parts = 0, [], [], [], [], [], [], []
        for label, index, plan in sequence:
            media_ref, _, _, offset_seconds = regions[index]
            key, offset, duration = media_ref['contentKey'], offset_seconds * RATE, samples(media_ref['durationSeconds'])
            if label:
                expected_parts.append(dict(id=label, sourceKey=key, kept=plan['kept']))
            if not plan['kept']:
                continue
            if output and story:
                part_seams.append(output)
            if output and key != sources[-1][0]:
                recording_seams.append(output)
            for caption_index, caption in enumerate(plan['captions']):
                captions.append([caption['id'], caption['text'], output + samples(caption['start']),
                                 output + samples(caption['end']), bool(captions) and output > 0 and caption_index == 0])
            for start, end in plan['kept']:
                length = end - start
                fade = min(samples(0.005), length // 2)
                kept.append([offset + start, offset + end])
                sources.append([key, start, end])
                fades.append([output, fade if start else 0, fade if end < duration else 0])
                output += length
        cursor, cuts = 0, []
        total = regions[-1][3] * RATE + samples(regions[-1][0]['durationSeconds'])
        for start, end in sorted(kept):
            if cursor < start:
                cuts.append([cursor, start])
            cursor = end
        if cursor < total:
            cuts.append([cursor, total])
        return dict(id=identity, project='reference-recordings.voxclip' if base is reference else 'two-recordings.voxclip',
                    clip=clip, edits=edits, totalSamples=total, outputSamples=output, kept=kept, cuts=cuts, fades=fades,
                    partSeams=part_seams, recordingSeams=recording_seams, captions=captions, sources=sources, parts=expected_parts,
                    pauseIds=[pause['id'] for region in oracle for pause in region['pauses']])

    edits = dict(pauseThresholdSeconds=0.8, pauseKeepSeconds=0.15, cutWordIds=[], cutPauseIds=[], corrections={})
    reference['edits'] = dict(edits, clips=[], activeClipId=None)
    write('reference-recordings.voxclip', reference)
    cases = [case('five-part-a1-b1-b2-a2-b3', reference, edits, ranges, story=True),
             case('full-take-caption-seam', reference, edits),
             case('region-start-and-end', reference, edits, [ranges[0], ranges[-1]], story=True, lead_in=0.6),
             case('pause-beside-region-end', reference, dict(edits, cutPauseIds=['pause-after-r2.w17']),
                  [('A', 'r2.w1', 'r2.w21')]),
             case('44100-on-48000-with-companion-edits', mixed_rate,
                  dict(edits, pauseThresholdSeconds=0.5, cutWordIds=['r2.w2'], cutPauseIds=['pause-after-r2.w1'],
                       corrections={'r2.w1': 'Report'})),
             case('44100-on-48000-companion-clip', mixed_rate, edits, [('A', 'r2.w1', 'r2.w2')])]
    write('plan-cases.json', dict(schema='voxclip-recording-plans/1', sampleRate=RATE, cases=cases))


def main():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    project = json.loads((ROOT / 'shared/fixtures/story-clips/story-project.voxclip').read_text())
    primary = project['media']['source']
    primary.update(absolutePath='/synthetic/DJI_0007.MOV', relativePath='DJI_0007.MOV', durationSeconds=2.125)
    project['schemaVersion'] = 7
    root_words = [word('w1', 'Opening', 0.123456789, 0.45), word('w2', 'continues', 1.5, 2.0)]
    project['transcript'].update(words=root_words, durationSeconds=primary['durationSeconds'])

    local_duration = Fraction(NATIVE_RATE + 1, NATIVE_RATE)
    companion = dict(primary, absolutePath='/synthetic/DJI_0010.MOV', relativePath='DJI_0010.MOV',
                     contentKey='b' * 64, durationSeconds=float(local_duration), audio={'sampleRate': NATIVE_RATE, 'channels': 1})
    unused = dict(companion, contentKey='c' * 64, absolutePath='/synthetic/DJI_0006.MOV', relativePath='DJI_0006.MOV')
    project['media']['additionalSources'] = [companion, unused]
    native_words = [(5, 4000, 1, 4100), (42000, 44050, None, None)]
    spoken_words = [word(f'w{index}', text, *(sample / NATIVE_RATE if sample is not None else None for sample in row))
                    for index, (text, row) in enumerate(zip(('Reporting', 'tool'), native_words), 1)]
    transcript = dict(project['transcript'], words=spoken_words, durationSeconds=float(local_duration), rawKey='d' * 64)
    offset_seconds = ceil(primary['durationSeconds']) + 1
    project['media']['spokenSources'] = [{'sourceKey': companion['contentKey'], 'offsetSeconds': offset_seconds,
                                          'wordIdPrefix': 'r2.', 'gainDb': -1.8, 'transcript': transcript}]
    clip = deepcopy(project['edits']['clips'][0])
    clip.update(startWordId='w1', endWordId='r2.w2', title='Two recordings')
    clip['parts'][0].update(startWordId='r2.w1', endWordId='r2.w2', takeReason='A clearer opening')
    clip['parts'][1].update(startWordId='w1', endWordId='w2')
    project['edits'].update(clips=[clip], corrections={'r2.w1': 'Report'}, cutWordIds=['r2.w2'], cutPauseIds=['pause-after-r2.w1'])
    write('two-recordings.voxclip', project)

    def resample(sample):
        return floor(Fraction(sample * RATE, NATIVE_RATE) + Fraction(1, 2))

    offset = offset_seconds * RATE
    primary_length = floor(Fraction(str(primary['durationSeconds'])) * RATE + Fraction(1, 2))
    companion_length = resample(NATIVE_RATE + 1)
    regions = [dict(key=primary['contentKey'], label='0007', prefix='', offsetSamples=0, durationSamples=primary_length, gainDb=0, colourIndex=0),
               dict(key=companion['contentKey'], label='0010', prefix='r2.', offsetSamples=offset, durationSamples=companion_length, gainDb=-1.8, colourIndex=1)]
    edges = [-1, 0, primary_length - 1, primary_length, offset - 1, offset, offset + 1, offset + companion_length - 1, offset + companion_length]
    resolved = []
    for sample in edges:
        matches = [(region['key'], sample - region['offsetSamples']) for region in regions
                   if region['offsetSamples'] <= sample < region['offsetSamples'] + region['durationSamples']]
        resolved.append(dict(clockSample=sample, source=dict(zip(('key', 'localSample'), matches[0])) if matches else None))
    shifted = [{'id': f'r2.w{index}', 'samples': [offset + resample(sample) if sample is not None else None for sample in row]}
               for index, row in enumerate(native_words, 1)]
    after_both = ceil(offset_seconds + local_duration) + 1
    write('clock-cases.json', {
        'schema': 'voxclip-recording-clock/1', 'project': 'two-recordings.voxclip', 'sampleRate': RATE,
        'regions': regions, 'guardGaps': [[primary_length, offset]], 'resolve': resolved, 'shiftedWords': shifted,
        'selection': {'startWordId': 'w2', 'endWordId': 'r2.w1', 'refusal': 'A part comes from one recording.'},
        'edits': {'cutWordIds': ['r2.w2'], 'cutPauseIds': ['pause-after-r2.w1'], 'corrections': {'r2.w1': 'Report'}},
        'invalidSpokenSources': [dict(name=name, overrides=overrides) for name, overrides in [
            ('empty', []),
            ('null', None),
            ('too many', [{}] * 6),
            ('duplicate recording', [{}, dict(wordIdPrefix='r3.', offsetSeconds=after_both)]),
            ('unknown companion', [dict(sourceKey='f' * 64)]),
            ('primary is not a companion', [dict(sourceKey=primary['contentKey'])]),
            ('duplicate prefix', [{}, dict(sourceKey=unused['contentKey'], offsetSeconds=after_both)]),
            ('guard gap too small', [dict(offsetSeconds=offset_seconds - 1)]),
            ('fractional offset', [dict(offsetSeconds=offset_seconds + 0.5)]),
            ('invalid prefix', [dict(wordIdPrefix='r02.')]),
            ('invalid gain', [dict(gainDb=12.1)]),
            ('invalid label', [dict(label='🟣' * 25)]),
            ('unknown property', [dict(unexpected=True)]),
            ('word outside its recording', [dict(transcript=dict(transcript, words=[dict(spoken_words[0], end=2.0)]))]),
            ('colliding local word IDs', [dict(transcript=dict(transcript, words=[spoken_words[0], dict(spoken_words[1], id='w1')]))]),
        ]],
        'removal': {'removedKey': companion['contentKey'], 'nextKey': unused['contentKey'], 'afterBothOffset': after_both,
                    'survivingPrefix': 'r3.', 'readdedPrefix': 'r4.'},
    })
    plan_vectors(project)


if __name__ == '__main__':
    main()
