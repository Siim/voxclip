import subprocess
import unittest

from check_release_boundary import CAPABILITY_CALL, POLICY_CALL, PROOF_CALL, require_access_rejection, same_module_source


class ReleaseBoundaryTests(unittest.TestCase):
    def test_a_compile_error_without_the_expected_access_diagnostic_is_not_evidence(self):
        for message in ['incorrect argument label validate:', 'missing arguments for parameters store, record',
                        'cannot find type in scope', "inaccessible due to 'internal' protection level"]:
            with self.assertRaisesRegex(RuntimeError, 'did not prove'):
                require_access_rejection('test', subprocess.CompletedProcess([], 1, stderr=message), 'fileprivate')
        require_access_rejection('test', subprocess.CompletedProcess([], 1,
            stderr="initializer is inaccessible due to 'fileprivate' protection level"), 'fileprivate')
        with self.assertRaisesRegex(RuntimeError, 'did not prove'):
            require_access_rejection('test', subprocess.CompletedProcess([], 0,
                stderr="inaccessible due to 'private' protection level"), 'private')
        with self.assertRaisesRegex(RuntimeError, 'did not prove'):
            require_access_rejection('test', subprocess.CompletedProcess([], 1,
                stderr="'unrelated' is inaccessible due to 'internal' protection level"), 'internal', "'authorized'")

    def test_probes_and_positive_controls_use_the_production_signatures(self):
        self.assertIn('authorized(for: quote, proof:', POLICY_CALL)
        self.assertNotIn('validate:', POLICY_CALL)
        for parameter in ['recordID:', 'cloneVoiceID:', 'store:', 'record:', 'statementHash:', 'embedder:']:
            self.assertIn(parameter, PROOF_CALL)
            self.assertIn(parameter, POLICY_CALL)
        source = same_module_source()
        self.assertIn('func authorized(for quote: VoiceLabQuote, proof: VoiceSpeakerMatch)', source)
        self.assertIn('fileprivate init(recordID:', source)
        self.assertIn('type(of: policy.capability!).init(quote: quote, reserve: nil, validate: {})', CAPABILITY_CALL)


if __name__ == '__main__':
    unittest.main()
