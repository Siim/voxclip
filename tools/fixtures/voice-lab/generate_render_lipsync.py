#!/usr/bin/env python3
"""Generate a lip-synced Rewrite project and its cases (voice-lab.md §8.9, Mac sync-3).

Mac saves a lip-synced Rewrite segment with video.mode = lipsync. The recipe keeps the source, cut or Match video
fields of the video the lip sync was made over and stores the provider sync mode that was actually used. This project
has one cut_off segment over the source video and one remap segment over a quiet-boundary cut. Each segment's second
candidate is the same take without lip sync. Windows decodes, validates and saves the project unchanged, and refuses to
render a selected lip-synced segment. Mac renders it.

Writes shared/fixtures/voice-lab/lipsync-render-v3.voxclip (from the committed passage-render-v3.voxclip, so it runs
after generate_render.py) and lipsync-project-cases.json. Run from any directory."""
import copy
import json
import math
import re
from pathlib import Path

root = Path(__file__).resolve().parents[3]
fixtures = root / 'shared/fixtures/voice-lab'
RATE = 1000  # the passage fixture's source sample rate
ASSET_RATE = 24000
MODEL = 'fal-ai/sync-lipsync/v3'


def half_up(value):
    return math.floor(value + .5)


def canonical_timestamps(node):
    """Timestamps under keys ending in At, written as a save writes them (three fraction digits)."""
    if isinstance(node, dict):
        for key, value in node.items():
            if key.endswith('At') and isinstance(value, str):
                node[key] = re.sub(r':(\d\d)Z$', r':\1.000Z', value)
            else:
                canonical_timestamps(value)
    elif isinstance(node, list):
        for value in node:
            canonical_timestamps(value)


def window(start, end, total):
    """Mac LipsyncWindow.make: one second of handles, widened to at least three seconds inside the source."""
    lower, upper = max(0, start - RATE), min(total, end + RATE)
    if upper - lower < 3 * RATE:
        lower = max(0, lower - (3 * RATE - (upper - lower) + 1) // 2)
        upper = min(total, lower + 3 * RATE)
        lower = upper - 3 * RATE
    return lower, upper


def lip_synced(video, asset_id, request_id, bounds, sync_mode):
    """Mac VoiceLabVideoRecipe.addingLipsync: every other field of the base video stays as it was."""
    synced = copy.deepcopy(video)
    synced.update({'mode': 'lipsync', 'assetId': asset_id, 'provider': 'fal', 'model': MODEL, 'requestId': request_id,
                   'windowStartSample': bounds[0], 'windowEndSample': bounds[1], 'syncMode': sync_mode})
    return synced


project = json.loads((fixtures / 'passage-render-v3.voxclip').read_text())
canonical_timestamps(project)
total = half_up(project['media']['source']['durationSeconds'] * RATE)
passage = project['voiceLab']['segments'][0]

# Segment 2 replaces "Thanks" (5.3 s to 6.0 s) with a 0.65 s take; the video cuts 50 ms at a quiet boundary.
thanks = copy.deepcopy(passage)
thanks['id'] = 'vl-thanks'
thanks['replace'] = {'start': 5.3, 'end': 6.0, 'firstWordId': 'w9', 'lastWordId': 'w9'}
thanks['text'] = {'original': 'Thanks', 'new': 'new words'}
thanks['outDuration'] = .65
cut = {'startSample': 5600, 'endSample': 5650}
for index, candidate in enumerate(thanks['candidates']):
    recipe = candidate['recipe']
    seed = 17 + index
    trim_start = recipe['audio']['trimStart']
    recipe['audio']['trimEnd'] = round(trim_start + .65, 12)
    recipe['audio']['stretch'] = 1
    recipe['outDuration'] = .65
    recipe['seed'] = seed
    recipe['chunks'][0].update({'sourceStartSample': 5300, 'sourceEndSample': 6000, 'requestId': f'request-{seed}', 'seed': seed,
                                'assembledStartFrame': half_up(trim_start * ASSET_RATE),
                                'assembledEndFrame': half_up(recipe['audio']['trimEnd'] * ASSET_RATE)})
    recipe['video'].update({'mode': 'cut', 'sourceStartSample': 5300, 'sourceEndSample': 6000, 'outputSamples': 650,
                            'zoom': 1.06, 'faceX': .5, 'faceY': .5})
    recipe['video']['cuts'] = [dict(cut)]
    recipe['provenance'].update({'requestId': f'request-{seed}', 'seed': seed})
    recipe['cost']['quoteId'] = f'quote-{seed}'

segments = [(passage, 'cut_off', 'lipsync-passage'), (thanks, 'remap', 'lipsync-thanks')]
video_assets = []
expected_segments = []
for segment, sync_mode, asset_id in segments:
    recipe = segment['candidates'][0]['recipe']
    base = recipe['video']
    bounds = window(base['sourceStartSample'], base['sourceEndSample'], total)
    recipe['video'] = lip_synced(base, asset_id, f'{asset_id}-request', bounds, sync_mode)
    video_assets.append({'id': asset_id, 'file': f"{project['id']}/{asset_id}.mp4", 'sha256': (asset_id.encode().hex() * 4)[:64],
                         'durationSeconds': (bounds[1] - bounds[0]) / RATE, 'frameRate': 30, 'width': 1920, 'height': 1080})
    segment['selectedCandidateIndex'] = 0
    segment['audio'] = copy.deepcopy(recipe['audio'])
    segment['words'] = copy.deepcopy(recipe['words'])
    segment['provenance'] = copy.deepcopy(recipe['provenance'])
    expected_segments.append({'id': segment['id'], 'candidate': 0, 'syncMode': sync_mode, 'baseMode': base['mode'],
                              'assetId': asset_id, 'windowStartSample': bounds[0], 'windowEndSample': bounds[1],
                              'outputSamples': base['outputSamples'], 'plainCandidate': 1})
project['voiceLab']['segments'] = [passage, thanks]
project['voiceLab']['videoAssets'] = video_assets
(fixtures / 'lipsync-render-v3.voxclip').write_text(json.dumps(project, indent=2, ensure_ascii=False) + '\n')

# Rendering refuses only while a selected candidate is lip-synced; Mac renders every selection.
renders = []
for name, choice in [('both-lip-synced', [0, 0]), ('passage-plain', [1, 0]), ('thanks-plain', [0, 1]), ('both-plain', [1, 1])]:
    renders.append({'id': name, 'selected': {'vl-passage': choice[0], 'vl-thanks': choice[1]},
                    'windows': None if choice == [1, 1] else 'videoModeUnsupported', 'mac': None})
# Changes to a lip-synced candidate's video and the error both validators give.
invalid = [
    {'id': 'unknown-sync-mode', 'segment': 'vl-passage', 'set': {'syncMode': 'stretch'}, 'error': 'missingRenderPolicy'},
    {'id': 'missing-sync-mode', 'segment': 'vl-passage', 'set': {'syncMode': None}, 'error': 'missingRenderPolicy'},
    {'id': 'window-inside-the-segment', 'segment': 'vl-passage', 'set': {'windowStartSample': 2600}, 'error': 'missingRenderPolicy'},
    {'id': 'unknown-video-asset', 'segment': 'vl-thanks', 'set': {'assetId': 'lipsync-missing'}, 'error': 'missingRenderPolicy'},
    {'id': 'source-base-with-a-zoom', 'segment': 'vl-passage', 'set': {'zoom': 1.3}, 'error': 'invalidRange'},
    {'id': 'cut-base-inside-the-edge-guard', 'segment': 'vl-thanks', 'set': {'cuts': [{'startSample': 5350, 'endSample': 5400}]}, 'error': 'invalidRange'},
]
cases = {'schema': 'voxclip-lipsync-project/1', 'caseCount': len(expected_segments) + len(renders) + len(invalid),
         'project': 'lipsync-render-v3.voxclip', 'segments': expected_segments, 'renders': renders, 'invalid': invalid}
(fixtures / 'lipsync-project-cases.json').write_text(json.dumps(cases, indent=2) + '\n')
