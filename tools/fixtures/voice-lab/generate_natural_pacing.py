import argparse
import json
from pathlib import Path


def document():
    return {
        'schema': 'voxclip-natural-pacing/1',
        'sourceSampleRate': 48000,
        'caseCount': 2,
        'cases': [
            {'id': 'short-hard-window', 'windowSeconds': 0.3,
             'reserveSeconds': 0.06, 'speechSeconds': 0.18},
            {'id': 'long-hard-window', 'windowSeconds': 1.1,
             'reserveSeconds': 0.14, 'speechSeconds': 0.82},
        ],
    }


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    path = Path(__file__).resolve().parents[3] / 'shared/fixtures/voice-lab/natural-pacing-cases.json'
    rendered = json.dumps(document(), indent=2) + '\n'
    if args.check:
        if path.read_text() != rendered:
            raise SystemExit('natural-pacing-cases.json differs; regenerate it')
        print('natural-pacing-cases.json: identical')
    else:
        path.write_text(rendered)
