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
        let lanes: [TimelineLane] = [canvas.overview, canvas.ruler, canvas.bed]
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
        let x = Double(canvas.overlay.playhead.transform.m41)
        #expect(abs(x - (Double(TimelineMetrics.header) + canvas.viewport.x(15))) < 1e-6)
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
