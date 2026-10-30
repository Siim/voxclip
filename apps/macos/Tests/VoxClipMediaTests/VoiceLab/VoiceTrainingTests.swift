import AVFoundation
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
    /// A float WAV with different content in each channel, so the mean mix is what the levels and cuts read.
    private func take(rate: Int, seconds: Double, in folder: URL) throws -> (url: URL, mono: [Float]) {
        let frames = Int(seconds * Double(rate))
        let url = folder.appendingPathComponent("take-\(rate).wav")
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(rate), channels: 2, interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        let left = try #require(buffer.floatChannelData?[0]), right = try #require(buffer.floatChannelData?[1])
        var mono: [Float] = []
        for index in 0..<frames {
            // Speech-like bursts over a quiet floor: one second of tone, then half a second near silence.
            let loud = index % (rate * 3 / 2) < rate
            let angle = 2 * Double.pi * 220 * Double(index) / Double(rate)
            left[index] = Float(sin(angle) * (loud ? 0.3 : 0.001))
            right[index] = Float(sin(angle * 1.5) * (loud ? 0.1 : 0.0005))
            mono.append(Float((Double(left[index]) + Double(right[index])) / 2))
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
        return (url, mono)
    }
    @Test func meterFollowsTheIntegerFrameGrid() {
        var meter = VoiceTrainingMeter(rate: 22_050)
        for _ in 0..<220 { meter.add(0.5) }
        // Frame 0 holds samples 0..<220, but floor(220 × 100 / 22,050) is 0 frames.
        #expect(meter.frameDb.isEmpty)
        meter.add(0)
        #expect(meter.frameDb == [20 * log10(0.5)])
        for _ in 221..<661 { meter.add(0) }
        // Frame 1 is samples 220..<441 (221 samples), frame 2 is 441..<661; silence floors at 1e-9.
        let quiet = 20 * log10((0.0 / 221).squareRoot() + 1e-9)
        #expect(meter.frameDb.count == 2 && meter.frameDb[1] == quiet && meter.samples == 661)
        meter.add(0)
        #expect(meter.frameDb.count == 3)
    }
    @Test func levelsStreamTheMeanMixAndSpansAreCutOnTheMillisecondGrid() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-training-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let rate = 22_050
        let (url, mono) = try take(rate: rate, seconds: 12.34567, in: folder)
        let levels = try await VoiceTrainingAudio.levels(source: url)
        #expect(levels.sampleRate == rate)
        #expect(levels.frameDb.count == mono.count * 100 / rate)
        #expect(levels.duration == Double(mono.count * 1_000 / rate) / 1_000)
        for frame in [0, 1, 99, 100, 150, levels.frameDb.count - 1] {
            let samples = mono[(frame * rate / 100)..<((frame + 1) * rate / 100)]
            let rms = (samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count)).squareRoot()
            #expect(abs(levels.frameDb[frame] - 20 * log10(max(rms, 1e-9))) < 1e-9)
        }
        let spans = [VoiceTrainingSpan(startMs: 1_001, endMs: 6_502, snrDb: 41), VoiceTrainingSpan(startMs: 6_502, endMs: 12_345, snrDb: 38.5)]
        let samples = try await VoiceTrainingAudio.projectSamples(source: url, sampleRate: rate, spans: spans)
        #expect(samples.map(\.source) == ["project", "project"] && samples.map(\.snrDb) == [41, 38.5])
        for (sample, span) in zip(samples, spans) {
            let count = (span.endMs * rate + 500) / 1_000 - (span.startMs * rate + 500) / 1_000
            let format = try ElevenLabsVoiceLab.validateWAV(sample.wav, maxBytes: 16 * 1_024 * 1_024)
            #expect(format.rate == rate && format.frames == count && sample.seconds == Double(count) / Double(rate))
            let decoded = try VoiceConsentAudio.pcm16k(sample.wav)
            let level = try #require(try VoiceLabLoudness.voicedRmsDb(decoded, sampleRate: 16_000))
            #expect(abs(level + 20) < 0.5)
        }
        await #expect(throws: VoiceLabSourceAudioError.rangeOutsideMedia) {
            try await VoiceTrainingAudio.projectSamples(source: url, sampleRate: rate, spans: [VoiceTrainingSpan(startMs: 7_000, endMs: 12_400, snrDb: 30)])
        }
    }
    @Test func missingMediaAndUnsupportedRatesAreUnreadableSources() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-training-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        await #expect(throws: VoiceLabSourceAudioError.unreadable) { try await VoiceTrainingAudio.levels(source: folder.appendingPathComponent("missing.mov")) }
        let (high, _) = try take(rate: 192_000, seconds: 0.05, in: folder)
        await #expect(throws: VoiceLabSourceAudioError.unsupportedRate) { try await VoiceTrainingAudio.levels(source: high) }
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
