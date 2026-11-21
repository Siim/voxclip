import Foundation
import Testing
@testable import VoxClipCore

@Suite struct ClipAutopilotMotionTests {
    private func zoom(_ word: Int, _ untilWord: Int, direction: String = "zoomIn", scale: Double = 1.12,
                      reason: String = "Emphasize the main point") -> JSONValue {
        .object(["word": .number(Double(word)), "untilWord": .number(Double(untilWord)),
                 "direction": .string(direction), "scale": .number(scale), "reason": .string(reason)])
    }

    private func plan(_ zooms: [JSONValue], edits: ProjectEdits = ProjectEdits(pauseThresholdSeconds: 1)) throws -> ClipAutopilotPlan {
        let context = try ClipAutopilotTests.context(scope: 0...29, edits: edits)
        return try #require(ClipAutopilotValidator.plan(.object(["startWord": .number(0), "endWord": .number(29),
                                                                "zooms": .array(zooms)]), context: context))
    }

    @Test func canonicalRepliesKeepLegacyZoomsWhileCodexRequiresDirections() throws {
        let prompt = try ClipAutopilotPrompt(shared: ClipAutopilotTests.shared())
        let strict = CanonicalResponseParser.strictSchema(prompt.schema)
        let item = strict[ai: "properties"][ai: "zooms"][ai: "items"]
        #expect(item[ai: "additionalProperties"].aiBool == false)
        #expect(Set(item[ai: "required"].aiArray.compactMap(\.aiString)) == Set(item[ai: "properties"].aiObject?.keys.map { $0 } ?? []))
        #expect(item[ai: "properties"][ai: "direction"][ai: "enum"].aiArray.compactMap(\.aiString) == ["zoomIn", "zoomOut"])
        #expect(prompt.system.contains("Leave the framing alone") && !prompt.momentsSystem.contains("zoomOut"))

        let legacy = try ClipAutopilotTests.sendable(ClipAutopilotTests.reply("valid-clip"))
        let parsed = try CanonicalResponseParser.validate(RawCompletion(object: legacy, model: "fixture", stop: .complete), schema: prompt.schema)
        let validated = try #require(ClipAutopilotValidator.plan(parsed.object, context: ClipAutopilotTests.context(scope: 0...29)))
        let oldZoom = try #require(validated.zooms.first)
        #expect(oldZoom.direction == nil && oldZoom.scale == 1.2)
        let encoded = try JSONEncoder().encode(validated)
        #expect(try JSONDecoder().decode(ClipAutopilotPlan.self, from: encoded) == validated)
        #expect(try JSONDecoder().decode(JSONValue.self, from: encoded)[ai: "zooms"].aiArray.first?.aiObject?["direction"] == nil)
    }

    @Test func directionalCuesRejectInvalidAndCrowdedPhraseRangesWithoutMovingThem() throws {
        let edits = ProjectEdits(pauseThresholdSeconds: 1, cutWordIds: ["w9"], cutPauseIds: ["pause-after-w6"])
        let result = try plan([
            zoom(2, 6), zoom(13, 15), zoom(21, 26, direction: "zoomOut", reason: "Release on the explanation"),
            zoom(27, 99), zoom(28, 27), zoom(13, 16), zoom(7, 10), zoom(5, 8), zoom(27, 27),
            zoom(27, 29, direction: "pan"), zoom(27, 29, scale: 1.35), zoom(27, 29, reason: " "), zoom(2, 26),
        ], edits: edits)
        #expect(result.zooms.map(\.word) == [2, 21])
        #expect(result.zooms.map(\.untilWord) == [6, 26])
        #expect(result.zooms.compactMap(\.direction) == [.zoomIn, .zoomOut])
        #expect(result.repairs.filter { $0.field.hasPrefix("zooms[") && $0.action == .dropped }.count == 11)
    }

    @Test func mapsRealPhrasesToPersistedCurvesAndReducedMotionUsesIdentity() throws {
        var project = try ClipAutopilotTests.project()
        project.edits.corrections["w3"] = "main"
        var plan = try plan([zoom(2, 6), zoom(21, 26, direction: "zoomOut", reason: "Release after the example")])
        plan.zooms.append(.init(word: -1, untilWord: 100, scale: 1.12, reason: "Bad saved range", direction: .zoomIn))
        let operations = try ClipAutopilotMapping.operations(for: plan, clipID: "c1", project: project, fonts: [:])
        let zooms = operations.filter { $0.decision == .zoom }
        #expect(zooms.map(\.reason) == ["“the main idea is simple.” · Emphasize the main point",
                                       "“water the plants one by one.” · Release after the example"])
        let (applied, pending) = try ClipAutopilotMapping.apply(operations, to: project)
        let cues = applied.motionCues
        #expect(pending.isEmpty && cues.map(\.id) == ["c1-zoom-2-6", "c1-zoom-21-26"])
        let incoming = try #require(cues.first), outgoing = try #require(cues.last)
        #expect(incoming.sourceStart == 0.6 && incoming.sourceEnd == 1.9)
        #expect(outgoing.sourceStart == 7.4 && outgoing.sourceEnd == 8.9)
        #expect(incoming.keyframes.map(\.scale) == [1, 1.12, 1.12, 1])
        #expect(outgoing.keyframes.map(\.scale) == [1.12, 1.12, 1])
        #expect(MotionCue.transform(atSourceTime: 7.5, clipID: "c1", cues: cues).scale == 1.12)
        #expect(MotionCue.transform(atSourceTime: 7.5, clipID: "c1", cues: cues, reduceMotion: true) == .identity)
        #expect(try JSONProjectStore.decode(JSONProjectStore.encode(applied)).motionCues == cues)
    }

    @Test func applyPreservesManualCuesAndChecksCurrentClipBoundsAndCuts() throws {
        let original = try ClipAutopilotTests.project()
        let manual = MotionCue(id: "creator", clipID: "c1", sourceStart: 0.7, sourceEnd: 1.1)
        let project = try ContextDemoProject.settingMotionCues([manual], in: original)
        let overlap = MotionCue(id: "planner", clipID: "c1", sourceStart: 0.6, sourceEnd: 1.9)
        let sameID = MotionCue(id: manual.id, clipID: "c1", sourceStart: 7.4, sourceEnd: 8.9)
        let badRange = MotionCue(id: "tail", clipID: "c1", sourceStart: 11.4, sourceEnd: 11.8)
        #expect(ClipAutopilotMapping.addingMotionCue(sameID, to: project) == nil)
        #expect(ClipAutopilotMapping.addingMotionCue(badRange, to: project) == nil)
        let operation = ClipAutopilotOperation(id: "zoom-0", decision: .zoom, action: .motion(overlap), reason: "Main point")
        let applied = try ClipAutopilotMapping.apply([operation], to: project)
        #expect(applied.project.motionCues == [manual] && applied.pending == [operation])
        var cutProject = original
        cutProject.edits.cutWordIds = ["w4"]
        #expect(ClipAutopilotMapping.addingMotionCue(overlap, to: cutProject) == nil)
    }
}
