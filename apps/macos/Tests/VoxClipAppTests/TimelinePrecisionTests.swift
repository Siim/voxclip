#if DEBUG
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import VoxClipCore
@testable import VoxClip

/// Settings for an editor in a temporary data folder: nothing loads or saves.
private actor PrecisionTestSettings: SettingsStore {
    func load() async throws -> SettingsDocument { SettingsDocument(values: ["update.autoCheck": .bool(false)]) }
    func save(_ settings: SettingsDocument) async throws {}
    func flush() async throws {}
}

/// Exact timeline positions and ranges (issue #41, step 1): frame and word-boundary steps of the
/// playhead, ruler scrubbing, the exact range with Snapping off, I and O on the timeline, the
/// edit bar's range actions and A1's word ticks. No window is shown; each test has its own data folder.
@Suite("Timeline precision", .serialized, .offlineFixtures)
@MainActor struct TimelinePrecisionTests {
    // MARK: Frame and word-boundary steps

    @Test(arguments: [TimelineAxis.edited, .source]) func commaAndPeriodStepThePlayheadOneFrameWithNothingSelected(_ axis: TimelineAxis) async throws {
        let app = try app(), model = editor(app, project: try project())
        defer { model.close() }
        model.showsCuts = axis == .source
        let (canvas, window) = windowed(model)
        defer { canvas.tearDown(); window.close() }
        canvas.renderContent()
        let start = axis == .source ? 12.0 : 2.0
        model.seekTimeline(start, on: axis); await settle()
        canvas.keyDown(with: try key(47, "."))
        await settle()
        #expect(abs(model.timelinePlayhead(on: axis) - (start + 1.0 / 30)) < 1e-6, "One frame of the 30 fps take later")
        canvas.keyDown(with: try key(43, ",")); await settle()
        canvas.keyDown(with: try key(43, ",")); await settle()
        #expect(abs(model.timelinePlayhead(on: axis) - (start - 1.0 / 30)) < 1e-6, "Two frames earlier")
        #expect(model.selectedWordIDs.isEmpty && model.timelineItemSelection.isEmpty)
        #expect(model.undoSteps == 0 && !model.document.isDocumentEdited)
    }

    @Test func shiftCommaAndPeriodJumpToWordBoundariesAndSkipFoldedWordsOnEdited() async throws {
        let app = try app(), model = editor(app, project: try project())
        defer { model.close() }
        model.showsCuts = true
        let (canvas, window) = windowed(model)
        defer { canvas.tearDown(); window.close() }
        canvas.renderContent()
        model.seekTimeline(12.5, on: .source); await settle()
        canvas.keyDown(with: try key(47, ".", shift: true)); await settle()
        #expect(abs(model.sourceTime - 12.8) < 1e-6, "The end of the word under the playhead")
        canvas.keyDown(with: try key(47, ".", shift: true)); await settle()
        #expect(abs(model.sourceTime - 13) < 1e-6, "The next word's start")
        canvas.keyDown(with: try key(43, ",", shift: true)); await settle()
        #expect(abs(model.sourceTime - 12.8) < 1e-6)
        model.showsCuts = false; canvas.renderContent()
        model.seekTimeline(model.timelineTime(source: 13, on: .edited), on: .edited); await settle()
        canvas.keyDown(with: try key(47, ".", shift: true)); await settle()
        canvas.keyDown(with: try key(47, ".", shift: true)); await settle()
        #expect(abs(model.timelinePlayhead(on: .edited) - model.timelineTime(source: 16, on: .edited)) < 1e-6,
                "Edited skips the two folded words: 13.8, then word 16's start")
        #expect(model.undoSteps == 0)
    }

    @Test func withAnItemSelectedCommaAndPeriodStillNudgeTheItem() async throws {
        let app = try app(), model = editor(app, project: try project())
        defer { model.close() }
        model.sourceTime = 18.5
        try model.addTimelineTitle("Title")
        let title = try #require(model.project.clipEffects.first)
        let (canvas, window) = windowed(model)
        defer { canvas.tearDown(); window.close() }
        canvas.renderContent()
        model.seekTimeline(12, on: .source); await settle()
        let playhead = model.timelinePlayhead(on: model.timelineAxis)
        model.selectTimelineItems([.effect(title.id)])
        canvas.keyDown(with: try key(47, ".")); await settle()
        let moved = try #require(model.project.clipEffects.first)
        #expect(abs(moved.start - (title.start + 1.0 / 30)) < 1e-3)
        #expect(model.timelinePlayhead(on: model.timelineAxis) == playhead)
    }

    // MARK: Ruler

    @Test(arguments: [TimelineAxis.edited, .source]) func aRulerDragScrubsThePlayheadAndSelectsNothing(_ axis: TimelineAxis) async throws {
        let app = try app(), model = editor(app, project: try project())
        defer { model.close() }
        model.showsCuts = axis == .source
        let (canvas, window) = windowed(model)
        defer { canvas.tearDown(); window.close() }
        canvas.renderContent()
        model.selectedWordIDs = ["t20", "t21"]
        let y = TimelineMetrics.ruler.y + 12
        func p(_ source: Double) -> NSPoint { NSPoint(x: canvas.headerWidth + canvas.viewport.x(model.timelineTime(source: source, on: axis)), y: y) }
        canvas.mouseDown(with: try mouse(.leftMouseDown, p(12.4), in: canvas)); await settle()
        #expect(abs(model.sourceTime - 12.4) < 1e-3)
        canvas.mouseDragged(with: try mouse(.leftMouseDragged, p(17.3), in: canvas)); await settle()
        #expect(abs(model.sourceTime - 17.3) < 1e-3, "The playhead follows the pointer, not a word edge")
        canvas.mouseUp(with: try mouse(.leftMouseUp, p(17.3), in: canvas)); await settle()
        #expect(model.selectedWordIDs == ["t20", "t21"] && model.askClaude.timeRange == nil, "A scrub keeps the selection it found")
        #expect(model.undoSteps == 0 && !model.document.isDocumentEdited)
    }

    @Test func theRulerDrawsHalfSecondTicksBetweenTheSeconds() throws {
        let app = try app(), model = editor(app, project: try project())
        defer { model.close() }
        model.showsCuts = true
        let (canvas, window) = windowed(model)
        defer { canvas.tearDown(); window.close() }
        canvas.renderContent()
        canvas.auditViewport(.init(axis: .source, ptPerSecond: 20, origin: 10, width: canvas.viewport.width))
        canvas.ruler.layer?.displayIfNeeded()
        let bitmap = try DebugTimeline.sRGBBitmap(of: canvas.ruler)
        let scale = CGFloat(bitmap.pixelsWide) / canvas.ruler.bounds.width
        func pixel(_ time: Double, _ y: CGFloat) -> [Double] {
            DebugTimeline.pixel(bitmap, x: Int((canvas.headerWidth + canvas.viewport.x(time) + 0.5) * scale), y: Int(y * scale))
        }
        let tick = try DebugTimeline.swatch("timeline.tick", over: "bg.window"), ground = try DebugTimeline.swatch("bg.window")
        func near(_ a: [Double], _ b: [Double]) -> Bool { a.count == 3 && zip(a, b).allSatisfy { abs($0 - $1) < 3.0 / 255 } }
        #expect(near(pixel(12.5, 20.5), tick), "A 3 pt tick at 12.5 s")
        #expect(near(pixel(12.5, 17.5), ground), "Half as tall as the 6 pt second ticks")
        #expect(near(pixel(13, 17.5), tick))
    }

    // MARK: Helpers

    private func settle() async { for _ in 0..<100 { await Task.yield() } }

    private func app() throws -> AppModel {
        let parent = ProcessInfo.processInfo.environment["VOXCLIP_DATA_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory
        let root = parent.appendingPathComponent("voxclip-precision-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Cache"), withIntermediateDirectories: true)
        return AppModel(settingsStore: PrecisionTestSettings(), locations: DataLocations(environment: ["VOXCLIP_DATA_DIR": root.path]))
    }

    /// A 60-second, 30 fps take of 0.8-second words a second apart, with Clip 1 on words 10–29
    /// and words 14 and 15 cut.
    private func project() throws -> Project {
        let shared = try SharedResources.locate()
        var project = try JSONProjectStore.decode(Data(contentsOf: shared.root.appendingPathComponent("fixtures/projects/interview-take.voxclip")))
        project.media.source.durationSeconds = 60
        project.transcript?.durationSeconds = 60
        project.transcript?.words = (0..<60).map { index in
            let start = Double(index)
            return TimedWord(id: "t\(index)", text: index % 10 == 9 ? "word." : "word", start: start, end: start + 0.8)
        }
        let clip = ClipRange(id: "clip-1", startWordId: "t10", endWordId: "t29")
        project.edits = ProjectEdits(cutWordIds: ["t14", "t15"], clips: [clip], activeClipId: clip.id)
        return project
    }

    private func editor(_ app: AppModel, project: Project) -> EditorModel {
        EditorModel(document: VoxClipDocument(project: project, demo: true), app: app, preview: DemoPreviewEngine())
    }

    /// The lanes as the panel sizes them, in a dark window that is never shown.
    private func windowed(_ model: EditorModel) -> (canvas: TimelineCanvasView, window: NSWindow) {
        let canvas = TimelineCanvasView(model: model)
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 1056, height: TimelineMetrics.height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = canvas
        return (canvas, window)
    }

    private func key(_ code: UInt16, _ characters: String = "", shift: Bool = false, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: shift ? flags.union(.shift) : flags, timestamp: 0,
                                      windowNumber: 0, context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                      isARepeat: false, keyCode: code))
    }

    /// A left-button event at `point` in the canvas (top-left origin).
    private func mouse(_ type: NSEvent.EventType, _ point: NSPoint, in canvas: NSView, clicks: Int = 1, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: flags, timestamp: 0,
                                        windowNumber: canvas.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1))
    }
}
#endif
