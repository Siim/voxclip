import pathlib
import tempfile
import unittest
from check_release_boundary import check_staged_actions


class StagedActionsTests(unittest.TestCase):
    def test_actions_are_debug_only_and_positive_control_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            fixture = root / 'Action.swift'
            fixture.write_text('#if DEBUG\nenum VoiceLabEditCommand {}\n#if os(macOS)\nfunc applyVoiceLab() {}\n#endif\n#else\nstruct Safe {}\n#endif\n')
            check_staged_actions(root)
            fixture.write_text('enum VoiceLabEditCommand {}')
            with self.assertRaisesRegex(RuntimeError, 'Release exposes'):
                check_staged_actions(root)
            fixture.write_text('func applyVoiceLab() {}')
            with self.assertRaisesRegex(RuntimeError, 'Release exposes'):
                check_staged_actions(root)
