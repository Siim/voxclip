import json
import pathlib
import unittest


class WireConformanceTests(unittest.TestCase):
    def test_every_clone_uses_repeated_files_field(self):
        root = pathlib.Path(__file__).resolve().parents[2]
        cases = json.loads((root / 'shared/fixtures/voice-lab/request-cases.json').read_text())['cases']
        clones = [case for case in cases if case['operation'] == 'createClone']
        self.assertTrue(clones)
        for case in clones:
            files = [part for part in case['request']['multipart'] if any('filename=' in header for header in part['headers'])]
            self.assertGreaterEqual(len(files), 1, case['case'])
            for part in files:
                self.assertIn('name="files";', part['headers'][0], case['case'])
                self.assertNotIn('files[]', part['headers'][0])


if __name__ == '__main__':
    unittest.main()
