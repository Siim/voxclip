#!/usr/bin/env python3
"""Write the shared Fix with AI behaviour vectors (voice-lab §8.1, path 3).

Every case is one canned model reply to a synthetic transcript. The expected result comes from an independent Python
reading of the §8.1 rules: the strict JSON parse and extraction (ai.md §4.5), structural validation (ai.md §2.3), the
edit checks, line matching, duplicates, Core's own letter-and-digit length (§8.9.1) against the line's range, deletions
and the checkThis rule. A case with "rewriteExpected" also sends its reply through VoiceRewriteService, which applies
the passage-rewrite output rules (§8.9.1). Each case states its outcome by hand too, and the generator fails if the two
disagree. Non-ASCII text and every JSON escape are built with chr(). Running the generator twice gives identical bytes.
See shared/fixtures/voice-lab/rewrite-README.md.
"""
import json
import math
import re
import unicodedata
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / 'shared/fixtures/voice-lab/patch-rewrite-cases.json'
PROMPT = json.loads((ROOT / 'shared/prompts/patch-rewrite.json').read_text(encoding='utf-8'))
CHECK_THIS = "Check this: it adds something you didn't say."
assert PROMPT['messages']['checkThis'] == CHECK_THIS, 'the badge copy is voice-lab §8.1 verbatim'

BACKSLASH = chr(92)
# JavaScript's whitespace set (editing §4.5) and the transcript sentence end (ai.md §11.3).
JS_WHITESPACE = frozenset([*range(0x09, 0x0E), 0x20, 0xA0, 0x1680, *range(0x2000, 0x200B), 0x2028, 0x2029, 0x202F,
                           0x205F, 0x3000, 0xFEFF])
SENTENCE_END = re.compile('[.!?%s%s%s]["\'%s%s)]*\\Z' % (chr(0x3002), chr(0xFF01), chr(0xFF1F), chr(0x201D), chr(0x2019)))
JSON_SPACE = ' \t\n\r'
NUMBER = re.compile('-?(?:0|[1-9][0-9]*)(?:[.][0-9]+)?(?:[eE][+-]?[0-9]+)?')
HEX_DIGITS = frozenset('0123456789abcdefABCDEF')
SIMPLE_ESCAPES = ('"', BACKSLASH, '/', 'b', 'f', 'n', 'r', 't')
URL_SCHEME = re.compile('https?://', re.IGNORECASE)
MAX_DEPTH = 64
MAX_EDIT_BYTES = 2000
MAX_TEXT_BYTES = 20000


class InvalidOutput(Exception):
    pass


def js_trim(text):
    start, end = 0, len(text)
    while start < end and ord(text[start]) in JS_WHITESPACE:
        start += 1
    while end > start and ord(text[end - 1]) in JS_WHITESPACE:
        end -= 1
    return text[start:end]


def split_words(text):
    words, current = [], ''
    for scalar in text:
        if ord(scalar) in JS_WHITESPACE:
            if current:
                words.append(current)
            current = ''
        else:
            current += scalar
    return words + ([current] if current else [])


def category(scalar):
    return unicodedata.category(scalar)


def nfc(text):
    return unicodedata.normalize('NFC', text)


def length(text):
    """§8.9.1: Unicode scalars of general category L* or Nd after NFC."""
    return sum(1 for scalar in nfc(text) if category(scalar).startswith('L') or category(scalar) == 'Nd')


class Strict:
    """The strict parse of voice-lab §8.1: one RFC 8259 value with at most 64 levels of nesting, every escape well formed
    with no unpaired surrogate, and every number a finite double, where a non-zero number that rounds to zero does not
    fit either. This holds for the whole text, the values of repeated keys included, although only a key's first value
    is used."""

    def __init__(self, text):
        self.text, self.at = text, 0

    def document(self):
        self.space()
        if not self.value(0):
            return False
        self.space()
        return self.at == len(self.text)

    def peek(self):
        return self.text[self.at] if self.at < len(self.text) else ''

    def space(self):
        while self.at < len(self.text) and self.text[self.at] in JSON_SPACE:
            self.at += 1

    def value(self, depth):
        head = self.peek()
        if head in ('{', '['):
            return self.container(depth + 1, '}' if head == '{' else ']')
        if head == '"':
            return self.string()
        for word in ('true', 'false', 'null'):
            if self.text.startswith(word, self.at):
                self.at += len(word)
                return True
        return self.number()

    def container(self, depth, close):
        if depth > MAX_DEPTH:
            return False
        self.at += 1
        self.space()
        if self.peek() == close:
            self.at += 1
            return True
        keys = {}
        while True:
            if close == '}':
                start = self.at
                if self.peek() != '"' or not self.string():
                    return False
                key = json.loads(self.text[start:self.at])
                normalized = nfc(key)
                if normalized in keys and keys[normalized] != key:
                    return False
                keys[normalized] = key
                self.space()
                if self.peek() != ':':
                    return False
                self.at += 1
                self.space()
            if not self.value(depth):
                return False
            self.space()
            if self.peek() == ',':
                self.at += 1
                self.space()
            elif self.peek() == close:
                self.at += 1
                return True
            else:
                return False

    def unit(self, at):
        digits = self.text[at + 2:at + 6]
        if self.text[at:at + 2] != BACKSLASH + 'u' or len(digits) != 4 or not set(digits) <= HEX_DIGITS:
            return None
        return int(digits, 16)

    def string(self):
        self.at += 1
        while self.at < len(self.text):
            character = self.text[self.at]
            if character == '"':
                self.at += 1
                return True
            if ord(character) < 0x20:
                return False
            if character != BACKSLASH:
                self.at += 1
                continue
            if self.text[self.at + 1:self.at + 2] in SIMPLE_ESCAPES:
                self.at += 2
                continue
            first = self.unit(self.at)
            if first is None or 0xDC00 <= first <= 0xDFFF:
                return False
            self.at += 6
            if 0xD800 <= first <= 0xDBFF:
                second = self.unit(self.at)
                if second is None or not 0xDC00 <= second <= 0xDFFF:
                    return False
                self.at += 6
        return False

    def number(self):
        match = NUMBER.match(self.text, self.at)
        if not match:
            return False
        self.at = match.end()
        value = float(match.group(0))
        mantissa = re.split('[eE]', match.group(0))[0]
        return math.isfinite(value) and (value != 0 or not any(digit in '123456789' for digit in mantissa))


def first_wins(pairs):
    value = {}
    for name, item in pairs:
        value.setdefault(name, item)
    return value


def parse(text):
    """One parse attempt: the strict check, then the value with the first of each repeated key."""
    if not Strict(text).document():
        return False, None
    return True, json.loads(text, object_pairs_hook=first_wins)


def extract(text):
    """ai.md §4.5 over Unicode scalars: drop a code fence, parse the whole text, else the first balanced object."""
    body = js_trim(text)
    if body.startswith('```'):
        newline = body.find('\n')
        body = body[newline + 1:] if newline >= 0 else ''
        if js_trim(body).endswith('```'):
            body = js_trim(body)[:-3]
    parsed, value = parse(body)
    if parsed:
        return value
    first = body.find('{')
    if first < 0:
        raise InvalidOutput('not JSON')
    depth, quoted, escaped = 0, False, False
    for position in range(first, len(body)):
        character = body[position]
        if quoted:
            if escaped:
                escaped = False
            elif character == BACKSLASH:
                escaped = True
            elif character == '"':
                quoted = False
        elif character == '"':
            quoted = True
        elif character == '{':
            depth += 1
        elif character == '}':
            depth -= 1
            if depth == 0:
                parsed, value = parse(body[first:position + 1])
                if parsed:
                    return value
                break
    raise InvalidOutput('not JSON')


def key(token):
    """normalizeForMatch without its lowercase step: the L* and N* scalars in order, so case still counts. Keys compare
    as scalar sequences."""
    return ''.join(scalar for scalar in token if category(scalar)[0] in 'LN')


def digit_runs(text):
    runs, current = [], ''
    for scalar in text:
        if category(scalar) == 'Nd':
            current += scalar
        elif current:
            runs.append(current)
            current = ''
    return runs + ([current] if current else [])


def is_url(token):
    """Contains "://", or starts with "www." in either ASCII case once leading non-letters and non-digits are skipped."""
    if '://' in token:
        return True
    rest = token
    while rest and category(rest[0])[0] not in 'LN':
        rest = rest[1:]
    return len(rest) >= 4 and all(letter in 'wW' for letter in rest[:3]) and rest[3] == '.'


def is_capitalised(token):
    letter = next((scalar for scalar in token if category(scalar).startswith('L')), None)
    return letter is not None and category(letter) in ('Lu', 'Lt')


def check_this(text, sources):
    keys, runs = set(), set()
    for source in sources:
        source = nfc(source)
        runs.update(digit_runs(source))
        keys.update(key(token) for token in split_words(source))
    text = nfc(text)
    if any(run not in runs for run in digit_runs(text)):
        return True
    tokens = split_words(text)
    for index, token in enumerate(tokens):
        if is_url(token) and key(token) not in keys:
            return True
        at_start = index == 0 or SENTENCE_END.search(tokens[index - 1]) is not None
        if is_capitalised(token) and not at_start and key(token) not in keys:
            return True
    return False


def bad_edit(item):
    """ai.md §2.3 and voice-lab §8.1: a string line, text and reason, no Cc but tab in the text or the reason, and a text
    of at most 2,000 UTF-8 bytes."""
    if not isinstance(item, dict) or not all(isinstance(item.get(name), str) for name in ('line', 'text', 'reason')):
        return True
    if any(category(scalar) == 'Cc' and scalar != '\t' for name in ('text', 'reason') for scalar in item[name]):
        return True
    return len(item['text'].encode('utf-8')) > MAX_EDIT_BYTES


def line_labels(entries):
    """ai.md §11.3 line breaks; only the [a-b] labels are needed here."""
    labels, first = [], 0
    for position, entry in enumerate(entries):
        following = entries[position + 1] if position + 1 < len(entries) else None
        gap = following['start'] - entry['end'] if following else 0
        if following is None or SENTENCE_END.search(entry['text']) or gap >= 1.2 or position - first >= 40:
            labels.append(f"[{entries[first]['index']}-{entry['index']}]")
            first = position + 1
    return labels


def validate(reply, instruction, entries, ranges):
    value = extract(reply)
    if not isinstance(value, dict):
        raise InvalidOutput('not JSON')
    items = value.get('edits')
    if not isinstance(items, list):
        raise InvalidOutput('missing "edits"')
    by_line = {item['line']: item for item in ranges}
    sources = [entry['text'] for entry in entries] + [instruction]
    seen, edits, unknown, duplicates, malformed = set(), [], 0, 0, 0
    for item in items:
        if bad_edit(item):
            malformed += 1
            continue
        line = js_trim(item['line'])
        if line not in by_line:
            unknown += 1
            continue
        if line in seen:
            duplicates += 1
            continue
        seen.add(line)
        count, deletion = length(item['text']), js_trim(item['text']) == ''
        edits.append({'line': line, 'text': item['text'], 'reason': item['reason'], 'length': count,
                      'inRange': deletion or by_line[line]['minChars'] <= count <= by_line[line]['maxChars'],
                      'checkThis': check_this(item['text'], sources), 'isDeletion': deletion})
    if sum(len(edit['text'].encode('utf-8')) for edit in edits) > MAX_TEXT_BYTES:
        raise InvalidOutput('the edits hold more than 20,000 bytes of text')
    return {'edits': edits, 'unknownLines': unknown, 'duplicateLines': duplicates, 'malformedItems': malformed}


def rewrite(reply):
    """The passage-rewrite output rules (§8.9.1) for a reply that a case also sends through VoiceRewriteService."""
    value = extract(reply)
    if not isinstance(value, dict) or not isinstance(value.get('rewrite'), str):
        raise InvalidOutput('missing "rewrite"')
    text = value['rewrite']
    if (js_trim(text) == '' or len(text.encode('utf-8')) > MAX_TEXT_BYTES or URL_SCHEME.search(text)
            or any(category(scalar) == 'Cc' and scalar != '\n' for scalar in text)):
        raise InvalidOutput('not a plain spoken passage')
    return {'rewrite': text, 'proposedLength': length(text)}


def words(first, *timed):
    return [{'index': first + offset, 'text': text, 'start': start, 'end': end} for offset, (text, start, end) in enumerate(timed)]


# Three lines with absolute indices; the gap after "bigger." renders "(pause 1.9s)".
ENTRIES = words(40, ('So', 0.0, 0.2), ('last', 0.25, 0.5), ('year,', 0.55, 0.9), ('in', 0.95, 1.05), ('2024,', 1.1, 1.6),
                ('we', 1.65, 1.8), ('moved', 1.85, 2.2), ('to', 2.25, 2.35), ('Tartu.', 2.4, 2.9),
                ('The', 3.0, 3.15), ('new', 3.2, 3.4), ('studio', 3.45, 3.9), ('is', 3.95, 4.05), ('bigger.', 4.1, 4.6),
                ('Come', 6.5, 6.8), ('and', 6.85, 7.0), ('visit', 7.05, 7.4), ('us.', 7.45, 7.8))
A, B, C = '[40-48]', '[49-53]', '[54-57]'
RANGES = [{'line': A, 'minChars': 27, 'maxChars': 31}, {'line': B, 'minChars': 17, 'maxChars': 21},
          {'line': C, 'minChars': 12, 'maxChars': 15}]
assert line_labels(ENTRIES) == [item['line'] for item in RANGES]
# Eleven one-word lines for the 20,000-byte rule; each range allows 1 to 5,000.
LONG_ENTRIES = words(100, *((f'Line{offset}.', offset * 1.0, offset * 1.0 + 0.5) for offset in range(11)))
LONG_RANGES = [{'line': label, 'minChars': 1, 'maxChars': 5000} for label in line_labels(LONG_ENTRIES)]
assert len(LONG_RANGES) == 11
INSTRUCTION = "I said 2024; it's 2025."
ARABIC_INDIC_2025 = ''.join(chr(value) for value in (0x662, 0x660, 0x662, 0x665))
FFFE, O_TILDE, E_ACUTE_MARK = chr(0xFFFE), chr(0xF5), chr(0x301)
SEE_US = 'Come and see us.'


def escape(hex_digits):
    """The six-character JSON escape for one UTF-16 unit, as text inside a reply."""
    return BACKSLASH + 'u' + hex_digits


def literal(text):
    """A JSON string literal for text, with non-ASCII kept as it is."""
    return json.dumps(text, ensure_ascii=False)


def edit(line, text, reason='Fixes the line.', **extra):
    return {'line': line, 'text': text, 'reason': reason, **extra}


def reply(*edits):
    return json.dumps({'edits': list(edits)}, ensure_ascii=False, separators=(',', ':'))


def item(line, text, reason=None):
    """One edit object written by hand, so a case can hold raw escapes; text and reason are JSON string literals."""
    return '{"line":' + literal(line) + ',"text":' + text + ',"reason":' + (reason or literal('Fixes the line.')) + '}'


def both(edits, rewrite_text='"Fine."', extra=''):
    """A reply for both services: an edits array and a rewrite, plus raw members such as repeated keys."""
    return '{"edits":[' + ','.join(edits) + '],"rewrite":' + rewrite_text + extra + '}'


SEE_US_ITEM = item(C, literal(SEE_US), literal('Clearer.'))
CASES = []


def case(case_id, note, raw, outcome, counts=(0, 0, 0), instruction=INSTRUCTION, rewritten=None, stop=None, lines=None):
    """outcome is the hand-stated [(line, inRange, checkThis, isDeletion)] or an error kind; rewritten is the expected
    VoiceRewriteService proposal text, or an error kind, when the case is also sent through that service."""
    CASES.append((case_id, note, raw, outcome, counts, instruction, rewritten, stop, lines))


case('in-range-correction', 'The year comes from the instruction and the name from the transcript, so nothing is flagged.',
     reply(edit(A, 'So last year, in 2025, we moved to Tartu.', 'Corrects the year.')), [(A, True, False, False)])
case('unknown-line-dropped', 'An id that no line emitted is dropped and counted.',
     reply(edit('[99-120]', 'Nothing here.'), edit(B, 'The new studio is larger.')), [(B, True, False, False)], (1, 0, 0))
case('duplicate-line-keeps-first', 'A second edit for the same line is dropped and counted; the first is kept.',
     reply(edit(B, 'The studio is bigger.', 'First.'), edit(B, 'The new studio is much bigger.', 'Second.')),
     [(B, True, False, False)], (0, 1, 0))
case('out-of-range-low', 'Too short for its range: kept with inRange false.',
     reply(edit(B, 'Bigger now.', 'Shorter.')), [(B, False, False, False)])
case('out-of-range-high', 'Too long for its range: kept with inRange false.',
     reply(edit(B, 'The new studio is much, much bigger than the old one.', 'Longer.')), [(B, False, False, False)])
case('new-digit-run', 'A digit run found in neither the transcript nor the instruction.',
     reply(edit(A, 'So last year, in 2026, we moved to Tartu.')), [(A, True, True, False)])
case('digit-run-other-script', 'Digit runs compare exactly, so Arabic-Indic 2025 is not the instruction\'s ASCII 2025.',
     reply(edit(A, 'So last year, in ' + ARABIC_INDIC_2025 + ', we moved to Tartu.')), [(A, True, True, False)])
case('new-url', 'A token containing :// that the sources do not have.',
     reply(edit(C, 'Come and visit https://voxclip.example now.')), [(C, False, True, False)])
case('url-from-instruction', 'The same URL in the instruction, with a trailing full stop, appears.',
     reply(edit(C, 'Come and visit https://voxclip.example now.')), [(C, False, False, False)],
     instruction='Add our site, https://voxclip.example.')
case('new-www-url', 'A token starting with www. is a URL too.',
     reply(edit(C, 'Come and visit www.voxclip.example today.')), [(C, False, True, False)])
case('capitalised-mid-sentence', 'A capitalised token after an ordinary word that the sources do not have.',
     reply(edit(B, 'The new studio in Tallinn is bigger.')), [(B, False, True, False)])
case('capitalised-sentence-start', 'Capitalised tokens at the line start and after a full stop are not checked.',
     reply(edit(B, 'The studio grew. Everyone is happy.')), [(B, False, False, False)])
case('capitalised-after-closing-quote', 'A full stop followed by a closing quote ends a sentence (ai.md §11.3).',
     reply(edit(A, 'We moved to "Tartu." Then it grew.')), [(A, False, False, False)])
case('capitalised-case-sensitive', 'Appearing is case-sensitive: the transcript has "studio", not "Studio".',
     reply(edit(B, 'The new Studio is bigger.')), [(B, True, True, False)])
case('hangul-jamo-key-is-ordinal', 'Keys compare as scalar sequences: the edit\'s Z, jamo, ZWJ, jamo token keeps two jamo, '
     'which are canonically equivalent to the instruction\'s precomposed syllable but not the same scalars, so it is new.',
     reply(edit(B, 'The Z' + chr(0x1100) + chr(0x200D) + chr(0x1161) + ' studio is bigger.')), [(B, True, True, False)],
     instruction='Call it Z' + chr(0xAC00) + '.')
case('hangul-syllable-and-trailing-jamo', 'NFC composes a precomposed syllable and a trailing jamo: the edit\'s Z, U+AC00, '
     'U+11A8 token is the instruction\'s Z, U+AC01 after NFC, so it appears and nothing is flagged.',
     reply(edit(B, 'The Z' + chr(0xAC00) + chr(0x11A8) + ' studio is bigger.')), [(B, True, False, False)],
     instruction='Call it Z' + chr(0xAC01) + '.')
case('decomposed-text', 'NFC before matching: a decomposed o-tilde equals the instruction\'s precomposed one; text stays as sent.',
     reply(edit(B, 'The new studio is for To' + chr(0x303) + 'nu.')), [(B, True, False, False)],
     instruction='Say the studio belongs to T' + O_TILDE + 'nu.')
case('delete-whole-line', 'An empty text deletes the line: length 0, inRange true and isDeletion true.',
     reply(edit(C, '', 'Not needed.')), [(C, True, False, True)])
case('delete-with-whitespace-text', 'A text that is empty after jsTrim is a deletion too; the text stays as sent.',
     reply(edit(C, '  ', 'Not needed.')), [(C, True, False, True)])
case('punctuation-only-is-not-deletion', 'A text of punctuation alone is not empty, so it is no deletion; its length is 0.',
     reply(edit(C, '...', 'Pause.')), [(C, False, False, False)])
case('malformed-items-dropped', 'Items missing a field or with a wrong type are dropped and counted (ai.md §2.3).',
     reply({'line': A, 'text': 'So last year, in 2025, we moved to Tartu.'}, {'line': 49, 'text': 'The new studio.', 'reason': 'Typed.'},
           edit(B, 'The new studio is larger.')), [(B, True, False, False)], (0, 0, 2))
case('control-character-in-text', 'A text with NUL is dropped and counted as malformed; the other edit stays.',
     reply(edit(B, 'The new' + chr(0) + 'studio is bigger.'), edit(C, SEE_US)), [(C, True, False, False)], (0, 0, 1))
case('escape-character-in-text', 'ESC is a control character too.',
     reply(edit(B, 'The new studio' + chr(0x1B) + ' is bigger.')), [], (0, 0, 1))
case('line-break-in-text', 'A line break is a control character: the new text of a line is one line.',
     reply(edit(B, 'The new studio' + chr(10) + 'is bigger.')), [], (0, 0, 1))
case('delete-and-c1-controls-in-text', 'DEL and NEL are Cc as well.',
     reply(edit(B, 'The new studio' + chr(0x7F) + ' is bigger.'), edit(C, 'Come and' + chr(0x85) + ' see us.')), [], (0, 0, 2))
case('tab-in-text-kept', 'Tab is the one control character an edit may hold.',
     reply(edit(C, 'Come and' + chr(9) + 'see us.')), [(C, True, False, False)])
case('control-character-in-reason', 'A reason with a control character drops its edit too.',
     reply(edit(C, SEE_US, 'Clearer.' + chr(7))), [], (0, 0, 1))
case('text-of-2000-bytes-kept', 'A text of exactly 2,000 UTF-8 bytes is kept (1,000 o-tildes, so far out of range).',
     reply(edit(C, O_TILDE * 1000)), [(C, False, False, False)])
case('text-over-2000-bytes-dropped', 'One byte more and the edit is dropped and counted.',
     reply(edit(C, O_TILDE * 1000 + 'a')), [], (0, 0, 1))
case('edits-of-20000-bytes-kept', 'Ten edits of 2,000 bytes hold exactly 20,000 bytes of text, which is allowed.',
     reply(*(edit(label['line'], 'a' * 2000) for label in LONG_RANGES[:10])),
     [(label['line'], True, False, False) for label in LONG_RANGES[:10]], lines=(LONG_ENTRIES, LONG_RANGES))
case('edits-over-20000-bytes', 'An eleventh edit of one byte takes the kept edits past 20,000 bytes: the whole reply is invalid.',
     reply(*(edit(label['line'], 'a' * 2000) for label in LONG_RANGES[:10]), edit(LONG_RANGES[10]['line'], 'a')),
     'invalidOutput', lines=(LONG_ENTRIES, LONG_RANGES))
case('extra-keys-ignored', 'Keys outside the schema are ignored.',
     reply(edit(C, SEE_US, 'Clearer.', kind='fix')), [(C, True, False, False)])
case('trimmed-line-label', 'The line id is compared after jsTrim.',
     reply(edit(' ' + C + ' ', SEE_US)), [(C, True, False, False)])
case('code-fenced-reply', 'A reply in a json code fence is extracted (ai.md §4.5).',
     '```json\n' + reply(edit(C, SEE_US)) + '\n```', [(C, True, False, False)])
case('one-line-code-fence', 'A fence with no line break is all opening fence line, so nothing is left to parse (ai.md §4.5).',
     '```json' + both([SEE_US_ITEM]) + '```', 'invalidOutput', rewritten='invalidOutput')
case('prose-around-json', 'Text around the object: the whole text fails to parse, so the first balanced object is used.',
     'Here you go: ' + both([SEE_US_ITEM]) + ' Thanks!', [(C, True, False, False)], rewritten='Fine.')
case('combining-mark-after-quote', 'The balanced-object scan reads Unicode scalars: a combining mark after a quote does not '
     'hide the quote, so the brace inside the reason stays inside its string.',
     'Here: ' + both([item(C, literal(SEE_US), literal(E_ACUTE_MARK + '} is fine'))]), [(C, True, False, False)], rewritten='Fine.')
case('byte-order-mark-before-json', 'jsTrim removes a leading U+FEFF before parsing.',
     chr(0xFEFF) + both([SEE_US_ITEM]), [(C, True, False, False)], rewritten='Fine.')
case('top-level-array', 'The whole text parses, but as an array, so there is no object (ai.md §2.3).',
     '[' + both([SEE_US_ITEM]) + ']', 'invalidOutput', rewritten='invalidOutput')
case('repeated-top-level-key', 'A repeated key keeps its first value, for both services.',
     both([SEE_US_ITEM], literal(SEE_US), ',"edits":[],"rewrite":"Other."'), [(C, True, False, False)], rewritten=SEE_US)
case('repeated-key-in-item', 'Inside an edit too: the first "line" is unknown, so the edit is dropped as unknown.',
     '{"edits":[{"line":"[99-120]","line":' + literal(C) + ',"text":' + literal(SEE_US) + ',"reason":"Clearer."}]}', [], (1, 0, 0))
case('repeated-ignored-key', 'Repeated keys outside the schema change nothing.',
     both([SEE_US_ITEM], extra=',"x":1,"x":2'), [(C, True, False, False)], rewritten='Fine.')

KEY_NFC = 'caf' + chr(0xE9)
KEY_NFD = 'cafe' + chr(0x301)


def key_pair(first, second, first_value='1'):
    return literal(first) + ':' + first_value + ',' + literal(second) + ':9'


for suffix, extra, valid in [
    ('latin-collision', ',' + key_pair(KEY_NFC, KEY_NFD), False),
    ('latin-reversed-collision', ',' + key_pair(KEY_NFD, KEY_NFC), False),
    ('kelvin-collision', ',' + key_pair(chr(0x4B), chr(0x212A)), False),
    ('nested-collision', ',"x":{' + key_pair(KEY_NFC, KEY_NFD) + '}', False),
    ('null-collision', ',' + key_pair(KEY_NFC, KEY_NFD, 'null'), False),
    ('byte-identical-repeat', ',' + key_pair(KEY_NFC, KEY_NFC), True),
    ('separate-objects', ',"x":{' + literal(KEY_NFC) + ':1},"y":{' + literal(KEY_NFD) + ':9}', True),
    ('distinct-case', ',' + key_pair(chr(0x4B), chr(0x6B)), True),
    ('escaped-byte-repeat', ',"' + escape('00e9') + '":1,' + literal(chr(0xE9)) + ':9', True),
    ('hangul-collision', ',' + key_pair(chr(0xAC00) + chr(0x11A8), chr(0xAC01)), False),
]:
    case('json-keys-' + suffix, 'UTF-8 keys compare by bytes; canonically equivalent byte-different keys are invalid '
         'within one object. Identical decoded bytes keep the first value.', both([SEE_US_ITEM], extra=extra),
         [(C, True, False, False)] if valid else 'invalidOutput', rewritten='Fine.' if valid else 'invalidOutput')

case('repeated-key-value-still-checked', 'The unused second value of a repeated key must still be valid: it holds an '
     'unpaired surrogate escape.', both([SEE_US_ITEM], extra=',"x":1,"x":"' + escape('d800') + '"'), 'invalidOutput',
     rewritten='invalidOutput')
case('unpaired-surrogate-in-text', 'An escaped unpaired surrogate in any string makes the reply invalid.',
     both([item(C, '"Come ' + escape('d800') + ' us."')]), 'invalidOutput', rewritten='invalidOutput')
case('unpaired-surrogate-in-reason', 'The same in a reason.',
     both([item(C, literal(SEE_US), '"Fix ' + escape('dfff') + '"')]), 'invalidOutput', rewritten='invalidOutput')
case('unpaired-surrogate-in-ignored-key', 'The same in a key outside the schema.',
     both([SEE_US_ITEM], extra=',"x":"' + escape('dc00') + '"'), 'invalidOutput', rewritten='invalidOutput')
case('unpaired-surrogate-in-key-name', 'The same in a key name.',
     '{"' + escape('d800') + '":1,' + both([SEE_US_ITEM])[1:], 'invalidOutput', rewritten='invalidOutput')
case('reversed-surrogate-pair', 'A low surrogate escape before a high one is two unpaired surrogates.',
     both([item(C, '"Come ' + escape('de00') + escape('d83d') + ' us."')]), 'invalidOutput', rewritten='invalidOutput')
case('escaped-surrogate-pair', 'A high and low surrogate escape in order is one emoji, which does not count.',
     both([item(C, '"Come and see us ' + escape('d83d') + escape('de00') + '"')]), [(C, True, False, False)], rewritten='Fine.')
case('nesting-of-64-levels', 'The top-level object and 63 arrays inside an ignored key: 64 levels are allowed.',
     both([SEE_US_ITEM], extra=',"x":' + '[' * 63 + ']' * 63), [(C, True, False, False)], rewritten='Fine.')
case('nesting-of-65-levels', 'One level more and the reply is invalid.',
     both([SEE_US_ITEM], extra=',"x":' + '[' * 64 + ']' * 64), 'invalidOutput', rewritten='invalidOutput')
case('number-out-of-range', 'A number beyond the double range makes the reply invalid, even in an ignored key.',
     both([SEE_US_ITEM], extra=',"x":1e400'), 'invalidOutput', rewritten='invalidOutput')
case('negative-number-out-of-range', 'The same below the double range.',
     both([SEE_US_ITEM], extra=',"x":-1e400'), 'invalidOutput', rewritten='invalidOutput')
case('integer-out-of-range', 'A 310-digit integer does not fit a double either.',
     both([SEE_US_ITEM], extra=',"x":1' + '0' * 309), 'invalidOutput', rewritten='invalidOutput')
case('number-rounding-to-zero', 'A non-zero number that rounds to zero does not fit.',
     both([SEE_US_ITEM], extra=',"x":1e-400'), 'invalidOutput', rewritten='invalidOutput')
case('subnormal-number', 'A small number that a double still holds is fine.',
     both([SEE_US_ITEM], extra=',"x":1e-310'), [(C, True, False, False)], rewritten='Fine.')
case('zero-with-large-exponent', 'Zero is zero whatever its exponent.',
     both([SEE_US_ITEM], extra=',"x":0e-400'), [(C, True, False, False)], rewritten='Fine.')
case('zero-with-exponent', 'An exact zero with an exponent is a valid number.',
     both([SEE_US_ITEM], extra=',"x":0e1'), [(C, True, False, False)], rewritten='Fine.')
case('zero-with-capital-exponent', 'The same with a capital E.',
     both([SEE_US_ITEM], extra=',"x":0E1'), [(C, True, False, False)], rewritten='Fine.')
case('zero-fraction-with-negative-exponent', 'A zero fraction with a negative exponent is zero too.',
     both([SEE_US_ITEM], extra=',"x":0.00e-1'), [(C, True, False, False)], rewritten='Fine.')
case('negative-zero-with-exponent', 'So is a negative zero with an exponent.',
     both([SEE_US_ITEM], extra=',"x":-0.0e5'), [(C, True, False, False)], rewritten='Fine.')
case('nan-literal', 'NaN is not JSON.', both([SEE_US_ITEM], extra=',"x":NaN'), 'invalidOutput', rewritten='invalidOutput')
case('noncharacter-in-text', 'An escaped U+FFFE in the new text and the rewrite is kept as sent and counts nothing.',
     both([item(C, '"Come and see' + escape('fffe') + ' us."')], '"Fine' + escape('fffe') + '."'), [(C, True, False, False)],
     rewritten='Fine' + FFFE + '.')
case('raw-noncharacter-in-text', 'The same with U+FFFE written as itself.',
     both([item(C, literal('Come and see' + FFFE + ' us.'))]), [(C, True, False, False)], rewritten='Fine.')
case('noncharacter-in-instruction', 'U+FFFE in the instruction: its 2025 still appears, so nothing is flagged.',
     reply(edit(A, 'So last year, in 2025, we moved to Tartu.')), [(A, True, False, False)], instruction=INSTRUCTION + FFFE)
case('rewrite-with-c1-control', 'The rewrite rules reject every Cc but a line break: here DEL and NEL. The edits are fine.',
     both([SEE_US_ITEM], literal('Fine' + chr(0x7F) + chr(0x85) + '.')), [(C, True, False, False)], rewritten='invalidOutput')
case('rewrite-of-only-a-byte-order-mark', 'A rewrite that is empty after jsTrim is invalid; U+FEFF is JavaScript whitespace.',
     both([SEE_US_ITEM], literal(chr(0xFEFF))), [(C, True, False, False)], rewritten='invalidOutput')
case('refused-stop', 'A refusal is the refused error on both services, whatever the text.',
     both([SEE_US_ITEM]), 'refused', rewritten='refused', stop='refused')
case('truncated-stop', 'An incomplete reply is the truncated error.',
     both([SEE_US_ITEM]), 'truncated', rewritten='truncated', stop='truncated')
case('empty-list', 'An empty edits list is a valid result.', reply(), [])
case('malformed-json', 'A reply with no JSON object is a typed error.', 'I could not find anything to fix.', 'invalidOutput',
     rewritten='invalidOutput')
case('missing-edits', 'A JSON object without "edits" is a typed error.', '{"changes":[]}', 'invalidOutput',
     rewritten='invalidOutput')

ERRORS = ('invalidOutput', 'refused', 'truncated')
cases = []
for case_id, note, raw, outcome, counts, instruction, rewritten, stop, lines in CASES:
    assert not any(0xD800 <= ord(scalar) <= 0xDFFF for scalar in raw + instruction), f'{case_id}: a raw surrogate'
    entries, ranges = lines or (ENTRIES, RANGES)
    if stop is not None:
        expected = {'error': stop}
    else:
        try:
            expected = validate(raw, instruction, entries, ranges)
        except InvalidOutput:
            expected = {'error': 'invalidOutput'}
    if outcome in ERRORS:
        assert expected == {'error': outcome}, (case_id, expected)
    else:
        stated = [(item['line'], item['inRange'], item['checkThis'], item['isDeletion']) for item in expected['edits']]
        assert stated == outcome, (case_id, stated)
        assert (expected['unknownLines'], expected['duplicateLines'], expected['malformedItems']) == counts, (case_id, expected)
    value = {'id': case_id, 'note': note, 'instruction': instruction, 'reply': raw}
    if stop is not None:
        value['stop'] = stop
    if lines is not None:
        value['entries'], value['ranges'] = entries, ranges
    value['expected'] = expected
    if rewritten is not None:
        if stop is not None:
            proposal = {'error': stop}
        else:
            try:
                proposal = rewrite(raw)
            except InvalidOutput:
                proposal = {'error': 'invalidOutput'}
        assert proposal == ({'error': rewritten} if rewritten in ERRORS else {'rewrite': rewritten, 'proposedLength': length(rewritten)}), (case_id, proposal)
        value['rewriteExpected'] = proposal
    cases.append(value)
assert len({case['id'] for case in cases}) == len(cases), 'duplicate case id'

document = {
    'version': 1,
    'rules': 'voice-lab ' + chr(0xA7) + '8.1, path 3: Fix with AI validation from canned replies.',
    'copy': {'checkThis': CHECK_THIS},
    'language': 'en',
    'entries': ENTRIES,
    'ranges': RANGES,
    'cases': cases,
}
OUT.write_text(json.dumps(document, indent=2) + '\n', encoding='utf-8')
