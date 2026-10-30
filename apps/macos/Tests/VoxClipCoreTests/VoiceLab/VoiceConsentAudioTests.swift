import Foundation
import Testing
@testable import VoxClipCore

@Suite("Consent band-limited resampling")
struct VoiceConsentAudioTests {
    @Test func nativeRateIsUnchanged() {
        let samples: [Float] = [0, 0.1, -0.3, 0.7, 0]
        #expect(VoiceConsentAudio.resample(samples, rate: 16_000) == samples)
    }
    @Test(arguments: [44_100, 48_000, 8_000])
    func lengthDCAndImpulseAlignment(rate: Int) throws {
        let dc = VoiceConsentAudio.resample([Float](repeating: 0.25, count: rate), rate: rate)
        #expect(dc.count == 16_000)
        #expect(dc[100..<15_900].allSatisfy { abs($0 - 0.25) < 0.000001 })
        var impulse = [Float](repeating: 0, count: rate)
        impulse[rate / 2] = 1
        let output = VoiceConsentAudio.resample(impulse, rate: rate)
        let peak = try #require(output.indices.max(by: { abs(output[$0]) < abs(output[$1]) }))
        #expect(peak == 8_000)
    }
    @Test(arguments: [44_100, 48_000])
    func removesAboveNyquistWithoutDamagingSpeechBand(rate: Int) throws {
        func tone(_ frequency: Double) -> [Float] {
            (0..<rate).map { Float(0.25 * sin(2 * .pi * frequency * Double($0) / Double(rate))) }
        }
        let high = VoiceConsentAudio.resample(tone(12_000), rate: rate)
        let rms = sqrt(high[100..<15_900].reduce(0.0) { $0 + Double($1) * Double($1) } / 15_800)
        #expect(rms < 0.0001)
        var wav = VoiceLabRequestFixtures.wav(rate: rate, frames: rate)
        let quantized = tone(1_000).map { Int16((Double($0) * 32_768).rounded()).littleEndian }
        wav.replaceSubrange(44..<wav.count, with: quantized.withUnsafeBytes { Data($0) })
        let low = try VoiceConsentAudio.pcm16k(wav)
        #expect(low.count == 16_000)
        let radiansPerSample = 2.0 * Double.pi * 1_000.0 / 16_000.0
        var maximumError = 0.0
        for index in 100..<15_900 {
            let expected = 0.25 * sin(radiansPerSample * Double(index))
            maximumError = max(maximumError, abs(Double(low[index]) - expected))
        }
        #expect(maximumError < 0.0001)
    }
}
