import pathlib
import tempfile
import unittest
from check_release_boundary import check_staged_actions


class StagedActionsTests(unittest.TestCase):
    def test_harness_stays_debug_only_and_production_actions_are_allowed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            fixture = root / 'Action.swift'
            fixture.write_text('#if DEBUG\nclass DebugRewrite {}\n#if os(macOS)\nvar publishForTests: Int = 0\n#endif\n#else\nstruct Safe {}\n#endif\nenum VoiceLabEditCommand {}\nfunc applyVoiceLab() {}\n')
            check_staged_actions(root)
            fixture.write_text('class DebugRewrite {}')
            with self.assertRaisesRegex(RuntimeError, 'Release exposes'):
                check_staged_actions(root)
            for name in ['publishForTests', 'prepareForTests', 'executeForTests', 'finishGenerationForTests']:
                fixture.write_text('var ' + name + ': Int = 0')
                with self.assertRaisesRegex(RuntimeError, 'Release exposes'):
                    check_staged_actions(root)
                fixture.write_text('#if DEBUG\nvar ' + name + ': Int = 0\n#endif')
                check_staged_actions(root)
