import Foundation
import Synchronization
import Testing
@testable import VoxClipCore

/// The planner's live evaluation (ai.md §16.9): one two-stage series plan and one clip plan from the creator's own Claude
/// Code sign-in. Never in CI: it needs VOXCLIP_AUTOPILOT_LIVE_EVAL=1, a project and an output folder under
/// /tmp/voxclip-autopilot-eval, and it refuses to send when Claude Code would bill an API key. Its output stays in /tmp.
private let liveEval = ProcessInfo.processInfo.environment["VOXCLIP_AUTOPILOT_LIVE_EVAL"] == "1"

@Test("Live Make it postable evaluation", .enabled(if: liveEval, "Requires VOXCLIP_AUTOPILOT_LIVE_EVAL=1 and a Claude Code plan sign-in"),
      .timeLimit(.minutes(60)))
func clipAutopilotLiveEvaluation() async throws {
    let environment = ProcessInfo.processInfo.environment
    let project = try await JSONProjectStore().load(from: URL(fileURLWithPath: try #require(environment["VOXCLIP_AUTOPILOT_EVAL_PROJECT"])))
    let output = URL(fileURLWithPath: try #require(environment["VOXCLIP_AUTOPILOT_EVAL_OUT"]), isDirectory: true)
    try #require(output.standardizedFileURL.path.hasPrefix("/tmp/voxclip-autopilot-eval/") ||
                 output.standardizedFileURL.path.hasPrefix("/private/tmp/voxclip-autopilot-eval/"))
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let transcript = try #require(project.transcript)
    let shared = SharedResources(root: try FixtureLoader.sharedRoot())
    let catalog = try LLMCatalog(shared: shared)
    let log = RedactingLogger(homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
    let cli = CLIConnector(id: .claudeCode, catalog: catalog, log: log)

    // A plan costs nothing extra only on the creator's Claude plan: refuse an API-key sign-in before any send.
    let detection = try await cli.detection()
    let method = detection.authMethod ?? ""
    let keyInEnvironment = !(environment["ANTHROPIC_API_KEY"] ?? "").isEmpty
    try write(output.appendingPathComponent("billing.json"), ["authMethod": method, "anthropicApiKeyInEnvironment": keyInEnvironment ? "yes" : "no",
                                                               "cliVersion": detection.version])
    guard !method.isEmpty, !method.lowercased().contains("api"), !keyInEnvironment else {
        Issue.record("Claude Code would bill an API key (authMethod \(method)); nothing was sent.")
        return
    }

    let main = RecordingConnector(cli)
    let lanes = [RecordingConnector(CLIConnector(id: .claudeCode, catalog: catalog, log: log)),
                 RecordingConnector(CLIConnector(id: .claudeCode, catalog: catalog, log: log))]
    let model = environment["VOXCLIP_AUTOPILOT_EVAL_MODEL"] ?? "opus"
    let service = ClipAutopilotService(runner: LLMRunner(keys: LLMEnvironmentKeyProvider(catalog: catalog), catalog: catalog, log: log), shared: shared)
    let preference = ClipAutopilotCaptionPreference(font: .init(family: "Roboto", weight: 900))
    let fonts = try ClipAutopilotFonts.load(shared: shared)
    let voiceCatalog = try VoiceLabPriceCatalog(data: Data(contentsOf: shared.root.appendingPathComponent("catalog/voice-lab.json")))
    let musicCatalog = try VoiceLabPriceCatalog(data: Data(contentsOf: shared.root.appendingPathComponent(ClipAutopilotPricing.musicCatalogPath)))
    let state = try EditState(transcript: transcript, edits: project.edits)
    let words = transcript.words, corrections = project.edits.corrections

    var report = "# Make it postable: live evaluation\n\nModel: \(model); moments at \(ClipAutopilotService.momentsEffort.rawValue), "
        + "clip plans at \(ClipAutopilotService.effort.rawValue), \(ClipAutopilotService.maxParallelPlans) at once. "
        + "Claude Code \(detection.version), sign-in \(method).\n"
    var rows: [[String: String]] = []
    var seriesPlans: [ClipAutopilotPlan] = []
    if environment["VOXCLIP_AUTOPILOT_EVAL_SKIP_SERIES"] != "1" {
        let request = ClipAutopilotRequest(transcript: transcript, edits: project.edits, mode: .series(nil), captionPreference: preference)
        let rendered = try await service.request(request, connector: .claudeCode)
        try text(rendered).write(to: output.appendingPathComponent("request-moments.txt"), atomically: true, encoding: .utf8)
        let timeline = Timeline()
        let result = try await service.plan(request, connector: main, model: model, lanes: lanes, progress: { timeline.add($0) })
        let total = timeline.seconds(since: timeline.start)
        try await RecordingConnector.save([main] + lanes, to: output.appendingPathComponent("replies-series.json"))
        try encode(result.series, to: output.appendingPathComponent("series.json"))
        let clipRequests = try await service.requests(request, moments: result.series.moments, connector: .claudeCode)
        try clipRequests.enumerated().map { "## Moment \($0.offset + 1)\n\n" + text($0.element) }.joined(separator: "\n\n=====\n\n")
            .write(to: output.appendingPathComponent("request-series-clips.txt"), atomically: true, encoding: .utf8)
        seriesPlans = result.series.plans
        report += "\n## Series: \(result.series.plans.count) clips in \(Int(total.rounded())) s (moments \(Int(timeline.momentsSeconds.rounded())) s; "
            + "clip plans " + timeline.clipSeconds.map { "\(Int($0.rounded())) s" }.joined(separator: ", ") + "), answered by \(result.model)"
            + "\(result.usedFallback ? ", fallback" : "")\n\n### Moments picked (stage 1, rank order)\n"
        for (rank, moment) in result.series.moments.enumerated() {
            let raw = words[moment.endWord].end - words[moment.startWord].start
            report += "\(rank + 1). \(moment.title) — words \(moment.startWord)–\(moment.endWord), \(toFixed1(raw)) s as recorded, "
                + "\(moment.score)/10 \(moment.verdict.rawValue), captions \(moment.captionStyle) (\(moment.captionReason)). \(moment.idea)\n"
        }
        if !result.series.repairs.isEmpty { report += "\nLeft out or repaired: " + result.series.repairs.map { "\($0.field) \($0.detail)" }.joined(separator: "; ") + "\n" }
        for (rank, plan) in result.series.plans.enumerated() {
            report += summary(plan, rank: rank + 1, words: words, corrections: corrections)
            rows.append(row(plan, kind: "series \(rank + 1)", words: words, corrections: corrections))
        }
        report += "\nSeries wall time \(toFixed1(total)) s.\n"
    }

    let span: ClosedRange<Int>
    if let value = environment["VOXCLIP_AUTOPILOT_EVAL_CLIP"], let dash = value.firstIndex(of: "-"),
       let start = Int(value[..<dash]), let end = Int(value[value.index(after: dash)...]) {
        span = start...end
    } else if let best = seriesPlans.first {
        span = best.startWord...best.endWord
    } else {
        span = 0...min(transcript.words.count - 1, 120)
    }
    let clipRequest = ClipAutopilotRequest(transcript: transcript, edits: project.edits, mode: .clip(span), captionPreference: preference)
    try text(try await service.request(clipRequest, connector: .claudeCode)).write(to: output.appendingPathComponent("request-clip.txt"),
                                                                                  atomically: true, encoding: .utf8)
    let single = RecordingConnector(CLIConnector(id: .claudeCode, catalog: catalog, log: log))
    let timeline = Timeline()
    let result = try await service.plan(clipRequest, connector: single, model: model)
    let seconds = timeline.seconds(since: timeline.start)
    try await RecordingConnector.save([single], to: output.appendingPathComponent("reply-clip.json"))
    let plan = try #require(result.plan)
    try encode(plan, to: output.appendingPathComponent("clip.json"))
    let operations = try ClipAutopilotMapping.operations(for: plan, clipID: "autopilot-eval", project: project, fonts: fonts)
    let musicSeconds = ClipAutopilotMapping.editedSeconds(plan, state: state)
    let price = try ClipAutopilotPricing.price(plan, voiceModel: "eleven_v3", candidates: 1, voiceCatalog: voiceCatalog, musicCatalog: musicCatalog,
                                               musicSeconds: musicSeconds, connector: .claudeCode, signIn: .plan)
    report += "\n## Single clip, words \(span.lowerBound)–\(span.upperBound) (\(toFixed1(seconds)) s wall time, answered by \(result.model))\n"
    report += summary(plan, rank: nil, words: words, corrections: corrections)
    report += "\nOperations: " + operations.map(\.decision.rawValue).joined(separator: ", ") + "\n"
    report += "Price: voice \(price.voice?.usd.map { "$\($0)" } ?? "none"), music \(price.music?.usd.map { "$\($0)" } ?? "none") for "
        + "\(toFixed1(musicSeconds)) s, LLM \(price.llm.rawValue), total \(price.usd.map { "$\($0)" } ?? "unknown").\n"
    var clipRow = row(plan, kind: "single", words: words, corrections: corrections)
    clipRow["wallSeconds"] = toFixed1(seconds)
    rows.append(clipRow)
    try report.write(to: output.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(rows).write(to: output.appendingPathComponent("table.json"))
}

private func text(_ request: LLMRequest) -> String {
    request.system + "\n\n=====\n\n" + (request.cachedBlock ?? "") + "\n\n=====\n\n" + request.instruction
}

/// When each progress event arrived, for the stage times.
private final class Timeline: Sendable {
    let start = ContinuousClock.now
    private let events = Mutex<[(ClipAutopilotProgress, ContinuousClock.Instant)]>([])
    func add(_ event: ClipAutopilotProgress) { events.withLock { $0.append((event, .now)) } }
    func seconds(since instant: ContinuousClock.Instant, to end: ContinuousClock.Instant = .now) -> Double {
        let parts = instant.duration(to: end).components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
    var momentsSeconds: Double {
        events.withLock { list in
            guard let picked = list.first(where: { if case .picked = $0.0 { true } else { false } }) else { return 0 }
            return seconds(since: start, to: picked.1)
        }
    }
    /// Each clip plan's own send time, in clip order.
    var clipSeconds: [Double] {
        events.withLock { list in
            var started: [Int: ContinuousClock.Instant] = [:], times: [Int: Double] = [:]
            for (event, at) in list {
                switch event {
                case .planning(let clip, _): started[clip] = at
                case .planned(let clip, _), .failed(let clip, _): if let from = started[clip] { times[clip] = seconds(since: from, to: at) }
                default: break
                }
            }
            return times.keys.sorted().map { times[$0]! }
        }
    }
}

private func write(_ url: URL, _ values: [String: String]) throws {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(values).write(to: url)
}

private func encode(_ value: some Encodable, to url: URL) throws {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(value).write(to: url)
}

private func shown(_ range: ClosedRange<Int>, _ words: [TimedWord], _ corrections: [String: String]) -> String {
    range.map { corrections[words[$0].id] ?? words[$0].text }.joined(separator: " ")
}

private func row(_ plan: ClipAutopilotPlan, kind: String, words: [TimedWord], corrections: [String: String]) -> [String: String] {
    ["kind": kind, "title": plan.title, "span": "\(plan.startWord)-\(plan.endWord)",
     "recordedSeconds": toFixed1(words[plan.endWord].end - words[plan.startWord].start), "finalSeconds": toFixed1(plan.seconds),
     "score": "\(plan.score) \(plan.verdict.rawValue)", "captions": "\(plan.captions.styleId) \(plan.captions.textCase.rawValue) ×\(plan.captions.wordsPerCaption)",
     "look": plan.look.id.rawValue, "speed": plan.speed.map { String($0.rate) } ?? "1",
     "corrections": plan.corrections.map { "\($0.heard)→\($0.text)" }.joined(separator: ", "),
     "cuts": String(plan.cuts.count), "pauseCuts": String(plan.pauseCuts.count), "rewrites": String(plan.rewrites.count),
     "flags": plan.flags.map(\.kind.rawValue).joined(separator: ", "), "repairs": String(plan.repairs.count)]
}

private func summary(_ plan: ClipAutopilotPlan, rank: Int?, words: [TimedWord], corrections: [String: String]) -> String {
    let recorded = words[plan.endWord].end - words[plan.startWord].start
    var lines = ["", "### \(rank.map { "\($0). " } ?? "")\(plan.title) — \(plan.score)/10, \(plan.verdict.rawValue), \(toFixed1(plan.seconds)) s finished",
                 "Words \(plan.startWord)–\(plan.endWord), \(toFixed1(words[plan.startWord].start))–\(toFixed1(words[plan.endWord].end)) s (\(toFixed1(recorded)) s as recorded)."
                    + (plan.lengthReason.isEmpty ? "" : " Length: \(plan.lengthReason)"),
                 "Hook: \(plan.hook)", "Why: \(plan.scoreReason)",
                 "Captions: \(plan.captions.styleId), \(plan.captions.font.family) \(plan.captions.font.weight), \(plan.captions.textCase.rawValue), "
                    + "\(plan.captions.wordsPerCaption) words. \(plan.captions.reason)",
                 "Look: \(plan.look.id.rawValue). \(plan.look.reason)", "Speed: " + (plan.speed.map { "\($0.rate) (\($0.reason))" } ?? "1")]
    for correction in plan.corrections { lines.append("Correction [\(correction.word)] “\(correction.heard)” → “\(correction.text)” (\(correction.reason))") }
    lines.append("Cuts (\(plan.cuts.count)): " + plan.cuts.map { "“\(shown($0.startWord...$0.endWord, words, corrections))” (\($0.kind.rawValue): \($0.reason))" }.joined(separator: "; "))
    lines.append("Pause cuts: \(plan.pauseCuts.count)")
    for rewrite in plan.rewrites { lines.append("Rewrite: “\(shown(rewrite.startWord...rewrite.endWord, words, corrections))” → “\(rewrite.text)” (\(rewrite.reason))") }
    for (index, music) in plan.music.enumerated() {
        lines.append("Music\(index == plan.musicPick ? " ✓" : ""): \(music.title) — \(music.mood), −\(toFixed1(music.underVoiceDb)) dB. \(music.prompt) (\(music.reason))")
    }
    for zoom in plan.zooms { lines.append("Zoom ×\(zoom.scale) on “\(shown(zoom.word...zoom.untilWord, words, corrections))” (\(zoom.reason))") }
    lines.append("Post: \(plan.postText)")
    for question in plan.questions { lines.append("Question: \(question.question) → \(question.answer)") }
    if !plan.flags.isEmpty { lines.append("Flags: " + plan.flags.map { "\($0.kind.rawValue) (\($0.detail))" }.joined(separator: "; ")) }
    if !plan.repairs.isEmpty { lines.append("Repairs: " + plan.repairs.map { "\($0.field) \($0.action.rawValue): \($0.detail)" }.joined(separator: "; ")) }
    return lines.joined(separator: "\n") + "\n"
}

/// Forwards to the real connector and keeps every raw reply, so the evaluation can compare them with the checked plans.
private actor RecordingConnector: LLMConnector {
    nonisolated let id: ConnectorID
    private let base: any LLMConnector
    private var replies: [JSONValue] = []
    init(_ base: any LLMConnector) { self.base = base; self.id = base.id }
    func status() async -> ConnectorStatus { await base.status() }
    func knownCLIAuthMethod() async -> String? { await base.knownCLIAuthMethod() }
    func models(refresh: Bool) async throws -> [LLMModel] { try await base.models(refresh: refresh) }
    func contextTokens(model: String) async -> Int? { await base.contextTokens(model: model) }
    func send(_ request: LLMRequest, model: String) async throws -> RawCompletion {
        let completion = try await base.send(request, model: model)
        replies.append(.object(["tag": .string(request.tag), "instruction": .string(String(request.instruction.prefix(200))),
                                "reply": completion.object ?? .string(completion.text ?? "")]))
        return completion
    }
    var recorded: [JSONValue] { replies }
    static func save(_ connectors: [RecordingConnector], to url: URL) async throws {
        var all: [JSONValue] = []
        for connector in connectors { all += await connector.recorded }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(JSONValue.array(all)).write(to: url)
    }
}
