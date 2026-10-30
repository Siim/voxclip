import pathlib
import re
import unittest


class CommandHandoffTests(unittest.TestCase):
    def test_every_shipping_command_has_payload_preconditions_and_inverse(self):
        root = pathlib.Path(__file__).resolve().parents[2]
        source = (root / 'apps/macos/Sources/VoxClipCore/Domain/Editing/EditingContracts.swift').read_text()
        declaration = source.split('public enum VoiceLabEditCommand:', 1)[1].split('public var actionName:', 1)[0]
        variants = set(re.findall(r'case (\w+)\(', declaration))
        contracts = (root / 'apps/macos/CONTRACTS.md').read_text()
        handoff = contracts.split('W7 Windows command handoff', 1)[1].split('### ', 1)[0]
        self.assertIn('supersedes the older W5 statement', handoff)
        self.assertIn('ship in Release', handoff)
        self.assertIn('| Variant | Payload | Preconditions and transition | Inverse |', handoff)
        rows = [line.split('|')[1:-1] for line in handoff.splitlines() if re.match(r'\| `\w+` \|', line)]
        self.assertEqual({row[0].strip(' `') for row in rows}, variants)
        for row in rows:
            self.assertEqual(len(row), 4)
            self.assertTrue(all(len(cell.strip()) > 10 for cell in row[1:]))
        for parameter in ['VoiceLabSegment', 'assets: [VoiceLabAsset]', 'voice: VoiceLabVoiceReference',
                          'segmentID: String', 'enabled: Bool', 'index: Int']:
            self.assertIn(parameter, handoff)
        for rule in ['modifiedAt', 'document change count', 'whole-run', 'Cancelling keeps old takes',
                     'en_US_POSIX', 'U+2212', '%.1f', 'negative zero', 'sign before rounding']:
            self.assertIn(rule, handoff)


if __name__ == '__main__':
    unittest.main()
