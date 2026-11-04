import Foundation

/// A checked plan and where it came from (ai.md §16).
public struct ClipAutopilotResult: Sendable, Equatable {
    /// The ranked clips of a series, or the single clip of a clip request.
    public let series: ClipAutopilotSeries
    public let model: String
    public let usedFallback: Bool
    /// Reply items the shared response parser dropped before validation because their types were wrong.
    public let droppedItems: Int
    public let usage: LLMUsage?
    public let promptVersion: Int
    public let promptSHA256: String
    /// The clip request's plan.
    public var plan: ClipAutopilotPlan? { series.plans.first }
}

/// The "Make it postable" planner (ai.md §16): asks the selected connector, at extra high effort, for every decision a
/// postable clip needs, and checks the reply item by item. It never applies, generates or bills anything; the review
/// (`ClipAutopilotMapping`) and the paid steps own that.
public actor ClipAutopilotService {
    /// Claude Code's `--effort xhigh`; other connectors send their highest level below it (`Effort.capped`).
    public static let effort: Effort = .xhigh

    private let runner: LLMRunner
    private let shared: SharedResources

    public init(runner: LLMRunner, shared: SharedResources) { self.runner = runner; self.shared = shared }

    /// The request a plan sends, built from the shared prompt file. Pure apart from reading the shared files.
    public func request(_ input: ClipAutopilotRequest, connector: ConnectorID) throws -> LLMRequest {
        try prepared(input, connector: connector).request
    }

    /// What a reply is checked against.
    public func context(_ input: ClipAutopilotRequest) throws -> ClipAutopilotContext {
        try prepared(input, connector: .claudeCode).context
    }

    public func plan(_ input: ClipAutopilotRequest, connector: any LLMConnector, model: String) async throws -> ClipAutopilotResult {
        guard VoiceLabLLMChecks.isValidModel(model) else { throw VoiceLabError.invalidInput }
        let prepared = try prepared(input, connector: connector.id)
        let request = prepared.request
        let catalog = try LLMCatalog(shared: shared)
        let policy = AITokenPolicy(catalog.document[ai: "policy"])
        if connector.id != .appleFoundation {
            let context = try await catalog.resolvedContextTokens(connector: connector, model: model)
            let required = VoiceLabLLMChecks.requiredTokens(policy, text: request.system + (request.cachedBlock ?? "") + request.instruction,
                schema: try request.schema.aiCompact(), maxOutputTokens: request.maxOutputTokens)
            guard VoiceLabLLMChecks.contextFits(context: context, required: required, safetyFactor: policy.safetyFactor) else {
                throw LLMError.contextTooLong
            }
        }
        try Task.checkCancellation()
        let reply = try await runner.run(request, on: connector, model: model)
        try Task.checkCancellation()
        let series: ClipAutopilotSeries
        if input.isSeries {
            series = ClipAutopilotValidator.series(reply.object, context: prepared.context)
        } else {
            guard let plan = ClipAutopilotValidator.plan(reply.object, context: prepared.context) else {
                throw LLMError.invalidOutput(reason: "The plan has no words of the clip.")
            }
            series = ClipAutopilotSeries(plans: [plan])
        }
        return ClipAutopilotResult(series: series, model: reply.model, usedFallback: reply.usedFallback, droppedItems: reply.droppedItems,
                                   usage: reply.usage, promptVersion: prepared.prompt.promptVersion, promptSHA256: prepared.prompt.sha256)
    }

    private func prepared(_ input: ClipAutopilotRequest, connector: ConnectorID) throws
        -> (request: LLMRequest, context: ClipAutopilotContext, prompt: ClipAutopilotPrompt) {
        let prompt = try ClipAutopilotPrompt(shared: shared)
        let styles = try CaptionStyleLibrary(shared: shared).styles
        let fonts = try ClipAutopilotFonts.load(shared: shared)
        let state = try EditState(transcript: input.transcript, edits: input.edits)
        let rendered = try ClipAutopilotRequestBuilder.render(input, prompt: prompt, styles: styles, fonts: fonts, pauses: state.pauses)
        guard (prompt.system + rendered.cachedBlock + rendered.instruction).utf8.count <= 400_000 else { throw LLMError.contextTooLong }
        let catalog = try LLMCatalog(shared: shared)
        let promptCap = input.isSeries ? prompt.seriesOutputTokens : prompt.clipOutputTokens
        let output = min(promptCap, catalog.connector(connector)[ai: "maxOutputTokensCap"].aiInt ?? promptCap)
        // xhigh replies take minutes: the plan waits at least the prompt file's minimum, more when the catalog allows it.
        let timeout = max(catalog.timeout(for: connector, feature: .clipAutopilot), prompt.minimumTimeout)
        let request = LLMRequest(feature: .clipAutopilot, system: prompt.system, cachedBlock: rendered.cachedBlock, instruction: rendered.instruction,
            schemaName: input.isSeries ? prompt.seriesSchemaName : prompt.schemaName, schema: input.isSeries ? prompt.seriesSchema : prompt.schema,
            maxOutputTokens: output, effort: Self.effort, timeout: timeout, language: input.language ?? input.transcript.language,
            tag: input.isSeries ? "clip-autopilot-series" : "clip-autopilot")
        let context = ClipAutopilotContext(words: input.transcript.words, corrections: input.edits.corrections,
            cutWordIDs: Set(input.edits.cutWordIds), pauses: state.pauses, cutPauseIDs: Set(input.edits.cutPauseIds), scope: rendered.scope,
            styleIDs: Set(styles.map(\.id)), fonts: fonts, preference: input.captionPreference, prompt: prompt)
        return (request, context, prompt)
    }
}
