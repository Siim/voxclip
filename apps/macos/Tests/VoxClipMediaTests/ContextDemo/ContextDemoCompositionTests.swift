import AVFoundation
import CoreGraphics
import Foundation
import Testing
import VoxClipCore
@testable import VoxClipMedia

@MainActor
func compositionTestImage(generator: AVAssetImageGenerator, at time: CMTime) async throws -> CGImage {
    try await withCheckedThrowingContinuation { continuation in
        generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, image, _, result, error in
            if result == .succeeded, let image {
                continuation.resume(returning: image)
            } else {
                continuation.resume(throwing: error ?? CocoaError(.fileReadCorruptFile))
            }
        }
    }
}

private let compositionProjectID = "5b7e0f7a-3c1d-4b8e-9a51-2f6d0c8e4a11"

private func compositionTestDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("context-composition-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func compositionRecord(data: Data, width: Int = 320, height: Int = 180, duration: Double = 2) throws -> ContextDemoAsset {
    ContextDemoAsset(id: "capture-one", requestId: "request-one",
        target: ContextDemoTarget(kind: .desktopApp, displayName: "Synthetic demo", locator: "com.example.synthetic"),
        relativePath: try ContextDemoAsset.relativePath(projectId: compositionProjectID, assetId: "capture-one"),
        sha256: SpeechSHA256.hex(data), durationSeconds: duration, pixelWidth: width, pixelHeight: height,
        byteSize: Int64(data.count), createdAt: Date(timeIntervalSince1970: 1_793_577_600))
}

private func compositionStore(_ data: Data, record: ContextDemoAsset, root: URL) throws -> URL {
    let file = root.appendingPathComponent(record.relativePath)
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: file)
    return file
}

private func compositionPlan(_ kept: [MediaInterval] = [MediaInterval(startSample: 0, endSample: 96_000)]) -> EditPlan {
    EditPlan(sampleRate: 48_000, totalSamples: 96_000, kept: kept)
}

private func compositionInput(record: ContextDemoAsset, source: URL, plan: EditPlan,
                              scope: TimeRange? = nil, editedStart: Double = 0.25) throws -> ContextDemoRenderInput {
    var project = try JSONProjectStore.decode(FixtureLoader.data("fixtures/voice-lab/passage-render-v3.voxclip"))
    project.media.source.contentKey = try JSONProjectStore.contentKey(for: source)
    let document = ContextDemoDocument(projectId: project.id, planId: "composition-demo",
        narration: try ContextDemoNarrationSnapshot(timeline: .legacy(plan)), assets: [record],
        placements: [ContextDemoPlacement(id: "placement-one", assetId: record.id,
            source: TimeRange(start: 0.25, end: 1.25), editedStartSeconds: editedStart)],
        sourceContentKey: project.media.source.contentKey)
    return try ContextDemoPlanner.prepare(document: document, project: project, timeline: .legacy(plan), scope: scope)
}

@Suite("context-demo-composition-contract")
struct ContextDemoCompositionContractTests {
    @Test func snapshotRejectsTraversalSymlinksAndAlteration() throws {
        let root = try compositionTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = Data([0, 0, 0, 24] + Array("ftypmp42".utf8) + [0, 0, 0, 0] + Array("mp42isom".utf8))
        let record = try compositionRecord(data: data)
        let file = try compositionStore(data, record: record, root: root)
        let staged = try ContextDemoCompositionAssets.snapshot([record], projectId: compositionProjectID,
            root: root, scratchRoot: root)
        #expect(try Data(contentsOf: #require(staged.urls[record.id])) == data)
        try Data(repeating: 0, count: data.count).write(to: file)
        #expect(throws: (any Error).self) {
            _ = try ContextDemoCompositionAssets.snapshot([record], projectId: compositionProjectID, root: root, scratchRoot: root)
        }
        try FileManager.default.removeItem(at: file)
        let outside = root.appendingPathComponent("outside.mp4")
        try data.write(to: outside)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
        #expect(throws: ContextDemoCompositionError.unsafePath) {
            _ = try ContextDemoCompositionAssets.snapshot([record], projectId: compositionProjectID, root: root, scratchRoot: root)
        }
        #expect(throws: ContextDemoCompositionError.invalidBinding) {
            _ = try ContextDemoCompositionAssets.snapshot([record], projectId: "../outside", root: root, scratchRoot: root)
        }
        let staging = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("voxclip-context-composition-") }
        #expect(staging.map(\.standardizedFileURL) == [staged.directory.standardizedFileURL])
    }

    @Test func snapshotRejectsQuickTimeMasqueradingAsMP4() throws {
        let root = try compositionTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = Data([0, 0, 0, 24] + Array("ftypqt  ".utf8) + [0, 0, 0, 0] + Array("qt  qt  ".utf8))
        let record = try compositionRecord(data: data)
        _ = try compositionStore(data, record: record, root: root)
        #expect(throws: ContextDemoCompositionError.unsupportedVideo) {
            _ = try ContextDemoCompositionAssets.snapshot([record], projectId: compositionProjectID, root: root, scratchRoot: root)
        }
    }

    @Test func normalizedTopLeftMotionUsesCoreImageBottomLeftCoordinates() {
        let frame = CGRect(x: 10, y: 20, width: 320, height: 180)
        let crop = CompositionFrameGeometry.crop(in: frame, scale: 1.25, anchorX: 1, anchorY: 0)
        #expect(crop == CGRect(x: 74, y: 56, width: 256, height: 144))
        let centered = CompositionFrameGeometry.crop(in: frame, scale: 1.12, anchorX: 0.5, anchorY: 0.5)
        #expect(abs(centered.midX - frame.midX) < 1e-9)
        #expect(abs(centered.midY - frame.midY) < 1e-9)
        let face = CompositionFrameGeometry.faceCrop(in: frame,
            aspectCrop: CGRect(x: 100, y: 20, width: 100, height: 180), scale: 1.12, faceX: 1, faceY: 0)
        #expect(abs(face.maxX - frame.maxX) < 1e-9)
        #expect(abs(face.maxY - frame.maxY) < 1e-9)
    }
}

extension HeavyMediaTests {
@Suite("context-demo-composition-native", .serialized)
struct ContextDemoCompositionNativeTests {
    private func capturedVideo(root: URL) async throws -> ContextDemoAsset {
        let source = AVURLAsset(url: try await NativeMediaFixtures.shared.file("counter.mov"))
        let video = try #require(try await source.loadTracks(withMediaType: .video).first)
        let composition = AVMutableComposition()
        let track = try #require(composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
        try track.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(value: 2, timescale: 1)), of: video, at: .zero)
        let temporary = root.appendingPathComponent("capture.mp4")
        let session = try #require(AVAssetExportSession(asset: composition, presetName: AVAssetExportPreset1920x1080))
        try await session.export(to: temporary, as: .mp4)
        let data = try Data(contentsOf: temporary)
        let record = try compositionRecord(data: data, width: 1920, height: 1080)
        _ = try compositionStore(data, record: record, root: root)
        return record
    }

    private func request(source: URL, plan: EditPlan, input: ContextDemoRenderInput?, root: URL,
                         preview: Bool = false) throws -> RenderRequest {
        RenderRequest(sourceURL: source, plan: plan,
            output: OutputSpec(size: PixelSize(width: 320, height: 180), fps: 30, videoBitrate: 2_000_000),
            forPreview: preview, contextDemo: input, contextDemoRoot: root,
            sourceContentKey: try JSONProjectStore.contentKey(for: source))
    }

    @MainActor private func frame(asset: AVAsset, composition: AVVideoComposition? = nil, at time: Double) async throws -> Data {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.videoComposition = composition
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let requested = CMTime(seconds: time, preferredTimescale: 48_000)
        let image = try await compositionTestImage(generator: generator, at: requested)
        var pixels = Data(count: image.width * image.height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try #require(CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return pixels
    }

    @MainActor private func audio(_ graph: RenderGraph) async throws -> Data {
        let track = try #require(graph.audioTrack)
        let reader = try AVAssetReader(asset: graph.composition)
        let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: MediaSupport.pcm(rate: 48_000, channels: 2))
        output.audioMix = graph.audioMix
        let provider = reader.outputProvider(for: output)
        try #require(reader.startReading())
        defer { reader.cancelReading() }
        var result = Data()
        while let ready = try await MediaSupport.nextSample(provider) {
            try ready.withUnsafeSampleBuffer { sample in
                let block = try #require(CMSampleBufferGetDataBuffer(sample))
                var bytes = Data(count: CMBlockBufferGetDataLength(block))
                let status = bytes.withUnsafeMutableBytes {
                    CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
                }
                try #require(status == noErr)
                result.append(bytes)
            }
        }
        #expect(reader.status == .completed)
        return result
    }

    @Test @MainActor func scopedSilentTracksAndOriginalNarrationFollowTheSameCutMap() async throws {
        let root = try compositionTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await NativeMediaFixtures.shared.file()
        let record = try await capturedVideo(root: root)
        let plan = compositionPlan([MediaInterval(startSample: 0, endSample: 24_000),
                                    MediaInterval(startSample: 48_000, endSample: 96_000)])
        let input = try compositionInput(record: record, source: source, plan: plan)
        let render = try request(source: source, plan: plan, input: input, root: root)
        let graph = try await CompositionBuilder(scratchRoot: root).build(render)
        let baseline = try await CompositionBuilder().build(request(source: source, plan: plan, input: nil, root: root))
        #expect(graph.composition.tracks(withMediaType: .video).count == 2)
        #expect(graph.composition.tracks(withMediaType: .audio).count == 1)
        #expect(graph.composition.duration == CMTime(value: 72_000, timescale: 48_000))
        let narration = try await audio(graph)
        let originalNarration = try await audio(baseline)
        #expect(narration == originalNarration)
        let instructions = try graph.videoComposition.instructions.map { try #require($0 as? RenderInstruction) }
        #expect(instructions.map { $0.timeRange.start.value } == [0, 12_000, 60_000])
        #expect(instructions.map { $0.requiredSourceTrackIDs?.count } == [1, 2, 1])
        let scoped = try compositionInput(record: record, source: source, plan: plan, scope: TimeRange(start: 0.5, end: 1))
        let clippedPlan = compositionPlan([MediaInterval(startSample: 48_000, endSample: 72_000)])
        let clipped = try await CompositionBuilder(scratchRoot: root).build(request(source: source,
            plan: clippedPlan, input: scoped, root: root))
        #expect(clipped.composition.duration == CMTime(value: 24_000, timescale: 48_000))
        let captureTrack = try #require(clipped.composition.tracks(withMediaType: .video).last)
        let segment = try #require(captureTrack.segments.first(where: { !$0.isEmpty }))
        #expect(segment.timeMapping.source.start == CMTime(value: 24_000, timescale: 48_000))
        #expect(segment.timeMapping.target.start == .zero)
        #expect(segment.timeMapping.target.duration == CMTime(value: 24_000, timescale: 48_000))
        var stale = render
        stale.plan = compositionPlan([MediaInterval(startSample: 0, endSample: 72_000)])
        await #expect(throws: ContextDemoError.staleNarration) { _ = try await CompositionBuilder().build(stale) }
    }

    @Test @MainActor func realPreviewAndMP4ShareVisibleFootageAndHalfOpenBounds() async throws {
        let root = try compositionTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await NativeMediaFixtures.shared.file()
        let record = try await capturedVideo(root: root)
        let plan = compositionPlan()
        let input = try compositionInput(record: record, source: source, plan: plan)
        let render = try request(source: source, plan: plan, input: input, root: root)
        var previewRequest = render
        previewRequest.forPreview = true
        let preview = try await CompositionBuilder(scratchRoot: root).build(previewRequest)
        let exportGraph = try await CompositionBuilder(scratchRoot: root).build(render)
        let baseline = try await CompositionBuilder().build(request(source: source, plan: plan, input: nil, root: root))
        for time in [0.1, 0.5, 1.5] {
            let shown = try await frame(asset: preview.composition, composition: preview.videoComposition, at: time)
            let exportedFrame = try await frame(asset: exportGraph.composition, composition: exportGraph.videoComposition, at: time)
            #expect(shown == exportedFrame)
            let original = try await frame(asset: baseline.composition, composition: baseline.videoComposition, at: time)
            #expect((shown == original) == (time < 0.25 || time >= 1.25))
        }
        let destination = root.appendingPathComponent("demo-export.mp4")
        _ = try await AVExporter(appVersion: "0.1.0").export(ExportJob(render: render, outputURL: destination)) { _ in }
        let expected = try await frame(asset: preview.composition, composition: preview.videoComposition, at: 0.5)
        let decoded = try await frame(asset: AVURLAsset(url: destination), at: 0.5)
        try #require(expected.count == decoded.count)
        let difference = zip(expected, decoded).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(expected.count)
        #expect(difference < 8)
        #expect(try await AVURLAsset(url: destination).loadTracks(withMediaType: .audio).count == 1)
    }

    @Test @MainActor func previewUpdatesRetainFullDemoInstructionsAndLeases() async throws {
        let root = try compositionTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await NativeMediaFixtures.shared.file()
        let record = try await capturedVideo(root: root)
        let plan = compositionPlan()
        let plain = try request(source: source, plan: plan, input: nil, root: root)
        let preview = PreviewPlayerController()
        defer { preview.close() }
        try await preview.load(plain)
        try await preview.seek(to: 0.1, exact: true)
        let original = try #require(preview.player.currentItem)
        var layered = try request(source: source, plan: plan,
            input: compositionInput(record: record, source: source, plan: plan), root: root)
        try await preview.update(layered)
        let first = try #require(preview.player.currentItem as? LeasedPlayerItem)
        #expect(first !== original && first.renderGraph.contextDemoLease != nil)
        #expect(abs(preview.editedTime - 0.1) < 0.001)
        func instructions(_ item: AVPlayerItem) throws -> [RenderInstruction] {
            try #require(item.videoComposition).instructions.map { try #require($0 as? RenderInstruction) }
        }
        let initial = try instructions(first)
        #expect(initial.map { $0.requiredSourceTrackIDs?.count } == [1, 2, 1])
        #expect(initial.last?.timeRange.end == CMTime(value: 96_000, timescale: 48_000))
        layered.placement = CaptionPosition(x: 0.5, y: 0.2)
        try await preview.update(layered)
        let captions = try #require(preview.player.currentItem as? LeasedPlayerItem)
        #expect(captions !== first && captions.renderGraph.contextDemoLease != nil)
        let afterCaptions = try instructions(captions)
        #expect(afterCaptions.map { $0.timeRange } == initial.map { $0.timeRange })
        #expect(afterCaptions.map { $0.requiredSourceTrackIDs?.count } == [1, 2, 1])
        layered.contextDemo = try compositionInput(record: record, source: source, plan: plan, editedStart: 0.75)
        try await preview.update(layered)
        let moved = try #require(preview.player.currentItem as? LeasedPlayerItem)
        let afterMove = try instructions(moved)
        #expect(afterMove[1].timeRange.start == CMTime(value: 36_000, timescale: 48_000))
        #expect(afterMove.last?.timeRange.end == CMTime(value: 96_000, timescale: 48_000))
        #expect(moved.renderGraph.contextDemoLease != nil)
        try await preview.update(plain)
        let removed = try #require(preview.player.currentItem as? LeasedPlayerItem)
        #expect(removed.renderGraph.contextDemoLease == nil)
        let afterRemoval = try instructions(removed)
        #expect(afterRemoval.count == 1 && afterRemoval[0].requiredSourceTrackIDs?.count == 1)
        #expect(afterRemoval[0].timeRange.duration == CMTime(value: 96_000, timescale: 48_000))
    }

    @Test @MainActor func motionIsPreviewReducedButAuthoredForExportAndFullTakeIsIdentity() async throws {
        let source = try await NativeMediaFixtures.shared.file()
        let root = try compositionTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var authored = try request(source: source, plan: compositionPlan(), input: nil, root: root)
        authored.motionClipID = "clip-main"
        authored.motionCues = [MotionCue(id: "motion-one", clipID: "clip-main", sourceStart: 0, sourceEnd: 2,
            keyframes: [MotionKeyframe(progress: 0, scale: 1.35, anchorX: 1, anchorY: 0)])]
        authored.reduceMotion = true
        let exportGraph = try await CompositionBuilder().build(authored)
        authored.forPreview = true
        let preview = try await CompositionBuilder().build(authored)
        authored.forPreview = false; authored.motionClipID = nil
        let fullTake = try await CompositionBuilder().build(authored)
        let reduced = try await frame(asset: preview.composition, composition: preview.videoComposition, at: 0.5)
        let fullTakeFrame = try await frame(asset: fullTake.composition, composition: fullTake.videoComposition, at: 0.5)
        let authoredFrame = try await frame(asset: exportGraph.composition, composition: exportGraph.videoComposition, at: 0.5)
        #expect(reduced == fullTakeFrame)
        #expect(reduced != authoredFrame)
    }

    @Test @MainActor func missingDemoFramesCannotFallBackAndRemovalNeedsNoCaptureFiles() async throws {
        let root = try compositionTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await NativeMediaFixtures.shared.file()
        let record = try await capturedVideo(root: root)
        let plan = compositionPlan()
        let input = try compositionInput(record: record, source: source, plan: plan)
        let render = try request(source: source, plan: plan, input: input, root: root)
        let graph = try await CompositionBuilder(scratchRoot: root).build(render)
        let capture = try #require(graph.composition.tracks(withMediaType: .video).last)
        graph.composition.removeTrack(capture)
        await #expect(throws: (any Error).self) {
            _ = try await frame(asset: graph.composition, composition: graph.videoComposition, at: 0.5)
        }
        let document = ContextDemoDocument(projectId: input.projectId, planId: input.planId,
            narration: input.narration, assets: [record], placements: [ContextDemoPlacement(id: "placement-one",
                assetId: record.id, source: TimeRange(start: 0.25, end: 1.25), editedStartSeconds: 0.25)],
            sourceContentKey: input.sourceContentKey)
        let removed = try document.removingPlacement(id: "placement-one", expectedRevision: 0)
        var project = try JSONProjectStore.decode(FixtureLoader.data("fixtures/voice-lab/passage-render-v3.voxclip"))
        project.media.source.contentKey = input.sourceContentKey
        let empty = try ContextDemoPlanner.prepare(document: removed, project: project, timeline: .legacy(plan))
        try FileManager.default.removeItem(at: root.appendingPathComponent(record.relativePath))
        var ordinary = render
        ordinary.contextDemo = empty; ordinary.contextDemoRoot = nil
        let restored = try await CompositionBuilder().build(ordinary)
        #expect(restored.contextDemoLease == nil)
        #expect(restored.composition.tracks(withMediaType: .video).count == 1)
        #expect(restored.composition.tracks(withMediaType: .audio).count == 1)
    }

    @Test @MainActor func identityMetadataCancellationAndInstructionLeaseFailClosed() async throws {
        let root = try compositionTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await NativeMediaFixtures.shared.file()
        let record = try await capturedVideo(root: root)
        let input = try compositionInput(record: record, source: source, plan: compositionPlan())
        var render = try request(source: source, plan: compositionPlan(), input: input, root: root)
        render.sourceContentKey = nil
        await #expect(throws: ContextDemoCompositionError.invalidBinding) { _ = try await CompositionBuilder().build(render) }
        render.sourceContentKey = String(repeating: "0", count: 64)
        await #expect(throws: ContextDemoCompositionError.invalidBinding) { _ = try await CompositionBuilder().build(render) }
        render = try request(source: source, plan: compositionPlan(), input: input, root: root)
        render.sourceURL = try await NativeMediaFixtures.shared.file("counter.mov")
        await #expect(throws: ContextDemoCompositionError.invalidBinding) { _ = try await CompositionBuilder().build(render) }
        render.sourceURL = source
        let task = Task { @MainActor in _ = try await CompositionBuilder(scratchRoot: root).build(render) }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        var graph: RenderGraph? = try await CompositionBuilder(scratchRoot: root).build(render)
        let directory = try #require(graph?.contextDemoLease?.directory)
        var retained: RenderInstruction? = try #require(graph?.videoComposition.instructions.first as? RenderInstruction)
        graph = nil
        #expect(FileManager.default.fileExists(atPath: directory.path))
        #expect(retained?.contextDemoLease?.directory == directory)
        retained = nil
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        let wrong = try compositionRecord(data: Data(contentsOf: root.appendingPathComponent(record.relativePath)), width: 318, height: 180)
        let invalid = try compositionInput(record: wrong, source: source, plan: compositionPlan())
        await #expect(throws: ContextDemoCompositionError.invalidVideo) {
            _ = try await CompositionBuilder(scratchRoot: root).build(request(source: source, plan: compositionPlan(), input: invalid, root: root))
        }
    }
}
}
