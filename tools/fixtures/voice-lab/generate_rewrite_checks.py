#!/usr/bin/env python3
"""Write the shared rows for the checks both Voice Lab rewrite sends make (ai.md §12.8).

The rows sit just below, at and just above each boundary: the answering model, including dated snapshots of an HTTP
connector's id; the model-id bound; the output cap; and the context fit. Each row states its outcome by hand, and the
generator checks it against its own reading of §12.8, which uses datetime for calendar dates and unicodedata for control
characters, independent of both Cores. Non-ASCII text is built with chr(). Running the generator twice gives identical
bytes. See shared/fixtures/voice-lab/rewrite-README.md.
"""
import datetime
import json
import math
import unicodedata
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / 'shared/fixtures/voice-lab/rewrite-checks-cases.json'
CATALOG = json.loads((ROOT / 'shared/catalog/llm-providers.json').read_text(encoding='utf-8'))
FACTOR = CATALOG['policy']['tokenEstimate']['contextSafetyFactor']
CONNECTORS = [connector['id'] for connector in CATALOG['connectors']]
HTTP = ('anthropic', 'openai', 'xai', 'gemini', 'ollama', 'lmstudio')
assert set(HTTP) < set(CONNECTORS), 'every HTTP connector is in the catalogue'
assert FACTOR == 0.9, 'the rows assume the catalogue safety factor'


def is_snapshot_date(suffix):
    """YYYY-MM-DD or YYYYMMDD in ASCII digits, naming a day the Gregorian calendar has."""
    if len(suffix) == 10 and suffix[4] == '-' and suffix[7] == '-':
        digits = suffix[:4] + suffix[5:7] + suffix[8:]
    elif len(suffix) == 8:
        digits = suffix
    else:
        return False
    if not all('0' <= character <= '9' for character in digits):
        return False
    try:
        datetime.date(int(digits[:4]), int(digits[4:6]), int(digits[6:]))
    except ValueError:
        return False
    return True


def answered_by(connector, selected, answered):
    """ai.md §12.8 over UTF-8 bytes."""
    choice, answer = selected.encode('utf-8'), answered.encode('utf-8')
    if answer == choice:
        return True
    if connector == 'claude-code':
        if selected == 'default':
            return answer.startswith(b'claude-')
        return selected in ('sonnet', 'opus', 'haiku') and answer.startswith(b'claude-' + choice + b'-')
    if connector in HTTP:
        return answer.startswith(choice + b'-') and is_snapshot_date(answer[len(choice) + 1:].decode('utf-8'))
    return False


def valid_model(model):
    return 1 <= len(model.encode('utf-8')) <= 256 and not any(unicodedata.category(scalar) == 'Cc' for scalar in model)


def max_output_tokens(source_tokens, prompt_cap, connector_cap):
    cap = min(prompt_cap, prompt_cap if connector_cap is None else connector_cap, max(512, math.ceil(source_tokens * 1.5)))
    return cap if cap >= source_tokens else None


def context_fits(context, required):
    return context >= 512 and required <= math.floor(context * FACTOR)


ARABIC_INDIC_DATE = ''.join(chr(0x660 + int(digit)) for digit in '20261001')
E_ACUTE, COMBINING_ACUTE = chr(0xE9), chr(0x301)

# (id, connector, selected, answered, accepted, note)
ANSWERS = [
    ('exact-id', 'openai', 'gpt-6.1-sol', 'gpt-6.1-sol', True, 'The selected id itself.'),
    ('dated-snapshot', 'openai', 'gpt-6.1-sol', 'gpt-6.1-sol-2026-10-01', True, 'A dated snapshot with hyphens.'),
    ('compact-dated-snapshot', 'anthropic', 'claude-sonnet-5-5', 'claude-sonnet-5-5-20261001', True, 'A dated snapshot without hyphens.'),
    ('leap-day', 'gemini', 'gemini-3.8-flash', 'gemini-3.8-flash-2028-02-29', True, '2028 is a leap year.'),
    ('leap-day-of-a-400-year', 'xai', 'grok-4.7', 'grok-4.7-20000229', True, '2000 is divisible by 400, so it is a leap year.'),
    ('no-leap-day', 'gemini', 'gemini-3.8-flash', 'gemini-3.8-flash-2026-02-29', False, '2026 has no 29 February.'),
    ('no-leap-day-in-a-century', 'xai', 'grok-4.7', 'grok-4.7-21000229', False, '2100 is divisible by 100 and not by 400.'),
    ('month-13', 'openai', 'gpt-6.1-sol', 'gpt-6.1-sol-2026-13-01', False, 'There is no month 13.'),
    ('day-0', 'openai', 'gpt-6.1-sol', 'gpt-6.1-sol-2026-10-00', False, 'There is no day 0.'),
    ('day-31-of-a-30-day-month', 'openai', 'gpt-6.1-sol', 'gpt-6.1-sol-2026-04-31', False, 'April has 30 days.'),
    ('last-day-of-a-month', 'openai', 'gpt-6.1-sol', 'gpt-6.1-sol-2026-04-30', True, 'The month\'s last day.'),
    ('local-server-snapshot', 'ollama', 'gemma4:12b', 'gemma4:12b-2026-10-01', True, 'Local servers are HTTP connectors too.'),
    ('local-server-other-model', 'lmstudio', 'local-model', 'local-model-v2', False, 'A suffix that is no date.'),
    ('non-date-suffix', 'openai', 'gpt-6.1-sol', 'gpt-6.1-sol-mini', False, 'Another model of the same family.'),
    ('date-then-suffix', 'openai', 'gpt-6.1-sol', 'gpt-6.1-sol-2026-10-01-preview', False, 'Anything after the date.'),
    ('date-without-hyphen', 'openai', 'gpt-6.1-sol', 'gpt-6.1-sol20261001', False, 'The date must follow a hyphen.'),
    ('mixed-date-form', 'openai', 'gpt-6.1-sol', 'gpt-6.1-sol-2026-1001', False, 'Hyphens for all of the date or none of it.'),
    ('nine-digit-date', 'openai', 'gpt-6.1-sol', 'gpt-6.1-sol-202610011', False, 'Eight digits exactly.'),
    ('other-script-digits', 'openai', 'gpt-6.1-sol', 'gpt-6.1-sol-' + ARABIC_INDIC_DATE, False, 'Dates are ASCII digits.'),
    ('prefix-of-the-selected-id', 'openai', 'gpt-6.1-sol', 'gpt-6.1', False, 'A shorter id of the same family.'),
    ('selected-id-as-a-prefix', 'openai', 'gpt-6.1', 'gpt-6.1-sol', False, 'A longer id that starts with the selected one.'),
    ('different-case', 'openai', 'gpt-6.1-sol', 'GPT-6.1-sol', False, 'Ids compare ordinally, so case counts.'),
    ('canonically-equivalent-id', 'lmstudio', 'caf' + E_ACUTE, 'cafe' + COMBINING_ACUTE, False,
     'Ids compare as UTF-8 bytes, never by canonical equivalence.'),
    ('codex-has-no-snapshots', 'codex', 'gpt-6.1-sol', 'gpt-6.1-sol-2026-10-01', False, 'Only HTTP connectors take snapshots.'),
    ('codex-default', 'codex', 'default', 'default', True, 'The exact id.'),
    ('codex-default-names-no-model', 'codex', 'default', 'gpt-6.1-sol', False, 'Only Claude Code\'s default is an alias.'),
    ('apple-has-no-snapshots', 'apple-foundation', 'system', 'system-2026-10-01', False, 'Only HTTP connectors take snapshots.'),
    ('claude-code-alias', 'claude-code', 'sonnet', 'claude-sonnet-5-5', True, 'A curated alias and the id it stands for.'),
    ('claude-code-alias-snapshot', 'claude-code', 'opus', 'claude-opus-5-5-20261001', True, 'The alias rule takes any claude-opus- id.'),
    ('claude-code-default', 'claude-code', 'default', 'claude-haiku-5-5', True, 'default takes any claude- id.'),
    ('claude-code-alias-itself', 'claude-code', 'haiku', 'haiku', True, 'The exact id.'),
    ('claude-code-other-alias', 'claude-code', 'sonnet', 'claude-opus-5-5', False, 'Another alias\'s model.'),
    ('claude-code-alias-without-hyphen', 'claude-code', 'opus', 'claude-opus5-5', False, 'The alias must be followed by a hyphen.'),
    ('claude-code-bare-family', 'claude-code', 'sonnet', 'claude-sonnet', False, 'The family name alone.'),
    ('claude-code-full-id-has-no-snapshots', 'claude-code', 'claude-sonnet-5-5', 'claude-sonnet-5-5-20261001', False,
     'A selected full id is no alias, and Claude Code takes no snapshots.'),
    ('claude-code-default-other-vendor', 'claude-code', 'default', 'gpt-6.1-sol', False, 'Not a claude- id.'),
    ('http-connector-has-no-aliases', 'openai', 'sonnet', 'claude-sonnet-5-5', False, 'Only Claude Code has aliases.'),
]

# (id, model, valid, note)
MODELS = [
    ('empty', '', False, 'At least one byte.'),
    ('one-byte', 'a', True, 'The shortest id.'),
    ('256-bytes', 'a' * 256, True, 'The longest id.'),
    ('257-bytes', 'a' * 257, False, 'One byte too many.'),
    ('256-bytes-with-a-two-byte-scalar', 'a' * 254 + E_ACUTE, True, 'U+00E9 is two UTF-8 bytes.'),
    ('257-bytes-with-a-two-byte-scalar', 'a' * 255 + E_ACUTE, False, 'The limit counts bytes, not scalars.'),
    ('256-bytes-with-an-astral-scalar', 'a' * 252 + chr(0x1F600), True, 'U+1F600 is four UTF-8 bytes and two UTF-16 units.'),
    ('257-bytes-with-an-astral-scalar', 'a' * 253 + chr(0x1F600), False, 'The limit counts UTF-8 bytes, not UTF-16 units.'),
    ('nul', 'gpt' + chr(0) + '6', False, 'NUL is a control character.'),
    ('tab', 'gpt' + chr(9) + '6', False, 'So is a tab.'),
    ('line-feed', 'gpt-6' + chr(10), False, 'So is a line feed.'),
    ('delete', 'gpt-6' + chr(0x7F), False, 'DEL is Cc.'),
    ('next-line', 'gpt-6' + chr(0x85), False, 'NEL is Cc.'),
    ('zero-width-space', 'gpt-6' + chr(0x200B), True, 'U+200B is Cf, not a control character.'),
    ('space-inside', 'my model', True, 'A space is no control character.'),
    ('curated-ids', 'claude-sonnet-5-5', True, 'An ordinary id.'),
]

# (id, sourceTokens, promptCap, connectorCap, maxOutputTokens, note)
OUTPUT_CAPS = [
    ('minimum-512', 1, 16000, None, 512, 'A short source still gets 512 tokens.'),
    ('one-and-a-half-below-512', 341, 16000, None, 512, '1.5 × 341 = 511.5 rounds up to 512.'),
    ('one-and-a-half-above-512', 342, 16000, None, 513, '1.5 × 342 = 513.'),
    ('prompt-cap-just-below', 15999, 16000, None, 16000, 'The prompt cap holds the source.'),
    ('prompt-cap-at', 16000, 16000, None, 16000, 'The cap equals the source: allowed.'),
    ('prompt-cap-just-above', 16001, 16000, None, None, 'The cap cannot hold the source.'),
    ('apple-cap-just-below', 1499, 16000, 1500, 1500, 'Apple caps output at 1,500 tokens.'),
    ('apple-cap-at', 1500, 16000, 1500, 1500, 'The cap equals the source.'),
    ('apple-cap-just-above', 1501, 16000, 1500, None, 'One source token too many.'),
    ('local-cap-at', 4096, 16000, 4096, 4096, 'Ollama and LM Studio cap output at 4,096 tokens.'),
    ('local-cap-just-above', 4097, 16000, 4096, None, 'One source token too many.'),
    ('prompt-cap-below-512', 100, 300, None, 300, 'A cap below 512 still binds.'),
]

# (id, context, required, fits, note)
CONTEXTS = [
    ('context-below-512', 511, 1, False, 'A context below 512 tokens fits nothing.'),
    ('context-512-at', 512, 460, True, 'floor(512 × 0.9) = 460.'),
    ('context-512-just-above', 512, 461, False, 'One token too many.'),
    ('fallback-just-below', 4096, 3685, True, 'The 4,096-token fallback: floor(3686.4) = 3686.'),
    ('fallback-at', 4096, 3686, True, 'Needing the whole limit fits.'),
    ('fallback-just-above', 4096, 3687, False, 'One token too many.'),
    ('exact-product-at', 1000, 900, True, '1000 × 0.9 is exactly 900, and needing 900 fits.'),
    ('exact-product-just-above', 1000, 901, False, 'One token too many.'),
    ('cloud-context-at', 128000, 115200, True, 'A 128,000-token context.'),
    ('cloud-context-just-above', 128000, 115201, False, 'One token too many.'),
    ('million-token-context-at', 1000000, 900000, True, 'A 1,000,000-token context.'),
    ('million-token-context-just-above', 1000000, 900001, False, 'One token too many.'),
]

for _, connector, selected, answered, accepted, _ in ANSWERS:
    assert connector in CONNECTORS and valid_model(selected), selected
    assert answered_by(connector, selected, answered) == accepted, (connector, selected, answered)
for _, model, valid, _ in MODELS:
    assert valid_model(model) == valid, ascii(model)
for _, source_tokens, prompt_cap, connector_cap, expected, _ in OUTPUT_CAPS:
    assert max_output_tokens(source_tokens, prompt_cap, connector_cap) == expected, (source_tokens, prompt_cap, connector_cap)
for _, context, required, fits, _ in CONTEXTS:
    assert context_fits(context, required) == fits, (context, required)
for name, rows in (('answers', ANSWERS), ('models', MODELS), ('output caps', OUTPUT_CAPS), ('contexts', CONTEXTS)):
    assert len({row[0] for row in rows}) == len(rows), 'duplicate id in ' + name

document = {
    'version': 1,
    'rules': 'ai.md ' + chr(0xA7) + '12.8: the checks both Voice Lab rewrite sends make, from canned values.',
    'contextSafetyFactor': FACTOR,
    'answeredBy': [{'id': case_id, 'connector': connector, 'selected': selected, 'answered': answered, 'accepted': accepted, 'note': note}
                   for case_id, connector, selected, answered, accepted, note in ANSWERS],
    'modelIds': [{'id': case_id, 'model': model, 'valid': valid, 'note': note} for case_id, model, valid, note in MODELS],
    'outputCaps': [{'id': case_id, 'sourceTokens': source_tokens, 'promptCap': prompt_cap, 'connectorCap': connector_cap,
                    'maxOutputTokens': expected, 'note': note}
                   for case_id, source_tokens, prompt_cap, connector_cap, expected, note in OUTPUT_CAPS],
    'contextResolution': [
        {'id': 'cloud-without-listed-context', 'connector': 'openai', 'model': 'gpt-5.6-terra', 'connectorContext': None,
         'modelContext': None, 'context': 128000, 'sourceWordCount': 1500, 'fits': True},
        {'id': 'local-without-listed-context', 'connector': 'ollama', 'model': 'local', 'connectorContext': None,
         'modelContext': None, 'context': 4096, 'sourceWordCount': 1500, 'fits': False},
        {'id': 'connector-before-metadata', 'connector': 'anthropic', 'model': 'claude-sonnet-5-5', 'connectorContext': 8192,
         'modelContext': 16384, 'context': 8192},
        {'id': 'metadata-before-curated', 'connector': 'anthropic', 'model': 'claude-sonnet-5-5', 'connectorContext': None,
         'modelContext': 16384, 'context': 16384},
        {'id': 'curated-before-default', 'connector': 'anthropic', 'model': 'claude-sonnet-5-5', 'connectorContext': None,
         'modelContext': None, 'context': 1000000},
        {'id': 'cli-default', 'connector': 'codex', 'model': 'default', 'connectorContext': None,
         'modelContext': None, 'context': 128000},
        {'id': 'lmstudio-default', 'connector': 'lmstudio', 'model': 'local', 'connectorContext': None,
         'modelContext': None, 'context': 4096},
    ],
    'contexts': [{'id': case_id, 'context': context, 'required': required, 'fits': fits, 'note': note}
                 for case_id, context, required, fits, note in CONTEXTS],
}
OUT.write_text(json.dumps(document, indent=2) + '\n', encoding='utf-8')
