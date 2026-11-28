import Foundation
import Testing
@testable import VoxClipCore

@Suite("Project harness proposals", .offlineFixtures)
struct HarnessProposalTests {
    @Test func confirmedLocalAndCloudTranscriptsStaySeparate() throws {
        let project = try JSONProjectStore.decode(FixtureLoader.data("fixtures/recordings/two-recordings.voxclip"))
        let key = project.media.source.contentKey
        let cloud = try #require(project.transcript)
        var local = cloud
        local.engine.id = .whispercpp
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cache) }
        RecordingTranscriptCache.write(cloud, key: key, cache: cache)
        #expect(RecordingTranscriptCache.read(key, cache: cache) == cloud)
        #expect(HarnessRecording.cachedTranscript(key, cache: cache) == nil)
        var recent = project
        recent.transcript = local
        let recentURL = cache.appendingPathComponent("recent.voxclip")
        try JSONProjectStore.encode(recent).write(to: recentURL)
        #expect(HarnessRecording.cachedTranscript(key, cache: cache, recent: [recentURL]) == local)
        let directory = cache.appendingPathComponent("\(key)/transcripts")
        let legacy = directory.appendingPathComponent("confirmed-v1.json")
        let legacyBytes = try JSONEncoder().encode(cloud)
        try legacyBytes.write(to: legacy)
        RecordingTranscriptCache.write(local, key: key, cache: cache)
        RecordingTranscriptCache.write(cloud, key: key, cache: cache)
        #expect(HarnessRecording.cachedTranscript(key, cache: cache) == local)
        #expect(RecordingTranscriptCache.read(key, cache: cache) == local)
        #expect(try Data(contentsOf: legacy) == legacyBytes)
        try Data("invalid".utf8).write(to: directory.appendingPathComponent("confirmed-local-v1.json"))
        #expect(HarnessRecording.cachedTranscript(key, cache: cache) == nil)
        #expect(RecordingTranscriptCache.read(key, cache: cache) == cloud)
    }

    @Test func aLocalCompanionAndStoryMapToTheSharedOperations() throws {
        let shared = SharedResources(root: try FixtureLoader.sharedRoot())
        struct Vector: Decodable {
            struct Expected: Decodable {
                let operationIds: [String], partIds: [String], startWordIds: [String], endWordIds: [String]
                let cloudRefusal: String
            }
            let project: String, timeline: HarnessTimeline, expected: Expected
        }
        let vector = try JSONDecoder().decode(Vector.self, from: FixtureLoader.data("fixtures/recordings/harness-cases.json"))
        var original = try JSONProjectStore.decode(FixtureLoader.data("fixtures/recordings/\(vector.project)"))
        var transcript = try #require(original.media.spokenSources?.first?.transcript)
        original.media.spokenSources = nil
        original.schemaVersion = 6
        original.edits.clips = []; original.edits.activeClipId = nil
        let cloud = try HarnessProposal(timeline: vector.timeline, project: original)
        do {
            _ = try cloud.review(original, shared: shared, recordingTranscript: transcript)
            Issue.record("A cloud-only project accepted useRecording.")
        } catch { #expect(error.localizedDescription == vector.expected.cloudRefusal) }

        original.transcript?.engine.id = .whispercpp
        transcript.engine.id = .whispercpp
        let proposal = try HarnessProposal(timeline: vector.timeline.pinningRecordingTranscript(transcript), project: original)
        let result = try proposal.review(original, shared: shared, recordingTranscript: transcript)
        let clip = try #require(result.project.edits.clips.first)
        #expect(result.operations.map(\.id) == vector.expected.operationIds)
        #expect(clip.playParts.map(\.id) == vector.expected.partIds)
        #expect(clip.playParts.map(\.startWordId) == vector.expected.startWordIds)
        #expect(clip.playParts.map(\.endWordId) == vector.expected.endWordIds)
        #expect(result.project.media.spokenSources?.first?.transcript == transcript)
        #expect(result.pending.isEmpty)
        #expect(original.media.spokenSources == nil && original.edits.clips.isEmpty)
        transcript.language = "et"
        do {
            _ = try proposal.review(original, shared: shared, recordingTranscript: transcript)
            Issue.record("Keep accepted a different recording transcript.")
        } catch { #expect(error.localizedDescription == "The recording transcript changed. Ask for a new timeline proposal.") }
    }

    @Test func timelineEditsApplyInOrderOrRefuseTheWholeProposal() throws {
        let shared = SharedResources(root: try FixtureLoader.sharedRoot())
        let project = try JSONProjectStore.decode(Data(contentsOf: shared.root.appendingPathComponent("fixtures/projects/clip-from-long-take.voxclip")))
        func proposal(_ edits: String) throws -> HarnessProposal {
            let wire = try JSONDecoder().decode(JSONValue.self, from: Data("""
                {"clipId":"clip-2f1c","reason":"Tighten the clip.","title":"Tighter","edits":[\(edits)]}
                """.utf8))
            return try HarnessProposal(timeline: HarnessTimeline.read(wire), project: project)
        }
        let trim = #"{"op":"trim","item":"clip-2f1c","edge":"start","toWord":10}"#
        let kept = try proposal(trim).review(project, shared: shared)
        let clip = try #require(kept.project.edits.clips.first { $0.id == "clip-2f1c" })
        #expect(clip.startWordId == "w11")
        #expect(clip.title == "Tighter")
        #expect(kept.pending.isEmpty)
        let invalid = try proposal(trim + #",{"op":"delete","items":["missing"]}"#)
        #expect(throws: TimelineEditRefusal("Select an item on this timeline.")) {
            try invalid.review(project, shared: shared)
        }
    }

    /// Looks spec §8.5: a timeline's look is any look of shared/looks/clip-looks.json at its amount, checked against the file;
    /// one VoxClip doesn't have refuses the proposal with the reason.
    @Test func aTimelinesLookIsALooksFileIDAtItsAmount() throws {
        let shared = SharedResources(root: try FixtureLoader.sharedRoot())
        let project = try JSONProjectStore.decode(Data(contentsOf: shared.root.appendingPathComponent("fixtures/projects/clip-from-long-take.voxclip")))
        func proposal(_ look: String) throws -> HarnessProposal {
            let wire = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"clipId":"clip-2f1c","reason":"Warmer.","look":\#(look)}"#.utf8))
            return try HarnessProposal(timeline: HarnessTimeline.read(wire), project: project)
        }
        let kept = try proposal(#"{"id":"warmPrint","amount":70,"reason":"A memory"}"#).review(project, shared: shared).project
        let controls = try #require(ClipControlsProject.controls(for: "clip-2f1c", in: kept))
        #expect(controls.colorGrade?.preset == "warmPrint" && controls.colorGrade?.amount == 70)
        #expect(try ClipLookLibrary.load(shared: shared).match(controls)?.look.id == "warmPrint")
        let classic = try proposal(#"{"id":"warm"}"#).review(project, shared: shared).project
        #expect(ClipControlsProject.controls(for: "clip-2f1c", in: classic)?.look == .warm)
        #expect(ClipControlsProject.controls(for: "clip-2f1c", in: classic)?.colorGrade == nil)
        let refusal = #expect(throws: HarnessError.self) { try proposal(#"{"id":"neonDream"}"#).review(project, shared: shared) }
        #expect(refusal?.errorDescription == "Choose one of VoxClip's looks.")
    }

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
