import argparse
import json
from pathlib import Path


def document():
    return {
        'schema': 'voxclip-pace-matching/2',
        'sourceSampleRate': 48000,
        'seamKind': 'gap',
        'incomingSilence': 0.05,
        'outgoingSilence': 0.05,
        'caseCount': 6,
        'cases': [
            {'id': 'phrase-1', 'windowSeconds': 19.400, 'measuredSeconds': 16.115,
             'quietSpan': [0.4, 18.9], 'pace': 1.0, 'fits': True, 'keepsSource': False, 'videoCut': True},
            {'id': 'phrase-2', 'windowSeconds': 5.120, 'measuredSeconds': 3.390,
             'quietSpan': [0.4, 4.7], 'pace': 1.0, 'fits': True, 'keepsSource': False, 'videoCut': True},
            {'id': 'phrase-3', 'windowSeconds': 1.145, 'measuredSeconds': 1.830,
             'quietSpan': [0.4, 0.7], 'pace': 1.0, 'fits': False, 'keepsSource': False, 'videoCut': False},
            {'id': 'mvp9-4.1-5.4', 'windowSeconds': 5.4, 'measuredSeconds': 4.1,
             'quietSpan': [0.4, 4.9], 'pace': 1.0, 'fits': True, 'keepsSource': False, 'videoCut': True},
            {'id': 'mvp9-1.3-2.2', 'windowSeconds': 2.2, 'measuredSeconds': 1.3,
             'quietSpan': [0.4, 1.8], 'pace': 1.0, 'fits': True, 'keepsSource': False, 'videoCut': True},
            {'id': 'mvp9-2.7-5.5', 'windowSeconds': 5.5, 'measuredSeconds': 2.7,
             'quietSpan': [0.4, 5.0], 'pace': 1.0, 'fits': True, 'keepsSource': False, 'videoCut': True},
        ],
    }


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[3]
    path = root / 'shared/fixtures/voice-lab/pace-matching-cases.json'
    rendered = json.dumps(document(), indent=2) + '\n'
    if args.check:
        if path.read_text() != rendered:
            raise SystemExit('pace-matching-cases.json differs; regenerate it')
        print('pace-matching-cases.json: identical')
    else:
        path.write_text(rendered)
