#!/usr/bin/env python3
"""Build small synthetic Voice Lab v2 project fixtures from the unchanged v1 interview, then the fit planner's
vectors (fit-cases.json) from their reference module, generate_fit.py."""
import copy
import hashlib
import json
import runpy
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SOURCE = ROOT / 'shared/fixtures/projects/interview-take.voxclip'
OUT = ROOT / 'shared/fixtures/voice-lab'
base = json.loads(SOURCE.read_text())
base['schemaVersion'] = 2
base['media']['source']['durationSeconds'] = 7
base['media']['source']['audio']['sampleRate'] = 1000
base['transcript']['durationSeconds'] = 7
base['edits'].update(cutWordIds=[], cutPauseIds=[], corrections={}, clips=[{
    'id': 'clip-main', 'startWordId': 'w3', 'endWordId': 'w8', 'title': 'Fixture clip',
    'origin': 'manual', 'aiResultId': None, 'aiClipIndex': None, 'selected': True
}], activeClipId='clip-main')
project_id = base['id']

def asset(name, duration):
    return {'id': name, 'kind': 'audio', 'file': f'{project_id}/{name}.wav',
            'sha256': hashlib.sha256(name.encode()).hexdigest(), 'durationSeconds': duration,
            'sampleRate': 24000, 'createdAt': '2026-10-25T12:10:00Z'}

def segment(name, start, end, first, last, out_duration, text, words):
    return {'id': name, 'kind': 'tts', 'enabled': True,
            'replace': {'start': start, 'end': end, 'firstWordId': first, 'lastWordId': last},
            'outDuration': out_duration,
            'audio': {'assetId': 'asset-one', 'trimStart': 0, 'trimEnd': 1, 'stretch': out_duration, 'gainDb': 0},
            'text': {'original': text, 'new': 'new words'}, 'words': words,
            'provenance': {'provider': 'elevenlabs', 'endpoint': 'v1/text-to-speech/fixture',
                           'model': 'fixture-model', 'voiceId': 'fixture-voice',
                           'consentRecordId': 'consent-fixture', 'requestId': 'request-fixture',
                           'seed': 7, 'createdAt': '2026-10-25T12:10:00Z'},
            'qa': {'transcriptMatch': 1, 'lufsJumpLu': 0.2, 'peakDbfs': -1, 'speakerScore': 0.9},
            'candidates': [{'assetId': 'asset-one', 'score': 0.9, 'rejected': None},
                           {'assetId': 'asset-two', 'score': 0.8, 'rejected': None}],
            'selectedCandidateIndex': 0}

passage = copy.deepcopy(base)
passage['voiceLab'] = {'assets': [asset('asset-one', 1), asset('asset-two', 1.2)],
                       'segments': [segment('vl-passage', 2.5, 3.2, 'w4', 'w5', 1,
                           'we ship', [{'text': 'we', 'start': 0, 'end': 0.2, 'synthetic': False},
                                       {'text': 'ship', 'start': 0.2, 'end': 0.5, 'synthetic': True},
                                       {'text': 'today', 'start': 0.5, 'end': 1, 'synthetic': True}])]}
full = copy.deepcopy(base)
full['voiceLab'] = {'assets': [asset('asset-one', 1), asset('asset-two', 1.2)],
                    'segments': [segment('vl-full', 0, 7, 'w1', 'w9', 8,
                        'full take', [{'text': 'whole', 'start': 0, 'end': 8, 'synthetic': True}])]}
for name, value in [('passage-project.voxclip', passage), ('full-take-project.voxclip', full)]:
    (OUT / name).write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')

# Independent arithmetic: seven source seconds at 1000 samples/s; a 700-sample
# source interval is exchanged for 1000 output samples. Clip bounds follow editing §7.2.
expected = {'sampleRate': 1000,
            'passage': {'outputSamples': 7300, 'pieces': [
                ['source', 0, 2500, 0, 2500], ['synth', 2500, 3200, 2500, 3500],
                ['source', 3200, 7000, 3500, 7300]],
                'mapping': [[0, 0], [2.5, 2.5], [2.85, 3], [3.2, 3.5], [7, 7.3]],
                'captions': [['vl-passage:word:0', 2.5, 2.7], ['vl-passage:word:1', 2.7, 3],
                             ['vl-passage:word:2', 3, 3.5]]},
            'disabled': {'outputSamples': 7000},
            'full': {'outputSamples': 8000, 'pieces': [['synth', 0, 7000, 0, 8000]],
                     'mapping': [[0, 0], [3.5, 4], [7, 8]]},
            'clip': {'sourceStart': 1.05, 'sourceEnd': 4.45, 'outputSamples': 3700}}
(OUT / 'plan-cases.json').write_text(json.dumps(expected, indent=2) + '\n')

# voice-lab.md section 8.9.2: the fit planner's vectors, from its standard-library reference.
runpy.run_path(str(Path(__file__).with_name('generate_fit.py')), run_name='__main__')
