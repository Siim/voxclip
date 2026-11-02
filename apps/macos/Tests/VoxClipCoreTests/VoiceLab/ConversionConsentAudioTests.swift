import Foundation
import Testing
@testable import VoxClipCore

@Suite("Conversion consent audio bounds", .offlineFixtures)
struct ConversionConsentAudioTests {
    private func metadataWAV() -> Data {
        var wav = VoiceLabRequestFixtures.wav(rate: 16_000, frames: 48_000)
        let metadataBytes = 16 * 1_024 * 1_024
        var chunk = Data("JUNK".utf8)
        var size = UInt32(metadataBytes).littleEndian
        withUnsafeBytes(of: &size) { chunk.append(contentsOf: $0) }
        chunk.append(Data(count: metadataBytes))
        wav.insert(contentsOf: chunk, at: 36)
        var riffSize = UInt32(wav.count - 8).littleEndian
        withUnsafeBytes(of: &riffSize) { wav.replaceSubrange(4..<8, with: $0) }
        return wav
    }

    @Test func conversionAllowsItsOwnByteEnvelopeWhileEnrollmentRemainsBounded() throws {
        let wav = metadataWAV()
        #expect(wav.count > 16 * 1_024 * 1_024 && wav.count < 50_000_000)
        #expect(throws: VoiceLabError.unsupportedFormat) { try VoiceConsentAudio.pcm16k(wav) }
        let expected = try VoiceConsentAudio.pcm16k(VoiceLabRequestFixtures.wav(rate: 16_000, frames: 48_000))
        #expect(try VoiceConsentAudio.conversionPCM16k(wav) == expected)
    }

    @Test func conversionStillRejectsTheExclusiveFiftyMegabyteBoundary() {
        #expect(throws: VoiceLabError.unsupportedFormat) {
            try VoiceConsentAudio.conversionPCM16k(Data(count: 50_000_000))
        }
    }

    @Test func conversionKeepsExactRIFFAndDurationValidation() {
        var malformed = metadataWAV()
        malformed[4] ^= 1
        #expect(throws: VoiceLabError.unsupportedFormat) { try VoiceConsentAudio.conversionPCM16k(malformed) }
        let overDuration = VoiceLabRequestFixtures.wav(rate: 8_000, frames: 8_000 * 290 + 1)
        #expect(throws: VoiceLabError.unsupportedFormat) { try VoiceConsentAudio.conversionPCM16k(overDuration) }
    }
}
