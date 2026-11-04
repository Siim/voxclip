import Foundation
import Testing
@testable import VoxClipCore

/// The planner's live evaluation (ai.md §16.9): one series plan and one clip plan from the creator's own Claude Code sign-in
/// at extra high effort. Never in CI: it needs VOXCLIP_AUTOPILOT_LIVE_EVAL=1, a project and an output folder under
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

    let connector = RecordingConnector(cli)
    let model = environment["VOXCLIP_AUTOPILOT_EVAL_MODEL"] ?? "opus"
    let service = ClipAutopilotService(runner: LLMRunner(keys: LLMEnvironmentKeyProvider(catalog: catalog), catalog: catalog, log: log), shared: shared)
    let preference = ClipAutopilotCaptionPreference(font: .init(family: "Roboto", weight: 900))
    let fonts = try ClipAutopilotFonts.load(shared: shared)
    let voiceCatalog = try VoiceLabPriceCatalog(data: Data(contentsOf: shared.root.appendingPathComponent("catalog/voice-lab.json")))
    let musicCatalog = try VoiceLabPriceCatalog(data: Data(contentsOf: shared.root.appendingPathComponent(ClipAutopilotPricing.musicCatalogPath)))
    let state = try EditState(transcript: transcript, edits: project.edits)

    var report = "# Make it postable: live evaluation\n\nModel: \(model) at effort \(ClipAutopilotService.effort.rawValue); Claude Code \(detection.version), sign-in \(method).\n"
    var seriesPlans: [ClipAutopilotPlan] = []
    if environment["VOXCLIP_AUTOPILOT_EVAL_SKIP_SERIES"] != "1" {
        let request = ClipAutopilotRequest(transcript: transcript, edits: project.edits, mode: .series(nil), captionPreference: preference)
        let rendered = try await service.request(request, connector: .claudeCode)
        try (rendered.system + "\n\n=====\n\n" + (rendered.cachedBlock ?? "") + "\n\n=====\n\n" + rendered.instruction)
            .write(to: output.appendingPathComponent("request-series.txt"), atomically: true, encoding: .utf8)
        let started = ContinuousClock.now
        let result = try await service.plan(request, connector: connector, model: model)
        let seconds = seconds(since: started)
        try await connector.save(to: output.appendingPathComponent("reply-series.json"))
        try encode(result.series, to: output.appendingPathComponent("series.json"))
        seriesPlans = result.series.plans
        report += "\n## Series (\(result.series.plans.count) clips, \(Int(seconds)) s, answered by \(result.model)\(result.usedFallback ? ", fallback" : ""))\n"
        if !result.series.repairs.isEmpty { report += "\nLeft out: " + result.series.repairs.map { "\($0.field) \($0.detail)" }.joined(separator: "; ") + "\n" }
        for (rank, plan) in result.series.plans.enumerated() {
            report += summary(plan, rank: rank + 1, words: transcript.words, corrections: project.edits.corrections)
        }
    }

    let span: ClosedRange<Int>
    if let text = environment["VOXCLIP_AUTOPILOT_EVAL_CLIP"], let dash = text.firstIndex(of: "-"),
       let start = Int(text[..<dash]), let end = Int(text[text.index(after: dash)...]) {
        span = start...end
    } else if let best = seriesPlans.first {
        span = best.startWord...best.endWord
    } else {
        span = 0...min(transcript.words.count - 1, 120)
    }
    let clipRequest = ClipAutopilotRequest(transcript: transcript, edits: project.edits, mode: .clip(span), captionPreference: preference)
    let rendered = try await service.request(clipRequest, connector: .claudeCode)
    try ((rendered.cachedBlock ?? "") + "\n\n=====\n\n" + rendered.instruction).write(to: output.appendingPathComponent("request-clip.txt"),
                                                                                    atomically: true, encoding: .utf8)
    let started = ContinuousClock.now
    let result = try await service.plan(clipRequest, connector: connector, model: model)
    let seconds = seconds(since: started)
    try await connector.save(to: output.appendingPathComponent("reply-clip.json"))
    let plan = try #require(result.plan)
    try encode(plan, to: output.appendingPathComponent("clip.json"))
    let operations = try ClipAutopilotMapping.operations(for: plan, clipID: "autopilot-eval", project: project, fonts: fonts)
    let musicSeconds = ClipAutopilotMapping.editedSeconds(plan, state: state)
    let price = try ClipAutopilotPricing.price(plan, voiceModel: "eleven_v3", candidates: 1, voiceCatalog: voiceCatalog, musicCatalog: musicCatalog,
                                               musicSeconds: musicSeconds, connector: .claudeCode, signIn: .plan)
    report += "\n## Single clip, words \(span.lowerBound)–\(span.upperBound) (\(Int(seconds)) s, answered by \(result.model))\n"
    report += summary(plan, rank: nil, words: transcript.words, corrections: project.edits.corrections)
    report += "\nOperations: " + operations.map(\.decision.rawValue).joined(separator: ", ") + "\n"
    report += "Edited length \(toFixed1(musicSeconds)) s. Price: voice \(price.voice?.usd.map { "$\($0)" } ?? "none"), music "
        + "\(price.music?.usd.map { "$\($0)" } ?? "none"), LLM \(price.llm.rawValue), total \(price.usd.map { "$\($0)" } ?? "unknown").\n"
    try report.write(to: output.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
}

private func seconds(since start: ContinuousClock.Instant) -> Double {
    let parts = start.duration(to: .now).components
    return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
}

private func write(_ url: URL, _ values: [String: String]) throws {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(values).write(to: url)
}

private func encode(_ value: some Encodable, to url: URL) throws {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(value).write(to: url)
}

private func summary(_ plan: ClipAutopilotPlan, rank: Int?, words: [TimedWord], corrections: [String: String]) -> String {
    func text(_ range: ClosedRange<Int>) -> String { range.map { corrections[words[$0].id] ?? words[$0].text }.joined(separator: " ") }
    let seconds = words[plan.endWord].end - words[plan.startWord].start
    var lines = ["", "### \(rank.map { "\($0). " } ?? "")\(plan.title) — \(plan.score)/10, \(plan.verdict.rawValue)",
                 "Words \(plan.startWord)–\(plan.endWord), \(toFixed1(words[plan.startWord].start))–\(toFixed1(words[plan.endWord].end)) s (\(toFixed1(seconds)) s before cuts).",
                 "Hook: \(plan.hook)", "Why: \(plan.scoreReason)",
                 "Captions: \(plan.captions.styleId), \(plan.captions.font.family) \(plan.captions.font.weight), \(plan.captions.textCase.rawValue), \(plan.captions.wordsPerCaption) words."]
    lines.append("Cuts (\(plan.cuts.count)): " + plan.cuts.map { "“\(text($0.startWord...$0.endWord))” (\($0.kind.rawValue): \($0.reason))" }.joined(separator: "; "))
    lines.append("Pause cuts: \(plan.pauseCuts.count)")
    for rewrite in plan.rewrites { lines.append("Rewrite: “\(text(rewrite.startWord...rewrite.endWord))” → “\(rewrite.text)” (\(rewrite.reason))") }
    for (index, music) in plan.music.enumerated() {
        lines.append("Music\(index == plan.musicPick ? " ✓" : ""): \(music.title) — \(music.mood), −\(toFixed1(music.underVoiceDb)) dB. \(music.prompt) (\(music.reason))")
    }
    for zoom in plan.zooms { lines.append("Zoom ×\(zoom.scale) on “\(text(zoom.word...zoom.untilWord))” (\(zoom.reason))") }
    lines.append("Post: \(plan.postText)")
    for question in plan.questions { lines.append("Question: \(question.question) → \(question.answer)") }
    if !plan.repairs.isEmpty { lines.append("Repairs: " + plan.repairs.map { "\($0.field) \($0.action.rawValue): \($0.detail)" }.joined(separator: "; ")) }
    return lines.joined(separator: "\n") + "\n"
}

/// Forwards to the real connector and keeps the last raw reply, so the evaluation can compare it with the checked plan.
private actor RecordingConnector: LLMConnector {
    nonisolated let id: ConnectorID
    private let base: any LLMConnector
    private var last: RawCompletion?
    init(_ base: any LLMConnector) { self.base = base; self.id = base.id }
    func status() async -> ConnectorStatus { await base.status() }
    func knownCLIAuthMethod() async -> String? { await base.knownCLIAuthMethod() }
    func models(refresh: Bool) async throws -> [LLMModel] { try await base.models(refresh: refresh) }
    func contextTokens(model: String) async -> Int? { await base.contextTokens(model: model) }
    func send(_ request: LLMRequest, model: String) async throws -> RawCompletion {
        let completion = try await base.send(request, model: model)
        last = completion
        return completion
    }
    func save(to url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let value: JSONValue = last?.object ?? .string(last?.text ?? "")
        try encoder.encode(value).write(to: url)
    }
}
