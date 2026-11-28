import Foundation
import Testing
@testable import VoxClipCore

/// The planner's look (looks spec 2026-11-28, sections 9.1–9.5): prompt version 14 lists the visible looks of
/// shared/looks/clip-looks.json, the reply's look, amount, fix and alternatives are checked against it, and plan version 5
/// keeps them. Shared vectors: shared/fixtures/autopilot/plan-look-cases.json, replayed by C# ClipAutopilotLookTests.
@Suite struct ClipAutopilotLookTests {
    static func fixture() throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: FixtureLoader.data("fixtures/autopilot/plan-look-cases.json"))
    }

    static func context(frames: JSONValue) throws -> ClipAutopilotContext {
        let shared = try ClipAutopilotTests.shared()
        let words = [TimedWord(id: "w0", text: "Hello.", kind: .word, start: 0, end: 0.5)]
        var sent: ClipAutopilotFrames?
        if frames != .null {
            let sheet = try frames.aiArray.enumerated().map { index, light in
                let measured: FrameLight? = light == .null ? nil : try JSONDecoder().decode(FrameLight.self, from: JSONEncoder().encode(light))
                return FrameSheetFrame(index: index + 1, observation: FrameObservation(time: Double(index), light: measured), jpeg: Data(),
                                       width: 320, height: 180)
            }
            sent = ClipAutopilotFrames(summary: "", images: [], blur: [], cover: [], frames: sheet, estimatedImageTokens: 0)
        }
        return ClipAutopilotContext(words: words, scope: 0...0, styleIDs: ["vox-bold"], fonts: [:], prompt: try ClipAutopilotPrompt(shared: shared),
                                    frames: sent)
    }

    @Test func thePromptListsExactlyTheVisibleLooks() throws {
        let shared = try ClipAutopilotTests.shared()
        let prompt = try ClipAutopilotPrompt(shared: shared)
        let library = try ClipLookLibrary.load(shared: shared)
        #expect(prompt.promptVersion == 14)
        #expect(prompt.looks.map(\.rawValue) == library.visible.map(\.id))
        let document = try JSONDecoder().decode(JSONValue.self, from: FixtureLoader.data(ClipAutopilotPrompt.path))
        #expect(document[ai: "schemaVersion"].aiInt == 3)
        for (item, look) in zip(document[ai: "looks"].aiArray, library.visible) {
            let line = try #require(item[ai: "line"].aiString)
            // The line is the look's own data, so the label/ID rule and the planner amount reach Claude as the pickers have them.
            #expect(line.hasPrefix("\(look.id): \(look.label) (") && line.contains(look.line) && line.hasSuffix("Start at \(look.plannerAmount)."))
            #expect(prompt.system.contains("\n- \(line)"), "\(look.id)")
        }
        #expect(prompt.system.contains("Use the frames' light notes") && !prompt.system.contains("You cannot see the footage"))
        #expect(prompt.system.contains("Never choose or describe a look by skin colour."))
        let required = Set(prompt.schema[ai: "required"].aiArray.compactMap(\.aiString))
        #expect(required.isSuperset(of: ["look", "lookAmount", "lookFix", "lookAlternatives", "lookReason"]))
    }

    @Test func aPromptWhoseLooksAreNotTheLibrarysRefusesToLoad() throws {
        let data = try FixtureLoader.data(ClipAutopilotPrompt.path)
        guard case .object(let root) = try JSONDecoder().decode(JSONValue.self, from: data) else { Issue.record("not an object"); return }
        let library = try ClipLookLibrary.load(shared: try ClipAutopilotTests.shared())
        #expect(throws: Never.self) { try ClipAutopilotPrompt(document: .object(root), sha256: "", looks: library) }
        var broken = root
        broken["looks"] = .array(root["looks"]!.aiArray.filter { $0[ai: "id"].aiString != "softSkin" })
        #expect(throws: VoxClipError.sharedResourcesMissing) { try ClipAutopilotPrompt(document: .object(broken), sha256: "", looks: library) }
        broken["looks"] = .array(root["looks"]!.aiArray + [.object(["id": .string("neonDream"), "line": .string("neonDream: Neon")])])
        #expect(throws: VoxClipError.sharedResourcesMissing) { try ClipAutopilotPrompt(document: .object(broken), sha256: "", looks: library) }
        broken = root
        broken["schemaVersion"] = .number(2)
        #expect(throws: VoxClipError.sharedResourcesMissing) { try ClipAutopilotPrompt(document: .object(broken), sha256: "", looks: library) }
    }

    @Test func theReplysLookReplays() throws {
        let fixture = try Self.fixture()
        let library = try ClipLookLibrary.load(shared: try ClipAutopilotTests.shared())
        #expect(fixture[ai: "sources"][ai: "shared/looks/clip-looks.json"].aiString
                == (try VoiceLabLLMChecks.readPrompt(try ClipAutopilotTests.shared(), ClipLookLibrary.path)).sha256)
        #expect(fixture[ai: "dimFaceLooks"].aiArray.compactMap(\.aiString) == ClipAutopilotValidator.dimFaceLooks.map(\.rawValue))
        #expect(fixture[ai: "dimFaceReplacement"].aiString == ClipAutopilotValidator.dimFaceReplacement.rawValue)
        let cases = fixture[ai: "cases"].aiArray
        #expect(cases.count == 23)
        for item in cases {
            let id = item[ai: "id"].aiString ?? ""
            var log = ClipAutopilotValidator.Log()
            let look = ClipAutopilotValidator.look(item[ai: "reply"], context: try Self.context(frames: item[ai: "frames"]), log: &log)
            let expect = item[ai: "expect"][ai: "look"]
            #expect(look.id.rawValue == expect[ai: "id"].aiString && look.amount == expect[ai: "amount"].aiInt, "\(id): \(look)")
            #expect(look.fix == expect[ai: "fix"].aiBool && look.reason == expect[ai: "reason"].aiString, "\(id): \(look)")
            #expect(look.alternatives.map(\.rawValue) == expect[ai: "alternatives"].aiArray.compactMap(\.aiString), "\(id): \(look)")
            #expect(library.look(look.id.rawValue) != nil, "\(id)")
            #expect(ClipAutopilotTests.repairs(log.repairs) == ClipAutopilotTests.expected(item[ai: "expect"][ai: "repairs"]), "\(id)")
        }
    }

    /// Plan version 5 keeps the look's amount, Fix and alternatives; a version 4 plan reads with the whole look, no Fix and no
    /// alternatives, and its four look IDs are looks of the library.
    @Test func aVersionFourPlanReadsWithTheWholeLook() throws {
        #expect(ClipAutopilotPlan.currentVersion == 5 && ClipAutopilotPlan.readableVersions == 1...5)
        let old = try JSONDecoder().decode(ClipAutopilotPlan.Look.self, from: Data(#"{"id":"warm","reason":"Friendly"}"#.utf8))
        #expect(old == ClipAutopilotPlan.Look(id: .warm, reason: "Friendly") && old.amount == 100 && !old.fix && old.alternatives.isEmpty)
        let library = try ClipLookLibrary.load(shared: try ClipAutopilotTests.shared())
        for id in ClipLook.allCases { #expect(library.look(ClipAutopilotPlan.LookPresetID(id).rawValue)?.base == id) }
        let new = ClipAutopilotPlan.Look(id: "warmPrint", amount: 70, fix: true, alternatives: ["goldenHour"], reason: "Memories")
        let encoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(new))
        #expect(encoded == .object(["id": .string("warmPrint"), "amount": .number(70), "fix": .bool(true),
                                    "alternatives": .array([.string("goldenHour")]), "reason": .string("Memories")]))
        #expect(try JSONDecoder().decode(ClipAutopilotPlan.Look.self, from: JSONEncoder().encode(new)) == new)
        // The whole look with no Fix writes only what version 4 wrote.
        #expect(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(old)) == .object(["id": .string("warm"), "reason": .string("Friendly")]))
    }
}
