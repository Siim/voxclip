import AVFoundation
import CryptoKit
import Foundation
import Testing
import VoxClipCore
@testable import VoxClipMedia

/// Synthetic source and paid WAVs only; shared v3 records retain their schema and recipes.
func voiceCallerFixture(in directory: URL) async throws -> Project {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let shared = try FixtureLoader.sharedRoot(environment: [:])
    let original = shared.appendingPathComponent("fixtures/media/joins-tone.mov")
    let source = directory.appendingPathComponent("source.mov")
    let session = try #require(AVAssetExportSession(asset: AVURLAsset(url: original), presetName: AVAssetExportPresetPassthrough))
    session.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: 7, preferredTimescale: 48_000))
    try await session.export(to: source, as: .mov)
    let probe = try await AVMediaProbe().probe(source)
    var project = try JSONProjectStore.decode(Data(contentsOf: shared.appendingPathComponent("fixtures/voice-lab/passage-render-v3.voxclip")))
    project.media.source.absolutePath = source.path
    project.media.source.relativePath = "source.mov"
    project.media.source.sizeBytes = try #require((FileManager.default.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?.int64Value)
    project.media.source.contentKey = try JSONProjectStore.contentKey(for: source)
    project.media.source.video = probe.video
    project.media.source.audio = probe.audio
    let scale = Int64(try #require(probe.audio).sampleRate / 1000)
    let paid = directory.appendingPathComponent("data/VoiceLab/\(project.id)")
    try FileManager.default.createDirectory(at: paid, withIntermediateDirectories: true)
    for index in project.voiceLab.assets!.indices {
        let asset = project.voiceLab.assets![index]
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: true))
        let url = paid.appendingPathComponent(URL(fileURLWithPath: asset.file).lastPathComponent)
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096))
            var cursor = 0
            let count = Int((asset.durationSeconds * 24_000).rounded())
            while cursor < count {
                let frames = min(4096, count - cursor)
                buffer.frameLength = AVAudioFrameCount(frames)
                for frame in 0..<frames { buffer.int16ChannelData![0][frame] = Int16((9_000 * sin(2 * .pi * Double(index == 0 ? 880 : 660) * Double(cursor + frame) / 24_000)).rounded()) }
                try file.write(from: buffer)
                cursor += frames
            }
        }
        project.voiceLab.assets![index].sha256 = SpeechSHA256.hex(try Data(contentsOf: url))
    }
    for index in project.voiceLab.segments[0].candidates.indices {
        var recipe = try #require(project.voiceLab.segments[0].candidates[index].recipe)
        recipe.video.sourceStartSample *= scale; recipe.video.sourceEndSample *= scale; recipe.video.outputSamples *= scale
        if var room = recipe.roomTone { room.sourceStartSample *= scale; room.sourceEndSample *= scale; room.gainDb = -30; recipe.roomTone = room }
        recipe.seams.in.fadeSamples *= scale; recipe.seams.in.sourceHandleSamples *= scale
        recipe.seams.out.fadeSamples *= scale; recipe.seams.out.sourceHandleSamples *= scale
        for chunk in recipe.chunks.indices {
            recipe.chunks[chunk].sourceStartSample *= scale; recipe.chunks[chunk].sourceEndSample *= scale
            recipe.chunks[chunk].assetSha256 = project.voiceLab.assets![index].sha256
        }
        project.voiceLab.segments[0].candidates[index].recipe = recipe
    }
    project.edits.clips = [ClipRange(id: "included", startWordId: "w3", endWordId: "w6", title: "Replacement"),
                           ClipRange(id: "outside", startWordId: "w1", endWordId: "w2", title: "Source")]
    project.edits.activeClipId = nil
    project.captions.styleId = "vox-highlight"
    project.captions.position = CaptionPosition(x: 0.15, y: 0.12)
    project.captions.positionByAspect["16:9"] = CaptionPosition(x: 0.15, y: 0.12)
    project.captions.overrides = ["font.sizeScale": .number(1.1)]
    project.export.aspect = .landscape; project.export.srt = true
    try JSONProjectStore.encode(project).write(to: directory.appendingPathComponent("caller.voxclip"))
    return project
}

func verifyVoiceCallerOutput(_ output: URL, expected: VoiceLabOutputPlan) throws {
    let bytes = try Data(contentsOf: output)
    let uuid = Data([0xBE, 0x7A, 0xCF, 0xCB, 0x97, 0xA9, 0x42, 0xE8, 0x9C, 0x71, 0x99, 0x94, 0x91, 0xE3, 0xAF, 0xAC])
    var offset = 0, marks = 0
    while offset < bytes.count {
        try #require(offset + 8 <= bytes.count)
        var size = bytes[offset..<offset+4].reduce(UInt64(0)) { $0 * 256 + UInt64($1) }
        let type = String(decoding: bytes[offset+4..<offset+8], as: UTF8.self)
        let header = size == 1 ? 16 : 8
        if size == 1 { try #require(offset + 16 <= bytes.count); size = bytes[offset+8..<offset+16].reduce(UInt64(0)) { $0 * 256 + UInt64($1) } }
        try #require(size >= header && size <= bytes.count - offset)
        if type == "uuid", size >= header + 16, bytes[offset+header..<offset+header+16] == uuid {
            marks += 1
            let rdf = String(decoding: bytes[offset+header+16..<offset+Int(size)], as: UTF8.self)
            #expect(rdf.contains("Iptc4xmpExt:DigitalSourceType"))
            #expect(rdf.contains("http://cv.iptc.org/newscodes/digitalsourcetype/compositeWithTrainedAlgorithmicMedia"))
        }
        offset += Int(size)
    }
    #expect(marks == 1)
    let sidecar = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: output.path + ".provenance.json"))) as? [String: Any])
    let export = try #require(sidecar["export"] as? [String: Any])
    #expect(export["sha256"] as? String == SpeechSHA256.hex(bytes))
    #expect(export["file"] as? String == output.lastPathComponent)
    #expect(export["durationSeconds"] as? Double == expected.duration)
}

func verifyVoiceCallerAudio(_ output: URL, expected: VoiceLabOutputPlan) async throws {
    let asset = AVURLAsset(url: output)
    let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
    let range = try await track.load(.timeRange)
    #expect(abs(range.duration.seconds - expected.duration) < 1 / 48_000)
    guard let synth = expected.pieces.first(where: { $0.kind == .synth }) else { return }
    let middle = Double(synth.outputStartSample + synth.outputEndSample) / (2 * expected.sampleRate)
    let first = Int((middle * 48_000).rounded()) - 2400
    let reader = try AVAssetReader(asset: asset)
    let provider = reader.outputProvider(for: AVAssetReaderTrackOutput(track: track, outputSettings: MediaSupport.pcm(rate: 48_000, channels: 2)))
    try #require(reader.startReading())
    var samples = [Float](repeating: .nan, count: 4800)
    while let ready = try await MediaSupport.nextSample(provider) {
        let start = Int((ready.presentationTimeStamp.seconds * 48_000).rounded())
        try ready.withUnsafeSampleBuffer { sample in
            let block = try #require(CMSampleBufferGetDataBuffer(sample))
            var data = Data(count: CMBlockBufferGetDataLength(block))
            let status = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
            try #require(status == noErr && data.count == Int(ready.sampleCount) * 8)
            data.withUnsafeBytes { bytes in
                for frame in 0..<Int(ready.sampleCount) where (first..<first + 4800).contains(start + frame) {
                    samples[start + frame - first] = bytes.loadUnaligned(fromByteOffset: frame * 8, as: Float.self)
                }
            }
        }
    }
    #expect(reader.status == .completed)
    try #require(samples.allSatisfy { $0.isFinite })
    func magnitude(_ hz: Double) -> Double {
        var real = 0.0, imaginary = 0.0
        for (i, sample) in samples.enumerated() {
            let phase = 2 * Double.pi * hz * Double(i) / 48_000
            real += Double(sample) * cos(phase); imaginary += Double(sample) * sin(phase)
        }
        return hypot(real, imaginary) / Double(samples.count)
    }
    #expect(magnitude(880) > 0.04)
    #expect(magnitude(880) > 3 * magnitude(440))
}

extension HeavyMediaTests {
@Suite("voice-lab-callers", .serialized)
struct VoiceLabCallerTests {
    @Test(.timeLimit(.minutes(3)), arguments: ["full", "clip", "off", "dormant-cuts", "source-only"])
    func cliExportsReviewedRecipe(_ route: String) async throws {
        let directory = try cliDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var project = try await voiceCallerFixture(in: directory)
        if route == "dormant-cuts" { project.edits.cutWordIds = ["w4", "w5"] }
        let scope: VoiceLabOutputScope = route == "clip" ? .clip("included") : route == "source-only" ? .clip("outside") : .full
        if route == "off" { project.captions.styleId = "off" }
        let input = directory.appendingPathComponent("caller.voxclip")
        try JSONProjectStore.encode(project).write(to: input)
        let original = try Data(contentsOf: input)
        let expected = try VoiceLabOutputPlanner.build(project, scope: scope)
        let output = directory.appendingPathComponent("result.mp4")
        let wav = directory.appendingPathComponent("result.wav"), srt = directory.appendingPathComponent("result.srt")
        var arguments = ["--open", input.path, "--export", output.path, "--audio-out", wav.path, "--json", "--quiet"]
        if route != "off" { arguments += ["--srt", srt.path] }
        if case .clip(let id) = scope { arguments += ["--clip", id] }
        let result = try runCLI(arguments, directory: directory, timeout: 90)
        try #require(result.status == 0, "CLI exit \(result.status): \(String(decoding: result.stdout, as: UTF8.self)) \(result.stderr)")
        let file = try AVAudioFile(forReading: wav)
        #expect(file.length == Int64((expected.duration * 48_000).rounded()))
        if expected.requiresSyntheticRendering {
            try verifyVoiceCallerOutput(output, expected: expected)
            try await verifyVoiceCallerAudio(output, expected: expected)
            try await verifyVoiceCallerAudio(wav, expected: expected)
            if route != "off" { #expect(try String(contentsOf: srt, encoding: .utf8).lowercased().contains("new")) }
        } else { #expect(!FileManager.default.fileExists(atPath: output.path + ".provenance.json")) }
        #expect(try Data(contentsOf: input) == original)
    }

    @Test(.timeLimit(.minutes(2)), arguments: ["missing", "altered", "fit", "video", "legacy", "collision"])
    func cliRefusesUnsafeRecipeWithoutReplacingOutputs(_ failure: String) async throws {
        let directory = try cliDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var project = try await voiceCallerFixture(in: directory)
        let paid = directory.appendingPathComponent("data/VoiceLab/\(project.voiceLab.assets![0].file)")
        if failure == "missing" { try FileManager.default.removeItem(at: paid) }
        if failure == "altered" { let file = try FileHandle(forWritingTo: paid); try file.seek(toOffset: 100); try file.write(contentsOf: Data([1, 2, 3, 4])); try file.close() }
        if failure == "fit" {
            project.voiceLab.segments[0].audio.stretch = 1 + 1e-9
            project.voiceLab.segments[0].candidates[0].recipe!.audio.stretch = 1 + 1e-9
        }
        if failure == "video" { project.voiceLab.segments[0].candidates[0].recipe!.video.mode = .retimed; project.voiceLab.segments[0].candidates[0].recipe!.video.retimeFactor = 1 }
        if failure == "legacy" {
            project.schemaVersion = 2
            project.voiceLab.cleanAudio = nil; project.voiceLab.voices = nil; project.voiceLab.videoAssets = nil
            project.voiceLab.segments[0].scope = nil; project.voiceLab.segments[0].groupId = nil
            project.voiceLab.segments[0].provenance.region = nil
            for i in project.voiceLab.segments[0].candidates.indices { project.voiceLab.segments[0].candidates[i].recipe = nil }
        }
        let input = directory.appendingPathComponent("caller.voxclip")
        try JSONProjectStore.encode(project).write(to: input)
        let output = directory.appendingPathComponent("result.mp4"), wav = directory.appendingPathComponent("result.wav")
        let sidecar = URL(fileURLWithPath: output.path + ".provenance.json")
        let sentinel = Data("previous output".utf8)
        for url in [output, wav, sidecar] { try sentinel.write(to: url) }
        let result = try runCLI(["--open", input.path, "--export", output.path, "--audio-out", failure == "collision" ? sidecar.path : wav.path, "--json", "--quiet"], directory: directory)
        #expect(result.status == 5)
        let message = try #require((result.json["error"] as? [String: Any])?["message"] as? String)
        if failure == "missing" { #expect(message.contains("missing")) }
        if failure == "altered" { #expect(message.contains("changed")) }
        if failure == "fit" { #expect(message.contains("stretched")) }
        for url in [output, wav, sidecar] { #expect(try Data(contentsOf: url) == sentinel) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).allSatisfy { !$0.contains(".partial") })
    }
}
}
