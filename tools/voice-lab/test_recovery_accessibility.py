import pathlib
import unittest


class RecoveryAccessibilityTests(unittest.TestCase):
    def test_every_voice_and_recovery_action_uses_the_tested_context(self):
        root = pathlib.Path(__file__).resolve().parents[2]
        source = (root / 'apps/macos/Sources/VoxClip/VoiceLabSettings.swift').read_text()
        self.assertIn('Self.accessibilityContexts(records: records, operations: operations, shared: app.shared)', source)
        start = source.index('ForEach(operations)')
        entries = source[start:source.index('Text("Make your voice from Rewrite', start)]
        self.assertIn('contexts["operation-\\(operation.id)"', entries)
        self.assertRegex(entries, r'\.accessibilityElement\(children: \.contain\)\s*\.accessibilityLabel\(context\)')
        for action in ['VoiceLabSession.Request.stopLooking(operation.id).title', '"Retry"', '"Remove unfinished voice"']:
            self.assertIn(f'Self.actionAccessibilityLabel({action}, context: context)', entries)
        records = source[source.index('ForEach(session.visibleRecords)'):start]
        self.assertIn('contexts["record-\\(record.id)"', records)
        for action in ['session.deleting.contains(record.id) ? "Retry deletion" : "Delete voice"', '"Remove from VoxClip only"', '"Retry saving consent record"', '"Remove unfinished voice"']:
            self.assertIn(f'Self.actionAccessibilityLabel({action}, context: context)', records)
        confirmation = source[source.index('private struct VoiceLabRequestSheet'):]
        self.assertIn('VoiceLabSettings.requestAccessibilityLabel(action, contexts: contexts)', confirmation)


if __name__ == '__main__':
    unittest.main()
