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
        // At v4, as a project with Voice Lab segments is.
        var project = try ContextDemoProject.upgradeToV4(JSONProjectStore.decode(Data(contentsOf: shared.root.appendingPathComponent("fixtures/projects/interview-take.voxclip"))))
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

    @Test func aCutWithoutAWaveformAndItsRestoreKeepTodaysPadding() throws {
        let app = try app()
        let original = try Self.project()
        let (model, undo) = editor(app, project: original, levels: nil)
        defer { model.close(); try? FileManager.default.removeItem(at: app.locations.root) }
        model.selectedWordIDs = ["w2"]
        step(undo) { model.cutSelection() }
        #expect(model.project.edits.cutEdges.isEmpty && model.project.schemaVersion == original.schemaVersion)
        #expect(model.plan?.cuts == [MediaInterval(startSample: 38_400, endSample: 62_400)])
        // Seated, then restored as a new step (not an Undo): the edits are byte for byte the ones before the cut.
        model.waveform = WaveformData(fine: Self.bothSeams)
        step(undo) { model.cutSelection(restore: true) }
        step(undo) { model.cutSelection() }
        #expect(model.project.edits.cutEdges == ["w2": 0.705, "w3": 1.205])
        step(undo) { model.cutSelection(restore: true) }
        #expect(try ProjectJSON.encoder().encode(model.project.edits) == ProjectJSON.encoder().encode(original.edits))
        // The v4 file went to v8 with its first key and lands at 6 once the last one goes (editing §10.1).
        #expect(model.project.schemaVersion == 6)
    }

    /// V1's levels: only the w2|w3 edge would move (to 1.205). Each kind of paid or open work keeps it where it is.
    static let lateBoundary = levels(dips: [79...81, 119...121])

    private func cutW2(_ app: AppModel, _ project: Project, prepare: (EditorModel) throws -> Void = { _ in }) throws -> [String: Double] {
        let (model, undo) = editor(app, project: project, levels: Self.lateBoundary)
        defer { model.close() }
        try prepare(model)
        model.selectedWordIDs = ["w2"]
        step(undo) { model.cutSelection() }
        #expect(model.project.edits.cutWordIds == ["w2"])
        return model.project.edits.cutEdges
    }

    /// A clip over w3 alone, so the w2|w3 edge is that clip's edge.
    static func projectWithClip() throws -> Project {
        var project = try project()
        project.edits.clips = [ClipRange(id: "c3", startWordId: "w3", endWordId: "w3")]
        return project
    }

    @Test func paidAndOpenWorkKeepTheEdgesBesideIt() throws {
        let app = try app()
        defer { try? FileManager.default.removeItem(at: app.locations.root) }
        #expect(try cutW2(app, Self.projectWithClip()) == ["w3": 1.205])
        // A voice patch over w3, enabled or not.
        let shared = try SharedResources.locate()
        let revoiced = try JSONProjectStore.decode(Data(contentsOf: shared.root.appendingPathComponent("fixtures/voice-lab/whole-clip-revoice-project.voxclip")))
        var segment = try #require(revoiced.voiceLab.segments.first)
        segment.replace = VoiceLabReplacement(start: 1.30, end: 1.90, firstWordId: "w3", lastWordId: "w3")
        segment.candidates = segment.candidates.map { candidate in
            var candidate = candidate
            candidate.recipe?.video.mode = .source
            return candidate
        }
        for enabled in [true, false] {
            var patched = try Self.projectWithClip()
            segment.enabled = enabled
            patched.voiceLab.segments = [segment]
            #expect(try cutW2(app, patched).isEmpty, "voice patch, enabled \(enabled)")
        }
        // A whole-clip revoice of the clip over w3.
        var whole = try Self.projectWithClip()
        var record = try #require(revoiced.voiceLab.wholeClipRevoices?.first)
        record.clipId = "c3"
        whole.voiceLab.wholeClipRevoices = [record]
        #expect(try cutW2(app, whole).isEmpty, "whole-clip revoice")
        // An open Rewrite on that clip, paid or not.
        #expect(try cutW2(app, Self.projectWithClip()) { model in
            model.rewrite = RewriteSession(editor: model, scope: .clip("c3"), envelope: nil, connector: nil)
        }.isEmpty, "open Rewrite")
        // Paid takes saved beside the project for that clip; a saved proposal with nothing paid keeps nothing.
        for takes in [1, 0] {
            let project = try Self.projectWithClip()
            let url = try #require(RewriteSavedProposalStore.url(paidRoot: app.locations.root.appendingPathComponent("VoiceLab", isDirectory: true),
                                                                 projectId: project.id, scope: "clip:c3"))
            let saved = RewriteSavedProposal(projectId: project.id, scope: "clip:c3", inputs: "x", instruction: "", changes: [], kept: [], pricedAnyway: [],
                                             voiceRecordID: nil, patchTakes: takes, patchUSD: 0, patchRequests: [], wholeClip: nil, savedAt: Date())
            try RewriteSavedProposalStore.write(RewriteSavedProposalStore.encode(saved), to: url)
            #expect(try cutW2(app, project) == (takes > 0 ? [:] : ["w3": 1.205]), "saved proposal with \(takes) paid takes")
            RewriteSavedProposalStore.remove(url)
        }
    }

    // MARK: Old cuts

    @Test func oldCutsAreOfferedInlineAndFixedInOneStep() throws {
        let app = try app()
        let original = try Self.project(cut: ["w2"])
        let (model, undo) = editor(app, project: original)
        defer { model.close(); try? FileManager.default.removeItem(at: app.locations.root) }
        // Opening changes nothing; the edit bar offers the two edges.
        #expect(model.project == original)
        #expect(model.cutEdgeOffer == CutEdges.Offer(count: 2, frozen: 0, unloaded: []))
        #expect(model.cutEdgeBarRow == CutEdgeBarRow(text: "2 cuts can land in the quiet", action: "Fix cut edges"))
        #expect(model.canFixCutEdges && model.fixCutEdgesReason == nil && model.mutationEnabled(77) == true)
        let steps = model.undoSteps
        step(undo) { model.fixCutEdges() }
        #expect(model.undoSteps == steps + 1 && undo.undoActionName == "Fix cut edges")
        #expect(model.project.edits.cutEdges == ["w2": 0.705, "w3": 1.205] && model.project.schemaVersion == 8)
        #expect(model.plan?.cuts == [MediaInterval(startSample: 33_840, endSample: 57_840)])
        #expect(model.cutEdgeBarRow == CutEdgeBarRow(text: "Moved 2 cut edges into the quiet"))
        #expect(model.lastAnnouncement == "Moved 2 cut edges into the quiet")
        // Edit ▸ Fix Cut Edges stays, disabled with its reason.
        #expect(!model.canFixCutEdges && model.fixCutEdgesReason == "All cut edges are in the quiet")
        undo.undo()
        #expect(model.project == original && model.cutEdgeBarRow?.action == "Fix cut edges")
    }

    @Test func fixingBesideAVoicePatchSaysWhatItKept() throws {
        let app = try app()
        var project = try Self.project(cut: ["w2"])
        let shared = try SharedResources.locate()
        let revoiced = try JSONProjectStore.decode(Data(contentsOf: shared.root.appendingPathComponent("fixtures/voice-lab/whole-clip-revoice-project.voxclip")))
        var segment = try #require(revoiced.voiceLab.segments.first)
        segment.replace = VoiceLabReplacement(start: 1.30, end: 1.90, firstWordId: "w3", lastWordId: "w3")
        project.voiceLab.segments = [segment]
        let (model, undo) = editor(app, project: project)
        defer { model.close(); try? FileManager.default.removeItem(at: app.locations.root) }
        #expect(model.cutEdgeOffer == CutEdges.Offer(count: 1, frozen: 1, unloaded: []))
        #expect(model.cutEdgeBarRow?.text == "1 cut can land in the quiet")
        step(undo) { model.fixCutEdges() }
        #expect(model.project.edits.cutEdges == ["w2": 0.705])
        #expect(model.cutEdgeBarRow == CutEdgeBarRow(text: "Moved 1 cut edge into the quiet · 1 kept beside voice patches"))
    }

    @Test func fixCutEdgesSaysWhyItCannotRun() throws {
        let app = try app()
        let (loading, _) = editor(app, project: try Self.project(cut: ["w2"]), levels: nil)
        defer { loading.close(); try? FileManager.default.removeItem(at: app.locations.root) }
        #expect(loading.cutEdgeOffer.unloaded == [loading.project.media.source.contentKey] && loading.cutEdgeBarRow == nil)
        #expect(!loading.canFixCutEdges && loading.fixCutEdgesReason == "Waveform still loading")
        // The video is missing: its waveform can't load until it is found again.
        var project = try Self.project(cut: ["w2"])
        project.media.source.absolutePath = app.locations.root.appendingPathComponent("absent.mov").path
        let missing = EditorModel(document: VoxClipDocument(project: project, demo: false), app: app, preview: DemoPreviewEngine())
        defer { missing.close() }
        missing.markMediaCheckedForAudit()
        let label = ProjectClock.label(project.media.source)
        #expect(missing.fixCutEdgesReason == "Reconnect \(label) to fix its cut edges")
        // No old cut to move.
        let (none, _) = editor(app, project: try Self.project())
        defer { none.close() }
        #expect(none.fixCutEdgesReason == "All cut edges are in the quiet" && none.cutEdgeBarRow == nil)
    }

    @Test func editMenuListsFixCutEdges() throws {
        _ = NSApplication.shared
        let previous = NSApp.mainMenu
        defer { NSApp.mainMenu = previous }
        AppDelegate().installMenus()
        let edit = try #require(NSApp.mainMenu?.item(withTitle: "Edit")?.submenu)
        let item = try #require(edit.item(withTitle: "Fix Cut Edges"))
        #expect(item.tag == 77 && item.action == NSSelectorFromString("performEditorCommand:") && !item.isHidden)
        let restore = try #require(edit.item(withTitle: "Restore All Cuts"))
        #expect(edit.index(of: item) == edit.index(of: restore) + 1)
    }
}
#endif
