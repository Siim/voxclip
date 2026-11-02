import pathlib
import re
import unittest


class CompilerShapeTests(unittest.TestCase):
    def test_consent_duration_uses_typed_arithmetic_before_conversion(self):
        root = pathlib.Path(__file__).resolve().parents[2]
        source = (root / 'apps/macos/Sources/VoxClipMedia/VoiceLab/ElevenLabsVoiceLab.swift').read_text()
        function = source.split('public func prepareConsentVerification(', 1)[1].split('public func transcribeConsentStatement(', 1)[0]
        for statement in ['let payloadBytes: Int = wav.count - 44', 'let sampleCount: Int = payloadBytes / 2',
                          'let samples: Double = Double(sampleCount)', 'let sampleRate: Double = 16_000',
                          'let seconds: Double = samples / sampleRate']:
            self.assertIn(statement, function)
        self.assertFalse(re.search(r'Double\([^\n]*(?:\+|\*|/| - )[^\n]*\)', function))

    def test_rewrite_chunking_keeps_integer_arithmetic_outside_conversions(self):
        root = pathlib.Path(__file__).resolve().parents[2]
        source = (root / 'apps/macos/Sources/VoxClipMedia/VoiceLab/VoiceLabSourceAudio.swift').read_text()
        rewrite = source.split('public static func rewriteSource(', 1)[1].split('public static func', 1)[0]
        decoder = source.split('private static func decodeMono(', 1)[1].split('static func decodeChunkFrames(', 1)[0]
        chunk_size = source.split('static func decodeChunkFrames(', 1)[1].split('struct EnvelopeAccumulator', 1)[0]
        self.assertIn('try await decodeMono(', rewrite)
        self.assertIn('let chunkSamples: Int = decodeChunkFrames(sampleRate: sampleRate)', decoder)
        self.assertIn('return min(280 * sampleRate, largest - trailing)', chunk_size)
        self.assertIn('let trailingSamples: Int = (sampleRate + 49) / 50', decoder)
        self.assertNotIn('Int64(280 *', decoder)
        self.assertNotIn('Float(Int16(', decoder)


if __name__ == '__main__':
    unittest.main()
