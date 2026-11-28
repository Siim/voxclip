#if DEBUG
import AppKit
import Foundation
import VoxClipCore

/// The cut edge self-tests (issue #42 CE4, editing §5.10) on the spec's V3 layout: touching w1 0.30–0.80, w2 0.80–1.30
/// and w3 1.30–1.90 over levels with a dip before and after w2, at 48 kHz. A new cut lands on the stored seam, A1 shades
/// the plan's cut, preview skips what export cuts, each action is one undo step, and every disabled action says why.
@MainActor enum DebugCutEdges {
    /// 300 frames of 10 ms: room tone at 2^-9, speech at 0.5 over frames 30–189, and the dips given at 0.0625.
    static func levels(dips: [ClosedRange<Int>]) -> [Float] {
        var levels = [Float](repeating: 0x1p-9, count: 300)
        for frame in 30...189 { levels[frame] = 0.5 }
        for dip in dips { for frame in dip { levels[frame] = 0.0625 } }
        return levels
    }

    static func project(_ fixture: Project, cut: [String] = []) throws -> Project {
        var project = try ContextDemoProject.upgradeToV4(fixture)
        project.transcript?.words = [("w1", 0.30, 0.80), ("w2", 0.80, 1.30), ("w3", 1.30, 1.90)].map {
            TimedWord(id: $0.0, text: $0.0, kind: .word, start: $0.1, end: $0.2)
        }
        project.transcript?.durationSeconds = 3
        project.media.source.durationSeconds = 3
        project.media.source.audio = MediaAudio(sampleRate: 48_000, channels: 1)
        project.edits = ProjectEdits(pauseThresholdSeconds: 0.8, cutWordIds: cut)
        project.captions.styleId = "off"
        return project
    }

    static func makeEditor(app: AppModel, project: Project, levels: [Float]?) -> (EditorModel, UndoManager) {
        let editor = EditorModel(document: VoxClipDocument(project: project, demo: true), app: app, preview: DemoPreviewEngine())
        let undo = UndoManager()
        undo.groupsByEvent = false
        editor.undoManager = undo
        editor.mediaResolved = true
        editor.refresh()
        if let levels { editor.waveform = WaveformData(fine: levels) }
        return (editor, undo)
    }

    static func run(app: AppModel, fixture: Project) async throws -> [DebugUISuite.Result] {
        var results: [DebugUISuite.Result] = []
        func check(_ name: String, _ passed: Bool) { results.append(.init(name: name, passed: passed)) }
        let bothSeams = levels(dips: [69...71, 119...121])
        let rate = 48_000.0
        func sample(_ seconds: Double) -> Int64 { Int64(EditingPrimitives.jsRound(seconds * rate)) }

        // A new cut, seated as it is committed.
        let (editor, undo) = makeEditor(app: app, project: try project(fixture), levels: bothSeams)
        defer { editor.close() }
        let steps = editor.undoSteps
        editor.selectedWordIDs = ["w2"]
        undo.beginUndoGrouping(); editor.cutSelection(); undo.endUndoGrouping()
        let edges = editor.project.edits.cutEdges
        check("cut edges: a new cut stores both seams in the quiet", edges == ["w2": 0.705, "w3": 1.205])
        let seam = MediaInterval(startSample: sample(edges["w2"] ?? 0), endSample: sample(edges["w3"] ?? 0))
        check("cut edges: the planned cut equals the stored seam", editor.plan?.cuts == [seam])
        check("cut edges: the cut and its seat are one undo step", editor.undoSteps == steps + 1 && undo.undoActionName == "Cut selection")
        let removed = editor.timelineRemovedRanges(editor.timelinePieces)
        check("cut edges: A1 shades the plan's cut, not the word's span", removed == [Double(seam.startSample) / rate..<Double(seam.endSample) / rate])
        let preview = try await editor.renderRequest()
        let export = try await editor.renderRequest(target: .fullEdit)
        let cli = try RenderCallerInputs.editPlan(project: editor.project)
        check("cut edges: preview skips what export and the CLI cut", preview.plan.cuts == [seam] && export.plan.cuts == [seam] && cli.cuts == [seam])
        let skipped = preview.plan.sourceTime(Double(seam.startSample) / rate)
        check("cut edges: preview plays on from the later seam", abs(skipped - Double(seam.endSample) / rate) < 1 / rate)
        undo.undo()
        check("cut edges: Undo takes the cut and its seat back together", editor.project.edits.cutWordIds.isEmpty && editor.project.edits.cutEdges.isEmpty)

        // An old cut: the inline offer, Fix cut edges as one step, and the menu's reasons.
        let (old, oldUndo) = makeEditor(app: app, project: try project(fixture, cut: ["w2"]), levels: bothSeams)
        defer { old.close() }
        check("cut edges: opening a project changes nothing", old.project.edits.cutEdges.isEmpty)
        check("cut edges: the edit bar offers the old cut", old.cutEdgeBarRow == CutEdgeBarRow(text: "2 cuts can land in the quiet", action: "Fix cut edges"))
        let oldSteps = old.undoSteps
        oldUndo.beginUndoGrouping(); old.fixCutEdges(); oldUndo.endUndoGrouping()
        check("cut edges: Fix cut edges is one undo step", old.undoSteps == oldSteps + 1 && oldUndo.undoActionName == "Fix cut edges"
              && old.project.edits.cutEdges == edges && old.plan?.cuts == [seam])
        check("cut edges: Fix cut edges says what it moved", old.cutEdgeBarRow == CutEdgeBarRow(text: "Moved 2 cut edges into the quiet"))
        check("cut edges: Fix Cut Edges is disabled once every edge is in the quiet",
              !old.canFixCutEdges && old.fixCutEdgesReason == "All cut edges are in the quiet")
        old.selectedWordIDs = ["w2"]
        oldUndo.beginUndoGrouping(); old.runCutEdgeBarAction(); oldUndo.endUndoGrouping()
        check("cut edges: Use word edge pins both edges as one undo step", oldUndo.undoActionName == "Use word edge"
              && old.project.edits.cutEdges == ["w2": 0.80, "w3": 1.30] && old.cutEdgeBarRow?.action == "Use quiet point")

        let (loading, _) = makeEditor(app: app, project: try project(fixture, cut: ["w2"]), levels: nil)
        defer { loading.close() }
        check("cut edges: Fix Cut Edges waits for the waveform", !loading.canFixCutEdges && loading.fixCutEdgesReason == "Waveform still loading")
        let (flat, _) = makeEditor(app: app, project: try project(fixture, cut: ["w2"]), levels: levels(dips: []))
        defer { flat.close() }
        flat.selectedWordIDs = ["w2"]
        check("cut edges: a cut with no quiet point says so", flat.cutEdgeBarRow?.reason == "No quiet point near this edge")
        if let delegate = NSApp.delegate as? AppDelegate, let item = NSApp.mainMenu?.item(withTitle: "Edit")?.submenu?.item(withTitle: "Fix Cut Edges") {
            check("cut edges: Edit ▸ Fix Cut Edges is always listed", !item.isHidden && item.tag == 77)
            _ = delegate.validateMenuItem(item)
        }
        return results
    }
}
#endif
