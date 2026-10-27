#!/usr/bin/env python3
"""Binary64-only duration oracle for §8.9.1; stdlib, deterministic on Linux and macOS."""
import itertools
import json
import math
import struct
import unicodedata
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / 'shared/fixtures/voice-lab/length-budget-cases.json'


def length(text):
    return sum(unicodedata.category(scalar)[0] == 'L' or unicodedata.category(scalar) == 'Nd'
               for scalar in unicodedata.normalize('NFC', text))


def fixed(value):
    numerator, denominator = value.as_integer_ratio()
    quotient, remainder = divmod(numerator * 10, denominator)
    quotient += remainder * 2 >= denominator
    return f'{quotient // 10}.{quotient % 10}'


def estimate(text, rate):
    return (length(text) / rate + .03) + .06


def adjacent(value, offset):
    bits = struct.unpack('>Q', struct.pack('>d', value))[0]
    return struct.unpack('>d', struct.pack('>Q', bits + offset))[0]


def rate_oracle(source, threshold, candidates):
    if candidates:
        if any(not math.isfinite(row[1]) or not math.isfinite(row[2]) or row[1] < 0 or row[2] <= row[1] for row in candidates):
            return dict(error='invalidInput')
        count = sum(length(row[0]) for row in candidates)
        seconds = 0.0
        for row in candidates:
            seconds += row[2] - row[1]
    else:
        if threshold <= 0:
            return dict(error='invalidInput')
        count = sum(length(row[1]) for row in source if row[4] == 'word')
        spans = []
        current = []
        for index, row in enumerate(source):
            pause = index > 0 and row[2] - source[index - 1][3] >= threshold
            if row[4] != 'word' or pause:
                if current:
                    spans.append(current[-1][3] - current[0][2])
                current = []
            if row[4] == 'word':
                current.append(row)
        if current:
            spans.append(current[-1][3] - current[0][2])
        seconds = 0.0
        for span in spans:
            seconds += span
    if count <= 0 or seconds <= 0:
        return dict(error='rateUnavailable')
    return dict(charactersPerSecond=count / seconds, source='candidates' if candidates else 'transcript', textLength=count, voicedSeconds=seconds)


def range_oracle(target, edge, bridge, rate, advisory=False):
    if not math.isfinite(target) or target <= 0 or not math.isfinite(rate) or rate <= 0 or bridge < 0:
        return dict(error='invalidInput')
    low = ((.92 * target - .03) - .06) * rate
    high = ((.97 * target - .03) - .06) * rate
    if not math.isfinite(low) or not math.isfinite(high):
        return dict(error='invalidInput')
    minimum = max(1, math.floor(low) - bridge)
    maximum = max(minimum, math.ceil(high) - bridge)
    if maximum > 2147483647:
        return dict(error='invalidInput')
    return dict(targetSeconds=target, edgePadSeconds=edge, bridgeLength=bridge, minChars=minimum, maxChars=maximum, advisory=advisory)


def window_oracle(value):
    start, end, left, right, incoming, outgoing = value['window']
    if end <= start or start < 0 or left == 'synthToSynth' or right == 'synthToSynth':
        return dict(error='invalidInput')
    for kind, silence in [(left, incoming), (right, outgoing)]:
        if (kind == 'hard' and silence is not None) or (kind != 'hard' and (silence is None or silence < 0)):
            return dict(error='invalidInput')
    edge = (max(0.0, incoming - .03) if left == 'none' else 0.0) + (max(0.0, outgoing - .06) if right == 'none' else 0.0)
    target = (end - start) - edge
    budget = range_oracle(target, edge, value['bridgeLength'], value['rate'])
    if 'error' in budget:
        return budget
    duration = estimate(value['text'], value['rate'])
    lower = (target - (.06 if left == 'hard' else .3)) - (.06 if right == 'hard' else .3)
    upper = (target + (max(0.0, incoming - .15) if left == 'gap' else 0.0)) + (max(0.0, outgoing - .15) if right == 'gap' else 0.0)
    verdict = 'fits' if lower <= duration <= upper else 'willChangeLength'
    prefix = '“' + value['newWords'] + '” · ' if value['multipleHunks'] else ''
    copy = prefix + f'about {fixed(duration)} s for a {fixed(target)} s gap: ' + ('fits' if verdict == 'fits' else 'will change length')
    return dict(budget=budget, meter=dict(estimateSeconds=duration, gapSeconds=target, lowerBoundSeconds=lower,
                                        upperBoundSeconds=upper, verdict=verdict, copy=copy))


def main():
    cases = []

    def add_window(name, duration=2.0, left='gap', right='gap', incoming=.4, outgoing=.4, rate=10.0,
                   bridge=0, text='abcdefghijklmnopqrst', multiple=False, start=0.0, boundary=None, new_words=None):
        value = dict(window=[start, start + duration, left, right, incoming, outgoing], rate=rate, bridgeLength=bridge,
                     text=text, newWords=text if new_words is None else new_words, multipleHunks=multiple)
        case = dict(name=name, kind='window', input=value, expected=window_oracle(value))
        if boundary:
            case['boundary'] = boundary
        cases.append(case)

    for left, right in itertools.product(['gap', 'hard', 'none'], repeat=2):
        add_window(f'seams-{left}-{right}', left=left, right=right, incoming=None if left == 'hard' else .4,
                   outgoing=None if right == 'hard' else .5, bridge=7, multiple=True)
    add_window('both-edge-trims-dominate', left='none', right='none', incoming=.02, outgoing=.04)
    add_window('both-edge-pads', duration=3, left='none', right='none', incoming=.43, outgoing=.66)
    add_window('no-borrow-below-slack', incoming=.1, outgoing=.149)
    add_window('no-borrow-at-slack', incoming=.15, outgoing=.15)
    for offset in [-.001, 0, .001]:
        add_window(f'lower-bound-{offset}', duration=1.6 + offset, rate=100, text='a' * 91)
        add_window(f'upper-bound-{offset}', duration=1 + offset, left='hard', right='hard', incoming=None, outgoing=None, rate=100, text='a' * 91)
        add_window(f'borrow-upper-bound-{offset}', duration=.5 + offset, incoming=.4, outgoing=.4, rate=100, text='a' * 91)
    add_window('short-window-clamps-to-one', duration=.01, bridge=99, rate=1, text='')
    add_window('bridge-nfc-length', bridge=6, text='õ ä ö ü 12')
    add_window('multi-hunk-quote-excludes-bridges', text='left new right', new_words='new', bridge=9, multiple=True)
    add_window('multi-hunk-quote-includes-merge-bridges', text='left new one fresh right', new_words='new one fresh',
               bridge=9, multiple=True)
    for aim, label in [(.92, 'floor'), (.97, 'ceil')]:
        denominator = (aim * 1.0 - .03) - .06
        center = 10.0 / denominator
        for offset in [-1, 0, 1]:
            rate = adjacent(center, offset)
            scaled = denominator * rate
            assert abs(scaled - 10) < 1e-9
            add_window(f'{label}-near-integer-{offset}', duration=1, rate=rate, boundary=dict(operation=label, scaled=scaled, integer=10))
    add_window('invalid-zero-rate', rate=0)
    add_window('invalid-negative-bridge', bridge=-1)
    add_window('invalid-hard-silence', left='hard', incoming=0)
    add_window('invalid-missing-gap-silence', incoming=None)
    add_window('invalid-synth-seam', left='synthToSynth')
    add_window('invalid-empty-window', duration=0)
    add_window('invalid-edge-consumes-window', duration=.1, left='none', incoming=1)
    add_window('invalid-range-overflow', rate=1e20)

    transcript = [['w0', 'Hello', .2, .6, 'word'], ['w1', 'õhtu!', .7, 1.2, 'word'],
                  ['w2', 'two', 2.2, 2.6, 'word'], ['e', '[laugh]', 2.6, 2.7, 'event'],
                  ['w3', 'three', 2.7, 3.2, 'word'], ['u', 'hmm', 3.2, 3.3, 'unlabeledSpeech'],
                  ['w4', 'four', 3.3, 3.8, 'word']]
    for name, source, threshold, candidates in [
        ('rate-transcript', transcript, 1.0, []), ('rate-no-detected-pause', transcript, 1.001, []),
        ('rate-exact-pause', [['a', 'one', 0, .5, 'word'], ['b', 'two', 1.5, 2, 'word']], 1.0, []),
        ('rate-candidates-override', transcript, 1.0, [['õhtu!', .1, .6], ['abc 12', .2, 1.2]]),
        ('rate-empty-candidates-fallback', transcript, 1.0, []), ('rate-no-text', [], 1.0, []),
        ('rate-only-events', [transcript[3]], 1.0, []), ('rate-zero-span', [['w', 'word', 0, 0, 'word']], 1.0, []),
        ('rate-invalid-candidate', transcript, 1.0, [['word', 1, 1]]),
        ('rate-candidate-no-letters', transcript, 1.0, [['...', 0, 1]]), ('rate-invalid-threshold', transcript, 0, [])]:
        value = dict(transcript=source, pauseThresholdSeconds=threshold, candidates=candidates)
        cases.append(dict(name=name, kind='rate', input=value, expected=rate_oracle(source, threshold, candidates)))
    for name, source in [('full-take-advisory', transcript), ('full-take-no-words', [transcript[3]])]:
        speech = [word for word in source if word[4] == 'word']
        expected = range_oracle(speech[-1][3] - speech[0][2], 0.0, 0, 10.0, True) if speech else dict(error='invalidInput')
        cases.append(dict(name=name, kind='fullTake', input=dict(transcript=source, rate=10.0), expected=expected))
    document = dict(schema='voxclip-voice-lab-length-budget/1', caseCount=len(cases), cases=cases)
    OUT.write_text(json.dumps(document, ensure_ascii=True, indent=2) + '\n', encoding='utf-8')
    print(f'{OUT.name}: {len(cases)} cases')


if __name__ == '__main__':
    main()
