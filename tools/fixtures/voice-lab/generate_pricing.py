#!/usr/bin/env python3
"""Write the Voice Lab pricing, cost-presentation and spend-ledger cases (voice-lab §3.1 and §3.2).

An independent stdlib reference of the rules in shared/fixtures/voice-lab/pricing-cases-README.md. It reads
shared/catalog/voice-lab.json, computes every expected value with the decimal module and writes the same bytes on
every run. Non-ASCII copy is built with chr() so the characters stay explicit.
"""
import base64
import decimal
import hashlib
import json
import math
import re
from datetime import datetime, timedelta, timezone
from decimal import Decimal, ROUND_CEILING, ROUND_HALF_UP
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
CATALOG_PATH = ROOT / 'shared/catalog/voice-lab.json'
OUT = ROOT / 'shared/fixtures/voice-lab/pricing-cases.json'
CATALOG_BYTES = CATALOG_PATH.read_bytes()
CATALOG = json.loads(CATALOG_BYTES.decode('utf-8'))
assert CATALOG['schema'] == 'voxclip-voice-lab-prices/1'

ALMOST_EQUAL, MIDDLE_DOT = chr(0x2248), chr(0xB7)
# Far more digits than either Core keeps before the final rounding, so the reference rounds the exact value.
decimal.setcontext(decimal.Context(prec=80, rounding=ROUND_HALF_UP, traps=[decimal.InvalidOperation, decimal.DivisionByZero]))
USD_QUANTUM = Decimal('1e-10')
CANDIDATES = 3
MAX_UNITS = 1_000_000
# The discovered character_cost_multiplier is a credit multiplier, bounded so neither Core under- or overflows a decimal.
MIN_MULTIPLIER, MAX_MULTIPLIER = Decimal('0.01'), Decimal(100)
CENT = Decimal('0.01')
DECIMAL = re.compile(r'\A(0|[1-9][0-9]*)(\.[0-9]+)?\Z')
LEDGER_DECIMAL = re.compile(r'\A(0|[1-9][0-9]{0,11})(\.[0-9]{1,10})?\Z')
CAP = re.compile(r'\A(0|[1-9][0-9]{0,8})(\.[0-9]{1,2})?\Z')
PROVIDER = re.compile(r'\A[a-z0-9]+(?:-[a-z0-9]+)*\Z')
MONTH = re.compile(r'\A[0-9]{4}-(0[1-9]|1[0-2])\Z')
SPEND_SCHEMA = 'voxclip-voice-lab-spend/1'


def exact(number):
    """A double as the shortest decimal that reads back as the same double; both Cores convert this way."""
    return Decimal(repr(float(number)))


def canonical(value):
    """Plain digits, no exponent and no trailing fractional zeros: 0.30 is "0.3", 10.0 is "10"."""
    text = format(value, 'f')
    if '.' in text:
        text = text.rstrip('0').rstrip('.')
    return text


def usd(value):
    return value.quantize(USD_QUANTUM, rounding=ROUND_HALF_UP)


def ceiling(value):
    return int(value.to_integral_value(rounding=ROUND_CEILING))


def parameter(entry, group, name):
    text = entry[group][name]
    assert DECIMAL.match(text), (entry, name)
    return Decimal(text)


def operation(provider, name, unit, endpoint=None):
    return {'provider': provider, 'operation': name, 'endpoint': endpoint, 'unit': unit}


TTS = operation('elevenlabs', 'textToSpeech', 'character')
SCRIBE = operation('elevenlabs', 'speechToText', 'second')
ISOLATOR = operation('elevenlabs', 'audioIsolation', 'second')
CHANGER = operation('elevenlabs', 'voiceChange', 'second')
ALIGNMENT = operation('elevenlabs', 'forcedAlignment', 'second')
CLONE = operation('elevenlabs', 'createClone', 'call')
DELETE = operation('elevenlabs', 'deleteClone', 'call')
LATENTSYNC = operation('fal', 'lipsync', 'second', 'fal-ai/latentsync')
FAL_V2 = operation('fal', 'lipsync', 'second', 'fal-ai/sync-lipsync/v2')
FAL_V3 = operation('fal', 'lipsync', 'second', 'fal-ai/sync-lipsync/v3')
SYNCSO = operation('syncso', 'lipsync', 'second')


def matching(op, model):
    rows = [entry for entry in CATALOG['entries']
            if entry['provider'] == op['provider'] and entry['operation'] == op['operation']
            and entry.get('endpoint') == op['endpoint'] and entry.get('model') in (None, model)]
    assert len(rows) <= 1, (op, model)
    return rows[0] if rows else None


def estimate(op, model, units, candidates=1, multiplier=None):
    """The expected CostEstimate fields, or the error both Cores throw."""
    if not math.isfinite(units) or units < 0 or units > MAX_UNITS:
        return {'error': 'invalidInput'}
    if op['unit'] in ('character', 'call') and units != int(units):
        return {'error': 'invalidInput'}
    # The caller refuses an empty lip-sync window before it asks, so zero seconds never reaches the catalog.
    if op['operation'] == 'lipsync' and units == 0:
        return {'error': 'invalidInput'}
    if not 1 <= candidates <= CANDIDATES:
        return {'error': 'invalidInput'}
    if multiplier is not None and not (math.isfinite(multiplier) and MIN_MULTIPLIER <= exact(multiplier) <= MAX_MULTIPLIER):
        return {'error': 'invalidInput'}
    entry = matching(op, model)
    unknown = {'units': units, 'unit': op['unit'], 'usd': None, 'credits': None, 'basis': 'unknown'}
    if entry is None:
        return unknown
    if entry['unit'] != op['unit'] or (candidates != 1 and entry['formula'] != 'perThousandCharacters'):
        return {'error': 'invalidInput'}
    u, formula = exact(units), entry['formula']
    reported, credits = units, None
    if formula == 'estimateApi':
        return unknown
    if formula == 'zero':
        value = Decimal(0)
    elif formula == 'perHour':
        value = u * parameter(entry, 'usdParameters', 'perHour') / 3600
    elif formula == 'perMinute':
        value = u * parameter(entry, 'usdParameters', 'perMinute') / 60
        if 'creditsParameters' in entry:
            credits = ceiling(u * parameter(entry, 'creditsParameters', 'perMinute') / 60)
    elif formula == 'perSecond':
        value = u * parameter(entry, 'usdParameters', 'perSecond')
    elif formula == 'flatThenPerSecond':
        extra = max(Decimal(0), u - parameter(entry, 'usdParameters', 'includedSeconds'))
        value = parameter(entry, 'usdParameters', 'flat') + extra * parameter(entry, 'usdParameters', 'perSecond')
    elif formula == 'perThousandCharacters':
        # Each row is already that model's list price, so the multiplier scales credits only.
        m = Decimal(1) if multiplier is None else exact(multiplier)
        billed = u * candidates
        reported = int(billed)
        value = billed * parameter(entry, 'usdParameters', 'perThousandCharacters') / 1000
        if 'creditsParameters' in entry:
            credits = ceiling(billed * m * parameter(entry, 'creditsParameters', 'perCharacter'))
    else:
        raise AssertionError(formula)
    return {'units': reported, 'unit': op['unit'], 'usd': canonical(usd(value)), 'credits': credits,
            'basis': 'list-' + entry['checked']}


def magnitude(value):
    """floor(log10(value)) for a positive decimal, by exact comparison with powers of ten."""
    exponent = 0
    while value >= Decimal(10) ** (exponent + 1):
        exponent += 1
    while value < Decimal(10) ** exponent:
        exponent -= 1
    return exponent


def grouped(whole):
    return f'{whole:,}'


def amount(value):
    """The amount without the approximation sign: "$0.36", "$12", "$1,000" or "< $0.01"."""
    if value < CENT:
        return '< $0.01'
    quantum = Decimal(10) ** max(magnitude(value) - 1, -2)
    rounded = (value / quantum).quantize(Decimal(1), rounding=ROUND_HALF_UP) * quantum
    if rounded >= 10:
        return '$' + grouped(int(rounded))
    cents = int((rounded * 100).to_integral_value())
    return f'${cents // 100}.{cents % 100:02d}'


def formatted(value):
    text = amount(value)
    return text if text.startswith('<') else ALMOST_EQUAL + ' ' + text


def crosses_cap(value, cap):
    """A known amount that takes the month's known spend from at most the limit to above it."""
    return cap is not None and value is not None and Decimal(cap['spent']) <= Decimal(cap['limit']) < Decimal(cap['spent']) + value


def kind(value, lip_sync, provider, cap=None):
    """A free action is inline with no amount, but lip sync always confirms; crossing the cap always confirms and appends
    the cap sentence."""
    if value is None:
        return {'kind': 'confirm', 'text': f"VoxClip can't tell what this costs. Check {provider}'s pricing."}
    if value == 0 and not lip_sync:
        return {'kind': 'inline', 'text': ''}
    crossing = crosses_cap(value, cap)
    if value < Decimal('0.5') and not lip_sync and not crossing:
        return {'kind': 'inline', 'text': formatted(value)}
    text = (f'This will cost less than $0.01 on your {provider} account.' if value < CENT
            else f'This will cost about {amount(value)} on your {provider} account.')
    if crossing:
        text += ' ' + cap_sentence(Decimal(cap['limit']), provider)
    return {'kind': 'confirm', 'text': text}


def takes(count):
    return f'{count} take' + ('' if count == 1 else 's')


def button(action, count, presentation):
    separator = ' ' + MIDDLE_DOT + ' '
    parts = [action] + ([takes(count)] if count is not None else [])
    if presentation['kind'] == 'inline' and presentation['text']:
        parts.append(presentation['text'])
    return separator.join(parts)


def cap_text(cap):
    if cap == cap.to_integral_value():
        return grouped(int(cap))
    cents = int((cap * 100).quantize(Decimal(1), rounding=ROUND_HALF_UP))
    return f'{grouped(cents // 100)}.{cents % 100:02d}'


def cap_sentence(cap, provider):
    return f'This takes you past your ${cap_text(cap)} limit for {provider} this month.'


def instant(text):
    """An ISO 8601 UTC instant with an optional fraction, read without relying on fromisoformat's Z support."""
    found = re.fullmatch(r'(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,3}))?Z', text)
    assert found, text
    year, month, day, hour, minute, second = (int(part) for part in found.groups()[:6])
    millis = int((found.group(7) or '0').ljust(3, '0'))
    return datetime(year, month, day, hour, minute, second, millis * 1000, tzinfo=timezone.utc)


def month_key(at, offset_seconds):
    local = instant(at).astimezone(timezone(timedelta(seconds=offset_seconds)))
    return f'{local.year:04d}-{local.month:02d}'


def record(months, provider, value, at, offset_seconds):
    """Adds one action that ran; a free action (exactly 0) is not recorded at all."""
    key = month_key(at, offset_seconds)
    if value is not None and Decimal(value) == 0:
        return key
    entry = months.setdefault(key, {}).setdefault(provider, {'usd': Decimal(0), 'unknownCount': 0})
    if value is None:
        entry['unknownCount'] += 1
    else:
        entry['usd'] += Decimal(value)
    return key


def ledger_text(months):
    """The canonical file: two-space indent, months and providers in ordinal order, usd before unknownCount."""
    lines = ['{', f'  "schema": "{SPEND_SCHEMA}",']
    if not months:
        lines.append('  "months": {}')
    else:
        lines.append('  "months": {')
        keys = sorted(months)
        for index, key in enumerate(keys):
            comma = ',' if index < len(keys) - 1 else ''
            providers = sorted(months[key])
            if not providers:
                lines.append(f'    "{key}": {{}}' + comma)
                continue
            lines.append(f'    "{key}": {{')
            for position, provider in enumerate(providers):
                entry = months[key][provider]
                lines.append(f'      "{provider}": {{')
                lines.append(f'        "usd": "{canonical(entry["usd"])}",')
                lines.append(f'        "unknownCount": {entry["unknownCount"]}')
                lines.append('      }' + (',' if position < len(providers) - 1 else ''))
            lines.append('    }' + comma)
        lines.append('  }')
    lines.append('}')
    return '\n'.join(lines) + '\n'


def parse_ledger(data):
    """The reader's rules: None means corrupt, so the next record moves the file aside and starts afresh."""
    def unique(pairs):
        keys = [key for key, _ in pairs]
        if len(set(keys)) != len(keys):
            raise ValueError('duplicate key')
        return dict(pairs)
    try:
        document = json.loads(data.decode('utf-8'), object_pairs_hook=unique)
    except (UnicodeDecodeError, ValueError):
        return None
    if not isinstance(document, dict) or set(document) != {'schema', 'months'} or document['schema'] != SPEND_SCHEMA:
        return None
    if not isinstance(document['months'], dict):
        return None
    months = {}
    for key, providers in document['months'].items():
        if not MONTH.match(key) or not isinstance(providers, dict):
            return None
        months[key] = {}
        for provider, entry in providers.items():
            if not PROVIDER.match(provider) or not isinstance(entry, dict) or set(entry) != {'usd', 'unknownCount'}:
                return None
            spent, count = entry['usd'], entry['unknownCount']
            if not isinstance(spent, str) or not LEDGER_DECIMAL.match(spent):
                return None
            if isinstance(count, bool) or not isinstance(count, int) or not 0 <= count <= 2_147_483_647:
                return None
            months[key][provider] = {'usd': Decimal(spent), 'unknownCount': count}
    return months


def estimate_case(name, op, model, units, candidates=1, multiplier=None):
    return {'id': name, 'operation': op, 'model': model, 'units': units, 'candidates': candidates,
            'characterMultiplier': multiplier, 'expected': estimate(op, model, units, candidates, multiplier)}


# Typical units per operation: a consent statement, 3 minutes of Clean audio, a 10 s preview, a 60-character patch,
# a one-call clone or deletion; anything else is a 9 s lip-sync window.
TYPICAL = {'speechToText': 30, 'audioIsolation': 180, 'voiceChange': 10, 'textToSpeech': 60, 'forcedAlignment': 9,
           'createClone': 1, 'deleteClone': 1}
ESTIMATES = []
for entry in CATALOG['entries']:
    op = operation(entry['provider'], entry['operation'], entry['unit'], entry.get('endpoint'))
    model = entry.get('model')
    label = '-'.join(part for part in (entry['provider'], entry['operation'], entry.get('endpoint'), model) if part)
    label = re.sub(r'[^a-z0-9]+', '-', label.lower()).strip('-')
    for units in sorted({0, 1, TYPICAL.get(entry['operation'], 9)}):
        ESTIMATES.append(estimate_case(f'row-{label}-{units}', op, model, units))
ESTIMATES += [
    estimate_case('latentsync-5s', LATENTSYNC, None, 5),
    estimate_case('latentsync-60s', LATENTSYNC, None, 60),
    estimate_case('latentsync-39.999s', LATENTSYNC, None, 39.999),
    estimate_case('latentsync-40s', LATENTSYNC, None, 40),
    estimate_case('latentsync-40.001s', LATENTSYNC, None, 40.001),
    estimate_case('isolator-3-minutes', ISOLATOR, None, 180),
    estimate_case('isolator-1-second-credits-round-up', ISOLATOR, None, 1),
    estimate_case('isolator-0.06-seconds-one-credit', ISOLATOR, None, 0.06),
    estimate_case('voice-changer-any-model', CHANGER, 'eleven_multilingual_sts_v2', 10),
    estimate_case('voice-changer-0.1-seconds', CHANGER, 'eleven_multilingual_sts_v2', 0.1),
    estimate_case('scribe-1-hour', SCRIBE, 'scribe_v2', 3600),
    estimate_case('alignment-tiny-duration', ALIGNMENT, None, 0.00001),
    estimate_case('tts-spec-60-characters-3-candidates', TTS, 'eleven_v3', 60, 3),
    estimate_case('tts-default-multiplier', TTS, 'eleven_multilingual_v2', 60, 1, None),
    estimate_case('tts-odd-multiplier-credits-round-up', TTS, 'eleven_v3', 1, 1, 0.5),
    estimate_case('tts-largest-text-3-candidates', TTS, 'eleven_v3', 5000, 3, 2),
]
for model in ('eleven_v3', 'eleven_flash_v2_5'):
    for candidates in (1, 2, 3):
        for multiplier in (0.5, 1, 2):
            ESTIMATES.append(estimate_case(f'tts-{model}-{candidates}-candidates-multiplier-{multiplier}', TTS, model, 60,
                                           candidates, multiplier))
ESTIMATES += [
    estimate_case('unknown-tts-model', TTS, 'eleven_v9_future', 60),
    estimate_case('unknown-tts-model-3-candidates', TTS, 'eleven_v9_future', 60, 3),
    estimate_case('tts-without-model', TTS, None, 60),
    estimate_case('unknown-operation', operation('elevenlabs', 'dubbing', 'second'), None, 60),
    estimate_case('unknown-provider', operation('heygen', 'lipsync', 'second'), None, 9),
    estimate_case('unknown-fal-endpoint', operation('fal', 'lipsync', 'second', 'fal-ai/unknown'), None, 9),
    estimate_case('fal-without-endpoint', operation('fal', 'lipsync', 'second'), None, 9),
    estimate_case('fal-v2-without-model', FAL_V2, None, 9),
    estimate_case('fal-v2-unknown-model', FAL_V2, 'lipsync-9', 9),
    estimate_case('fal-v3-any-model', FAL_V3, 'sync-3', 9),
    estimate_case('delete-clone-free', DELETE, None, 1),
    estimate_case('invalid-negative-units', ISOLATOR, None, -1),
    estimate_case('invalid-too-many-units', ISOLATOR, None, MAX_UNITS + 1),
    estimate_case('largest-units', ISOLATOR, None, MAX_UNITS),
    estimate_case('invalid-fractional-characters', TTS, 'eleven_v3', 60.5),
    estimate_case('invalid-fractional-call', CLONE, None, 1.5),
    estimate_case('invalid-zero-second-lipsync', SYNCSO, 'sync-3', 0),
    estimate_case('invalid-zero-second-lipsync-unknown-provider', operation('heygen', 'lipsync', 'second'), None, 0),
    estimate_case('invalid-zero-candidates', TTS, 'eleven_v3', 60, 0),
    estimate_case('invalid-four-candidates', TTS, 'eleven_v3', 60, 4),
    estimate_case('invalid-zero-multiplier', TTS, 'eleven_v3', 60, 1, 0),
    estimate_case('invalid-negative-multiplier', TTS, 'eleven_v3', 60, 1, -1),
    estimate_case('invalid-huge-multiplier', TTS, 'eleven_v3', 60, 1, 101),
    estimate_case('invalid-tiny-multiplier', TTS, 'eleven_v3', 60, 1, 1e-120),
    estimate_case('invalid-multiplier-below-bound', TTS, 'eleven_v3', 60, 1, 0.0099),
    estimate_case('smallest-multiplier', TTS, 'eleven_v3', 60, 1, 0.01),
    estimate_case('largest-multiplier', TTS, 'eleven_v3', 60, 1, 100),
    estimate_case('invalid-unit-mismatch', operation('elevenlabs', 'voiceChange', 'minute'), None, 1),
    estimate_case('invalid-candidates-for-isolator', ISOLATOR, None, 60, 2),
    estimate_case('invalid-candidates-for-estimate-api', SYNCSO, 'sync-3', 9, 2),
    estimate_case('multiplier-ignored-outside-tts', ISOLATOR, None, 180, 1, 2),
]
assert len({case['id'] for case in ESTIMATES}) == len(ESTIMATES)
EXPECTED_USD = {case['id']: case['expected'].get('usd') for case in ESTIMATES}
assert EXPECTED_USD['isolator-3-minutes'] == '0.36'
assert EXPECTED_USD['latentsync-5s'] == '0.2' and EXPECTED_USD['latentsync-60s'] == '0.3'
assert EXPECTED_USD['tts-spec-60-characters-3-candidates'] == '0.0144'
# Flash and Turbo are already listed at half price: a 0.5 multiplier halves their credits, not their dollars.
FLASH_HALF = next(case for case in ESTIMATES if case['id'] == 'tts-eleven_flash_v2_5-1-candidates-multiplier-0.5')
assert FLASH_HALF['expected']['usd'] == '0.0024' and FLASH_HALF['expected']['credits'] == 30


def provider_price(name, base, value, credits, basis):
    expected = {'error': 'invalidInput'}
    if DECIMAL.match(value) and (credits is None or credits >= 0):
        expected = dict(base, usd=canonical(usd(Decimal(value))), credits=credits, basis=basis)
    return {'id': name, 'estimate': base, 'price': {'usd': value, 'credits': credits, 'basis': basis}, 'expected': expected}


SYNC_UNKNOWN = dict(provider='syncso', operation='lipsync', units=9, unit='second', usd=None, credits=None, basis='unknown')
FAL_LIST = dict(provider='fal', operation='lipsync', units=9, unit='second', usd='0.45', credits=None, basis='list-2026-10-25')
PROVIDER_PRICES = [
    provider_price('syncso-estimate', SYNC_UNKNOWN, '0.6', 12, 'provider-estimate'),
    provider_price('fal-pricing-api', FAL_LIST, '0.45', None, 'provider-pricing-api'),
    provider_price('rounded-to-ten-places', SYNC_UNKNOWN, '1.23456789015', None, 'provider-estimate'),
    provider_price('negative-usd', SYNC_UNKNOWN, '-0.01', None, 'provider-estimate'),
    provider_price('negative-credits', SYNC_UNKNOWN, '0.6', -1, 'provider-estimate'),
]

FORMAT_VALUES = ['0', '0.004999', '0.005', '0.0099', '0.01', '0.0144', '0.0149', '0.015', '0.02', '0.04', '0.099',
                 '0.0995', '0.36', '0.495', '0.4999', '0.5', '1', '1.2', '9.949', '9.95', '9.99', '9.994', '10', '12',
                 '99.5', '120', '999.5', '12345.6', '133333.3333333333']
FORMATS = [{'usd': value, 'text': formatted(Decimal(value)), 'presentation': kind(Decimal(value), False, 'ElevenLabs')}
           for value in FORMAT_VALUES]
assert [case['text'] for case in FORMATS if case['usd'] in ('0.0144', '0.36', '1.2', '12', '120')] == [
    ALMOST_EQUAL + ' $0.01', ALMOST_EQUAL + ' $0.36', ALMOST_EQUAL + ' $1.20', ALMOST_EQUAL + ' $12', ALMOST_EQUAL + ' $120']

def cap(limit, spent):
    return {'limit': limit, 'spent': spent}


PRESENTATIONS = []
for value, lip_sync, provider, monthly in [
        ('0.36', False, 'ElevenLabs', None), ('0.4999', False, 'ElevenLabs', None), ('0.5', False, 'ElevenLabs', None),
        ('0.2', True, 'fal.ai', None), (None, False, 'sync.so', None), (None, True, 'sync.so', None),
        ('0.004', True, 'fal.ai', None), ('0', False, 'ElevenLabs', None), ('0', True, 'fal.ai', None),
        ('12.4', False, 'ElevenLabs', None), ('1200', False, 'ElevenLabs', None), (None, False, 'OpenAI', None),
        # The cap: crossing forces a confirmation even under $0.50; reaching it exactly or starting above it does not.
        ('0.36', False, 'ElevenLabs', cap('20', '19.7')), ('0.36', False, 'ElevenLabs', cap('20', '19.64')),
        ('0.36', False, 'ElevenLabs', cap('20', '20.5')), ('0.6', False, 'ElevenLabs', cap('20', '19.7')),
        ('0.2', True, 'fal.ai', cap('12.5', '12.4')), (None, False, 'sync.so', cap('20', '19.9')),
        ('0', False, 'ElevenLabs', cap('0', '0')), ('0.004', False, 'ElevenLabs', cap('0', '0')),
        ('1000', False, 'ElevenLabs', cap('1000', '0'))]:
    row = {'usd': value, 'isLipSync': lip_sync, 'providerName': provider}
    if monthly is not None:
        row['cap'] = monthly
    row['expected'] = kind(None if value is None else Decimal(value), lip_sync, provider, monthly)
    PRESENTATIONS.append(row)
CAPPED = [row['expected'] for row in PRESENTATIONS if 'cap' in row]
assert CAPPED[0] == {'kind': 'confirm', 'text': 'This will cost about $0.36 on your ElevenLabs account. '
                                                'This takes you past your $20 limit for ElevenLabs this month.'}
assert [row['kind'] for row in CAPPED] == ['confirm', 'inline', 'inline', 'confirm', 'confirm', 'confirm', 'inline', 'confirm',
                                           'confirm']
assert CAPPED[-1]['text'] == 'This will cost about $1,000 on your ElevenLabs account.'

BUTTONS = []
for action, count, value, lip_sync, monthly in [
        ('Clean audio', None, '0.36', False, None), ('Re-voice', 3, '0.0192', False, None),
        ('Re-voice', 1, '0.0064', False, None), ('Generate Takes', None, '0.0192', False, None),
        ('Clean audio', None, '0.6', False, None), ('Re-voice', 3, None, False, None),
        ('Lip sync', None, '0.2', True, None), ('Create voice', None, '0', False, None),
        ('Delete voice', None, '0', False, None), ('Clean audio', None, '0.36', False, cap('20', '19.7'))]:
    presentation = kind(None if value is None else Decimal(value), lip_sync, 'ElevenLabs', monthly)
    row = {'action': action, 'takes': count, 'usd': value, 'isLipSync': lip_sync}
    if monthly is not None:
        row['cap'] = monthly
    row['text'] = button(action, count, presentation)
    BUTTONS.append(row)
assert BUTTONS[0]['text'] == 'Clean audio ' + MIDDLE_DOT + ' ' + ALMOST_EQUAL + ' $0.36'
assert BUTTONS[1]['text'] == 'Re-voice ' + MIDDLE_DOT + ' 3 takes ' + MIDDLE_DOT + ' ' + ALMOST_EQUAL + ' $0.02'
assert [row['text'] for row in BUTTONS[-3:]] == ['Create voice', 'Delete voice', 'Clean audio']


def spend(provider, value, at):
    return {'provider': provider, 'usd': value, 'at': at}


def sequence(name, offset_seconds, records):
    months = {}
    steps = [dict(item, month=record(months, item['provider'], item['usd'], item['at'], offset_seconds)) for item in records]
    return {'id': name, 'timeZoneOffsetSeconds': offset_seconds, 'records': steps, 'ledger': ledger_text(months)}


ROLLOVERS = [
    sequence('east-of-utc-local-midnight', 7200, [
        spend('elevenlabs', '0.36', '2026-10-31T21:59:59Z'),
        spend('elevenlabs', '0', '2026-10-31T21:59:59.500Z'),
        spend('elevenlabs', None, '2026-10-31T22:00:00Z'),
        spend('fal', '0.2', '2026-11-30T21:59:59.999Z'),
        spend('elevenlabs', '0.12', '2026-11-15T12:00:00Z'),
        spend('elevenlabs', '0.0144', '2026-12-31T22:00:00Z'),
    ]),
    sequence('west-of-utc-local-midnight', -18000, [
        spend('elevenlabs', '0.5', '2026-11-01T04:59:59.999Z'),
        spend('elevenlabs', '0.5', '2026-11-01T05:00:00Z'),
        spend('syncso', None, '2027-01-01T04:59:59Z'),
        spend('fal', '0', '2027-01-01T04:59:59Z'),
        spend('syncso', '0.6', '2027-01-01T05:00:00Z'),
    ]),
]
assert [step['month'] for step in ROLLOVERS[0]['records']] == ['2026-10', '2026-10', '2026-11', '2026-11', '2026-11', '2027-01']
assert [step['month'] for step in ROLLOVERS[1]['records']] == ['2026-10', '2026-11', '2026-12', '2026-12', '2027-01']
assert '"fal"' not in ROLLOVERS[1]['ledger']
# Free actions alone never create the ledger, its lock or the paid root.
FREE_ONLY = {'timeZoneOffsetSeconds': 0, 'records': [spend('elevenlabs', '0', '2026-10-27T12:00:00Z'),
                                                     spend('fal', '0', '2026-10-27T12:00:01Z')]}

CONCURRENT_AT = '2026-10-27T12:00:00Z'
CONCURRENT = {'timeZoneOffsetSeconds': 0, 'at': CONCURRENT_AT, 'recordsPerWriter': 50,
              'writers': [{'provider': 'elevenlabs', 'usd': '0.01'}, {'provider': 'elevenlabs', 'usd': None}]}
concurrent_months = {}
for writer in CONCURRENT['writers']:
    for _ in range(CONCURRENT['recordsPerWriter']):
        record(concurrent_months, writer['provider'], writer['usd'], CONCURRENT_AT, 0)
CONCURRENT['ledger'] = ledger_text(concurrent_months)
assert canonical(concurrent_months['2026-10']['elevenlabs']['usd']) == '0.5'

RECOVERY_RECORD = spend('elevenlabs', '0.36', '2026-10-27T12:00:00Z')
VALID_PREFIX = '{"schema":"' + SPEND_SCHEMA + '","months":'


def existing(name, content=None, raw=None):
    data = raw if raw is not None else content.encode('utf-8')
    months = parse_ledger(data)
    corrupt = months is None
    months = {} if corrupt else months
    record(months, RECOVERY_RECORD['provider'], RECOVERY_RECORD['usd'], RECOVERY_RECORD['at'], 0)
    row = {'id': name, 'corrupt': corrupt, 'ledger': ledger_text(months)}
    if raw is not None:
        row['contentBase64'] = base64.b64encode(raw).decode('ascii')
    else:
        row['content'] = content
    return row


EXISTING = [
    existing('invalid-json', '{broken'),
    existing('empty-file', ''),
    existing('top-level-array', '[]'),
    existing('unknown-format', '{"schema":"voxclip-voice-lab-spend/2","months":{}}'),
    existing('extra-top-level-key', VALID_PREFIX + '{},"total":"1"}'),
    existing('usd-as-number', VALID_PREFIX + '{"2026-10":{"elevenlabs":{"usd":0.36,"unknownCount":0}}}}'),
    existing('usd-with-exponent', VALID_PREFIX + '{"2026-10":{"elevenlabs":{"usd":"3.6e-1","unknownCount":0}}}}'),
    existing('usd-too-precise', VALID_PREFIX + '{"2026-10":{"elevenlabs":{"usd":"0.12345678901","unknownCount":0}}}}'),
    existing('negative-usd', VALID_PREFIX + '{"2026-10":{"elevenlabs":{"usd":"-0.36","unknownCount":0}}}}'),
    existing('negative-unknown-count', VALID_PREFIX + '{"2026-10":{"elevenlabs":{"usd":"0.36","unknownCount":-1}}}}'),
    existing('fractional-unknown-count', VALID_PREFIX + '{"2026-10":{"elevenlabs":{"usd":"0.36","unknownCount":1.5}}}}'),
    existing('boolean-unknown-count', VALID_PREFIX + '{"2026-10":{"elevenlabs":{"usd":"0.36","unknownCount":true}}}}'),
    existing('missing-unknown-count', VALID_PREFIX + '{"2026-10":{"elevenlabs":{"usd":"0.36"}}}}'),
    existing('month-13', VALID_PREFIX + '{"2026-13":{}}}'),
    existing('provider-with-space', VALID_PREFIX + '{"2026-10":{"Eleven Labs":{"usd":"0.36","unknownCount":0}}}}'),
    existing('invalid-utf8', raw=VALID_PREFIX.encode('utf-8') + b'{"2026-10":{"' + bytes([0xFF]) +
             b'":{"usd":"0","unknownCount":0}}}}'),
    existing('byte-order-mark', raw=bytes([0xEF, 0xBB, 0xBF]) + (VALID_PREFIX + '{}}').encode('utf-8')),
    existing('duplicate-top-level-key', VALID_PREFIX + '{},"months":{}}'),
    existing('duplicate-month', VALID_PREFIX + '{"2026-10":{},"2026-10":{}}}'),
    existing('duplicate-escaped-month', VALID_PREFIX + '{"2026-10":{},"' + chr(92) + 'u0032026-10":{}}}'),
    existing('duplicate-provider', VALID_PREFIX + '{"2026-10":{"fal":{"usd":"0.2","unknownCount":0},'
                                                  '"fal":{"usd":"0.3","unknownCount":0}}}}'),
    existing('duplicate-usd', VALID_PREFIX + '{"2026-10":{"fal":{"usd":"0.2","usd":"0.3","unknownCount":0}}}}'),
    existing('valid-escaped-month', VALID_PREFIX + '{"' + chr(92) + 'u0032026-10":{"fal":{"usd":"0.2","unknownCount":0}}}}'),
    existing('valid-noncanonical-decimal', VALID_PREFIX + '{"2026-10":{"elevenlabs":{"usd":"0.360","unknownCount":2}}}}'),
    existing('valid-empty-month', VALID_PREFIX + '{"2026-09":{}}}'),
    existing('valid-other-month-and-provider',
             VALID_PREFIX + '{"2026-09":{"fal":{"usd":"0.2","unknownCount":0}},"2026-10":{"syncso":{"usd":"0","unknownCount":1}}}}'),
]
assert [row['corrupt'] for row in EXISTING].count(False) == 4
assert all(row['corrupt'] for row in EXISTING if row['id'].startswith('duplicate-'))

CAP_EXISTING = [spend('elevenlabs', '19.5', '2026-10-02T09:00:00Z'), spend('elevenlabs', '0.4', '2026-10-20T09:00:00Z'),
                spend('elevenlabs', None, '2026-10-21T09:00:00Z')]


def crossing(cap, provider, value, at):
    before = sum((Decimal(item['usd']) for item in CAP_EXISTING if item['provider'] == provider and item['usd'] is not None
                  and month_key(item['at'], 0) == month_key(at, 0)), Decimal(0))
    return value is not None and before <= Decimal(cap) < before + Decimal(value)


CAP_CHECKS = []
for cap, provider, value, at in [('20', 'elevenlabs', '0.05', '2026-10-27T12:00:00Z'), ('20', 'elevenlabs', '0.1', '2026-10-27T12:00:00Z'),
                                 ('20', 'elevenlabs', '0.11', '2026-10-27T12:00:00Z'), ('20', 'elevenlabs', None, '2026-10-27T12:00:00Z'),
                                 ('19.9', 'elevenlabs', '0.01', '2026-10-27T12:00:00Z'), ('19.8', 'elevenlabs', '1', '2026-10-27T12:00:00Z'),
                                 ('0', 'fal', '0.01', '2026-10-27T12:00:00Z'), ('0', 'fal', '0', '2026-10-27T12:00:00Z'),
                                 ('20', 'elevenlabs', '0.11', '2026-11-01T00:00:00Z'), ('20', 'elevenlabs', '20.01', '2026-11-01T00:00:00Z')]:
    CAP_CHECKS.append({'cap': cap, 'provider': provider, 'usd': value, 'at': at, 'wouldCross': crossing(cap, provider, value, at)})
assert [check['wouldCross'] for check in CAP_CHECKS] == [False, False, True, False, True, False, True, False, False, True]
CAP_SENTENCES = [{'cap': cap, 'providerName': provider, 'text': cap_sentence(Decimal(cap), provider)}
                 for cap, provider in [('20', 'ElevenLabs'), ('12.5', 'fal.ai'), ('12.50', 'sync.so'), ('1000', 'ElevenLabs'),
                                       ('0.5', 'ElevenLabs'), ('0', 'ElevenLabs')]]

SETTINGS = []
for key, value in [('voiceLab.monthlyCapUsd.elevenlabs', '20'), ('voiceLab.monthlyCapUsd.fal', '12.50'),
                   ('voiceLab.monthlyCapUsd.syncso', '0'), ('voiceLab.monthlyCapUsd.claude-code', '999999999.99'),
                   ('voiceLab.monthlyCapUsd.elevenlabs', None), ('voiceLab.monthlyCapUsd.elevenlabs', 20),
                   ('voiceLab.monthlyCapUsd.elevenlabs', '12.345'), ('voiceLab.monthlyCapUsd.elevenlabs', '-1'),
                   ('voiceLab.monthlyCapUsd.elevenlabs', '01'), ('voiceLab.monthlyCapUsd.elevenlabs', ''),
                   ('voiceLab.monthlyCapUsd.elevenlabs', '1e3'), ('voiceLab.monthlyCapUsd.elevenlabs', '1000000000')]:
    valid = value is None or (isinstance(value, str) and CAP.match(value) is not None)
    SETTINGS.append({'key': key, 'value': value, 'valid': valid})


def quote(name, op, model=None, multiplier=None, text=None, wav=None):
    units = len(text) if text is not None else wav['frames'] / wav['rate'] if wav is not None else 1
    row = {'id': name, 'operation': op['operation'], 'model': model, 'characterCostMultiplier': multiplier,
           'expected': dict(estimate(op, model, units, 1, multiplier), provider='elevenlabs', operation=op['operation'])}
    if text is not None:
        row['text'] = text
    if wav is not None:
        row['wav'] = wav
    return row


QUOTES = [
    quote('tts-discovered-multiplier', TTS, 'eleven_v3', 0.5, text='Hello there'),
    quote('tts-unpriced-model', TTS, 'new_speech_model', None, text='Hi'),
    quote('voice-changer-tenth-of-a-second', CHANGER, 'eleven_multilingual_sts_v2', None, wav={'rate': 24000, 'frames': 2400}),
    quote('voice-changer-odd-rate', CHANGER, 'eleven_multilingual_sts_v2', None, wav={'rate': 22050, 'frames': 2400}),
    quote('create-clone-free', CLONE),
    quote('delete-clone-free', DELETE),
]
assert QUOTES[0]['expected']['usd'] == '0.00088' and QUOTES[0]['expected']['credits'] == 6

document = {
    'schema': 'voxclip-voice-lab-pricing-cases/1',
    'source': 'doc/spec/voice-lab.md §3.1 and §3.2',
    'description': 'Synthetic Voice Lab pricing, presentation and spend-ledger cases. Generated by '
                   'tools/fixtures/voice-lab/generate_pricing.py; see pricing-cases-README.md.',
    'inputs': {'shared/catalog/voice-lab.json': hashlib.sha256(CATALOG_BYTES).hexdigest()},
    'usdDecimalPlaces': 10,
    'estimates': ESTIMATES,
    'providerPrices': PROVIDER_PRICES,
    'formats': FORMATS,
    'presentations': PRESENTATIONS,
    'buttons': BUTTONS,
    'quotes': QUOTES,
    'ledger': {
        'emptyFile': ledger_text({}),
        'rollovers': ROLLOVERS,
        'freeOnly': FREE_ONLY,
        'concurrent': CONCURRENT,
        'recoveryRecord': RECOVERY_RECORD,
        'existing': EXISTING,
        'cap': {'timeZoneOffsetSeconds': 0, 'existing': CAP_EXISTING, 'checks': CAP_CHECKS, 'sentences': CAP_SENTENCES},
    },
    'settings': SETTINGS,
}
OUT.write_text(json.dumps(document, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')
