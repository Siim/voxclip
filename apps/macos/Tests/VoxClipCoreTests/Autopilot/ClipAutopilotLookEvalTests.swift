import Foundation
import Testing
@testable import VoxClipCore

/// The planner look's evaluation (looks spec 2026-11-28 §11.6) on placeholder clips: made-up transcripts with made-up
/// measured light, no footage and no person. The checks:
/// - business and education talks pick a Natural look (As filmed is one, as in the pickers);
/// - a screen demo picks As filmed;
/// - a dim test-card face never ends in Moody or Teal & Amber;
/// - no reason mentions skin colour;
/// - a series shares one look and amount (the Fix is per clip).
///
/// Offline, stub replies run through the planner's whole send path to check the checker; nothing is sent. The live run is
/// opt-in (VOXCLIP_LOOK_LIVE_EVAL=1 and a Claude Code plan sign-in, never an API key) and writes its replies under
/// /tmp/voxclip-autopilot-eval/. The prompt and the validator vectors are shared, so one platform's run covers both.
enum ClipLookEval {
    enum Kind: String, Sendable, CaseIterable { case business, education, screenDemo, dimFace, series }

    struct Case: Sendable {
        let kind: Kind
        /// One line per clip; a series has three.
        let clips: [String]
        let light: FrameLight
        let screen: Bool
    }

    static let lit = FrameLight(medianLuma: 0.48, p95Luma: 0.9, faceMeanLuma: 0.52, faceMedianLuma: 0.5, faceClippedShare: 0,
                                neutralMeans: [0.5, 0.49, 0.48], meanChroma: 0.12)
    /// A dim face on a grey test card: "face a little dark".
    static let dim = FrameLight(medianLuma: 0.18, p95Luma: 0.6, faceMeanLuma: 0.22, faceMedianLuma: 0.2, faceClippedShare: 0,
                                neutralMeans: [0.3, 0.29, 0.28], meanChroma: 0.1)
    /// A screen recording: bright, grey, "low color", no face.
    static let screen = FrameLight(medianLuma: 0.72, p95Luma: 0.97, neutralMeans: [0.8, 0.8, 0.8], meanChroma: 0.05)

    static let cases: [Case] = [
        Case(kind: .business, clips: ["Our quarterly numbers are in. Revenue grew twelve percent because we focused on three customers instead of thirty. "
            + "Here is what we changed in sales, what it cost, and what the team will do next quarter."], light: lit, screen: false),
        Case(kind: .education, clips: ["Photosynthesis turns light into sugar. The leaf takes in carbon dioxide and water. Chlorophyll absorbs red and "
            + "blue light, which is why leaves look green. Let us walk through the two stages one at a time."], light: lit, screen: false),
        Case(kind: .screenDemo, clips: ["Open the settings panel and click the blue Export button. Pick the vertical size, then choose the folder. "
            + "The progress bar fills as the file renders, and the brand colours stay exactly as they are on screen."], light: screen, screen: true),
        Case(kind: .dimFace, clips: ["I never told anyone this. The night the shop closed I sat in the dark car for an hour. I thought it was over. "
            + "It was not. Here is what happened the next morning, and why I still keep that key."], light: dim, screen: false),
        Case(kind: .series, clips: ["Day one in the mountains. We left before sunrise and the trail was still frozen. By noon the valley opened up "
            + "and we could see the lake.", "Day two was harder. Rain all morning, wet boots, and a bridge that was not on the map. We crossed it "
            + "anyway and found the hut by dark.", "Day three we reached the top. Clear sky, wind, and the whole range in front of us. Worth every "
            + "step, and here is the one thing I would pack differently."], light: lit, screen: false),
    ]

    static func words(_ eval: Case) -> [TimedWord] {
        eval.clips.joined(separator: " ").split(separator: " ").enumerated().map { index, text in
            TimedWord(id: "w\(index)", text: String(text), kind: .word, start: Double(index) * 0.4, end: Double(index) * 0.4 + 0.35)
        }
    }

    static func spans(_ eval: Case) -> [ClosedRange<Int>] {
        var start = 0
        return eval.clips.map { clip in
            let count = clip.split(separator: " ").count
            defer { start += count }
            return start...(start + count - 1)
        }
    }

    static func request(_ eval: Case) -> ClipAutopilotRequest {
        let words = words(eval)
        let transcript = Transcript(words: words, language: "en", durationSeconds: (words.last?.end ?? 0) + 1,
                                    engine: EngineRef(id: .whispercpp, engineVersion: "placeholder"), verbatim: false, refined: false,
                                    rawKey: String(repeating: "0", count: 64), createdAt: Date(timeIntervalSince1970: 0))
        let spans = spans(eval)
        guard eval.kind == .series else { return ClipAutopilotRequest(transcript: transcript, mode: .clip(spans[0])) }
        let moments = spans.enumerated().map { index, span in
            ClipAutopilotMoment(startWord: span.lowerBound, endWord: span.upperBound, title: "Day \(index + 1)", idea: "A day of the trip.",
                                score: 8 - index, verdict: index == 0 ? .postFirst : .post, captionStyle: "karaoke")
        }
        return ClipAutopilotRequest(transcript: transcript, mode: .clips(spans), moments: moments)
    }

    /// Four sheet frames over each clip, all with the case's light; text only (the light line, no pictures).
    static func frames(_ eval: Case, light: ClipColorMeasure.Light) -> ClipAutopilotFrameSource {
        let words = words(eval)
        return { _, span in
            let start = words[span.lowerBound].start, end = words[span.upperBound].end
            let frames = (0..<4).map { index in
                let time = start + (end - start) * (Double(index) + 0.5) / 4
                let face = eval.screen ? nil : FrameFace(rect: ClipEffect.Rect(x: 0.35, y: 0.2, width: 0.3, height: 0.45), captureQuality: 0.6)
                let screens = eval.screen ? [FrameScreen(rect: ClipEffect.Rect(x: 0, y: 0, width: 1, height: 1), textBoxes: 12, textCoverage: 0.3,
                                                         framed: false)] : []
                return FrameSheetFrame(index: index + 1, observation: FrameObservation(time: time, faceCount: face == nil ? 0 : 1, face: face,
                                                                                       screens: screens, light: eval.light),
                                       jpeg: Data(), width: 320, height: 180)
            }
            return ClipAutopilotFrames(sheet: FrameSheet(frames: frames), clipStart: start, clipEnd: end, images: false, pitchBaseline: nil, light: light)
        }
    }

    /// Words that describe skin colour, never a reason for a look (looks spec §9.2). "Soft Skin", the look's name, is not one.
    static var skinColour: Regex<(Substring, Substring, Substring?, Substring?, Substring?)> { /(?i)\b(skin[- ]?(tone|colou?r|shade|type)s?|complexion|melanin|ethnic\w*|racial|race|(dark|darker|light|lighter|fair|pale|deep|olive|brown|black|white|tan|tanned)[- ]skin(ned)?)\b/ }

    /// What `plans` get wrong for `eval`; empty when every check holds.
    static func failures(_ eval: Case, plans: [ClipAutopilotPlan], library: ClipLookLibrary) -> [String] {
        let name = eval.kind.rawValue
        guard !plans.isEmpty else { return ["\(name): no plan"] }
        var failures: [String] = []
        for plan in plans {
            let id = plan.look.id.rawValue
            switch eval.kind {
            case .business, .education:
                if library.look(id)?.category != "natural" { failures.append("\(name): \(id) is not a Natural look") }
            case .screenDemo:
                if id != ClipAutopilotPlan.LookPresetID.original.rawValue { failures.append("\(name): \(id) is not As filmed") }
            case .dimFace:
                if ClipAutopilotValidator.dimFaceLooks.contains(where: { $0.rawValue == id }) { failures.append("\(name): \(id) on a dim face") }
            case .series:
                break
            }
            if plan.look.reason.contains(skinColour) { failures.append("\(name): the reason mentions skin colour: \(plan.look.reason)") }
        }
        if eval.kind == .series {
            let looks = Set(plans.map { "\($0.look.id.rawValue) at \($0.look.amount)" })
            if plans.count < 2 { failures.append("\(name): \(plans.count) clip") }
            if looks.count > 1 { failures.append("\(name): the clips differ: " + looks.sorted().joined(separator: ", ")) }
        }
        return failures
    }
}

@Suite struct ClipAutopilotLookEvalTests {
    struct Pick: Sendable {
        var look: String, amount: Double, reason: String
        var fix = false
    }

    /// A stub plan reply for the span the request names, with `pick(start)`'s look.
    static func reply(_ request: LLMRequest, _ pick: (Int) -> Pick) throws -> String {
        let base = try ClipAutopilotV2Tests.planReply(request)
        guard case .object(var object) = try JSONDecoder().decode(JSONValue.self, from: Data(base.utf8)),
              let start = request.instruction.firstMatch(of: #/Plan the clip from word (\d+) to/#).flatMap({ Int($0.1) }) else {
            throw VoiceLabError.invalidInput
        }
        let choice = pick(start)
        object["look"] = .string(choice.look); object["lookAmount"] = .number(choice.amount); object["lookFix"] = .bool(choice.fix)
        object["lookAlternatives"] = .array([]); object["lookReason"] = .string(choice.reason)
        return try JSONValue.object(object).aiCompact()
    }

    /// Plans `eval` through the planner's whole send path with `connector`, the frames carrying the case's light.
    static func plan(_ eval: ClipLookEval.Case, connector: any LLMConnector, model: String = "fixture",
                     runner: LLMRunner? = nil) async throws -> [ClipAutopilotPlan] {
        let shared = try ClipAutopilotTests.shared()
        let library = try ClipLookLibrary.load(shared: shared)
        let service = ClipAutopilotService(runner: try runner ?? ClipAutopilotTests.runner(), shared: shared)
        let result = try await service.plan(ClipLookEval.request(eval), connector: connector, model: model,
                                            frames: ClipLookEval.frames(eval, light: library.measure.light))
        return result.series.plans
    }

    static func eval(_ kind: ClipLookEval.Kind) throws -> ClipLookEval.Case { try #require(ClipLookEval.cases.first { $0.kind == kind }) }

    @Test func goodPicksPassEveryCheckAndEachRequestCarriesItsLight() async throws {
        let library = try ClipLookLibrary.load(shared: try ClipAutopilotTests.shared())
        let picks: [ClipLookEval.Kind: Pick] = [
            .business: Pick(look: "naturalBoost", amount: 80, reason: "Even office light; a clean, true picture for business talk"),
            .education: Pick(look: "Studio Clean", amount: 70, reason: "A teaching clip wants calm, honest colour"),
            .screenDemo: Pick(look: "As filmed", amount: 100, reason: "The screen's colours matter"),
            .dimFace: Pick(look: "softSkin", amount: 100, reason: "The face is a little dark", fix: true),
            .series: Pick(look: "goldenHour", amount: 70, reason: "Warm outdoor light for the whole trip"),
        ]
        #expect(Set(picks.keys) == Set(ClipLookEval.Kind.allCases))
        for eval in ClipLookEval.cases {
            let pick = try #require(picks[eval.kind])
            let stub = LookStub { try Self.reply($0) { _ in pick } }
            let plans = try await Self.plan(eval, connector: stub)
            #expect(ClipLookEval.failures(eval, plans: plans, library: library).isEmpty, "\(eval.kind)")
            #expect(plans.count == eval.clips.count)
            let sent = await stub.requests
            #expect(sent.count == eval.clips.count && sent.allSatisfy { $0.schemaName == "clip_autopilot_plan" })
            // The measured light reaches Claude as the frames' light line (looks spec §9.3).
            let line = eval.light.line(library.measure.light)
            #expect(sent.allSatisfy { ($0.instruction + ($0.cachedBlock ?? "")).contains(line) }, "\(eval.kind): \(line)")
        }
        #expect(ClipLookEval.dim.line(library.measure.light) == "light: face a little dark")
        #expect(ClipLookEval.screen.line(library.measure.light).contains("low color"))
    }

    @Test func eachMissIsCaught() async throws {
        let library = try ClipLookLibrary.load(shared: try ClipAutopilotTests.shared())
        func failures(_ kind: ClipLookEval.Kind, _ pick: @escaping @Sendable (Int) -> Pick) async throws -> [String] {
            let eval = try Self.eval(kind)
            return ClipLookEval.failures(eval, plans: try await Self.plan(eval, connector: LookStub { try Self.reply($0, pick) }), library: library)
        }
        #expect(try await failures(.business) { _ in Pick(look: "moody", amount: 65, reason: "Serious numbers") }
                == ["business: moody is not a Natural look"])
        #expect(try await failures(.education) { _ in Pick(look: "Bold Pop", amount: 70, reason: "Energy") }
                == ["education: boldPop is not a Natural look"])
        #expect(try await failures(.screenDemo) { _ in Pick(look: "naturalBoost", amount: 70, reason: "Cleaner") }
                == ["screenDemo: naturalBoost is not As filmed"])
        // An unknown look comes back As filmed, which a screen demo wants anyway.
        #expect(try await failures(.screenDemo) { _ in Pick(look: "Neon Dream", amount: 70, reason: "Bold") }.isEmpty)
        #expect(try await failures(.business) { _ in Pick(look: "naturalBoost", amount: 80, reason: "Suits her darker skin tone") }
                == ["business: the reason mentions skin colour: Suits her darker skin tone"])
        #expect(try await failures(.education) { _ in Pick(look: "softSkin", amount: 100, reason: "Flatters a fair-skinned teacher") }
                == ["education: the reason mentions skin colour: Flatters a fair-skinned teacher"])
        #expect(try await failures(.education) { _ in Pick(look: "softSkin", amount: 100, reason: "Soft Skin keeps the face gentle") }.isEmpty)
        let second = try ClipLookEval.spans(Self.eval(.series))[1].lowerBound
        #expect(try await failures(.series) { start in
            start == second ? Pick(look: "moody", amount: 65, reason: "Rain") : Pick(look: "goldenHour", amount: 70, reason: "Sun")
        } == ["series: the clips differ: goldenHour at 70, moody at 65"])
        #expect(try await failures(.series) { start in Pick(look: "goldenHour", amount: start == second ? 85 : 70, reason: "Sun") }
                == ["series: the clips differ: goldenHour at 70, goldenHour at 85"])
        // Moody on the dim face never reaches the clip: the validator's dim-face repair turns it into Soft Skin.
        let eval = try Self.eval(.dimFace)
        let plans = try await Self.plan(eval, connector: LookStub { try Self.reply($0) { _ in Pick(look: "Moody", amount: 65, reason: "A late-night confession") } })
        #expect(ClipLookEval.failures(eval, plans: plans, library: library).isEmpty)
        #expect(plans.map(\.look.id.rawValue) == ["softSkin"] && plans.first?.look.reason == "A late-night confession; brightened for a dim face")
        #expect(ClipLookEval.failures(eval, plans: [], library: library) == ["dimFace: no plan"])
    }
}

@Test("Live planner look evaluation", .enabled(if: ProcessInfo.processInfo.environment["VOXCLIP_LOOK_LIVE_EVAL"] == "1",
                                                "Requires VOXCLIP_LOOK_LIVE_EVAL=1 and a Claude Code plan sign-in"),
      .timeLimit(.minutes(30)))
func clipLookLiveEvaluation() async throws {
    let environment = ProcessInfo.processInfo.environment
    let keyVariables = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "VOXCLIP_ANTHROPIC_API_KEY"]
    try #require(keyVariables.allSatisfy { (environment[$0] ?? "").isEmpty }, "Remove API-key overrides before running the plan-only eval.")
    let shared = try ClipAutopilotTests.shared()
    let library = try ClipLookLibrary.load(shared: shared)
    let catalog = try LLMCatalog(shared: shared)
    let log = RedactingLogger(homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
    let cli = CLIConnector(id: .claudeCode, catalog: catalog, log: log)
    let detection = try await cli.detection()
    // A plan costs nothing extra only on the creator's Claude plan: refuse anything else before any send.
    try #require(detection.authMethod == "claude.ai", "A Claude Code plan sign-in is required; nothing was sent.")
    let output = URL(fileURLWithPath: "/tmp/voxclip-autopilot-eval/looks-\(Int(Date().timeIntervalSince1970))", isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let runner = LLMRunner(keys: LLMEnvironmentKeyProvider(catalog: catalog), catalog: catalog, log: log)
    let model = environment["VOXCLIP_AUTOPILOT_EVAL_MODEL"] ?? "opus"
    var rows: [JSONValue] = [], failures: [String] = []
    for eval in ClipLookEval.cases {
        let plans = try await ClipAutopilotLookEvalTests.plan(eval, connector: cli, model: model, runner: runner)
        let missed = ClipLookEval.failures(eval, plans: plans, library: library)
        failures += missed
        rows.append(.object(["case": .string(eval.kind.rawValue), "failures": .array(missed.map(JSONValue.string)),
                             "looks": .array(plans.map { plan in
                                 .object(["id": .string(plan.look.id.rawValue), "amount": .number(Double(plan.look.amount)), "fix": .bool(plan.look.fix),
                                          "alternatives": .array(plan.look.alternatives.map { .string($0.rawValue) }), "reason": .string(plan.look.reason),
                                          "repairs": .array(plan.repairs.filter { $0.field.hasPrefix("look") }.map { .string("\($0.field): \($0.detail)") })])
                             })]))
    }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(JSONValue.object(["model": .string(model), "cliVersion": .string(detection.version), "cases": .array(rows)]))
        .write(to: output.appendingPathComponent("looks.json"))
    #expect(failures.isEmpty, "\(failures.joined(separator: "; ")); replies in \(output.path)")
}

private actor LookStub: LLMConnector {
    nonisolated let id = ConnectorID.ollama
    private let reply: @Sendable (LLMRequest) throws -> String
    private(set) var requests: [LLMRequest] = []
    init(reply: @escaping @Sendable (LLMRequest) throws -> String) { self.reply = reply }
    func status() -> ConnectorStatus { .ready }
    func models(refresh: Bool) -> [LLMModel] { [.init(id: "fixture", name: "Fixture", contextTokens: 256_000, source: .curated)] }
    func contextTokens(model: String) -> Int? { 256_000 }
    func send(_ request: LLMRequest, model: String) async throws -> RawCompletion {
        requests.append(request)
        return RawCompletion(text: try reply(request), model: model, stop: .complete)
    }
}
