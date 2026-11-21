#if DEBUG
import AppKit
import AVFoundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import VoxClipCore
import VoxClipMedia
@testable import VoxClip

@MainActor
@Suite("Generated illustration with a fake system sheet", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["VOXCLIP_DATA_DIR"] != nil), .offlineFixtures)
struct IllustrativeCutawayTests {
    private func project() throws -> Project {
        let fixture = try SharedResources.locate().root.appendingPathComponent("fixtures/projects/interview-take.voxclip")
        return try JSONProjectStore.decode(Data(contentsOf: fixture))
    }

    private func editor(media: URL? = nil) async throws -> (EditorModel, UndoManager) {
        _ = NSApplication.shared
        let app = AppModel()
        var project = try project()
        project.edits.cutWordIds.removeAll { $0 == "w6" }
        if let media {
            project.media.source.absolutePath = media.path
            project.media.source.contentKey = try JSONProjectStore.contentKey(for: media)
            project.media.source.sizeBytes = Int64(try #require(media.resourceValues(forKeys: [.fileSizeKey]).fileSize))
        }
        await app.shell.attachForTesting(VoxClipDocument(project: project, demo: true), selection: .fullTake)
        let model = try #require(app.shell.editor)
        model.mediaResolved = true
        model.refresh()
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.undoManager = undo
        model.selectedWordIDs = ["w4", "w5", "w6", "w7", "w8"]
        return (model, undo)
    }

    private func image(at url: URL, size: Int = 128) throws {
        let context = try #require(CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(red: 0.9, green: 0.2, blue: 0.1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        try #require(CGImageDestinationFinalize(destination))
    }

    private func transaction(_ undo: UndoManager, _ edit: () -> Bool) -> Bool {
        undo.beginUndoGrouping()
        defer { undo.endUndoGrouping() }
        return edit()
    }

    private func pixel(_ graph: RenderGraph, at seconds: Double) async throws -> [UInt8] {
        let generator = AVAssetImageGenerator(asset: graph.composition)
        generator.videoComposition = graph.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let time = CMTime(seconds: seconds, preferredTimescale: 48_000)
        let image: CGImage = try await withCheckedThrowingContinuation { continuation in
            generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, image, _, result, error in
                if result == .succeeded, let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: error ?? CocoaError(.fileReadCorruptFile))
                }
            }
        }
        var pixel = [UInt8](repeating: 0, count: 4)
        try pixel.withUnsafeMutableBytes { bytes in
            let context = try #require(CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return pixel
    }

    @Test func boundsAndOverlapAreCheckedBeforeAnySheetRequest() throws {
        let original = try project()
        var project = original
        project.edits.cutWordIds.removeAll()
        project.edits.clips = [ClipRange(id: "active", startWordId: "w4", endWordId: "w8", origin: .manual)]
        let timeline = try RenderCallerInputs.timeline(project: project)
        let document = try ContextDemoDocument(project: project, planId: "test", timeline: timeline)
        let selection: Set<String> = ["w4", "w5", "w6", "w7", "w8"]
        let result = try IllustrativeCutawaySelection.matching(project: project, clipID: "active", selected: selection,
            timeline: timeline, document: document)
        #expect(result.phrase == "we shipped uh the clipper.")
        #expect(abs(result.start - timeline.mapTime(2.6)) < 0.000_01)
        #expect(abs(result.end - timeline.mapTime(4.2)) < 0.000_01)
        for invalid: Set<String> in [[], ["w4", "w8"], ["w5"], selection.union(["w3"]), Set((0..<31).map(String.init))] {
            #expect(throws: IllustrativeCutawayIssue.selection) {
                _ = try IllustrativeCutawaySelection.matching(project: project, clipID: "active", selected: invalid,
                    timeline: timeline, document: document)
            }
        }
        let cutTimeline = try RenderCallerInputs.timeline(project: original)
        let cutDocument = try ContextDemoDocument(project: original, planId: "test", timeline: cutTimeline)
        #expect(throws: IllustrativeCutawayIssue.selection) {
            _ = try IllustrativeCutawaySelection.matching(project: original, clipID: nil, selected: selection,
                timeline: cutTimeline, document: cutDocument)
        }
        let asset = ContextDemoAsset(id: "other", requestId: "other", target: IllustrativeCutawayAssets.target,
            relativePath: try ContextDemoAsset.relativePath(projectId: project.id, assetId: "other"),
            sha256: String(repeating: "a", count: 64), durationSeconds: 2, pixelWidth: 128, pixelHeight: 128,
            byteSize: 100, createdAt: Date())
        let occupied = try document.placing(asset: asset, placement: ContextDemoPlacement(id: "other", assetId: "other",
            source: TimeRange(start: 0, end: result.duration), editedStartSeconds: result.start), expectedRevision: 0)
        #expect(throws: IllustrativeCutawayIssue.occupied) {
            _ = try IllustrativeCutawaySelection.matching(project: project, clipID: nil, selected: selection,
                timeline: timeline, document: occupied)
        }
    }

    @Test func fakeImageProducesSilentPlacementAndSingleStepApplyRemoveUndo() async throws {
        let source = try SharedResources.locate().root.appendingPathComponent("fixtures/media/fillers-chirp.mp4")
        let (model, undo) = try await editor(media: source)
        defer { model.close() }
        let root = model.app.locations.root
        let photo = root.appendingPathComponent("fake-\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: photo) }
        try image(at: photo)
        let session = IllustrativeCutawaySession(model: model)
        let original = model.project
        let narration = try RenderCallerInputs.timeline(project: original)
        model.openGeneratedIllustrationReview()
        let routed = try #require(model.contextDemoSession?.illustrationReviewRequest)
        session.reviewSelection(expected: routed)
        let selection = try #require(session.selection)
        #expect(session.prompt.contains("we shipped"))
        #expect(session.sheetRequest == nil)
        session.openSheet(supported: false)
        #expect(session.sheetRequest == nil)
        session.prompt = String(repeating: "😀", count: 257)
        session.openSheet(supported: true)
        #expect(session.sheetRequest == nil)
        session.prompt = "A paper rocket lifting off"
        session.openSheet(supported: true)
        let request = try #require(session.sheetRequest)
        #expect(request.prompt == "A paper rocket lifting off")
        session.receive(photo, requestID: request.id)
        try FileManager.default.removeItem(at: photo)
        await session.preparation?.value
        let draft = try #require(session.draft)
        defer { try? IllustrativeCutawayAssets(root: root).discard(draft.asset) }
        #expect(model.contextDemoDocument == nil)
        let video = AVURLAsset(url: draft.url)
        #expect(try await video.loadTracks(withMediaType: .audio).isEmpty)
        #expect(try await video.loadTracks(withMediaType: .video).count == 1)
        #expect(try await video.load(.duration).seconds >= selection.duration)
        #expect(transaction(undo) { session.apply() })
        let applied = try #require(model.contextDemoDocument)
        let placement = try #require(applied.placements.first)
        #expect(placement.editedStartSeconds == selection.start)
        #expect(placement.source.end == selection.duration)
        let render = try ContextDemoPlanner.prepare(document: applied, project: model.project, timeline: narration)
        #expect(render.preservesNarration && render.captureAudioGain == 0)
        #expect(render.placements.first?.output.start == selection.start)
        #expect(try RenderCallerInputs.timeline(project: model.project) == narration)
        #expect(model.project.transcript == original.transcript)
        #expect(model.project.media == original.media)
        guard case .legacy(let plan) = narration else { Issue.record("Expected the fixture to use the legacy timeline"); return }
        let renderRequest = RenderRequest(sourceURL: source, plan: plan,
            output: OutputSpec(size: PixelSize(width: 320, height: 180), fps: 30, videoBitrate: 2_000_000), forPreview: true)
        let baseline = try await CompositionBuilder().build(RenderCallerInputs.prepare(renderRequest,
            project: original, clipID: nil, dataRoot: root))
        let illustrated = try await CompositionBuilder().build(RenderCallerInputs.prepare(renderRequest,
            project: model.project, clipID: nil, dataRoot: root))
        let audibleTrack = try #require(illustrated.audioTrack)
        let baselineTrack = try #require(baseline.audioTrack)
        let audible: [AVCompositionTrackSegment] = (audibleTrack as AVCompositionTrack).segments
        let baselineAudio: [AVCompositionTrackSegment] = (baselineTrack as AVCompositionTrack).segments
        #expect(audible.count == baselineAudio.count)
        let audioTimingUnchanged = zip(audible, baselineAudio).allSatisfy { pair in
            pair.0.timeMapping.source == pair.1.timeMapping.source && pair.0.timeMapping.target == pair.1.timeMapping.target
        }
        #expect(audioTimingUnchanged)
        for time in [0.1, selection.end + 0.2] {
            let shown = try await pixel(illustrated, at: time)
            let original = try await pixel(baseline, at: time)
            #expect(shown == original)
        }
        let insideTime = selection.start + 0.3
        let inside = try await pixel(illustrated, at: insideTime)
        let originalPixel = try await pixel(baseline, at: insideTime)
        #expect(inside[0] > 165 && inside[1] < 100 && inside[2] < 80)
        #expect(inside != originalPixel)
        undo.undo()
        #expect(model.contextDemoDocument == nil)
        undo.redo()
        #expect(model.contextDemoDocument == applied)
        #expect(transaction(undo) { session.remove(placement.id) })
        #expect(model.contextDemoDocument == nil)
        #expect(FileManager.default.fileExists(atPath: draft.url.path))
        undo.undo()
        #expect(model.contextDemoDocument == applied)
        #expect(try IllustrativeCutawayAssets(root: root).verifiedURL(for: draft.asset) == draft.url)
    }

    @Test func staleAndCancelledCallbacksCannotPublishAndInvalidImageIsRejected() async throws {
        let (model, _) = try await editor()
        defer { model.close() }
        let root = model.app.locations.root
        let file = root.appendingPathComponent("fake-invalid-\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("not an image".utf8).write(to: file)
        let link = root.appendingPathComponent("fake-link-\(UUID()).png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        defer { try? FileManager.default.removeItem(at: link) }
        #expect(throws: IllustrativeCutawayAssetError.invalidImage) { _ = try IllustrativeCutawayAssets.readImage(at: link) }
        let session = IllustrativeCutawaySession(model: model)
        let outdated = IllustrativeCutawayReviewRequest(snapshot: model.contextDemoSnapshot(), clipID: nil)
        model.selectedWordIDs = ["w1"]
        if case .unavailable(let reason) = session.readiness { #expect(reason.contains("0.75")) }
        else { Issue.record("Expected a short phrase to disable illustration") }
        session.reviewSelection(expected: outdated)
        #expect(session.selection == nil)
        #expect(session.sheetRequest == nil)
        model.selectedWordIDs = ["w4", "w5", "w6", "w7", "w8"]
        session.reviewSelection()
        session.openSheet(supported: true)
        let cancelled = try #require(session.sheetRequest)
        session.cancelledSheet(cancelled.id)
        session.receive(file, requestID: cancelled.id)
        #expect(session.preparation == nil)
        session.openSheet(supported: true)
        let stale = try #require(session.sheetRequest)
        model.selectedWordIDs = ["w1"]
        session.receive(file, requestID: stale.id)
        #expect(session.selection == nil)
        #expect(session.preparation == nil)
        #expect(session.message?.contains("changed") == true)
        model.selectedWordIDs = ["w4", "w5", "w6", "w7", "w8"]
        session.reviewSelection()
        session.openSheet(supported: true)
        let invalid = try #require(session.sheetRequest)
        session.receive(file, requestID: invalid.id)
        await session.preparation?.value
        #expect(session.draft == nil)
        #expect(session.message?.contains("usable illustration") == true)
        #expect(model.contextDemoDocument == nil)
    }
}
#endif
