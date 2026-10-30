import pathlib
import unittest


class EnrollmentUITests(unittest.TestCase):
    def test_speaker_unavailability_reason_precedes_attestations(self):
        root = pathlib.Path(__file__).resolve().parents[2]
        source = (root / 'apps/macos/Sources/VoxClip/VoiceLabSettings.swift').read_text()
        sheet = source[source.index('private struct CreateVoiceSheet'):]
        self.assertLess(sheet.index('Text(session.speakerMessage)'), sheet.index('                    attestations'))
        self.assertIn('.disabled(!session.canRecord)', sheet)
        session = (root / 'apps/macos/Sources/VoxClip/VoiceLabSession.swift').read_text()
        self.assertIn('VoiceLabGate.canCheckOwnVoice(speakerAvailable: app.speakerModelLibrary.installed,', session)
        self.assertIn('calibratedThreshold: app.speakerModelLibrary.model?.calibratedThreshold(language: enrollmentLanguage), language: enrollmentLanguage)', session)
        self.assertIn('var canRecord: Bool { enabled && speakerReady', session)

    def test_silent_state_offers_microphone_privacy_settings(self):
        root = pathlib.Path(__file__).resolve().parents[2]
        source = (root / 'apps/macos/Sources/VoxClip/VoiceLabSettings.swift').read_text()
        sheet = source[source.index('private struct CreateVoiceSheet'):]
        self.assertRegex(sheet, r'if session\.recorder\.failure == \.silent \{\s*Text\("Silent"\)')
        self.assertIn('Button("Open Settings") { NSWorkspace.shared.open(MicrophoneError.privacySettingsURL) }', sheet)
        session = (root / 'apps/macos/Sources/VoxClip/VoiceLabSession.swift').read_text()
        self.assertIn('message = failure.localizedDescription; recorder.discard(); trainingReady = false', session)
        recorder = (root / 'apps/macos/Sources/VoxClipMedia/VoiceLab/VoiceMicrophoneRecorder.swift').read_text()
        self.assertIn('input.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in sink.observeInput(buffer) }', recorder)
        self.assertIn('input.removeTap(onBus: 0); mixer.removeTap(onBus: 0); engine.stop()', recorder)

    def test_turn_on_defaults_return_and_escape_to_cancel(self):
        root = pathlib.Path(__file__).resolve().parents[2]
        source = (root / 'apps/macos/Sources/VoxClip/VoiceLabSettings.swift').read_text()
        start = source.index('.alert("Turn on Voice Lab?"')
        alert = source[start:source.index('.sheet(isPresented:', start)]
        self.assertIn('Button("Cancel", role: .cancel) {}.keyboardShortcut(.defaultAction)', alert)
        self.assertIn('.onExitCommand { confirmBeta = false }', alert)
        self.assertNotRegex(alert, r'Button\("Turn on"[^\n]*keyboardShortcut')
        sheet = source[source.index('if action.defaultIsCancel'):source.index('private struct CreateVoiceSheet')]
        self.assertIn('Button("Cancel", role: .cancel)', sheet)
        self.assertIn('.keyboardShortcut(.defaultAction)', sheet)
        self.assertIn('.onExitCommand { session.confirmation = nil }', sheet)

    def test_headphones_caption_is_always_before_record_and_not_live(self):
        root = pathlib.Path(__file__).resolve().parents[2]
        source = (root / 'apps/macos/Sources/VoxClip/VoiceLabSettings.swift').read_text()
        sheet = source[source.index('private struct CreateVoiceSheet'):]
        copy = "If you use a screen reader, wear headphones so it isn't recorded."
        self.assertRegex(sheet, r'\}\s*Text\("' + copy + r'"\)\.font\(\.caption\)\.foregroundStyle\(\.secondary\)\s*recordingControls')
        self.assertLess(sheet.index('voice-consent-teleprompter'), sheet.index(copy))
        caption = sheet[sheet.index(copy):sheet.index('recordingControls')]
        self.assertNotIn('accessibilityLiveRegion', caption)
        self.assertNotIn('announce', caption)


if __name__ == '__main__':
    unittest.main()
