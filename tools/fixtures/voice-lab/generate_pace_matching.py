import argparse
import json
from pathlib import Path


def document():
    return {
        'schema': 'voxclip-pace-matching/1',
        'sourceSampleRate': 48000,
        'seamKind': 'gap',
        'incomingSilence': 0.05,
        'outgoingSilence': 0.05,
        'caseCount': 3,
        'cases': [
            {'id': 'phrase-1', 'windowSeconds': 19.400, 'measuredSeconds': 16.115,
             'pace': 0.84, 'fits': True, 'keepsSource': True},
            {'id': 'phrase-2', 'windowSeconds': 5.120, 'measuredSeconds': 3.390,
             'pace': 0.70, 'fits': True, 'keepsSource': True},
            {'id': 'phrase-3', 'windowSeconds': 1.145, 'measuredSeconds': 1.830,
             'pace': 1.20, 'fits': False, 'keepsSource': False},
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
