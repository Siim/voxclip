import pathlib
import unittest


class EnrollmentUITests(unittest.TestCase):
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
