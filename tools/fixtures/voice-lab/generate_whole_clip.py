#!/usr/bin/env python3
"""Generate the shared whole-clip revoice rule vectors (ADR-R46, voice-lab section 8.14).

Writes shared/fixtures/voice-lab/whole-clip-revoice-cases.json (format voxclip-whole-clip-revoice/1), a file of its own: the
switch rule and its callout, Claude mode's choice within the cap, the script with cuts and voice changes applied, its parts and
the voice changes each part becomes, the fit and its "video matched" copy, the price from shared/catalog/voice-lab.json, and the
never-pay-twice ledger. An independent stdlib reference of the Mac WholeClipRevoice.swift; both Cores replay every case (Swift
WholeClipRevoiceReplayTests, C# WholeClipRevoiceReplayTests). Rounding is half away from zero on the exact binary64 value, as Swift
`.rounded()` and C# MidpointRounding.AwayFromZero; money is decimal. Byte-exact in check_drift.py. Run from anywhere.
"""
import json
import math
from decimal import Decimal, ROUND_HALF_UP
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / 'shared/fixtures/voice-lab/whole-clip-revoice-cases.json'
CATALOG = json.loads((ROOT / 'shared/catalog/voice-lab.json').read_text(encoding='utf-8'))

WORD_SHARE_PERCENT = 40
NO_FIT_PHRASES = 2
FIT_TOLERANCE = 0.08
MAXIMUM_REWORD_ROUNDS = 2
MAXIMUM_PART_SECONDS = 12.0
MAXIMUM_PART_CHARACTERS = 1000
MAXIMUM_CLIP_SECONDS = 300.0
# voice-lab 8.3: the narrowest gap a seam can sit in.
SEAM_MIN_GAP = 0.12
MINUS = chr(0x2212)
PLUS_MINUS = chr(0xB1)
ELLIPSIS = chr(0x2026)
LIPSYNC = {'lipsync2': ('fal-ai/sync-lipsync/v2:lipsync-2', 'fal-ai/sync-lipsync/v2', 'lipsync-2'),
           'sync3': ('fal-ai/sync-lipsync/v3', 'fal-ai/sync-lipsync/v3', None)}


def away(value):
    """Round half away from zero on the exact value of a double."""
    return int(Decimal(value).to_integral_value(rounding=ROUND_HALF_UP))


def canonical(value):
    text = format(value, 'f')
    if '.' in text:
        text = text.rstrip('0').rstrip('.')
    return text


# MARK: - The switch rule and Claude mode

def reason(spoken, revoiced, no_fit):
    if spoken > 0 and revoiced > 0 and revoiced * 100 >= spoken * WORD_SHARE_PERCENT:
        return {'kind': 'manyWords', 'revoiced': revoiced, 'spoken': spoken}
    if no_fit >= NO_FIT_PHRASES:
        return {'kind': 'phrasesCantFit', 'count': no_fit}
    return None


def callout(found):
    if found['kind'] == 'manyWords':
        return (f"These changes re-voice {found['revoiced']} words, a lot for a {found['spoken']}-word clip. "
                'Long stretches in your voice can sound stitched.')
    return (f"{found['count']} phrases can't fit their places in the video, so they would keep your original audio. "
            'Revoicing the whole clip fits the picture to the voice.')


def rule_cases():
    rows = [(100, 39, 0), (100, 40, 0), (5, 2, 0), (74, 29, 0), (74, 30, 0), (74, 58, 0), (0, 3, 0), (10, 0, 0),
            (100, 10, 1), (100, 10, 2), (100, 0, 3), (0, 0, 2), (3, 3, 5), (1, 1, 0), (1000, 399, 1), (1000, 400, 9)]
    cases = []
    for spoken, revoiced, no_fit in rows:
        found = reason(spoken, revoiced, no_fit)
        cases.append({'spokenWords': spoken, 'revoicedWords': revoiced, 'noFitPhrases': no_fit, 'reason': found,
                      'callout': callout(found) if found else None})
    return cases


def auto_choice(stitched, price, remaining):
    if not stitched or price is None or Decimal(price) <= 0:
        return {'kind': 'patch', 'price': None}
    if remaining is None or Decimal(price) > Decimal(remaining):
        return {'kind': 'patchAndOffer', 'price': price}
    return {'kind': 'revoice', 'price': price}


def auto_choice_cases():
    rows = [(True, '1.04', '2'), (True, '1.04', '1.04'), (True, '1.04', '1.03'), (True, '1.04', None), (True, None, '2'),
            (False, '1.04', '2'), (True, '0', '2'), (True, '0.0000000001', '0'), (True, '12.5', '12.50'), (True, '3', '0')]
    return [{'stitched': stitched, 'price': price, 'remaining': remaining, 'expected': auto_choice(stitched, price, remaining)}
            for stitched, price, remaining in rows]


# MARK: - Script, parts and hunks

def split_words(text):
    return text.split()


def assemble(words, cut_ids, hunks):
    spoken = [word for word in words if word['kind'] == 'word']
    by_id = {}
    for word in spoken:
        by_id.setdefault(word['id'], word)
    owner = {}
    for index, hunk in enumerate(hunks):
        for identity in hunk['sourceWordIds']:
            if identity in by_id and identity not in owner:
                owner[identity] = index
    units, emitted = [], set()
    for word in spoken:
        if word['id'] in owner:
            index = owner[word['id']]
            if index in emitted:
                continue
            emitted.add(index)
            sources = [identity for identity in hunks[index]['sourceWordIds'] if identity in by_id]
            units.append(([token for token in split_words(hunks[index]['newText']) if token], sources))
        elif word['id'] not in cut_ids:
            units.append((split_words(word['text']), [word['id']]))
    sentences = []
    state = {'tokens': [], 'sources': []}

    def close():
        tokens, sources = state['tokens'], state['sources']
        state['tokens'], state['sources'] = [], []
        if not tokens:
            return
        times = [by_id[identity] for identity in sources if identity in by_id]
        if not times:
            if sentences:
                last = sentences.pop()
                sentences.append({'tokens': last['tokens'] + tokens, 'sourceWordIds': last['sourceWordIds'],
                                  'start': last['start'], 'end': last['end']})
            return
        sentences.append({'tokens': tokens, 'sourceWordIds': sources, 'start': min(word['start'] for word in times),
                          'end': max(word['end'] for word in times)})

    for tokens, sources in units:
        state['sources'] = state['sources'] + [identity for identity in sources if identity not in state['sources']]
        for token in tokens:
            state['tokens'].append(token)
            if token and token[-1] in '.!?' + ELLIPSIS:
                close()
    close()
    return sentences or None


def text_of(sentence):
    return ' '.join(sentence['tokens'])


def parts_of(sentences):
    parts, group = [], []

    def flush():
        if not group:
            return
        tokens = [token for sentence in group for token in sentence['tokens']]
        parts.append({'text': ' '.join(tokens), 'words': len(tokens),
                      'sourceWordIds': [identity for sentence in group for identity in sentence['sourceWordIds']],
                      'start': group[0]['start'], 'end': group[-1]['end']})
        group.clear()

    for sentence in sentences:
        if group:
            seconds = sentence['end'] - group[0]['start']
            characters = len(' '.join([text_of(item) for item in group] + [text_of(sentence)]))
            if seconds > MAXIMUM_PART_SECONDS or characters > MAXIMUM_PART_CHARACTERS:
                flush()
        group.append(sentence)
    flush()
    return parts


def hunks_of(parts, words, cut_ids=(), cut_pause_ids=()):
    """The parts tile the clip (voice-lab 8.14 item 3): the first starts at the clip's first item, the last ends at its last.
    Between two parts, from the last kept source word of one to the first kept source word of the next, the items go to the
    side of the widest gap (the earliest on a tie; a cut pause counts as no gap); when that gap is narrower than SEAM_MIN_GAP
    the two parts are one change."""
    cuts, cut_pauses = set(cut_ids), set(cut_pause_ids)
    items = {}
    for offset, item in enumerate(words):
        items.setdefault(item['id'], offset)
    tiles = []
    for part in parts:
        positions = [items[identity] for identity in part['sourceWordIds'] if identity in items]
        if not positions:
            continue
        kept = [position for position in positions if words[position]['kind'] == 'word' and words[position]['id'] not in cuts]
        tiles.append({'sources': list(part['sourceWordIds']), 'tokens': split_words(part['text']), 'first': min(positions),
                      'last': max(positions), 'keptFirst': min(kept) if kept else min(positions),
                      'keptLast': max(kept) if kept else max(positions), 'lower': min(positions), 'upper': max(positions)})
    if not tiles:
        return []
    reached = []
    for item in words:
        reached.append(max(reached[-1] if reached else item['end'], item['end']))
    joined = [tiles[0]]
    for following in tiles[1:]:
        current = joined.pop()
        left, right = current['keptLast'], following['keptFirst']
        if current['last'] < following['first'] and right > left:
            split, widest = left, math.inf
            if right > left + 1:
                widest = -math.inf
                for j in range(left, right):
                    gap = 0.0 if 'pause-after-' + words[j]['id'] in cut_pauses else words[j + 1]['start'] - reached[j]
                    if gap > widest:
                        widest, split = gap, j
            if widest >= SEAM_MIN_GAP:
                current['upper'] = split
                joined.append(current)
                joined.append(dict(following, lower=split + 1))
                continue
        current['sources'] = current['sources'] + [identity for identity in following['sources'] if identity not in current['sources']]
        current['tokens'] = current['tokens'] + following['tokens']
        for key, pick in (('first', min), ('last', max), ('keptFirst', min), ('keptLast', max), ('upper', max)):
            current[key] = pick(current[key], following[key])
        joined.append(current)
    joined[0]['lower'] = 0
    joined[-1]['upper'] = len(words) - 1
    spoken_before = [0]
    for item in words:
        spoken_before.append(spoken_before[-1] + (1 if item['kind'] == 'word' else 0))
    result = []
    for tile in joined:
        lower, upper = tile['lower'], tile['upper']
        sources = [identity for identity in tile['sources'] if identity in items and lower <= items[identity] <= upper]
        positions = [items[identity] for identity in sources]
        first = min(positions) if positions else lower
        last = max(positions) if positions else upper
        leading = [item['id'] for item in words[lower:first]]
        trailing = [item['id'] for item in words[last + 1:upper + 1]]
        result.append({'sourceWordIds': leading + sources + trailing, 'newTokens': tile['tokens'],
                       'absorbedItemIds': [item['id'] for item in words[lower:upper + 1] if item['kind'] != 'word'],
                       'sourceStartIndex': spoken_before[lower], 'sourceEndIndex': spoken_before[upper + 1]})
    return result


def word(index, text, kind='word', prefix='w', step=0.5, length=0.4):
    start = index * step
    return {'id': f'{prefix}{index}', 'text': text, 'kind': kind, 'start': start, 'end': start + length}


def script_case(name, words, cut_ids=(), hunks=(), cut_pause_ids=()):
    hunks = [{'sourceWordIds': list(ids), 'newText': text} for ids, text in hunks]
    sentences = assemble(words, set(cut_ids), hunks)
    expected = None
    if sentences is not None:
        text = ' '.join(text_of(sentence) for sentence in sentences)
        parts = parts_of(sentences)
        expected = {'text': text, 'words': sum(len(sentence['tokens']) for sentence in sentences), 'characters': len(text),
                    'sentences': [{'text': text_of(sentence), 'sourceWordIds': sentence['sourceWordIds'], 'start': sentence['start'],
                                   'end': sentence['end']} for sentence in sentences],
                    'parts': parts, 'hunks': hunks_of(parts, words, cut_ids, cut_pause_ids)}
    return {'id': name, 'words': words, 'cutWordIds': list(cut_ids), 'cutPauseIds': list(cut_pause_ids), 'voiceHunks': hunks,
            'expected': expected}


def laid_out(script, prefix='t'):
    """Items for a tiling case: a plain token is a 1.3 s word touching the one before it (so two five-word sentences never
    share a 12 s part), '~um' a cut word, '[laughs]' an event, '|0.5' a 0.5 s silence. Returns the items and the cut IDs."""
    items, cuts, time = [], [], 0.0
    for token in script:
        if token.startswith('|'):
            time += float(token[1:])
            continue
        identity = f'{prefix}{len(items)}'
        kind = 'event' if token.startswith('[') else 'word'
        text = token[1:] if token.startswith('~') else token
        items.append({'id': identity, 'text': text, 'kind': kind, 'start': time, 'end': time + 1.3})
        if token.startswith('~'):
            cuts.append(identity)
        time += 1.3
    return items, cuts


def tiling_cases():
    def sentence(letter):
        return [f'{letter}{index}' for index in range(4)] + [f'{letter}-end.']

    a, b, c = sentence('a'), sentence('b'), sentence('c')
    rows = [
        ('tiles-a-filler-cut-before-a-sentence', a + ['|0.5', '~um'] + b + ['|0.5', '~uh'] + c, (), ()),
        ('tiles-a-filler-cut-after-a-sentence', a + ['~um', '|0.5'] + b + ['~so', '|0.5'] + c, (), ()),
        ('tiles-cut-words-at-the-clip-edges', ['~um', '~so'] + a + ['|0.5'] + b + ['~yeah'], (), ()),
        ('tiles-consecutive-cuts-split-at-the-widest-gap', a + ['~so', '~um', '|0.5', '~like', '~uh'] + b, (), ()),
        ('tiles-an-event-at-a-boundary', a + ['|0.5', '[laughs]'] + b, (), ()),
        ('joins-parts-at-a-cut-run-with-no-silence', a + ['~um', '~uh'] + b + ['|0.5'] + c, (), ()),
        ('joins-parts-at-a-tightened-pause-beside-a-filler', a + ['|1.2', '~um'] + b, (), ['pause-after-t4']),
        ('keeps-the-split-at-a-tightened-pause-between-sentences', a + ['|1.2'] + b, (), ['pause-after-t4']),
        ('keeps-the-split-of-touching-sentences', a + b, (), ()),
        ('tiles-a-part-made-only-of-new-words', a + ['|0.5', '~um'] + b, [([f't{index}' for index in range(6, 11)], 'Then it all changed.')], ()),
        ('gives-a-rewrites-trailing-cut-filler-to-the-next-part', a + ['|0.5', '~um'] + b,
         [([f't{index}' for index in range(0, 6)], 'A whole new start.')], ()),
    ]
    cases = []
    for name, script, hunks, pauses in rows:
        items, cuts = laid_out(script)
        cases.append(script_case(name, items, cuts, hunks, pauses))
    return cases


def script_cases():
    mockup = [word(i, text) for i, text in enumerate(['So', 'we', 'drove', 'north.', 'It', 'was', 'um', 'cold.', 'Then', 'we', 'stopped.'])]
    mockup.append(word(11, '[music]', kind='event'))
    long = [word(i, 'end.' if i % 4 == 3 else 'word', prefix='l', length=0.45) for i in range(48)]
    wide = [word(i, ('x' * 60 + '.') if i % 2 else 'y' * 60, prefix='c', step=0.1, length=0.05) for i in range(40)]
    paused = [word(0, 'Hi'), word(1, '[laughs]', kind='event'), word(2, 'there.'), word(3, '[pause]', kind='unlabeledSpeech'),
              word(4, 'Bye'), word(5, 'now!')]
    accents = [word(0, 'Café'), word(1, 'naïve'), word(2, 'déjà'), word(3, 'vu' + ELLIPSIS), word(4, 'Olé?')]
    # Each sentence is 451 scalars but 902 UTF-16 units: one part by scalars, two if UTF-16 units were counted.
    smiles = [word(i, chr(0x1F642) * 450 + '.', prefix='e') for i in range(2)]
    return [
        script_case('edits-and-a-rewrite-in-order', mockup, ['w6'], [(['w8', 'w9', 'w10'], 'Then we finally stopped.')]),
        script_case('plain-clip', mockup),
        script_case('nothing-said', [word(0, '[music]', kind='event')]),
        script_case('a-rewrite-spanning-sentences-keeps-its-place', mockup, (), [(['w3', 'w4', 'w5'], 'east, and it got')]),
        script_case('parts-within-their-seconds', long),
        script_case('parts-within-their-characters', wide),
        script_case('a-rewrite-with-its-own-full-stop-joins-the-sentence-before', mockup, (),
                    [(['w0', 'w1', 'w2', 'w3'], 'Hello. We headed out'), (['w4', 'w5', 'w6', 'w7'], 'today.')]),
        script_case('a-new-sentence-with-no-source-left-joins-the-one-before', mockup, (),
                    [(['w8', 'w9', 'w10'], 'We stopped. Done. Finally.')]),
        script_case('an-insertion-is-left-out', mockup, (), [([], 'Inserted words.'), (['w0'], 'Well')]),
        script_case('a-rewrite-over-a-cut-word-still-says-it', mockup, ['w6', 'w7'], [(['w6', 'w7'], 'freezing.')]),
        script_case('the-first-change-owns-a-shared-word', mockup, (), [(['w1', 'w2'], 'they walked'), (['w2', 'w3'], 'flew south.')]),
        script_case('unknown-source-words-are-ignored', mockup, (), [(['w0', 'missing'], 'Now')]),
        script_case('a-removed-phrase-says-nothing', mockup, (), [(['w4', 'w5', 'w6', 'w7'], '')]),
        script_case('events-between-words-are-absorbed', paused),
        script_case('characters-count-scalars', accents),
        script_case('parts-count-scalars-not-utf16-units', smiles),
        script_case('everything-cut', mockup, [f'w{i}' for i in range(11)]),
    ] + tiling_cases()


# MARK: - Fit

def fit(voice, video, words, rounds):
    if not (math.isfinite(voice) and math.isfinite(video)) or voice <= 0 or video <= 0:
        return {'kind': 'cannotFit'}
    factor = voice / video
    if abs(factor - 1) <= FIT_TOLERANCE + 1e-9:
        return {'kind': 'matched', 'factor': factor, 'copy': matched_copy(factor)}
    if rounds >= MAXIMUM_REWORD_ROUNDS or words <= 0:
        return {'kind': 'cannotFit'}
    return {'kind': 'reword', 'shorter': factor > 1, 'targetWords': max(1, away(words / factor))}


def matched_copy(factor):
    percent = (factor - 1) * 100
    rounded = away(percent * 10) / 10
    sign = MINUS if rounded < 0 else '+' if rounded > 0 else PLUS_MINUS
    return f'video matched ({sign}{"%.1f" % abs(rounded)}%)'


def fit_cases():
    rows = [(30.6, 31, 74, 0), (108, 100, 74, 0), (92, 100, 74, 0), (108.1, 100, 100, 0), (80, 100, 80, 1), (120, 100, 100, 2),
            (0, 100, 10, 0), (100, 0, 10, 0), (-1, 100, 10, 0), (102, 100, 50, 0), (100, 100, 50, 0), (99.96, 100, 50, 0),
            (2, 1, 5, 0), (1, 2, 5, 1), (91.9, 100, 0, 0), (200, 1, 3, 0), (100.05, 100, 9, 0), (99.95, 100, 9, 0),
            (106.25, 100, 9, 0), (93.75, 100, 9, 0)]
    return [{'voiceSeconds': voice, 'videoSeconds': video, 'words': words, 'round': rounds, 'expected': fit(voice, video, words, rounds)}
            for voice, video, words, rounds in rows]


# MARK: - Price

def entry(provider, operation, endpoint, model):
    rows = [row for row in CATALOG['entries'] if row['provider'] == provider and row['operation'] == operation
            and row.get('endpoint') == endpoint and row.get('model') in (None, model)]
    assert len(rows) <= 1
    return rows[0] if rows else None


def estimate(provider, operation, endpoint, model, units):
    row = entry(provider, operation, endpoint, model)
    if row is None:
        return None
    amount = Decimal(repr(float(units)))
    parameters = {name: Decimal(value) for name, value in row['usdParameters'].items()}
    formula = row['formula']
    if formula == 'perThousandCharacters':
        value = amount * parameters['perThousandCharacters'] / 1000
    elif formula == 'perSecond':
        value = amount * parameters['perSecond']
    elif formula == 'perMinute':
        value = amount * parameters['perMinute'] / 60
    else:
        raise AssertionError(formula)
    return value.quantize(Decimal('1e-10'), rounding=ROUND_HALF_UP)


def price_cases():
    rows = [(400, 'eleven_v4', 31, 'lipsync2'), (400, 'eleven_v4', 31, 'sync3'), (400, 'no-such-model', 31, 'lipsync2'),
            (1, 'eleven_v4', 0.5, 'lipsync2'), (12345, 'eleven_v4', 299.97, 'sync3'), (0, 'eleven_v4', 12, 'lipsync2'),
            (999, 'eleven_v4_turbo', 45.5, 'lipsync2'), (2000, 'eleven_v4', 300, 'sync3')]
    cases = []
    for characters, model, seconds, lipsync in rows:
        raw, endpoint, lipsync_model = LIPSYNC[lipsync]
        voice = estimate('elevenlabs', 'textToSpeech', None, model, characters)
        sync = estimate('fal', 'lipsync', endpoint, lipsync_model, seconds)
        total = voice + sync if voice is not None and sync is not None else None
        cases.append({'characters': characters, 'ttsModel': model, 'videoSeconds': seconds, 'lipsync': raw,
                      'expected': {'voiceUsd': None if voice is None else canonical(voice),
                                   'lipsyncUsd': None if sync is None else canonical(sync),
                                   'usd': None if total is None else canonical(total)}})
    return cases


# MARK: - Ledger

def ledger_cases():
    voice = {'script': 'So we drove north.', 'recordId': 'r1', 'model': 'eleven_v4'}
    other = {'script': 'Shorter.', 'recordId': 'r1', 'model': 'eleven_v4'}
    another_voice = {'script': 'So we drove north.', 'recordId': 'r2', 'model': 'eleven_v4'}
    standard = {'voice': voice, 'retime': 0.99, 'model': LIPSYNC['lipsync2'][0]}
    upgrade = {'voice': voice, 'retime': 0.99, 'model': LIPSYNC['sync3'][0]}
    retimed = {'voice': voice, 'retime': 1.01, 'model': LIPSYNC['lipsync2'][0]}
    paid_voices, paid_lipsyncs = {}, {}

    def key(value):
        return json.dumps(value, sort_keys=True)

    steps = []

    def remaining(voice_key, voice_usd, lipsync_key, lipsync_usd):
        due = Decimal(0) if key(voice_key) in paid_voices else Decimal(voice_usd)
        lipsync_paid = lipsync_key is not None and key(lipsync_key) in paid_lipsyncs
        value = due + (Decimal(0) if lipsync_paid else Decimal(lipsync_usd))
        steps.append({'remaining': {'voice': voice_key, 'voiceUsd': voice_usd, 'lipsync': lipsync_key, 'lipsyncUsd': lipsync_usd},
                      'expected': canonical(value)})

    def record_voice(voice_key, usd):
        paid_voices[key(voice_key)] = Decimal(usd)
        steps.append({'recordVoice': voice_key, 'usd': usd})

    def record_lipsync(lipsync_key, usd):
        paid_lipsyncs[key(lipsync_key)] = Decimal(usd)
        steps.append({'recordLipsync': lipsync_key, 'usd': usd})

    def paid(voice_key=None, lipsync_key=None):
        if voice_key is not None:
            steps.append({'paidVoice': voice_key, 'expected': key(voice_key) in paid_voices})
        else:
            steps.append({'paidLipsync': lipsync_key, 'expected': key(lipsync_key) in paid_lipsyncs})

    def total():
        steps.append({'total': canonical(sum(paid_voices.values(), Decimal(0)) + sum(paid_lipsyncs.values(), Decimal(0)))})

    total()
    remaining(voice, '1', standard, '2')
    record_voice(voice, '1')
    paid(voice_key=voice)
    paid(voice_key=another_voice)
    remaining(voice, '1', standard, '2')
    record_lipsync(standard, '2')
    paid(lipsync_key=standard)
    paid(lipsync_key=upgrade)
    remaining(voice, '1', standard, '2')
    remaining(voice, '1', upgrade, '4.1333333333')
    remaining(voice, '1', retimed, '2')
    remaining(other, '1', None, '0')
    remaining(voice, '1', None, '3')
    record_voice(voice, '1.25')
    record_lipsync(upgrade, '4.1333333333')
    remaining(voice, '1', upgrade, '4.1333333333')
    total()
    return [{'id': 'a-paid-step-is-never-paid-again', 'steps': steps}]


def main():
    document = {
        'format': 'voxclip-whole-clip-revoice/1',
        'constants': {'wordSharePercent': WORD_SHARE_PERCENT, 'noFitPhrases': NO_FIT_PHRASES, 'fitTolerance': FIT_TOLERANCE,
                      'maximumRewordRounds': MAXIMUM_REWORD_ROUNDS, 'maximumPartSeconds': MAXIMUM_PART_SECONDS,
                      'maximumPartCharacters': MAXIMUM_PART_CHARACTERS, 'maximumClipSeconds': MAXIMUM_CLIP_SECONDS,
                      'standardLipsync': LIPSYNC['lipsync2'][0],
                      'lipsyncModels': [{'rawValue': raw, 'endpoint': endpoint, 'model': model, 'name': name}
                                        for (raw, endpoint, model), name in zip(LIPSYNC.values(), ['lipsync-2', 'sync-3'])]},
        'rule': rule_cases(),
        'autoChoice': auto_choice_cases(),
        'script': script_cases(),
        'fit': fit_cases(),
        'price': price_cases(),
        'ledger': ledger_cases(),
    }
    OUT.write_text(json.dumps(document, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')


if __name__ == '__main__':
    main()
