import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


class EnrollmentUITests(unittest.TestCase):
    def test_enrollment_is_inline_and_never_defaults_a_paid_button(self):
        job = (ROOT / 'apps/macos/Sources/VoxClip/DirectorVoiceSteps.swift').read_text()
        settings = (ROOT / 'apps/macos/Sources/VoxClip/VoiceLabSettings.swift').read_text()
        editor = (ROOT / 'apps/macos/Sources/VoxClip/EditorView.swift').read_text()
        library = (ROOT / 'apps/macos/Sources/VoxClip/SpeakerModelLibrary.swift').read_text()
        for source in [job, settings, editor]:
            self.assertNotIn('CreateVoiceSheet', source)
            self.assertNotIn('VoiceLabOptInView', source)
        for popup in ['.sheet(', '.alert(', '.confirmationDialog(', 'NSAlert']:
            self.assertNotIn(popup, job)
            self.assertNotIn(popup, library)
        self.assertNotIn('.keyboardShortcut(.defaultAction)', job)
        self.assertIn('VoiceFirstUseCard(session: session)', settings)
        self.assertIn('.onExitCommand { session.cancelVoiceAction() }', job)

    def test_microphone_errors_keep_privacy_help_and_all_agreements(self):
        job = (ROOT / 'apps/macos/Sources/VoxClip/DirectorVoiceSteps.swift').read_text()
        self.assertIn('if session.recorder.failure != nil', job)
        self.assertIn('Button("Open Privacy Settings")', job)
        session = (ROOT / 'apps/macos/Sources/VoxClip/VoiceLabSession.swift').read_text()
        self.assertIn('VoiceLabGate.canCheckOwnVoice(speakerAvailable: app.speakerModelLibrary.installed,', session)
        self.assertIn('var canRecord: Bool { enabled && speakerReady', session)
        self.assertIn('message = failure.localizedDescription; recorder.discard(); trainingReady = false', session)
        self.assertIn('Toggle(VoiceLabSession.projectConsentCopy, isOn: $session.ownVoice)', job)
        self.assertIn('static let projectConsentCopy = VoiceConsentRecord.ProjectConsent.text', session)
        consent = (ROOT / 'apps/macos/Sources/VoxClipCore/Domain/VoiceLab/VoiceConsent.swift').read_text()
        self.assertIn('I confirm this is my own voice and I consent to creating a voice clone.', consent)
        for agreement in ['I am 18 or older.', 'I will use it only on videos of myself.']:
            self.assertIn(f'Toggle("{agreement}"', job)

    def test_headphones_caption_precedes_recording_and_is_not_announced_during_it(self):
        job = (ROOT / 'apps/macos/Sources/VoxClip/DirectorVoiceSteps.swift').read_text()
        copy = 'Using a screen reader? Wear headphones so it isn\'t recorded.'
        self.assertLess(job.index(copy), job.index('if session.recorder.recording {'))
        self.assertNotIn('accessibilityLiveRegion', job)
        self.assertIn('voxclip.voice.statement', job)


if __name__ == '__main__':
    unittest.main()
