import Foundation
import Testing
@testable import VoxClipCore

@Suite("Project harness proposals", .offlineFixtures)
struct HarnessProposalTests {
    @Test func newStoryPreservesPartOrderAndLeavesRewritesPending() throws {
        let shared = SharedResources(root: try FixtureLoader.sharedRoot())
        let project = try JSONProjectStore.decode(Data(contentsOf: shared.root.appendingPathComponent("fixtures/projects/clip-from-long-take.voxclip")))
        let cases = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: shared.root.appendingPathComponent("fixtures/clips-mode/harness-proposal-cases.json")))
        let proposal = try HarnessProposal(timeline: HarnessTimeline.read(#require(cases["story"])), project: project)
        let result = try proposal.review(project, shared: shared)
        let kept = result.project
        let story = try #require(kept.edits.clips.last)
        #expect(story.playParts.map(\.startWordId) == ["w15", "w10"])
        #expect(story.kind == .story)
        #expect(kept.voiceLab == (try ContextDemoProject.upgradeToV4(project)).voiceLab)
        #expect(result.pending.map(\.decision) == [.rewrite])
    }

    @Test func harnessAndAutopilotProduceTheSameOperations() throws {
        let shared = SharedResources(root: try FixtureLoader.sharedRoot())
        let project = try JSONProjectStore.decode(Data(contentsOf: shared.root.appendingPathComponent("fixtures/projects/clip-from-long-take.voxclip")))
        let cases = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: shared.root.appendingPathComponent("fixtures/clips-mode/harness-proposal-cases.json")))
        let timeline = try HarnessTimeline.read(#require(cases["equivalentPlan"]))
        let staged = try HarnessProposal(timeline: timeline, project: project)
        let plan = ClipAutopilotPlan(startWord: 9, endWord: 16, title: "A faster edit", hook: "Edit faster",
            cuts: [.init(startWord: 11, endWord: 11, kind: .other, reason: "Remove the aside.")],
            captions: .init(styleId: "vox-bold", font: .init(family: "DM Sans", weight: 700), textCase: .upper, wordsPerCaption: 4),
            look: .init(id: .warm, reason: "Warm the footage."), speed: .init(rate: 1.1, reason: "Keep the pacing brisk."),
            postText: "A simpler way to make an edit.", score: 90, verdict: .post)
        let mapped = try ClipAutopilotMapping.operations(for: plan, clipID: timeline.clipId, project: project, fonts: ClipAutopilotFonts.load(shared: shared))
        #expect(try staged.review(project, shared: shared).operations == mapped)
    }

    @Test(.enabled(if: SchemaPython.enabled, SchemaPython.skipReason))
    func allHarnessMotionTemplatesReplayAsSchemaValidProjects() throws {
        let shared = SharedResources(root: try FixtureLoader.sharedRoot())
        let project = try JSONProjectStore.decode(Data(contentsOf: shared.root.appendingPathComponent("fixtures/projects/clip-from-long-take.voxclip")))
        let vectors = try JSONDecoder().decode([JSONValue].self, from: Data(contentsOf: shared.root.appendingPathComponent("fixtures/clip-effects/motion-template-cases.json")))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-motion-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("fixture.voxclip")
        let timeline = try HarnessTimeline.read(.object(["clipId": .string("clip-2f1c"), "reason": .string("Make a showreel."), "effects": .array(vectors)]))
        try HarnessInbox.stage(HarnessProposal(timeline: timeline, project: project), for: file)
        let proposal = try #require(try HarnessInbox.read(for: file))
        let candidate = try proposal.applying(to: project, shared: shared)
        let rendered = ClipEffects.rendered(in: candidate, clipID: "clip-2f1c")
        #expect(rendered.count == vectors.count)
        #expect(ClipEffects.rendered(in: candidate, clipID: nil).isEmpty)
        #expect(rendered.map(\.template) == timeline.effects?.map(\.template))
        #expect(candidate.music == project.music)
        #expect(try proposal.estimatedMusicPrice(in: project, shared: shared) == nil)
        try JSONProjectStore.encode(candidate).write(to: file)
        try SchemaPython.validate([file])
    }

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
