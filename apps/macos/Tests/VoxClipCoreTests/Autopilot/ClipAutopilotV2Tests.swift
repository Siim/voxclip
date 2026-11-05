import Foundation
import Synchronization
import Testing
@testable import VoxClipCore

/// The planner's version 2 contract (ai.md §16): corrections, look, speed, fixed caption choices, the finished length and
/// its flags, the moments stage, ranking, and the two-stage service with parallel clip plans. Shared vectors:
/// shared/fixtures/autopilot/plan-v2-cases.json. Every connector is a stub; nothing waits on a clock.
@Suite struct ClipAutopilotV2Tests {
    static func fixture() throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: FixtureLoader.data("fixtures/autopilot/plan-v2-cases.json"))
    }

    static func transcript() throws -> Transcript {
        let words = try fixture()[ai: "transcript"][ai: "words"].aiArray.map { item in
            TimedWord(id: try #require(item[ai: "id"].aiString), text: try #require(item[ai: "text"].aiString), kind: .word,
                      start: try #require(item[ai: "start"].aiDouble), end: try #require(item[ai: "end"].aiDouble))
        }
        return Transcript(words: words, language: "en", durationSeconds: 75, engine: EngineRef(id: .whispercpp, engineVersion: "fixture"),
                          verbatim: false, refined: false, rawKey: String(repeating: "0", count: 64), createdAt: Date(timeIntervalSince1970: 0))
    }

    static func preference(_ value: JSONValue) -> ClipAutopilotCaptionPreference? {
        guard value != .null else { return nil }
        let font = value[ai: "fontFamily"].aiString.map { ClipAutopilotPlan.Font(family: $0, weight: value[ai: "fontWeight"].aiInt ?? 0) }
        return .init(styleId: value[ai: "styleId"].aiString, font: font, textCase: value[ai: "case"].aiString.flatMap(ClipAutopilotPlan.CaptionCase.init))
    }

    static func context(scope: ClosedRange<Int>, preference: ClipAutopilotCaptionPreference? = nil) throws -> ClipAutopilotContext {
        let shared = try ClipAutopilotTests.shared()
        let transcript = try transcript()
        let edits = ProjectEdits(pauseThresholdSeconds: 1)
        return ClipAutopilotContext(words: transcript.words, pauses: try EditState(transcript: transcript, edits: edits).pauses,
            pauseKeepSeconds: edits.pauseKeepSeconds, scope: scope, styleIDs: Set(try CaptionStyleLibrary(shared: shared).styles.map(\.id)),
            fonts: try ClipAutopilotFonts.load(shared: shared), preference: preference, prompt: try ClipAutopilotPrompt(shared: shared))
    }

    static func vector(_ id: String) throws -> JSONValue {
        try #require(try fixture()[ai: "cases"].aiArray.first { $0[ai: "id"].aiString == id })
    }

    // MARK: Shared vectors

    @Test func vectorsPinTheCurrentPrompt() throws {
        let prompt = try ClipAutopilotPrompt(shared: ClipAutopilotTests.shared())
        #expect(try Self.fixture()[ai: "sources"][ai: "shared/prompts/clip-autopilot.json"].aiString == prompt.sha256,
                "Update plan-v2-cases.json sources when the prompt changes")
    }

    @Test(arguments: ["corrections", "speed-clamped-bw", "speed-slow-clamped", "speed-unreadable-unknown-look", "v3-reply-without-new-fields",
                      "over-length", "long-without-reason", "long-with-reason", "speed-brings-it-in", "cuts-bring-it-in", "fixed-style",
                      "fixed-font-and-case"])
    func planVectorsRepairDropAndFlag(_ id: String) throws {
        let vector = try Self.vector(id)
        let context = try Self.context(scope: try ClipAutopilotTests.range(vector[ai: "scope"]), preference: Self.preference(vector[ai: "preference"]))
        let plan = try #require(ClipAutopilotValidator.plan(vector[ai: "reply"], context: context))
        let expect = vector[ai: "expect"]
        #expect(plan.version == 2)
        #expect(plan.startWord...plan.endWord == (try ClipAutopilotTests.range(expect[ai: "span"])))
        let corrections: [[String]] = plan.corrections.map { [String($0.word), $0.heard, $0.text] }
        #expect(corrections == expect[ai: "corrections"].aiArray.map { $0.aiArray.map { $0.aiString ?? String($0.aiInt ?? -1) } })
        let rewrites: [[String]] = plan.rewrites.map { [String($0.startWord), String($0.endWord), $0.text] }
        #expect(rewrites == expect[ai: "rewrites"].aiArray.map { $0.aiArray.map { $0.aiString ?? String($0.aiInt ?? -1) } })
        let cuts: [[String]] = plan.cuts.map { [String($0.startWord), String($0.endWord), $0.kind.rawValue] }
        #expect(cuts == expect[ai: "cuts"].aiArray.map { $0.aiArray.map { $0.aiString ?? String($0.aiInt ?? -1) } })
        let captions = expect[ai: "captions"]
        #expect(plan.captions == .init(styleId: captions[ai: "styleId"].aiString ?? "",
            font: .init(family: captions[ai: "family"].aiString ?? "", weight: captions[ai: "weight"].aiInt ?? 0),
            textCase: ClipAutopilotPlan.CaptionCase(rawValue: captions[ai: "case"].aiString ?? "") ?? .upper,
            wordsPerCaption: captions[ai: "wordsPerCaption"].aiInt ?? 0, reason: captions[ai: "reason"].aiString ?? ""))
        #expect([plan.look.id.rawValue, plan.look.reason] == expect[ai: "look"].aiArray.compactMap(\.aiString))
        if expect[ai: "speed"] == .null {
            #expect(plan.speed == nil)
        } else {
            #expect(plan.speed == .init(rate: expect[ai: "speed"].aiArray[0].aiDouble ?? 0, reason: expect[ai: "speed"].aiArray[1].aiString ?? ""))
        }
        #expect(abs(plan.seconds - (expect[ai: "seconds"].aiDouble ?? -1)) < 1e-9)
        #expect(plan.flags.map(\.kind.rawValue) == expect[ai: "flags"].aiArray.compactMap(\.aiString))
        #expect(ClipAutopilotTests.repairs(plan.repairs) == ClipAutopilotTests.expected(expect[ai: "repairs"]))
    }

    @Test(arguments: ["moments", "moments-fixed-style"])
    func momentVectorsKeepTheStrongestSpans(_ id: String) throws {
        let vector = try Self.vector(id)
        let context = try Self.context(scope: try ClipAutopilotTests.range(vector[ai: "scope"]), preference: Self.preference(vector[ai: "preference"]))
        let checked = ClipAutopilotValidator.moments(vector[ai: "reply"], context: context)
        let expect = vector[ai: "expect"]
        let moments: [[String]] = checked.moments.map { [String($0.startWord), String($0.endWord), $0.verdict.rawValue, $0.captionStyle] }
        #expect(moments == expect[ai: "moments"].aiArray.map { $0.aiArray.map { $0.aiString ?? String($0.aiInt ?? -1) } })
        #expect(checked.moments.map(\.score) == expect[ai: "scores"].aiArray.compactMap(\.aiInt))
        #expect(ClipAutopilotTests.repairs(checked.repairs) == ClipAutopilotTests.expected(expect[ai: "repairs"]))
    }

    // MARK: Contract

    @Test func aVersionOnePlanStillReadsAndIsUpgraded() throws {
        let plan = try #require(ClipAutopilotValidator.plan(try Self.vector("corrections")[ai: "reply"], context: try Self.context(scope: 0...29)))
        let encoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(plan))
        guard case .object(var object) = encoded, case .object(var captions) = object["captions"]! else { Issue.record("not an object"); return }
        for key in ["corrections", "look", "speed", "lengthReason", "seconds", "flags"] { object.removeValue(forKey: key) }
        captions.removeValue(forKey: "reason")
        object["captions"] = .object(captions)
        object["version"] = .number(1)
        let old = try JSONDecoder().decode(ClipAutopilotPlan.self, from: JSONEncoder().encode(JSONValue.object(object)))
        #expect(old.version == 2 && old.corrections.isEmpty && old.look == .original && old.speed == nil && old.seconds == 0 && old.flags.isEmpty)
        #expect(old.captions.reason.isEmpty && old.cuts == plan.cuts && old.rewrites == plan.rewrites)
        object["version"] = .number(3)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(ClipAutopilotPlan.self, from: JSONEncoder().encode(JSONValue.object(object))) }
        let series = ClipAutopilotSeries(plans: [plan], moments: [.init(startWord: 0, endWord: 29, title: "T", idea: "I", score: 7, verdict: .post,
                                                                         captionStyle: "karaoke")])
        #expect(try JSONDecoder().decode(ClipAutopilotSeries.self, from: JSONEncoder().encode(series)) == series)
    }

    @Test func correctionsMapToTheCorrectCommandAndLookAndSpeedStayPending() throws {
        guard case .object(var reply) = try ClipAutopilotTests.reply("valid-clip") else { Issue.record("not an object"); return }
        reply["corrections"] = .array([.object(["word": .number(13), "heard": .string("sleep"), "text": .string("Sleep"), "reason": .string("name")])])
        reply["look"] = .string("warm"); reply["lookReason"] = .string("a human moment")
        reply["speed"] = .number(1.2); reply["speedReason"] = .string("drags")
        let plan = try #require(ClipAutopilotValidator.plan(.object(reply), context: try ClipAutopilotTests.context(scope: 0...29)))
        let project = try ClipAutopilotTests.project()
        let operations = try ClipAutopilotMapping.operations(for: plan, clipID: "c1", project: project,
                                                             fonts: try ClipAutopilotFonts.load(shared: ClipAutopilotTests.shared()))
        #expect(Array(operations.map(\.id).prefix(3)) == ["title", "correction-0", "cut-0"])
        #expect(operations[1].action == .edit(.correct(id: "w13", text: "Sleep")) && operations[1].reason == "name")
        let look = try #require(operations.first { $0.decision == .look })
        #expect(look.action == .look(clipID: "c1", look: .init(id: .warm, reason: "a human moment")) && look.reason == "a human moment")
        let speed = try #require(operations.first { $0.decision == .speed })
        #expect(speed.action == .speed(clipID: "c1", speed: .init(rate: 1.2, reason: "drags")))
        let (applied, pending) = try ClipAutopilotMapping.apply(operations, to: project)
        #expect(applied.edits.corrections == ["w13": "Sleep"])
        #expect(pending.map(\.decision) == [.rewrite, .look, .speed, .music, .hook])
        try ProjectValidation.validateModel(applied)
        // 9.75 s edited (ClipAutopilotTests.editedLengthTakesOffCutsAndTightenedPauses) at 1.2.
        let state = try EditState(transcript: try ClipAutopilotTests.transcript(), edits: ProjectEdits(pauseThresholdSeconds: 1))
        #expect(abs(ClipAutopilotMapping.finalSeconds(plan, state: state) - 9.75 / 1.2) < 1e-9 && abs(plan.seconds - 9.75 / 1.2) < 1e-9)
    }

    @Test func aSeriesRanksByScoreAndKeepsOnePostFirst() throws {
        let base = try #require(ClipAutopilotValidator.plan(try Self.vector("corrections")[ai: "reply"], context: try Self.context(scope: 0...29)))
        func plan(_ start: Int, _ score: Int, _ verdict: ClipAutopilotPlan.Verdict) -> ClipAutopilotPlan {
            var plan = base; plan.startWord = start; plan.endWord = start + 9; plan.score = score; plan.verdict = verdict; plan.repairs = []
            return plan
        }
        let series = ClipAutopilotValidator.series([plan(0, 6, .casualPost), plan(10, 9, .postFirst), nil, plan(30, 9, .postFirst)], moments: [],
                                                   failures: [2: "the plan failed: timeout"], repairs: [])
        #expect(series.plans.map(\.startWord) == [10, 30, 0])
        #expect(series.plans.map(\.verdict) == [.postFirst, .post, .casualPost])
        #expect(series.plans[1].repairs == [.init(field: "verdict", action: .repaired, detail: "another clip posts first; post")])
        #expect(series.repairs == [.init(field: "plans[2]", action: .dropped, detail: "the plan failed: timeout")])
    }

    // MARK: Requests

    @Test func aLongClipIsToldHowMuchToCutAndAFontOnlyPreferenceFixesOnlyTheFont() async throws {
        let service = ClipAutopilotService(runner: try ClipAutopilotTests.runner(), shared: try ClipAutopilotTests.shared())
        let input = ClipAutopilotRequest(transcript: try Self.transcript(), edits: ProjectEdits(pauseThresholdSeconds: 1), mode: .clip(0...149),
                                         captionPreference: .init(font: .init(family: "Roboto", weight: 900)))
        let request = try await service.request(input, connector: .claudeCode)
        #expect(request.instruction.hasPrefix("Plan the clip from word 0 to word 149 as one finished, postable short. As recorded it runs 75.0 s; "
            + "with its fillers and pauses cut, about 75.0 s. Land it at 20–45 s after all your cuts, so cut about 30 s more: tangents"))
        #expect(request.cachedBlock?.contains("\nCaption preference: font Roboto weight 900. The creator fixed these, so use them exactly and choose the rest per clip.\n") == true)
        #expect(request.effort == .xhigh && request.schemaName == "clip_autopilot_plan" && request.tag == "clip-autopilot")
    }

    // MARK: Two-stage service

    static func momentsReply(_ spans: [(Int, Int, String)]) throws -> String {
        try JSONValue.object(["clips": .array(spans.enumerated().map { index, span in
            .object(["startWord": .number(Double(span.0)), "endWord": .number(Double(span.1)), "title": .string("Moment \(index + 1)"),
                     "idea": .string("Idea \(index + 1)."), "captionStyle": .string(span.2), "captionReason": .string("fits \(index + 1)"),
                     "score": .number(Double(8 - index)), "verdict": .string(index == 0 ? "postFirst" : "post"), "scoreReason": .string("")])
        })]).aiCompact()
    }

    /// A clip plan for whatever span the request names, scored by `score(start)`.
    static func planReply(_ request: LLMRequest, score: (Int) -> Int = { 10 - $0 / 30 }) throws -> String {
        let match = try #require(request.instruction.firstMatch(of: #/Plan the clip from word (\d+) to word (\d+)/#))
        let start = try #require(Int(match.1)), end = try #require(Int(match.2))
        guard case .object(var reply) = try vector("long-with-reason")[ai: "reply"] else { throw VoiceLabError.invalidInput }
        reply["startWord"] = .number(Double(start)); reply["endWord"] = .number(Double(end))
        reply["score"] = .number(Double(score(start))); reply["verdict"] = .string("postFirst")
        return try JSONValue.object(reply).aiCompact()
    }

    @Test(.timeLimit(.minutes(1)))
    func aSeriesPicksMomentsThenPlansThreeAtOnce() async throws {
        let gate = PlanGate(needed: 3)
        let moments = try Self.momentsReply([(0, 29, "karaoke"), (30, 59, "outline"), (60, 89, "pill"), (90, 119, "karaoke")])
        let reply: @Sendable (LLMRequest) throws -> String = { request in
            request.schemaName == "clip_autopilot_moments" ? moments : try Self.planReply(request)
        }
        let main = PlanStub(gate: gate, reply: reply), lanes = [PlanStub(gate: gate, reply: reply), PlanStub(gate: gate, reply: reply),
                                                                 PlanStub(gate: gate, reply: reply)]
        let log = ProgressLog()
        let service = ClipAutopilotService(runner: try ClipAutopilotTests.runner(), shared: try ClipAutopilotTests.shared())
        let input = ClipAutopilotRequest(transcript: try Self.transcript(), edits: ProjectEdits(pauseThresholdSeconds: 1), mode: .series(nil))
        let result = try await service.plan(input, connector: main, model: "fixture", lanes: lanes, progress: { log.add($0) })
        #expect(await gate.maxInFlight == 3)
        // The fourth lane is never used: at most three plans at once.
        #expect(await lanes[2].requests.isEmpty)
        var sent = await main.requests
        #expect(sent.first?.schemaName == "clip_autopilot_moments" && sent.first?.effort == .high)
        sent = Array(sent.dropFirst())
        for lane in lanes { sent += await lane.requests }
        #expect(sent.count == 4 && sent.allSatisfy { $0.effort == .xhigh && $0.schemaName == "clip_autopilot_plan" && $0.tag == "clip-autopilot-series-clip" })
        let first = try #require(sent.first { $0.instruction.contains("from word 0 to word 29") })
        #expect(first.instruction.hasPrefix("This clip is moment 1 of 4 picked from a longer video for a series: “Moment 1”. Idea 1.\n"
            + "Caption style picked for it: karaoke (fits 1). The other clips use: outline, pill, karaoke. Keep it unless it clearly does not suit this clip.\n\n"
            + "Plan the clip from word 0 to word 29 as one finished, postable short."))
        // Its words only: the clip's own transcript lines.
        #expect(first.cachedBlock?.contains("[29]anyway.") == true && first.cachedBlock?.contains("[30]") == false)
        #expect(result.series.moments.map(\.startWord) == [0, 30, 60, 90])
        #expect(result.series.plans.map(\.startWord) == [0, 30, 60, 90])
        #expect(result.series.plans.map(\.verdict) == [.postFirst, .post, .post, .post])
        let events = log.events
        #expect(events.first == .pickingMoments)
        if case .picked(let picked) = events.dropFirst().first { #expect(picked.count == 4) } else { Issue.record("no picked event") }
        let later = Array(events.dropFirst(2))
        #expect(later.count == 8)
        for clip in 0..<4 {
            let planning = try #require(later.firstIndex(of: .planning(clip: clip, of: 4)))
            let planned = try #require(later.firstIndex(of: .planned(clip: clip, of: 4)))
            #expect(planning < planned)
        }
    }

    @Test func aFailedClipPlanIsLeftOutAndEveryFailureFailsTheRun() async throws {
        let moments = try Self.momentsReply([(0, 29, "karaoke"), (30, 59, "outline")])
        let one = PlanStub(gate: nil) { request in
            if request.schemaName == "clip_autopilot_moments" { return moments }
            if request.instruction.contains("from word 30 to") { throw LLMError.timeout }
            return try Self.planReply(request)
        }
        let log = ProgressLog()
        let service = ClipAutopilotService(runner: try ClipAutopilotTests.runner(), shared: try ClipAutopilotTests.shared())
        let input = ClipAutopilotRequest(transcript: try Self.transcript(), edits: ProjectEdits(pauseThresholdSeconds: 1), mode: .series(nil))
        let result = try await service.plan(input, connector: one, model: "fixture", progress: { log.add($0) })
        #expect(result.series.plans.map(\.startWord) == [0])
        #expect(result.series.repairs == [.init(field: "plans[1]", action: .dropped, detail: "the plan failed: timeout")])
        #expect(log.events.contains(.failed(clip: 1, of: 2)))
        let none = PlanStub(gate: nil) { request in
            if request.schemaName == "clip_autopilot_moments" { return moments }
            throw LLMError.timeout
        }
        await #expect(throws: LLMError.timeout) { try await service.plan(input, connector: none, model: "fixture") }
        let empty = PlanStub(gate: nil) { _ in #"{"clips":[]}"# }
        let nothing = try await service.plan(input, connector: empty, model: "fixture")
        #expect(nothing.series.plans.isEmpty && nothing.series.moments.isEmpty)
    }

    @Test func clipsSkipTheMomentsStageAndRankByScore() async throws {
        let stub = PlanStub(gate: nil) { try Self.planReply($0, score: { $0 == 0 ? 5 : 8 }) }
        let service = ClipAutopilotService(runner: try ClipAutopilotTests.runner(), shared: try ClipAutopilotTests.shared())
        let input = ClipAutopilotRequest(transcript: try Self.transcript(), edits: ProjectEdits(pauseThresholdSeconds: 1), mode: .clips([0...29, 30...59]))
        let result = try await service.plan(input, connector: stub, model: "fixture")
        let sent = await stub.requests
        #expect(sent.map(\.schemaName) == ["clip_autopilot_plan", "clip_autopilot_plan"])
        #expect(sent.allSatisfy { $0.tag == "clip-autopilot" && $0.instruction.hasPrefix("Plan the clip from word ") })
        #expect(result.series.plans.map(\.startWord) == [30, 0] && result.series.plans.map(\.verdict) == [.postFirst, .post])
        #expect(result.series.moments.isEmpty)
        await #expect(throws: VoiceLabError.invalidInput) {
            try await service.plan(input, connector: stub, model: "fixture", lanes: [OtherConnectorStub()])
        }
        await #expect(throws: VoiceLabError.invalidInput) {
            try await service.plan(ClipAutopilotRequest(transcript: try Self.transcript(), mode: .clips([])), connector: stub, model: "fixture")
        }
    }
}

/// Holds clip-plan sends until `needed` have arrived, so a test proves that many run at once; records the most in flight.
private actor PlanGate {
    let needed: Int
    private var arrived = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private(set) var inFlight = 0
    private(set) var maxInFlight = 0
    init(needed: Int) { self.needed = needed }
    func enter() async {
        inFlight += 1; maxInFlight = max(maxInFlight, inFlight); arrived += 1
        if arrived >= needed {
            let ready = waiting
            waiting = []
            for continuation in ready { continuation.resume() }
        } else {
            await withCheckedContinuation { waiting.append($0) }
        }
    }
    func leave() { inFlight -= 1 }
}

private actor PlanStub: LLMConnector {
    nonisolated let id = ConnectorID.ollama
    private let gate: PlanGate?
    private let reply: @Sendable (LLMRequest) throws -> String
    private(set) var requests: [LLMRequest] = []
    init(gate: PlanGate?, reply: @escaping @Sendable (LLMRequest) throws -> String) { self.gate = gate; self.reply = reply }
    func status() -> ConnectorStatus { .ready }
    func models(refresh: Bool) -> [LLMModel] { [.init(id: "fixture", name: "Fixture", contextTokens: 256_000, source: .curated)] }
    func contextTokens(model: String) -> Int? { 256_000 }
    func send(_ request: LLMRequest, model: String) async throws -> RawCompletion {
        requests.append(request)
        let gated = request.schemaName == "clip_autopilot_plan" ? gate : nil
        await gated?.enter()
        let text: String
        do { text = try reply(request) } catch { await gated?.leave(); throw error }
        await gated?.leave()
        return RawCompletion(text: text, model: model, stop: .complete)
    }
}

private actor OtherConnectorStub: LLMConnector {
    nonisolated let id = ConnectorID.lmstudio
    func status() -> ConnectorStatus { .ready }
    func models(refresh: Bool) -> [LLMModel] { [] }
    func contextTokens(model: String) -> Int? { nil }
    func send(_ request: LLMRequest, model: String) -> RawCompletion { RawCompletion(text: "", model: model, stop: .complete) }
}

private final class ProgressLog: Sendable {
    private let store = Mutex<[ClipAutopilotProgress]>([])
    func add(_ event: ClipAutopilotProgress) { store.withLock { $0.append(event) } }
    var events: [ClipAutopilotProgress] { store.withLock { $0 } }
}
