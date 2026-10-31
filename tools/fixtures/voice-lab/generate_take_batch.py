#!/usr/bin/env python3
"""Write take-batch-cases.json: one approval for every voice window's bounded take set in a Rewrite (voice-lab.md
section 8.6 with several hunks, section 2.6 bounded runs and section 3.1 presentation and monthly cap; design delta
section 6 T1).

An independent standard-library reference of the rules in shared/fixtures/voice-lab/take-batch-cases-README.md:

- A batch holds 1 to MAXIMUM_WINDOWS windows. They share one voice record, language, model and source, and are in
  source order with a gap between them (placeAll merges windows that touch).
- Its estimate is the sum of every take's TTS and Scribe QA quote. `usd` is unknown when any quote's is, and so are
  `credits`. One presentation covers the whole batch, with the monthly cap.
- The windows run in source order. A window that completes or stops early discards its own unsent quotes and hands over
  to the next. A fatal, cancelled or invalidated window ends the batch and discards every later window. Only requests
  the provider accepted count as sent, which is exactly what the spend ledger records.

Per-take quotes use the catalog list prices: TTS bills the window's characters on eleven_v3, and every take's QA quote is
the bounded 290 s of scribe_v2. Two runs give identical bytes."""
import decimal
import json
from decimal import Decimal, ROUND_HALF_UP
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
CATALOG = json.loads((ROOT / 'shared/catalog/voice-lab.json').read_text(encoding='utf-8'))
OUT = ROOT / 'shared/fixtures/voice-lab/take-batch-cases.json'

decimal.setcontext(decimal.Context(prec=80, rounding=ROUND_HALF_UP, traps=[decimal.InvalidOperation, decimal.DivisionByZero]))
ALMOST_EQUAL = chr(0x2248)
PROVIDER_NAME = 'ElevenLabs'
CANDIDATES = 3
# ElevenLabsVoiceLab holds at most 32 outstanding quotes (section 2.6), and a window holds 2 * CANDIDATES of them.
MAXIMUM_WINDOWS = 32 // (2 * CANDIDATES)
SAMPLE_RATE = 24_000
QA_SECONDS = 290
TTS_MODEL, QA_MODEL, UNLISTED_MODEL = 'eleven_v3', 'scribe_v2', 'eleven_unlisted'
USD_QUANTUM = Decimal('1e-10')
CENT = Decimal('0.01')
BASIS, UNKNOWN = 'bounded-tts-and-scribe', 'unknown'
DEFAULTS = {'recordId': 'voice-record', 'language': 'en', 'modelId': TTS_MODEL, 'contentKey': 'source-content'}


def entry(operation, model):
    for row in CATALOG['entries']:
        if row['provider'] == 'elevenlabs' and row['operation'] == operation and row.get('model') == model:
            return row
    return None


def canonical(value):
    text = format(value, 'f')
    return text.rstrip('0').rstrip('.') if '.' in text else text


def usd(value):
    return value.quantize(USD_QUANTUM, rounding=ROUND_HALF_UP)


def tts_quote(characters, model):
    row = entry('textToSpeech', model)
    if row is None:
        return {'usd': None, 'credits': None}
    credits = row.get('creditsParameters', {}).get('perCharacter')
    return {'usd': canonical(usd(Decimal(characters) * Decimal(row['usdParameters']['perThousandCharacters']) / 1000)),
            'credits': None if credits is None else int(Decimal(characters) * Decimal(credits))}


def qa_quote():
    row = entry('speechToText', QA_MODEL)
    return {'usd': canonical(usd(Decimal(QA_SECONDS) * Decimal(row['usdParameters']['perHour']) / 3600)), 'credits': None}


def window(start, end, characters, **overrides):
    """A window whose CANDIDATES takes each hold the same TTS quote (the same text) and the same bounded QA quote."""
    tts = tts_quote(characters, overrides.get('modelId', TTS_MODEL))
    return {**DEFAULTS, **overrides, 'startSample': start, 'endSample': end, 'characters': characters,
            'takes': CANDIDATES, 'synthesis': tts, 'qa': qa_quote()}


def requests(windows):
    """Every request in run order: (window, take, part, quote)."""
    return [(w, t, part, row[part]) for w, row in enumerate(windows) for t in range(row['takes'])
            for part in ('synthesis', 'qa')]


def total(quotes):
    """The summed estimate of a set of (window, take, part, quote) requests; units are the takes it touches."""
    known = all(quote['usd'] is not None for *_, quote in quotes)
    credits_known = all(quote['credits'] is not None for *_, quote in quotes)
    return {'units': len({(w, t) for w, t, _, _ in quotes}),
            'usd': canonical(sum((Decimal(quote['usd']) for *_, quote in quotes), Decimal(0))) if known else None,
            'credits': sum(quote['credits'] for *_, quote in quotes) if credits_known else None,
            'basis': BASIS if known else UNKNOWN}


def valid(windows):
    if not 1 <= len(windows) <= MAXIMUM_WINDOWS:
        return False
    first = windows[0]
    if any(row[key] != first[key] for row in windows for key in DEFAULTS):
        return False
    return all(earlier['endSample'] < later['startSample'] for earlier, later in zip(windows, windows[1:]))


def amount(value):
    if value < CENT:
        return '< $0.01'
    exponent = 0
    while value >= Decimal(10) ** (exponent + 1):
        exponent += 1
    while value < Decimal(10) ** exponent:
        exponent -= 1
    quantum = Decimal(10) ** max(exponent - 1, -2)
    rounded = (value / quantum).quantize(Decimal(1), rounding=ROUND_HALF_UP) * quantum
    if rounded >= 10:
        return f'${int(rounded):,}'
    cents = int((rounded * 100).to_integral_value())
    return f'${cents // 100}.{cents % 100:02d}'


def cap_text(cap):
    if cap == cap.to_integral_value():
        return f'{int(cap):,}'
    cents = int((cap * 100).quantize(Decimal(1), rounding=ROUND_HALF_UP))
    return f'{cents // 100:,}.{cents % 100:02d}'


def kind(value, cap):
    """voice-lab section 3.1 for a take batch: never lip sync, and never free (every take has a QA quote)."""
    if value is None:
        return {'kind': 'confirm', 'text': f"VoxClip can't tell what this costs. Check {PROVIDER_NAME}'s pricing."}
    crossing = cap is not None and Decimal(cap['spent']) <= Decimal(cap['limit']) < Decimal(cap['spent']) + value
    if value < Decimal('0.5') and not crossing:
        text = amount(value)
        return {'kind': 'inline', 'text': text if text.startswith('<') else ALMOST_EQUAL + ' ' + text}
    text = (f'This will cost less than $0.01 on your {PROVIDER_NAME} account.' if value < CENT
            else f'This will cost about {amount(value)} on your {PROVIDER_NAME} account.')
    if crossing:
        text += f" This takes you past your ${cap_text(Decimal(cap['limit']))} limit for {PROVIDER_NAME} this month."
    return {'kind': 'confirm', 'text': text}


def replay(windows, steps):
    """The run, step by step: which requests are sent, discarded or still to come after each window ends."""
    every = requests(windows)
    sent, discarded, next_window = set(), set(), 0
    out = []
    for step in steps:
        index, end, parts = step['window'], step['end'], step['sent']
        if index != next_window or len(parts) > windows[index]['takes']:
            out.append({**step, 'expected': {'error': 'invalidInput'}})
            continue
        accepted = {(index, take, part) for take, which in enumerate(parts)
                    for part in {'both': ('synthesis', 'qa'), 'synthesis': ('synthesis',), 'none': ()}[which]}
        own = {(w, t, part) for w, t, part, _ in every if w == index}
        sent |= accepted
        discarded |= own - accepted
        if end in ('completed', 'earlyStop'):
            next_window = index + 1 if index + 1 < len(windows) else None
        else:
            discarded |= {(w, t, part) for w, t, part, _ in every if w > index}
            next_window = None
        pending = [row for row in every if row[:3] not in sent and row[:3] not in discarded]
        out.append({**step, 'expected': {
            'next': next_window,
            'sent': total([row for row in every if row[:3] in sent]),
            'remaining': total(pending),
            'discarded': [list(row[:3]) for row in every if row[:3] in discarded]}})
    return out


def case(identifier, description, windows, cap=None, run=None):
    row = {'id': identifier, 'description': description, 'windows': windows, 'cap': cap}
    if not valid(windows):
        row['expected'] = {'error': 'invalidInput'}
        return row
    estimate = total(requests(windows))
    row['expected'] = {'estimate': estimate,
                       'kind': kind(None if estimate['usd'] is None else Decimal(estimate['usd']), cap)}
    if run is not None:
        row['run'] = replay(windows, run)
    return row


def three(characters=(40, 25, 60)):
    return [window(48_000, 96_000, characters[0]), window(120_000, 168_000, characters[1]),
            window(192_000, 240_000, characters[2])]


INLINE_TOTAL = Decimal(total(requests(three()))['usd'])


def steps(*rows):
    return [{'window': w, 'end': end, 'sent': sent} for w, end, sent in rows]


cases = [
    case('three-windows-inline', 'Three phrases of 40, 25 and 60 characters: nine takes under $0.50, inline.', three()),
    case('three-windows-just-below-limit', 'Nine takes of 470 characters: $0.4979, inline, shown rounded as $0.50.',
         three((470, 470, 470))),
    case('three-windows-crossing-limit', 'Nine takes of 480 characters: $0.5051 confirms once for the whole batch.',
         three((480, 480, 480))),
    case('three-windows-crossing-cap', 'The inline batch takes the month from $4.90 past a $5 cap: it confirms with the cap '
         'sentence.', three(), cap={'limit': '5', 'spent': '4.9'}),
    case('three-windows-reaching-cap', 'The inline batch takes the month exactly to the $5 cap: that does not cross.',
         three(), cap={'limit': '5', 'spent': canonical(Decimal(5) - INLINE_TOTAL)}),
    case('three-windows-already-past-cap', 'The month is already past the cap before the batch: nothing crosses.',
         three(), cap={'limit': '5', 'spent': '5.5'}),
    case('three-windows-crossing-limit-and-cap', 'Over $0.50 and crossing a $12.50 cap: one confirmation with both.',
         three((480, 480, 480)), cap={'limit': '12.5', 'spent': '12.25'}),
    case('price-unknown', 'A model without a list price makes the batch\'s price unknown: it confirms.',
         [window(48_000, 96_000, 40, modelId=UNLISTED_MODEL), window(120_000, 168_000, 25, modelId=UNLISTED_MODEL),
          window(192_000, 240_000, 60, modelId=UNLISTED_MODEL)]),
    case('single-window-try-another', 'Try Another on one phrase is a new batch of one window.',
         [window(120_000, 168_000, 40)]),
    case('five-windows', 'The most windows one batch holds.',
         [window(48_000 * (2 * index + 1), 48_000 * (2 * index + 2), 20) for index in range(5)]),
    case('six-windows', 'A sixth window would evict the first window\'s quotes from the client: refused.',
         [window(48_000 * (2 * index + 1), 48_000 * (2 * index + 2), 20) for index in range(6)]),
    case('overlapping-windows', 'Windows that overlap: refused.',
         [window(48_000, 96_000, 40), window(90_000, 120_000, 25)]),
    case('touching-windows', 'Windows that touch, which placeAll would have merged: refused.',
         [window(48_000, 96_000, 40), window(96_000, 120_000, 25)]),
    case('windows-out-of-order', 'Windows not in source order: refused.',
         [window(120_000, 168_000, 40), window(48_000, 96_000, 25)]),
    case('mixed-voice-record', 'Windows for two voice records: refused.',
         [window(48_000, 96_000, 40), window(120_000, 168_000, 25, recordId='other-record')]),
    case('mixed-language', 'Windows in two languages: refused.',
         [window(48_000, 96_000, 40), window(120_000, 168_000, 25, language='et')]),
    case('mixed-model', 'Windows on two models: refused.',
         [window(48_000, 96_000, 40), window(120_000, 168_000, 25, modelId='eleven_multilingual_v2')]),
    case('mixed-source', 'Windows over two sources: refused.',
         [window(48_000, 96_000, 40), window(120_000, 168_000, 25, contentKey='other-content')]),
    case('early-stop-on-window-2', 'Window 1 runs all three takes; window 2 stops early after its first take and '
         'discards takes 2 and 3; window 3 runs on, its first take failing the speaker check before QA.', three(),
         run=steps((0, 'completed', ['both', 'both', 'both']), (1, 'earlyStop', ['both']),
                   (2, 'completed', ['synthesis', 'both', 'both']))),
    case('provider-refusal-is-not-sent', 'A take the provider refused (a 500) is not sent and not recorded; the next '
         'take fits and stops the window early.', three(),
         run=steps((0, 'earlyStop', ['none', 'both']), (1, 'earlyStop', ['both']), (2, 'earlyStop', ['both']))),
    case('fatal-on-window-1', 'A fatal end (such as a 401) on window 1 ends the batch: windows 2 and 3 are discarded '
         'unsent, and nothing can finish after it.', three(),
         run=steps((0, 'fatal', ['synthesis']), (1, 'earlyStop', ['both']))),
    case('cancelled-on-window-2', 'Stop during window 2 keeps what was sent and discards the rest of the batch.', three(),
         run=steps((0, 'earlyStop', ['both']), (1, 'cancelled', ['synthesis']))),
    case('invalidated-before-window-3', 'An edit to the scope invalidates window 3 before it sends anything.', three(),
         run=steps((0, 'earlyStop', ['both']), (1, 'earlyStop', ['both']), (2, 'invalidated', []))),
    case('windows-finish-in-order', 'Window 2 cannot finish before window 1, and a window cannot report more takes than '
         'it has.', three(),
         run=steps((1, 'earlyStop', ['both']), (0, 'completed', ['both', 'both', 'both', 'both']),
                   (0, 'earlyStop', ['both']))),
]

fixture = {
    'schema': 'voxclip-take-batch-cases/1',
    'source': 'doc/spec/voice-lab.md sections 2.6, 3.1 and 8.6 (several hunks, design delta section 13.2); '
              'design delta section 6 T1',
    'description': 'Synthetic take batches: the summed TTS and Scribe QA estimate, its one presentation with the monthly '
                   'cap, the refusals, and the window-by-window run. Generated by '
                   'tools/fixtures/voice-lab/generate_take_batch.py; see take-batch-cases-README.md.',
    'providerName': PROVIDER_NAME,
    'candidates': CANDIDATES,
    'maximumWindows': MAXIMUM_WINDOWS,
    'sampleRate': SAMPLE_RATE,
    'cases': cases,
}


def dumps(value, indent=0):
    """Two-space JSON with every array of scalars on one line."""
    pad = ' ' * (indent + 2)
    if isinstance(value, dict) and value:
        rows = [f'{pad}{json.dumps(key)}: {dumps(item, indent + 2)}' for key, item in value.items()]
        return '{\n' + ',\n'.join(rows) + '\n' + ' ' * indent + '}'
    if isinstance(value, list) and value and any(isinstance(item, (dict, list)) for item in value):
        return '[\n' + ',\n'.join(pad + dumps(item, indent + 2) for item in value) + '\n' + ' ' * indent + ']'
    return json.dumps(value, ensure_ascii=False)


OUT.write_text(dumps(fixture) + '\n', encoding='utf-8')
