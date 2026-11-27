#!/usr/bin/env python3
"""Write the portable two-recording clock example and its model vectors."""
import json
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
        'removal': {'removedKey': companion['contentKey'], 'nextKey': unused['contentKey'], 'afterBothOffset': after_both,
                    'survivingPrefix': 'r3.', 'readdedPrefix': 'r4.'},
    })


if __name__ == '__main__':
    main()
