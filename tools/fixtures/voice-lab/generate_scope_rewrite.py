#!/usr/bin/env python3
"""Write the scope rewrite plan vectors (voice-lab.md section 8.1 item 1 and section 8.9.1).

A clip or Full take Rewrite is "Fix with AI" over the scope. The plan holds the request's entries, its transcript lines
and one character range per line:

- Entries are the scope's kept items in source order, in the ai.md section 11.2 item format (absolute index, display text
  with corrections applied, event label or an ellipsis for unlabeled speech, cut to 100 UTF-16 units without splitting a
  surrogate pair). Unlike section 11.2, which sends every item, cut items are left out, and a clip keeps only the items
  from its first to its last word.
- Lines are the ai.md section 11.3 `formatTranscript` lines of the entries.
- A line's range is the length budget of its words placed as one replace hunk (section 8.9.1): `place` puts the window
  from the line's first to its last word item in the scope's render scope, `lendableSilence` gives the take-edge pads,
  and the bridge words' length is `f`. A refused window, or no source envelope, falls back to the advisory range of the
  line's own word span (`fullTake` of the line). A line with no word item gets 1 to 1. Ranges are capped at the
  request's 5,000.
- More than 3,000 entries or 20,000 UTF-8 bytes of entry text joined with spaces is `tooLarge` with the entry count.

The window geometry and the budget come from the existing references, generate_window.py and
generate_length_budget.py; only their definitions are loaded, so their own vectors are not rewritten. Non-ASCII text is
built with chr(). Running the generator twice gives identical bytes. See shared/fixtures/voice-lab/scope-rewrite-README.md.
"""
import ast
import json
import re
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
OUT = ROOT / 'shared/fixtures/voice-lab/scope-rewrite-plan-cases.json'

MAX_ENTRIES = 3000
MAX_BYTES = 20000
MAX_WORD_TEXT_LENGTH = 100   # ai.md section 11.2, in UTF-16 code units
MAX_CHARS = 5000             # PatchRewriteRequest range limit, voice-lab.md section 8.1
ELLIPSIS = chr(0x2026)
SENTENCE_END = re.compile('[.!?%s%s%s]["\'%s%s)]*\\Z' % (chr(0x3002), chr(0xFF01), chr(0xFF1F), chr(0x201D), chr(0x2019)))

assert Path(__file__).read_text(encoding='utf-8').isascii(), 'write non-ASCII characters with chr()'


def definitions(name):
    """A generator's imports, functions, classes and upper-case constants, without running its cases."""
    path = HERE / name
    tree = ast.parse(path.read_text(encoding='utf-8'), str(path))
    body = [node for node in tree.body if isinstance(node, (ast.Import, ast.ImportFrom, ast.FunctionDef, ast.ClassDef))
            or isinstance(node, ast.Assign) and all(isinstance(target, ast.Name) and target.id.isupper() for target in node.targets)]
    namespace = {'__file__': str(path), '__name__': path.stem}
    exec(compile(ast.Module(body=body, type_ignores=[]), str(path), 'exec'), namespace)
    return namespace


WINDOW = definitions('generate_window.py')
BUDGET = definitions('generate_length_budget.py')
GeometryError = WINDOW['GeometryError']


def utf16_prefix(text, limit):
    """AIText.prefix: the first `limit` UTF-16 units, less a trailing high surrogate."""
    units = text.encode('utf-16-le', 'surrogatepass')[:2 * limit]
    if len(units) >= 2 and 0xD800 <= int.from_bytes(units[-2:], 'little') <= 0xDBFF:
        units = units[:-2]
    return units.decode('utf-16-le', 'surrogatepass')


def display(item, corrections):
    if item['kind'] == 'word':
        return corrections.get(item['id'], item['text'])
    return item['text'] if item['kind'] == 'event' else ELLIPSIS


def line_bounds(entries):
    """ai.md section 11.3: the (first, last) entry positions of each line."""
    bounds, first = [], 0
    for position, entry in enumerate(entries):
        following = entries[position + 1] if position + 1 < len(entries) else None
        gap = following['start'] - entry['end'] if following else 0
        if following is None or SENTENCE_END.search(entry['text']) or gap >= 1.2 or position - first >= 40:
            bounds.append((first, position))
            first = position + 1
    return bounds


def window_range(project, clip_id, envelope, line_words, texts, rate):
    """Section 8.9.1 for the line's words as one replace hunk: the window, its take-edge pads and its bridge length."""
    window = WINDOW['place'](project, clip_id, envelope, line_words[0]['id'], line_words[-1]['id'])
    incoming, outgoing = WINDOW['lendable_silence'](project, clip_id, window)
    bridge = sum(BUDGET['length'](texts[ident]) for ident in window['leftBridgeWordIds'] + window['rightBridgeWordIds'])
    left, right = window['leftSeam']['kind'], window['rightSeam']['kind']
    edge = (max(0.0, incoming - 0.03) if left == 'none' else 0.0) + (max(0.0, outgoing - 0.06) if right == 'none' else 0.0)
    target = (window['end'] - window['start']) - edge
    budget = BUDGET['range_oracle'](target, edge, bridge, rate)
    if 'error' in budget:
        raise GeometryError('budget:' + budget['error'])
    return budget, '%s/%s' % (left, right)


def plan(take, scope, envelope):
    """The expected plan or error for one case."""
    items, edits = take['words'], take['edits']
    corrections = edits['corrections']
    if scope['kind'] == 'fullTake':
        clip_id, positions = None, range(len(items))
    elif scope['kind'] == 'clip':
        clip_id = scope['clipId']
        clip = next((clip for clip in edits['clips'] if clip['id'] == clip_id), None)
        ids = [item['id'] for item in items]
        if clip is None or clip['startWordId'] not in ids or clip['endWordId'] not in ids:
            return {'error': 'invalidInput'}
        first, last = ids.index(clip['startWordId']), ids.index(clip['endWordId'])
        if first > last:
            return {'error': 'invalidInput'}
        positions = range(first, last + 1)
    else:
        return {'error': 'invalidInput'}
    cut = set(edits['cutWordIds'])
    kept = [position for position in positions if items[position]['id'] not in cut]
    entries = [{'index': position, 'text': utf16_prefix(display(items[position], corrections), MAX_WORD_TEXT_LENGTH),
                'start': items[position]['start'], 'end': items[position]['end']} for position in kept]
    if not entries:
        return {'error': 'empty'}
    size = len(' '.join(entry['text'] for entry in entries).encode('utf-8'))
    if len(entries) > MAX_ENTRIES or size > MAX_BYTES:
        return {'error': 'tooLarge', 'count': len(entries)}
    texts = {item['id']: display(item, corrections) for item in items}
    rows = [[item['id'], texts[item['id']], item['start'], item['end'], item['kind']] for item in items]
    project = {'sampleRate': float(take['sampleRate']), 'durationSeconds': take['durationSeconds'], 'words': items,
               'edits': edits, 'segments': []}
    if envelope is not None:
        # The take and envelope are checked once, as place reads them; a failure there is the plan's, not a line's.
        try:
            WINDOW['checked_take'](project)
            WINDOW['check_envelope'](envelope, project['sampleRate'])
            WINDOW['check_items'](items, project['sampleRate'])
        except GeometryError:
            return {'error': 'invalidInput'}
    lines = []
    for first, last in line_bounds(entries):
        line_items = [items[kept[position]] for position in range(first, last + 1)]
        words = [item for item in line_items if item['kind'] == 'word']
        line = {'line': '[%d-%d]' % (entries[first]['index'], entries[last]['index']),
                'itemIds': [item['id'] for item in line_items]}
        if not words:
            line.update(minChars=1, maxChars=1, rangeSource='noSpeech')
            lines.append(line)
            continue
        rate = BUDGET['rate_oracle'](rows, edits['pauseThresholdSeconds'], [])['charactersPerSecond']
        refusal = None
        try:
            if envelope is None:
                raise GeometryError('noEnvelope')
            budget, seams = window_range(project, clip_id, envelope, words, texts, rate)
            source = 'window'
        except GeometryError as error:
            refusal = error.value['error']
            budget = BUDGET['range_oracle'](words[-1]['end'] - words[0]['start'], 0.0, 0, rate, True)
            source = 'lineSpan'
        line.update(minChars=min(budget['minChars'], MAX_CHARS), maxChars=min(budget['maxChars'], MAX_CHARS), rangeSource=source)
        # Informative only; the suites read neither.
        line['note'] = ('seams ' + seams + ', target %r s, bridge %d' % (budget['targetSeconds'], budget['bridgeLength'])
                        if source == 'window' else 'refused: ' + refusal)
        lines.append(line)
    return {'entries': entries, 'utf8Bytes': size, 'lines': lines}


def summary(expected):
    """Large passing cases keep counts and the line table without item lists, so the file stays reviewable."""
    if 'error' in expected:
        return expected
    return {'summary': {'entryCount': len(expected['entries']), 'utf8Bytes': expected['utf8Bytes'],
                        'firstEntry': expected['entries'][0], 'lastEntry': expected['entries'][-1],
                        'lines': [{'line': line['line'], 'itemCount': len(line['itemIds']), 'firstItemId': line['itemIds'][0],
                                   'lastItemId': line['itemIds'][-1], 'minChars': line['minChars'], 'maxChars': line['maxChars'],
                                   'rangeSource': line['rangeSource']} for line in expected['lines']]}}


def word(ident, text, start, end, kind='word'):
    return {'id': ident, 'text': text, 'kind': kind, 'start': start, 'end': end}


def edits(cut=(), corrections=None, clips=(), threshold=1.0, keep=0.15):
    return {'cutWordIds': list(cut), 'cutPauseIds': [], 'corrections': dict(corrections or {}),
            'pauseThresholdSeconds': threshold, 'pauseKeepSeconds': keep,
            'clips': [{'id': ident, 'startWordId': first, 'endWordId': last, 'origin': origin, 'selected': origin == 'manual'}
                      for ident, first, last, origin in clips]}


def envelope_for(items, rate, duration, overrides=()):
    levels = WINDOW['envelope_levels'](items, rate, WINDOW['samples'](duration, rate) // WINDOW['frame_size'](rate), overrides)
    return {'sampleRate': rate, 'levels': levels}


def repeated(spec):
    """README "wordsRepeat": item i has ID idPrefix + i, text `token`, start i * timingStep and end start + timingStep / 2."""
    return [word(spec['idPrefix'] + str(index), spec['token'], index * spec['timingStep'],
                 index * spec['timingStep'] + spec['timingStep'] / 2) for index in range(spec['count'])]


CASES = []


def case(name, note, take, scope, envelope=True, instruction='Fix slips and repeats.', language='en', compact=None, large=False):
    items = take['words']
    env = envelope_for(items, take['sampleRate'], take['durationSeconds']) if envelope is True else envelope
    expected = plan(take, scope, env)
    value = {'sampleRate': take['sampleRate'], 'durationSeconds': take['durationSeconds']}
    if compact is not None:
        value['wordsRepeat'] = compact
    else:
        value['words'] = items
    value.update(edits=take['edits'], envelope=None if env is None else
                 {'sampleRate': env['sampleRate'], 'runs': WINDOW['runs'](env['levels'])},
                 scope=scope, instruction=instruction, language=language)
    CASES.append({'name': name, 'note': note, 'input': value, 'expected': summary(expected) if large else expected})
    return expected


def sources(expected):
    return [line['rangeSource'] for line in expected['lines']]


# One take for the clip and Full take cases, at 48 kHz. "today" is corrected to end a sentence, two words are cut (a
# filler and a repeat), an event and unlabeled speech sit inside lines, the applause stands alone after a long pause,
# and the filler "uh" before "Thanks" is cut and touches it, so that line's window is refused.
TAKE_A_WORDS = [
    word('w0', 'So', 0.05, 0.30), word('w1', 'um', 0.45, 0.60), word('w2', 'today', 0.62, 0.95),
    word('w3', 'we', 1.30, 1.45), word('w4', 'ship', 1.50, 1.80), word('w5', 'the', 1.85, 1.95),
    word('w6', 'the', 2.00, 2.10), word('w7', 'new', 2.15, 2.40), word('w8', 'editor.', 2.45, 2.90),
    word('e9', '(laughs)', 3.00, 3.40, 'event'), word('w10', 'It', 3.50, 3.60), word('w11', 'cuts', 3.65, 3.95),
    word('u12', 'mm', 4.00, 4.20, 'unlabeledSpeech'), word('w13', 'words', 4.25, 4.60), word('w14', 'fast.', 4.65, 5.00),
    word('e15', '(applause)', 6.30, 7.00, 'event'), word('w16', 'uh', 8.20, 8.40), word('w17', 'Thanks', 8.40, 8.70),
    word('w18', 'for', 8.95, 9.10), word('w19', 'watching!', 9.15, 9.45),
]
TAKE_A_EDITS = edits(cut=['w1', 'w6', 'w16'], corrections={'w2': 'today.', 'w13': 'words,'},
                     clips=[('clip-mid', 'w3', 'w14', 'manual'), ('clip-start', 'w0', 'w8', 'manual'),
                            ('clip-end', 'w18', 'w19', 'manual'), ('clip-suggested', 'w10', 'w19', 'ai'),
                            ('clip-all-cut', 'w16', 'w16', 'manual')])
TAKE_A = {'sampleRate': 48000, 'durationSeconds': 9.6, 'words': TAKE_A_WORDS, 'edits': TAKE_A_EDITS}

result = case('clip-cuts-corrections', 'A kept clip in mid-take: the cut repeat w6 is left out and absorbed by its line window; '
              'corrections are applied; the event and unlabeled speech are entries; the clip head and tail come from clipTimes.',
              TAKE_A, {'kind': 'clip', 'clipId': 'clip-mid'})
assert [entry['index'] for entry in result['entries']] == [3, 4, 5, 7, 8, 9, 10, 11, 12, 13, 14], result
assert sources(result) == ['window', 'window'], result

result = case('full-take', 'Full take: cut items left out, a correction ending a sentence, an event-only line (1 to 1) '
              'and a line whose window is refused because the cut filler touches it (advisory span).',
              TAKE_A, {'kind': 'fullTake'}, instruction='Make it clearer. Keep my words where they work; change as little as possible.')
assert sources(result) == ['window', 'window', 'window', 'noSpeech', 'lineSpan'], result
assert result['lines'][-1]['note'] == 'refused: seamFadeCrossesCut', result

result = case('clip-at-take-start', 'A clip whose clipTimes range starts at 0: its first line window reaches the take start '
              'with a none seam, so the edge pad shortens that line\'s target.', TAKE_A, {'kind': 'clip', 'clipId': 'clip-start'})
assert result['lines'][0]['note'].startswith('seams none/'), result

result = case('clip-at-take-end', 'A clip whose clipTimes range reaches the take end: the window there gets a none seam. The '
              'clip starts in the pause after "Thanks", so its left seam is a gap seam inside the clip head.', TAKE_A, {'kind': 'clip', 'clipId': 'clip-end'})
assert result['lines'][0]['note'].startswith('seams gap/none,'), result

result = case('suggested-clip', 'A suggested clip (origin ai, not selected) is a scope like a kept clip. Its head cuts the '
              'event just before "It", so the first line\'s hard seam has no kept source for its fade and takes the advisory span.',
              TAKE_A, {'kind': 'clip', 'clipId': 'clip-suggested'})
assert sources(result) == ['lineSpan', 'noSpeech', 'lineSpan'], result

result = case('no-envelope', 'Without the source envelope no window is placed: every line with words takes its advisory span.',
              TAKE_A, {'kind': 'fullTake'}, envelope=None)
assert sources(result) == ['lineSpan', 'lineSpan', 'lineSpan', 'noSpeech', 'lineSpan'], result

case('all-cut', 'A clip whose only item is cut keeps nothing.', TAKE_A, {'kind': 'clip', 'clipId': 'clip-all-cut'})
case('unknown-clip', 'An unknown clip ID is invalid input.', TAKE_A, {'kind': 'clip', 'clipId': 'clip-missing'})
case('selection', 'A selection is a passage for VoiceRewriteService (section 8.1 item 2), not a scope plan.', TAKE_A,
     {'kind': 'selection', 'first': 3, 'last': 8})
case('envelope-rate-mismatch', 'An envelope on another rate than the source is invalid input, never a silent fallback.', TAKE_A,
     {'kind': 'fullTake'}, envelope={'sampleRate': 44100, 'levels': [WINDOW['ROOM']] * 960})

# ai.md section 11.2 text: a correction is cut to 100 UTF-16 units, and a surrogate pair that would straddle the cut is
# dropped whole. 99 letters then an emoji keep 99 letters.
emoji = chr(0x1F600)
take = {'sampleRate': 48000, 'durationSeconds': 2.0, 'words': [word('a', 'Long', 0.1, 0.5), word('b', 'word', 0.6, 1.0),
                                                               word('c', 'here.', 1.1, 1.5)],
        'edits': edits(corrections={'b': 'x' * 99 + emoji + 'tail', 'c': 'y' * 98 + emoji + 'z'})}
result = case('long-text-cut-to-100-units', 'Entry text is cut to 100 UTF-16 units without splitting a surrogate pair.', take,
              {'kind': 'fullTake'}, envelope=None)
assert [len(entry['text']) for entry in result['entries']] == [4, 99, 99], result

# The range cap: one fast line raises the take rate, so a slow line's budget passes 5,000 and is capped.
fast = [word('f%d' % index, 'abcdefghij', index * 0.05, index * 0.05 + 0.05) for index in range(40)]
fast[-1]['text'] = 'abcdefghij.'
slow = [word('s%d' % index, 'x', 3.0 + index * 1.2, 3.0 + index * 1.2 + 0.01) for index in range(41)]
take = {'sampleRate': 48000, 'durationSeconds': 53.0, 'words': fast + slow, 'edits': edits()}
result = case('range-capped-at-5000', 'A line whose budget passes the request limit is capped at 5,000 on both bounds.', take,
              {'kind': 'fullTake'}, envelope=None)
assert result['lines'][1]['minChars'] == result['lines'][1]['maxChars'] == MAX_CHARS, result

# Request limits (section 8.1): at most 3,000 entries and 20,000 bytes. The limit counts kept items, so cutting one of
# 3,001 words passes; a clip counts only its own items.
spec = {'token': 'go', 'count': 3001, 'idPrefix': 'r', 'timingStep': 0.5}
words_3001 = repeated(spec)
case('entries-over-limit', '3,001 kept items refuse with their count.', {'sampleRate': 48000, 'durationSeconds': 1501.0,
     'words': words_3001, 'edits': edits()}, {'kind': 'fullTake'}, envelope=None, compact=spec)
case('entries-at-limit', 'Cutting one of 3,001 items leaves 3,000, which pass.', {'sampleRate': 48000, 'durationSeconds': 1501.0,
     'words': words_3001, 'edits': edits(cut=['r1500'])}, {'kind': 'fullTake'}, envelope=None, compact=spec, large=True)
case('clip-in-long-take', 'A clip of a 3,001-item take counts only its own items.', {'sampleRate': 48000,
     'durationSeconds': 1501.0, 'words': words_3001, 'edits': edits(clips=[('clip-long', 'r100', 'r180', 'manual')])},
     {'kind': 'clip', 'clipId': 'clip-long'}, envelope=None, compact=spec, large=True)
# 339 items of 58 letters joined with single spaces are exactly 20,000 bytes; one more letter is 20,001.
spec = {'token': 'a' * 58, 'count': 339, 'idPrefix': 'b', 'timingStep': 0.5}
words_339 = repeated(spec)
result = case('bytes-at-limit', '20,000 UTF-8 bytes pass.', {'sampleRate': 48000, 'durationSeconds': 170.0, 'words': words_339,
              'edits': edits()}, {'kind': 'fullTake'}, envelope=None, compact=spec, large=True)
assert result['utf8Bytes'] == MAX_BYTES, result
case('bytes-over-limit', 'A correction adding one letter makes 20,001 bytes, which refuse with the entry count.',
     {'sampleRate': 48000, 'durationSeconds': 170.0, 'words': words_339, 'edits': edits(corrections={'b7': 'a' * 59})},
     {'kind': 'fullTake'}, envelope=None, compact=spec)

document = {'schema': 'voxclip-voice-lab-scope-rewrite-plan/1',
            'limits': {'maxEntries': MAX_ENTRIES, 'maxBytes': MAX_BYTES, 'maxWordTextLength': MAX_WORD_TEXT_LENGTH,
                       'maxChars': MAX_CHARS},
            'caseCount': len(CASES), 'cases': CASES}
OUT.write_text(json.dumps(document, ensure_ascii=True, indent=1) + '\n', encoding='utf-8')
print('%s: %d cases' % (OUT.name, len(CASES)))
