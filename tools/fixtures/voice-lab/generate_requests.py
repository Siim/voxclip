#!/usr/bin/env python3
"""Write synthetic Voice Lab request cases (voice-lab §6.5, §6.7, §7.3, §8.5 and §15 test 12).

Every WAV is built from parameters, never from a recorded voice. See
shared/fixtures/voice-lab/request-cases-README.md for the construction rules.
Non-ASCII text is built with chr() so precomposed and decomposed forms stay explicit.
"""
import hashlib
import json
import struct
import unicodedata
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / 'shared/fixtures/voice-lab/request-cases.json'

A_UMLAUT, O_TILDE_CAPITAL, U_UMLAUT, COMBINING_DIAERESIS = chr(0xE4), chr(0xD5), chr(0xFC), chr(0x308)
NO_BREAK_SPACE, THIN_SPACE, IDEOGRAPHIC_SPACE, LINE_SEPARATOR = chr(0xA0), chr(0x2009), chr(0x3000), chr(0x2028)
ZERO_WIDTH_SPACE, UNIT_SEPARATOR = chr(0x200B), chr(0x1F)  # not Unicode White_Space
NEXT_LINE = chr(0x85)
MICROPHONE = chr(0x1F399) + chr(0xFE0F)  # an astral scalar and a variation selector
# Unicode White_Space (PropList.txt). str.isspace() differs: it also accepts U+001C to U+001F.
WHITE_SPACE = frozenset([*range(0x09, 0x0E), 0x20, 0x85, 0xA0, 0x1680, *range(0x2000, 0x200B),
                         0x2028, 0x2029, 0x202F, 0x205F, 0x3000])
assert len(WHITE_SPACE) == 25
# General Category Cc, which Unicode never changes: C0 controls, DEL and C1 controls.
CONTROL = frozenset([*range(0x00, 0x20), *range(0x7F, 0xA0)])
assert CONTROL == {value for value in range(0x110000) if unicodedata.category(chr(value)) == 'Cc'}


def wav(rate, frames, fill=0, junkBytes=0, mutation=None, **_):
    """Mono PCM16 RIFF/WAVE: an optional zero JUNK chunk, fmt, then data holding `fill` in every sample."""
    chunks = b''
    if junkBytes:
        chunks += b'JUNK' + struct.pack('<I', junkBytes) + bytes(junkBytes + junkBytes % 2)
    fmt = struct.pack('<HHIIHH', 1, 2 if mutation == 'stereo' else 1, rate, rate * 2, 2, 16)
    chunks += b'fmt ' + struct.pack('<I', len(fmt)) + fmt
    chunks += b'data' + struct.pack('<I', frames * 2) + struct.pack('<h', fill) * frames
    return b'RIFF' + struct.pack('<I', 4 + len(chunks)) + b'WAVE' + chunks


def sha256(spec):
    return hashlib.sha256(wav(**spec)).hexdigest()


def space(character):
    return ord(character) in WHITE_SPACE


def trim(text):
    start, end = 0, len(text)
    while start < end and space(text[start]):
        start += 1
    while end > start and space(text[end - 1]):
        end -= 1
    return text[start:end]


def display_name_valid(name):
    """§6.1: 1 to 60 Unicode scalars after trimming White_Space, with no control character left in the name."""
    name = trim(name)
    return 1 <= len(name) <= 60 and not any(ord(character) in CONTROL for character in name)


def extends(character):
    """Combining marks (General Category M), ZWJ and variation selectors extend the cluster before them."""
    value = ord(character)
    return (unicodedata.category(character).startswith('M') or value == 0x200D or 0xFE00 <= value <= 0xFE0F
            or 0xE0100 <= value <= 0xE01EF)


def splits(text, index):
    """A cut before text[index] splits a cluster when that scalar extends one or follows a ZWJ."""
    return extends(text[index]) or ord(text[index - 1]) == 0x200D


def context(text, previous):
    """§8.5: trim White_Space and keep the last (previous) or first (next) 300 scalars. If they hold White_Space, a
    word split by the cut is dropped first. Then the cut moves until it splits no cluster: previous text drops orphaned
    marks and joiners, next text drops a partial cluster back to its base."""
    if text is None:
        return None
    text = trim(text)
    if len(text) > 300:
        start, end = (len(text) - 300, len(text)) if previous else (0, 300)
        if any(space(character) for character in text[start:end]):
            if previous and not space(text[start - 1]):
                while start < end and not space(text[start]):
                    start += 1
            if not previous and not space(text[end]):
                while end > start and not space(text[end - 1]):
                    end -= 1
        if previous:
            while start < end and splits(text, start):
                start += 1
        else:
            while end > start and splits(text, end):
                end -= 1
        text = text[start:end]
    return text or None


def created(text):
    return datetime.fromisoformat(text).astimezone(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


def sample(role, frames, rate=8000, **extra):
    return {'role': role, 'rate': rate, 'frames': frames, **extra}


FIVE = 40_000  # five seconds at 8 kHz


def consent(frames=FIVE, **extra):
    return sample('consentStatement', frames, **extra)


def training(frames=FIVE, **extra):
    return sample('training', frames, **extra)


CLONE_DEFAULTS = {'displayName': 'Mari Maasikas', 'language': 'et', 'createdAt': '2026-10-26T09:15:42Z',
                  'removeBackgroundNoise': False}


def clone_input(case, valid, samples, **overrides):
    return {'case': case, 'valid': valid, **overrides, 'samples': samples}


CLONE_INPUTS = [
    clone_input('two_five_second_files', True, [consent(), training(fill=1)]),
    clone_input('one_ten_second_file', True, [consent(80_000)]),
    clone_input('one_file_under_ten_seconds', False, [consent(79_999)]),
    clone_input('file_under_five_seconds', False, [consent(), training(39_999)]),
    clone_input('file_at_thirty_seconds', True, [consent(240_000), training()]),
    clone_input('file_over_thirty_seconds', False, [consent(240_001), training()]),
    clone_input('twenty_five_files', True, [consent(), training(count=24)]),
    clone_input('twenty_six_files', False, [consent(), training(count=25)]),
    clone_input('total_240_seconds', True, [consent(240_000), training(240_000, count=7)]),
    clone_input('total_over_240_seconds', False, [consent(240_000), training(240_000, count=7), training()]),
    clone_input('no_samples', False, []),
    clone_input('no_consent_statement', False, [training(), training(fill=1)]),
    clone_input('two_consent_statements', False, [consent(), consent(fill=1)]),
    clone_input('consent_after_training', True, [training(), consent(fill=1)]),
    clone_input('mixed_sample_rates', True, [consent(480_000, rate=96_000), training(220_500, rate=44_100)]),
    clone_input('stereo_sample', False, [consent(), training(mutation='stereo')]),
    clone_input('rate_below_8k', False, [consent(), training(39_995, rate=7_999)]),
    clone_input('file_over_16_mib', False, [consent(), training(junkBytes=16 * 1024 * 1024)]),
    clone_input('language_three_letters', True, [consent(), training()], language='est'),
    clone_input('language_uppercase', False, [consent(), training()], language='ET'),
    clone_input('language_four_letters', False, [consent(), training()], language='eest'),
    clone_input('language_trailing_newline', False, [consent(), training()], language='et\n'),
    clone_input('display_name_padded', True, [consent(), training()], displayName='  Mari  '),
    clone_input('display_name_blank', False, [consent(), training()], displayName=' \t '),
    clone_input('display_name_line_break', False, [consent(), training()], displayName='Mari\nMaasikas'),
    clone_input('display_name_trailing_line_break', True, [consent(), training()], displayName='Mari\n'),
    clone_input('display_name_60_scalars', True, [consent(), training()], displayName=A_UMLAUT * 60),
    clone_input('display_name_60_decomposed_scalars', True, [consent(), training()],
                displayName=('a' + COMBINING_DIAERESIS) * 30),
    clone_input('display_name_61_decomposed_scalars', False, [consent(), training()],
                displayName=('a' + COMBINING_DIAERESIS) * 30 + 'a'),
    clone_input('display_name_zero_width_space', True, [consent(), training()], displayName=ZERO_WIDTH_SPACE),
    clone_input('display_name_unicode_white_space_only', False, [consent(), training()],
                displayName=NEXT_LINE + IDEOGRAPHIC_SPACE + LINE_SEPARATOR),
    # A control character (General Category Cc) left anywhere in the trimmed name is refused; trimming runs first.
    clone_input('display_name_unit_separator', False, [consent(), training()], displayName=UNIT_SEPARATOR),
    clone_input('display_name_null', False, [consent(), training()], displayName='Mari' + chr(0x00) + 'Maasikas'),
    clone_input('display_name_tab_inside', False, [consent(), training()], displayName='Mari\tMaasikas'),
    clone_input('display_name_delete', False, [consent(), training()], displayName='Mari' + chr(0x7F)),
    clone_input('display_name_c1_first', False, [consent(), training()], displayName=chr(0x80) + 'Mari'),
    clone_input('display_name_next_line_inside', False, [consent(), training()],
                displayName='Mari' + NEXT_LINE + 'Maasikas'),
    clone_input('display_name_c1_last', False, [consent(), training()], displayName='Mari' + chr(0x9F)),
    clone_input('display_name_no_break_space_inside', True, [consent(), training()],
                displayName='Mari' + NO_BREAK_SPACE + 'Maasikas'),
    clone_input('created_at_epoch', True, [consent(), training()], createdAt='1970-01-01T00:00:00Z'),
    clone_input('created_before_epoch', False, [consent(), training()], createdAt='1969-12-31T23:59:59Z'),
    clone_input('created_last_second_of_9999', True, [consent(), training()], createdAt='9999-12-31T23:59:59Z'),
]
assert all(row['valid'] == display_name_valid(row['displayName']) for row in CLONE_INPUTS if 'displayName' in row)

VOICE_ID = 'voice123'
DISCOVERY = {
    'models': [
        {'model_id': 'eleven_v3', 'name': 'Eleven v3', 'can_do_text_to_speech': True, 'can_do_voice_conversion': False,
         'languages': [{'language_id': 'en'}, {'language_id': 'et'}, {'language_id': 'ja'}, {'language_id': 'th'}]},
        {'model_id': 'eleven_multilingual_v2', 'name': 'Eleven Multilingual v2', 'can_do_text_to_speech': True,
         'can_do_voice_conversion': False, 'languages': [{'language_id': 'en'}]},
        {'model_id': 'eleven_multilingual_sts_v2', 'name': 'Eleven Multilingual v2 STS', 'can_do_text_to_speech': False,
         'can_do_voice_conversion': True, 'languages': [{'language_id': 'en'}]},
    ],
    'voices': {'voices': [{'voice_id': VOICE_ID, 'name': 'Fixture voice', 'category': 'premade'}], 'has_more': False},
    'subscription': {'tier': 'starter', 'status': 'active', 'character_count': 0, 'character_limit': 10000,
                     'can_use_instant_voice_cloning': True, 'voice_slots_used': 0, 'voice_limit': 10},
}
# Consumers fix the multipart boundary to this value, so whole request bodies compare byte for byte.
BOUNDARY = 'voxclip-0123456789abcdef0123456789abcdef'
MULTIPART = {'xi-api-key': '[REDACTED]', 'content-type': f'multipart/form-data; boundary="{BOUNDARY}"'}
JSON = {'xi-api-key': '[REDACTED]', 'content-type': 'application/json'}


def text_part(name, value):
    return {'headers': [f'Content-Disposition: form-data; name="{name}"'], 'value': value}, value.encode()


def file_part(name, filename, spec):
    data = wav(**spec)
    return {'headers': [f'Content-Disposition: form-data; name="{name}"; filename="{filename}"', 'Content-Type: audio/wav'],
            'sha256': hashlib.sha256(data).hexdigest()}, data


def multipart_request(path, query, parts):
    """Frames the parts as both Cores do: '--' BOUNDARY CRLF, each header line and CRLF, CRLF, bytes, CRLF; then the closing line."""
    body = b''
    for golden, data in parts:
        head = ''.join(line + '\r\n' for line in golden['headers'])
        body += b'--' + BOUNDARY.encode() + b'\r\n' + head.encode() + b'\r\n' + data + b'\r\n'
    body += b'--' + BOUNDARY.encode() + b'--\r\n'
    return {'method': 'POST', 'path': path, 'query': query, 'headers': MULTIPART, 'multipart': [golden for golden, _ in parts],
            'bodyLength': len(body), 'bodySha256': hashlib.sha256(body).hexdigest()}


def clone_request(source):
    assert display_name_valid(source['displayName'])
    consent_sample = next(item for item in source['samples'] if item['role'] == 'consentStatement')
    parts = [text_part('name', trim(source['displayName']) + ' (VoxClip)'),
             file_part('files', 'consent-statement.wav', consent_sample)]
    parts += [file_part('files', f'sample-{index + 2:02d}.wav', item)
              for index, item in enumerate(item for item in source['samples'] if item['role'] == 'training')]
    parts += [text_part('remove_background_noise', 'true' if source['removeBackgroundNoise'] else 'false'),
              text_part('description', f'VoxClip own-voice clone. Consent sha256:{sha256(consent_sample)}. '
                                       f'Created {created(source["createdAt"])}.'),
              text_part('labels', json.dumps({'language': source['language']}, separators=(',', ':')))]
    return multipart_request('/v1/voices/add', {}, parts)


def speech_request(source):
    body = {'text': source['text'], 'model_id': source['modelId']}
    if source['modelId'] != 'eleven_multilingual_v2':
        body['language_code'] = source['language']
    body['voice_settings'] = {'stability': 0.5, 'similarity_boost': 0.8}
    body['seed'] = source['seed']
    for key, field, previous in [('previousText', 'previous_text', True), ('nextText', 'next_text', False)]:
        value = context(source.get(key), previous)
        if value is not None:
            body[field] = value
    body['apply_text_normalization'] = 'auto'
    return {'method': 'POST', 'path': f'/v1/text-to-speech/{source["voiceId"]}/with-timestamps',
            'query': {'output_format': 'pcm_24000'}, 'headers': JSON, 'json': body}


def conversion_request(source):
    return multipart_request(f'/v1/voice-changer/{source["voiceId"]}', {'output_format': 'pcm_24000'},
                             [file_part('audio', 'audio.wav', source['audio']), text_part('model_id', source['modelId']),
                              text_part('voice_settings', '{"stability":0.5,"similarity_boost":0.75}'),
                              text_part('seed', str(source['seed'])),
                              text_part('remove_background_noise', 'false' if source['cleanAudioOn'] else 'true')])


BUILD = {'createClone': clone_request, 'textToSpeech': speech_request, 'voiceChange': conversion_request}


def case(name, operation, source):
    return {'case': name, 'operation': operation, 'input': source, 'request': BUILD[operation](source)}


def speech(text, model, language, seed, **context_fields):
    return {'voiceId': VOICE_ID, 'modelId': model, 'language': language, 'text': text, 'seed': seed, **context_fields}


# A word split at each cut is dropped: the kept previous text starts and the kept next text ends with White_Space.
SPLIT_BODY = (('T' + A_UMLAUT + 'na' + NO_BREAK_SPACE + 'on ' + MICROPHONE + ' ilus' + IDEOGRAPHIC_SPACE + 'p' + A_UMLAUT
               + 'ev' + THIN_SPACE + 'ja ') * 20)[:291] + '.'
SPLIT_NEXT_BODY = (('Homme j' + A_UMLAUT + 'tkame ' + MICROPHONE + ' salvestust' + NO_BREAK_SPACE + 'ja ') * 20)[:289] + '!'
SPLIT_PREVIOUS = IDEOGRAPHIC_SPACE + ' Sissejuhatus pikksonaline ' + SPLIT_BODY + ' \n'
SPLIT_NEXT = '\t' + SPLIT_NEXT_BODY + ' viimaneSona lisa' + IDEOGRAPHIC_SPACE
# The cut falls beside White_Space, so nothing is dropped and the White_Space at the cut stays.
BESIDE_PREVIOUS = 'Algus' + IDEOGRAPHIC_SPACE + ('sona ' * 60)[:298] + 'x'
BESIDE_NEXT = 'w' * 299 + THIN_SPACE + 'tail'
# The previous cut falls just after a space; the next text is exactly 300 scalars once trimmed.
WORD_START_PREVIOUS = 'Algus ' + ('sona ' * 60)[:299] + 'x'
EXACT_NEXT = LINE_SEPARATOR + ('kolmsada ' * 34)[:299] + 'z '


def scalars(*values):
    return ''.join(map(chr, values))


# A cut that splits a cluster moves: previous text drops orphaned marks and joiners, next text drops the partial
# cluster back to its base. These windows hold no White_Space, except where noted.
COMBINING_TILDE, VOICED_SOUND_MARK, ZERO_WIDTH_JOINER = chr(0x303), chr(0x3099), chr(0x200D)
JAPANESE = scalars(0x3053, 0x308C, 0x306F, 0x65E5, 0x672C, 0x8A9E, 0x306E, 0x6587, 0x7AE0, 0x3067, 0x3059, 0x3002)
JAPANESE_REST = (JAPANESE * 25)[:299]
JAPANESE_PREVIOUS = JAPANESE * 3 + chr(0x304B) + VOICED_SOUND_MARK + JAPANESE_REST  # the cut leaves the voiced mark first
JAPANESE_NEXT = (JAPANESE * 26)[:310]
# THAI starts with the cluster THO THAHAN, SARA II, MAI EK. Each pair of offsets puts both cuts beside that cluster,
# just after its base, or between its two marks.
THAI = scalars(0x0E17, 0x0E35, 0x0E48, 0x0E1A, 0x0E49, 0x0E32, 0x0E19, 0x0E21, 0x0E35, 0x0E19, 0x0E49, 0x0E33)
THAI_HELLO = scalars(0x0E2A, 0x0E27, 0x0E31, 0x0E2A, 0x0E14, 0x0E35, 0x0E04, 0x0E23, 0x0E31, 0x0E1A)
THAI_KEPT = (THAI[6:] + THAI * 25, THAI[3:] + THAI * 26)
THAI_AFTER_BASE = (THAI * 26 + THAI[:1], THAI[1:] + THAI * 26)
THAI_BETWEEN_MARKS = (THAI * 26 + THAI[:2], THAI[2:] + THAI * 26)
COUPLE = scalars(0x1F469, 0x200D, 0x2764, 0xFE0F, 0x200D, 0x1F468)  # woman, ZWJ, heart, VS16, ZWJ, man
EMOJI_AFTER_ZWJ = (COUPLE * 55 + MICROPHONE, MICROPHONE * 2 + COUPLE * 55)  # each cut falls just after a ZWJ
EMOJI_BEFORE_ZWJ = (COUPLE * 55 + MICROPHONE * 2, MICROPHONE + COUPLE * 55)  # each cut falls just before a ZWJ
PLACES = ['Tallinn', 'Pa' + COMBINING_DIAERESIS + 'rnu', 'Vo' + COMBINING_TILDE + 'ru', 'Po' + COMBINING_TILDE + 'lva',
          'Jo' + COMBINING_TILDE + 'geva', 'Tu' + COMBINING_DIAERESIS + 'ri', 'Valga', 'Ra' + COMBINING_DIAERESIS + 'pina']
ROUTE = '-'.join(PLACES * 8)
ROUTE_CUT = next(index for index in range(10, len(ROUTE)) if ROUTE[index] == COMBINING_DIAERESIS)
ESTONIAN_PREVIOUS = ROUTE[:ROUTE_CUT + 300]  # one hyphenated route; the cut leaves a mark first
VOWEL_PREVIOUS = ROUTE[:ROUTE_CUT - 1 + 300]  # the cut falls before a decomposed vowel, which stays whole
TILDE_CUT = next(index for index in range(300, len(ROUTE)) if ROUTE[index] == COMBINING_TILDE)
VOWEL_NEXT = ROUTE[TILDE_CUT - 300:]  # the cut falls between o and U+0303, so the o is dropped too
WINTER = ('Talvel on ja' + COMBINING_DIAERESIS + 'a' + COMBINING_DIAERESIS + ' ja o' + COMBINING_DIAERESIS + 'o'
          + COMBINING_DIAERESIS + ' pikk ') * 12
WINTER_CUT = next(index for index in range(300, len(WINTER)) if WINTER[index] == ' '
                  and WINTER[index - 1] == COMBINING_DIAERESIS and WINTER[index - 300] != ' ')
ESTONIAN_NEXT = trim(WINTER[WINTER_CUT - 300:WINTER_CUT + 20])  # White_Space: no word is split and the final vowel stays
# Both windows hold White_Space and neither cut splits a word, but each splits a cluster: a mark follows a space before
# the previous cut, and a ZWJ ends the next window. The clean-cut rule still moves both cuts.
ORPHAN_PREVIOUS = 'x' * 10 + ' ' + COMBINING_DIAERESIS + ('sona ' * 60)[:299]
JOINER_NEXT = 'w ' + 'w' * 297 + ZERO_WIDTH_JOINER + ' tail'

CASES = [
    case('clone_estonian_caller_order', 'createClone', {
        'displayName': '  Mari ' + O_TILDE_CAPITAL + 'unapuu ', 'language': 'et',
        'createdAt': '2026-10-26T12:15:42.750+03:00', 'removeBackgroundNoise': False,
        'samples': [training(120_000, rate=24_000, fill=3), consent(96_000, rate=16_000, fill=1), training(56_000, fill=-2)]}),
    case('clone_english_single_file_noise_removal', 'createClone', {
        'displayName': 'Alex Example', 'language': 'en', 'createdAt': '2026-10-26T09:15:42Z',
        'removeBackgroundNoise': True, 'samples': [consent(441_000, rate=44_100)]}),
    case('clone_nine_training_samples', 'createClone', {
        'displayName': 'Kai', 'language': 'fil', 'createdAt': '2026-01-02T03:04:05.999Z', 'removeBackgroundNoise': False,
        'samples': [consent()] + [training(fill=number) for number in range(1, 10)]}),
    # Trimming removes the space and U+0085 but keeps U+200B, which is not White_Space.
    case('clone_name_keeps_zero_width_space', 'createClone', {
        'displayName': ' ' + ZERO_WIDTH_SPACE + 'Mari' + ZERO_WIDTH_SPACE + NEXT_LINE, 'language': 'et',
        'createdAt': '2026-10-26T09:15:42Z', 'removeBackgroundNoise': False, 'samples': [consent(80_000)]}),
    case('tts_v3_split_words_dropped', 'textToSpeech', speech(
        'T' + A_UMLAUT + 'na on ilus p' + A_UMLAUT + 'ev.', 'eleven_v3', 'et', 4_294_967_295,
        previousText=SPLIT_PREVIOUS, nextText=SPLIT_NEXT)),
    case('tts_v3_cut_beside_white_space', 'textToSpeech', speech(
        'Right beside a space.', 'eleven_v3', 'en', 1, previousText=BESIDE_PREVIOUS, nextText=BESIDE_NEXT)),
    case('tts_v3_cut_at_word_start', 'textToSpeech', speech(
        'Sona algab siit.', 'eleven_v3', 'et', 2, previousText=WORD_START_PREVIOUS, nextText=EXACT_NEXT)),
    case('tts_multilingual_v2_omitted_context', 'textToSpeech', speech(
        'Hello there.', 'eleven_multilingual_v2', 'en', 0,
        nextText=' ' + IDEOGRAPHIC_SPACE + '\t' + LINE_SEPARATOR + ' ')),
    case('tts_v3_unbroken_long_word', 'textToSpeech', speech(
        'Lause.', 'eleven_v3', 'et', 42, previousText='a' * 200 + ZERO_WIDTH_SPACE + 'b' * 150,
        nextText='L' + U_UMLAUT + 'hike' + UNIT_SEPARATOR + 'j' + A_UMLAUT + 'tk.' + UNIT_SEPARATOR + ' ')),
    case('tts_v3_japanese_scalar_cut', 'textToSpeech', speech(
        scalars(0x30C6, 0x30B9, 0x30C8, 0x3067, 0x3059, 0x3002), 'eleven_v3', 'ja', 7,
        previousText=JAPANESE_PREVIOUS, nextText=JAPANESE_NEXT)),
    case('tts_v3_thai_cluster_kept', 'textToSpeech', speech(
        THAI_HELLO, 'eleven_v3', 'th', 8, previousText=THAI_KEPT[0], nextText=THAI_KEPT[1])),
    case('tts_v3_thai_cluster_split_after_base', 'textToSpeech', speech(
        THAI_HELLO, 'eleven_v3', 'th', 11, previousText=THAI_AFTER_BASE[0], nextText=THAI_AFTER_BASE[1])),
    case('tts_v3_thai_cluster_split_between_marks', 'textToSpeech', speech(
        THAI_HELLO, 'eleven_v3', 'th', 12, previousText=THAI_BETWEEN_MARKS[0], nextText=THAI_BETWEEN_MARKS[1])),
    case('tts_v3_emoji_split_after_zwj', 'textToSpeech', speech(
        'Love wins.', 'eleven_v3', 'en', 9, previousText=EMOJI_AFTER_ZWJ[0], nextText=EMOJI_AFTER_ZWJ[1])),
    case('tts_v3_emoji_split_before_zwj', 'textToSpeech', speech(
        'Love stays.', 'eleven_v3', 'en', 13, previousText=EMOJI_BEFORE_ZWJ[0], nextText=EMOJI_BEFORE_ZWJ[1])),
    case('tts_v3_estonian_marks_at_cut', 'textToSpeech', speech(
        'Tere o' + COMBINING_TILDE + 'htust.', 'eleven_v3', 'et', 10, previousText=ESTONIAN_PREVIOUS, nextText=ESTONIAN_NEXT)),
    case('tts_v3_estonian_vowel_cut', 'textToSpeech', speech(
        'Ja' + COMBINING_DIAERESIS + 'rgmine peatus.', 'eleven_v3', 'et', 14, previousText=VOWEL_PREVIOUS, nextText=VOWEL_NEXT)),
    case('tts_v3_clean_cut_after_word_rule', 'textToSpeech', speech(
        'Puhas.', 'eleven_v3', 'et', 15, previousText=ORPHAN_PREVIOUS, nextText=JOINER_NEXT)),
    # At most 300 scalars once trimmed, so neither step runs: a leading mark and a final ZWJ are sent.
    case('tts_v3_short_context_sent_as_trimmed', 'textToSpeech', speech(
        'L' + U_UMLAUT + 'hike.', 'eleven_v3', 'et', 16, previousText=IDEOGRAPHIC_SPACE + COMBINING_DIAERESIS + 'Tere',
        nextText='Tere' + ZERO_WIDTH_JOINER + NEXT_LINE)),
    case('voice_changer_clean_audio_off', 'voiceChange', {
        'voiceId': VOICE_ID, 'modelId': 'eleven_multilingual_sts_v2', 'language': 'en', 'seed': 123_456_789,
        'cleanAudioOn': False, 'audio': {'rate': 24_000, 'frames': 2_400, 'fill': 5}}),
    case('voice_changer_clean_audio_on', 'voiceChange', {
        'voiceId': VOICE_ID, 'modelId': 'eleven_multilingual_sts_v2', 'language': 'en', 'seed': 4_294_967_295,
        'cleanAudioOn': True, 'audio': {'rate': 48_000, 'frames': 4_800, 'fill': -7}}),
]

names = {item['case']: item['request']['multipart'][0]['value'] for item in CASES if item['operation'] == 'createClone'}
assert names['clone_name_keeps_zero_width_space'] == ZERO_WIDTH_SPACE + 'Mari' + ZERO_WIDTH_SPACE + ' (VoxClip)'
bodies = {item['case']: item['request'].get('json', {}) for item in CASES}
assert bodies['tts_v3_split_words_dropped']['previous_text'] == ' ' + SPLIT_BODY
assert bodies['tts_v3_split_words_dropped']['next_text'] == SPLIT_NEXT_BODY + ' '
assert bodies['tts_v3_cut_beside_white_space']['previous_text'][0] == IDEOGRAPHIC_SPACE
assert bodies['tts_v3_cut_beside_white_space']['next_text'] == 'w' * 299 + THIN_SPACE
assert bodies['tts_v3_cut_at_word_start']['previous_text'] == WORD_START_PREVIOUS[6:]
assert len(bodies['tts_v3_cut_at_word_start']['next_text']) == 300
assert 'previous_text' not in bodies['tts_multilingual_v2_omitted_context']
assert 'next_text' not in bodies['tts_multilingual_v2_omitted_context']
assert bodies['tts_v3_unbroken_long_word']['previous_text'] == 'a' * 149 + ZERO_WIDTH_SPACE + 'b' * 150
assert bodies['tts_v3_unbroken_long_word']['next_text'][-1] == UNIT_SEPARATOR
assert bodies['tts_v3_japanese_scalar_cut']['previous_text'] == JAPANESE_REST
assert bodies['tts_v3_japanese_scalar_cut']['next_text'] == JAPANESE_NEXT[:300]
assert bodies['tts_v3_thai_cluster_kept']['previous_text'] == THAI * 25
assert bodies['tts_v3_thai_cluster_kept']['next_text'] == THAI[3:] + THAI * 24 + THAI[:3]
assert bodies['tts_v3_thai_cluster_split_after_base']['previous_text'] == THAI[3:] + THAI * 24 + THAI[:1]
assert bodies['tts_v3_thai_cluster_split_after_base']['next_text'] == THAI[1:] + THAI * 24
assert bodies['tts_v3_thai_cluster_split_between_marks']['previous_text'] == THAI[3:] + THAI * 24 + THAI[:2]
assert bodies['tts_v3_thai_cluster_split_between_marks']['next_text'] == THAI[2:] + THAI * 24
assert bodies['tts_v3_emoji_split_after_zwj']['previous_text'] == COUPLE * 49 + MICROPHONE
assert bodies['tts_v3_emoji_split_after_zwj']['next_text'] == MICROPHONE * 2 + COUPLE * 49
assert bodies['tts_v3_emoji_split_before_zwj']['previous_text'] == COUPLE * 49 + MICROPHONE * 2
assert bodies['tts_v3_emoji_split_before_zwj']['next_text'] == MICROPHONE + COUPLE * 49
assert ESTONIAN_PREVIOUS[-300] == COMBINING_DIAERESIS and not any(map(space, ESTONIAN_PREVIOUS))
assert bodies['tts_v3_estonian_marks_at_cut']['previous_text'] == ESTONIAN_PREVIOUS[-299:]
assert bodies['tts_v3_estonian_marks_at_cut']['next_text'] == ESTONIAN_NEXT[:300]
assert ESTONIAN_NEXT[299] == COMBINING_DIAERESIS and ESTONIAN_NEXT[300] == ' '
assert VOWEL_PREVIOUS[-300] == 'a' and VOWEL_PREVIOUS[-299] == COMBINING_DIAERESIS and not extends(VOWEL_NEXT[0])
assert bodies['tts_v3_estonian_vowel_cut']['previous_text'] == VOWEL_PREVIOUS[-300:]
assert bodies['tts_v3_estonian_vowel_cut']['next_text'] == VOWEL_NEXT[:299] and VOWEL_NEXT[299] == 'o'
assert not any(map(space, VOWEL_PREVIOUS[-300:] + VOWEL_NEXT[:300]))
assert bodies['tts_v3_clean_cut_after_word_rule']['previous_text'] == ('sona ' * 60)[:299]
assert bodies['tts_v3_clean_cut_after_word_rule']['next_text'] == 'w ' + 'w' * 296
assert bodies['tts_v3_short_context_sent_as_trimmed']['previous_text'] == COMBINING_DIAERESIS + 'Tere'
assert bodies['tts_v3_short_context_sent_as_trimmed']['next_text'] == 'Tere' + ZERO_WIDTH_JOINER


def mutation(name, base, field, allowed=False, error=None, **change):
    """A refused row fails with the consent error, or with `error` when the changed input is itself invalid."""
    row = {'case': name, 'base': base, 'field': field, **change, 'allowed': allowed}
    if error:
        row['error'] = error
    return row


QUOTE_MUTATIONS = [
    mutation('tts_seed', 'tts_v3_split_words_dropped', 'seed', value=4_294_967_294),
    mutation('tts_previous_text', 'tts_v3_split_words_dropped', 'previousText', value='A different previous sentence.'),
    mutation('tts_next_text', 'tts_v3_split_words_dropped', 'nextText', value='A different next sentence.'),
    mutation('tts_same', 'tts_v3_split_words_dropped', 'same', allowed=True),
    mutation('voice_changer_seed', 'voice_changer_clean_audio_off', 'seed', value=123_456_790),
    mutation('voice_changer_clean_audio', 'voice_changer_clean_audio_off', 'cleanAudioOn', value=True),
    mutation('voice_changer_same', 'voice_changer_clean_audio_off', 'same', allowed=True),
    mutation('clone_sample_byte', 'clone_estonian_caller_order', 'sampleByte', index=2),
    mutation('clone_sample_order', 'clone_estonian_caller_order', 'sampleOrder', swap=[0, 2]),
    mutation('clone_sample_role', 'clone_estonian_caller_order', 'sampleRole', swap=[0, 1]),
    mutation('clone_created_at', 'clone_estonian_caller_order', 'createdAt', value='2026-10-26T12:15:43.750+03:00'),
    mutation('clone_labels_language', 'clone_estonian_caller_order', 'language', value='en'),
    mutation('clone_display_name', 'clone_estonian_caller_order', 'displayName', value='Mari ' + O_TILDE_CAPITAL + 'unapuu-Tamm'),
    # U+200B is not White_Space, so it stays in the bound name; U+0085 and U+3000 are trimmed away. U+001F is a
    # control character, so that changed name is refused as invalid input.
    mutation('clone_display_name_zero_width_space', 'clone_estonian_caller_order', 'displayName',
             value='Mari ' + O_TILDE_CAPITAL + 'unapuu' + ZERO_WIDTH_SPACE),
    mutation('clone_display_name_unit_separator', 'clone_estonian_caller_order', 'displayName', error='invalidInput',
             value=UNIT_SEPARATOR + 'Mari ' + O_TILDE_CAPITAL + 'unapuu'),
    mutation('clone_display_name_white_space_only', 'clone_estonian_caller_order', 'displayName', allowed=True,
             value=NEXT_LINE + 'Mari ' + O_TILDE_CAPITAL + 'unapuu' + IDEOGRAPHIC_SPACE),
    mutation('clone_remove_background_noise', 'clone_estonian_caller_order', 'removeBackgroundNoise', value=True),
    mutation('clone_same', 'clone_estonian_caller_order', 'same', allowed=True),
]
assert all(display_name_valid(row['value']) == ('error' not in row) for row in QUOTE_MUTATIONS if row['field'] == 'displayName')

document = {
    'schema': 'voxclip-voice-lab-requests/1',
    'source': 'doc/spec/voice-lab.md §6.5, §6.7, §7.3, §8.5 and §15 test 12',
    'description': 'Synthetic Voice Lab request cases. Generated by tools/fixtures/voice-lab/generate_requests.py; '
                   'see request-cases-README.md. WAV bytes are built from parameters, never from a recorded voice.',
    'discovery': DISCOVERY,
    'multipartBoundary': BOUNDARY,
    'cases': CASES,
    'quoteMutations': QUOTE_MUTATIONS,
    'cloneDefaults': CLONE_DEFAULTS,
    'cloneInputs': CLONE_INPUTS,
    'whiteSpace': sorted(WHITE_SPACE),
}
OUT.write_text(json.dumps(document, indent=2) + '\n')
