import Foundation
import Testing
@testable import VoxClipCore

/// The planner's tone (prompt version 6, plan version 3; ai.md §16.3 and §16.5): the tone line each mode adds to a clip
/// instruction, and the plan's `tone` the validator keeps, repairs or drops. Shared vectors:
/// shared/fixtures/autopilot/plan-tone-cases.json. Nothing is sent.
@Suite struct ClipAutopilotToneTests {
    static func fixture() throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: FixtureLoader.data("fixtures/autopilot/plan-tone-cases.json"))
    }

    static func catalog() throws -> RewriteToneCatalog { try RewriteToneCatalog.load(shared: ClipAutopilotTests.shared()) }

    static func saved() throws -> [RewriteTone] {
        try fixture()[ai: "savedTones"].aiArray.map { item in
            RewriteTone(id: try #require(item[ai: "id"].aiString), title: try #require(item[ai: "title"].aiString),
                        instruction: try #require(item[ai: "instruction"].aiString))
        }
    }

    /// A vector's request tone: nil, Auto offering the catalogue, As I said it, or a fixed catalogue or saved tone.
    static func tone(_ value: JSONValue) throws -> ClipAutopilotTone? {
        guard value != .null else { return nil }
        let catalog = try catalog()
        switch value[ai: "mode"].aiString {
        case "auto": return .auto(offered: catalog.tones)
        case "as-said": return .asSaid
        case "fixed":
            let id = try #require(value[ai: "id"].aiString)
            return .fixed(try #require(catalog.tone(id, saved: try saved())))
        default: Issue.record("unknown tone mode"); return nil
        }
    }

    static func context(tone: ClipAutopilotTone?) throws -> ClipAutopilotContext {
        let base = try ClipAutopilotTests.context(scope: 0...29)
        return ClipAutopilotContext(words: base.words, corrections: base.corrections, cutWordIDs: base.cutWordIDs, pauses: base.pauses,
                                    cutPauseIDs: base.cutPauseIDs, scope: base.scope, styleIDs: base.styleIDs, fonts: base.fonts,
                                    preference: base.preference, prompt: base.prompt, tone: tone)
    }

    @Test func vectorsPinThePromptAndTheToneCatalog() throws {
        let shared = try ClipAutopilotTests.shared()
        let sources = try Self.fixture()[ai: "sources"]
        #expect(sources[ai: "shared/prompts/clip-autopilot.json"].aiString == (try ClipAutopilotPrompt(shared: shared)).sha256,
                "Update plan-tone-cases.json sources when the prompt changes")
        let tones = try VoiceLabLLMChecks.readPrompt(shared, RewriteToneCatalog.path)
        #expect(sources[ai: "shared/data/rewrite-tones.json"].aiString == tones.sha256, "Update plan-tone-cases.json when the tones change")
        #expect(try ClipAutopilotPrompt(shared: shared).promptVersion == 7)
        #expect(try Self.fixture()[ai: "cases"].aiArray.count == 11)
    }

    @Test(arguments: ["fixed-viral", "fixed-other-reply", "fixed-saved", "fixed-long-summary", "auto-picks", "auto-none", "auto-unknown",
                      "auto-saved-not-offered", "as-said", "as-said-none", "no-tone"])
    func planVectorsKeepRepairOrDropTheTone(_ id: String) throws {
        let vector = try #require(try Self.fixture()[ai: "cases"].aiArray.first { $0[ai: "id"].aiString == id })
        let plan = try #require(ClipAutopilotValidator.plan(vector[ai: "reply"], context: try Self.context(tone: try Self.tone(vector[ai: "tone"]))))
        #expect(plan.version == 3)
        let expect = vector[ai: "expect"]
        if expect[ai: "tone"] == .null {
            #expect(plan.tone == nil)
        } else {
            let parts = expect[ai: "tone"].aiArray.compactMap(\.aiString)
            #expect(plan.tone == .init(id: parts[0], title: parts[1], summary: parts[2]))
        }
        #expect(ClipAutopilotTests.repairs(plan.repairs) == ClipAutopilotTests.expected(expect[ai: "repairs"]))
        // The tone changes no other decision.
        #expect(plan.rewrites == [.init(startWord: 17, endWord: 23, text: "You still need to feed the plants", reason: "feed is the verb")])
    }

    @Test func eachModeEndsTheClipInstructionWithItsToneLine() throws {
        let shared = try ClipAutopilotTests.shared()
        let prompt = try ClipAutopilotPrompt(shared: shared)
        let transcript = try ClipAutopilotTests.transcript()
        let state = try EditState(transcript: transcript, edits: ProjectEdits(pauseThresholdSeconds: 1))
        let styles = try CaptionStyleLibrary(shared: shared).styles, fonts = try ClipAutopilotFonts.load(shared: shared)
        func render(_ tone: ClipAutopilotTone?) throws -> String {
            try ClipAutopilotRequestBuilder.render(ClipAutopilotRequest(transcript: transcript, edits: ProjectEdits(pauseThresholdSeconds: 1),
                                                                        mode: .clip(0...29), tone: tone),
                                                   prompt: prompt, styles: styles, fonts: fonts, pauses: state.pauses).instruction
        }
        let plain = try render(nil)
        #expect(!plain.contains("Tone:"))
        for vector in try Self.fixture()[ai: "instructions"].aiArray {
            let expected = try #require(vector[ai: "endsWith"].aiString)
            let rendered = try render(try Self.tone(vector[ai: "tone"]))
            #expect(rendered == plain + expected)
        }
        // A series' moments stage carries no tone line; its clip plans do (`clip(span)` keeps the tone).
        let series = ClipAutopilotRequest(transcript: transcript, mode: .series(nil), tone: .asSaid)
        #expect(!(try ClipAutopilotRequestBuilder.render(series, prompt: prompt, styles: styles, fonts: fonts, pauses: state.pauses).instruction.contains("Tone:")))
        #expect(series.clip(0...29).tone == .asSaid)
        // The system prompt names the tone rules and the schema asks for both fields.
        #expect(prompt.system.contains("Tone\n- The request gives the clip a tone"))
        let required = prompt.schema[ai: "required"].aiArray.compactMap(\.aiString)
        #expect(required.contains("tone") && required.contains("toneSummary"))
    }

    @Test func versionTwoPlansReadWithoutATone() throws {
        let first = try #require(try Self.fixture()[ai: "cases"].aiArray.first)
        let plan = try #require(ClipAutopilotValidator.plan(first[ai: "reply"], context: try Self.context(tone: .fixed(try Self.catalog().tones[0]))))
        #expect(plan.tone?.id == "viral-youtuber")
        let encoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(plan))
        guard case .object(var object) = encoded else { Issue.record("not an object"); return }
        #expect(try JSONDecoder().decode(ClipAutopilotPlan.self, from: JSONEncoder().encode(encoded)) == plan)
        object.removeValue(forKey: "tone")
        object["version"] = .number(2)
        let old = try JSONDecoder().decode(ClipAutopilotPlan.self, from: JSONEncoder().encode(JSONValue.object(object)))
        #expect(old.version == 3 && old.tone == nil && old.rewrites == plan.rewrites)
        object["version"] = .number(4)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(ClipAutopilotPlan.self, from: JSONEncoder().encode(JSONValue.object(object))) }
    }
}
