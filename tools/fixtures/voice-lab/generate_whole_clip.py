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


def hunks_of(parts, words):
    spoken = [word for word in words if word['kind'] == 'word']
    index, items = {}, {}
    for offset, word in enumerate(spoken):
        index.setdefault(word['id'], offset)
    for offset, word in enumerate(words):
        items.setdefault(word['id'], offset)
    result = []
    for part in parts:
        positions = [index[identity] for identity in part['sourceWordIds'] if identity in index]
        if not positions:
            continue
        item_positions = [items[identity] for identity in part['sourceWordIds'] if identity in items]
        absorbed = []
        if item_positions and max(item_positions) > min(item_positions):
            absorbed = [word['id'] for word in words[min(item_positions) + 1:max(item_positions)] if word['kind'] != 'word']
        result.append({'sourceWordIds': part['sourceWordIds'], 'newTokens': split_words(part['text']), 'absorbedItemIds': absorbed,
                       'sourceStartIndex': min(positions), 'sourceEndIndex': max(positions) + 1})
    return result


def word(index, text, kind='word', prefix='w', step=0.5, length=0.4):
    start = index * step
    return {'id': f'{prefix}{index}', 'text': text, 'kind': kind, 'start': start, 'end': start + length}


def script_case(name, words, cut_ids=(), hunks=()):
    hunks = [{'sourceWordIds': list(ids), 'newText': text} for ids, text in hunks]
    sentences = assemble(words, set(cut_ids), hunks)
    expected = None
    if sentences is not None:
        text = ' '.join(text_of(sentence) for sentence in sentences)
        parts = parts_of(sentences)
        expected = {'text': text, 'words': sum(len(sentence['tokens']) for sentence in sentences), 'characters': len(text),
                    'sentences': [{'text': text_of(sentence), 'sourceWordIds': sentence['sourceWordIds'], 'start': sentence['start'],
                                   'end': sentence['end']} for sentence in sentences],
                    'parts': parts, 'hunks': hunks_of(parts, words)}
    return {'id': name, 'words': words, 'cutWordIds': list(cut_ids), 'voiceHunks': hunks, 'expected': expected}


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
    ]


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
