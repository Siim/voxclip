#!/usr/bin/env python3
"""Write the shared Voice Lab Core contract tables (voice-lab §2.6, §8.9.1).

contract.json was first written by hand with the Mac Voice Lab Core services; this generator reproduces that file
byte for byte and is now its only writer. Each table row is one JSON object on one line, in the order below. The
tables are synthetic: they hold no voice sample, key or provider response. Running the generator twice gives
identical bytes. See shared/fixtures/voice-lab/README.md.
"""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / 'shared/fixtures/voice-lab/contract.json'

TABLES = {
    'voiceChoices': [
        {'category': 'premade', 'owner': False, 'choice': 'stock', 'allowed': True},
        {'category': 'generated', 'owner': True, 'choice': 'stock', 'allowed': True},
        {'category': 'generated', 'owner': False, 'choice': 'stock', 'allowed': False},
        {'category': 'cloned', 'owner': True, 'choice': 'stock', 'allowed': False},
        {'category': 'professional', 'owner': True, 'choice': 'stock', 'allowed': False},
        {'category': 'famous', 'owner': False, 'choice': 'stock', 'allowed': False},
        {'category': 'future_category', 'owner': False, 'choice': 'stock', 'allowed': False},
        {'category': 'cloned', 'owner': True, 'choice': 'own', 'allowed': True},
        {'category': 'cloned', 'owner': True, 'choice': 'own_inactive', 'allowed': False},
        {'category': 'cloned', 'owner': True, 'choice': 'own_unverified', 'allowed': False},
    ],
    'quoteMutations': [
        {'field': 'text', 'value': 'Changed words', 'allowed': False},
        {'field': 'model', 'value': 'other_model', 'allowed': False},
        {'field': 'voice', 'value': 'other_voice', 'allowed': False},
        {'field': 'region', 'value': 'us', 'allowed': False},
        {'field': 'language', 'value': 'et', 'allowed': False},
        {'field': 'consentRecord', 'value': 'other_record', 'allowed': False},
        {'field': 'audioByte', 'value': '01', 'allowed': False},
        {'field': 'estimate', 'value': 'changed_units', 'allowed': False},
        {'field': 'same', 'value': 'unchanged', 'allowed': True},
    ],
    'rewriteMutations': [
        {'field': 'scope', 'allowed': False},
        {'field': 'sourceText', 'allowed': False},
        {'field': 'sourceTiming', 'allowed': False},
        {'field': 'instruction', 'allowed': False},
        {'field': 'language', 'allowed': False},
        {'field': 'connector', 'allowed': False},
        {'field': 'model', 'allowed': False},
        # ADR-R30 length budget (voice-lab §8.9.1): a changed budget needs a new quote and approval.
        {'field': 'targetSeconds', 'allowed': False},
        {'field': 'minChars', 'allowed': False},
        {'field': 'maxChars', 'allowed': False},
        {'field': 'same', 'allowed': True},
    ],
    'replay': [
        {'event': 'first_send', 'billableSends': 1},
        {'event': 'sequential_replay', 'billableSends': 1},
        {'event': 'concurrent_duplicate', 'billableSends': 1},
        {'event': '429_then_same_quote', 'billableSends': 1},
        {'event': 'network_loss_then_same_quote', 'billableSends': 1},
        {'event': 'invalid_reply_then_same_quote', 'billableSends': 1},
        {'event': 'new_quote_after_failure', 'billableSends': 2},
    ],
    'discovery': [
        {'event': 'duplicate_model_id', 'error': 'malformedResponse'},
        {'event': 'duplicate_voice_id_same_page', 'error': 'malformedResponse'},
        {'event': 'duplicate_voice_id_next_page', 'error': 'malformedResponse'},
        {'event': 'repeated_cursor', 'error': 'malformedResponse'},
        {'event': 'page_21', 'error': 'responseTooLarge'},
    ],
    'audio': [
        {'prefixHex': 'ffff', 'format': 'pcm16le', 'valid': True},
        {'prefixHex': 'fff3', 'format': 'pcm16le', 'valid': True},
        {'prefixHex': '52494646', 'format': 'pcm16le_without_wave_container', 'valid': True},
        {'prefixHex': '52494646', 'format': 'riff_wave_container', 'valid': False},
        {'prefixHex': '494433', 'format': 'id3_container', 'valid': False},
        {'prefixHex': 'fffb9064', 'format': 'two_mp3_frames', 'valid': False},
        {'prefixHex': '0000001866747970', 'format': 'mp4_container', 'valid': False},
        {'prefixHex': '00', 'format': 'odd_pcm_length', 'valid': False},
    ],
    'conversionInputs': [
        {'case': 'canonical', 'valid': True},
        {'case': 'ordinary_ancillary', 'ancillary': True, 'valid': True},
        {'case': 'pcm_fmt_18', 'mutation': 'fmt18', 'valid': True},
        {'case': 'data_before_fmt', 'mutation': 'dataBeforeFmt', 'valid': True},
        {'case': 'nonzero_index_canonical', 'slice': True, 'valid': True},
        {'case': 'nonzero_index_ancillary', 'ancillary': True, 'slice': True, 'valid': True},
        {'case': 'riff_size_short', 'mutation': 'riffShort', 'valid': False},
        {'case': 'riff_size_long', 'mutation': 'riffLong', 'valid': False},
        {'case': 'truncated_file', 'mutation': 'truncateFile', 'valid': False},
        {'case': 'truncated_chunk', 'mutation': 'truncatedChunk', 'valid': False},
        {'case': 'overflow_chunk', 'mutation': 'overflowChunk', 'valid': False},
        {'case': 'missing_odd_padding', 'mutation': 'missingPad', 'valid': False},
        {'case': 'duplicate_fmt', 'mutation': 'duplicateFmt', 'valid': False},
        {'case': 'duplicate_data', 'mutation': 'duplicateData', 'valid': False},
        {'case': 'missing_fmt', 'mutation': 'missingFmt', 'valid': False},
        {'case': 'missing_data', 'mutation': 'missingData', 'valid': False},
        {'case': 'float_format', 'mutation': 'floatFormat', 'valid': False},
        {'case': 'stereo', 'mutation': 'stereo', 'valid': False},
        {'case': 'pcm8', 'mutation': 'pcm8', 'valid': False},
        {'case': 'rate_below_8k', 'rate': 7999, 'valid': False},
        {'case': 'rate_above_96k', 'rate': 96001, 'valid': False},
        {'case': 'wrong_block_align', 'mutation': 'badAlign', 'valid': False},
        {'case': 'wrong_byte_rate', 'mutation': 'badByteRate', 'valid': False},
        {'case': 'odd_pcm_payload', 'mutation': 'oddPayload', 'valid': False},
        {'case': 'empty_pcm_payload', 'frames': 0, 'valid': False},
        {'case': 'under_20ms', 'frames': 479, 'valid': False},
        {'case': 'exact_20ms', 'frames': 480, 'valid': True},
        {'case': 'under_20ms_nonround_rate', 'rate': 8001, 'frames': 160, 'valid': False},
        {'case': 'at_least_20ms_nonround_rate', 'rate': 8001, 'frames': 161, 'valid': True},
        {'case': 'exact_290s', 'rate': 8000, 'frames': 2320000, 'valid': True},
        {'case': 'over_290s', 'rate': 8000, 'frames': 2320001, 'valid': False},
    ],
}


def row(values):
    return '{ ' + ', '.join(f'{json.dumps(key)}: {json.dumps(value)}' for key, value in values.items()) + ' }'


lines = ['{', '  "version": 1,']
for index, (name, rows) in enumerate(TABLES.items()):
    lines.append(f'  {json.dumps(name)}: [')
    lines += ['    ' + row(item) + (',' if position < len(rows) - 1 else '') for position, item in enumerate(rows)]
    lines.append('  ]' + (',' if index < len(TABLES) - 1 else ''))
lines.append('}')
text = '\n'.join(lines) + '\n'
assert json.loads(text) == {'version': 1, **TABLES}
OUT.write_text(text, encoding='utf-8')
