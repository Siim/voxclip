#!/usr/bin/env python3
"""Write the scope rewrite plan vectors (voice-lab.md section 8.1 item 1 and section 8.9.1).

A clip or Full take Rewrite is "Fix with AI" over the scope. The plan holds the request's entries, its transcript lines
and one character range per line:

- The take, the envelope (when there is one) and the scope's render scope are read first, as `place` reads them. A take,
  envelope or scope it cannot read, including a scope VoiceLabOutputPlanner does not render (a replacement that crosses
  the clip's range, or replacements that overlap), is invalidInput for the whole plan.
- Entries are the scope's kept items in source order, in the ai.md section 11.2 item format (absolute index, display text
  with corrections applied, event label or an ellipsis for unlabeled speech, cut to 100 UTF-16 units without splitting a
  surrogate pair). Unlike section 11.2, which sends every item, cut items are left out, and so are the items an enabled
  replacement of the scope already re-voices (section 8.4 replaced items). A clip keeps only the items from its first to
  its last word.
- Lines are the ai.md section 11.3 `formatTranscript` lines of the entries.
- A line's range is the length budget of its words placed as one replace hunk (section 8.9.1): `place` puts the window
  from the line's first to its last word item in the scope's render scope, `lendableSilence` gives the take-edge pads,
  and the bridge words' length is `f`. The rate is the section 8.9.1 rate: the stored candidates the caller passes, or
  else the take's transcript with corrections applied. A refused window, or no source envelope, falls back to the
  advisory range of the line's own word span (`fullTake` of the line), except a refusal that says the scope does not
  render as it stands (invalidInput naming a replacement), which is invalidInput for the whole plan. The model echoes the
  line's event labels, and Core counts every letter of the returned line, so both bounds add the length of the line's
  non-word entries. A line with no word item gets that length, at least 1, on both bounds. Ranges are capped at the
  request's 5,000.
- More than 3,000 entries is tooManyEntries with the entry count; otherwise more than 20,000 UTF-8 bytes of entry text
  joined with spaces is tooMuchText with that byte count.

The window geometry and the budget come from the existing references, generate_window.py and
generate_length_budget.py; only their definitions are loaded, so their own vectors are not rewritten. Non-ASCII text is
built with chr(). Running the generator twice gives identical bytes. See shared/fixtures/voice-lab/scope-rewrite-README.md.
"""
import ast
import copy
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


def take_project(take):
    """The take as generate_window.py's place reads it, with the replacements already accepted in it."""
    return {'sampleRate': float(take['sampleRate']), 'durationSeconds': take['durationSeconds'], 'words': take['words'],
            'edits': take['edits'], 'segments': take.get('segments', [])}


def plan(take, scope, envelope, candidates=()):
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
    project = take_project(take)
    # The take, the envelope and the render scope are read once, as place reads them; a failure there is the plan's, not a
    # line's. The scope's enabled replacements say which items are already re-voiced.
    try:
        rate, duration = WINDOW['checked_take'](project)[:2]
        if envelope is not None:
            WINDOW['check_envelope'](envelope, rate)
        WINDOW['check_items'](items, rate)
        replaced = WINDOW['ScopeSource'](project, clip_id, rate, duration, items, edits).replaced
    except GeometryError:
        return {'error': 'invalidInput'}
    cut = set(edits['cutWordIds'])
    kept = [position for position in positions if items[position]['id'] not in cut and not replaced[position]]
    entries = [{'index': position, 'text': utf16_prefix(display(items[position], corrections), MAX_WORD_TEXT_LENGTH),
                'start': items[position]['start'], 'end': items[position]['end']} for position in kept]
    if not entries:
        return {'error': 'empty'}
    size = len(' '.join(entry['text'] for entry in entries).encode('utf-8'))
    if len(entries) > MAX_ENTRIES:
        return {'error': 'tooManyEntries', 'count': len(entries)}
    if size > MAX_BYTES:
        return {'error': 'tooMuchText', 'bytes': size}
    texts = {item['id']: display(item, corrections) for item in items}
    rows = [[item['id'], texts[item['id']], item['start'], item['end'], item['kind']] for item in items]
    speech = None
    lines = []
    for first, last in line_bounds(entries):
        line_items = [items[kept[position]] for position in range(first, last + 1)]
        words = [item for item in line_items if item['kind'] == 'word']
        # The labels the model echoes when it returns the line: events count, and an ellipsis has no letters.
        echoed = sum(BUDGET['length'](entries[position]['text']) for position in range(first, last + 1)
                     if items[kept[position]]['kind'] != 'word')
        line = {'line': '[%d-%d]' % (entries[first]['index'], entries[last]['index']),
                'itemIds': [item['id'] for item in line_items]}
        if not words:
            chars = min(max(1, echoed), MAX_CHARS)
            line.update(minChars=chars, maxChars=chars, rangeSource='noSpeech')
            lines.append(line)
            continue
        if speech is None:
            measured = BUDGET['rate_oracle'](rows, edits['pauseThresholdSeconds'],
                                             [(row['text'], row['firstCharStart'], row['lastCharEnd']) for row in candidates])
            if 'error' in measured:
                return {'error': 'invalidInput'}
            speech = measured['charactersPerSecond']
        refusal = None
        try:
            if envelope is None:
                raise GeometryError('noEnvelope')
            budget, seams = window_range(project, clip_id, envelope, words, texts, speech)
            source = 'window'
        except GeometryError as error:
            if error.value['error'] == 'invalidInput' and 'segmentId' in error.value:
                # The scope does not render as it stands (section 8.4 step 6); no line of it can be placed.
                return {'error': 'invalidInput'}
            refusal = error.value['error'] + (' ' + error.value['segmentId'] if 'segmentId' in error.value else '')
            budget = BUDGET['range_oracle'](words[-1]['end'] - words[0]['start'], 0.0, 0, speech, True)
            source = 'lineSpan'
        line.update(minChars=min(budget['minChars'] + echoed, MAX_CHARS), maxChars=min(budget['maxChars'] + echoed, MAX_CHARS),
                    rangeSource=source)
        # Informative only; the suites read neither.
        line['note'] = ('seams ' + seams + ', target %r s, bridge %d' % (budget['targetSeconds'], budget['bridgeLength'])
                        if source == 'window' else 'refused: ' + refusal) + (', labels %d' % echoed if echoed else '')
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


def segment_input(segment):
    """A replacement as the vectors carry it: its source range and first and last word, and the kind and fade of its
    selected recipe's seams, which is all `place` reads. The suite builds the segment on the passage fixture's."""
    window = segment['window']
    return {'id': segment['id'], 'enabled': segment['enabled'], 'start': window['start'], 'end': window['end'],
            'firstWordId': window['firstWordId'], 'lastWordId': window['lastWordId'],
            'inSeam': {'kind': window['leftSeam']['kind'], 'fadeSamples': window['leftSeam']['fadeSamples']},
            'outSeam': {'kind': window['rightSeam']['kind'], 'fadeSamples': window['rightSeam']['fadeSamples']}}


def accept(take, envelope, first, last, clip_id=None, enabled=True):
    """Accepts a replacement on the window `place` gives first..last in `clip_id`'s scope beside the take's replacements so
    far, as generate_window.py's window_case does, and returns the take with it. The take passed in is not changed."""
    project = take_project(take)
    window = WINDOW['place'](project, clip_id, envelope, first, last)
    assert WINDOW['render_failure'](project, clip_id, window) is None, (first, last)
    result = copy.deepcopy(take)
    result.setdefault('segments', []).append({'id': 'r%d' % (len(result['segments']) + 1), 'enabled': enabled, 'window': window})
    return result


def case(name, note, take, scope, envelope=True, instruction='Fix slips and repeats.', language='en', compact=None, large=False,
         candidates=()):
    items = take['words']
    env = envelope_for(items, take['sampleRate'], take['durationSeconds']) if envelope is True else envelope
    expected = plan(take, scope, env, candidates)
    value = {'sampleRate': take['sampleRate'], 'durationSeconds': take['durationSeconds']}
    if compact is not None:
        value['wordsRepeat'] = compact
    else:
        value['words'] = items
    value.update(edits=take['edits'], envelope=None if env is None else
                 {'sampleRate': env['sampleRate'], 'runs': WINDOW['runs'](env['levels'])},
                 scope=scope, instruction=instruction, language=language)
    if take.get('segments'):
        value['segments'] = [segment_input(segment) for segment in take['segments']]
    if candidates:
        value['rateCandidates'] = list(candidates)
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
CLIP_MID = result

result = case('full-take', 'Full take: cut items left out, a correction ending a sentence, an event-only line (its '
              'label\'s length on both bounds) and a line whose window is refused because the cut filler touches it (advisory span).',
              TAKE_A, {'kind': 'fullTake'}, instruction='Make it clearer. Keep my words where they work; change as little as possible.')
assert sources(result) == ['window', 'window', 'window', 'noSpeech', 'lineSpan'], result
assert result['lines'][-1]['note'] == 'refused: seamFadeCrossesCut', result
assert (result['lines'][3]['minChars'], result['lines'][3]['maxChars']) == (8, 8), result

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

result = case('no-envelope', 'Without the source envelope no window is placed: every line with words takes its advisory span. '
              'The line that starts with "(laughs)" adds its 6 letters to both bounds, because the model echoes the label.',
              TAKE_A, {'kind': 'fullTake'}, envelope=None)
assert sources(result) == ['lineSpan', 'lineSpan', 'lineSpan', 'noSpeech', 'lineSpan'], result
spans = [BUDGET['range_oracle'](end - start, 0.0, 0, BUDGET['rate_oracle'](
    [[item['id'], TAKE_A_EDITS['corrections'].get(item['id'], item['text']), item['start'], item['end'], item['kind']]
     for item in TAKE_A_WORDS], 1.0, [])['charactersPerSecond'], True) for start, end in [(1.30, 2.90), (3.50, 5.00)]]
assert [(line['minChars'], line['maxChars']) for line in result['lines'][1:3]] == \
    [(spans[0]['minChars'], spans[0]['maxChars']), (spans[1]['minChars'] + 6, spans[1]['maxChars'] + 6)], result

case('all-cut', 'A clip whose only item is cut keeps nothing.', TAKE_A, {'kind': 'clip', 'clipId': 'clip-all-cut'})
case('unknown-clip', 'An unknown clip ID is invalid input.', TAKE_A, {'kind': 'clip', 'clipId': 'clip-missing'})
case('selection', 'A selection is a passage for VoiceRewriteService (section 8.1 item 2), not a scope plan.', TAKE_A,
     {'kind': 'selection', 'first': 3, 'last': 8})
case('envelope-rate-mismatch', 'An envelope on another rate than the source is invalid input, never a silent fallback.', TAKE_A,
     {'kind': 'fullTake'}, envelope={'sampleRate': 44100, 'levels': [WINDOW['ROOM']] * 960})

# Replacements already accepted (section 8.4). An item wholly inside an enabled replacement of the scope is already
# re-voiced: its cuts and corrections are dormant and no window may overlap it, so it is never an entry, and the model
# never sees words the video no longer has. Each replacement here is placed by `place` itself, as the window vectors do.
ENVELOPE_A = envelope_for(TAKE_A_WORDS, 48000, 9.6)
revoiced = accept(TAKE_A, ENVELOPE_A, 'w11', 'w11', 'clip-mid')
result = case('replacement-inside-line', '"cuts" was re-voiced in clip-mid. The clip leaves it out, so its line runs from "It" to '
              '"fast." on both sides of the replacement: that window overlaps r1 and takes the advisory span.', revoiced,
              {'kind': 'clip', 'clipId': 'clip-mid'}, envelope=ENVELOPE_A)
assert [entry['index'] for entry in result['entries']] == [3, 4, 5, 7, 8, 9, 10, 12, 13, 14], result
assert result['lines'][0] == CLIP_MID['lines'][0], result
assert result['lines'][1]['rangeSource'] == 'lineSpan' and result['lines'][1]['note'].startswith('refused: overlapsReplacement r1'), result
result = case('replacement-disabled', 'The same replacement turned off renders source again: the plan is clip-cuts-corrections.',
              accept(TAKE_A, ENVELOPE_A, 'w11', 'w11', 'clip-mid', enabled=False), {'kind': 'clip', 'clipId': 'clip-mid'},
              envelope=ENVELOPE_A)
assert result == CLIP_MID, result
revoiced = accept(TAKE_A, ENVELOPE_A, 'w5', 'w8')
result = case('replacement-beside-lines', '"we ship the the new editor." was re-voiced in Full take, its window reaching back over '
              '"we ship" as bridges. That line is gone; the lines before and after it are placed beside r1.', revoiced,
              {'kind': 'fullTake'}, envelope=ENVELOPE_A)
assert [line['line'] for line in result['lines']][:2] == ['[0-2]', '[9-14]'], result
assert all(not set(line['itemIds']) & {'w3', 'w4', 'w5', 'w7', 'w8'} for line in result['lines']), result
assert sources(result)[:2] == ['window', 'window'], result
case('clip-crosses-replacement', 'That Full take replacement starts in the pause before "we", before clip-mid\'s clipTimes '
     'head: the clip boundary crosses it, so clip-mid does not render (section 10.2) and the plan is invalid input.', revoiced,
     {'kind': 'clip', 'clipId': 'clip-mid'}, envelope=ENVELOPE_A)
case('clip-crosses-replacement-no-envelope', 'The scope is read without an envelope too.', revoiced,
     {'kind': 'clip', 'clipId': 'clip-mid'}, envelope=None)
# Cutting w3 and w4 after r1 was accepted leaves a 5 ms sliver of kept source after it, too short for its fade's outer
# half (window-cases.json replacement-cut-leaves-sliver): placing "w1" reports that the scope does not render as it
# stands, which no other line can mend.
sliver = {'sampleRate': 48000, 'durationSeconds': 3.4, 'edits': edits(threshold=0.8),
          'words': WINDOW['gaps_words']([(0.20, 0.50), (0.80, 1.10), (1.24, 1.50), (1.705, 1.80), (2.40, 2.70)])}
sliver = accept(sliver, envelope_for(sliver['words'], 48000, 3.4), 'w2', 'w2')
sliver['edits']['cutWordIds'] += ['w3', 'w4']
case('scope-does-not-render', 'An edit after acceptance left r1\'s fade without kept source: place names r1 with '
     'invalidInput, and the whole plan is invalid input, never a line fallback.', sliver, {'kind': 'fullTake'})
single = {'sampleRate': 48000, 'durationSeconds': 2.0, 'words': [word('a', 'Hello.', 0.5, 1.0)], 'edits': edits()}
case('all-revoiced', 'A scope whose every item is already re-voiced keeps nothing.',
     accept(single, envelope_for(single['words'], 48000, 2.0), 'a', 'a'), {'kind': 'fullTake'})

# The section 8.9.1 rate: once the project stores candidates for the voice, model and language, their rate replaces the
# transcript's. 19 letters over 2.5 s is 7.6 per second, much slower than this take's own 12.7.
STORED = [{'text': 'We ship the new editor.', 'firstCharStart': 0.12, 'lastCharEnd': 2.62}]
result = case('stored-candidate-rate', 'clip-cuts-corrections with a stored candidate for the key: the candidate rate sets every '
              'range.', TAKE_A, {'kind': 'clip', 'clipId': 'clip-mid'}, candidates=STORED)
assert [line['minChars'] for line in result['lines']] != [line['minChars'] for line in CLIP_MID['lines']], result
case('malformed-rate-candidate', 'A candidate span that ends where it starts is invalid input, never a silent fallback.',
     TAKE_A, {'kind': 'clip', 'clipId': 'clip-mid'},
     candidates=[{'text': 'We ship.', 'firstCharStart': 0.5, 'lastCharEnd': 0.5}])

# An event that ends a line: the window holds the words before it, and both bounds add the label's 6 letters the model
# echoes, so keeping the label never pushes an edit out of range.
edge = {'sampleRate': 48000, 'durationSeconds': 4.0, 'edits': edits(),
        'words': [word('a', 'We', 0.20, 0.40), word('b', 'did', 0.45, 0.70), word('c', 'it', 0.75, 1.00),
                  word('d', '(laughs)', 1.05, 1.50, 'event'), word('e', 'Right.', 3.00, 3.40)]}
result = case('event-at-line-end', 'A line that ends with an event: its window budget plus the label\'s length.', edge,
              {'kind': 'fullTake'})
assert sources(result) == ['window', 'window'] and result['lines'][0]['note'].endswith(', labels 6'), result

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
case('bytes-over-limit', 'A correction adding one letter makes 20,001 bytes, which refuse as too much text with the byte '
     'count.', {'sampleRate': 48000, 'durationSeconds': 170.0, 'words': words_339, 'edits': edits(corrections={'b7': 'a' * 59})},
     {'kind': 'fullTake'}, envelope=None, compact=spec)
# 3,001 items of 6 letters are 21,006 bytes: over both limits, the entry limit is reported.
spec = {'token': 'abcdef', 'count': 3001, 'idPrefix': 'q', 'timingStep': 0.5}
case('entries-and-bytes-over-limit', 'Over both limits, the entry count is reported.', {'sampleRate': 48000,
     'durationSeconds': 1501.0, 'words': repeated(spec), 'edits': edits()}, {'kind': 'fullTake'}, envelope=None, compact=spec)

document = {'schema': 'voxclip-voice-lab-scope-rewrite-plan/1',
            'limits': {'maxEntries': MAX_ENTRIES, 'maxBytes': MAX_BYTES, 'maxWordTextLength': MAX_WORD_TEXT_LENGTH,
                       'maxChars': MAX_CHARS},
            'caseCount': len(CASES), 'cases': CASES}
OUT.write_text(json.dumps(document, ensure_ascii=True, indent=1) + '\n', encoding='utf-8')
print('%s: %d cases' % (OUT.name, len(CASES)))
