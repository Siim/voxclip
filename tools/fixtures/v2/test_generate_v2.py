"""Regression checks for the independent reference and its byte-exact CI registration."""
import contextlib
import hashlib
import importlib.util
import io
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location('generate_v2', Path(__file__).with_name('generate_v2.py'))
generator = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(generator)


class V2GeneratorTests(unittest.TestCase):
    def test_monologue_and_later_ties(self):
        self.assertEqual([[i, min(i+150,10000)] for i in range(0,10000,150)], generator.paragraphs(generator.words(10000)))
        words = generator.words(400)
        generator.widen(words,120,.5)
        generator.widen(words,145,.5)
        self.assertEqual([0,145], generator.paragraphs(words)[0])

    def test_regeneration_is_byte_exact(self):
        old = generator.OUT
        try:
            with tempfile.TemporaryDirectory(prefix='voxclip-wc1-generator-') as directory:
                generator.OUT = Path(directory)
                with contextlib.redirect_stdout(io.StringIO()): generator.main()
                for name in ['paragraphs.json','timeline-cases.json']:
                    self.assertEqual((old/name).read_bytes(), (generator.OUT/name).read_bytes())
                before = {p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in generator.OUT.iterdir()}
                with contextlib.redirect_stdout(io.StringIO()): generator.main()
                self.assertEqual(before, {p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in generator.OUT.iterdir()})
        finally:
            generator.OUT = old

    def test_ci_regenerates_both_files_with_exact_comparison(self):
        path = generator.ROOT/'tools/fixtures/voice-lab/check_drift.py'
        spec = importlib.util.spec_from_file_location('drift',path)
        drift = importlib.util.module_from_spec(spec);spec.loader.exec_module(drift)
        for name in ['paragraphs.json','timeline-cases.json']:
            self.assertIn('shared/fixtures/v2/'+name,drift.EXACT)
            self.assertNotIn('shared/fixtures/v2/'+name,drift.TOLERANT)
        self.assertIn('tools/fixtures/v2/generate_v2.py',path.read_text())


if __name__=='__main__': unittest.main()
