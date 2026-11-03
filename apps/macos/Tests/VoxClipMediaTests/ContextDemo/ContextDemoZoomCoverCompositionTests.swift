import AVFoundation
import Foundation
import Testing
import VoxClipCore
@testable import VoxClipMedia

private func zoomCoverProject(duration: Double, source: URL? = nil, paidRoot: URL? = nil) throws -> Project {
    var project = try JSONProjectStore.decode(FixtureLoader.data("fixtures/voice-lab/passage-render-v3.voxclip"))
    project.media.source.audio!.sampleRate = 48_000
    if let source {
        project.media.source.absolutePath = source.path
        project.media.source.relativePath = source.lastPathComponent
        project.media.source.contentKey = try JSONProjectStore.contentKey(for: source)
        project.media.source.sizeBytes = try #require((FileManager.default.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?.int64Value)
        project.media.source.video = MediaVideo(width: 320, height: 180, frameRate: 30, rotationDegrees: 0)
        project.media.source.audio!.channels = 2
    }
    if let paidRoot {
        let directory = paidRoot.appendingPathComponent(project.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for index in project.voiceLab.assets!.indices {
            let data = zoomCoverWave(rate: 24_000, seconds: 1.2, frequency: index == 0 ? 880 : 660)
            project.voiceLab.assets![index].durationSeconds = 1.2
            project.voiceLab.assets![index].sha256 = SpeechSHA256.hex(data)
            try data.write(to: paidRoot.appendingPathComponent(project.voiceLab.assets![index].file))
        }
    } else { project.voiceLab.assets![0].durationSeconds = 1.2 }
    for index in project.voiceLab.segments[0].candidates.indices {
        var recipe = try #require(project.voiceLab.segments[0].candidates[index].recipe)
        recipe.video.sourceStartSample *= 48
        recipe.video.sourceEndSample *= 48
        recipe.video.outputSamples *= 48
        recipe.roomTone?.sourceStartSample *= 48
        recipe.roomTone?.sourceEndSample *= 48
        recipe.seams.in.fadeSamples *= 48
        recipe.seams.in.sourceHandleSamples *= 48
        recipe.seams.out.fadeSamples *= 48
        recipe.seams.out.sourceHandleSamples *= 48
        for chunk in recipe.chunks.indices {
            recipe.chunks[chunk].sourceStartSample *= 48
            recipe.chunks[chunk].sourceEndSample *= 48
            recipe.chunks[chunk].assetSha256 = project.voiceLab.assets![index].sha256
        }
        if index == 0 {
            recipe.outDuration = duration
            recipe.audio.trimEnd = recipe.audio.trimStart + duration
            recipe.audio.stretch = 1
            recipe.words = [VoiceLabWord(text: "new", start: 0.05, end: duration * 0.4, synthetic: true),
                            VoiceLabWord(text: "words", start: duration * 0.4, end: duration - 0.05, synthetic: true)]
            recipe.chunks[recipe.chunks.count - 1].assembledEndFrame = Int64((recipe.audio.trimEnd * 24_000).rounded())
            recipe.video.mode = .zoomCover
            recipe.video.outputSamples = Int64((duration * 48_000).rounded())
            recipe.video.retimeFactor = Double(recipe.video.sourceEndSample - recipe.video.sourceStartSample) / Double(recipe.video.outputSamples)
            recipe.video.zoom = 1.12; recipe.video.faceX = 0.5; recipe.video.faceY = 0.5
            project.voiceLab.segments[0].outDuration = recipe.outDuration
            project.voiceLab.segments[0].audio = recipe.audio
            project.voiceLab.segments[0].words = recipe.words
        }
        project.voiceLab.segments[0].candidates[index].recipe = recipe
    }
    return project
}

private func zoomCoverWave(rate: Int, seconds: Double, frequency: Double) -> Data {
    let frames = Int(seconds * Double(rate))
    var data = Data()
    func text(_ value: String) { data.append(contentsOf: value.utf8) }
    func integer<Value: FixedWidthInteger>(_ value: Value) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
    text("RIFF"); integer(UInt32(36 + frames * 2)); text("WAVEfmt "); integer(UInt32(16))
    integer(UInt16(1)); integer(UInt16(1)); integer(UInt32(rate)); integer(UInt32(rate * 2))
    integer(UInt16(2)); integer(UInt16(16)); text("data"); integer(UInt32(frames * 2))
    for frame in 0..<frames {
        let sample = Int16((sin(2 * .pi * frequency * Double(frame) / Double(rate)) * 3_000).rounded())
        integer(sample)
    }
    return data
}

private func zoomCoverRequest(project: Project, paidRoot: URL) throws -> RenderRequest {
    let prepared = try VoiceLabRenderContract.prepare(project, scope: .full, labelPosition: .topRight)
    let input = try VoiceLabRenderInput(project: project, scope: .full, labelPosition: .topRight,
        paidRoot: paidRoot, prepared: prepared)
    let transcript = try #require(project.transcript)
    let edits = project.edits
    let pauses = try detectPauses(transcript.words, thresholdSeconds: edits.pauseThresholdSeconds)
    let state = EditState(transcript: transcript, pauses: pauses,
        pauseThresholdSeconds: edits.pauseThresholdSeconds, pauseKeepSeconds: edits.pauseKeepSeconds,
        cutWordIds: Set(edits.cutWordIds), cutPauseIds: Set(edits.cutPauseIds),
        corrections: edits.corrections, clips: edits.clips, activeClipId: nil)
    let plan = try EditPlan.build(transcript: transcript, editState: state, activeClip: nil,
        duration: project.media.source.durationSeconds, sampleRate: 48_000)
    return RenderRequest(sourceURL: URL(fileURLWithPath: project.media.source.absolutePath), plan: plan,
        output: OutputSpec(size: PixelSize(width: 320, height: 180), fps: 30, videoBitrate: 2_000_000), voiceLab: input)
}

@Suite("context-demo-zoom-cover-contract", .offlineFixtures)
struct ContextDemoZoomCoverContractTests {
    @Test func videoCutKeepsAudioContinuousAndPunchesInOnlyAfterTheJump() throws {
        var project = try zoomCoverProject(duration: 0.63)
        var recipe = try #require(project.voiceLab.segments[0].candidates[0].recipe)
        let start = recipe.video.sourceStartSample, end = recipe.video.sourceEndSample
        recipe.video.mode = .cut; recipe.video.retimeFactor = nil
        recipe.video.zoom = 1.06; recipe.video.faceX = 0.5; recipe.video.faceY = 0.5
        let removed = end - start - recipe.video.outputSamples
        recipe.video.cuts = [.init(startSample: start + 14_400, endSample: start + 14_400 + removed)]
        project.voiceLab.segments[0].candidates[0].recipe = recipe
        let request = try zoomCoverRequest(project: project, paidRoot: URL(fileURLWithPath: "/unread-paid-root"))
        let spans = try CompositionVideoSpan.build(request)
        let before = try #require(spans.first { $0.source.start == CMTime(value: start, timescale: 48_000) })
        let after = try #require(spans.first { $0.source.end == CMTime(value: end, timescale: 48_000) })
        #expect(before.zoom == 1 && after.zoom == 1.06)
        #expect(before.source.duration == before.output.duration && after.source.duration == after.output.duration)
        #expect(before.output.end == after.output.start)
        #expect(after.source.start.value - before.source.end.value == removed)
        #expect(request.voiceLab?.prepared.selectedSegmentRecipes.count == 1)
        #expect(request.voiceLab?.prepared.selectedSegmentRecipes[0].recipe.audio.stretch == 1)
        recipe.video.cuts = [.init(startSample: start, endSample: start + removed)]
        project.voiceLab.segments[0].candidates[0].recipe = recipe
        #expect(throws: (any Error).self) { try zoomCoverRequest(project: project, paidRoot: URL(fileURLWithPath: "/unread-paid-root")) }
    }

    @Test(arguments: [0.875, 0.56]) func endpointsAndBoundsAreOnTheDeclaredOutputGrid(_ duration: Double) throws {
        let request = try zoomCoverRequest(project: zoomCoverProject(duration: duration), paidRoot: URL(fileURLWithPath: "/unread-paid-root"))
        let spans = try CompositionVideoSpan.build(request)
        let pieces = try #require(request.voiceLab).prepared.outputPlan.pieces
        #expect(spans.count == pieces.count)
        for (span, piece) in zip(spans, pieces) {
            #expect(span.output.start == CMTime(value: piece.outputStartSample, timescale: 48_000))
            #expect(span.output.end == CMTime(value: piece.outputEndSample, timescale: 48_000))
            #expect(span.source.start == CMTime(value: piece.sourceStartSample, timescale: 48_000))
            #expect(span.source.end == CMTime(value: piece.sourceEndSample, timescale: 48_000))
            #expect(span.zoom == (piece.kind == .synth ? 1.12 : 1))
        }
        let piece = try #require(pieces.first { $0.kind == .synth })
        #expect(piece.outputEndSample - piece.outputStartSample == Int64((duration * 48_000).rounded()))
        let sourceMiddle = Double(piece.sourceStartSample + piece.sourceEndSample) / 96_000
        let outputMiddle = Double(piece.outputStartSample + piece.outputEndSample) / 96_000
        #expect(abs(request.timeline.mapTime(sourceMiddle) - outputMiddle) < 1 / 48_000)
        #expect(abs(request.timeline.sourceTime(outputMiddle) - sourceMiddle) < 1 / 48_000)
    }

    @Test func nonunitySpeechRemainsRefusedBeforeAssetIO() throws {
        var project = try zoomCoverProject(duration: 0.7)
        var recipe = try #require(project.voiceLab.segments[0].candidates[0].recipe)
        recipe.audio.trimEnd = 0.75
        recipe.audio.stretch = 0.7 / 0.65
        recipe.chunks[recipe.chunks.count - 1].assembledEndFrame = 18_000
        recipe.video.mode = .source
        recipe.video.retimeFactor = nil; recipe.video.zoom = nil
        recipe.video.faceX = nil; recipe.video.faceY = nil
        project.voiceLab.segments[0].audio = recipe.audio
        project.voiceLab.segments[0].candidates[0].recipe = recipe
        #expect(throws: VoiceLabRenderCapabilityError.nonunityFitUnsupported) {
            _ = try VoiceLabRenderPreflight.prepare(project: project, scope: .full, paidRoot: URL(fileURLWithPath: "/unread-paid-root"))
        }
    }

    @Test func legacyRetimedStaysUnsupportedAndLipsyncUsesValidatedBasePolicy() {
        #expect(!VoiceLabRenderInput.supportsVideoMode(.retimed))
        #expect(VoiceLabRenderInput.supportsVideoMode(.lipsync))
    }
}

extension HeavyMediaTests {
@Suite("context-demo-zoom-cover-native", .serialized, .offlineFixtures)
struct ContextDemoZoomCoverNativeTests {
    @Test @MainActor func lipsyncPreparationFaceGateAndPreviewExportFrames() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lipsync-composition-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await NativeMediaFixtures.shared.file("joins-tone.mov")
        var project = try zoomCoverProject(duration: 0.875, source: source, paidRoot: root)
        let baseRequest = try zoomCoverRequest(project: project, paidRoot: root)
        let outputPlan = try #require(baseRequest.voiceLab).prepared.outputPlan
        let recipe = try #require(project.voiceLab.segments[0].candidates[0].recipe)
        let sourceWindow = try LipsyncWindow.make(seamIn: recipe.video.sourceStartSample,
            seamOut: recipe.video.sourceEndSample, totalSamples: outputPlan.totalSourceSamples, sampleRate: 48_000, phraseID: 0)
        let window = try LipsyncRenderWindow(source: sourceWindow, plan: outputPlan)
        #expect(window.syncMode == .remap)
        await #expect(throws: LipsyncPreparationError.noClearFace) {
            _ = try await LipsyncWindowPreparation.prepare(request: baseRequest, window: window, scratchRoot: root, detector: { _ in 0 })
        }
        let prepared = try await LipsyncWindowPreparation.prepare(request: baseRequest, window: window, scratchRoot: root, detector: { _ in 0.2 })
        #expect(prepared.width == 320 && prepared.height == 180 && prepared.fps == 30)
        #expect(prepared.audio.data.count == 44 + Int((window.seconds(sampleRate: 48_000) * 48_000).rounded()) * 2)
        let mezzanine = root.appendingPathComponent("check.mp4")
        try prepared.video.data.write(to: mezzanine)
        let native = try await LipsyncResultValidation.validate(file: mezzanine, durationSeconds: window.seconds(sampleRate: 48_000), fps: 30, width: 320, height: 180)
        #expect(native.frameRate == 30)
        let whiteGraph = try await CompositionBuilder(scratchRoot: root).build(baseRequest, includeDisclosure: false, colorCorrection: (0, 0.95))
        let assetID = UUID().uuidString.lowercased()
        let lipFile = root.appendingPathComponent("\(project.id)/\(assetID).mp4")
        let range = CMTimeRange(start: CMTime(value: window.outputStartSample, timescale: 48_000),
            end: CMTime(value: window.outputEndSample, timescale: 48_000))
        try await LipsyncMezzanine.write(graph: whiteGraph, range: range, output: baseRequest.output, to: lipFile)
        let bytes = try Data(contentsOf: lipFile)
        project.voiceLab.videoAssets = [VoiceLabVideoAsset(id: assetID, file: "\(project.id)/\(assetID).mp4",
            sha256: SpeechSHA256.hex(bytes), durationSeconds: range.duration.seconds, frameRate: 30, width: 320, height: 180)]
        project.voiceLab.segments[0].candidates[0].recipe!.video = recipe.video.addingLipsync(assetID: assetID,
            requestID: "11111111-2222-4333-8444-555555555555", sourceWindow: window.source, syncMode: .remap)
        let request = try zoomCoverRequest(project: project, paidRoot: root)
        let graph = try await CompositionBuilder(scratchRoot: root).build(request)
        let instructions = graph.videoComposition.instructions.compactMap { $0 as? RenderInstruction }
        #expect(instructions.contains { !$0.lipsyncLayers.isEmpty && $0.videoZoom == 1.12 })
        let preview = PreviewPlayerController()
        defer { preview.close() }
        try await preview.load(request)
        let previewItem = try #require(preview.player.currentItem as? LeasedPlayerItem)
        #expect(previewItem.renderGraph.videoComposition.instructions.contains { ($0 as? RenderInstruction)?.lipsyncLayers.isEmpty == false })
        let generator = AVAssetImageGenerator(asset: graph.composition)
        generator.videoComposition = graph.videoComposition
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let piece = try #require(outputPlan.pieces.first { $0.kind == .synth })
        let fadeStart = Double(piece.outputStartSample) / 48_000 - 0.2
        var levels: [Double] = []
        for frame in 0...3 {
            let image = try await compositionTestImage(generator: generator,
                at: CMTime(seconds: fadeStart + Double(frame) / 30, preferredTimescale: 600_000))
            levels.append(try Self.centerLuma(image))
        }
        #expect(levels[3] > levels[0] + 30)
        #expect(levels[1] > levels[0] && levels[2] > levels[1] && levels[3] > levels[2])
        let destination = root.appendingPathComponent("lip-export.mp4")
        _ = try await AVExporter(appVersion: "0.1.0").export(ExportJob(render: request, outputURL: destination)) { _ in }
        let exported = AVAssetImageGenerator(asset: AVURLAsset(url: destination))
        exported.requestedTimeToleranceBefore = .zero; exported.requestedTimeToleranceAfter = .zero
        let image = try await exported.image(at: CMTime(seconds: fadeStart + 0.15, preferredTimescale: 600_000)).image
        #expect(try Self.centerLuma(image) > 200)
        #expect(request.voiceLab?.prepared.disclosure.postText?.contains("Lip movements in parts of it were generated with AI.") == true)
        let (conformed, warning) = try await LipsyncResultConformer.conform(lipFile, duration: range.duration.seconds,
            fps: 30, width: 160, height: 90, reference: prepared.video)
        let resized = try await LipsyncResultValidation.validate(file: conformed, durationSeconds: range.duration.seconds,
            fps: 30, width: 160, height: 90)
        #expect(resized.width == 160 && resized.height == 90 && warning)
    }

    private static func centerLuma(_ image: CGImage) throws -> Double {
        var pixel = [UInt8](repeating: 0, count: 4)
        let drawn = pixel.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                let cropped = image.cropping(to: CGRect(x: image.width / 2, y: image.height / 2, width: 1, height: 1)) else { return false }
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1)); return true
        }
        #expect(drawn)
        return (Double(pixel[0]) + Double(pixel[1]) + Double(pixel[2])) / 3
    }

    @Test @MainActor func changedDurationScalesOnlyVideoAndKeepsNaturalGeneratedSpeech() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zoom-composition-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = AVURLAsset(url: try await NativeMediaFixtures.shared.file("joins-tone.mov"))
        let session = try #require(AVAssetExportSession(asset: original, presetName: AVAssetExportPresetPassthrough))
        session.timeRange = CMTimeRange(start: .zero, duration: CMTime(value: 7, timescale: 1))
        let source = root.appendingPathComponent("source.mov")
        try await session.export(to: source, as: .mov)
        let project = try zoomCoverProject(duration: 0.875, source: source, paidRoot: root)
        let request = try zoomCoverRequest(project: project, paidRoot: root)
        let plan = try #require(request.voiceLab).prepared.outputPlan
        let graph = try await CompositionBuilder(scratchRoot: root).build(request)
        #expect(graph.composition.duration == CMTime(value: plan.outputSamples, timescale: 48_000))
        let preview = PreviewPlayerController()
        defer { preview.close() }
        try await preview.load(request)
        let firstItem = try #require(preview.player.currentItem)
        var captionUpdate = request
        captionUpdate.placement = CaptionPosition(x: 0.5, y: 0.2)
        try await preview.update(captionUpdate)
        let updatedItem = try #require(preview.player.currentItem as? LeasedPlayerItem)
        #expect(updatedItem !== firstItem && updatedItem.renderGraph.voiceLabLease != nil)
        let updatedInstructions = try #require(updatedItem.videoComposition).instructions.map { try #require($0 as? RenderInstruction) }
        #expect(updatedInstructions.contains { $0.videoZoom == 1.12 })
        #expect(updatedInstructions.last?.timeRange.end == CMTime(value: plan.outputSamples, timescale: 48_000))
        let spans = try CompositionVideoSpan.build(request)
        let segments = graph.videoTrack.segments.filter { !$0.isEmpty }
        #expect(segments.count == spans.count)
        for (span, segment) in zip(spans, segments) {
            #expect(segment.timeMapping.source == span.source)
            #expect(segment.timeMapping.target == span.output)
        }
        let mixed = try AVAudioFile(forReading: #require(graph.voiceLabLease).mixedAudioURL,
                                    commonFormat: .pcmFormatFloat32, interleaved: false)
        #expect(mixed.length == plan.outputSamples)
        let replacement = try #require(plan.pieces.first { $0.kind == .synth })
        mixed.framePosition = replacement.outputStartSample + 4_800
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: mixed.processingFormat, frameCapacity: 24_000))
        try mixed.read(into: buffer, frameCount: 24_000)
        let samples = try #require(buffer.floatChannelData?[0])
        func magnitude(_ frequency: Double) -> Double {
            var real = 0.0, imaginary = 0.0
            for frame in 0..<Int(buffer.frameLength) {
                let phase = 2 * Double.pi * frequency * Double(frame) / 48_000
                real += Double(samples[frame]) * cos(phase)
                imaginary += Double(samples[frame]) * sin(phase)
            }
            return hypot(real, imaginary)
        }
        #expect(magnitude(880) > 10 * magnitude(704))
        let generator = AVAssetImageGenerator(asset: graph.composition)
        generator.videoComposition = graph.videoComposition
        let image = try await compositionTestImage(generator: generator,
            at: CMTime(value: replacement.outputStartSample + 4_800, timescale: 48_000))
        #expect(image.width == 320 && image.height == 180)
        let destination = root.appendingPathComponent("zoom-export.mp4")
        let exported = try await AVExporter(appVersion: "0.1.0").export(ExportJob(render: request, outputURL: destination)) { _ in }
        #expect(exported.audioSamples == plan.outputSamples)
        let outputDuration = try await AVURLAsset(url: destination).load(.duration).seconds
        #expect(abs(outputDuration - plan.duration) < 1 / 30.0)
    }
}
}
