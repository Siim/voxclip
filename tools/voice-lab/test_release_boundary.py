import pathlib
import subprocess
import tempfile
import unittest

from check_release_boundary import CAPABILITY_CALL, POLICY_CALL, PROOF_CALL, check_internal_build, check_validation_diagnostics, require_access_rejection, same_module_source

FLAG = """extension AppModel {
    static var internalBuild: Bool {
        #if DEBUG
        true
        #else
        %s
        #endif
    }
}
"""


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

    def test_release_builds_are_never_internal(self):
        root = pathlib.Path(__file__).resolve().parents[2] / 'apps/macos/Sources'
        check_internal_build(root)
        cases = {
            'false': 'let gate = VoiceLabGate.rewriteEnabled(enabled: true, noticeAccepted: false, internalBuild: Self.internalBuild)',
            'true': None,
        }
        for release, call in cases.items():
            with tempfile.TemporaryDirectory() as directory:
                sources = pathlib.Path(directory)
                (sources / 'VoxClip').mkdir()
                (sources / 'VoxClip/VoiceLabSession.swift').write_text(FLAG % release)
                if call:
                    (sources / 'VoxClip/Gate.swift').write_text('#if DEBUG\nlet any = f(internalBuild: true)\n#endif\n' + call + '\n')
                    check_internal_build(sources)
                    (sources / 'VoxClip/Gate.swift').write_text(call.replace('Self.internalBuild', 'true') + '\n')
                    with self.assertRaisesRegex(RuntimeError, 'internalBuild: true'):
                        check_internal_build(sources)
                else:
                    with self.assertRaisesRegex(RuntimeError, 'internalBuild as true'):
                        check_internal_build(sources)


class ValidationDiagnosticBoundary(unittest.TestCase):
    def test_real_sources_and_negative_control(self):
        root = pathlib.Path(__file__).resolve().parents[2] / 'apps/macos/Sources'
        check_validation_diagnostics(root)
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            source = root / 'Probe.swift'
            source.write_text('#if DEBUG\nfunc recordValidationDiagnostic() {}\n#endif\n')
            check_validation_diagnostics(root)
            source.write_text('func recordValidationDiagnostic() {}\n')
            with self.assertRaisesRegex(RuntimeError, 'Release exposes speech validation diagnostics'):
                check_validation_diagnostics(root)


if __name__ == '__main__':
    unittest.main()
