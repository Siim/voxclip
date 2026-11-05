#!/usr/bin/env python3
"""The Rewrite tone catalog validator (shared/data/rewrite-tones.json, doc/design.md section 6.3.1)."""
import copy
import importlib.util
import json
import sys
import unittest
from pathlib import Path

sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('rewrite_tones', ROOT / 'tools/fixtures/voice-lab/generate_rewrite_tones.py')
TONES = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(TONES)


class RewriteToneCatalogTests(unittest.TestCase):
    def setUp(self):
        self.committed = json.loads((ROOT / 'shared/data/rewrite-tones.json').read_text())

    def test_committed_catalog_is_generated_and_valid(self):
        self.assertEqual(self.committed, TONES.document())
        self.assertEqual(TONES.check(self.committed), [])

    def test_the_approved_tones_in_order(self):
        titles = [tone['title'] for tone in self.committed['tones']]
        self.assertEqual(titles, ['Viral YouTuber', 'Punchy Reel', 'Storyteller', 'Clear explainer', 'LinkedIn pro', 'Funny',
                                  'Hype launch', 'Calm & sincere'])
        viral = self.committed['tones'][0]
        self.assertTrue(viral['featured'])
        for phrase in ('hook in the first sentence', 'short, punchy sentences', 'pattern interrupt', 'one clear payoff',
                       'Energetic but natural', 'rather than adding a line before it'):
            self.assertIn(phrase, viral['instruction'])

    def test_every_instruction_keeps_facts_and_stays_speakable(self):
        for tone in self.committed['tones']:
            with self.subTest(tone=tone['id']):
                self.assertTrue(tone['instruction'].endswith(TONES.KEEP))
                self.assertLessEqual(len(tone['instruction'].encode('utf-8')), 1000)
                self.assertTrue(TONES.speakable(tone['instruction']))
                self.assertIn(TONES.FIT_SHORTER if tone['shortens'] else TONES.FIT, tone['instruction'])

    def test_validator_refuses_each_broken_rule(self):
        def broken(change):
            doc = copy.deepcopy(self.committed)
            change(doc)
            return TONES.check(doc)
        cases = {
            'reserved id': lambda d: d['tones'][1].update(id='as-said'),
            'saved-tone prefix': lambda d: d['tones'][1].update(id='my-reel'),
            'duplicate id': lambda d: d['tones'][2].update(id=d['tones'][1]['id']),
            'emoji': lambda d: d['tones'][1].update(instruction='Fire \U0001F525 ' + d['tones'][1]['instruction']),
            'hashtag': lambda d: d['tones'][1].update(instruction='#viral ' + d['tones'][1]['instruction']),
            'stage direction': lambda d: d['tones'][1].update(instruction='[laughs] ' + d['tones'][1]['instruction']),
            'link': lambda d: d['tones'][1].update(instruction='See https://example.com. ' + d['tones'][1]['instruction']),
            'drops the facts rule': lambda d: d['tones'][1].update(instruction=d['tones'][1]['instruction'].replace(TONES.KEEP, '').strip()),
            'shortening without the fit rule': lambda d: d['tones'][3].update(shortens=True),
            'too long': lambda d: d['tones'][1].update(instruction='x' * 1001 + ' ' + TONES.KEEP),
            'two featured': lambda d: d['tones'][1].update(featured=True),
            'choices': lambda d: d['choices'].reverse(),
        }
        for name, change in cases.items():
            with self.subTest(case=name):
                self.assertNotEqual(broken(change), [])


if __name__ == '__main__':
    unittest.main()
