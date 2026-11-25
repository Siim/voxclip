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

        let cases = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: shared.root.appendingPathComponent("fixtures/clips-mode/harness-proposal-cases.json")))
        let story = try HarnessTimeline.read(#require(cases["story"]))
        let series = try HarnessProposal(timelines: [story, timeline, timeline], project: editor.project)
        let proposed = try series.review(editor.project, shared: shared)
        let clip = try #require(proposed.project.edits.clips.last)
        let card = editor.harnessCreativeData(story, clip: clip, result: proposed.project, operations: proposed.operations, estimate: nil)
        #expect(card.source.hasPrefix("Story · proposed"))
        #expect(card.parts.first?.start == clip.playPartIndices(in: editor.words).map { editor.words[$0[0].lowerBound].start })
        #expect(card.cost?.contains("doesn't spend") == true)
        #expect(HarnessCreativeProposal.changeUnavailable == "Ask Claude Code or Codex in your terminal to change it.")
        try HarnessInbox.stage(series, for: url)
        try HarnessInbox.resolve(series, remaining: series.discarding(at: 2), for: url)
        let two = try #require(try HarnessInbox.read(for: url))
        #expect(two.timelines == [story, timeline])

        undo.beginUndoGrouping()
        try editor.keepHarnessProposal(two, at: url, timeline: 1)
        undo.endUndoGrouping()
        #expect(!editor.project.edits.clips.contains { $0.kind == .story })
        let afterFirst = editor.project
        let one = try #require(try HarnessInbox.read(for: url))
        #expect(one.timelines == [story])

        undo.beginUndoGrouping()
        let actions = try editor.keepHarnessTimeline(one, at: url, index: 0)
        undo.endUndoGrouping()
        #expect(actions.map(\.decision) == [.rewrite])
        #expect(editor.project.edits.clips.last?.kind == .story)
        #expect(try HarnessInbox.read(for: url) == nil)
        undo.undo()
        #expect(editor.project.edits == afterFirst.edits)
        undo.undo()
        #expect(editor.project.edits == project.edits)
    }
}
#endif
