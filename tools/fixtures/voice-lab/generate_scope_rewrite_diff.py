#!/usr/bin/env python3
"""Write the scope rewrite diff vectors (voice-lab.md section 8.1 item 1 and section 8.2).

A clip or Full take Rewrite proposal holds one edit per changed line: the line's whole new text. ScopeRewriteDiff turns
the edits into review hunks in transcript order:

- Echoed labels. The model reads a line's events as their labels and unlabeled speech as an ellipsis, and may return
  them. The edit's tokens are paired with the line as the model read it, by the section 8.2 LCS over the entries' texts
  with every entry tokenised. A non-word entry is echoed when each of its tokens pairs with an equal operation and no
  inserted token falls between them. Echoed tokens are dropped, and each echoed entry splits the line into stretches:
  the items and new tokens between two echoed entries are diffed alone.
- Per stretch, VoiceLabWordDiff runs on the stretch's items as the transcript holds them (corrections applied).
- Across stretches, section 8.2 step 6 runs once more in transcript order: each stretch's first voice hunk may merge
  with the last voice hunk before it. Word counts, times and barriers read the plan's kept items, and a hunk's source
  token indices address the word tokens of all the plan's lines in order.
- An insertion into a stretch without a word item anchors at the start of the stretch's first item, else at the start
  of the echoed entry after it, else at the end of the one before it, and is never merged.
- Each hunk carries the line labels and reasons of the edits it comes from, and checkThis when one of its own new
  tokens is a token the section 8.1 rule flags in its edit.

The plan comes from generate_scope_rewrite.py, the diff from generate_word_diff.py and the edit validation and the
checkThis rule from generate_patch_rewrite.py; only their definitions are loaded, so their own vectors are not rewritten.
Non-ASCII text is built with chr(). Running the generator twice gives identical bytes. See
shared/fixtures/voice-lab/scope-rewrite-README.md.
"""
import ast
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
OUT = ROOT / 'shared/fixtures/voice-lab/scope-rewrite-diff-cases.json'
PATCH_CASES = ROOT / 'shared/fixtures/voice-lab/patch-rewrite-cases.json'
MERGE_WORDS = 2
MERGE_SECONDS = 0.35
ELLIPSIS = chr(0x2026)

assert Path(__file__).read_text(encoding='utf-8').isascii(), 'write non-ASCII characters with chr()'


def definitions(name, constants=None):
    """A generator's imports, functions and classes, and its upper-case constants (only those named in `constants`, when
    given), without running its cases."""
    path = HERE / name
    tree = ast.parse(path.read_text(encoding='utf-8'), str(path))

    def wanted(node):
        if isinstance(node, (ast.Import, ast.ImportFrom, ast.FunctionDef, ast.ClassDef)):
            return True
        if not isinstance(node, ast.Assign) or not all(isinstance(target, ast.Name) for target in node.targets):
            return False
        return all(target.id.isupper() and (constants is None or target.id in constants) for target in node.targets)

    namespace = {'__file__': str(path), '__name__': path.stem}
    body = [node for node in tree.body if wanted(node)]
    exec(compile(ast.Module(body=body, type_ignores=[]), str(path), 'exec'), namespace)
    return namespace


PLAN = definitions('generate_scope_rewrite.py', {
    'HERE', 'ROOT', 'MAX_ENTRIES', 'MAX_BYTES', 'MAX_WORD_TEXT_LENGTH', 'MAX_CHARS', 'ELLIPSIS', 'SENTENCE_END', 'WINDOW',
    'BUDGET', 'TAKE_A_WORDS', 'TAKE_A_EDITS', 'TAKE_A'})
PLAN['GeometryError'] = PLAN['WINDOW']['GeometryError']
DIFF = definitions('generate_word_diff.py')
PATCH = definitions('generate_patch_rewrite.py', {
    'ROOT', 'BACKSLASH', 'JS_WHITESPACE', 'SENTENCE_END', 'JSON_SPACE', 'NUMBER', 'HEX_DIGITS', 'SIMPLE_ESCAPES',
    'URL_SCHEME', 'MAX_DEPTH', 'MAX_EDIT_BYTES', 'MAX_TEXT_BYTES', 'INSTRUCTION'})


def flagged_tokens(text, sources):
    """The section 8.1 checkThis rule for each splitWords token of NFC text, in order. The edit's checkThis is true exactly
    when one token is flagged: a digit run never spans whitespace, so each run lies in one token."""
    keys, runs = set(), set()
    for source in sources:
        source = PATCH['nfc'](source)
        runs.update(PATCH['digit_runs'](source))
        keys.update(PATCH['key'](token) for token in PATCH['split_words'](source))
    tokens = PATCH['split_words'](PATCH['nfc'](text))
    flags = []
    for index, token in enumerate(tokens):
        at_start = index == 0 or PATCH['SENTENCE_END'].search(tokens[index - 1]) is not None
        new_key = PATCH['key'](token) not in keys
        flags.append(any(run not in runs for run in PATCH['digit_runs'](token)) or (PATCH['is_url'](token) and new_key)
                     or (PATCH['is_capitalised'](token) and not at_start and new_key))
    assert any(flags) == PATCH['check_this'](text, sources), text
    return flags


def new_start(ops, source):
    """How many new tokens come before a hunk that starts at source token `source`: those of the equal operations before
    it and of the insertions at an earlier source position (an insertion at its own position belongs to the hunk)."""
    count = position = 0
    for op in ops:
        if position >= source:
            break
        if op[0] != 'delete':
            count += 1
        if op[0] != 'insert':
            position += 1
    return count


def scope_diff(lines, instruction, entries, edits):
    """The expected hunks, or an error, for validated `edits` over the plan `lines`: each {'line', 'items': rows of [id,
    text with corrections applied, start, end, kind], 'entries': the line's request entries}."""
    labels = [line['line'] for line in lines]
    by_line = {}
    for edit in edits:
        if edit['line'] not in labels or edit['line'] in by_line:
            return {'error': 'invalidInput'}
        by_line[edit['line']] = edit
    sources = [entry['text'] for entry in entries] + [instruction]
    ids, kinds, tokens, surfaces, parts = [], [], [], [], []
    run = 0
    for line in lines:
        first_item, first_token = len(ids), len(tokens)
        for offset, row in enumerate(line['items']):
            ids.append(row[0])
            kinds.append(row[4])
            if row[4] == 'word':
                for surface in DIFF['tokens'](row[1]):
                    tokens.append((first_item + offset, row[2], row[3]))
                    surfaces.append(surface)
        edit = by_line.get(line['line'])
        if edit is None:
            continue
        # The line as the model read it, every entry a word, so the LCS pairs the labels it echoed.
        read = [[row[0], entry['text'], row[2], row[3], 'word'] for row, entry in zip(line['items'], line['entries'])]
        pairing = DIFF['oracle'](read, edit['text'], 0)
        if 'error' in pairing:
            return {'error': pairing['error'], 'side': pairing['side'], 'count': pairing['count']}
        ops = pairing['ops']
        echoed = []
        for row in line['items']:
            at = [index for index, op in enumerate(ops) if op[1] == row[0]]
            if row[4] != 'word' and at and all(ops[index][0] == 'equal' for index in at) and at[-1] - at[0] + 1 == len(at):
                echoed.append(row)
        echoed_ids = [row[0] for row in echoed]
        flags = flagged_tokens(edit['text'], sources)
        stretches = [{'items': [], 'new': [], 'editIndex': []}]
        for row in line['items']:
            if row[0] in echoed_ids:
                stretches.append({'items': [], 'new': [], 'editIndex': []})
            else:
                stretches[-1]['items'].append(row)
        current, previous, new_index = 0, None, 0
        for op in ops:
            if op[1] in echoed_ids:
                if op[1] != previous:
                    current += 1
                    previous = op[1]
            elif op[3] is not None:
                stretches[current]['new'].append(op[3])
                stretches[current]['editIndex'].append(new_index)
            if op[3] is not None:
                new_index += 1
        assert current == len(echoed) and new_index == len(flags), line['line']
        offset = first_token
        for number, stretch in enumerate(stretches):
            count = sum(len(DIFF['tokens'](row[1])) for row in stretch['items'] if row[4] == 'word')
            start_token, offset = offset, offset + count
            if not stretch['items'] and not stretch['new']:
                continue
            diff = DIFF['oracle'](stretch['items'], ' '.join(stretch['new']), 0)
            if 'error' in diff:
                return {'error': diff['error'], 'side': diff['side'], 'count': diff['count']}
            position = 0
            for op in diff['ops']:
                if op[0] == 'equal':
                    surfaces[start_token + position] = op[3]
                if op[0] != 'insert':
                    position += 1
            first_voice = True
            for hunk in diff['hunks']:
                hunk = dict(hunk, sourceStartIndex=start_token + hunk['sourceStartIndex'],
                            sourceEndIndex=start_token + hunk['sourceEndIndex'])
                local = hunk['sourceStartIndex'] - start_token
                insert_item = None
                if hunk['sourceStartIndex'] == hunk['sourceEndIndex']:
                    if count == 0:
                        hunk['anchorSeconds'] = (stretch['items'][0][2] if stretch['items'] else echoed[number][2]
                                                 if number < len(echoed) else echoed[number - 1][3])
                    else:
                        insert_item = tokens[start_token + min(local, count - 1)][0]
                begin = new_start(diff['ops'], local)
                flagged = any(flags[stretch['editIndex'][begin + index]] for index in range(len(hunk['newTokens'])))
                parts.append({'hunk': hunk, 'lines': [edit['line']], 'reasons': [edit['reason']], 'checkThis': flagged,
                              'run': run, 'firstVoice': hunk['kind'] == 'voice' and first_voice, 'wordless': count == 0,
                              'insertItem': insert_item})
                if hunk['kind'] == 'voice':
                    first_voice = False
            run += 1

    def start_time(part):
        hunk = part['hunk']
        return tokens[hunk['sourceStartIndex']][1] if hunk['sourceStartIndex'] < hunk['sourceEndIndex'] else hunk['anchorSeconds']

    def end_time(part):
        hunk = part['hunk']
        return tokens[hunk['sourceEndIndex'] - 1][2] if hunk['sourceStartIndex'] < hunk['sourceEndIndex'] else hunk['anchorSeconds']

    def first_item(part):
        hunk = part['hunk']
        return tokens[hunk['sourceStartIndex']][0] if hunk['sourceStartIndex'] < hunk['sourceEndIndex'] else part['insertItem']

    def last_item(part):
        hunk = part['hunk']
        return tokens[hunk['sourceEndIndex'] - 1][0] if hunk['sourceStartIndex'] < hunk['sourceEndIndex'] else part['insertItem']

    merged = []
    for part in parts:
        earlier_index = next((index for index in reversed(range(len(merged))) if merged[index]['hunk']['kind'] == 'voice'), None)
        if part['firstVoice'] and not part['wordless'] and earlier_index is not None and not merged[earlier_index]['wordless'] \
                and all(other['hunk']['kind'] != 'cut' for other in merged[earlier_index + 1:]):
            earlier = merged[earlier_index]
            between = range(earlier['hunk']['sourceEndIndex'], part['hunk']['sourceStartIndex'])
            bridges = list(dict.fromkeys(ids[tokens[index][0]] for index in between))
            gap = start_time(part) - end_time(earlier)
            left, right = last_item(earlier), first_item(part)
            barrier = any(kinds[index] != 'word' for index in range(left + 1, right))
            if not barrier and (len(bridges) <= MERGE_WORDS or gap <= MERGE_SECONDS):
                pieces = merged[earlier_index:] + [part]
                labels_reasons = list(dict.fromkeys((label, reason) for piece in pieces
                                                    for label, reason in zip(piece['lines'], piece['reasons'])))
                start, end = earlier['hunk']['sourceStartIndex'], part['hunk']['sourceEndIndex']
                hunk = {'kind': 'voice',
                        'sourceWordIds': list(dict.fromkeys(earlier['hunk']['sourceWordIds'] + bridges + part['hunk']['sourceWordIds'])),
                        'newTokens': earlier['hunk']['newTokens'] + [surfaces[index] for index in between] + part['hunk']['newTokens'],
                        'correctedTexts': [],
                        'absorbedItemIds': earlier['hunk']['absorbedItemIds'] + part['hunk']['absorbedItemIds'],
                        'bridgeWordIds': list(dict.fromkeys(earlier['hunk']['bridgeWordIds'] + bridges + part['hunk']['bridgeWordIds'])),
                        'sourceStartIndex': start, 'sourceEndIndex': end,
                        'anchorSeconds': earlier['hunk']['anchorSeconds'] if start == end else None}
                del merged[earlier_index:]
                merged.append({'hunk': hunk, 'lines': [label for label, _ in labels_reasons],
                               'reasons': [reason for _, reason in labels_reasons],
                               'checkThis': any(piece['checkThis'] for piece in pieces), 'run': part['run'], 'firstVoice': False,
                               'wordless': False, 'insertItem': part['insertItem']})
                continue
        merged.append(part)
    for part in merged:
        assert not part['checkThis'] or any(by_line[label]['checkThis'] for label in part['lines']), part
    return {'hunks': [dict(part['hunk'], lines=part['lines'], reasons=part['reasons'], checkThis=part['checkThis'])
                      for part in merged]}


def plan_lines(take, expected_plan):
    """The plan's lines with their items as the transcript holds them (corrections applied) and their request entries."""
    items = {item['id']: item for item in take['words']}
    corrections = take['edits']['corrections']
    lines, at = [], 0
    for line in expected_plan['lines']:
        count = len(line['itemIds'])
        rows = [[ident, corrections.get(ident, items[ident]['text']) if items[ident]['kind'] == 'word' else items[ident]['text'],
                 items[ident]['start'], items[ident]['end'], items[ident]['kind']] for ident in line['itemIds']]
        lines.append({'line': line['line'], 'items': rows, 'entries': expected_plan['entries'][at:at + count]})
        at += count
    return lines


CASES = []


def case(name, note, take, reply=None, proposal=None, scope=None, instruction='Fix slips and repeats.'):
    """One scope case: the plan of `take` without an envelope (ranges only set inRange, which the diff does not read), then
    `reply`, the model's raw reply holding these edits, validated as PatchRewriteService validates it, or `proposal`, edits
    taken as they are (for the refusals the validator would have dropped)."""
    scope = scope or {'kind': 'fullTake'}
    expected_plan = PLAN['plan'](take, scope, None)
    assert 'lines' in expected_plan, (name, expected_plan)
    ranges = [{'line': line['line'], 'minChars': line['minChars'], 'maxChars': line['maxChars']} for line in expected_plan['lines']]
    value = {'sampleRate': take['sampleRate'], 'durationSeconds': take['durationSeconds'], 'words': take['words'],
             'edits': take['edits'], 'envelope': None, 'scope': scope, 'instruction': instruction, 'language': 'en'}
    if proposal is not None:
        value['proposal'] = proposal
        edits = [dict(edit, isDeletion=PATCH['js_trim'](edit['text']) == '') for edit in proposal]
        summary = None
    else:
        value['reply'] = json.dumps({'edits': reply}, ensure_ascii=False, separators=(',', ':'))
        validated = PATCH['validate'](value['reply'], instruction, expected_plan['entries'], ranges)
        edits = validated['edits']
        assert (validated['unknownLines'], validated['duplicateLines'], validated['malformedItems']) == (0, 0, 0), name
        summary = [{'line': edit['line'], 'inRange': edit['inRange'], 'checkThis': edit['checkThis'],
                    'isDeletion': edit['isDeletion']} for edit in edits]
    expected = scope_diff(plan_lines(take, expected_plan), instruction, expected_plan['entries'], edits)
    if summary is not None and 'error' not in expected:
        expected = {'edits': summary, **expected}
    CASES.append({'name': name, 'note': note, 'input': value, 'expected': expected})
    return expected


word, edits = PLAN['word'], PLAN['edits']


def reply_edit(line, text, reason='Fixes the line.'):
    return {'line': line, 'text': text, 'reason': reason}


def shape(result):
    """(kind, source IDs, new text, bridge IDs) of each hunk, for the hand-stated outcomes below."""
    return [(hunk['kind'], hunk['sourceWordIds'], ' '.join(hunk['newTokens']), hunk['bridgeWordIds']) for hunk in result['hunks']]


# Two sentences, one line each: [0-5] and [6-9].
TWO = {'sampleRate': 48000, 'durationSeconds': 3.2, 'edits': edits(), 'words': [
    word('a0', 'So', 0.00, 0.20), word('a1', 'last', 0.25, 0.50), word('a2', 'year', 0.55, 0.80), word('a3', 'we', 0.85, 1.00),
    word('a4', 'shipped', 1.05, 1.40), word('a5', 'it.', 1.45, 1.70), word('a6', 'Then', 1.80, 2.00),
    word('a7', 'we', 2.05, 2.20), word('a8', 'fixed', 2.25, 2.60), word('a9', 'bugs.', 2.65, 3.00)]}

result = case('cross-line-merge-adjacent', 'The last word of [0-5] and the first of [6-9] are each re-voiced. No word lies between '
              'them, so step 6 merges them across the line boundary into one hunk carrying both lines and both reasons. The new '
              '"2" is a digit run no source has, so the merged hunk carries checkThis.', TWO,
              [reply_edit('[0-5]', 'So last year we shipped version 2.', 'Names the version.'),
               reply_edit('[6-9]', 'Now we fixed bugs.', 'Smoother start.')])
assert shape(result) == [('voice', ['a5', 'a6'], 'version 2. Now', [])], result
assert result['hunks'][0]['lines'] == ['[0-5]', '[6-9]'] and result['hunks'][0]['checkThis'], result

result = case('cross-line-merge-one-bridge', '"shipped" and "Then" are re-voiced; "it." lies between them, one word item, so they '
              'merge and "it." becomes a bridge, re-voiced with its own surface.', TWO,
              [reply_edit('[0-5]', 'So last year we released it.'), reply_edit('[6-9]', 'Now we fixed bugs.')])
assert shape(result) == [('voice', ['a4', 'a5', 'a6'], 'released it. Now', ['a5'])], result

result = case('cross-line-no-merge', '"year" and "Then" are three word items and 1.0 s apart: two hunks.', TWO,
              [reply_edit('[0-5]', 'So last spring we shipped it.'), reply_edit('[6-9]', 'Now we fixed bugs.')])
assert shape(result) == [('voice', ['a2'], 'spring', []), ('voice', ['a6'], 'Now', [])], result

# A fast take for the time rule: three word items between the hunks, but little time.
FAST = {'sampleRate': 48000, 'durationSeconds': 1.0, 'edits': edits(), 'words': [
    word('c0', 'One', 0.000, 0.125), word('c1', 'two', 0.175, 0.195), word('c2', 'three', 0.225, 0.245),
    word('c3', 'four.', 0.275, 0.295), word('c4', 'Five', 0.475, 0.495), word('c5', 'six', 0.525, 0.545),
    word('c6', 'seven.', 0.575, 0.600)]}
result = case('cross-line-merge-by-time', '"One" and "Five" have three word items between them, but "Five" starts exactly 0.35 s '
              'after "One" ends (binary64, inclusive): they merge with three bridges.', FAST,
              [reply_edit('[0-3]', 'Uno two three four.'), reply_edit('[4-6]', 'Cinco six seven.')])
assert shape(result) == [('voice', ['c0', 'c1', 'c2', 'c3', 'c4'], 'Uno two three four. Cinco', ['c1', 'c2', 'c3'])], result
assert FAST['words'][4]['start'] - FAST['words'][0]['end'] == MERGE_SECONDS
result = case('cross-line-bridge-fix-absorbed', 'A capital fix to "three" lies between "One" and "Five". Within [0-3] it stays a '
              'text-only hunk beside the voice hunk; the merge across the line absorbs it with its new surface. "Three" is a capital no '
              'source has, so the merged hunk carries checkThis.', FAST,
              [reply_edit('[0-3]', 'Uno two Three four.'), reply_edit('[4-6]', 'Cinco six seven.')])
assert shape(result) == [('voice', ['c0', 'c1', 'c2', 'c3', 'c4'], 'Uno two Three four. Cinco', ['c1', 'c2', 'c3'])], result
result = case('cross-line-cut-barrier', 'The same edits, but [0-3] also cuts "four." between the voice hunks: a cut between '
              'voice hunks prevents the merge, across lines as within one.', FAST,
              [reply_edit('[0-3]', 'Uno two three'), reply_edit('[4-6]', 'Cinco six seven.')])
assert shape(result) == [('voice', ['c0'], 'Uno', []), ('cut', ['c3'], '', []), ('voice', ['c4'], 'Cinco', [])], result

# An event that starts the second line is a barrier, whether the model echoes its label or not.
EVENT = {'sampleRate': 48000, 'durationSeconds': 3.6, 'edits': edits(), 'words': [
    word('b0', 'We', 0.00, 0.20), word('b1', 'shipped', 0.25, 0.60), word('b2', 'it.', 0.65, 0.90),
    word('b3', '(applause)', 0.95, 1.60, 'event'), word('b4', 'Then', 1.65, 1.80), word('b5', 'we', 1.85, 2.00),
    word('b6', 'fixed', 2.05, 2.40), word('b7', 'bugs.', 2.45, 2.80)]}
result = case('cross-line-event-barrier', '"it." ends [0-2] and "Then" follows the applause in [3-7]: never merged across the '
              'event. The echoed label is dropped from the new text and never spoken.', EVENT,
              [reply_edit('[0-2]', 'We shipped that.'), reply_edit('[3-7]', '(applause) Now we fixed bugs.')])
assert shape(result) == [('voice', ['b2'], 'that.', []), ('voice', ['b4'], 'Now', [])], result

# Labels inside a line: echoed, they split it; left out, a voice hunk across them absorbs them.
LAUGH = {'sampleRate': 48000, 'durationSeconds': 2.6, 'edits': edits(), 'words': [
    word('d0', 'We', 0.00, 0.20), word('d1', 'were', 0.25, 0.45), word('d2', '(laughs)', 0.50, 1.10, 'event'),
    word('d3', 'late.', 1.15, 1.50), word('d4', 'It', 1.70, 1.80), word('d5', 'cuts', 1.85, 2.05),
    word('d6', 'mm', 2.10, 2.20, 'unlabeledSpeech'), word('d7', 'fast.', 2.25, 2.50)]}
result = case('echoed-label-splits-line', 'The model keeps "(laughs)" between two changed words: the line splits there, each side '
              'is diffed alone, the event is a barrier and stays.', LAUGH, [reply_edit('[0-3]', 'We are (laughs) early.')])
assert shape(result) == [('voice', ['d1'], 'are', []), ('voice', ['d3'], 'early.', [])], result
assert all(not hunk['absorbedItemIds'] for hunk in result['hunks']), result
result = case('dropped-label-absorbed', 'The same change without the label: one stretch, one voice hunk across the event, which it '
              'absorbs (section 8.2 step 6).', LAUGH, [reply_edit('[0-3]', 'We are early.')])
assert shape(result) == [('voice', ['d1', 'd3'], 'are early.', [])] and result['hunks'][0]['absorbedItemIds'] == ['d2'], result
result = case('dropped-label-no-change', 'Leaving the label out and changing nothing else changes nothing: cuts and fixes never '
              'touch events.', LAUGH, [reply_edit('[0-3]', 'We were late.')])
assert result['hunks'] == [], result
result = case('flagged-label-echo', 'An echoed label written with a capital flags the edit, but it is dropped and never '
              'spoken, so no hunk carries checkThis.', LAUGH, [reply_edit('[0-3]', 'We are (Laughs) late.')])
assert shape(result) == [('voice', ['d1'], 'are', [])] and not result['hunks'][0]['checkThis'] and result['edits'][0]['checkThis'], result
result = case('echoed-ellipsis', 'Unlabeled speech reads as an ellipsis; the model keeps it, so only "fast." changes.', LAUGH,
              [reply_edit('[4-7]', 'It cuts ' + ELLIPSIS + ' quickly.')])
assert shape(result) == [('voice', ['d7'], 'quickly.', [])], result
result = case('changed-label-is-words', 'A label the model changed is not echoed: its tokens are new words, here re-voicing '
              '"were" with "(laughing)" spoken. Its key is not in the transcript and it follows an ordinary word, so checkThis '
              'flags it.', LAUGH, [reply_edit('[0-3]', 'We (Laughing) late.')])
assert shape(result) == [('voice', ['d1'], '(Laughing)', [])] and result['hunks'][0]['checkThis'], result

# An event-only line: an insertion there has no word to anchor on.
ALONE = {'sampleRate': 48000, 'durationSeconds': 6.0, 'edits': edits(), 'words': [
    word('e0', 'We', 0.00, 0.20), word('e1', 'did', 0.25, 0.50), word('e2', 'it.', 0.55, 0.80),
    word('e3', '(applause)', 2.20, 3.00, 'event'), word('e4', 'Thanks', 4.40, 4.80), word('e5', 'all.', 4.85, 5.20)]}
result = case('insert-after-echoed-label', 'Words added after the echoed "(applause)" anchor at its end. An insertion into a '
              'stretch without a word item is never merged, even with re-voiced words right before and after it.', ALONE,
              [reply_edit('[0-2]', 'We did this.'), reply_edit('[3-3]', '(applause) Thank you.'), reply_edit('[4-5]', 'Cheers all.')])
assert shape(result) == [('voice', ['e2'], 'this.', []), ('voice', [], 'Thank you.', []), ('voice', ['e4'], 'Cheers', [])], result
assert result['hunks'][1]['anchorSeconds'] == 3.0 and result['hunks'][1]['sourceStartIndex'] == 3, result
result = case('insert-before-echoed-label', 'Words added before the label anchor at its start.', ALONE,
              [reply_edit('[3-3]', 'Thank you. (applause)')])
assert result['hunks'][0]['anchorSeconds'] == 2.2, result
result = case('insert-replacing-label', 'Without the label the stretch is the whole line, which holds the event and no word: the '
              'insertion anchors at the event\'s start and does not absorb it.', ALONE, [reply_edit('[3-3]', 'Thank you.')])
assert result['hunks'][0]['anchorSeconds'] == 2.2 and result['hunks'][0]['absorbedItemIds'] == [], result

# Deleting whole lines: cut hunks, and an event inside a deleted line stays.
result = case('whole-line-deletion', 'An empty text deletes [6-9]: one cut hunk of its words, nothing to re-voice.', TWO,
              [reply_edit('[6-9]', '', 'Not needed.')])
assert shape(result) == [('cut', ['a6', 'a7', 'a8', 'a9'], '', [])] and result['edits'][0]['isDeletion'], result
result = case('whole-line-deletion-keeps-events', 'Deleting [0-3] cuts its three words; the laugh between them is never cut.',
              LAUGH, [reply_edit('[0-3]', '   ')])
assert shape(result) == [('cut', ['d0', 'd1', 'd3'], '', [])], result
result = case('labels-only-left', 'A text of only the echoed label keeps the event and cuts the words on each side of it, one '
              'cut hunk per stretch; it is no deletion, so it is out of range.', LAUGH, [reply_edit('[0-3]', '(laughs)')])
assert shape(result) == [('cut', ['d0', 'd1'], '', []), ('cut', ['d3'], '', [])] and not result['edits'][0]['isDeletion'], result

# Surface-only fixes, including a multi-word correction, against the corrected text.
FIX = {'sampleRate': 48000, 'durationSeconds': 2.4, 'edits': edits(corrections={'f1': 'going to'}), 'words': [
    word('f0', 'We', 0.00, 0.20), word('f1', 'gonna', 0.25, 0.60), word('f2', 'ship', 0.65, 0.90), word('f3', 'it', 0.95, 1.10),
    word('f4', 'today.', 1.15, 1.50)]}
result = case('surface-only-fix', 'Commas and a capital: text-only hunks with one corrected text per item. "going to" is the '
              'correction, so the diff reads it, and its fix keeps both words on its one item. "Going" is a capital no source has, '
              'so the fix carries checkThis (the rule is a heuristic).', FIX,
              [reply_edit('[0-4]', 'We, Going to ship it today.')])
assert shape(result) == [('textOnly', ['f0', 'f1'], 'We, Going to', [])] and result['hunks'][0]['correctedTexts'] == ['We,', 'Going to'], result
result = case('partial-correction-revoices-item', 'Changing one word of the two-word correction re-voices the whole item with its '
              'kept word (section 8.2 step 4).', FIX, [reply_edit('[0-4]', 'We aiming to ship it today.')])
assert shape(result) == [('voice', ['f1'], 'aiming to', [])], result
result = case('unchanged-echo', 'An edit identical to its line gives no hunk.', FIX, [reply_edit('[0-4]', 'We going to ship it today.')])
assert result['hunks'] == [], result

# checkThis goes to the hunk whose own new tokens the rule flags, not to every hunk of the line.
STUDIO = {'sampleRate': 48000, 'durationSeconds': 2.4, 'edits': edits(), 'words': [
    word('g0', 'We', 0.00, 0.20), word('g1', 'moved', 0.25, 0.50), word('g2', 'to', 0.55, 0.65), word('g3', 'the', 0.70, 0.80),
    word('g4', 'old', 0.85, 1.00), word('g5', 'studio', 1.05, 1.40), word('g6', 'in', 1.45, 1.55), word('g7', 'May.', 1.60, 1.90)]}
result = case('check-this-on-its-hunk', '"went" is in no source but is lower case; "2026" is a new digit run. Only the second '
              'hunk carries checkThis.', STUDIO, [reply_edit('[0-7]', 'We went to the old studio in 2026.')])
assert [hunk['checkThis'] for hunk in result['hunks']] == [False, True] and result['edits'][0]['checkThis'], result
result = case('check-this-on-a-fix', 'A capital that no source has, mid-sentence, flags a text-only hunk too; the voice hunk of '
              'the same line is not flagged.', STUDIO, [reply_edit('[0-7]', 'We went to the old Studio in May.')])
assert [(hunk['kind'], hunk['checkThis']) for hunk in result['hunks']] == [('voice', False), ('textOnly', True)], result
result = case('check-this-from-instruction', 'The year comes from the instruction, so nothing is flagged.', STUDIO,
              [reply_edit('[0-7]', 'We moved to the old studio in 2025.')], instruction="It was 2025, not May.")
assert [hunk['checkThis'] for hunk in result['hunks']] == [False], result

# The clip and Full take plans leave cut and re-voiced items out, so they never stop a merge. Take A of the plan vectors:
# "um" (w1) is cut between "So" and "today." in [0-2].
TAKE_A = PLAN['TAKE_A']
result = case('cut-item-between-lines', 'Full take of the plan vectors\' take A: "So" and "we" are re-voiced in [0-2] and [3-8]. '
              'Only "today." lies between them as a kept word, so they merge; the cut "um" is not in the plan and stops nothing.',
              TAKE_A, [reply_edit('[0-2]', 'Well today.'), reply_edit('[3-8]', 'they ship the new editor.')])
assert shape(result) == [('voice', ['w0', 'w2', 'w3'], 'Well today. they', ['w2'])], result
result = case('clip-scope', 'clip-mid of take A: the cut repeat w6 is not in the plan; the echoed "(laughs)" and ellipsis are '
              'dropped; a new "Fast" after the ellipsis is a capital no source has.', TAKE_A,
              [reply_edit('[3-8]', 'we ship a new editor.'), reply_edit('[9-14]', '(laughs) It cuts ' + ELLIPSIS + ' words, Fast.')],
              scope={'kind': 'clip', 'clipId': 'clip-mid'})
assert shape(result) == [('voice', ['w5'], 'a', []), ('textOnly', ['w14'], 'Fast.', [])] and result['hunks'][1]['checkThis'], result
result = case('full-take-event-line-and-fix', 'Full take of take A: the event-only line echoed unchanged gives no hunk, and '
              '"watching!" becomes "watching." as a text-only fix.', TAKE_A,
              [reply_edit('[15-15]', '(applause)'), reply_edit('[17-19]', 'Thanks for watching.')])
assert shape(result) == [('textOnly', ['w19'], 'watching.', [])], result

# A proposal that does not fit the plan is refused, never partly diffed.
case('unknown-line', 'An edit for a line the plan does not have (the validator drops these, so this proposal came from elsewhere).',
     TWO, proposal=[{'line': '[0-9]', 'text': 'Hello.', 'reason': 'x', 'checkThis': False}])
case('duplicate-line', 'Two edits for one line.', TWO, proposal=[{'line': '[0-5]', 'text': 'So.', 'reason': 'x', 'checkThis': False},
                                                                  {'line': '[0-5]', 'text': 'Yes.', 'reason': 'y', 'checkThis': False}])

# Every reply of the Fix with AI vectors that validates, mapped to hunks. Each entry is a word item with ID "i" + index; each
# formatTranscript line of the entries is a plan line.
patch = json.loads(PATCH_CASES.read_text(encoding='utf-8'))
PATCH_RESULTS = []
for vector in patch['cases']:
    if 'error' in vector['expected']:
        PATCH_RESULTS.append({'id': vector['id'], 'expected': {'error': vector['expected']['error']}})
        continue
    entries = vector.get('entries', patch['entries'])
    lines = []
    for first, last in PLAN['line_bounds'](entries):
        part = entries[first:last + 1]
        lines.append({'line': '[%d-%d]' % (part[0]['index'], part[-1]['index']), 'entries': part,
                      'items': [['i%d' % entry['index'], entry['text'], entry['start'], entry['end'], 'word'] for entry in part]})
    assert [line['line'] for line in lines] == [item['line'] for item in vector.get('ranges', patch['ranges'])], vector['id']
    PATCH_RESULTS.append({'id': vector['id'],
                          'expected': scope_diff(lines, vector['instruction'], entries, vector['expected']['edits'])})
assert len(PATCH_RESULTS) == len(patch['cases'])

document = {'schema': 'voxclip-voice-lab-scope-rewrite-diff/1',
            'merge': {'words': MERGE_WORDS, 'seconds': MERGE_SECONDS},
            'caseCount': len(CASES), 'cases': CASES,
            'patchRewriteCaseCount': len(PATCH_RESULTS), 'patchRewriteCases': PATCH_RESULTS}
OUT.write_text(json.dumps(document, ensure_ascii=True, indent=1) + '\n', encoding='utf-8')
print('%s: %d cases, %d Fix with AI replies' % (OUT.name, len(CASES), len(PATCH_RESULTS)))
