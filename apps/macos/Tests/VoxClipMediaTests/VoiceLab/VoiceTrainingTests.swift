import Foundation
import Testing
import VoxClipCore
@testable import VoxClipMedia

extension HeavyMediaTests {
@Suite("Own-voice training audio", .timeLimit(.minutes(2)))
struct VoiceTrainingTests {
    private func speech(seconds: Int, amplitude: Double = 0.2) -> [Float] {
        (0..<(seconds * 48_000)).map { index in
            let angle: Double = Double(index) * (2 * Double.pi * 220 / 48_000)
            return Float(sin(angle) * amplitude)
        }
    }
    @Test func normalizedPCM16WavAndPeak() throws {
        let wav = try VoiceTrainingAudio.wav(speech(seconds: 5))
        let decoded = try VoiceConsentAudio.pcm16k(wav)
        #expect(wav.count == 44 + 5 * 48_000 * 2)
        #expect(decoded.count == 80_000)
        let level = try #require(try VoiceLabLoudness.voicedRmsDb(decoded, sampleRate: 16_000))
        #expect(abs(level + 20) < 0.1)
        #expect(try VoiceLabLoudness.truePeakDbtp(decoded, sampleRate: 16_000) <= -3)
    }
    @Test func readAloudSplitsIntoBoundedSpans() throws {
        let samples = try VoiceTrainingAudio.training(speech(seconds: 60))
        #expect((3...12).contains(samples.count))
        #expect(samples.allSatisfy { (5...30).contains($0.seconds) && $0.source == "readAloud" && $0.snrDb.isFinite })
        #expect(abs(samples.reduce(0) { $0 + $1.seconds } - 60) < 0.001)
        for sample in samples { #expect(try VoiceConsentAudio.pcm16k(sample.wav).count == Int(sample.seconds * 16_000)) }
    }
    @Test func refusesShortSilentAndNonfiniteAudio() {
        #expect(throws: (any Error).self) { try VoiceTrainingAudio.training(speech(seconds: 5)) }
        #expect(throws: (any Error).self) { try VoiceTrainingAudio.wav([Float](repeating: 0, count: 48_000)) }
        #expect(throws: (any Error).self) { try VoiceTrainingAudio.wav([Float.nan]) }
    }
    @Test func partialInputBufferCannotOverrunPauseSearch() throws {
        var audio = speech(seconds: 60)
        audio.append(contentsOf: audio.prefix(128))
        for second in [14, 28, 42] {
            let start = second * 48_000
            audio.replaceSubrange(start..<(start + 480), with: repeatElement(Float(0), count: 480))
        }
        let samples = try VoiceTrainingAudio.training(audio)
        #expect(samples.allSatisfy { (5...30).contains($0.seconds) })
        let seconds = Double(audio.count) / 48_000
        #expect(abs(samples.reduce(0) { $0 + $1.seconds } - seconds) < 0.001)
    }
    @Test func sampleRateAndStatementDurationsStayBounded() throws {
        let wav = try VoiceTrainingAudio.wav(speech(seconds: 5))
        let pcm = try VoiceConsentAudio.pcm16k(wav)
        let scribe = try VoiceTrainingAudio.wav(pcm, rate: 16_000)
        #expect(try VoiceConsentAudio.pcm16k(scribe).count == 80_000)
        #expect(VoiceTrainingAudio.speech16k([0.1, 0.2, 0.3]).count == 1)
        #expect(VoiceTrainingAudio.speech16k([]).isEmpty)
    }
}
}
