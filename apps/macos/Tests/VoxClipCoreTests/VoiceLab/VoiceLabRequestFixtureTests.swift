import Foundation
import Testing

@Suite("Voice Lab WAV fixture encoding", .timeLimit(.minutes(1)))
struct VoiceLabRequestFixtureTests {
    @Test(arguments: [0, 0x1234, -1, -32_768, 65_537, -65_537])
    func constantPCMPreservesExactBytes(fill: Int) {
        let sample: [UInt8]
        switch fill {
        case 0: sample = [0, 0]
        case 0x1234: sample = [0x34, 0x12]
        case -32_768: sample = [0, 0x80]
        case 65_537: sample = [1, 0]
        default: sample = [0xff, 0xff]
        }
        let header: [UInt8] = [
            0x52, 0x49, 0x46, 0x46, 0x28, 0, 0, 0,
            0x57, 0x41, 0x56, 0x45, 0x66, 0x6d, 0x74, 0x20,
            0x10, 0, 0, 0, 1, 0, 1, 0,
            0x80, 0x3e, 0, 0, 0, 0x7d, 0, 0,
            2, 0, 0x10, 0, 0x64, 0x61, 0x74, 0x61, 4, 0, 0, 0,
        ]
        #expect(VoiceLabRequestFixtures.wav(rate: 16_000, frames: 2, fill: fill) == Data(header + sample + sample))
    }

    @Test func junkPaddingPreservesIntentionallyInvalidStereoHeader() {
        let expected: [UInt8] = [
            0x52, 0x49, 0x46, 0x46, 0x32, 0, 0, 0,
            0x57, 0x41, 0x56, 0x45,
            0x4a, 0x55, 0x4e, 0x4b, 3, 0, 0, 0, 0, 0, 0, 0,
            0x66, 0x6d, 0x74, 0x20, 0x10, 0, 0, 0, 1, 0, 2, 0,
            0x40, 0x1f, 0, 0, 0x80, 0x3e, 0, 0,
            2, 0, 0x10, 0, 0x64, 0x61, 0x74, 0x61, 2, 0, 0, 0, 0x34, 0x12,
        ]
        #expect(VoiceLabRequestFixtures.wav(rate: 8_000, frames: 1, fill: 0x1234, junkBytes: 3, channels: 2) == Data(expected))
    }

    @Test(arguments: [0, 2_000, 2_001, -4_000])
    func fullLengthFixturesKeepSamplesAndIndependentStorage(fill: Int) throws {
        let wav = VoiceLabRequestFixtures.wav(rate: 16_000, frames: 240_000, fill: fill)
        try #require(wav.count == 480_044)
        let expected = UInt16(truncatingIfNeeded: fill)
        wav.withUnsafeBytes { bytes in
            #expect(UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: 4, as: UInt32.self)) == 480_036)
            #expect(UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: 40, as: UInt32.self)) == 480_000)
            for frame in [0, 120_000, 239_999] {
                #expect(UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: 44 + frame * 2, as: UInt16.self)) == expected)
            }
        }
        var changed = wav
        changed[44] ^= 0xff
        #expect(wav[44] == UInt8(truncatingIfNeeded: fill))
        #expect(changed[44] != wav[44])
    }
}
