#!/usr/bin/env python3
"""Build shared/fixtures/projects/timestamps.json: the persisted timestamp rule of editing.md section 10.1.

Writers round an instant to the nearest millisecond, an exact half going to the later instant, and write UTC
YYYY-MM-DDTHH:MM:SS.sssZ in the proleptic Gregorian calendar, years 0001-9999. Readers accept 0-9 fractional
digits and an uppercase Z, and round the same way. The expected values come from exact integer arithmetic and
Python's proleptic Gregorian datetime, independent of both Cores. Nothing reads a clock; the only randomness is
the seeded SplitMix64 below, so two runs write identical bytes. Both native Core suites replay every case.
"""
import hashlib
import json
import math
import re
from datetime import datetime, timedelta
from fractions import Fraction
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / 'shared/fixtures/projects/timestamps.json'

TICKS_PER_SECOND = 10_000_000   # .NET ticks: 100 ns since 0001-01-01T00:00:00Z
TICKS_PER_MILLISECOND = 10_000
EPOCH = datetime(1, 1, 1)
LAST = 3_155_378_975_999_990_000   # 9999-12-31T23:59:59.999Z, the last writable millisecond
REFERENCE = 631_139_040_000_000_000   # 2001-01-01T00:00:00Z, where a macOS Date counts from
PATTERN = re.compile(r'([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})(?:\.([0-9]{1,9}))?Z')
PAST_LAST = 'rounds past 9999-12-31T23:59:59.999Z'


def whole_ticks(year, month, day, hour=0, minute=0, second=0):
    return (datetime(year, month, day, hour, minute, second) - EPOCH) // timedelta(microseconds=1) * 10


def rounded(ticks):
    return (ticks + TICKS_PER_MILLISECOND // 2) // TICKS_PER_MILLISECOND * TICKS_PER_MILLISECOND


def canonical(ticks):
    """The text a writer produces for an instant, or None when it rounds past the last millisecond."""
    ticks = rounded(ticks)
    if ticks > LAST:
        return None
    moment = EPOCH + timedelta(microseconds=ticks // 10)
    return (f'{moment.year:04d}-{moment.month:02d}-{moment.day:02d}T{moment.hour:02d}:{moment.minute:02d}:'
            f'{moment.second:02d}.{moment.microsecond // 1000:03d}Z')


def parse(text):
    """The rounded ticks a reader keeps for a text, or None when the text is refused."""
    match = PATTERN.fullmatch(text)
    if not match:
        return None
    try:
        whole = whole_ticks(*(int(group) for group in match.groups()[:6]))
    except ValueError:
        return None
    nanoseconds = int((match.group(7) or '').ljust(9, '0'))
    ticks = whole + (nanoseconds + 500_000) // 1_000_000 * TICKS_PER_MILLISECOND
    return ticks if ticks <= LAST else None


def mac_ticks(ticks):
    """What the macOS suite writes for these ticks: Date(timeIntervalSinceReferenceDate: Double(seconds) +
    Double(remainder) / 10_000_000), then the exact binary value rounded like any write."""
    seconds, remainder = divmod(ticks - REFERENCE, TICKS_PER_SECOND)
    value = float(seconds) + float(remainder) / 1e7
    return REFERENCE + math.floor(Fraction(value) * 1000 + Fraction(1, 2)) * TICKS_PER_MILLISECOND


def splitmix64(state):
    mask = (1 << 64) - 1
    while True:
        state = (state + 0x9E3779B97F4A7C15) & mask
        z = state
        z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & mask
        z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & mask
        yield z ^ (z >> 31)


def digits(text, zero):
    """ASCII digits rewritten in another Unicode digit block (zero is that block's zero code point)."""
    return ''.join(chr(zero + int(digit)) for digit in text)


# The Unix epoch and the second before it, macOS's reference date and the second before it, a working day, a
# year end, leap-day and century rollovers, the Gregorian reform (Foundation's calendar is Julian before it),
# and the first and last representable seconds.
BASES = [(1970, 1, 1, 0, 0, 0), (1969, 12, 31, 23, 59, 59), (2001, 1, 1, 0, 0, 0), (2000, 12, 31, 23, 59, 59),
         (2026, 10, 27, 12, 34, 56), (2026, 12, 31, 23, 59, 59), (2028, 2, 28, 23, 59, 59), (2028, 2, 29, 23, 59, 59),
         (2000, 2, 28, 23, 59, 59), (2100, 2, 28, 23, 59, 59), (1582, 10, 4, 23, 59, 59), (1582, 10, 15, 0, 0, 0),
         (1, 1, 1, 0, 0, 0), (9999, 12, 31, 23, 59, 59)]
FRACTIONS = ['', '.0', '.000', '.001', '.005', '.123', '.999', '.5', '.12', '.1234', '.1235', '.1234567', '.123456789',
             '.0004999', '.0005', '.9994', '.9995', '.9994999', '.9995000', '.999499999', '.999500000', '.9999999',
             '.999999999']
# Sub-second offsets in ticks: whole seconds, one tick, both sides of a half millisecond, 1 and 5 ms, 1/16 and
# 15/16 s (binary fractions that are exact halves of a millisecond), .123, a half second and the rollovers.
OFFSETS = [0, 1, 4_999, 5_000, 5_001, 10_000, 50_000, 625_000, 1_230_000, 1_234_999, 1_235_000, 5_000_000, 9_375_000,
           9_990_000, 9_994_999, 9_995_000, 9_995_001, 9_996_000, 9_999_999]
REJECTED = [
    ('2026-10-27T12:00:00+00:00', 'offset instead of Z'), ('2026-10-27T12:00:00-00:00', 'offset instead of Z'),
    ('2026-10-27T12:00:00+02:00', 'offset instead of Z'), ('2026-10-27T12:00:00.123-05:00', 'offset instead of Z'),
    ('2026-10-27T12:00:00+0000', 'offset instead of Z'), ('2026-10-27T12:00:00.123+00:00Z', 'offset before Z'),
    ('2026-10-27T12:00:00z', 'lowercase z'), ('2026-10-27T12:00:00.123z', 'lowercase z'),
    ('2026-10-27t12:00:00Z', 'lowercase t'),
    ('2026-10-27T12:00:00.1234567890Z', '10 fractional digits'),
    ('2026-10-27T12:00:00.000000000000Z', '12 fractional digits'),
    ('2026-10-27T12:00:00.Z', 'decimal point without digits'), ('2026-10-27T12:00:00,123Z', 'comma before the fraction'),
    ('2026-10-27T12:00Z', 'missing seconds'), ('2026-10-27T12Z', 'missing minutes and seconds'),
    ('2026-10-27Z', 'date only'), ('2026-10-27', 'date only, no Z'),
    ('2026-10-27T12:00:00', 'no Z'), ('2026-10-27T12:00:00.123', 'no Z'),
    ('2026-10-27 12:00:00Z', 'space instead of T'), ('2026-10-27_12:00:00Z', 'underscore instead of T'),
    ('0000-12-31T23:59:59Z', 'year 0000'), ('10000-01-01T00:00:00Z', 'five-digit year'),
    ('-0001-01-01T00:00:00Z', 'negative year'), ('+2026-10-27T12:00:00Z', 'signed year'),
    ('2026-13-01T00:00:00Z', 'month 13'), ('2026-00-10T00:00:00Z', 'month 00'), ('2026-10-00T00:00:00Z', 'day 00'),
    ('2026-10-32T00:00:00Z', 'day 32'), ('2026-02-29T00:00:00Z', 'February 29 in a common year'),
    ('2100-02-29T00:00:00Z', 'February 29 in a century common year'), ('2026-04-31T00:00:00Z', 'April 31'),
    ('2026-10-27T24:00:00Z', 'hour 24'), ('2026-10-27T12:60:00Z', 'minute 60'), ('2016-12-31T23:59:60Z', 'leap second'),
    ('2026-1-27T12:00:00Z', 'one-digit month'), ('2026-10-7T12:00:00Z', 'one-digit day'),
    ('2026-10-27T1:00:00Z', 'one-digit hour'), ('20261027T120000Z', 'basic format'),
    (' 2026-10-27T12:00:00Z', 'leading space'), ('2026-10-27T12:00:00Z ', 'trailing space'),
    ('2026-10-27T12:00:00Z\n', 'trailing newline'), ('2026-10-27T12:00:00ZZ', 'two Z'),
    ('2026-10-27T12:00:00UTC', 'zone name'), (digits('2026', 0xFF10) + '-10-27T12:00:00Z', 'fullwidth digits'),
    ('2026-10-27T12:00:00.' + digits('123', 0xFF10) + 'Z', 'fullwidth fraction digits'),
    (digits('2026', 0x0660) + '-10-27T12:00:00Z', 'Arabic-Indic digits'), ('', 'empty'),
]

texts, rejected = [], []
for input_text, reason in REJECTED:
    assert parse(input_text) is None, input_text
    rejected.append({'input': input_text, 'reason': reason})
for base in BASES:
    stem = f'{base[0]:04d}-{base[1]:02d}-{base[2]:02d}T{base[3]:02d}:{base[4]:02d}:{base[5]:02d}'
    for fraction in FRACTIONS:
        text = stem + fraction + 'Z'
        ticks = parse(text)
        if ticks is None:
            rejected.append({'input': text, 'reason': PAST_LAST})
            continue
        texts.append({'input': text, 'canonical': canonical(ticks)})
        assert parse(canonical(ticks)) == ticks, text

# Instants both suites hold exactly enough. A macOS Date is binary64, so an instant within its precision of a half
# millisecond can round the other way there; those exact ties stay covered by the seven- and nine-digit texts.
instants, dropped = [], 0
for base in BASES:
    for offset in OFFSETS:
        ticks = whole_ticks(*base) + offset
        if mac_ticks(ticks) != rounded(ticks):
            dropped += 1
            continue
        instants.append({'ticks': str(ticks), 'canonical': canonical(ticks)})
assert any(case['canonical'] is None for case in instants)

# Seeded random instants in years 0001-9999, below the last millisecond. Offsets within 50 us of a half millisecond
# are skipped, because a Date near year 9999 holds an instant only to about 15 us.
SEED, COUNT = 20261027, 10_000
draws = splitmix64(SEED)
digest, first, last = hashlib.sha256(), None, None
for _ in range(COUNT):
    milliseconds = next(draws) % (LAST // TICKS_PER_MILLISECOND)
    offset = next(draws) % 9_000
    ticks = milliseconds * TICKS_PER_MILLISECOND + (offset if offset < 4_500 else offset + 1_000)
    assert mac_ticks(ticks) == rounded(ticks), ticks
    text = canonical(ticks)
    digest.update(text.encode('ascii') + b'\n')
    first, last = first or text, text

document = {
    'schema': 'voxclip-timestamp-cases/1',
    'spec': 'doc/spec/editing.md section 10.1',
    'generator': 'tools/fixtures/projects/generate_timestamps.py',
    'texts': texts,
    'rejected': rejected,
    'instants': instants,
    'property': {'generator': 'splitmix64', 'seed': SEED, 'count': COUNT, 'sha256': digest.hexdigest(),
                 'first': first, 'last': last},
}
OUT.write_text(json.dumps(document, indent=2) + '\n', encoding='utf-8')
print(f'{OUT.relative_to(ROOT)}: {len(texts)} texts, {len(rejected)} rejected, {len(instants)} instants '
      f'({dropped} binary64-ambiguous offsets left to the texts), property {COUNT} instants, sha256 {digest.hexdigest()}')
