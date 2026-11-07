import Foundation

/// A checked plan and where it came from (ai.md §16).
public struct ClipAutopilotResult: Sendable, Equatable {
    /// The ranked clips of a series or of a `clips` request, or the single clip of a clip request.
    public let series: ClipAutopilotSeries
    /// The model that answered the clip plans (the first stage's when no plan came back).
    public let model: String
    /// Whether any send used the connector's fallback model.
    public let usedFallback: Bool
    /// Reply items the shared response parser dropped before validation because their types were wrong, over every send.
    public let droppedItems: Int
    /// Token use over every send, where the connector reports it.
    public let usage: LLMUsage?
    public let promptVersion: Int
    public let promptSHA256: String
    /// The clip request's plan, or the best clip of a series.
    public var plan: ClipAutopilotPlan? { series.plans.first }
}

/// What a running plan is doing, for the progress lines (ai.md §16.3). Sent in order from the service; `clip` indexes the
/// moments of a series or the spans of a `clips` request, and is 0 of 1 for a single clip.
public enum ClipAutopilotProgress: Sendable, Equatable {
    /// The series' first stage was sent.
    case pickingMoments
    /// The first stage's checked moments, in its rank order; the second stage plans each one.
    case picked([ClipAutopilotMoment])
    case planning(clip: Int, of: Int)
    case planned(clip: Int, of: Int)
    /// That clip's checked plan, sent the moment it is ready and before `planned`, while the other clips are still
    /// planned: Claude mode applies and shows each clip as it comes (ai.md §16.12).
    case ready(clip: Int, of: Int, ClipAutopilotPlan)
    /// That clip's plan failed; the other clips go on.
    case failed(clip: Int, of: Int)
}

/// The "Make it postable" planner (ai.md §16): asks the selected connector for every decision a postable clip needs and
/// checks the reply item by item. A clip is one send at extra high effort. A series is two stages: the moments worth a clip
/// at high effort over the whole transcript, then each moment's plan at extra high effort with that clip's words only, at
/// most `maxParallelPlans` at once. It never applies, generates or bills anything; the review (`ClipAutopilotMapping`) and
/// the paid steps own that.
public actor ClipAutopilotService {
    /// A clip plan: Claude Code's `--effort xhigh`; other connectors send their highest level below it (`Effort.capped`).
    public static let effort: Effort = .xhigh
    /// The series' first stage, which only picks moments.
    public static let momentsEffort: Effort = .high
    /// Clip plans in flight at once in a series or a `clips` request.
    public static let maxParallelPlans = 3

    private let runner: LLMRunner
    private let shared: SharedResources

    public init(runner: LLMRunner, shared: SharedResources) { self.runner = runner; self.shared = shared }

    /// The first request a plan sends, built from the shared prompt file: the clip's plan, the series' moments, or the
    /// first span's plan of a `clips` request. Pure apart from reading the shared files.
    public func request(_ input: ClipAutopilotRequest, connector: ConnectorID) throws -> LLMRequest {
        let resources = try Resources(shared: shared)
        if case .clips(let spans) = input.mode {
            guard let first = spans.first else { throw VoiceLabError.invalidInput }
            return try Self.prepare(input.clip(first), resources: resources, connector: connector,
                                    moment: input.moments.count == spans.count ? Self.briefs(input.moments).first : nil).request
        }
        return try Self.prepare(input, resources: resources, connector: connector).request
    }

    /// The second stage's requests for a series' checked moments, in their order.
    func requests(_ input: ClipAutopilotRequest, moments: [ClipAutopilotMoment], connector: ConnectorID) throws -> [LLMRequest] {
        let resources = try Resources(shared: shared)
        return try Self.briefs(moments).map { try Self.prepare(input.clip($0.moment.startWord...$0.moment.endWord), resources: resources,
                                                              connector: connector, moment: $0).request }
    }

    /// What the first reply is checked against.
    public func context(_ input: ClipAutopilotRequest) throws -> ClipAutopilotContext {
        let resources = try Resources(shared: shared)
        if case .clips(let spans) = input.mode {
            guard let first = spans.first else { throw VoiceLabError.invalidInput }
            return try Self.prepare(input.clip(first), resources: resources, connector: .claudeCode).context
        }
        return try Self.prepare(input, resources: resources, connector: .claudeCode).context
    }

    /// Plans `input`. `lanes` are extra connectors of the same kind, one per parallel clip plan; each sends one plan at a
    /// time (a CLI connector runs one process at a time). Without lanes the clip plans of a series go one after another.
    /// A clip plan that fails is left out of the series and listed in its repairs; the run fails only when every clip plan
    /// does, or on cancellation.
    public func plan(_ input: ClipAutopilotRequest, connector: any LLMConnector, model: String, lanes: [any LLMConnector] = [],
                     progress: (@Sendable (ClipAutopilotProgress) -> Void)? = nil) async throws -> ClipAutopilotResult {
        guard VoiceLabLLMChecks.isValidModel(model), lanes.allSatisfy({ $0.id == connector.id }) else { throw VoiceLabError.invalidInput }
        let resources = try Resources(shared: shared)
        let all = [Lane(runner: runner, connector: connector)] + lanes.prefix(Self.maxParallelPlans - 1).map {
            Lane(runner: LLMRunner(keys: runner.keys, catalog: runner.catalog, log: runner.log), connector: $0)
        }
        switch input.mode {
        case .clip:
            let prepared = try Self.prepare(input, resources: resources, connector: connector.id)
            progress?(.planning(clip: 0, of: 1))
            let reply = try await Self.send(prepared, lane: all[0], model: model, catalog: resources.catalog)
            guard let plan = ClipAutopilotValidator.plan(reply.object, context: prepared.context) else {
                throw LLMError.invalidOutput(reason: "The plan has no words of the clip.")
            }
            progress?(.planned(clip: 0, of: 1))
            return Self.result(ClipAutopilotSeries(plans: [plan]), replies: [reply], model: reply.model, resources: resources)
        case .clips(let spans):
            guard !spans.isEmpty, spans.count <= resources.prompt.limits.maxClips,
                  input.moments.isEmpty || input.moments.count == spans.count else { throw VoiceLabError.invalidInput }
            // With Find Clips' moments each plan knows its rank and the other clips, as a series' second stage does.
            let briefs: [ClipAutopilotMomentBrief?] = input.moments.isEmpty ? spans.map { _ in nil } : Self.briefs(input.moments)
            let items = try zip(spans, briefs).map { try Self.prepare(input.clip($0.0), resources: resources, connector: connector.id, moment: $0.1) }
            let outcome = try await Self.planAll(items, lanes: all, model: model, catalog: resources.catalog, progress: progress)
            let series = ClipAutopilotValidator.series(outcome.plans, moments: [], failures: outcome.failures, repairs: [])
            return Self.result(series, replies: outcome.replies, model: outcome.replies.first?.model ?? model, resources: resources)
        case .series:
            let prepared = try Self.prepare(input, resources: resources, connector: connector.id)
            progress?(.pickingMoments)
            let reply = try await Self.send(prepared, lane: all[0], model: model, catalog: resources.catalog)
            let (moments, repairs) = ClipAutopilotValidator.moments(reply.object, context: prepared.context)
            progress?(.picked(moments))
            guard !moments.isEmpty else {
                return Self.result(ClipAutopilotSeries(plans: [], repairs: repairs), replies: [reply], model: reply.model, resources: resources)
            }
            let items = try Self.briefs(moments).map {
                try Self.prepare(input.clip($0.moment.startWord...$0.moment.endWord), resources: resources, connector: connector.id, moment: $0)
            }
            let outcome = try await Self.planAll(items, lanes: all, model: model, catalog: resources.catalog, progress: progress)
            let series = ClipAutopilotValidator.series(outcome.plans, moments: moments, failures: outcome.failures, repairs: repairs)
            return Self.result(series, replies: [reply] + outcome.replies, model: outcome.replies.first?.model ?? reply.model, resources: resources)
        }
    }

    // MARK: Sending

    struct Lane: Sendable {
        let runner: LLMRunner
        let connector: any LLMConnector
    }

    struct Prepared: Sendable {
        let request: LLMRequest
        let context: ClipAutopilotContext
    }

    /// Every shared file a plan reads, read once per call.
    struct Resources {
        let prompt: ClipAutopilotPrompt
        let styles: [CaptionStyle]
        let fonts: [ClipAutopilotPlan.Font: String]
        let catalog: LLMCatalog
        init(shared: SharedResources) throws {
            prompt = try ClipAutopilotPrompt(shared: shared)
            styles = try CaptionStyleLibrary(shared: shared).styles
            fonts = try ClipAutopilotFonts.load(shared: shared)
            catalog = try LLMCatalog(shared: shared)
        }
    }

    /// One send through `lane`, after the model's context check (§12.8).
    static func send(_ prepared: Prepared, lane: Lane, model: String, catalog: LLMCatalog) async throws -> LLMResult {
        let request = prepared.request
        if lane.connector.id != .appleFoundation {
            let policy = AITokenPolicy(catalog.document[ai: "policy"])
            let context = try await catalog.resolvedContextTokens(connector: lane.connector, model: model)
            let required = VoiceLabLLMChecks.requiredTokens(policy, text: request.system + (request.cachedBlock ?? "") + request.instruction,
                schema: try request.schema.aiCompact(), maxOutputTokens: request.maxOutputTokens)
            guard VoiceLabLLMChecks.contextFits(context: context, required: required, safetyFactor: policy.safetyFactor) else {
                throw LLMError.contextTooLong
            }
        }
        try Task.checkCancellation()
        let reply = try await lane.runner.run(request, on: lane.connector, model: model)
        try Task.checkCancellation()
        return reply
    }

    /// The clip plans of `items`, each lane sending one at a time, in item order as lanes free up. A failed plan is nil and
    /// its reason is in `failures`; when every plan fails the first error is thrown. Cancellation always throws.
    static func planAll(_ items: [Prepared], lanes: [Lane], model: String, catalog: LLMCatalog,
                        progress: (@Sendable (ClipAutopilotProgress) -> Void)?) async throws
        -> (plans: [ClipAutopilotPlan?], replies: [LLMResult], failures: [Int: String]) {
        typealias Finished = (lane: Int, item: Int, outcome: Result<(LLMResult, ClipAutopilotPlan?), any Error>)
        var plans = [ClipAutopilotPlan?](repeating: nil, count: items.count)
        var replies: [LLMResult?] = Array(repeating: nil, count: items.count)
        var failures: [Int: String] = [:]
        var firstError: (any Error)?
        try await withThrowingTaskGroup(of: Finished.self) { group in
            var next = 0
            func start(_ lane: Int) {
                let item = next, prepared = items[item], chosen = lanes[lane]
                next += 1
                progress?(.planning(clip: item, of: items.count))
                group.addTask {
                    do {
                        let reply = try await send(prepared, lane: chosen, model: model, catalog: catalog)
                        return (lane, item, .success((reply, ClipAutopilotValidator.plan(reply.object, context: prepared.context))))
                    } catch {
                        return (lane, item, .failure(error))
                    }
                }
            }
            for lane in lanes.indices where next < items.count { start(lane) }
            while let finished = try await group.next() {
                switch finished.outcome {
                case .success(let (reply, plan)):
                    replies[finished.item] = reply
                    plans[finished.item] = plan
                    if plan == nil { failures[finished.item] = "the plan has no words of the clip" }
                    if let plan { progress?(.ready(clip: finished.item, of: items.count, plan)) }
                    progress?(plan == nil ? .failed(clip: finished.item, of: items.count) : .planned(clip: finished.item, of: items.count))
                case .failure(let error):
                    if Task.isCancelled || error is CancellationError || (error as? LLMError) == .cancelled {
                        group.cancelAll()
                        throw LLMError.cancelled
                    }
                    failures[finished.item] = "the plan failed: \((error as? LLMError)?.caseName ?? "error")"
                    firstError = firstError ?? error
                    progress?(.failed(clip: finished.item, of: items.count))
                }
                if next < items.count { start(finished.lane) }
            }
        }
        if plans.allSatisfy({ $0 == nil }), let firstError { throw firstError }
        return (plans, replies.compactMap { $0 }, failures)
    }

    static func result(_ series: ClipAutopilotSeries, replies: [LLMResult], model: String, resources: Resources) -> ClipAutopilotResult {
        func sum(_ part: (LLMUsage) -> Int?) -> Int? {
            let values = replies.compactMap { $0.usage.flatMap(part) }
            return values.isEmpty ? nil : values.reduce(0, +)
        }
        let reported = replies.contains { $0.usage != nil }
        let usage = reported ? LLMUsage(input: sum(\.input), output: sum(\.output), cacheRead: sum(\.cacheRead), cacheWrite: sum(\.cacheWrite)) : nil
        return ClipAutopilotResult(series: series, model: model, usedFallback: replies.contains(where: \.usedFallback),
                                   droppedItems: replies.reduce(0) { $0 + $1.droppedItems }, usage: usage,
                                   promptVersion: resources.prompt.promptVersion, promptSHA256: resources.prompt.sha256)
    }

    // MARK: Requests

    /// The second stage's briefs: each moment's rank and the caption styles of the others.
    static func briefs(_ moments: [ClipAutopilotMoment]) -> [ClipAutopilotMomentBrief] {
        moments.enumerated().map { index, moment in
            let others = moments.enumerated().filter { $0.offset != index }.map(\.element)
            return ClipAutopilotMomentBrief(rank: index + 1, count: moments.count, moment: moment,
                                            otherStyles: others.map(\.captionStyle).filter { !$0.isEmpty }, others: others)
        }
    }

    /// The request and checking context of a clip or series request; a series request is its first stage.
    static func prepare(_ input: ClipAutopilotRequest, resources: Resources, connector: ConnectorID,
                        moment: ClipAutopilotMomentBrief? = nil) throws -> Prepared {
        let prompt = resources.prompt
        let state = try EditState(transcript: input.transcript, edits: input.edits)
        let rendered = try ClipAutopilotRequestBuilder.render(input, prompt: prompt, styles: resources.styles, fonts: resources.fonts,
                                                              pauses: state.pauses, moment: moment)
        let moments = input.isSeries
        let system = moments ? prompt.momentsSystem : prompt.system
        guard (system + rendered.cachedBlock + rendered.instruction).utf8.count <= 400_000 else { throw LLMError.contextTooLong }
        let promptCap = moments ? prompt.momentsOutputTokens : prompt.clipOutputTokens
        let output = min(promptCap, resources.catalog.connector(connector)[ai: "maxOutputTokensCap"].aiInt ?? promptCap)
        // Extra high replies take minutes: a plan waits at least the prompt file's minimum, more when the catalog allows it.
        let timeout = max(resources.catalog.timeout(for: connector, feature: .clipAutopilot), prompt.minimumTimeout)
        let request = LLMRequest(feature: .clipAutopilot, system: system, cachedBlock: rendered.cachedBlock, instruction: rendered.instruction,
            schemaName: moments ? prompt.momentsSchemaName : prompt.schemaName, schema: moments ? prompt.momentsSchema : prompt.schema,
            maxOutputTokens: output, effort: moments ? Self.momentsEffort : Self.effort, timeout: timeout,
            language: input.language ?? input.transcript.language,
            tag: moments ? "clip-autopilot-moments" : moment == nil ? "clip-autopilot" : "clip-autopilot-series-clip")
        let context = ClipAutopilotContext(words: input.transcript.words, corrections: input.edits.corrections,
            cutWordIDs: Set(input.edits.cutWordIds), pauses: state.pauses, cutPauseIDs: Set(input.edits.cutPauseIds),
            pauseKeepSeconds: input.edits.pauseKeepSeconds, scope: rendered.scope, styleIDs: Set(resources.styles.map(\.id)),
            fonts: resources.fonts, preference: input.captionPreference, prompt: prompt, tone: moments ? nil : input.tone)
        return Prepared(request: request, context: context)
    }
}
