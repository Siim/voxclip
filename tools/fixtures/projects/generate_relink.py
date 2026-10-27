#!/usr/bin/env python3
"""Generate the shared millisecond-grid relink decisions, editing section 10.3."""
import json
import math
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / 'shared/fixtures/projects/relink-cases.json'


def milliseconds(value):
    # Both Cores multiply in binary64 and then jsRound (floor, plus one at a remainder of 0.5 or more).
    scaled = float(value) * 1000.0
    lower = math.floor(scaled)
    return lower + 1 if scaled - lower >= 0.5 else lower


def main():
    cases = []
    values = [
        ('match', 100, 'original', 2, False, 0.25),
        ('confirmed-within', 200, 'different', 0.29, True, 0.25),
        ('upper-boundary', 200, 'different', 0.30, True, 0.25),
        ('lower-boundary', 200, 'different', 0.20, True, 0.25),
        ('outside', 200, 'different', 0.3001, True, 0.25),
        ('unconfirmed', 200, 'different', 0.26, False, 0.25),
        ('same-size-other-key', 100, 'different', 0.25, False, 0.25),
        ('decimal-upper-boundary', 200, 'different', 10.05, True, 10.00),
        ('decimal-lower-boundary', 200, 'different', 9.95, True, 10.00),
        ('decimal-above', 200, 'different', 10.051, True, 10.00),
        ('decimal-below', 200, 'different', 9.949, True, 10.00),
        ('binary64-half-millisecond', 200, 'different', 0.551, True, 0.5005),
    ]
    for identifier, size, key, duration, confirmed, stored in values:
        expected = 'match' if size == 100 and key == 'original' else 'needsConfirmation' if not confirmed else (
            'different' if abs(milliseconds(duration) - milliseconds(stored)) <= 50 else 'refused')
        cases.append(dict(id=identifier, size=size, key=key, duration=duration,
                          storedDuration=stored, confirmed=confirmed, expected=expected))
    fixture = dict(fixture='voxclip-relink/1', storedSize=100, storedKey='original', storedDuration=0.25, cases=cases)
    OUT.write_text(json.dumps(fixture, indent=2, ensure_ascii=True) + '\n')


if __name__ == '__main__':
    main()
