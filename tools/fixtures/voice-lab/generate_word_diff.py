#!/usr/bin/env python3
"""Deterministic stdlib oracle for Voice Lab §8.2; no provider calls or platform code."""
import itertools
import json
import unicodedata
from decimal import Decimal, ROUND_HALF_UP
from pathlib import Path
from generate_length_budget import estimate, fixed

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / 'shared/fixtures/voice-lab/word-diff-cases.json'
SPACE = set(map(chr, [9, 10, 11, 12, 13, 32, 160, 5760, *range(8192, 8203), 8232, 8233, 8239, 8287, 12288, 65279]))
COPY = "That's a lot to re-voice. Re-record these sentences instead."


def split(text):
    return ''.join(' ' if scalar in SPACE else scalar for scalar in text).split(' ')


def tokens(text):
    return [part for part in split(text) if part]


def normalize(text):
    text = unicodedata.normalize('NFC', text)
    lowered = ''.join('i' if scalar == chr(304) else scalar.lower() for scalar in text)
    return ''.join(scalar for scalar in lowered if unicodedata.category(scalar)[0] in 'LN')


def words(text, step=1.0):
    return [[f'w{index}', token, index * step, index * step + step / 2, 'word'] for index, token in enumerate(tokens(text))]


def oracle(source, text, word_items):
    old = [(row, token) for row in source if row[4] == 'word' for token in tokens(row[1])]
    fresh = tokens(text)
    for side, count in [('source', len(old)), ('newText', len(fresh))]:
        if count > 2000:
            return dict(error='tokenLimit', side=side, count=count, limit=2000)
    before = [normalize(token) for _, token in old]
    after = [normalize(token) for token in fresh]
    table = [[0] * (len(after) + 1) for _ in range(len(before) + 1)]
    for source_index in reversed(range(len(before))):
        for new_index in reversed(range(len(after))):
            table[source_index][new_index] = (table[source_index + 1][new_index + 1] + 1 if before[source_index] == after[new_index]
                                              else max(table[source_index + 1][new_index], table[source_index][new_index + 1]))
    source_index = new_index = 0
    ops = []
    while source_index < len(old) or new_index < len(fresh):
        if source_index < len(old) and new_index < len(fresh) and before[source_index] == after[new_index]:
            ops.append(['equal', old[source_index][0][0], old[source_index][1], fresh[new_index]])
            source_index += 1
            new_index += 1
        elif source_index < len(old) and (new_index == len(fresh) or table[source_index + 1][new_index] >= table[source_index][new_index + 1]):
            ops.append(['delete', old[source_index][0][0], old[source_index][1], None])
            source_index += 1
        else:
            ops.append(['insert', None, None, fresh[new_index]])
            new_index += 1
    ordered = []
    for equal, run in itertools.groupby(ops, lambda op: op[0] == 'equal'):
        run = list(run)
        ordered.extend(run if equal else [op for op in run if op[0] == 'delete'] + [op for op in run if op[0] == 'insert'])
    if len(before) <= 8 and len(after) <= 8:
        def subsequences(values):
            return {tuple(values[index] for index in indices) for size in range(len(values) + 1)
                    for indices in itertools.combinations(range(len(values)), size)}
        longest = max(map(len, subsequences(before) & subsequences(after)))
        assert sum(op[0] == 'equal' for op in ordered) == longest
    regions = []
    source_index = 0
    for _, grouped in itertools.groupby(enumerate(ordered), lambda entry: 'textOnly' if entry[1][0] == 'equal' and entry[1][2] != entry[1][3]
                                         else 'unchanged' if entry[1][0] == 'equal' else 'replace'):
        run = list(grouped)
        start, end = run[0][0], run[-1][0] + 1
        source_start = source_index
        source_index += sum(op[1][0] != 'insert' for op in run)
        if all(op[1][0] == 'equal' and op[1][2] == op[1][3] for op in run):
            continue
        kind = 'textOnly' if run[0][1][0] == 'equal' else 'voice' if any(op[1][0] == 'insert' for op in run) else 'cut'
        regions.append(dict(start=start, end=end, sourceStart=source_start, sourceEnd=source_index, kind=kind, bridges=[]))

    spans = {}
    for index, op in enumerate(ordered):
        if op[1] is not None:
            spans.setdefault(op[1], []).append(index)
    widened = []
    for region in regions:
        affected = {op[1] for op in ordered[region['start']:region['end']] if op[1] is not None}
        position = region['sourceStart']
        if region['sourceStart'] == region['sourceEnd'] and 0 < position < len(old) and old[position - 1][0][0] == old[position][0][0]:
            affected.add(old[position][0][0])
        indices = [index for word_id in affected for index in spans[word_id]]
        if indices:
            region['start'] = min(region['start'], min(indices))
            region['end'] = max(region['end'], max(indices) + 1)
        if widened and region['start'] <= widened[-1]['end']:
            prior = widened.pop()
            region['start'] = min(prior['start'], region['start'])
            region['end'] = max(prior['end'], region['end'])
        region['sourceStart'] = sum(op[0] != 'insert' for op in ordered[:region['start']])
        region['sourceEnd'] = sum(op[0] != 'insert' for op in ordered[:region['end']])
        widened.append(region)
    for region in widened:
        run = ordered[region['start']:region['end']]
        before = [normalize(op[2]) for op in run if op[2] is not None]
        after = [normalize(op[3]) for op in run if op[3] is not None]
        region['kind'] = 'cut' if not after else 'textOnly' if before == after else 'voice'

    def anchor(index):
        return old[index][0][2] if index < len(old) else old[-1][0][3] if old else 0.0

    positions = {row[0]: index for index, row in enumerate(source)}

    def item_position(index):
        return positions[old[min(index, len(old) - 1)][0][0]] if old else 0

    merged = []
    for region in widened:
        prior = next((index for index in reversed(range(len(merged))) if merged[index]['kind'] == 'voice'), None)
        if region['kind'] == 'voice' and prior is not None:
            left = merged[prior]
            bridge = ordered[left['end']:region['start']]
            left_end = old[left['sourceEnd'] - 1][0][3] if left['sourceEnd'] > left['sourceStart'] else anchor(left['sourceStart'])
            right_start = old[region['sourceStart']][0][2] if region['sourceEnd'] > region['sourceStart'] else anchor(region['sourceStart'])
            left_position = item_position(left['sourceEnd'] - 1 if left['sourceStart'] < left['sourceEnd'] else left['sourceStart'])
            right_position = item_position(region['sourceStart'])
            barrier = any(row[4] != 'word' for row in source[left_position + 1:right_position])
            if not barrier and all(op[0] == 'equal' for op in bridge) and (len({op[1] for op in bridge}) <= 2 or right_start - left_end <= .35):
                region = dict(start=left['start'], end=region['end'], sourceStart=left['sourceStart'], sourceEnd=region['sourceEnd'],
                              kind='voice', bridges=left['bridges'] + [op[1] for op in bridge])
                del merged[prior:]
        merged.append(region)
    hunks = []
    for region in merged:
        run = ordered[region['start']:region['end']]
        source_ids = list(dict.fromkeys(op[1] for op in run if op[1] is not None))
        new_tokens = [op[3] for op in run if op[3] is not None]
        absorbed = [row[0] for row in source[positions[source_ids[0]] + 1:positions[source_ids[-1]]]
                    if row[4] != 'word'] if region['kind'] == 'voice' and source_ids else []
        corrected = []
        if region['kind'] == 'textOnly':
            offset = 0
            for word_id in source_ids:
                count = sum(op[1] == word_id for op in run)
                corrected.append(' '.join(new_tokens[offset:offset + count]))
                offset += count
        hunks.append(dict(kind=region['kind'], sourceWordIds=list(dict.fromkeys(op[1] for op in run if op[1] is not None)),
                          newTokens=new_tokens, correctedTexts=corrected, absorbedItemIds=absorbed,
                          bridgeWordIds=list(dict.fromkeys(region['bridges'])),
                          sourceStartIndex=region['sourceStart'], sourceEndIndex=region['sourceEnd'],
                          anchorSeconds=anchor(region['sourceStart']) if region['sourceStart'] == region['sourceEnd'] else None))
    count = sum(len(hunk['newTokens']) for hunk in hunks if hunk['kind'] == 'voice')
    disabled = count * 100 > 15 * word_items or count > 60
    return dict(ops=ordered, hunks=hunks, budget=dict(voiceTokenCount=count, wordItems=word_items,
                flag='reRecordInstead' if disabled else 'allowed', copy=COPY if disabled else None))


def main():
    cases = []

    def add(name, source, text, word_items=1000, events=0):
        source = words(source) if isinstance(source, str) else source
        cases.append(dict(name=name, source=source, newText=text, transcriptWordItems=word_items, transcriptEvents=events,
                          expected=oracle(source, text, word_items)))

    add('unchanged', 'one two three', 'one two three')
    add('empty', '', '')
    for index, (source, fresh) in enumerate([('a b', 'b a'), ('a b c', 'c b a'), ('a b a', 'b a b'),
                                            ('a a b b', 'b b a a'), ('a b c a', 'b a c b'), ('a b', 'x a y')]):
        add(f'lcs-alternatives-{index}', source, fresh)
    add('delete-before-insert', 'old old', 'new new')
    add('case-only', 'Hello WORLD', 'hello World')
    add('punctuation-only', 'Hello, world!', 'Hello world?')
    add('pure-cut', 'one two three', '')
    add('cut-middle', 'one two three', 'one three')
    for name, text in [('start', 'new one two'), ('middle', 'one new two'), ('end', 'one two new')]:
        add('insert-' + name, 'one two', text)
    add('insert-empty', '', 'new words 🎉!')
    add('estonian', 'Õhtu käes', 'õhtu käes!')
    add('estonian-change', 'õ ä ö ü', 'õ ä uus ü')
    add('nfc-surface', 'õhtu', 'o' + chr(771) + 'htu')
    add('js-whitespace', 'one two', chr(65279) + 'one' + chr(160) + 'two\n')
    add('not-js-whitespace', 'one two', 'one' + chr(133) + 'two')
    add('nonword-items-untouched', [['w0', 'one', 0, .2, 'word'], ['e', '[laugh]', .2, .4, 'event'],
                                   ['u', 'hmm', .4, .5, 'unlabeledSpeech'], ['w1', 'two', .5, .8, 'word']], 'one two', 2, 99)
    add('multi-token-word-item', [['w0', 'one two', 0, 1, 'word']], 'one new two')
    for name, text in [('partial-cut', 'hello'), ('partial-replace', 'hello there'),
                       ('insert-inside', 'hello new world'), ('partial-case', 'HELLO world')]:
        add('whole-item-' + name, [['w0', 'hello world', 0, 1, 'word']], text)
    add('whole-item-two-edits', [['w0', 'old keep stale', 0, 1, 'word']], 'new keep fresh')
    add('multi-token-bridge-item', [['w0', 'old', 0, .2, 'word'], ['w1', 'one two three', 1, 2, 'word'],
                                   ['w2', 'stale', 3, 3.2, 'word']], 'new one two three fresh')
    for kind in ['event', 'unlabeledSpeech']:
        add('barrier-insert-' + kind, [['red', 'red', 0, .2, 'word'], ['noise', '[laugh]', .3, .4, kind],
                                     ['blue', 'blue', .5, .7, 'word']], 'new red blue again')
        add('voice-absorbs-' + kind, [['red', 'red', 0, .2, 'word'], ['noise', '[laugh]', .3, .4, kind],
                                    ['blue', 'blue', .5, .7, 'word']], 'new fresh')
    add('barrier-one-equal-word', [['w0', 'old', 0, .2, 'word'], ['e', '[laugh]', .3, .4, 'event'],
                                 ['w1', 'keep', 1, 1.2, 'word'], ['w2', 'stale', 2, 2.2, 'word']], 'new keep fresh')
    add('barrier-point-one-second', [['w0', 'old', 0, 1, 'word'], ['e', '[laugh]', 1, 1.01, 'event'],
                                    ['w1', 'one', 1.01, 1.02, 'word'], ['w2', 'two', 1.03, 1.04, 'word'],
                                    ['w3', 'three', 1.05, 1.06, 'word'], ['w4', 'stale', 1.1, 1.3, 'word']], 'new one two three fresh')
    for name, text in [('cut', ''), ('textOnly', 'RED BLUE')]:
        add(name + '-preserves-event', [['red', 'red', 0, .2, 'word'], ['e', '[laugh]', .3, .4, 'event'],
                                       ['blue', 'blue', .5, .7, 'word']], text)
    add('replace-before-event', [['w0', 'old', 0, .2, 'word'], ['e', '[laugh]', .3, .4, 'event'],
                                 ['w1', 'blue', .5, .7, 'word']], 'new again blue')
    add('anchor-after-event', [['w0', 'red', 0, .2, 'word'], ['e', '[laugh]', .3, .4, 'event'],
                               ['w1', 'blue', .5, .7, 'word']], 'red new blue')
    add('voice-excludes-edge-nonwords', [['before', '[laugh]', 0, .1, 'event'], ['w0', 'old', .1, .2, 'word'],
                                        ['after', 'hmm', .2, .3, 'unlabeledSpeech']], 'new')
    add('merge-two-equals', 'old one two stale', 'new one two fresh')
    add('do-not-merge-three-slow', 'old one two three stale', 'new one two three fresh')
    for name, gap in [('minus-1ms', .349), ('exact', .35), ('plus-1ms', .351)]:
        source = [['w0', 'old', 0, .125, 'word']]
        source += [[f'w{index}', token, .125 + .05 * index, .125 + .05 * index + .02, 'word'] for index, token in enumerate(['one', 'two', 'three'], 1)]
        source += [['w4', 'stale', .125 + gap, .125 + gap + .1, 'word']]
        add('merge-time-' + name, source, 'new one two three fresh')
    add('bridge-surface-correction', 'old one two stale', 'new ONE two fresh')
    add('merge-transitive', 'old one stale two past', 'new one fresh two next')
    add('cut-prevents-merge', 'old keep delete keep stale', 'new keep keep fresh')
    add('insert-anchor-time', words('one two three four five', .05), 'new one two three fresh four five')
    add('insert-end-bridge', 'old one two', 'new one two fresh')
    for count, denominator in [(3, 20), (4, 20), (60, 400), (61, 1000), (60, 399), (0, 0), (1, 0)]:
        add(f'budget-{count}-of-{denominator}', '', ' '.join(['new'] * count), denominator, 100)
    add('budget-counts-bridges', 'old one two stale', 'new one two fresh', 20)
    add('summary-complete-window-bridges', 'old', 'new')
    cases[-1]['patchTexts'] = ['left new right']
    add('summary-missing-window-text', 'old', 'new')
    cases[-1]['patchTexts'] = [None]
    add('summary-one-window-text-missing', 'old one two three stale', 'new one two three fresh')
    cases[-1]['patchTexts'] = ['left new right', None]
    for side in ['source', 'newText']:
        add('token-limit-' + side, words(' '.join(['old'] * 2001)) if side == 'source' else 'old',
            ' '.join(['new'] * 2001) if side == 'newText' else 'new')
    add('token-limit-inclusive', ' '.join(['same'] * 2000), ' '.join(['same'] * 2000), 2000)
    for old in itertools.product(['a', 'b'], repeat=3):
        for fresh in itertools.product(['a', 'b'], repeat=3):
            add('ties-' + ''.join(old) + '-' + ''.join(fresh), ' '.join(old), ' '.join(fresh))
    for case in cases:
        expected = case['expected']
        if 'error' in expected:
            continue
        hunks = expected['hunks']
        voice = [hunk for hunk in hunks if hunk['kind'] == 'voice']
        patch_texts = case.setdefault('patchTexts', [' '.join(hunk['newTokens']) for hunk in voice])
        cut_count = len(set(word_id for hunk in hunks if hunk['kind'] == 'cut' for word_id in hunk['sourceWordIds']))
        seconds = 0.0
        units = 0
        for hunk, patch_text in zip(voice, patch_texts):
            text = patch_text if patch_text is not None else ' '.join(hunk['newTokens'])
            seconds += estimate(text, 10.0)
            units += len(text) * 3
        priced = bool(voice) and all(text is not None for text in patch_texts)
        usd = (Decimal(units) * Decimal('0.08') / Decimal(1000)).quantize(Decimal('0.0000000001'), rounding=ROUND_HALF_UP) if priced else None
        cuts = f'{cut_count} cut' + ('' if cut_count == 1 else 's')
        phrases = f'{len(voice)} re-voiced phrase' + ('' if len(voice) == 1 else 's')
        copy = f'{cuts} · {phrases} ({fixed(seconds)} s of AI voice)'
        if usd is not None:
            copy += ' · ' + ('< $0.01' if usd < Decimal('.01') else '≈ $' + str(usd.quantize(Decimal('.01'), rounding=ROUND_HALF_UP)))
        expected['summary'] = dict(cutCount=cut_count, revoicedPhrases=len(voice), estimateSeconds=seconds,
                                   costUnits=units if priced else None, usd=str(usd) if usd is not None else None, copy=copy)
    for case in cases:
        if case['name'] not in ['token-limit-source', 'token-limit-newText', 'token-limit-inclusive']:
            continue
        inclusive = case['name'] == 'token-limit-inclusive'
        case['sourceRepeat'] = dict(token='same' if inclusive else 'old', count=2000 if inclusive else 2001 if case['name'] == 'token-limit-source' else 1,
                                    idPrefix='w', timingStep=1.0)
        case['newTextRepeat'] = dict(token='same' if inclusive else 'new', count=2000 if inclusive else 2001 if case['name'] == 'token-limit-newText' else 1)
        del case['source'], case['newText']
        if inclusive:
            del case['expected']['ops']
            case['expected']['repeatedOps'] = dict(kind='equal', sourceToken='same', newToken='same', count=2000, idPrefix='w')
    document = dict(schema='voxclip-voice-lab-word-diff/1', caseCount=len(cases), cases=cases)
    OUT.write_text(json.dumps(document, ensure_ascii=True, indent=2) + '\n', encoding='utf-8')
    print(f'{OUT.name}: {len(cases)} cases')


if __name__ == '__main__':
    main()
