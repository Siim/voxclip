#!/usr/bin/env python3
import json
from pathlib import Path

nonce = ['velvet', 'garden', 'cobalt', 'silver']
expected = ['fixture'] * 46 + nonce
cases = [
    {'id': 'wer-0.14-all-nonces', 'recognized': ['different'] * 7 + expected[7:], 'wer': .14, 'passes': True},
    {'id': 'wer-0.10-missing-nonce', 'recognized': ['different'] * 4 + expected[4:-1], 'wer': .10, 'passes': False},
]
path = Path(__file__).resolve().parents[3] / 'shared/fixtures/voice-lab/consent-checks.json'
path.write_text(json.dumps({'language': 'en', 'expected': expected, 'nonce': nonce, 'cases': cases}, indent=2) + '\n')
