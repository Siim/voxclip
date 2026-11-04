#!/usr/bin/env python3
"""Generate Rewrite projects with the user's own recorded take and their cases (voice-lab.md §8.13, Mac VoiceLabRecordedTake).

Mac saves the user's own microphone take of a Rewrite phrase as a `recorded` segment: real speech, so its recipe names no
voice reference and no consent record, its provenance is `microphone`/`local`/`own-microphone` with region `local` and no
pace, its speaker fields are empty, it costs nothing and its words are what on-device recognition heard (never synthetic).
It is rendered like any other accepted take, and only its lip sync, if chosen, is disclosed as AI.

Writes, from the committed passage-, touching- and lipsync-render-v3.voxclip (so it runs after generate_render.py and
generate_render_lipsync.py):
- recorded-render-v3.voxclip: one recorded passage with two ranked candidates and no voice references;
- recorded-lipsync-render-v3.voxclip: the same take, lip-synced (cut_off over the source video);
- recorded-beside-tts-render-v3.voxclip: a cloned passage touching a recorded one through a shared synth seam;
- recorded-take-cases.json (`voxclip-voice-lab-recorded-take-cases/1`): the expected disclosure, aiSegment kinds and
  captions of each project, accept-all without a voice reference, and the refusals of changed recipes.
Run from any directory."""
import copy
import json
import math
import re
from pathlib import Path

root = Path(__file__).resolve().parents[3]
fixtures = root / 'shared/fixtures/voice-lab'
RATE = 1000  # the passage fixture's source sample rate
DURATION = 7.0  # the passage fixture's output duration (render-cases.json)
REQUESTS = ['3f1c2a4e-7b5d-4c6e-9a8f-0d1e2f3a4b5c', '8a9b0c1d-2e3f-4a5b-8c6d-7e8f9a0b1c2d']
TEXT = {'tts': 'Some words in this video were re-voiced with an AI copy of my own voice.',
        'lipsync': 'Lip movements in parts of it were generated with AI.'}


def half_up(value):
    return math.floor(value + .5)


def load(name):
    return json.loads((fixtures / name).read_text())


def record(segment, model='apple-speech'):
    """Make a cloned passage segment the user's own recorded take, as Mac VoiceLabRecordedTake.candidate does."""
    segment['kind'] = 'recorded'
    for index, candidate in enumerate(segment['candidates']):
        recipe = candidate['recipe']
        request = REQUESTS[index] if segment['id'] == 'vl-passage' else REQUESTS[index][:-1] + 'f'
        recipe['words'] = [dict(word, synthetic=False) for word in recipe['words']]
        recipe['qa'].update({'speakerScore': None, 'speakerThreshold': None, 'speakerModel': None, 'speakerPassed': None})
        recipe['provenance'] = {'provider': 'microphone', 'endpoint': 'local', 'model': model, 'voiceId': 'own-microphone',
                                'consentRecordId': None, 'requestId': request, 'seed': recipe['seed'],
                                'createdAt': recipe['provenance']['createdAt'], 'region': 'local'}
        recipe['cost'] = {'quoteId': request, 'usd': 0}
        recipe['voiceRefId'] = None
        recipe['consentVerifiedAt'] = None
    chosen = segment['candidates'][segment['selectedCandidateIndex']]['recipe']
    segment['words'] = copy.deepcopy(chosen['words'])
    segment['provenance'] = copy.deepcopy(chosen['provenance'])
    segment['qa']['speakerScore'] = None


def canonical_timestamps(node):
    """Timestamps under keys ending in At, written as a save writes them (three fraction digits)."""
    if isinstance(node, dict):
        for key, value in node.items():
            if key.endswith('At') and isinstance(value, str): node[key] = re.sub(r':(\d\d)Z$', r':\1.000Z', value)
            else: canonical_timestamps(value)
    elif isinstance(node, list):
        for value in node: canonical_timestamps(value)


def write(name, project):
    canonical_timestamps(project)
    (fixtures / name).write_text(json.dumps(project, indent=2, ensure_ascii=False) + '\n')


def intervals(pieces):
    """Mac deriveDisclosure's label intervals for a non-persistent label: the first 3 s and each AI piece ± 0.5 s, merged
    across gaps under 1 s."""
    spans = sorted([(0, min(3, DURATION))] + [(max(0, start - .5), min(DURATION, end + .5)) for start, end in pieces])
    merged = []
    for start, end in spans:
        if merged and start - merged[-1][1] < 1: merged[-1][1] = max(merged[-1][1], end)
        else: merged.append([start, end])
    return merged


def captions(segment, output_start_sample):
    return [{'id': f"{segment['id']}:word:{index}", 'text': word['text'],
             'start': (output_start_sample + half_up(word['start'] * RATE)) / RATE,
             'end': (output_start_sample + half_up(word['end'] * RATE)) / RATE}
            for index, word in enumerate(segment['words'])]


def disclosure(kinds, pieces):
    seconds = sum(half_up(end * RATE) - half_up(start * RATE) for start, end in pieces) / RATE
    required = bool(pieces)
    persistent = required and seconds > DURATION * .3
    return {'required': required, 'kinds': kinds, 'aiSeconds': seconds, 'persistent': persistent,
            'labelIntervals': ([[0, DURATION]] if persistent else intervals(pieces)) if required else [],
            'text': ' '.join(TEXT[kind] for kind in ['tts', 'lipsync'] if kind in kinds) or None}


# One recorded passage over [2.5, 3.2] s with no voice references.
recorded = load('passage-render-v3.voxclip')
recorded['voiceLab']['voices'] = []
passage = recorded['voiceLab']['segments'][0]
record(passage)
write('recorded-render-v3.voxclip', recorded)

# The same take lip-synced: Mac discloses only the lip sync.
lipsync = copy.deepcopy(recorded)
source = load('lipsync-render-v3.voxclip')
synced = next(segment for segment in source['voiceLab']['segments'] if segment['id'] == 'vl-passage')
video_id = synced['candidates'][0]['recipe']['video']['assetId']
lipsync['voiceLab']['videoAssets'] = [asset for asset in source['voiceLab']['videoAssets'] if asset['id'] == video_id]
lipsync['voiceLab']['segments'][0]['candidates'][0]['recipe']['video'] = copy.deepcopy(synced['candidates'][0]['recipe']['video'])
write('recorded-lipsync-render-v3.voxclip', lipsync)

# A cloned passage [2.5, 3.2] s touching a recorded one [3.2, 3.5] s: only the clone is AI speech.
beside = load('touching-render-v3.voxclip')
record(next(segment for segment in beside['voiceLab']['segments'] if segment['id'] == 'vl-follow'), model='whisper.cpp base')
write('recorded-beside-tts-render-v3.voxclip', beside)

renders = [
    {'id': 'recorded-source', 'project': 'recorded-render-v3.voxclip', 'disclosure': disclosure([], []),
     'aiSegments': [{'segmentId': 'vl-passage', 'kind': 'recorded'}], 'captions': captions(passage, 2500)},
    {'id': 'recorded-lipsync', 'project': 'recorded-lipsync-render-v3.voxclip', 'disclosure': disclosure(['lipsync'], [(2.5, 3.2)]),
     'aiSegments': [{'segmentId': 'vl-passage', 'kind': 'recorded'}], 'captions': captions(passage, 2500)},
    {'id': 'recorded-beside-tts', 'project': 'recorded-beside-tts-render-v3.voxclip', 'disclosure': disclosure(['tts'], [(2.5, 3.2)]),
     'aiSegments': [{'segmentId': 'vl-passage', 'kind': 'tts'}, {'segmentId': 'vl-follow', 'kind': 'recorded'}],
     'captions': [caption for segment, start in zip(beside['voiceLab']['segments'], [2500, 3200]) for caption in captions(segment, start)]},
]

# Accepting the recorded passage into the same project without it needs no voice reference; a cloned take does.
accept_all = [
    {'id': 'recorded-needs-no-voice', 'project': 'recorded-render-v3.voxclip', 'segment': 'vl-passage', 'kind': 'recorded', 'error': None},
    {'id': 'cloned-needs-consent', 'project': 'recorded-render-v3.voxclip', 'segment': 'vl-passage', 'kind': 'tts', 'error': 'consentUnverified'},
]

# Changes to the recorded passage (paths from the segment) and the error both validators give.
recipe = 'candidates/0/recipe/'
invalid = [
    {'id': 'own-voice-without-consent-as-tts', 'error': 'consentUnverified', 'set': {
        'kind': 'tts', recipe + 'words/0/synthetic': True, recipe + 'words/1/synthetic': True,
        'candidates/1/recipe/words/0/synthetic': True, 'candidates/1/recipe/words/1/synthetic': True}},
    {'id': 'consent-record', 'error': 'invalidSegment', 'set': {
        recipe + 'provenance/consentRecordId': 'consent-fixture', 'provenance/consentRecordId': 'consent-fixture'}},
    {'id': 'voice-reference', 'error': 'invalidSegment', 'set': {recipe + 'voiceRefId': 'voice-fixture'}},
    {'id': 'consent-verified-at', 'error': 'invalidSegment', 'set': {recipe + 'consentVerifiedAt': '2026-10-25T12:09:00Z'}},
    {'id': 'cloned-provider', 'error': 'invalidSegment', 'set': {recipe + 'provenance/provider': 'elevenlabs', 'provenance/provider': 'elevenlabs'}},
    {'id': 'paced', 'error': 'invalidSegment', 'set': {recipe + 'provenance/pace': 1.1, 'provenance/pace': 1.1}},
    {'id': 'speaker-score', 'error': 'invalidSegment', 'set': {recipe + 'qa/speakerScore': .9, 'qa/speakerScore': .9}},
    {'id': 'paid', 'error': 'invalidSegment', 'set': {recipe + 'cost/usd': .01}},
    {'id': 'synthetic-words', 'error': 'alignmentUnavailable', 'set': {recipe + 'words/0/synthetic': True}},
    {'id': 'word-check-failed', 'error': 'qaRejected', 'set': {
        recipe + 'qa/transcriptMatch': .5, recipe + 'qa/transcriptExact': False, 'qa/transcriptMatch': .5}},
    {'id': 'passage-without-room-tone', 'error': 'missingRenderPolicy', 'set': {recipe + 'roomTone': None}},
    {'id': 'unranked', 'error': 'invalidCandidate', 'set': {'candidates/0/score': None}},
]
for row in invalid: row.update({'project': 'recorded-render-v3.voxclip', 'segment': 'vl-passage'})

cases = {'schema': 'voxclip-voice-lab-recorded-take-cases/1', 'caseCount': len(renders) + len(accept_all) + len(invalid),
         'renders': renders, 'acceptAll': accept_all, 'invalid': invalid}
(fixtures / 'recorded-take-cases.json').write_text(json.dumps(cases, indent=2) + '\n')
