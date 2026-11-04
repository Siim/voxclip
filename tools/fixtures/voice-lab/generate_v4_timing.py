#!/usr/bin/env python3
"""Eleven v4 dialogue timing variants (voice-lab §8.5 "Tolerant timing").

Each case is one text-to-dialogue reply a correct provider could plausibly send, or one whose words really differ.
Accepted cases carry the typed words with the times both Cores must derive; rejected cases carry the check name the
release log records. Write-only: shared/fixtures/voice-lab/v4-timing-cases.json (voxclip-voice-lab-v4-timing-cases/1).
Run from anywhere; the path is resolved from this file."""
import json
import unicodedata
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
CATALOG = json.loads((ROOT / 'shared/data/voice-audio-tags.json').read_text())
TAGS = {row['tag'] for row in CATALOG['tags']}
OVERRUN = 0.25
ORDER = 0.001
WHITE = {0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x20, 0x85, 0xa0, 0x1680, *range(0x2000, 0x200b), 0x2028, 0x2029, 0x202f, 0x205f, 0x3000}
VOICE = 'voice123'


def white(ch):
    return ord(ch) in WHITE


def fold(text):
    out = []
    for ch in unicodedata.normalize('NFC', text):
        lowered = 'i' if ch == 'İ' else ch.lower()
        out += [c for c in lowered if unicodedata.category(c) in ('Lu', 'Ll', 'Lt', 'Lm', 'Lo', 'Nd', 'Nl', 'No')]
    return ''.join(out)


def expands(token):
    return any(unicodedata.category(c) in ('Nd', 'Nl', 'No', 'Sc', 'Sm', 'So') or c in '%&@#/+' for c in token)


def strip_tags(text):
    out, i = '', 0
    while i < len(text):
        if text[i] == '[':
            j = i + 1
            while j < len(text) and text[j] not in '[]\r\n':
                j += 1
            if j < len(text) and text[j] == ']' and text[i + 1:j] in TAGS:
                i = j + 1
                continue
        out += text[i]
        i += 1
    return out


class Reject(Exception):
    def __init__(self, check):
        super().__init__(check)
        self.check = check


def provider_tokens(chars, starts, ends, duration):
    if not chars or len(chars) != len(starts) or len(starts) != len(ends):
        raise Reject('alignment_count_mismatch')
    latest = 0.0
    for index, (start, end) in enumerate(zip(starts, ends)):
        if start < 0 or end < start or start < latest - ORDER:
            raise Reject('alignment_time_order')
        if end > duration + OVERRUN:
            raise Reject('alignment_end_beyond_duration')
        latest = max(latest, start)
    scalars, s_starts, s_ends = [], [], []
    for ch, start, end in zip(chars, starts, ends):
        if not ch:
            continue
        start, end = min(start, duration), min(end, duration)
        step = (end - start) / len(ch)
        for offset, scalar in enumerate(ch):
            scalars.append(scalar)
            s_starts.append(start + step * offset)
            s_ends.append(start + step * (offset + 1))
    opened = None
    for index, scalar in enumerate(scalars):
        if scalar == '[':
            opened = index
        elif scalar == ']':
            if opened is not None:
                for inner in range(opened, index + 1):
                    scalars[inner] = ' '
            opened = None
        elif scalar in '\r\n':
            opened = None
    tokens, buffer, start, end = [], '', 0.0, 0.0
    for index, scalar in enumerate(scalars):
        if white(scalar):
            if buffer:
                tokens.append((buffer, fold(buffer), start, end))
            buffer = ''
            continue
        if not buffer:
            start, end = s_starts[index], s_ends[index]
        buffer += scalar
        end = max(end, s_ends[index])
    if buffer:
        tokens.append((buffer, fold(buffer), start, end))
    return tokens


def mapped(source, typed_text):
    typed = [t for t in ''.join(' ' if white(c) else c for c in strip_tags(typed_text)).split(' ') if t]
    if not typed:
        raise Reject('alignment_text_mismatch')
    folded = [fold(t) for t in typed]
    width = len(folded) + 1
    lengths = [0] * ((len(source) + 1) * width)
    for left in reversed(range(len(source))):
        for right in reversed(range(len(folded))):
            cell = left * width + right
            lengths[cell] = lengths[cell + width + 1] + 1 if source[left][1] == folded[right] else max(lengths[cell + width], lengths[cell + 1])
    result, removed, inserted = [], [], []
    left = right = 0

    def next_start():
        probe, other = left, right
        while probe < len(source) and other < len(folded):
            if source[probe][1] == folded[other]:
                return source[probe][2]
            if lengths[(probe + 1) * width + other] >= lengths[probe * width + other + 1]:
                probe += 1
            else:
                other += 1
        return None

    def flush():
        nonlocal removed, inserted
        if not inserted and not removed:
            return
        previous = result[-1][2] if result else 0.0
        spoken = any(t[1] for t in removed)
        words = [i for i in inserted if folded[i]]
        if not inserted and spoken:
            raise Reject('alignment_words_mismatch')
        if words and (not spoken or not all(expands(typed[i]) for i in words)):
            raise Reject('alignment_words_mismatch')
        if inserted:
            if removed:
                first = max(previous, removed[0][2])
                last = max(first, removed[-1][3])
            else:
                first = previous
                following = next_start()
                last = max(previous, following if following is not None else previous)
            total = float(sum(max(1, len(typed[i])) for i in inserted))
            cursor = first
            for offset, index in enumerate(inserted):
                end = last if offset == len(inserted) - 1 else cursor + (last - first) * float(max(1, len(typed[index]))) / total
                result.append((typed[index], cursor, end))
                cursor = end
        removed, inserted = [], []

    while left < len(source) or right < len(folded):
        if left < len(source) and right < len(folded) and source[left][1] == folded[right]:
            flush()
            previous = result[-1][2] if result else 0.0
            start = max(previous, source[left][2])
            result.append((typed[right], start, max(start, source[left][3])))
            left += 1
            right += 1
        elif right >= len(folded) or (left < len(source) and lengths[(left + 1) * width + right] >= lengths[left * width + right + 1]):
            removed.append(source[left])
            left += 1
        else:
            inserted.append(right)
            right += 1
    flush()
    if len(result) != len(typed):
        raise Reject('alignment_words_mismatch')
    return result


def arrays(text, step=0.05, offset=0.0):
    """Input times are short decimals, so every JSON reader parses them exactly."""
    chars = list(text)
    return {'characters': chars, 'character_start_times_seconds': [round(offset + i * step, 6) for i in range(len(chars))],
            'character_end_times_seconds': [round(offset + (i + 1) * step, 6) for i in range(len(chars))]}


def strict(alignment, typed, duration):
    """The unchanged exact path: provider text equal to the typed text (tags may be omitted), times in order."""
    chars = alignment['characters']
    actual = ''.join(chars)
    has_tags = strip_tags(typed) != typed
    if not (actual == typed or (has_tags and strip_tags(actual).split() == strip_tags(typed).split())):
        return False
    previous = 0.0
    for start, end in zip(alignment['character_start_times_seconds'], alignment['character_end_times_seconds']):
        if start < previous or end < start or end > duration + 0.05:
            return False
        previous = end
    return True


def segments_ok(case, count):
    duration = case['pcmSamples'] * 2 / 48000
    return all(s['character_end_index'] <= count and s['end_time_seconds'] <= duration + 0.05 for s in case['voice_segments'])


def bound(case, path):
    """Segment indices are bounded by the original array, widened only by a valid normalized alignment (§8.5)."""
    duration = case['pcmSamples'] * 2 / 48000
    count = len(case['normalized_alignment']['characters']) if path == 'normalized' else len(case['alignment']['characters'])
    normalized = case['normalized_alignment']
    if normalized is not None and strict(normalized, ''.join(normalized['characters']), duration):
        count = max(count, len(normalized['characters']))
    return count


def outcome(case):
    result = timing(case)
    if result['outcome'] == 'accepted' and not segments_ok(case, bound(case, result['path'])):
        return {'outcome': 'rejected', 'error': 'malformedResponse', 'check': 'segment', 'recoveredByTakeRun': True}
    return result


def timing(case):
    duration = case['pcmSamples'] * 2 / 48000
    sources = [s for s in [case['alignment'], case['normalized_alignment']] if s is not None]
    if case['alignment'] is not None and strict(case['alignment'], case['typed'], duration):
        tokens = provider_tokens(case['alignment']['characters'], case['alignment']['character_start_times_seconds'],
                                 case['alignment']['character_end_times_seconds'], duration)
        words = [t for t in tokens if strip_tags(t[0]).strip()]
        return {'outcome': 'accepted', 'path': 'exact',
                'words': [{'text': t[0], 'start': t[2], 'end': t[3]} for t in words]}
    last = 'null_alignment'
    for path, source in zip(['original', 'normalized'] if case['alignment'] is not None else ['normalized'], sources):
        try:
            tokens = provider_tokens(source['characters'], source['character_start_times_seconds'],
                                     source['character_end_times_seconds'], duration)
            words = mapped(tokens, case['typed'])
            return {'outcome': 'accepted', 'path': path, 'words': [{'text': w[0], 'start': w[1], 'end': w[2]} for w in words]}
        except Reject as failure:
            last = failure.check
    return {'outcome': 'rejected', 'error': 'invalidAlignment', 'check': last}


SIMILAR = 'I use a similar method as'
CLAUDE = "Claude, that is, when you are using your Claude's"
CURLY = CLAUDE.replace("'", '’')


def case(id, typed, alignment, normalized=None, samples=36000, segment_end=None, segment_end_time=None, note=''):
    count = max(len(alignment['characters']) if alignment else 0, len(normalized['characters']) if normalized else 0)
    last_end = max([*(alignment or {}).get('character_end_times_seconds', []), *(normalized or {}).get('character_end_times_seconds', []), 0])
    duration = samples * 2 / 48000
    row = {'id': id, 'note': note, 'typed': typed, 'pcmSamples': samples, 'alignment': alignment, 'normalized_alignment': normalized,
           'voice_segments': [{'voice_id': VOICE, 'dialogue_input_index': 0, 'character_start_index': 0,
                               'character_end_index': count if segment_end is None else segment_end,
                               'start_time_seconds': 0, 'end_time_seconds': min(last_end, duration) if segment_end_time is None else segment_end_time}]}
    row['expected'] = outcome(row)
    return row


def overlapping(text):
    rows = arrays(text)
    rows['character_start_times_seconds'] = [round(max(0, s - 0.01), 6) if i else s for i, s in enumerate(rows['character_start_times_seconds'])]
    return rows


def backwards(text):
    rows = arrays(text)
    rows['character_start_times_seconds'][6] = round(rows['character_start_times_seconds'][6] - 0.2, 6)
    return rows


def far_past(text):
    rows = arrays(text)
    rows['character_end_times_seconds'][-1] = 2.5
    return rows


TAGGED = '[laughs] ' + SIMILAR
cases = [
    case('exact', SIMILAR, arrays(SIMILAR), note='Equal text and times: the unchanged exact path.'),
    case('trailing_newline', SIMILAR, arrays(SIMILAR + '\n'), note='The provider appends a newline.'),
    case('surrounding_spaces', SIMILAR, arrays(' ' + SIMILAR + ' '), note='Leading and trailing spaces.'),
    case('curly_apostrophe_reply', CLAUDE, arrays(CURLY), samples=72000, note="Typed U+0027, provider U+2019 in Claude's."),
    case('straight_apostrophe_reply', CURLY, arrays(CLAUDE), samples=72000, note="Typed U+2019, provider U+0027."),
    case('lowercase_without_punctuation', CLAUDE, arrays("claude that is when you are using your claudes"), samples=72000,
         note='Case, commas and the apostrophe dropped.'),
    case('added_period', SIMILAR, arrays(SIMILAR + '.'), note='The provider adds sentence punctuation.'),
    case('null_original_normalized_lowercase', SIMILAR, None, arrays(' i use a similar method as'),
         note='Null alignment; normalized timing lowercases and leads with a space.'),
    case('null_original_normalized_expansion', 'We paid $12 for 21 apples', None,
         arrays('We paid twelve dollars for twenty one apples'), samples=72000, note='Normalized number and currency expansion.'),
    case('original_expansion', 'We paid $12 for 21 apples', arrays('We paid twelve dollars for twenty one apples'), samples=72000,
         note='Original alignment already expanded.'),
    case('tag_present', TAGGED, arrays(TAGGED), samples=48000, note='The tag is in the characters.'),
    case('tag_absent', TAGGED, arrays(SIMILAR), note='The tag is omitted from the characters.'),
    case('tag_absent_segments_count_tags', TAGGED, arrays(SIMILAR), segment_end=len(TAGGED),
         note='The segment also indexes the tag: the client keeps the shared segment contract (dialogue-cases.json) '
              'and the take run recovers the take from its word check.'),
    case('tag_unspaced', TAGGED, arrays('[laughs]' + SIMILAR), samples=48000, note='No space after the tag.'),
    case('tag_spaced_brackets', TAGGED, arrays('[ laughs ] ' + SIMILAR), samples=48000, note='Spaces inside the brackets.'),
    case('unrequested_direction', SIMILAR, arrays('[thoughtful] ' + SIMILAR), samples=48000,
         note='A direction the request did not carry.'),
    case('end_slightly_past_pcm', SIMILAR, arrays(SIMILAR), samples=27120, note='Character times end 0.12 s past the PCM.'),
    case('segment_end_past_pcm', SIMILAR, arrays(SIMILAR), samples=27120, segment_end_time=1.25,
         note='The segment also ends 0.12 s past the PCM: recovered by the take run.'),
    case('overlapping_characters', SIMILAR, overlapping(SIMILAR), note='Each character starts 10 ms before the previous one ends.'),
    case('different_word', SIMILAR, arrays('I use a different method as'), note='A word really differs.'),
    case('dropped_word', SIMILAR, arrays('I use a method as'), note='A word is missing.'),
    case('extra_word', SIMILAR, arrays('I use a very similar method as'), note='An extra word.'),
    case('normalized_different_word', SIMILAR, None, arrays('I use another method as'),
         note='Normalized timing with a different word (accepted before 2026-11-04).'),
    case('far_past_pcm', SIMILAR, far_past(SIMILAR), note='The last character ends far past the PCM.'),
    case('starts_backwards', SIMILAR, backwards(SIMILAR), note='A character starts 0.2 s before the previous one.'),
    case('both_null', SIMILAR, None, None, note='No timing at all.'),
]
document = {'schema': 'voxclip-voice-lab-v4-timing-cases/1', 'modelID': 'eleven_v4', 'voiceID': VOICE,
            'overrunTolerance': OVERRUN, 'orderTolerance': ORDER, 'caseCount': len(cases), 'cases': cases}
out = ROOT / 'shared/fixtures/voice-lab/v4-timing-cases.json'
out.write_text(json.dumps(document, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
