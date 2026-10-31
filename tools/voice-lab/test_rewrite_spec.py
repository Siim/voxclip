import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


def read(path):
    return (ROOT / path).read_text(encoding='utf-8')


def section(text, heading):
    """The body under the first heading line that starts with `heading`, up to the next heading of the same or a higher level."""
    lines = text.splitlines()
    for index, line in enumerate(lines):
        if line.startswith(heading + ' '):
            level = len(heading.split(' ', 1)[0])
            body = []
            for following in lines[index + 1:]:
                match = re.match(r'(#+) ', following)
                if match and len(match.group(1)) <= level:
                    break
                body.append(following)
            return '\n'.join(body)
    raise AssertionError(f'no heading {heading!r}')


def numbered_item(text, number):
    """Top-level list item `number.` with its indented sub-items."""
    match = re.search(rf'^{number}\. .*?(?=^\d+\. |\Z)', text, re.S | re.M)
    if not match:
        raise AssertionError(f'no item {number}')
    return match.group(0)


def table_rows(text, header):
    """The rows of the Markdown table whose header line is `header`, as lists of stripped cells."""
    lines = text.splitlines()
    start = lines.index(header)
    rows = []
    for line in lines[start + 2:]:
        if not line.startswith('|'):
            break
        cells = line.replace('\\|', '\0').strip('|').split('|')
        rows.append([cell.replace('\0', '|').strip() for cell in cells])
    return rows


def between(text, start, end):
    begin = text.index(start)
    return text[begin:text.index(end, begin)]


def quoted(text):
    return re.findall(r'"([^"]+)"', text)


class RewriteSpecTests(unittest.TestCase):
    """Cross-section consistency of the clip-first Rewrite specs (design.md §6.3, voice-lab.md, ai.md)."""

    @classmethod
    def setUpClass(cls):
        cls.voice_lab = read('doc/spec/voice-lab.md')
        cls.design = read('doc/design.md')
        cls.ai = read('doc/spec/ai.md')

    def test_llm_send_plan_sign_in_is_a_closed_list(self):
        rule = between(section(self.voice_lab, '### 3.1'), 'An LLM send (', '| Estimate |')
        # A plan is named positively, never as "not an API key".
        self.assertNotRegex(rule, r'`authMethod` is not an API key|does not say "API key"')
        self.assertIn('Logged in using ChatGPT', rule)
        unknown = next(line for line in rule.splitlines() if line.startswith('- **Unknown**'))
        for method in ['`third_party`', '`none`', 'any other successful Codex output']:
            self.assertIn(method, unknown)
        self.assertIn('sends nothing', unknown)
        detection = numbered_item(section(self.ai, '### 6.8'), 3)
        plan = re.search(r'It is a plan only when it is (.*?), and an API key', detection)
        self.assertIsNotNone(plan, 'ai.md §6.8 item 3 must list the plan methods')
        plans = set(re.findall(r'`([^`]+)`', plan.group(1)))
        self.assertIn('claude_ai', plans)
        self.assertTrue(plans.isdisjoint({'third_party', 'none', 'api_key'}))
        self.assertRegex(detection, r'Every other value, including `third_party`.*?is an unknown method')
        cost = numbered_item(section(self.voice_lab, '## 15.'), 10)
        for row in ['`claude.ai`', '`third_party`', '`none`', 'an unrecognised status']:
            self.assertIn(row, cost)

    def test_single_enrollment_approval_binds_what_the_creation_quote_binds(self):
        creation = section(self.voice_lab, '### 6.7')
        bound = between(creation, 'The quote binds:', 'Any change to these').splitlines()[1:]
        bound = [line.strip('- ;.').removeprefix('the ').removeprefix("each file's ") for line in bound if line.strip()]
        self.assertGreaterEqual(len(bound), 5)
        terms = [term for line in bound for term in re.split(r', | and ', line)]
        order = numbered_item(section(self.voice_lab, '### 6.4'), 1)
        for term in terms:
            self.assertIn(term, order)
        self.assertIn('only if the plan check passes, Scribe', order)
        self.assertIn('A failed plan check stops before Scribe', order)
        consent = numbered_item(section(self.voice_lab, '## 15.'), 11)
        for term in ['noise-removal choice', "position, role or SHA-256", 'A failed plan check makes no Scribe request']:
            self.assertIn(term, consent)

    def test_scope_entries_do_not_credit_ai_11_2_with_leaving_out_cuts(self):
        self.assertIn('**All** items are included, cut ones too', section(self.ai, '### 11.2'))
        for name, text in [('voice-lab.md §8.1', section(self.voice_lab, '### 8.1')), ('design.md §6.3.6', section(self.design, '#### 6.3.6'))]:
            lines = [line for line in text.splitlines() if '§11.2' in line and re.search(r'\bcut', line)]
            self.assertTrue(lines, name)
            for line in lines:
                self.assertIn('unlike §11.2', line, name)

    def test_voice_lab_copy_points_at_the_clip_first_panel(self):
        # §6.5.2 no longer holds the mismatch copy; design.md §6.3.7 V3 does.
        self.assertNotIn('§6.5.2 copy', self.voice_lab)
        mismatch = between(section(self.design, '#### 6.3.7'), '**V3.', '**V4.')
        self.assertIn('Some of this video\'s audio doesn\'t sound like the voice in your consent statement.', mismatch)
        self.assertEqual(self.voice_lab.count('the mismatch copy of `doc/design.md` §6.3.7 V3'), 2)
        # Copy the clip-first panel replaced is either gone or named as the passage panel's.
        for old in ["That's a lot to re-voice.", 're-voiced phrases (', 'Try different wording or re-record', 'Generate Again']:
            for line in self.voice_lab.splitlines():
                if old in line:
                    self.assertIn("passage panel's", line, old)
                    self.assertIn('design.md` §6.3.6 R2', line, old)

    def test_v1_speech_row_covers_every_scope(self):
        voice = section(self.design, '#### 6.3.7')
        ok = next(line for line in between(voice, '**V1. Agree**', '**V2.').splitlines() if line.strip().startswith('- ok:'))
        # Full take and a selection outside every clip have no preferRange (voice-lab.md §6.5.2).
        self.assertIn('when `preferRange` is absent', ok)
        self.assertIn('for a selection is the clip containing it', ok)
        scope_words = between(section(self.design, '### 6.3'), '**Scope words.**', '#### 6.3.1')
        self.assertIn('The V1 speech row and its strip (§6.3.7) are the exception', scope_words)
        found = next(row for row in table_rows(section(self.design, '## 13.'), '| Situation | Where | Copy / UI |') if row[0] == 'Your voice: speech found')
        for text in quoted(ok):
            self.assertIn(text, found[2])
        names = section(self.design, '## 15.')
        self.assertIn('"Speech found: 1 minute 52 seconds" without `preferRange`', names)

    def test_plain_return_never_runs_the_panel_primary_from_a_row(self):
        rows = {row[0]: row for row in table_rows(section(self.design, '### 11.2'), '| Action | macOS | Windows | Notes |')}
        primary = rows["Rewrite panel's primary action"][1]
        edit = rows['Edit a proposed change'][1]
        self.assertIn('⌘Return', primary)
        self.assertIn('Return on a focused change', edit)
        # The edit binding owns Return on a row, so a plain-Return primary must exclude rows.
        if 'Return' in primary.replace('⌘Return', ''):
            self.assertRegex(primary, r'never on a change or phrase row')

    def test_macos_shortcuts_never_bind_bare_f6(self):
        rows = table_rows(section(self.design, '### 11.2'), '| Action | macOS | Windows | Notes |')
        moves = {row[0]: row[1] for row in rows}
        self.assertEqual(moves['Move focus to the next pane'], '⌃F6')
        for action, mac, *_ in rows:
            self.assertNotRegex(mac, r'(?<!⌃)F6', action)

    def test_take_buttons_show_their_phrase_estimate(self):
        rewrite = section(self.design, '### 6.3')
        copy = '\n'.join('|'.join(row) for row in table_rows(section(self.design, '## 13.'), '| Situation | Where | Copy / UI |')
                         if row[0].split(':')[0] in {'Rewrite', 'Your voice', 'Takes'})
        names = between(section(self.design, '## 15.'), '- **Rewrite names**', '- **Rewrite announcements:**')
        for name, text in [('§6.3', rewrite), ('§13', copy), ('§15', names)]:
            self.assertNotRegex(text, r'≈ \$\d', name)
            self.assertNotIn('about 1 cent', text, name)
        for button in ['Try Another', 'Try Again']:
            self.assertIn(f'[{button} · {{amount}}] or [{button}…]', copy)


if __name__ == '__main__':
    unittest.main()
