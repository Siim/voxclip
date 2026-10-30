import json
import pathlib
import unittest


class WireConformanceTests(unittest.TestCase):
    def test_recovery_nonce_is_pinned_in_labels_and_description(self):
        root = pathlib.Path(__file__).resolve().parents[2]
        cases = json.loads((root / 'shared/fixtures/voice-lab/request-cases.json').read_text())['cases']
        rows = [case for case in cases if case['input'].get('recoveryNonce')]
        self.assertEqual(len(rows), 2)
        for case in rows:
            fields = {part['headers'][0]: part.get('value') for part in case['request']['multipart']}
            labels = json.loads(fields['Content-Disposition: form-data; name="labels"'])
            self.assertEqual(labels, {'language': case['input']['language'], 'voxclip_record_id': case['input']['recoveryNonce']})
            self.assertTrue(fields['Content-Disposition: form-data; name="description"'].endswith(' VoxClip request ' + case['input']['recoveryNonce'] + '.'))

    def test_v3_has_no_stitching_and_context_does_not_bind_its_quote(self):
        root = pathlib.Path(__file__).resolve().parents[2]
        document = json.loads((root / 'shared/fixtures/voice-lab/request-cases.json').read_text())
        rows = [case for case in document['cases'] if case['input'].get('modelId') == 'eleven_v3']
        self.assertTrue(rows)
        for case in rows:
            self.assertNotIn('previous_text', case['request']['json'])
            self.assertNotIn('next_text', case['request']['json'])
        mutations = [item for item in document['quoteMutations'] if item['case'].startswith('v3_')]
        self.assertEqual(len(mutations), 2)
        self.assertTrue(all(item['allowed'] for item in mutations))

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
