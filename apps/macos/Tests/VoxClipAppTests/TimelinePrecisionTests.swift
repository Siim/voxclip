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

/// A preview whose playback times the test reports. `whileSeeking` are times from playback before
/// the seek: one arrives as the seek starts and the rest just before it lands.
@MainActor private final class ReportingPreview: PreviewEngine {
    let events: AsyncStream<PreviewEvent>
    private let continuation: AsyncStream<PreviewEvent>.Continuation
    private(set) var isPlaying = false
    private(set) var editedTime = 0.0
    private(set) var pauses = 0
    var whileSeeking: [Double] = []
    var timeline: RenderTimeline?
    init() { (events, continuation) = AsyncStream.makeStream() }
    func load(_ request: RenderRequest) async throws {}
    func update(_ request: RenderRequest) async throws {}
    func seek(to editedTime: Double, exact: Bool) async throws {
        let stale = whileSeeking
        if let first = stale.first { report(first) }
        for _ in 0..<50 { await Task.yield() }
        for time in stale.dropFirst() { report(time) }
        self.editedTime = editedTime
        continuation.yield(.time(edited: editedTime, source: timeline?.sourceTime(editedTime) ?? editedTime))
    }
    /// Playback reached `source`.
    func report(_ source: Double) { continuation.yield(.time(edited: timeline?.mapTime(source) ?? source, source: source)) }
    func play() { isPlaying = true; continuation.yield(.playing(true)) }
    func pause() { pauses += 1; isPlaying = false; continuation.yield(.playing(false)) }
    func close() { continuation.finish() }
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

    // MARK: Range actions

    @Test func rangeActionsPlayTheRangeAndAddATitleTrimAnItemOrMakeAClipAsOrdinaryUndoSteps() async throws {
        let app = try app(), model = editor(app, project: try project()), undo = UndoManager()
        defer { model.close() }
        undo.groupsByEvent = false; model.undoManager = undo
        model.showsCuts = true
        let hint = EditorModel.timelineRangeHint
        #expect(model.timelinePlayRangeReason == hint && model.timelineAddTitleReason == hint)
        #expect(model.timelineTrimToRangeReason == hint && model.timelineMakeClipReason == hint)
        _ = model.setTimelineRange(from: 12.4, to: 17.06, on: .source)
        let out = 512.0 / 30
        // Play range plays from In and stops at Out.
        model.playTimelineRange(); await settle()
        #expect(model.previewStop == out && abs(model.sourceTime - 12.4) < 1e-6 && model.isPlaying)
        model.transport("k")
        // Cut range is shown but cuts nothing yet.
        #expect(!model.timelineCanCut)
        model.cutSelection()
        #expect(model.cutWordIDs == ["t14", "t15"] && model.undoSteps == 0)
        #expect(model.timelineAskClaudeReason != nil, "No AI is chosen in the test settings")
        // Add title over the range, one "Add title" step.
        undo.beginUndoGrouping(); model.addTimelineTitleOverRange(); undo.endUndoGrouping()
        let title = try #require(model.project.clipEffects.first)
        #expect(abs(title.start - 12.4) < 1e-6 && title.end == out && title.text == "Title" && undo.undoActionName == "Add title")
        // Trim item to range: a second title from the playhead, trimmed to 19–20 s in one "Trim to range" step.
        model.clearTimelineRange()
        model.sourceTime = 18.5
        undo.beginUndoGrouping(); try model.addTimelineTitle("Second"); undo.endUndoGrouping()
        let second = try #require(model.project.clipEffects.first { $0.text == "Second" })
        #expect(second.start == 18.5 && second.end == 20.5)
        _ = model.setTimelineRange(from: 19, to: 20, on: .source)
        #expect(model.timelineRangeTrimTarget?.id == .effect(second.id) && model.timelineTrimToRangeReason == nil)
        let steps = model.undoSteps
        undo.beginUndoGrouping(); model.trimTimelineItemToRange(); undo.endUndoGrouping()
        let trimmed = try #require(model.project.clipEffects.first { $0.id == second.id })
        #expect(abs(trimmed.start - 19) < 1e-3 && abs(trimmed.end - 20) < 1e-3, "\(trimmed.start)–\(trimmed.end)")
        #expect(model.undoSteps == steps + 1 && undo.undoActionName == "Trim to range")
        #expect(model.timelineTrimToRangeReason == "The title already fits inside the range.")
        undo.undo()
        #expect(model.project.clipEffects.first { $0.id == second.id }.map { ($0.start, $0.end) } ?? (0, 0) == (18.5, 20.5))
        // Make clip: In snaps to word 12's start and Out to word 16's end.
        _ = model.setTimelineRange(from: 12.4, to: 17.06, on: .source)
        #expect(model.timelineMakeClipReason == nil)
        undo.beginUndoGrouping(); model.makeClip(); undo.endUndoGrouping()
        let clip = try #require(model.activeClip)
        #expect(clip.startWordId == "t12" && clip.endWordId == "t16" && undo.undoActionName == "Make clip")
    }

    @Test func editMenuCutAndRestoreSelectionAreOffWhileARangeIsSet() async throws {
        let app = try app()
        await app.shell.attachForTesting(VoxClipDocument(project: try project(), demo: true), preview: DemoPreviewEngine())
        let controller = MainWindowController(shell: app.shell)
        defer { controller.window?.close(); app.shell.editor?.close() }
        let editor = try #require(app.shell.editor)
        editor.mediaResolved = true; editor.refresh()
        let delegate = AppDelegate(model: app)
        delegate.commandWindowForTesting = controller.window
        defer { delegate.commandWindowForTesting = nil }
        func enabled(_ tag: Int) -> Bool {
            let item = NSMenuItem(title: "", action: NSSelectorFromString("performEditorCommand:"), keyEquivalent: "")
            item.tag = tag
            return delegate.validateMenuItem(item)
        }
        // Words 14 (cut) to 16: Cut Selection and Restore Selection both apply.
        editor.select("t14"); editor.select("t16", extend: true)
        #expect(enabled(1) && enabled(2))
        _ = editor.setTimelineRange(from: 13.9, to: 16.9, on: .source)
        #expect(editor.timelineRange != nil && editor.selectedWordIDs.isSuperset(of: ["t14", "t16"]), "The words stay selected under the range")
        #expect(!enabled(1) && !enabled(2), "Like the edit bar's Cut range, the menu cuts nothing from a range")
        editor.clearTimelineRange()
        editor.select("t14"); editor.select("t16", extend: true)
        #expect(enabled(1) && enabled(2))
    }

    @Test func trimToRangeReadsASongAcrossACutWhereItShows() throws {
        var fixture = try project()
        let asset = MusicAsset(file: "\(fixture.id)/music-night.wav", sha256: String(repeating: "a", count: 64), durationSeconds: 46)
        // Six seconds of song from 12 s: words 14 and 15 are cut under it, so it runs on to about 20 s of the take.
        let segment = MusicSegment(id: "song", anchorSeconds: 12, lengthSeconds: 6, songFromSeconds: 0, loop: true, fadeInSeconds: 0, fadeOutSeconds: 0)
        fixture.music = [.init(id: "song", clipId: fixture.edits.activeClipId, asset: asset, source: .file, title: "Night Drive",
                               license: .own, gainDb: -30, fadeInSeconds: 0, fadeOutSeconds: 0, startOffsetSeconds: 0, segments: [segment])]
        let app = try app(), model = editor(app, project: fixture), undo = UndoManager()
        defer { model.close() }
        undo.groupsByEvent = false; model.undoManager = undo
        func shown() throws -> ClosedRange<Double> {
            let plan = try #require(model.itemEditPlan)
            let item = try #require(TimelineItems.layout(project: model.project, plan: plan, scope: model.itemEditScope, axis: .source).items
                .first { $0.id == .music("song") })
            return try #require(item.axisIntervals.map(\.start).min())...(try #require(item.axisIntervals.map(\.end).max()))
        }
        let before = try shown()
        #expect(abs(before.lowerBound - 12) < 1e-3 && before.upperBound > 19.5, "\(before)")
        _ = model.setTimelineRange(from: 11.5, to: 19, on: .source)
        let target = try #require(model.timelineRangeTrimTarget)
        #expect(target.id == .music("song") && abs(target.span.upperBound - before.upperBound) < 1e-6)
        #expect(model.timelineTrimToRangeReason == nil, "The song runs past Out")
        undo.beginUndoGrouping(); model.trimTimelineItemToRange(); undo.endUndoGrouping()
        let after = try shown()
        #expect(abs(after.lowerBound - 12) < 1e-3 && abs(after.upperBound - 19) < 1e-3, "\(after)")
        #expect(undo.undoActionName == "Trim to range" && model.timelineTrimToRangeReason == "The music already fits inside the range.")
    }

    @Test func playRangeStopsAtOutEvenFromPastItAndSpaceOrASeekEndsTheStop() async throws {
        let engine = ReportingPreview(), app = try app()
        let model = EditorModel(document: VoxClipDocument(project: try project(), demo: true), app: app, preview: engine)
        defer { model.close() }
        model.showsCuts = true
        await model.start()
        engine.timeline = try #require(model.renderTimeline)
        let out = 512.0 / 30
        // Playback is past Out when Play range is pressed; times from before the seek keep coming in during it and after it.
        engine.report(20); engine.play(); await settle()
        engine.whileSeeking = [20.5, 20.6]
        _ = model.setTimelineRange(from: 12.4, to: 17.06, on: .source)
        model.playTimelineRange(); await settle(); await settle()
        #expect(engine.pauses == 0 && model.previewStop == out && engine.isPlaying, "Old times past Out don't end the range")
        #expect(abs(model.sourceTime - 12.4) < 1e-6)
        engine.whileSeeking = []
        engine.report(16.9); await settle()
        #expect(engine.isPlaying)
        engine.report(17.1); await settle()
        #expect(engine.pauses == 1 && !engine.isPlaying && model.previewStop == nil, "Playback stops at Out")
        // Space pauses and ends the stop: after a click past Out, Space plays on.
        model.playTimelineRange(); await settle(); await settle()
        engine.report(13); await settle()
        model.transport(" "); await settle()
        #expect(!engine.isPlaying && model.previewStop == nil)
        model.seek(source: 20); await settle()
        model.transport(" "); engine.report(20.1); engine.report(20.2); await settle()
        #expect(engine.isPlaying, "No stop left from the range")
        model.transport(" ")
        // From before In, Space plays on past the old Out.
        model.playTimelineRange(); await settle(); await settle()
        model.transport(" "); model.seek(source: 10); await settle()
        model.transport(" "); engine.report(10.5); engine.report(17.2); await settle()
        #expect(engine.isPlaying)
        // A seek while the range plays ends the stop too.
        model.playTimelineRange(); await settle(); await settle()
        model.seek(source: 14); engine.report(14.1); engine.report(17.3); await settle()
        #expect(engine.isPlaying && model.previewStop == nil)
    }

    @Test(arguments: [CGFloat(700), 1280]) func everyRangeActionShowsInTheEditBar(_ width: CGFloat) throws {
        let app = try app(), model = editor(app, project: try project()), shell = WorkspaceShell(app: app)
        defer { model.close() }
        _ = model.setTimelineRange(from: 12.4, to: 17.06, on: .source)
        let size = NSSize(width: width, height: 210)
        let host = ShellHost.controller(TimelinePanel(model: model, shell: shell), app: app)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentViewController = host
        defer { window.close() }
        host.view.frame = CGRect(origin: .zero, size: size); host.view.layoutSubtreeIfNeeded()
        let rects = DebugRightColumn.markers(in: host.view)
        for marker in ["timeline.cutSelection", "timeline.playRange", "timeline.askClaude", "timeline.addTitle", "timeline.trimToRange", "timeline.makeClip"] {
            let rect = try #require(rects[marker], "\(marker) at \(width) pt")
            #expect(rect.width > 5 && rect.minX >= 0 && rect.maxX <= width, "\(marker): \(rect)")
        }
    }

    // MARK: Word ticks

    @Test func a1TicksWordEdgesFromAHundredPointsPerSecond() throws {
        let app = try app(), model = editor(app, project: try project())
        defer { model.close() }
        model.showsCuts = true
        let (canvas, window) = windowed(model)
        defer { canvas.tearDown(); window.close() }
        canvas.renderContent()
        canvas.auditViewport(.init(axis: .source, ptPerSecond: 99, origin: 12.5, width: canvas.viewport.width))
        canvas.audio.layer?.displayIfNeeded()
        #expect(canvas.audio.state.wordStarts.isEmpty && canvas.audio.drawn.wordTicks == 0)
        canvas.auditViewport(.init(axis: .source, ptPerSecond: 120, origin: 12.5, width: canvas.viewport.width))
        canvas.audio.layer?.displayIfNeeded()
        let starts = canvas.audio.state.wordStarts, ends = canvas.audio.state.wordEnds
        #expect(starts.first == 13 && starts.contains(14) && ends.first.map { abs($0 - 12.8) < 1e-9 } == true, "Source ticks cut words too")
        #expect(canvas.audio.drawn.wordTicks == starts.count + ends.count && starts.count >= 7)
        let bitmap = try DebugTimeline.sRGBBitmap(of: canvas.audio)
        let scale = CGFloat(bitmap.pixelsWide) / canvas.audio.bounds.width
        let tick = try DebugTimeline.swatch("timeline.tick", over: "timeline.audioPiece")
        func shows(_ time: Double, _ y: CGFloat) -> Bool {
            let pixel = DebugTimeline.pixel(bitmap, x: Int((canvas.headerWidth + canvas.viewport.x(time) + 0.5) * scale), y: Int(y * scale))
            return pixel.count == 3 && zip(pixel, tick).allSatisfy { abs($0 - $1) < 3.0 / 255 }
        }
        #expect(shows(13, TimelineAudioLane.pieceInset + 2), "A start hangs from the top")
        #expect(!shows(13, canvas.audio.bounds.height - TimelineAudioLane.pieceInset - 2))
        model.showsCuts = false; canvas.renderContent()
        canvas.auditViewport(.init(axis: .edited, ptPerSecond: 120, origin: 2, width: canvas.viewport.width))
        let edited = canvas.audio.state.wordStarts
        let folded = model.timelineTime(source: 14, on: .edited), next = model.timelineTime(source: 16, on: .edited)
        #expect(edited.contains(next) && !edited.contains { abs($0 - folded) < 1e-9 }, "Edited ticks only the words that play")
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
