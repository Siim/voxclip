import AVFoundation
import CryptoKit
import Foundation
import Testing
import VoxClipCore
import VoxClipMedia
import XCTest

@Suite("canonical-cli-e2e", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["VOXCLIP_REQUIRE_E2E"] == "1" ||
                    ProcessInfo.processInfo.environment["VOXCLIP_CLI"] != nil,
                "Set VOXCLIP_CLI to run the canonical CLI media suite"))
struct MediaCliE2ETests {
    static let cases = [
        "e2e-1-chirp-cut-fillers", "e2e-2-tone-joins", "e2e-3-captions-vox-bold",
        "e2e-3-captions-vox-highlight", "e2e-4-style-off", "e2e-5-everything-cut",
        "e2e-6-big-source", "e2e-7-counter-9x16", "e2e-8-bars", "e2e-9-tiny-webm"
    ]

    @Test(.timeLimit(.minutes(5)), arguments: cases)
    func cliExportsMatchDecodedMedia(_ caseId: String) async throws {
        let strict = ProcessInfo.processInfo.environment["VOXCLIP_REQUIRE_E2E"] == "1"
        let shared = try FixtureLoader.sharedRoot()
        let fixtures = shared.appendingPathComponent("fixtures/media")
        let index = fixtures.appendingPathComponent("index.json")
        var package = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { package.deleteLastPathComponent() }
        let cli = ProcessInfo.processInfo.environment["VOXCLIP_CLI"] ?? package.appendingPathComponent(".build/debug/voxclip-cli").path
        if !FileManager.default.fileExists(atPath: index.path) || !FileManager.default.isExecutableFile(atPath: cli) {
            let reason = "Canonical media index or built CLI is absent: \(index.path), \(cli)"
            if strict { throw NSError(domain: "VoxClipE2EPrerequisite", code: 1, userInfo: [NSLocalizedDescriptionKey: reason]) }
            throw XCTSkip(reason)
        }
        if strict { try #require(cli.hasPrefix("/"), "VOXCLIP_CLI must be absolute") }
        try verifyHashes(fixtures, index: index)
        let sourceName: String = switch caseId {
        case "e2e-2-tone-joins": "joins-tone.mov"
        case "e2e-6-big-source": "big-2400x1350.mp4"
        case "e2e-7-counter-9x16": "counter-1080p.mp4"
        case "e2e-8-bars": "bars-1080p.mp4"
        case "e2e-9-tiny-webm": "tiny.webm"
        default: "fillers-chirp.mp4"
        }
        let source = fixtures.appendingPathComponent(sourceName)
        let directory = try cliDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("output.mp4")
        let wave = directory.appendingPathComponent("edited.wav")
        var arguments = ["--open", source.path, "--export", output.path, "--json", "--quiet", "--style", "off"]
        let needsCuts = caseId == "e2e-1-chirp-cut-fillers" || caseId == "e2e-2-tone-joins" ||
            caseId.hasPrefix("e2e-3-") || caseId == "e2e-4-style-off" || caseId == "e2e-5-everything-cut"
        if needsCuts {
            let transcript = caseId == "e2e-2-tone-joins" ? "joins-tone.transcript.json" :
                caseId == "e2e-5-everything-cut" ? "fillers-only.transcript.json" : "fillers-chirp.transcript.json"
            arguments += ["--transcript", fixtures.appendingPathComponent(transcript).path, "--cut-fillers"]
        }
        if caseId == "e2e-1-chirp-cut-fillers" || caseId == "e2e-2-tone-joins" {
            arguments += ["--audio-out", wave.path]
        }
        if caseId.hasPrefix("e2e-3-") { arguments[arguments.firstIndex(of: "--style")! + 1] = String(caseId.dropFirst("e2e-3-captions-".count)) }
        if caseId == "e2e-7-counter-9x16" { arguments += ["--aspect", "9:16"] }
        if caseId == "e2e-6-big-source" { arguments += ["--aspect", "source"] }
        if ["e2e-6-big-source", "e2e-7-counter-9x16", "e2e-8-bars", "e2e-9-tiny-webm"].contains(caseId) {
            var transcript = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixtures.appendingPathComponent("fillers-chirp.transcript.json"))) as? [String: Any])
            let first = try #require((transcript["words"] as? [[String: Any]])?.first)
            transcript["words"] = [first]
            let path = directory.appendingPathComponent("synthetic-transcript.json")
            try JSONSerialization.data(withJSONObject: transcript).write(to: path)
            arguments += ["--transcript", path.path]
        }
        let invocation = try runCLI(arguments, directory: directory, timeout: 240)
        let result = try invocation.json
        try writeReport(caseId, status: invocation.status, result: result)
        if caseId == "e2e-9-tiny-webm" {
            #expect(invocation.status == 3)
            #expect((result["error"] as? [String: Any])?["code"] as? String == "unsupportedContainer")
            #expect(!FileManager.default.fileExists(atPath: output.path))
            return
        }
        if caseId == "e2e-5-everything-cut" {
            #expect(invocation.status == 5)
            #expect((result["error"] as? [String: Any])?["code"] as? String == "everythingCut")
            #expect(!FileManager.default.fileExists(atPath: output.path))
            return
        }
        try #require(invocation.status == 0, "\(caseId): CLI exit \(invocation.status): \(invocation.stderr)")
        try #require(result["ok"] as? Bool == true)
        let probe = try await AVMediaProbe().probe(output)
        #expect(probe.isPlayable && probe.videoCodec == "h264")
        if caseId == "e2e-1-chirp-cut-fillers" {
            let plan = try await expectedPlan(source: source, transcript: fixtures.appendingPathComponent("fillers-chirp.transcript.json"))
            #expect(plan.joins.count == 17)
            #expect(result["audioSamples"] as? Int64 == plan.outputSamples)
            let edited = try waveSamples(wave, plan: plan)
            let original = try await decodedAudio(source)
            for fraction in [0.08, 0.5, 0.94] {
                let center = Int(Double(plan.outputSamples) * fraction)
                var bestLag = 0, best = -Double.infinity
                for lag in -96...96 {
                    var score = 0.0
                    for offset in -2048..<2048 {
                        let outputFrame = center + offset
                        let sourceFrame = Int((plan.sourceTime(Double(outputFrame) / 48000) * 48000).rounded()) + lag
                        if outputFrame >= 0 && outputFrame < Int(plan.outputSamples) && sourceFrame >= 0 && sourceFrame * 2 < original.count {
                            score += Double(edited[outputFrame * 2]) * Double(original[sourceFrame * 2])
                        }
                    }
                    if score > best { best = score; bestLag = lag }
                }
                #expect(best > 0.1 && abs(bestLag) < 48, "chirp fraction \(fraction): lag \(bestLag), score \(best)")
            }
        }
        if caseId == "e2e-2-tone-joins" {
            let plan = try await expectedPlan(source: source, transcript: fixtures.appendingPathComponent("joins-tone.transcript.json"))
            #expect(plan.joins.count == 59)
            #expect(result["audioSamples"] as? Int64 == plan.outputSamples)
            let samples = try waveSamples(wave, plan: plan)
            for join in plan.joins {
                for offset in -3...3 { for channel in 0..<2 {
                    #expect(abs(samples[(Int(join.outSample) + offset) * 2 + channel]) < 0.01,
                            "join \(join.outSample), offset \(offset), channel \(channel)")
                } }
            }
        }
        if caseId.hasPrefix("e2e-3-") {
            let transcript = fixtures.appendingPathComponent("fillers-chirp.transcript.json")
            let plan = try await expectedPlan(source: source, transcript: transcript)
            let state = EditReducer.reduce(EditState(transcript: try ProjectJSON.decoder().decode(Transcript.self, from: Data(contentsOf: transcript))), command: .cutFillers)
            let words = captionCopy(try buildSegments(state, activeClip: nil), plan: plan)
            try #require(!words.isEmpty)
            let checks = words.flatMap { word in [
                (time: max(0, word.start - 0.12), present: false, id: word.id),
                (time: (word.start + word.end) / 2, present: true, id: word.id),
                (time: word.end + 0.12, present: false, id: word.id)
            ] }
            let frameCount = try #require(result["frames"] as? Int)
            let inMedia = checks.filter { check in
                let frame = Int((check.time * 30).rounded())
                return frame >= 0 && frame < frameCount
            }
            try #require(inMedia.filter(\.present).count == words.count)
            let counts = try await brightCaptionCounts(output, frames: Set(inMedia.map { Int(($0.time * 30).rounded()) }))
            for check in inMedia {
                let count = try #require(counts[Int((check.time * 30).rounded())])
                #expect(check.present ? count > 10 : count == 0, "caption \(check.id) at \(check.time): \(count) bright pixels")
            }
        }
        if caseId == "e2e-4-style-off" {
            let plan = try await expectedPlan(source: source, transcript: fixtures.appendingPathComponent("fillers-chirp.transcript.json"))
            #expect(result["captionStyle"] as? String == "off")
            #expect(abs((result["durationSeconds"] as? Double ?? 0) - plan.duration) <= 0.001)
        }
        if caseId == "e2e-6-big-source" {
            #expect(probe.orientedSize == PixelSize(width: 1920, height: 1080))
        }
        if caseId == "e2e-7-counter-9x16" {
            #expect(probe.orientedSize == PixelSize(width: 1080, height: 1920))
            var points = [(Int, Int)]()
            for marker in [185, 895] { for offset in -3...3 { points.append((marker + offset, 500)) } }
            for bit in 0..<12 {
                let x = Int((Double(720 + 16 + 40 * bit - 656) * 1080 / 608).rounded())
                points.append((x, 57))
            }
            let frames = try await sampledFrames(output, points: points)
            #expect(frames.count == 120)
            for (index, frame) in frames.enumerated() {
                for marker in 0..<2 { #expect(frame.pixels[(marker * 7)..<(marker * 7 + 7)].contains { $0.min()! > 150 }, "frame \(index), marker \(marker)") }
                let code = frame.pixels.dropFirst(14).reduce(0) { ($0 << 1) | ($1.min()! > 150 ? 1 : 0) }
                #expect(code == index, "frame \(index), barcode \(code)")
            }
        }
        if caseId == "e2e-8-bars" {
            #expect(try await AVURLAsset(url: output).loadTracks(withMediaType: .audio).isEmpty)
            let expected = [[191,191,191], [191,191,0], [0,191,191], [0,191,0],
                            [191,0,191], [191,0,0], [0,0,191], [0,0,0]]
            let points = (0..<8).flatMap { bar in (0..<3).map { position in (bar * 240 + 60 * (position + 1), 300 + 200 * position) } }
            let frames = try await sampledFrames(output, points: points)
            #expect(frames.count == 60)
            for index in [9, 15, 30] { for bar in 0..<8 { for position in 0..<3 { for channel in 0..<3 {
                let actual = frames[index].pixels[bar * 3 + position][channel]
                #expect(abs(actual - expected[bar][channel]) <= 3,
                        "frame \(index), bar \(bar), point \(position), RGB \(channel): \(actual)")
            } } } }
        }
    }

    private func verifyHashes(_ directory: URL, index: URL) throws {
        let entries = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: index)) as? [[String: Any]])
        let names = Set(["joins-tone.mov", "fillers-chirp.mp4", "counter-1080p.mp4", "big-2400x1350.mp4", "bars-1080p.mp4", "tiny.webm"])
        try #require(entries.count == 6 && Set(entries.compactMap { $0["file"] as? String }) == names)
        for entry in entries {
            let name = try #require(entry["file"] as? String)
            let data = try Data(contentsOf: directory.appendingPathComponent(name))
            try #require(data.count == entry["bytes"] as? Int, "\(name): indexed byte size")
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            try #require(hash == entry["sha256"] as? String, "\(name): indexed SHA-256")
        }
    }

    private func expectedPlan(source: URL, transcript: URL) async throws -> EditPlan {
        let text = try ProjectJSON.decoder().decode(Transcript.self, from: Data(contentsOf: transcript))
        let state = EditReducer.reduce(EditState(transcript: text), command: .cutFillers)
        let probe = try await AVMediaProbe().probe(source)
        return try EditPlan.build(transcript: text, editState: state, activeClip: nil,
                                  duration: probe.durationSeconds, sampleRate: Double(probe.audio?.sampleRate ?? 48000))
    }

    private func waveSamples(_ path: URL, plan: EditPlan) throws -> [Float] {
        let data = try Data(contentsOf: path)
        try #require(data.count == 44 + Int(plan.outputSamples) * 8)
        try #require(String(data: data.prefix(4), encoding: .ascii) == "RIFF")
        try #require(String(data: data[8..<12], encoding: .ascii) == "WAVE")
        try #require((Int(data[22]) | (Int(data[23]) << 8)) == 2, "edited WAV needs two channels")
        let rate = (0..<4).reduce(0) { $0 | Int(data[24 + $1]) << (8 * $1) }
        try #require(rate == 48000, "edited WAV needs 48 kHz")
        return data.dropFirst(44).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    private func decodedAudio(_ url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 2, AVSampleRateKey: 48000])
        reader.add(output)
        try #require(reader.startReading())
        var samples = [Float]()
        while let sample = output.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(buffer)
            var chunk = [Float](repeating: 0, count: length / 4)
            let copied = chunk.withUnsafeMutableBytes { bytes in
                CMBlockBufferCopyDataBytes(buffer, atOffset: 0, dataLength: length, destination: bytes.baseAddress!)
            }
            try #require(copied == noErr)
            samples.append(contentsOf: chunk)
        }
        try #require(reader.status == .completed)
        return samples
    }

    private func brightCaptionCounts(_ url: URL, frames wanted: Set<Int>) async throws -> [Int: Int] {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        let provider = reader.outputProvider(for: output)
        try #require(reader.startReading())
        var counts = [Int: Int](), index = 0
        while let ready = try await provider.next() {
            if wanted.contains(index) {
                counts[index] = try ready.withUnsafeSampleBuffer { sample in
                    let buffer = try #require(CMSampleBufferGetImageBuffer(sample))
                    CVPixelBufferLockBaseAddress(buffer, .readOnly)
                    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
                    let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
                    let rowStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
                    let luma = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 0)).assumingMemoryBound(to: UInt8.self)
                    var count = 0
                    for row in stride(from: height * 7 / 10, to: height * 9 / 10, by: 2) {
                        for column in stride(from: width / 4, to: width * 3 / 4, by: 2) {
                            if luma[row * rowStride + column] >= 188 { count += 1 }
                        }
                    }
                    return count
                }
            }
            index += 1
        }
        try #require(reader.status == .completed)
        return counts
    }

    private func writeReport(_ caseId: String, status: Int32, result: [String: Any]) throws {
        guard let path = ProcessInfo.processInfo.environment["VOXCLIP_E2E_OUT"], !path.isEmpty else { return }
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let report: [String: Any] = ["caseId": caseId, "platform": "macos", "exitCode": Int(status), "result": result]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent(caseId + ".json"), options: .atomic)
    }
}
