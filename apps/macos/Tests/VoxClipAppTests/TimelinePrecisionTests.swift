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

    // MARK: Exact range

    @Test(arguments: [TimelineAxis.edited, .source]) func snappingOffKeepsAFrameRoundedRangeAndSelectsTheWordsWhollyInside(_ axis: TimelineAxis) throws {
        let app = try app(), model = editor(app, project: try project())
        defer { model.close() }
        model.showsCuts = axis == .source
        model.timelineSnapping = false
        let (canvas, window) = windowed(model)
        defer { canvas.tearDown(); window.close() }
        canvas.renderContent()
        let y = TimelineMetrics.audio.y + 12
        func p(_ source: Double) -> NSPoint { NSPoint(x: canvas.headerWidth + canvas.viewport.x(model.timelineTime(source: source, on: axis)), y: y) }
        canvas.mouseDown(with: try mouse(.leftMouseDown, p(17.06), in: canvas))
        canvas.mouseDragged(with: try mouse(.leftMouseDragged, p(12.84), in: canvas))
        canvas.mouseUp(with: try mouse(.leftMouseUp, p(12.84), in: canvas))
        let range = try #require(model.timelineRange)
        // 12.84 s and 17.06 s fall on frames 385.2 and 511.8 of 30 fps: the nearest frames are 385 and 512.
        #expect(range.recording == nil)
        #expect(abs(range.start * 30 - 385) < 0.01 && abs(range.end * 30 - 512) < 0.01, "\(range)")
        #expect(model.selectedWordIDs == Set((13...16).map { "t\($0)" }), "Word 17 ends at 17.8, outside the range")
        let shown = try #require(canvas.content.selection)
        #expect(abs(shown.lowerBound - model.timelineTime(source: 385.0 / 30, on: axis)) < 1e-6)
        #expect(abs(shown.upperBound - model.timelineTime(source: 512.0 / 30, on: axis)) < 1e-6, "The band is the range, not the words")
        #expect(canvas.ruler.state.selection == shown)
        let wash = canvas.overlay.wash.frame
        #expect(!canvas.overlay.wash.isHidden && abs(wash.minX - canvas.viewport.x(shown.lowerBound)) < 0.001)
        #expect(model.timelineRangeReadout == "4.23\u{00A0}s · 0:12.83\u{2013}0:17.07")
        #expect(model.askClaude.timeRange == 385.0 / 30...512.0 / 30)
        #expect(!model.timelineCanCut && model.undoSteps == 0 && !model.document.isDocumentEdited)
    }

    @Test func optionDragKeepsARangeWithSnappingOnAndAPlainDragStillSelectsWords() throws {
        let app = try app(), model = editor(app, project: try project())
        defer { model.close() }
        model.showsCuts = true
        let (canvas, window) = windowed(model)
        defer { canvas.tearDown(); window.close() }
        canvas.renderContent()
        let y = TimelineMetrics.audio.y + 12
        func p(_ source: Double) -> NSPoint { NSPoint(x: canvas.headerWidth + canvas.viewport.x(source), y: y) }
        canvas.mouseDown(with: try mouse(.leftMouseDown, p(20.3), in: canvas, flags: .option))
        canvas.mouseDragged(with: try mouse(.leftMouseDragged, p(20.9), in: canvas, flags: .option))
        canvas.mouseUp(with: try mouse(.leftMouseUp, p(20.9), in: canvas, flags: .option))
        let range = try #require(model.timelineRange)
        #expect(abs(range.start - 0.3 - 20) < 1e-6 && abs(range.end - 20.9) < 1e-6)
        #expect(model.selectedWordIDs.isEmpty, "No word is wholly inside a breath-sized range")
        // A plain drag snaps to words and drops the range.
        canvas.mouseDown(with: try mouse(.leftMouseDown, p(12.1), in: canvas))
        #expect(model.timelineRange == nil)
        canvas.mouseDragged(with: try mouse(.leftMouseDragged, p(13.7), in: canvas))
        canvas.mouseUp(with: try mouse(.leftMouseUp, p(13.7), in: canvas))
        #expect(model.timelineRange == nil && model.selectedWordIDs == ["t12", "t13"])
    }

    @Test func rangesWordsAndItemsReplaceEachOtherAndEscapeClearsTheRange() async throws {
        let app = try app(), model = editor(app, project: try project())
        defer { model.close() }
        model.showsCuts = true
        model.sourceTime = 25
        try model.addTimelineTitle("Title")
        let title = try #require(model.project.clipEffects.first)
        let (canvas, window) = windowed(model)
        defer { canvas.tearDown(); window.close() }
        canvas.renderContent()
        _ = model.setTimelineRange(from: 11.5, to: 13.9, on: .source)
        #expect(model.timelineRange != nil && model.selectedWordIDs == ["t12", "t13"])
        model.selectTimelineItems([.effect(title.id)])
        #expect(model.timelineRange == nil && model.selectedWordIDs.isEmpty, "An item selection replaces the range")
        _ = model.setTimelineRange(from: 11.5, to: 13.9, on: .source)
        #expect(model.timelineItemSelection.isEmpty, "A range replaces the item selection")
        model.selectedWordIDs = ["t20"]
        #expect(model.timelineRange == nil, "A word selection replaces the range")
        _ = model.setTimelineRange(from: 11.5, to: 13.9, on: .source)
        #expect(canvas.interaction.key(53, shift: false))
        #expect(model.timelineRange == nil && model.selectedWordIDs.isEmpty && model.askClaude.timeRange == nil)
        #expect(!canvas.interaction.key(53, shift: false), "Esc with nothing left passes on")
        #expect(model.undoSteps == 1, "Only the title is an undo step")
    }

    @Test func shiftClickExtendsByFrameWithSnappingOffAndByWordWithItOn() throws {
        let app = try app(), model = editor(app, project: try project())
        defer { model.close() }
        model.showsCuts = true
        let (canvas, window) = windowed(model)
        defer { canvas.tearDown(); window.close() }
        canvas.renderContent()
        let y = TimelineMetrics.audio.y + 12
        func p(_ source: Double) -> NSPoint { NSPoint(x: canvas.headerWidth + canvas.viewport.x(source), y: y) }
        model.timelineSnapping = false
        _ = model.setTimelineRange(from: 12.4, to: 13.5, on: .source)
        canvas.mouseDown(with: try mouse(.leftMouseDown, p(16.42), in: canvas, flags: .shift))
        canvas.mouseUp(with: try mouse(.leftMouseUp, p(16.42), in: canvas, flags: .shift))
        let range = try #require(model.timelineRange)
        #expect(abs(range.start - 12.4) < 1e-6 && abs(range.end * 30 - 493) < 0.01, "\(range)")
        #expect(model.selectedWordIDs == ["t13", "t14", "t15"])
        model.timelineSnapping = true
        canvas.mouseDown(with: try mouse(.leftMouseDown, p(18.7), in: canvas, flags: .shift))
        canvas.mouseUp(with: try mouse(.leftMouseUp, p(18.7), in: canvas, flags: .shift))
        #expect(model.timelineRange == nil)
        #expect(model.selectedWordIDs == Set((12...18).map { "t\($0)" }), "Word grain: In snaps to word 12's start, Out to word 18's end")
        #expect(model.undoSteps == 0)
    }

    @Test func severalRecordingsKeepTheRangeInTheRecordingItBeganIn() throws {
        let shared = try SharedResources.locate()
        var project = try JSONProjectStore.decode(Data(contentsOf: shared.root.appendingPathComponent("fixtures/recordings/two-recordings.voxclip")))
        project.edits.clips = []; project.edits.activeClipId = nil
        let app = try app(), model = editor(app, project: project)
        defer { model.close() }
        model.showsCuts = true
        model.timelineSnapping = false
        let clock = try #require(model.recordingClock)
        let second = try #require(clock.regions.last)
        let offset = Double(second.offsetSamples) / Double(clock.sampleRate)
        _ = model.setTimelineRange(from: offset + 0.2, to: offset - 2, on: .source)
        let range = try #require(model.timelineRange)
        #expect(range.recording == second.key && range.start == 0 && abs(range.end - 0.2) < 1e-6, "\(range)")
        let source = try #require(model.timelineRangeSource)
        #expect(abs(source.lowerBound - offset) < 1e-6 && abs(source.upperBound - offset - 0.2) < 1e-6)
    }

    // MARK: I and O

    @Test func iAndOOnTheTimelineSetTheRangeAtThePlayheadAndTheTranscriptKeepsClipEdges() async throws {
        let app = try app(), model = editor(app, project: try project())
        defer { model.close() }
        model.showsCuts = true
        let (canvas, window) = windowed(model)
        defer { canvas.tearDown(); window.close() }
        canvas.renderContent()
        let clip = try #require(model.activeClip)
        model.seekTimeline(12.34, on: .source); await settle()
        canvas.keyDown(with: try key(34, "i")); await settle()
        var range = try #require(model.timelineRange)
        let scopeEnd = try #require(model.scopeSourceRange).upperBound
        #expect(abs(range.start * 30 - 370) < 0.01 && abs(range.end * 30 - (scopeEnd * 30).rounded()) < 0.01, "Out defaults to the scope's end: \(range)")
        model.seekTimeline(15.5, on: .source); await settle()
        canvas.keyDown(with: try key(31, "o")); await settle()
        range = try #require(model.timelineRange)
        #expect(abs(range.end - 15.5) < 1e-6 && abs(range.start * 30 - 370) < 0.01)
        #expect(model.activeClip == clip && model.undoSteps == 0, "The clip's edges stay where they were")
        // In the transcript I still sets the clip's start at the caret.
        model.selectedWordIDs = ["t12"]
        #expect(model.timelineRange == nil)
        model.transport("i")
        #expect(model.activeClip?.startWordId == "t12")
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
