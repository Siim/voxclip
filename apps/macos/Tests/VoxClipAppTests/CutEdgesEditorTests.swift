#if DEBUG
import AppKit
import Foundation
import Testing
@testable import VoxClipCore
@testable import VoxClip

/// Settings for an editor in a temporary data folder: nothing loads or saves.
private actor CutEdgeTestSettings: SettingsStore {
    func load() async throws -> SettingsDocument { SettingsDocument(values: ["update.autoCheck": .bool(false)]) }
    func save(_ settings: SettingsDocument) async throws {}
    func flush() async throws {}
}

/// Cut edges seated in the quiet in the Mac editor (editing §5.10, issue #42 CE4): the commit hook in `replace`, the
/// freeze it reads, the edit bar's offer and per-cut rows, and Edit ▸ Fix Cut Edges. The words and levels are the
/// spec's V1–V3 layout: touching w1 0.30–0.80, w2 0.80–1.30 and w3 1.30–1.90, speech at 0.5 with dips at 0.0625.
@Suite("Cut edges in the editor", .serialized, .offlineFixtures)
@MainActor struct CutEdgesEditorTests {
    /// 300 frames of 10 ms: room tone at 2^-9, speech at 0.5 over frames 30–189, and the dips given.
    static func levels(dips: [ClosedRange<Int>]) -> [Float] {
        var levels = [Float](repeating: 0x1p-9, count: 300)
        for frame in 30...189 { levels[frame] = 0.5 }
        for dip in dips { for frame in dip { levels[frame] = 0.0625 } }
        return levels
    }
    /// V3: a dip before w2's true start and one after its true end, so both seams move.
    static let bothSeams = levels(dips: [69...71, 119...121])

    private func app() throws -> AppModel {
        let parent = ProcessInfo.processInfo.environment["VOXCLIP_DATA_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory
        let root = parent.appendingPathComponent("voxclip-cut-edges-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Cache"), withIntermediateDirectories: true)
        return AppModel(settingsStore: CutEdgeTestSettings(), locations: DataLocations(environment: ["VOXCLIP_DATA_DIR": root.path]))
    }

    static func project(cut: [String] = []) throws -> Project {
        let shared = try SharedResources.locate()
        var project = try JSONProjectStore.decode(Data(contentsOf: shared.root.appendingPathComponent("fixtures/projects/interview-take.voxclip")))
        project.transcript?.words = [("w1", 0.30, 0.80), ("w2", 0.80, 1.30), ("w3", 1.30, 1.90)].map {
            TimedWord(id: $0.0, text: $0.0, kind: .word, start: $0.1, end: $0.2)
        }
        project.transcript?.durationSeconds = 3
        project.media.source.durationSeconds = 3
        project.edits = ProjectEdits(pauseThresholdSeconds: 0.8, cutWordIds: cut)
        return project
    }

    /// An editable editor over `project` with its waveform loaded, or none.
    private func editor(_ app: AppModel, project: Project, levels: [Float]? = bothSeams) -> (EditorModel, UndoManager) {
        let model = EditorModel(document: VoxClipDocument(project: project, demo: true), app: app, preview: DemoPreviewEngine())
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.undoManager = undo
        model.mediaResolved = true
        model.refresh()
        if let levels { model.waveform = WaveformData(fine: levels) }
        return (model, undo)
    }

    private func step(_ undo: UndoManager, _ body: () -> Void) {
        undo.beginUndoGrouping(); body(); undo.endUndoGrouping()
    }

    @Test func aNewCutLandsInTheQuietInTheSameUndoStep() throws {
        let app = try app()
        let original = try Self.project()
        let (model, undo) = editor(app, project: original)
        defer { model.close(); try? FileManager.default.removeItem(at: app.locations.root) }
        let steps = model.undoSteps
        model.selectedWordIDs = ["w2"]
        step(undo) { model.cutSelection() }
        #expect(model.project.edits.cutWordIds == ["w2"])
        #expect(model.project.edits.cutEdges == ["w2": 0.705, "w3": 1.205])
        #expect(model.project.schemaVersion == 8)
        #expect(model.undoSteps == steps + 1 && undo.undoActionName == "Cut selection")
        #expect(model.plan?.cuts == [MediaInterval(startSample: 33_840, endSample: 57_840)])
        undo.undo()
        #expect(model.project.edits == original.edits && model.project.schemaVersion == original.schemaVersion)
        undo.redo()
        #expect(model.project.edits.cutEdges == ["w2": 0.705, "w3": 1.205])
    }
}
#endif
