import AVFoundation
import Foundation
import Testing
import VoxClipCore
@testable import VoxClipMedia

/// Social loudness at export (ADR-R47, amended 2026-11-08): the exported MP4's decoded audio is measured with the shared
/// Core meter and, when it is installed, FFmpeg's `ebur128=peak=true`.
private enum ExportedAudio {
    /// The first audio track of `url` decoded to 48 kHz interleaved Float32 stereo.
    static func samples(_ url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: MediaSupport.pcm(rate: 48000, channels: 2))
        let provider = reader.outputProvider(for: output)
        guard reader.startReading() else { throw reader.error ?? VoxClipError.decodeFailed("test reader") }
        var samples: [Float] = []
        while let sample = try await MediaSupport.nextSample(provider) {
            var chunk: [Float] = []
            try ExportLoudnessPass.copy(sample, frames: sample.sampleCount, into: &chunk)
            samples.append(contentsOf: chunk.prefix(2 * sample.sampleCount))
        }
        return samples
    }

    static func measure(_ samples: [Float]) throws -> SocialLoudnessMeasurement {
        var meter = try SocialLoudnessMeter(sampleRate: 48_000, channels: 2)
        try meter.append(samples)
        return meter.finish()
    }

    static func job(_ source: URL, seconds: Int, to output: URL, loudness: ExportLoudness = .social) -> ExportJob {
        let samples = Int64(seconds * 48000)
        let render = RenderRequest(sourceURL: source,
            plan: EditPlan(sampleRate: 48000, totalSamples: samples, kept: [MediaInterval(startSample: 0, endSample: samples)]),
            output: OutputSpec(size: PixelSize(width: 320, height: 180), fps: 30, videoBitrate: 1_000_000))
        return ExportJob(render: render, outputURL: output, loudness: loudness)
    }

    /// How far AAC may ring past the PCM's −1 dBTP on a limited transient.
    static let codecMarginDb = 0.1

    /// FFmpeg's EBU R128 reading of `url` (integrated loudness and its 4× true peak), or nil without FFmpeg.
    static func ebur128(_ url: URL) throws -> (lufs: Double, peak: Double)? {
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin"]
        guard let ffmpeg = paths.map({ URL(fileURLWithPath: $0).appendingPathComponent("ffmpeg") })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else { return nil }
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = ["-hide_banner", "-nostats", "-i", url.path, "-map", "0:a:0", "-af", "ebur128=peak=true", "-f", "null", "-"]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let text = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0, let summary = text.range(of: "Summary:") else { return nil }
        func value(_ label: String) -> Double? {
            guard let line = text[summary.upperBound...].split(separator: "\n").first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix(label) }) else { return nil }
            return line.split(separator: " ").compactMap { Double($0) }.first
        }
        guard let lufs = value("I:"), let peak = value("Peak:") else { return nil }
        return (lufs, peak)
    }
}

extension HeavyMediaTests {
@Test(.timeLimit(.minutes(2))) func socialLoudnessExportLandsAtMinus14AndOffLeavesTheMix() async throws {
    let directory = try cliDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = try await NativeMediaFixtures.shared.file("speech-bursts.mov")
    let sourceLoudness = try #require(try ExportedAudio.measure(try await ExportedAudio.samples(source)).integratedLufs())
    #expect(abs(sourceLoudness + 23.9) < 0.5, "source \(sourceLoudness)")

    let social = directory.appendingPathComponent("social.mp4")
    let result = try await AVExporter().export(ExportedAudio.job(source, seconds: 6, to: social)) { _ in }
    let report = try #require(result.loudness)
    let exported = try ExportedAudio.measure(try await ExportedAudio.samples(social))
    let lufs = try #require(exported.integratedLufs()), peak = try #require(exported.truePeakDbtp)
    #expect(abs(lufs - SocialLoudness.targetLufs) <= 0.5, "exported \(lufs) LUFS")
    #expect(peak <= SocialLoudness.ceilingDbtp, "exported true peak \(peak)")
    // The report is the composed PCM's: measured as the source, exactly −14 after the gain.
    #expect(abs((report.measuredLufs ?? 0) - sourceLoudness) < 0.05)
    #expect(abs((report.outputLufs ?? 0) - SocialLoudness.targetLufs) < 1e-6)
    #expect(abs(report.gainDb - (SocialLoudness.targetLufs - sourceLoudness)) < 0.05 && !report.capped)
    #expect((report.truePeakDbtp ?? 0) <= SocialLoudness.ceilingDbtp)
    // The gain alone keeps this one under the ceiling: the limiter has no work.
    #expect(report.limiterMaxReductionDb == 0 && report.limitedPercent == 0)

    let off = directory.appendingPathComponent("off.mp4")
    let unchanged = try await AVExporter().export(ExportedAudio.job(source, seconds: 6, to: off, loudness: .off)) { _ in }
    #expect(unchanged.loudness == nil)
    let offLufs = try #require(try ExportedAudio.measure(try await ExportedAudio.samples(off)).integratedLufs())
    #expect(abs(offLufs - sourceLoudness) <= 0.5, "off \(offLufs) vs source \(sourceLoudness)")
    #expect(abs((lufs - offLufs) - report.gainDb) < 0.2, "the gain is all that differs")
}

@Test(.timeLimit(.minutes(2))) func socialLoudnessLimitsTransientsAndLandsAtMinus14() async throws {
    let directory = try cliDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = try await NativeMediaFixtures.shared.file("speech-plosives.mov")
    let sourceMeasurement = try ExportedAudio.measure(try await ExportedAudio.samples(source))
    let sourcePeak = try #require(sourceMeasurement.truePeakDbtp)
    let sourceLoudness = try #require(sourceMeasurement.integratedLufs())
    // The static gain alone would stop well short: plosives and clicks reach −1 dBTP before the speech reaches −14.
    #expect(SocialLoudness.ceilingDbtp - sourcePeak < SocialLoudness.targetLufs - sourceLoudness - 3, "source \(sourceLoudness) LUFS, \(sourcePeak) dBTP")
    let output = directory.appendingPathComponent("limited.mp4")
    let result = try await AVExporter().export(ExportedAudio.job(source, seconds: 6, to: output)) { _ in }
    let report = try #require(result.loudness)
    #expect(!report.capped)
    #expect(report.limiterMaxReductionDb > 3 && report.limiterMaxReductionDb <= SocialLoudness.maximumReductionDb, "reduction \(report.limiterMaxReductionDb)")
    #expect(report.limitedPercent > 0 && report.limitedPercent < 100)
    #expect(abs((report.outputLufs ?? 0) - SocialLoudness.targetLufs) <= 0.5, "reported \(String(describing: report.outputLufs))")
    #expect((report.truePeakDbtp ?? 0) <= SocialLoudness.ceilingDbtp + 1e-6, "reported peak \(String(describing: report.truePeakDbtp))")
    // Independently, from the decoded AAC. The ceiling is the PCM's: AAC rings a few hundredths of a dB past it on a
    // limited transient (−0.97 dBTP here), so the decoded peak gets the codec's margin.
    let exported = try ExportedAudio.measure(try await ExportedAudio.samples(output))
    let lufs = try #require(exported.integratedLufs()), peak = try #require(exported.truePeakDbtp)
    #expect(abs(lufs - SocialLoudness.targetLufs) <= 0.5, "exported \(lufs) LUFS")
    #expect(peak <= SocialLoudness.ceilingDbtp + ExportedAudio.codecMarginDb, "exported true peak \(peak)")
    if let reading = try ExportedAudio.ebur128(output) {
        #expect(abs(reading.lufs - SocialLoudness.targetLufs) <= 0.5, "ffmpeg \(reading.lufs) LUFS")
        #expect(reading.peak <= SocialLoudness.ceilingDbtp + ExportedAudio.codecMarginDb, "ffmpeg true peak \(reading.peak)")
    }
}

@Test(.timeLimit(.minutes(2))) func socialLoudnessStopsAtTheReductionCapAndSaysSo() async throws {
    let directory = try cliDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = try await NativeMediaFixtures.shared.file("speech-clicks.mov")
    let output = directory.appendingPathComponent("capped.mp4")
    let result = try await AVExporter().export(ExportedAudio.job(source, seconds: 6, to: output)) { _ in }
    let report = try #require(result.loudness)
    // Clicks 26 dB over quiet speech would need more than 9 dB: the gain stops where the limiter reduces exactly 9.
    #expect(report.capped)
    #expect(abs(report.limiterMaxReductionDb - SocialLoudness.maximumReductionDb) < 1e-6, "reduction \(report.limiterMaxReductionDb)")
    #expect((report.truePeakDbtp ?? 0) <= SocialLoudness.ceilingDbtp + 1e-6)
    #expect((report.outputLufs ?? 0) < SocialLoudness.targetLufs - 1)
    let exported = try ExportedAudio.measure(try await ExportedAudio.samples(output))
    let lufs = try #require(exported.integratedLufs())
    #expect(abs(lufs - (report.outputLufs ?? 0)) <= 0.5, "exported \(lufs) vs reported \(String(describing: report.outputLufs))")
    #expect(try #require(exported.truePeakDbtp) <= SocialLoudness.ceilingDbtp + ExportedAudio.codecMarginDb, "exported true peak \(String(describing: exported.truePeakDbtp))")
}

@Test(.timeLimit(.minutes(3))) func cliLoudnessFlagReportsAndTheEditedWAVCarriesTheGainAndLimiter() async throws {
    let directory = try cliDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    func export(_ fixture: String, _ name: String, _ extra: [String]) async throws -> (json: [String: Any], wav: [Float]) {
        let source = try await NativeMediaFixtures.shared.file(fixture)
        let probe = try await AVMediaProbe().probe(source)
        let transcript = Transcript(durationSeconds: probe.durationSeconds, engine: EngineRef(id: .elevenlabs, engineVersion: "synthetic-fixture"),
            rawKey: String(repeating: "0", count: 64), createdAt: Date(timeIntervalSince1970: 0))
        let transcriptURL = directory.appendingPathComponent("\(name)-transcript.json")
        try ProjectJSON.encoder().encode(transcript).write(to: transcriptURL)
        let output = directory.appendingPathComponent("\(name).mp4"), audio = directory.appendingPathComponent("\(name).wav")
        let result = try runCLI(["export", "--open", source.path, "--transcript", transcriptURL.path, "--export", output.path,
            "--audio-out", audio.path, "--style", "off", "--json", "--quiet"] + extra, directory: directory, timeout: 60)
        try #require(result.status == 0, "CLI exit \(result.status): \(result.stderr)")
        let wav = try Data(contentsOf: audio).dropFirst(44).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        return (try result.json, wav)
    }
    let off = try await export("speech-bursts.mov", "off", ["--loudness", "off"])
    #expect(off.json["loudness"] is NSNull)
    let social = try await export("speech-bursts.mov", "social", [])
    let report = try #require(social.json["loudness"] as? [String: Any])
    #expect(Set(report.keys) == ["measuredLufs", "gainDb", "outputLufs", "truePeakDbtp", "capped", "limiterMaxReductionDb", "limitedPercent"])
    let gain = try #require(report["gainDb"] as? Double)
    #expect(gain > 8 && gain < 12 && report["capped"] as? Bool == false)
    #expect(report["limiterMaxReductionDb"] as? Double == 0 && report["limitedPercent"] as? Double == 0)
    #expect(abs((report["outputLufs"] as? Double ?? 0) - SocialLoudness.targetLufs) < 1e-6)
    // Gain alone: the WAV is the edited voice at its own level times the same gain.
    let factor = SocialLoudness.linearGain(gain)
    #expect(off.wav.count == social.wav.count && off.wav.count == 6 * 48000 * 2)
    var largest: Float = 0
    for index in off.wav.indices { largest = max(largest, abs(off.wav[index] * factor - social.wav[index])) }
    #expect(largest < 1e-6, "largest difference \(largest)")

    // Limited: the WAV is the edited voice through the same gain and the same limiter, sample for sample.
    let plain = try await export("speech-plosives.mov", "plosives-off", ["--loudness", "off"])
    let limited = try await export("speech-plosives.mov", "plosives", [])
    let limitedReport = try #require(limited.json["loudness"] as? [String: Any])
    let limitedGain = try #require(limitedReport["gainDb"] as? Double)
    #expect(try #require(limitedReport["limiterMaxReductionDb"] as? Double) > 0)
    var limiter = try SocialLimiter(gainDb: limitedGain, limiting: true, sampleRate: 48_000, channels: 2)
    let replayed = limiter.process(plain.wav) + limiter.finish()
    #expect(replayed.count == limited.wav.count)
    largest = 0
    for index in replayed.indices { largest = max(largest, abs(replayed[index] - limited.wav[index])) }
    #expect(largest < 1e-6, "largest limited difference \(largest)")
    #expect(try ExportedAudio.measure(limited.wav).truePeakDbtp ?? 0 <= SocialLoudness.ceilingDbtp + 1e-6)

    let source = try await NativeMediaFixtures.shared.file("speech-bursts.mov")
    let bad = try runCLI(["export", "--open", source.path, "--export", directory.appendingPathComponent("bad.mp4").path,
        "--loudness", "loud", "--json"], directory: directory)
    #expect(bad.status == 2)
}
}
