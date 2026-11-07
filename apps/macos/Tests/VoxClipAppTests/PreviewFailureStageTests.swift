#if DEBUG
import AppKit
import AVFoundation
import CoreVideo
import Foundation
import QuartzCore
import SwiftUI
import Testing
import VoxClipCore
import VoxClipMedia
@testable import VoxClip

/// A preview that can't draw is never a silent black box (design.md §5.4.4 g): a compositor failure is logged by its tag
/// and shown on the stage over the player, with Reload Preview; and a Make it postable result previews real frames through
/// the app's own request path. Offline: a synthetic clip written at run time, stub engines, no window.
@Suite("Preview failure on the stage", .serialized, .enabled(if: ProcessInfo.processInfo.environment["VOXCLIP_DATA_DIR"] != nil, "Use an isolated VOXCLIP_DATA_DIR"), .offlineFixtures)
@MainActor struct PreviewFailureStageTests {
    /// A preview engine whose failures the test sends.
    @MainActor final class FailingEngine: PreviewEngine {
        let events: AsyncStream<PreviewEvent>
        private let continuation: AsyncStream<PreviewEvent>.Continuation
        private(set) var isPlaying = false
        private(set) var editedTime = 0.0
        private(set) var loads = 0
        init() { (events, continuation) = AsyncStream.makeStream() }
        func load(_ request: RenderRequest) async throws { loads += 1 }
        func update(_ request: RenderRequest) async throws {}
        func seek(to editedTime: Double, exact: Bool) async throws {}
        func play() {}
        func pause() {}
        func close() {}
        func fail(_ reason: PreviewFailureReason?) { continuation.yield(.failed(.decodeFailed("Preview frames failed"), reason: reason)) }
    }

    /// An 8 s synthetic clip (160 × 90 H.264 with a tone), written once into this suite's scratch folder.
    static func source() async throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-preview-stage", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let count: Int = 24_000 * 8
        let pcm: [Float] = (0..<count).map { index in
            let phase: Double = Double(index) * 0.05
            return Float(sin(phase) * 0.2)
        }
        return try await DebugRewriteSmoke.sourceMovie(pcm, rate: 24_000, seconds: 8, root: root)
    }

    /// The interview fixture on `source`, scoped to one clip.
    static func project(source: URL) async throws -> Project {
        let shared = try SharedResources.locate()
        var project = try JSONProjectStore.decode(Data(contentsOf: shared.root.appendingPathComponent("fixtures/projects/interview-take.voxclip")))
        project.id = UUID().uuidString.lowercased()
        project = try ContextDemoProject.upgradeToV4(project)
        let probe = try await AVMediaProbe().probe(source)
        project.media.source.absolutePath = source.path
        project.media.source.durationSeconds = probe.durationSeconds
        project.media.source.video = probe.video
        project.media.source.audio = probe.audio
        project.captions.styleId = "vox-highlight"
        project.edits = ProjectEdits(clips: [ClipRange(id: "scope", startWordId: "w3", endWordId: "w9", origin: .ai)])
        project.edits.activeClipId = "scope"
        return project
    }

    /// What Make it postable leaves on a clip (design.md §6.6, §6.7, §6.9): Claude's caption pick, the hook as a title card,
    /// 1.1× speed, a zoom and the run's shape.
    static func postable(_ base: Project, style: String, shape: AspectRatio) throws -> Project {
        var project = base
        project.clipStyle = ClipStyle(preset: .auto, captions: .auto, music: .auto, maxLengthSec: 60, shapes: [.landscape, .portrait],
            rewording: .fixOnly, captionPicks: ["scope": ClipCaptionPick(styleId: style, reason: "Fast and direct.")])
        project = try ClipControlsProject.settingSpeed(1.1, clipId: "scope", in: project)
        project.export.aspect = shape
        project.motionCues = [MotionCue(id: "motion", clipID: "scope", sourceStart: 2.5, sourceEnd: 3.2,
            keyframes: [MotionKeyframe(progress: 0), MotionKeyframe(progress: 1, scale: 1.12)])]
        let card = try #require(ClipHookTitle.effect(hook: "My first sale was a scammer", clipID: "scope", in: project))
        return try ClipEffects.adding([card], to: project)
    }

    static func editor(_ project: Project, preview: any PreviewEngine, app: AppModel = AppModel(settingsStore: RegressionSettingsStore())) async throws -> EditorModel {
        _ = NSApplication.shared
        let shell = WorkspaceShell(app: app)
        await shell.attachForTesting(VoxClipDocument(project: project), selection: .clip("scope"), preview: preview, exporter: RegressionExporter())
        let model = try #require(shell.editor)
        // The fixture's content key isn't the synthetic clip's, so opening reports it as moved; the clip is the one meant.
        model.mediaResolved = true; model.mediaUnreadable = false; model.previewError = nil; model.refresh()
        return model
    }

    /// The viewer laid out offscreen at 404 wide, and the layout marker `name` in it.
    static func marker(_ name: String, model: EditorModel) -> ColumnLayoutMarker? {
        let host = NSHostingView(rootView: ViewerSection(model: model, columnWidth: 404))
        host.frame = CGRect(x: 0, y: 0, width: 404, height: 227)
        host.layoutSubtreeIfNeeded()
        return DebugShell.markerView(name, in: host)
    }

    /// The mean of the frame's colour channels at `seconds` of edited time, read through the player's video output.
    static func meanLuma(_ controller: PreviewPlayerController, at seconds: Double) async throws -> Double {
        let item = try #require(controller.player.currentItem)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        item.add(output)
        defer { item.remove(output) }
        for _ in 0..<100 where item.status != .readyToPlay && item.status != .failed { try await Task.sleep(for: .milliseconds(50)) }
        try await controller.seek(to: seconds, exact: true)
        controller.play()
        var buffer: CVPixelBuffer?
        for _ in 0..<60 {
            try await Task.sleep(for: .milliseconds(50))
            let time = output.itemTime(forHostTime: CACurrentMediaTime())
            if output.hasNewPixelBuffer(forItemTime: time), let copied = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
                buffer = copied; break
            }
        }
        controller.pause()
        guard let buffer else { return -1 }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer), row = CVPixelBufferGetBytesPerRow(buffer)
        let base = try #require(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        var sum = 0.0
        for y in stride(from: 0, to: height, by: 4) {
            for x in stride(from: 0, to: width, by: 4) {
                let pixel = base + y * row + x * 4
                sum += Double(pixel[0]) + Double(pixel[1]) + Double(pixel[2])
            }
        }
        let samples = Double((height / 4) * (width / 4) * 3)
        return sum / samples
    }

    @Test(.timeLimit(.minutes(2)))
    func aPreviewErrorShowsOnTheStageWithReloadPreview() async throws {
        let controller = PreviewPlayerController()
        let model = try await Self.editor(Self.project(source: Self.source()), preview: controller)
        defer { model.close() }
        #expect(model.stageShowsPlayer && model.stagePreviewError == nil)
        #expect(Self.marker("viewer.previewError", model: model) == nil)
        model.previewError = "The preview couldn't draw the video."
        #expect(model.stagePreviewError == "The preview couldn't draw the video.")
        #expect(Self.marker("viewer.previewError", model: model)?.text == "The preview couldn't draw the video.")
        #expect(Self.marker("viewer.reloadPreview", model: model) != nil)
        // A stand-in carries its own state; the message stays in the transcript's notice there (§5.4.4 c, f).
        model.mediaUnreadable = true
        #expect(model.stagePreviewError == nil && Self.marker("viewer.previewError", model: model) == nil)
    }

    @Test(.timeLimit(.minutes(2)))
    func reloadPreviewLoadsAgainAndClearsTheMessage() async throws {
        let controller = PreviewPlayerController()
        let model = try await Self.editor(Self.project(source: Self.source()), preview: controller)
        defer { model.close() }
        // A failed load closes the player: the stage would be black.
        controller.close()
        model.previewError = "The preview couldn't draw the video."
        #expect(controller.player.currentItem == nil && model.stagePreviewError != nil)
        await model.reloadPreview()
        #expect(controller.player.currentItem != nil)
        #expect(model.previewError == nil && model.stagePreviewError == nil)
        #expect(try await Self.meanLuma(controller, at: 0.5) > 20)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [PreviewFailureReason.captionRaster, .captionLayout, .title, .disclosure, .sourceFrame])
    func aCompositorFailureSetsTheMessageAndLogsItsTag(reason: PreviewFailureReason) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-preview-log-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(settingsStore: RegressionSettingsStore(), locations: DataLocations(environment: ["VOXCLIP_DATA_DIR": root.path]))
        let engine = FailingEngine()
        let model = try await Self.editor(Self.project(source: Self.source()), preview: engine, app: app)
        defer { model.close() }
        engine.fail(reason)
        let expected = EditorModel.previewFailureMessage(reason)
        for _ in 0..<200 where model.previewError != expected { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.previewError == expected)
        #expect(model.announcements.contains(expected))
        let log = (try? String(contentsOf: app.locations.logs.appendingPathComponent("voxclip.log"), encoding: .utf8)) ?? ""
        #expect(log.contains("[error] preview: compositor reason=\(reason.rawValue)"))
        // The tag and the app's own line only: no file name, path or user text.
        #expect(!log.contains("interview") && !log.contains(".mov"))
    }

    @Test(.timeLimit(.minutes(1)))
    func everyReasonHasItsOwnLine() {
        let lines = PreviewFailureReason.allCases.map(EditorModel.previewFailureMessage)
        #expect(lines.allSatisfy { !$0.isEmpty })
        #expect(EditorModel.previewFailureMessage(.captionRaster).contains("plays without them"))
        #expect(EditorModel.previewFailureMessage(.disclosure).contains("stopped"))
    }

    /// The user's report (signed build 3f6a04a2): after Make it postable the viewer stayed black. The result's preview, built
    /// by the editor's own request path and applied in place as the run applies it, shows real frames in both shapes.
    @Test(.timeLimit(.minutes(4)), arguments: ["vox-highlight", "punch-in", "karaoke", "one-word"], [AspectRatio.landscape, .portrait])
    func aMakeItPostableResultPreviewsRealFrames(style: String, shape: AspectRatio) async throws {
        let controller = PreviewPlayerController()
        let base = try await Self.project(source: Self.source())
        let model = try await Self.editor(base, preview: controller)
        defer { model.close() }
        await model.updatePreview(load: true)
        controller.play()
        var next = try Self.postable(base, style: style, shape: shape)
        next.title = model.project.title
        model.replace(next, name: "Make it postable")
        await model.waitForPendingPreviewForAudit()
        let request = try await model.renderRequest()
        #expect(request.captionLayout != nil && request.speed == 1.1 && request.effects?.picture.count == 1 && request.motionCues.count == 1)
        for time in [0.4, 1.2, 2.0, 3.0] {
            let luma = try await Self.meanLuma(controller, at: time)
            #expect(luma > 20, "\(style) \(shape) t=\(time) luma=\(luma)")
        }
        #expect(model.previewError == nil)
    }
}

/// The display side of a black stage (design.md §5.4.4 g): a ready item whose layer shows no frame for four ticks in a
/// window is re-attached once per item; anything else resets the count.
@Suite struct PlayerDisplayWatchTests {
    final class Item {}
    @Test func aReadyItemWhoseLayerShowsNothingIsReattachedOncePerItem() {
        var watch = PlayerDisplayWatch()
        let first = Item(), second = Item()
        func tick(_ item: Item?, ready: Bool = true, layer: Bool = false, window: Bool = true) -> Bool {
            watch.tick(item: item, itemReady: ready, layerReady: layer, inWindow: window)
        }
        var answers: [Bool] = []
        for _ in 0..<4 { answers.append(tick(first)) }
        #expect(answers == [false, false, false, true])
        // Once per item: the same item never asks again.
        answers = []
        for _ in 0..<8 { answers.append(tick(first)) }
        #expect(!answers.contains(true))
        // A new item gets its own chance.
        answers = []
        for _ in 0..<4 { answers.append(tick(second)) }
        #expect(answers == [false, false, false, true])
        // The handled item is held weakly: once it is gone, a new item is never mistaken for it.
        var fresh = PlayerDisplayWatch()
        do {
            let gone = Item()
            for _ in 0..<4 { _ = fresh.tick(item: gone, itemReady: true, layerReady: false, inWindow: true) }
        }
        #expect(fresh.handled == nil)
    }

    @Test func aShownFrameAnItemNotReadyOrNoWindowResetsTheCount() {
        let item = Item()
        for reset in [(true, true, true), (false, false, true), (true, false, false)] {
            var watch = PlayerDisplayWatch()
            for _ in 0..<3 { _ = watch.tick(item: item, itemReady: true, layerReady: false, inWindow: true) }
            let atReset = watch.tick(item: item, itemReady: reset.0, layerReady: reset.1, inWindow: reset.2)
            #expect(!atReset)
            #expect(watch.stalledTicks == 0)
            let after = watch.tick(item: item, itemReady: true, layerReady: false, inWindow: true)
            #expect(!after)
        }
        var empty = PlayerDisplayWatch()
        var answers: [Bool] = []
        for _ in 0..<6 { answers.append(empty.tick(item: nil, itemReady: true, layerReady: false, inWindow: true)) }
        #expect(!answers.contains(true))
    }
}
#endif
