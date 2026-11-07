import AVFoundation
import Foundation
import Testing
import VoxClipCore
@testable import VoxClipMedia

/// Social loudness at export (ADR-R47): the exported MP4's decoded audio is measured with the shared Core meter.
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

    let off = directory.appendingPathComponent("off.mp4")
    let unchanged = try await AVExporter().export(ExportedAudio.job(source, seconds: 6, to: off, loudness: .off)) { _ in }
    #expect(unchanged.loudness == nil)
    let offLufs = try #require(try ExportedAudio.measure(try await ExportedAudio.samples(off)).integratedLufs())
    #expect(abs(offLufs - sourceLoudness) <= 0.5, "off \(offLufs) vs source \(sourceLoudness)")
    #expect(abs((lufs - offLufs) - report.gainDb) < 0.2, "the gain is all that differs")
}

@Test(.timeLimit(.minutes(2))) func socialLoudnessStopsAtTheTruePeakCeilingAndSaysSo() async throws {
    let directory = try cliDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = try await NativeMediaFixtures.shared.file("speech-clicks.mov")
    let output = directory.appendingPathComponent("capped.mp4")
    let result = try await AVExporter().export(ExportedAudio.job(source, seconds: 6, to: output)) { _ in }
    let report = try #require(result.loudness)
    #expect(report.capped)
    #expect(abs((report.truePeakDbtp ?? 0) - SocialLoudness.ceilingDbtp) < 1e-9)
    #expect((report.outputLufs ?? 0) < SocialLoudness.targetLufs - 1)
    let exported = try ExportedAudio.measure(try await ExportedAudio.samples(output))
    let lufs = try #require(exported.integratedLufs())
    #expect(abs(lufs - (report.outputLufs ?? 0)) <= 0.5, "exported \(lufs) vs reported \(String(describing: report.outputLufs))")
    // AAC may ring a little past the PCM's −1 dBTP on a click; the encoded peak stays within 0.5 dB of it.
    #expect(try #require(exported.truePeakDbtp) <= SocialLoudness.ceilingDbtp + 0.5, "exported true peak \(String(describing: exported.truePeakDbtp))")
}

@Test(.timeLimit(.minutes(2))) func cliLoudnessFlagReportsAndTheEditedWAVCarriesTheGain() async throws {
    let directory = try cliDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = try await NativeMediaFixtures.shared.file("speech-bursts.mov")
    let probe = try await AVMediaProbe().probe(source)
    let transcript = Transcript(durationSeconds: probe.durationSeconds, engine: EngineRef(id: .elevenlabs, engineVersion: "synthetic-fixture"),
        rawKey: String(repeating: "0", count: 64), createdAt: Date(timeIntervalSince1970: 0))
    let transcriptURL = directory.appendingPathComponent("transcript.json")
    try ProjectJSON.encoder().encode(transcript).write(to: transcriptURL)
    func export(_ name: String, _ extra: [String]) throws -> (json: [String: Any], wav: [Float]) {
        let output = directory.appendingPathComponent("\(name).mp4"), audio = directory.appendingPathComponent("\(name).wav")
        let result = try runCLI(["export", "--open", source.path, "--transcript", transcriptURL.path, "--export", output.path,
            "--audio-out", audio.path, "--style", "off", "--json", "--quiet"] + extra, directory: directory, timeout: 60)
        try #require(result.status == 0, "CLI exit \(result.status): \(result.stderr)")
        let wav = try Data(contentsOf: audio).dropFirst(44).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        return (try result.json, wav)
    }
    let off = try export("off", ["--loudness", "off"])
    #expect(off.json["loudness"] is NSNull)
    let social = try export("social", [])
    let report = try #require(social.json["loudness"] as? [String: Any])
    #expect(Set(report.keys) == ["measuredLufs", "gainDb", "outputLufs", "truePeakDbtp", "capped"])
    let gain = try #require(report["gainDb"] as? Double)
    #expect(gain > 8 && gain < 12 && report["capped"] as? Bool == false)
    #expect(abs((report["outputLufs"] as? Double ?? 0) - SocialLoudness.targetLufs) < 1e-6)
    // The WAV is the edited voice at its own level times the same static gain.
    let factor = SocialLoudness.linearGain(gain)
    #expect(off.wav.count == social.wav.count && off.wav.count == 6 * 48000 * 2)
    var largest: Float = 0
    for index in off.wav.indices { largest = max(largest, abs(off.wav[index] * factor - social.wav[index])) }
    #expect(largest < 1e-6, "largest difference \(largest)")
    let bad = try runCLI(["export", "--open", source.path, "--export", directory.appendingPathComponent("bad.mp4").path,
        "--loudness", "loud", "--json"], directory: directory)
    #expect(bad.status == 2)
}
}
