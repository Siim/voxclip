#if DEBUG
import AppKit
import Foundation
import Testing
@testable import VoxClipCore
@testable import VoxClip

/// Settings for an editor in a temporary data folder: nothing loads or saves.
private actor TimelineTestSettings: SettingsStore {
    func load() async throws -> SettingsDocument { SettingsDocument(values: ["update.autoCheck": .bool(false)]) }
    func save(_ settings: SettingsDocument) async throws {}
    func flush() async throws {}
}

/// The v2 timeline's app side (impl-plan V7a): the viewport, the lanes following the model
/// without redrawing on a playhead tick, Show cuts as a view setting and the model-owned
/// waveform. No window is shown; each test has its own data folder.
@Suite("v2 timeline", .serialized)
@MainActor struct TimelineCanvasTests {
    private func app() throws -> AppModel {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-timeline-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Cache"), withIntermediateDirectories: true)
        return AppModel(settingsStore: TimelineTestSettings(), locations: DataLocations(environment: ["VOXCLIP_DATA_DIR": root.path]))
    }

    /// A 60-second take of one-second words with Clip 1 on words 10–29, words 14 and 15 cut.
    private func project() throws -> Project {
        let shared = try SharedResources.locate()
        var project = try JSONProjectStore.decode(Data(contentsOf: shared.root.appendingPathComponent("fixtures/projects/interview-take.voxclip")))
        project.media.source.durationSeconds = 60
        project.transcript?.durationSeconds = 60
        project.transcript?.words = (0..<60).map { TimedWord(id: "t\($0)", text: $0 % 10 == 9 ? "word." : "word", start: Double($0), end: Double($0) + 0.8) }
        let clip = ClipRange(id: "clip-1", startWordId: "t10", endWordId: "t29")
        project.edits = ProjectEdits(cutWordIds: ["t14", "t15"], clips: [clip], activeClipId: clip.id)
        return project
    }

    private func editor(_ app: AppModel, project: Project, demo: Bool = true) -> EditorModel {
        EditorModel(document: VoxClipDocument(project: project, demo: demo), app: app, preview: DemoPreviewEngine())
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

    /// A left-button event at `point` in the canvas (top-left origin).
    private func mouse(_ type: NSEvent.EventType, _ point: NSPoint, in canvas: NSView, clicks: Int = 1) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                                        windowNumber: canvas.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1))
    }

    /// A horizontal trackpad swipe of `points`.
    private func swipe(_ points: Int32) throws -> NSEvent {
        let event = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: points, wheel3: 0))
        return try #require(NSEvent(cgEvent: event))
    }

    /// The canvas read back in sRGB, and `token` at `alpha` over `ground` read back the same way.
    @MainActor private struct Pixels {
        let bitmap: NSBitmapImageRep
        let scale: CGFloat
        init(_ view: NSView) throws {
            bitmap = try DebugTimeline.sRGBBitmap(of: view)
            scale = CGFloat(bitmap.pixelsWide) / view.bounds.width
        }
        func at(_ x: CGFloat, _ y: CGFloat) -> [Double] { DebugTimeline.pixel(bitmap, x: Int(x * scale), y: Int(y * scale)) }
        // Expected colours go through the same drawing and read-back, so colour management treats both alike.
        func shows(_ x: CGFloat, _ y: CGFloat, _ token: String, alpha: CGFloat = 1, over ground: String? = nil) throws -> Bool {
            let actual = at(x, y), expected = try DebugTimeline.swatch(token, alpha: alpha, over: ground)
            return actual.count == 3 && zip(actual, expected).allSatisfy { abs($0 - $1) < 3.0 / 255 }
        }
    }

    // MARK: Viewport

    @Test func fittingKeepsASecondOfLaneEachSideAsInF1() {
        // f1: a 43.2 s clip in a 944 pt lane shows -1.0 s to 44.2 s over 936 pt.
        let viewport = TimelineViewport.fitting(0...43.2, width: 944, axis: .edited)
        #expect(abs(viewport.ptPerSecond - 936 / 45.2) < 1e-9)
        #expect(viewport.origin == -1)
        #expect(abs(viewport.x(44.2) - 936) < 1e-9)
        #expect(abs(viewport.time(atX: viewport.x(12.3)) - 12.3) < 1e-9)
        // Source keeps the zoom; only the axis and its start change (notes.md §6).
        let source = viewport.switched(to: .source, start: 221)
        #expect(source.ptPerSecond == viewport.ptPerSecond && source.origin == 220 && source.axis == .source)
    }

    @Test func playheadPagesAndPansStayInTheContent() {
        let viewport = TimelineViewport(axis: .edited, ptPerSecond: 10, origin: -1, width: 508)
        #expect(viewport.showing(20) == viewport)
        #expect(viewport.showing(55).origin == 54)
        #expect(viewport.showing(-5).origin == -6)
        #expect(viewport.panned(by: 100, within: 0...100).origin == 9)
        #expect(viewport.panned(by: 10_000, within: 0...100).origin == 51)
        #expect(viewport.panned(by: -10_000, within: 0...100).origin == -1)
    }

    // MARK: The canvas

    @Test func aPlayheadTickMovesOnlyThePlayheadLayers() throws {
        let app = try app()
        let model = editor(app, project: try project())
        defer { model.close() }
        let canvas = TimelineCanvasView(model: model)
        defer { canvas.tearDown() }
        canvas.frame = NSRect(x: 0, y: 0, width: 1056, height: TimelineMetrics.height)
        canvas.layoutSubtreeIfNeeded()
        canvas.renderContent()
        model.waveform = DebugTimeline.speech(words: model.words, duration: 60)
        canvas.renderContent()
        let lanes: [TimelineLane] = [canvas.overview, canvas.ruler, canvas.bed, canvas.audio]
        // Lanes draw through their layers (the 60-minute budget measures this way).
        lanes.forEach { $0.layer?.displayIfNeeded() }
        let draws = lanes.map(\.draws)
        #expect(draws.allSatisfy { $0 >= 1 })
        let invalidations = lanes.map(\.invalidations)
        let moves = canvas.overlay.playheadMoves
        for frame in 1...30 {
            model.playhead = Double(frame) * 0.5
            model.sourceTime = model.timelineSourceTime(model.playhead, on: .edited)
            canvas.followPlayhead()
        }
        #expect(lanes.map(\.invalidations) == invalidations)
        lanes.forEach { $0.layer?.displayIfNeeded() }
        #expect(lanes.map(\.draws) == draws)
        #expect(canvas.overlay.playheadMoves == moves + 30)
        // The playhead layer lives in the lanes' clip, right of the headers.
        let x = Double(canvas.overlay.playhead.transform.m41)
        #expect(abs(x - canvas.viewport.x(15)) < 1e-6)
        #expect(canvas.overlay.laneClip.masksToBounds && canvas.overlay.laneClip.frame.minX == TimelineMetrics.header)
        // Clip 1's overview label steps 5 pt past a playhead that would sit on it, as a layer move.
        let block = canvas.overview.x(try #require(model.timelineOverviewClips.first).source.lowerBound)
        #expect(canvas.overview.labels(playheadX: block + 20).first?.x == block + 4)
        #expect(canvas.overview.labels(playheadX: block + 6).first?.x == block + 11)
        // The selection is content: it redraws the ruler.
        model.selectedWordIDs = ["t20", "t21"]
        canvas.renderContent()
        #expect(canvas.ruler.invalidations > invalidations[1])
        #expect(canvas.content.selection == model.timelineSelection(on: .edited))
    }

    @Test func thePlayheadOffScreenPagesTheViewport() throws {
        let app = try app()
        let model = editor(app, project: try project())
        defer { model.close() }
        let canvas = TimelineCanvasView(model: model)
        defer { canvas.tearDown() }
        canvas.frame = NSRect(x: 0, y: 0, width: 1056, height: TimelineMetrics.height)
        canvas.layoutSubtreeIfNeeded()
        model.showsCuts = true
        canvas.renderContent()
        let before = canvas.viewport
        #expect(!before.visible.contains(45))
        let invalidations = canvas.ruler.invalidations
        model.sourceTime = 45
        model.playhead = model.timelineTime(source: 45, on: .edited)
        canvas.followPlayhead()
        #expect(canvas.viewport.origin == 44 && canvas.viewport.ptPerSecond == before.ptPerSecond)
        #expect(canvas.ruler.invalidations > invalidations)
    }

    @Test func showCutsOpensTakeTimeAtTheEditedZoomFromTheClip() throws {
        let app = try app()
        let model = editor(app, project: try project())
        defer { model.close() }
        let canvas = TimelineCanvasView(model: model)
        defer { canvas.tearDown() }
        canvas.frame = NSRect(x: 0, y: 0, width: 1056, height: TimelineMetrics.height)
        canvas.layoutSubtreeIfNeeded()
        canvas.renderContent()
        let edited = canvas.viewport
        #expect(edited.axis == .edited && edited.origin == -1)
        #expect(canvas.content.inOut == 0...model.duration)
        model.showsCuts = true
        canvas.renderContent()
        let scope = try #require(model.scopeSourceRange)
        #expect(canvas.viewport.axis == .source && canvas.viewport.ptPerSecond == edited.ptPerSecond && canvas.viewport.origin == scope.lowerBound - 1)
        #expect(canvas.content.inOut == scope)
        // Full Take has no In/Out and fits again.
        model.activate(nil)
        canvas.renderContent()
        #expect(canvas.content.inOut == nil && canvas.content.scope == nil)
        #expect(canvas.accessibilityChildren()?.count == 1)
    }

    @Test func showCutsIsAViewSettingOffByDefault() throws {
        let app = try app()
        let model = editor(app, project: try project())
        defer { model.close() }
        let undo = UndoManager()
        model.undoManager = undo
        #expect(!model.showsCuts && model.timelineAxis == .edited)
        let steps = model.undoSteps, edited = model.document.isDocumentEdited
        model.showsCuts = true
        #expect(model.timelineAxis == .source)
        #expect(model.undoSteps == steps && !undo.canUndo)
        #expect(model.document.isDocumentEdited == edited)
        // The playhead slider's value names the axis it shows (design §5.2).
        #expect(model.timelineAccessibilityValue.contains(" source, "))
        model.showsCuts = false
        #expect(model.timelineAccessibilityValue.contains(" after cuts, "))
    }

    @Test func editedTrimsMapAcrossAClosedCut() throws {
        let app = try app()
        let model = editor(app, project: try project())
        defer { model.close() }
        let clip = try #require(model.activeClip)
        // Words 14 and 15 are cut: Edited time after the seam lands on word 16.
        let inside = model.timelineTime(source: 16.4, on: .edited)
        #expect(abs(model.timelineSourceTime(inside, on: .edited) - 16.4) < 0.001)
        #expect(model.timelineTrimIndex(clip, start: false, time: inside + 0.1, on: .edited) == 16)
        #expect(model.timelineTime(source: 16.4, on: .source) == 16.4)
        #expect(model.timelineTrimIndex(clip, start: true, time: -5, on: .edited) == 10)
        #expect(model.timelineTrimIndex(clip, start: false, time: 9_999, on: .edited) == 29)
        // On Source a drag can widen the clip.
        #expect(model.timelineTrimIndex(clip, start: true, time: 3.1, on: .source) == 3)
    }

    /// While nothing has moved it, Edited stays fitted to the clip through cuts and
    /// restores, so Out never leaves the lane and no empty ruler trails it; an edge dropped
    /// on the timeline keeps the zoom it was dropped at; a pan that moves the view ends the fit.
    @Test func aFittedEditedViewFitsAgainWhenTheClipsLengthChanges() throws {
        let app = try app()
        let model = editor(app, project: try project())
        defer { model.close() }
        let (canvas, window) = windowed(model)
        defer { canvas.tearDown(); window.close() }
        canvas.renderContent()
        let lane = Double(canvas.bounds.width - TimelineMetrics.header)
        func fit() -> TimelineViewport { TimelineViewport.fitting(0...model.duration, width: lane, axis: .edited) }
        #expect(canvas.viewport == fit())
        // A swipe the fitted view has no room for moves nothing and keeps the fit.
        let push = try swipe(-40)
        #expect(push.scrollingDeltaX != 0)
        canvas.scrollWheel(with: push)
        #expect(canvas.viewport == fit())
        // Restore Cuts lengthens the clip by its two cut words: Out stays on the lane.
        let cut = model.duration
        model.apply(.restoreCuts, name: "Restore cuts")
        canvas.renderContent()
        #expect(model.duration > cut + 1.5)
        #expect(canvas.viewport == fit())
        #expect(canvas.viewport.x(try #require(canvas.content.inOut).upperBound) <= lane - Double(TimelineMetrics.trailing) + 1e-9)
        // A cut shortens it: the clip still ends at the lane's end.
        model.selectedWordIDs = ["t20", "t21", "t22"]
        model.cutSelection()
        canvas.renderContent()
        #expect(canvas.viewport == fit())
        // Out dragged 3 s in on the ruler lands under the pointer at the zoom it was dropped at.
        let zoom = canvas.viewport
        let outX = TimelineMetrics.header + CGFloat(zoom.x(model.duration)), y = TimelineMetrics.ruler.y + 11
        let drop = outX - CGFloat(3 * zoom.ptPerSecond)
        canvas.mouseDown(with: try mouse(.leftMouseDown, NSPoint(x: outX, y: y), in: canvas))
        canvas.mouseDragged(with: try mouse(.leftMouseDragged, NSPoint(x: drop, y: y), in: canvas))
        canvas.mouseUp(with: try mouse(.leftMouseUp, NSPoint(x: drop, y: y), in: canvas))
        // The model's observation takes the same change again.
        canvas.renderContent()
        #expect(model.activeClip?.endWordId == "t26")
        #expect(canvas.viewport == zoom)
        #expect(abs(TimelineMetrics.header + CGFloat(canvas.viewport.x(model.duration)) - drop) < CGFloat(zoom.ptPerSecond) / 2)
        // The next change fits again.
        model.selectedWordIDs = ["t12"]
        model.cutSelection()
        canvas.renderContent()
        #expect(canvas.viewport == fit())
        // A pan that moves the view (Source has the take to move through) ends the fit:
        // back on Edited a cut keeps that zoom.
        model.showsCuts = true
        canvas.renderContent()
        let source = canvas.viewport
        canvas.scrollWheel(with: try swipe(-200))
        #expect(canvas.viewport.origin != source.origin)
        model.showsCuts = false
        canvas.renderContent()
        let kept = canvas.viewport
        #expect(kept.axis == .edited && kept.ptPerSecond == source.ptPerSecond)
        model.selectedWordIDs = ["t11"]
        model.cutSelection()
        canvas.renderContent()
        #expect(canvas.viewport == kept)
    }

    /// notes.md §6: the headers are chrome over anything left of the lanes. A scrub dragged
    /// over them and a selection that starts before the view leave the playhead and the
    /// wash on the lanes alone, and letting go pages to the playhead.
    @Test func thePlayheadAndTheWashStayOffTheTrackHeaders() throws {
        let app = try app()
        let model = editor(app, project: try project())
        defer { model.close() }
        model.showsCuts = true
        model.sourceTime = 20.4
        model.playhead = model.timelineTime(source: 20.4, on: .edited)
        let (canvas, window) = windowed(model)
        defer { canvas.tearDown(); window.close() }
        canvas.renderContent()
        canvas.followPlayhead()
        let y = TimelineMetrics.tracks[1].y + 10
        canvas.mouseDown(with: try mouse(.leftMouseDown, NSPoint(x: TimelineMetrics.header + 300, y: y), in: canvas))
        canvas.mouseDragged(with: try mouse(.leftMouseDragged, NSPoint(x: 40, y: y), in: canvas))
        let early = canvas.viewport.time(atX: Double(40 - TimelineMetrics.header))
        #expect(early > 0 && early < canvas.viewport.origin)
        // The seek lands (the preview answers later); the view holds under the pointer.
        model.sourceTime = early
        model.playhead = model.timelineTime(source: early, on: .edited)
        canvas.followPlayhead()
        #expect(!canvas.viewport.visible.contains(early))
        // Words 5–12, from before the view, selected.
        model.selectedWordIDs = Set((5...12).map { "t\($0)" })
        canvas.renderContent()
        canvas.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        canvas.audio.layer?.displayIfNeeded()
        let pixels = try Pixels(canvas)
        #expect(try pixels.shows(40, y, "bg.window"))
        #expect(try pixels.shows(80, y, "bg.window"))
        // V1's bare lane under the wash (A1 draws the take's audio there).
        #expect(try pixels.shows(TimelineMetrics.header + 4, TimelineMetrics.tracks[0].y + 18, "tint.wash", over: "timeline.lane"))
        let zoom = canvas.viewport.ptPerSecond
        canvas.mouseUp(with: try mouse(.leftMouseUp, NSPoint(x: 40, y: y), in: canvas))
        #expect(canvas.viewport.visible.contains(early) && canvas.viewport.ptPerSecond == zoom)
        #expect(abs(Double(canvas.overlay.playhead.transform.m41) - canvas.viewport.x(early)) < 1e-6)
    }

    /// The default Edited view closes a cut to a seam: a double-click within reach of it
    /// restores everything cut there as one step, as one on the cut does in Source view.
    @Test func aDoubleClickOnAClosedCutsSeamRestoresIt() throws {
        let app = try app()
        let model = editor(app, project: try project())
        defer { model.close() }
        let (canvas, window) = windowed(model)
        defer { canvas.tearDown(); window.close() }
        canvas.renderContent()
        #expect(canvas.toolTip == "Drag to scrub. Shift-drag snaps to word starts. Double-click a cut to restore it.")
        // Words 14 and 15 close to one seam, where the piece after them starts.
        let pieces = model.timelinePieces.pieces
        let after = try #require(pieces.indices.dropFirst().first { pieces[$0].source.lowerBound - pieces[$0 - 1].source.upperBound > 1 })
        let seam = TimelineMetrics.header + CGFloat(canvas.viewport.x(pieces[after].edited.lowerBound))
        let y = TimelineMetrics.tracks[1].y + 10
        let steps = model.undoSteps
        canvas.mouseDown(with: try mouse(.leftMouseDown, NSPoint(x: seam + TimelineMetrics.reach + 3, y: y), in: canvas, clicks: 2))
        #expect(model.cutWordIDs == ["t14", "t15"] && model.undoSteps == steps)
        canvas.mouseDown(with: try mouse(.leftMouseDown, NSPoint(x: seam - 3, y: y), in: canvas, clicks: 2))
        canvas.mouseUp(with: try mouse(.leftMouseUp, NSPoint(x: seam - 3, y: y), in: canvas))
        #expect(model.cutWordIDs.isEmpty && model.undoSteps == steps + 1)
        // Source view restores the cut word under the pointer.
        model.selectedWordIDs = ["t14", "t15"]
        model.cutSelection()
        model.restoreCut(at: 14.4, on: .source, tolerance: 0.1)
        #expect(model.cutWordIDs == ["t15"])
    }

    /// The panel lays out in a window that is never shown: the toolbar's readout resolves
    /// its token colours and the lanes are hosted under it.
    @Test func thePanelLaysOutWithItsToolbarAndLanes() throws {
        let app = try app()
        let model = editor(app, project: try project())
        defer { model.close() }
        model.playhead = 14 + 23.0 / 30
        let host = ShellHost.controller(TimelinePanel(model: model, shell: WorkspaceShell(app: app)), app: app)
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 1056, height: 216), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentViewController = host
        window.setContentSize(NSSize(width: 1056, height: 216))
        defer { window.close() }
        host.view.layoutSubtreeIfNeeded()
        let canvas = try #require(DebugShell.firstView(TimelineCanvasView.self, in: host.view))
        #expect(abs(canvas.frame.height - (216 - TimelineMetrics.toolbar)) < 1 && abs(canvas.frame.width - 1056) < 1)
        _ = host.view.fittingSize
        canvas.tearDown()
    }

    /// notes.md §6's pixels, drawn in a window that is never shown: the playhead's line and
    /// head in the tint, the In bracket in clip.label, the ruler on chrome inside In/Out and
    /// darker outside, the track lanes, the open clip's 42% overview block, no red.
    @Test(arguments: [TimelineAxis.edited, .source]) func theLanesDrawNotesSixPixels(_ axis: TimelineAxis) throws {
        let app = try app()
        let model = editor(app, project: try project())
        defer { model.close() }
        model.showsCuts = axis == .source
        // The playhead inside the clip before the canvas follows it, so neither axis pages.
        let source = 20.4
        model.sourceTime = source
        model.playhead = model.timelineTime(source: source, on: .edited)
        let (canvas, window) = windowed(model)
        defer { canvas.tearDown(); window.close() }
        canvas.renderContent()
        canvas.followPlayhead()
        #expect(abs(canvas.viewport.origin - (axis == .edited ? -1 : 8.9)) < 1e-9)
        canvas.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let pixels = try Pixels(canvas)
        let cached = pixels.bitmap
        let viewport = canvas.viewport
        let play = TimelineMetrics.header + CGFloat(viewport.x(model.timelinePlayhead(on: axis)))
        #expect(try pixels.shows(play, TimelineMetrics.tracks[1].y + 10, "tint.default"))
        #expect(try pixels.shows(play, TimelineMetrics.ruler.y + 14, "tint.default"))
        let inOut = try #require(model.timelineInOut(on: axis))
        let inX = TimelineMetrics.header + CGFloat(viewport.x(inOut.lowerBound))
        #expect(try pixels.shows(inX + 0.75, TimelineMetrics.ruler.y + 12, "clip.label"))
        #expect(try pixels.shows(inX + 3, TimelineMetrics.ruler.y + 13, "bg.window"))
        #expect(try pixels.shows(inX - 6, TimelineMetrics.ruler.y + 13, "timeline.rulerOut"))
        #expect(try pixels.shows(TimelineMetrics.header + 4, TimelineMetrics.tracks[0].y + 18, "timeline.lane"))
        let block = canvas.overview.x(try #require(model.timelineOverviewClips.first).source.lowerBound + 0.3)
        #expect(try pixels.shows(block, TimelineMetrics.overview.y + 12, "clip.label", alpha: 0.42, over: "timeline.lane"))
        // The header column and its hairline stay beside every lane.
        #expect(try pixels.shows(TimelineMetrics.header - 0.5, TimelineMetrics.overview.y + 6, "line.default"))
        var red = false
        for row in stride(from: 0, to: cached.pixelsHigh, by: 2) {
            for column in stride(from: 0, to: cached.pixelsWide, by: 2) {
                guard let color = cached.colorAt(x: column, y: row)?.usingColorSpace(.sRGB) else { continue }
                if color.redComponent > 0.55 && color.greenComponent < 0.3 && color.blueComponent < 0.3 { red = true }
            }
        }
        #expect(!red)
    }

    /// A pending proposed change is a 3 pt `change.add` bar in the ruler on either axis, under the selection's bar
    /// (notes.md §6), and goes once it is kept or left out (impl-plan V14, V15).
    @Test(arguments: [TimelineAxis.edited, .source]) func pendingChangesAreRulerBars(_ axis: TimelineAxis) throws {
        let app = try app()
        let model = editor(app, project: try project())
        defer { model.close() }
        model.showsCuts = axis == .source
        // The playhead inside the clip before the canvas follows it, so neither axis pages.
        model.sourceTime = 20.4
        model.playhead = model.timelineTime(source: 20.4, on: .edited)
        model.proposal = TranscriptProposal(clipID: "clip-1", title: "Rewrite clip 1", changes: [
            TranscriptChange(ordinal: 1, parts: [.init(kind: .cut, sourceWordIDs: ["t20", "t21"])])
        ])
        let (canvas, window) = windowed(model)
        defer { canvas.tearDown(); window.close() }
        canvas.renderContent()
        canvas.followPlayhead()
        let change = try #require(canvas.content.changes.first)
        #expect(canvas.content.changes.count == 1 && canvas.ruler.state.changes == canvas.content.changes)
        #expect(abs(change.lowerBound - model.timelineTime(source: 20, on: axis)) < 1e-6 && abs(change.upperBound - model.timelineTime(source: 21.8, on: axis)) < 1e-6)
        canvas.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let x = TimelineMetrics.header + CGFloat(canvas.viewport.x((change.lowerBound + change.upperBound) / 2))
        #expect(try Pixels(canvas).shows(x, TimelineMetrics.ruler.y + 20.5, "change.add"))
        // The selection's bar draws over it.
        model.selectedWordIDs = ["t20", "t21"]
        canvas.renderContent()
        window.displayIfNeeded()
        #expect(try Pixels(canvas).shows(x, TimelineMetrics.ruler.y + 20.5, "tint.default"))
        model.selectedWordIDs = []
        model.excludeChange(1)
        canvas.renderContent()
        #expect(canvas.content.changes.isEmpty && canvas.ruler.state.changes.isEmpty)
    }

    // MARK: A1

    /// The default project with words 14, 15, 20 and 24 cut, a speech envelope (each word
    /// voiced, silence between words) and the playhead in word 17, which both axes' fitted
    /// views show, so neither pages.
    private func audioModel(_ app: AppModel) throws -> EditorModel {
        var project = try project()
        project.edits.cutWordIds = ["t14", "t15", "t20", "t24"]
        let model = editor(app, project: project)
        model.waveform = DebugTimeline.speech(words: model.words, duration: 60)
        model.sourceTime = 17.4
        model.playhead = model.timelineTime(source: 17.4, on: .edited)
        return model
    }

    /// The take-time cut ranges of the scope's plan inside `span`, adjacent ones merged.
    private func cutRanges(_ model: EditorModel, within span: ClosedRange<Double>) throws -> [Range<Double>] {
        let plan = try #require(model.plan)
        var ranges: [Range<Double>] = []
        for cut in plan.cuts {
            let lower = max(span.lowerBound, Double(cut.startSample) / plan.sampleRate), upper = min(span.upperBound, Double(cut.endSample) / plan.sampleRate)
            guard upper > lower else { continue }
            if let last = ranges.last, abs(last.upperBound - lower) < 1e-9 { ranges[ranges.count - 1] = last.lowerBound..<upper } else { ranges.append(lower..<upper) }
        }
        return ranges.filter { $0.upperBound - $0.lowerBound > 0.02 }
    }

    /// notes.md §6, Edited: pieces butt on `timeline.audioPiece`, each cut in the clip is one
    /// `timeline.seam`, words draw the waveform's core and the silence between them draws
    /// nothing, not even a centre line.
    @Test func editedA1DrawsASeamPerCutAndNothingInSilence() throws {
        let app = try app()
        let model = try audioModel(app)
        defer { model.close() }
        let (canvas, window) = windowed(model)
        defer { canvas.tearDown(); window.close() }
        canvas.renderContent()
        canvas.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        canvas.audio.layer?.displayIfNeeded()
        let plan = try #require(model.plan)
        let first = try #require(plan.kept.first), last = try #require(plan.kept.last)
        let interior = plan.cuts.filter { $0.startSample > first.startSample && $0.endSample < last.endSample }
        #expect(interior.count == 3)
        #expect(canvas.audio.drawn.seams.count == interior.count)
        #expect(model.timelinePieces.seams.count == interior.count)
        let pixels = try Pixels(canvas)
        let viewport = canvas.viewport, top = TimelineMetrics.audio.y, mid = top + TimelineMetrics.audio.height / 2
        func x(_ time: Double) -> CGFloat { TimelineMetrics.header + CGFloat(viewport.x(time)) }
        for seam in canvas.audio.drawn.seams { #expect(try pixels.shows(seam - 0.5, mid, "timeline.seam")) }
        // Word 22 is spoken: its loudest column shows the core in timeline.wave and the peak
        // around it at 62%. The 0.2 s after it is silence inside the same piece.
        let waveform = try #require(model.waveform)
        let half = TimelineMetrics.audio.height / 2 - TimelineAudioLane.pieceInset - TimelineAudioLane.waveInset
        let columns = stride(from: x(model.timelineTime(source: 22.05, on: .edited)).rounded(.down), to: x(model.timelineTime(source: 22.75, on: .edited)), by: 1).map { column in
            (column: column, value: waveform.column(from: viewport.time(atX: Double(column - TimelineMetrics.header)) + 22 - model.timelineTime(source: 22, on: .edited),
                                                    to: viewport.time(atX: Double(column + 1 - TimelineMetrics.header)) + 22 - model.timelineTime(source: 22, on: .edited)))
        }
        let loudest = try #require(columns.max { $0.value.core < $1.value.core })
        let core = CGFloat(loudest.value.core) * half, peak = CGFloat(loudest.value.peak) * half
        #expect(core >= 3 && peak - core >= 2)
        let voiced = loudest.column + 0.5
        #expect(try pixels.shows(voiced, mid, "timeline.wave"))
        #expect(try pixels.shows(voiced, mid - core + 1, "timeline.wave"))
        #expect(try pixels.shows(voiced, mid - (core + peak) / 2, "timeline.wave", alpha: TimelineAudioLane.peakOpacity, over: "timeline.audioPiece"))
        let silent = x(model.timelineTime(source: 22.9, on: .edited)).rounded(.down) + 0.5
        #expect(try pixels.shows(silent, mid, "timeline.audioPiece"))
        #expect(try pixels.shows(silent, top + 2.25, "timeline.audioPiece"))
        // The waveform keeps 2.5 pt of the piece clear above and below it.
        #expect(try pixels.shows(voiced, top + 2.25, "timeline.audioPiece"))
    }

    /// notes.md §6, Source: the same zoom on take time; each cut range in the clip is empty
    /// lane with a dashed `timeline.cutOutline`, kept pieces stand where they are and media
    /// outside In/Out shows at 32%.
    @Test func sourceA1GapsCoverExactlyTheCutRanges() throws {
        let app = try app()
        let model = try audioModel(app)
        defer { model.close() }
        model.showsCuts = true
        let (canvas, window) = windowed(model)
        defer { canvas.tearDown(); window.close() }
        canvas.renderContent()
        canvas.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        canvas.audio.layer?.displayIfNeeded()
        let scope = try #require(model.scopeSourceRange)
        let expected = try cutRanges(model, within: scope)
        #expect(expected.count == 3 && expected.allSatisfy { canvas.viewport.visible.contains($0.upperBound) })
        #expect(canvas.audio.drawn.gaps == expected)
        #expect(canvas.audio.drawn.seams.isEmpty)
        let pixels = try Pixels(canvas)
        let viewport = canvas.viewport, top = TimelineMetrics.audio.y, mid = top + TimelineMetrics.audio.height / 2
        func x(_ time: Double) -> CGFloat { TimelineMetrics.header + CGFloat(viewport.x(time)) }
        // The silence between the cut words 14 and 15 is empty lane; the words show ghosted.
        #expect(try pixels.shows(x(14.9), mid, "timeline.lane"))
        #expect(try pixels.shows(x(14.9), top + 2.25, "timeline.lane"))
        let ghosted = stride(from: x(14.05).rounded(.down) + 0.5, to: x(14.75), by: 1).filter { (try? pixels.shows($0, mid, "timeline.lane")) == false }
        #expect(ghosted.count > 5)
        let gap = try #require(expected.first)
        let dashes = stride(from: x(gap.lowerBound) + 1, to: x(gap.upperBound) - 2, by: 0.5).filter { (try? pixels.shows($0, top + 1.5, "timeline.cutOutline")) == true }
        #expect(dashes.count > 4)
        // A kept piece in take time, and the take before In at 32%.
        #expect(try pixels.shows(x(12.4), top + 2.25, "timeline.audioPiece"))
        #expect(try pixels.shows(x(scope.lowerBound) - 4, top + 2.25, "timeline.audioPiece", alpha: TimelineAudioLane.outsideOpacity, over: "timeline.lane"))
    }

    /// A Voice Lab patch on Edited (notes.md §6): an `ai.tint` 10% fill with no outline and no
    /// seam of its own; with the playhead in it the src TC reads "AI voice".
    @Test func anAIPatchIsABlueFillWithoutSeams() throws {
        let app = try app()
        let model = try audioModel(app)
        defer { model.close() }
        func piece(_ kind: VoiceLabOutputPieceKind, _ source: (Int64, Int64), _ output: (Int64, Int64)) -> VoiceLabOutputPiece {
            VoiceLabOutputPiece(kind: kind, sourceStartSample: source.0, sourceEndSample: source.1, outputStartSample: output.0, outputEndSample: output.1,
                                segmentId: nil, assetId: nil, audio: nil)
        }
        // Words 10–29 with 16–18 s spoken by your AI voice in 2.5 s, and 24–25 s cut.
        model.voiceLabPlan = VoiceLabOutputPlan(sampleRate: 100, totalSourceSamples: 6_000,
            pieces: [piece(.source, (1_000, 1_600), (0, 600)), piece(.synth, (1_600, 1_800), (600, 850)), piece(.source, (1_800, 2_400), (850, 1_450)),
                     piece(.source, (2_500, 3_000), (1_450, 1_950))], captions: [], scope: .clip("clip-1"))
        let (canvas, window) = windowed(model)
        defer { canvas.tearDown(); window.close() }
        canvas.renderContent()
        canvas.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        canvas.audio.layer?.displayIfNeeded()
        #expect(canvas.audio.drawn.seams.count == 1)
        let pixels = try Pixels(canvas)
        let viewport = canvas.viewport, top = TimelineMetrics.audio.y
        func x(_ time: Double) -> CGFloat { TimelineMetrics.header + CGFloat(viewport.x(time)) }
        #expect(try pixels.shows(x(7.2), top + 2.25, "ai.tint", alpha: 0.10, over: "timeline.lane"))
        #expect(try pixels.shows(x(7.2), top + 1.5, "ai.tint", alpha: 0.10, over: "timeline.lane"))
        #expect(try pixels.shows(x(3), top + 2.25, "timeline.audioPiece"))
        model.playhead = 7.2
        #expect(model.playheadInAIVoice)
        model.playhead = 5.9
        #expect(!model.playheadInAIVoice)
        model.playhead = 8.5
        #expect(!model.playheadInAIVoice)
    }

    /// notes.md §6 on Source while In is dragged: A1 dims from the edge the ruler shows, so
    /// the bracket and the dimming agree. Words the drag drops show at 32%; words it adds
    /// show as kept media.
    @Test(arguments: [12.1, 9.1]) func sourceA1DimsFromTheDraggedIn(_ target: Double) throws {
        let app = try app()
        let model = try audioModel(app)
        defer { model.close() }
        model.showsCuts = true
        let (canvas, window) = windowed(model)
        defer { canvas.tearDown(); window.close() }
        canvas.renderContent()
        canvas.layoutSubtreeIfNeeded()
        // In is 0.1 s before word 10, a second after the view's start; the drag shows it at
        // the start of word 12 (or 9).
        let scope = try #require(model.scopeSourceRange)
        let viewport = canvas.viewport, top = TimelineMetrics.audio.y, y = TimelineMetrics.ruler.y + 11
        func x(_ time: Double) -> CGFloat { TimelineMetrics.header + CGFloat(viewport.x(time)) }
        canvas.mouseDown(with: try mouse(.leftMouseDown, NSPoint(x: x(scope.lowerBound), y: y), in: canvas))
        canvas.mouseDragged(with: try mouse(.leftMouseDragged, NSPoint(x: x(target), y: y), in: canvas))
        let dragged = target.rounded(.down)
        #expect(canvas.audio.state.inOut == dragged...scope.upperBound)
        #expect(canvas.audio.state.clip == scope)
        canvas.audio.layer?.displayIfNeeded()
        let pixels = try Pixels(canvas)
        // Word 11 (or word 9) lies between the old In and the dragged one.
        let between = x(dragged > 10 ? 11.4 : 9.4)
        if dragged > 10 {
            #expect(try pixels.shows(between, top + 2.25, "timeline.audioPiece", alpha: TimelineAudioLane.outsideOpacity, over: "timeline.lane"))
        } else {
            #expect(try pixels.shows(between, top + 2.25, "timeline.audioPiece"))
        }
        #expect(try pixels.shows(x(dragged) - 4, top + 2.25, "timeline.audioPiece", alpha: TimelineAudioLane.outsideOpacity, over: "timeline.lane"))
        canvas.mouseUp(with: try mouse(.leftMouseUp, NSPoint(x: x(target), y: y), in: canvas))
        #expect(model.activeClip?.startWordId == "t\(Int(dragged))")
        #expect(canvas.audio.state.inOut == model.scopeSourceRange && canvas.audio.state.clip == model.scopeSourceRange)
    }

    /// A lane of `pieces` on Edited at 20 pt/s from a second before 0, over a steady voice.
    private func lane(_ pieces: [TimelinePiece]) -> (lane: TimelineAudioLane, window: NSWindow) {
        let lane = TimelineAudioLane()
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 1056, height: 44), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = lane
        lane.frame = NSRect(x: 0, y: 0, width: 1056, height: 44)
        lane.state = TimelineAudioLane.State(viewport: TimelineViewport(axis: .edited, ptPerSecond: 20, origin: -1, width: 944),
                                             pieces: TimelinePieces(pieces), waveform: WaveformData(fine: [Float](repeating: 0.05, count: 1_000)), takeLength: 10)
        lane.layer?.displayIfNeeded()
        return (lane, window)
    }

    /// The lane point a cut falls inside is one column, drawn once: the pieces either side
    /// of it do not each paint it.
    @Test func aPointTwoPiecesShareIsOneColumn() throws {
        // The cut is at x 60.4 in the lane: columns 20–60 are the first piece's, 60–100 the second's.
        let (lane, window) = lane([TimelinePiece(source: 0..<2.02, edited: 0..<2.02), TimelinePiece(source: 3..<5, edited: 2.02..<4.02)])
        defer { window.close() }
        #expect(lane.drawn.seams.count == 1)
        #expect(lane.drawn.columns == 81)
        #expect(lane.drawn.boxes == 2)
    }

    /// A fitted hour with 1,500 cuts has pieces under a point: they share one box rather
    /// than each having none, so A1 keeps its `timeline.audioPiece` ground.
    @Test func piecesUnderAPointShareOneBox() throws {
        // A hundred 0.6 pt pieces, each after a 10 ms cut.
        let pieces: [TimelinePiece] = (0..<100).map { (index: Int) -> TimelinePiece in
            let source: Double = Double(index) * 0.04, edited: Double = Double(index) * 0.03
            return TimelinePiece(source: source..<(source + 0.03), edited: edited..<(edited + 0.03))
        }
        let (lane, window) = lane(pieces)
        defer { window.close() }
        #expect(lane.drawn.boxes == 1)
        #expect(lane.drawn.columns == 60)
        // Between the seams (each the point left of a cut), above the waveform.
        let pixels = try Pixels(lane)
        let seams = lane.drawn.seams.map { $0 - 1..<$0 }
        let clear = stride(from: TimelineMetrics.header + 22, to: TimelineMetrics.header + 78, by: 1).filter { point in
            !seams.contains { $0.overlaps(point..<point + 1) }
        }
        #expect(clear.count > 5)
        for point in clear { #expect(try pixels.shows(point + 0.5, 5.5, "timeline.audioPiece")) }
    }

    /// Until the waveform arrives (or with no media to read) A1 draws one capsule per kept
    /// word (design §5.4.10); when it arrives A1 draws it, and only A1 redraws.
    @Test func a1RedrawsWhenTheWaveformArrives() throws {
        let app = try app()
        var project = try project()
        project.edits.cutWordIds = ["t12"]
        let model = editor(app, project: project)
        defer { model.close() }
        model.sourceTime = 17.4
        model.playhead = model.timelineTime(source: 17.4, on: .edited)
        let (canvas, window) = windowed(model)
        defer { canvas.tearDown(); window.close() }
        canvas.renderContent()
        canvas.layoutSubtreeIfNeeded()
        canvas.audio.layer?.displayIfNeeded()
        #expect(canvas.audio.drawn.columns == 0 && canvas.audio.drawn.capsules == 19)
        let pixels = try Pixels(canvas)
        let mid = TimelineMetrics.audio.y + TimelineMetrics.audio.height / 2
        func x(_ source: Double) -> CGFloat { TimelineMetrics.header + CGFloat(canvas.viewport.x(model.timelineTime(source: source, on: .edited))) }
        #expect(try pixels.shows(x(21.4), mid, "timeline.wave"))
        #expect(try pixels.shows(x(21.4), mid - 5, "timeline.audioPiece"))
        #expect(try pixels.shows(x(21.9), mid, "timeline.audioPiece"))
        let ruler = canvas.ruler.invalidations, audio = canvas.audio.invalidations
        model.waveform = DebugTimeline.speech(words: model.words, duration: 60)
        canvas.renderContent()
        #expect(canvas.audio.invalidations == audio + 1 && canvas.ruler.invalidations == ruler)
        canvas.audio.layer?.displayIfNeeded()
        #expect(canvas.audio.drawn.columns > 100)
        // The same load again changes nothing.
        canvas.renderContent()
        #expect(canvas.audio.invalidations == audio + 1)
    }

    // MARK: The waveform pyramid

    /// notes.md §6: nothing is drawn in silence, down to one silent 10 ms frame at a zoom
    /// where a point is 10 ms; the column beside it draws.
    @Test func aSilentTenMillisecondRunDrawsNothing() throws {
        var fine = [Float](repeating: 0.08, count: 1_000)
        fine[300] = 0
        let waveform = WaveformData(fine: fine)
        #expect(waveform.column(from: 3.0, to: 3.01) == (0, 0))
        #expect(waveform.column(from: 2.99, to: 3.0).core > 0)
        #expect(waveform.column(from: 3.01, to: 3.02).peak > 0)
        // Quiet room tone 30 dB under the voice is silence too.
        fine[400] = 0.08 * 0.03
        #expect(WaveformData(fine: fine).column(from: 4.0, to: 4.01) == (0, 0))
        // Drawn: at 100 pt/s the silent frame is one blank column of the piece.
        let lane = TimelineAudioLane()
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 1056, height: 44), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = lane
        defer { window.close() }
        lane.frame = NSRect(x: 0, y: 0, width: 1056, height: 44)
        lane.state = TimelineAudioLane.State(viewport: TimelineViewport(axis: .edited, ptPerSecond: 100, origin: 2.5, width: 944),
                                             pieces: TimelinePieces([TimelinePiece(source: 0..<10, edited: 0..<10)]), waveform: waveform, takeLength: 10)
        lane.layer?.displayIfNeeded()
        let pixels = try Pixels(lane)
        let silent = TimelineMetrics.header + 50.5
        #expect(try pixels.shows(silent, 22, "timeline.audioPiece"))
        #expect(try pixels.shows(silent - 1, 22, "timeline.wave"))
        #expect(try pixels.shows(silent + 1, 22, "timeline.wave"))
    }

    /// notes.md §6: typical peaks reach 55–70% of the half-height, and the core sits inside
    /// them. Measured on a minute of speech from a whole take's zoom to 10 ms a point, f1's
    /// 20.7 pt/s among them.
    @Test func typicalPeaksReachFiftyFiveToSeventyPercent() throws {
        let words = (0..<60).map { TimedWord(id: "t\($0)", text: "word", start: Double($0), end: Double($0) + 0.8) }
        let waveform = DebugTimeline.speech(words: words, duration: 60)
        for ptPerSecond in [936 / 45.2, 3, 8, 40, 100] {
            let step = 1 / ptPerSecond
            let columns = stride(from: 0.0, to: 60, by: step).map { waveform.column(from: $0, to: $0 + step) }.filter { $0.peak > 0 }
            let peaks = columns.map(\.peak).sorted()
            let median = peaks[peaks.count / 2]
            #expect(median >= 0.55 && median <= 0.70, "median peak \(median) at \(ptPerSecond) pt/s")
            #expect(columns.allSatisfy { $0.core <= $0.peak })
        }
        // A column a piece ends inside keeps the whole column's scale, so the columns at a
        // seam are no taller than their neighbours.
        let alternating = WaveformData(fine: (0..<400).map { $0 % 4 == 0 ? 0.1 : 0.02 })
        let whole = alternating.column(from: 1.0, to: 1.048), edge = alternating.column(from: 1.034, to: 1.048, span: 0.048)
        #expect(whole.peak > 0.5 && edge.peak <= whole.peak + 1e-6)
        #expect(alternating.column(from: 1.034, to: 1.048).peak > whole.peak)
        // A level of a 60-minute envelope folds four frames of the one below it.
        let hour = WaveformData(fine: [Float](repeating: 0.1, count: 360_000))
        #expect(hour.levels.map(\.max.count) == [360_000, 90_000, 22_500, 5_625])
        #expect(hour.byteCount < 4 << 20)
    }

    /// The column at each lane point of `seconds` at `ptPerSecond`, and whether it is a
    /// pause: every 10 ms frame within 100 ms of it under −45 dBFS.
    private func columns(_ waveform: WaveformData, seconds: Double, ptPerSecond: Double) -> [(peak: Float, pause: Bool)] {
        let step = 1 / ptPerSecond, quiet = Float(pow(10, -45.0 / 20))
        return stride(from: 0.0, to: seconds, by: step).map { start in
            let lower = max(0, Int((start - 0.1) * 100)), upper = min(waveform.fine.count, Int(((start + step + 0.1) * 100).rounded(.up)))
            return (waveform.column(from: start, to: start + step, span: step).peak, lower < upper && waveform.fine[lower..<upper].allSatisfy { $0 < quiet })
        }
    }

    /// notes.md §6 on `waveform` at the timeline's zooms: no pause draws (not even a centre
    /// line), fewer than 10% of the voiced columns reach the top, and their median peak is
    /// within `typical` of the half-height.
    private func expectSpeech(_ waveform: WaveformData, seconds: Double, typical: ClosedRange<Float>, _ name: String) {
        let half = Float(TimelineMetrics.audio.height / 2 - TimelineAudioLane.pieceInset - TimelineAudioLane.waveInset)
        for ptPerSecond in [3, 8, 936 / 45.2, 40, 100] {
            let all = columns(waveform, seconds: seconds, ptPerSecond: ptPerSecond)
            let pauses = all.filter(\.pause), voiced = all.filter { !$0.pause && $0.peak * half >= 0.5 }.map(\.peak).sorted()
            let drawn = pauses.filter { $0.peak * half >= 0.5 }.count
            #expect(drawn == 0, "\(name): \(drawn) of \(pauses.count) pause columns draw at \(ptPerSecond) pt/s")
            guard !voiced.isEmpty else { Issue.record("\(name): nothing voiced at \(ptPerSecond) pt/s"); continue }
            let top = voiced.filter { $0 >= 0.99 }.count, median = voiced[voiced.count / 2]
            #expect(top * 10 < voiced.count, "\(name): \(top) of \(voiced.count) voiced columns reach the top at \(ptPerSecond) pt/s")
            #expect(typical.contains(median), "\(name): median peak \(median) at \(ptPerSecond) pt/s")
        }
    }

    /// Real speech, decoded as the cache decodes a take: four LibriSpeech readings whose
    /// pauses hold room tone between −60 and −45 dBFS. Six seconds each, so a median holds a
    /// few dozen columns at a whole take's zoom: 50–75% here, 55–70% on the minute above.
    @Test func realSpeechDrawsNothingInItsPausesAndRarelyReachesTheTop() async throws {
        let shared = try SharedResources.locate()
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-waveform-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cache) }
        let loader = WaveformCache()
        for name in ["1089-134686-0000", "1089-134686-0002", "1188-133604-0000", "1188-133604-0001"] {
            let source = shared.root.appendingPathComponent("fixtures/voice-lab/speaker/\(name).wav")
            let waveform = try #require(await loader.load(.init(contentKey: "fixture-\(name)", source: source, cache: cache)))
            #expect(waveform.fine.count == 600)
            expectSpeech(waveform, seconds: 6, typical: 0.5...0.75, name)
        }
    }

    /// A phone or laptop take: two minutes of speech with pauses most of the time (57%)
    /// holding −50 dBFS room tone, ±3 dB. The room is not voice: it draws nothing, and it
    /// does not set the scale.
    @Test func roomToneIsSilenceAndDoesNotSetTheScale() {
        let words = (0..<60).map { TimedWord(id: "t\($0)", text: "word", start: Double($0) * 2, end: Double($0) * 2 + 0.86) }
        var fine = DebugTimeline.speech(words: words, duration: 120).fine
        var seed: UInt32 = 7
        for index in fine.indices where fine[index] == 0 {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let jitter: Double = 6 * Double(seed >> 8) / Double(1 << 24)
            let decibels: Double = -50 + jitter - 3
            fine[index] = Float(pow(10.0, decibels / 20))
        }
        #expect(fine.filter { $0 < 0.005 }.count * 100 / fine.count >= 55)
        expectSpeech(WaveformData(fine: fine), seconds: 120, typical: 0.55...0.70, "room tone")
    }

    /// impl-plan §3.1's 60-minute gate times Source as it draws: with
    /// Show cuts on and a clip open, its frames draw the removed ranges and the take outside
    /// In/Out, and its full redraw is timed with Edited's.
    @Test func thePerformanceGateTimesSourceWithItsCutsAndInOut() throws {
        let app = try app()
        let shared = try SharedResources.locate()
        let fixture = try DemoEditing.loadFixture(shared.root.appendingPathComponent("fixtures/projects/interview-take.voxclip"))
        let directory = app.locations.root.appendingPathComponent("performance", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let results = try DebugTimeline.performance(app: app, fixture: fixture, directory: directory)
        let source = try #require(results.first { $0.name.contains("Source frames draw the removed ranges and the take outside In/Out") })
        #expect(source.passed, "\(source.name)")
        #expect(results.contains { $0.name.contains("full redraw on Edited and Source") })
        for result in results { #expect(result.passed, "\(result.name)") }
    }

    // MARK: The waveform

    /// impl-plan §3.1: the model loads the waveform when the media is there, so a hidden
    /// timeline (or none) never starves the audiogram stand-in or Rewrite.
    @Test func theWaveformLoadsWithNoTimeline() async throws {
        let app = try app()
        var project = try project()
        let key = String(repeating: "c", count: 64)
        project.media.source.contentKey = key
        project.media.source.absolutePath = app.locations.root.appendingPathComponent("absent.mov").path
        let entry = app.locations.cache.appendingPathComponent(key, isDirectory: true)
        try FileManager.default.createDirectory(at: entry, withIntermediateDirectories: true)
        let samples: [Float] = [0.1, 0.4, 0.2, 0.6, 0.3]
        let data = samples.withUnsafeBytes { Data($0) }
        try data.write(to: entry.appendingPathComponent("envelope-10ms.f32"))
        var metadata = CacheEntry(contentKey: key, createdAt: Date(), lastAccessAt: Date(), bytes: Int64(data.count))
        metadata.envelope = CacheEnvelope(sampleRate: 48_000, count: samples.count)
        try ProjectJSON.encoder().encode(metadata).write(to: entry.appendingPathComponent("meta.json"))
        let model = editor(app, project: project, demo: false)
        defer { model.close() }
        #expect(model.waveform == nil && model.waveformTask == nil)
        model.mediaResolved = true
        let task = try #require(model.waveformTask)
        await task.value
        #expect(model.waveform?.fine == samples)
        // The same media does not load again; missing media drops the request.
        model.refresh()
        #expect(model.waveformTask == task)
        model.mediaResolved = false
        #expect(model.waveformKey == nil)
    }
}
#endif
