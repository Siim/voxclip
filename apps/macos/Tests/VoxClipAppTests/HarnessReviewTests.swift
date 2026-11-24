#if DEBUG
import AppKit
import Foundation
import Testing
@testable import VoxClip
@testable import VoxClipCore

@MainActor @Suite("Reviewing a harness timeline", .offlineFixtures)
struct HarnessReviewTests {
    @Test func keepsOneUndoableEditAndRejectsStaleOrDismissedProposals() throws {
        _ = NSApplication.shared
        let shared = try SharedResources.locate()
        let fixture = shared.root.appendingPathComponent("fixtures/projects/clip-from-long-take.voxclip")
        let original = try Data(contentsOf: fixture)
        let project = try JSONProjectStore.decode(original)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-harness-review-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("fixture.voxclip")
        try original.write(to: url)
        let app = AppModel(settingsStore: RegressionSettingsStore(), locations: DataLocations(environment: ["VOXCLIP_DATA_DIR": folder.path]))
        let document = VoxClipDocument(project: project)
        document.fileURL = url
        let editor = EditorModel(document: document, app: app, preview: DemoPreviewEngine())
        defer { editor.close(); document.fileURL = nil }
        editor.mediaResolved = true
        let undo = UndoManager()
        undo.groupsByEvent = false
        editor.undoManager = undo
        let raw = try JSONDecoder().decode(JSONValue.self, from: Data("""
            {"clipId":"clip-2f1c","reason":"Make the point clear.","title":"A new title","generateMusic":"A warm instrumental",
             "effects":[{"kind":"motionTemplate","startWord":9,"endWord":10,"reason":"Name the point.",
                         "template":{"name":"titleCard","text":"A new title"}}]}
            """.utf8))
        let timeline = try HarnessTimeline.read(raw)
        let rejected = try HarnessProposal(timeline: timeline, project: project)
        try HarnessInbox.stage(rejected, for: url)
        try HarnessInbox.dismiss(rejected, for: url)
        #expect(throws: HarnessError.self) { try editor.keepHarnessProposal(rejected, at: url) }
        #expect(editor.project == project)

        let pending = try HarnessProposal(timeline: timeline, project: project)
        try HarnessInbox.stage(pending, for: url)
        var changed = project
        try changed.applyEditing(.renameClip(id: "clip-2f1c", title: "Creator's edit"))
        document.replaceProject(changed)
        #expect(throws: HarnessError.self) { try editor.keepHarnessProposal(pending, at: url) }
        #expect(editor.project == changed)
        #expect(try HarnessInbox.read(for: url) == pending)
        document.replaceProject(project)

        undo.beginUndoGrouping()
        try editor.keepHarnessProposal(pending, at: url)
        undo.endUndoGrouping()
        #expect(editor.undoSteps == 1)
        #expect(editor.project.edits.clips.first?.title == "A new title")
        #expect(editor.project.clipEffects.map(\.template) == [.titleCard("A new title")])
        #expect(editor.project.music == project.music)
        #expect(editor.musicPanel.phase == .idle)
        #expect(try HarnessInbox.read(for: url) == nil)
        undo.undo()
        #expect(editor.project.edits == project.edits)
        #expect(editor.project.clipEffects == project.clipEffects)
    }
}
#endif
