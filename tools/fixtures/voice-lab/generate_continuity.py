#!/usr/bin/env python3
"""Portable exact-rational/binary64 oracle for Voice Lab section 7.2 placement."""
import hashlib
import json
from fractions import Fraction
from math import floor
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / 'shared/fixtures/voice-lab/continuity-cases.json'


def outcome(rate, timestamp, previous_end, next_sample, frames):
    if timestamp is None:
        if previous_end is None:
            return dict(error='unreadable')
        first = previous_end
    else:
        value = timestamp['value']
        numerator = timestamp['numerator']
        denominator = timestamp['denominator']
        position = float(Fraction(value * numerator * rate, denominator))
        if position < -4_611_686_018_427_387_904 or position >= 4_611_686_018_427_387_904:
            return dict(error='unreadable')
        tick = float(rate) * numerator / denominator
        first = floor(position + 0.5)
        if previous_end is not None and abs(position - previous_end) < max(1.0, tick):
            first = previous_end
    if first > next_sample:
        return dict(firstSample=first, error='rangeOutsideMedia')
    return dict(firstSample=first, skipCount=min(frames, next_sample - first))


def main():
    cases = []

    def add(name, value, denominator, previous_end, next_sample, rate=48_000, frames=960):
        timestamp = None if value is None else dict(value=value, numerator=1, denominator=denominator)
        expected = outcome(rate, timestamp, previous_end, next_sample, frames)
        cases.append(dict(name=name, rate=rate, timestamp=timestamp, previousEnd=previous_end,
                          nextSample=next_sample, sampleCount=frames, expected=expected))
        return expected.get('firstSample')

    add('first-4799-point-four-at-4800', 23_997, 240_000, None, 4_800)
    add('anchored-4799-point-four-at-4800', 23_997, 240_000, 4_800, 4_800)
    add('first-minus-point-six', -3, 240_000, None, 0)
    add('anchored-minus-point-six', -3, 240_000, 0, 0)
    add('first-negative-half-up-tie', -1, 96_000, None, 0)
    add('negative-whole-frame-overlap', -2_000, 48_000, None, 0)
    add('missing-before-anchor', None, 1_000, None, 0)
    add('missing-after-anchor', None, 1_000, 1_920, 1_920)
    add('missing-after-negative-anchor', None, 1_000, -16, 0)
    add('first-late-is-a-gap-not-a-snap', 24_003, 240_000, None, 4_800)
    add('anchored-late-fraction-snaps', 24_003, 240_000, 4_800, 4_800)
    for direction, step in [('early', -1), ('late', 1)]:
        for label, previous in [('inside', 4_800 + step), ('boundary', 4_800), ('outside', 4_800 - step)]:
            add(f'millisecond-{direction}-{label}', 100 + step, 1_000, previous, previous)
        for ticks in [0, 1, 2]:
            add(f'ninetiethousand-48k-{direction}-{ticks}-ticks', step * ticks, 90_000, 0, 0)
        for ticks in [1, 2]:
            add(f'ninetiethousand-96k-{direction}-{ticks}-ticks', step * ticks, 90_000, 0, 0, rate=96_000)
        for samples in [0, 1, 2]:
            add(f'sample-rate-{direction}-{samples}-samples', 4_800 + step * samples, 48_000, 4_800, 4_800)
    first = add('forty-sample-gaps-anchor', 0, 1_000, None, 0, frames=920)
    previous = first + 920
    first = add('forty-sample-gaps-first-tolerated', 20, 1_000, previous, previous, frames=920)
    previous = first + 920
    add('forty-sample-gaps-second-refused', 40, 1_000, previous, previous, frames=920)
    add('first-overflowing-position', 9_223_372_036_854_775_807, 1, None, 0)
    add('first-negative-overflowing-position', -9_223_372_036_854_775_807, 1, None, 0)
    document = dict(schema='voxclip-voice-lab-continuity/1', caseCount=len(cases), cases=cases)
    data = (json.dumps(document, ensure_ascii=True, indent=2) + '\n').encode('utf-8')
    OUT.write_bytes(data)
    print(f'{OUT.name}: {len(cases)} cases, sha256 {hashlib.sha256(data).hexdigest()}')


if __name__ == '__main__':
    main()
