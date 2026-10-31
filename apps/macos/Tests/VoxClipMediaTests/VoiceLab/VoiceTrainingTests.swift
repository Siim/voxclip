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
    /// Stereo buffer `index` at `time`, with different content in each channel, and its mean mix.
    private func block(_ index: Int, count: Int, rate: Int, at time: CMTime) throws -> (buffer: CMReadySampleBuffer<CMSampleBuffer.DynamicContent>, mono: [Float]) {
        var content: [Float] = [], mono: [Float] = []
        for sample in 0..<count {
            let leftStep: Int = (index * 977 + sample * 7_919) % 4_001 - 2_000
            let rightStep: Int = (index * 331 + sample * 104_729) % 3_001 - 1_500
            let left: Float = Float(leftStep) / 4_000, right: Float = Float(rightStep) / 6_000
            content.append(left); content.append(right)
            mono.append(Float((Double(left) + Double(right)) / 2))
        }
        return (try VoiceLabSourceAudioTests.floatBuffer(content, rate: rate, channels: 2, time: time), mono)
    }
    @Test func levelsPlaceEachBufferByItsTimestampAsTheCutsDo() throws {
        let rate = 8_000
        func at(_ sample: Int64) -> CMTime { CMTime(value: sample, timescale: CMTimeScale(rate)) }
        // Presentation time, decoded samples and the placed first sample; at 8 kHz a frame is 80 samples.
        let buffers: [(time: CMTime, count: Int, first: Int?)] = [
            (at(120), 100, 120),                            // a late start: silence before it
            (CMTime(value: 28, timescale: 1_000), 100, 220), // 224 is within one 8-sample tick of 220: sequential
            (at(300), 100, 300),                            // 20 samples of overlap are skipped
            (CMTime.invalid, 100, 400),                     // a missing timestamp continues at the decoded end
            (at(200), 100, 200),                            // wholly placed already, but it moves the decoded end
            (at(2_000), 81, 2_000),                         // a timestamp gap: silence across it
            (at(5_000), 50, nil),                           // at the media's duration: dropped
        ]
        var timeline = VoiceTrainingTimeline(rate: rate, channels: 2, limit: 5_000)
        var expected: [Float] = []
        for (index, row) in buffers.enumerated() {
            let (buffer, mono) = try block(index, count: row.count, rate: rate, at: row.time)
            try timeline.append(buffer)
            guard let first = row.first else { continue }
            if first > expected.count { expected.append(contentsOf: repeatElement(Float(0), count: first - expected.count)) }
            let skip: Int = expected.count - first
            if skip < row.count { expected.append(contentsOf: mono[skip...]) }
        }
        var reference = VoiceTrainingMeter(rate: rate)
        for value in expected { reference.add(value) }
        let levels: [Double] = timeline.meter.frameDb
        #expect(expected.count == 2_081)
        #expect(timeline.meter.samples == 2_081)
        #expect(reference.frameDb.count == 26)
        #expect(levels == reference.frameDb)
        #expect(levels[0] < -179)
        #expect(levels[1] > -60)
        #expect(levels[7...24].allSatisfy { (level: Double) -> Bool in level < -179 })
        #expect(levels[25] > -60)
        // Samples before source zero are skipped, and the first buffer needs a timestamp.
        var early = VoiceTrainingTimeline(rate: rate, channels: 2, limit: 5_000)
        let (before, mono) = try block(9, count: 200, rate: rate, at: at(-40))
        try early.append(before)
        var direct = VoiceTrainingMeter(rate: rate)
        for value in mono.dropFirst(40) { direct.add(value) }
        #expect(early.meter.samples == 160)
        #expect(direct.frameDb.count == 2)
        #expect(early.meter.frameDb == direct.frameDb)
        let missing = try block(0, count: 10, rate: rate, at: .invalid).buffer
        var anchorless = VoiceTrainingTimeline(rate: rate, channels: 2, limit: 5_000)
        #expect(throws: VoiceLabSourceAudioError.unreadable) { try anchorless.append(missing) }
    }
    @Test func levelsMeasureTheReaderOutputOnThePlacedTimelineUpToTheMediaDuration() async throws {
        let rate = 8_000
        func at(_ sample: Int64) -> CMTime { CMTime(value: sample, timescale: CMTimeScale(rate)) }
        // 2,001 / 16,000 s is 1,000.5 samples: buffers placed from sample 1,001 on are dropped, and the duration is 125 ms.
        let length = CMTime(value: 2_001, timescale: 16_000)
        let rows: [(time: CMTime, count: Int, first: Int?)] = [
            (at(0), 100, 0),
            (at(400), 100, 400),     // a timestamp gap: silence across it
            (at(1_000), 50, 1_000),  // placed before the limit, so kept whole
            (at(1_050), 50, nil),    // sequential, but at the limit or after it: dropped
            (at(800_000), 50, nil),  // a corrupt far timestamp: dropped, with no silence up to it
        ]
        var queue: [CMReadySampleBuffer<CMSampleBuffer.DynamicContent>] = []
        var expected: [Float] = []
        for (index, row) in rows.enumerated() {
            let (buffer, mono) = try block(index, count: row.count, rate: rate, at: row.time)
            queue.append(buffer)
            guard let first = row.first else { continue }
            expected.append(contentsOf: repeatElement(Float(0), count: first - expected.count))
            expected.append(contentsOf: mono)
        }
        var reference = VoiceTrainingMeter(rate: rate)
        for value in expected { reference.add(value) }
        var pending = queue[...]
        let levels: VoiceTrainingLevels = try await VoiceTrainingAudio.levels(rate: rate, channels: 2, length: length) { pending.popFirst() }
        #expect(pending.isEmpty)
        #expect(expected.count == 1_050)
        #expect(levels.sampleRate == rate)
        #expect(levels.frameDb.count == 13)
        #expect(levels.frameDb == reference.frameDb)
        #expect(levels.duration == 0.125)
        // A placed take shorter than the media sets the duration, and a take with nothing placed is unreadable.
        var head = queue.prefix(1)
        let second = CMTime(value: 1, timescale: 1)
        let partial: VoiceTrainingLevels = try await VoiceTrainingAudio.levels(rate: rate, channels: 2, length: second) { head.popFirst() }
        #expect(partial.frameDb == Array(reference.frameDb.prefix(1)))
        #expect(partial.duration == 0.012)
        var far = queue.suffix(1)
        do {
            _ = try await VoiceTrainingAudio.levels(rate: rate, channels: 2, length: length) { far.popFirst() }
            Issue.record("A take with nothing placed was measured")
        } catch {
            #expect(error as? VoiceLabSourceAudioError == .unreadable)
        }
    }
    /// The `take` placed 1.5 s into the asset with a 0.75 s gap 4 s into the audio, both empty edits as an exported
    /// composition stores them, and the mean mix on that asset timeline, which preview, export and the cuts use.
    /// AVAssetReader fills empty edits with silence itself; timestamps that jump are covered by the timeline test.
    private func lateTake(rate: Int, in folder: URL) async throws -> (url: URL, mono: [Float]) {
        let (source, decoded) = try take(rate: rate, seconds: 10, in: folder)
        let asset = AVURLAsset(url: source)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let composition = AVMutableComposition()
        let audio = try #require(composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
        func time(_ sample: Int) -> CMTime { CMTime(value: Int64(sample), timescale: CMTimeScale(rate)) }
        let late: Int = rate * 3 / 2, split: Int = rate * 4, resume: Int = rate * 25 / 4
        try audio.insertTimeRange(CMTimeRange(start: .zero, duration: time(split)), of: track, at: time(late))
        try audio.insertTimeRange(CMTimeRange(start: time(split), duration: time(decoded.count - split)), of: track, at: time(resume))
        let url = folder.appendingPathComponent("late-\(rate).mov")
        let session = try #require(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
        try await session.export(to: url, as: .mov)
        withExtendedLifetime(asset) {}
        var mono = [Float](repeating: 0, count: late)
        mono.append(contentsOf: decoded[..<split])
        mono.append(contentsOf: repeatElement(Float(0), count: resume - late - split))
        mono.append(contentsOf: decoded[split...])
        return (url, mono)
    }
    @Test func lateAndGappedAudioIsMeasuredAndCutOnTheAssetTimeline() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-training-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let rate = 48_000
        let (url, mono) = try await lateTake(rate: rate, in: folder)
        #expect(mono.count == 588_000)
        let levels = try await VoiceTrainingAudio.levels(source: url)
        var reference = VoiceTrainingMeter(rate: rate)
        for value in mono { reference.add(value) }
        #expect(levels.sampleRate == rate)
        #expect(levels.duration == 12.25)
        #expect(levels.frameDb.count == 1_225)
        #expect(levels.frameDb == reference.frameDb)
        // Silence before the late start and across the gap; the take opens on a tone and resumes on its quiet floor.
        let silent = { (level: Double) -> Bool in level < -179 }
        #expect(levels.frameDb[..<150].allSatisfy(silent))
        #expect(levels.frameDb[150] > -40)
        #expect(levels.frameDb[549] > -40)
        #expect(levels.frameDb[550..<625].allSatisfy(silent))
        #expect(levels.frameDb[625] > -100)
        let spans = [VoiceTrainingSpan(startMs: 1_000, endMs: 7_000, snrDb: 30), VoiceTrainingSpan(startMs: 6_500, endMs: 12_250, snrDb: 30)]
        let samples = try await VoiceTrainingAudio.projectSamples(source: url, sampleRate: rate, spans: spans)
        #expect(samples.count == spans.count)
        for (sample, span) in zip(samples, spans) {
            let first: Int = (span.startMs * rate + 500) / 1_000, last: Int = (span.endMs * rate + 500) / 1_000
            let cut: [Float] = mono[first..<last].map { (value: Float) -> Float in Float(VoiceLabAssetStore.pcm16(value)) / 32_768 }
            let expected = try VoiceTrainingAudio.wav(cut, rate: rate)
            #expect(sample.wav == expected)
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
