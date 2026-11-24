import Foundation
import Testing
@testable import VoxClipCore

@Suite("Project harness proposals", .offlineFixtures)
struct HarnessProposalTests {
    @Test(.enabled(if: SchemaPython.enabled, SchemaPython.skipReason))
    func stagedTimelineReplaysAsSchemaValidProject() throws {
        let shared = SharedResources(root: try FixtureLoader.sharedRoot())
        let project = try JSONProjectStore.decode(Data(contentsOf: shared.root.appendingPathComponent("fixtures/projects/clip-from-long-take.voxclip")))
        let value = try JSONDecoder().decode(JSONValue.self, from: Data("""
            {"clipId":"clip-2f1c","reason":"Emphasize the takeaway.","title":"A faster edit","captionStyle":"vox-bold",
             "cuts":[{"kind":"other","startWord":11,"endWord":11,"reason":"A shorter lead."}],
             "effects":[{"kind":"motionTitle","startWord":9,"endWord":9,"text":"A faster edit","reason":"Name the point."},
                        {"kind":"punchIn","startWord":14,"endWord":15,"scale":1.1,"reason":"Emphasize the point."}],
             "generateMusic":"A quiet instrumental bed"}
            """.utf8))
        let proposal = try HarnessProposal(timeline: HarnessTimeline.read(value), project: project)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-harness-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("fixture.voxclip")
        try HarnessInbox.stage(proposal, for: file)
        let staged = try HarnessInbox.read(for: file)
        let pending = try #require(staged)
        let candidate = try pending.applying(to: project, shared: shared)
        #expect(candidate.edits.clips.first?.title == "A faster edit")
        #expect(candidate.edits.cutWordIds.contains("w12"))
        #expect(candidate.captionSettings(forClip: "clip-2f1c").styleId == "vox-bold")
        #expect(candidate.clipEffects.map(\.kind) == [.title])
        #expect(candidate.motionCues.count == 1)
        #expect(candidate.music == project.music)
        let migrated = try ContextDemoProject.upgradeToV4(project)
        #expect(candidate.voiceLab == migrated.voiceLab)
        try JSONProjectStore.encode(candidate).write(to: file)
        try SchemaPython.validate([file])
    }
}
