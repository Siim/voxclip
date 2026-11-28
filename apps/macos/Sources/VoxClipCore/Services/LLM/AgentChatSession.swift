import Foundation

@MainActor public final class AgentChatSession {
    public struct Question: Sendable, Equatable {
        public let text: String
        public let answers: [String]
    }

    public enum Status: Sendable, Equatable {
        case idle, running(String), finished, stopped, budget(Int), question(Question)
        case unavailable(ConnectorStatus), failed(String), modelUnavailable(String), approvalRequired(AgentChatApproval)
    }

    public struct Context: Sendable {
        public var clipID: String?
        public var playhead: Double?
        public var selection: [AgentTurn.Context]
        public var capLeft: Decimal?

        public init(clipID: String? = nil, playhead: Double? = nil, selection: [AgentTurn.Context] = [], capLeft: Decimal? = nil) {
            self.clipID = clipID; self.playhead = playhead; self.selection = selection; self.capLeft = capLeft
        }
    }

    public private(set) var project: Project
    public private(set) var status: Status = .idle
    public private(set) var next: [String] = []
    public var context: Context
    public var onChange: (() -> Void)?

    let shared: SharedResources
    let connector: any LLMConnector
    private let model: String
    private let effort: Effort
    private let stepBudget: Int
    private let defaultMode: AgentThread.Mode
    private let estimatedUSD: ClosedRange<Decimal>?
    private var keyApprovedThreads: Set<String> = []
    let projectURL: URL?
    let decodeFrames: (@Sendable (URL, [Double]) async throws -> [HarnessResult.Frame])?
    let music: HarnessMusicLibrary?
    let check: (@Sendable (Project, String, [String]) throws -> JSONValue)?
    private let delay: @Sendable (Duration) async throws -> Void
    private let now: @Sendable () -> Date
    private let prompt: AgentChatPrompt
    var active = false
    var stopping = false
    private var queue: [AgentTurn.Request] = []
    private var steering: [AgentTurn.Request] = []
    private var suspended: Run?

    struct Run {
        var turn: AgentTurn
        var results: [JSONValue] = []
        var images: [LLMImage] = []
        var steering: [JSONValue] = []
        var feedback: String?
        var refusal: String?
        var refusedTool: String?
        var didMatchRetry = false
        var claims: [String] = []
        var asked = false
    }

    public init(project: Project, shared: SharedResources, connector: any LLMConnector, model: String,
                effort: Effort = .high, stepBudget: Int = 8, defaultMode: AgentThread.Mode = .propose,
                estimatedUSD: ClosedRange<Decimal>? = nil,
                context: Context = .init(), projectURL: URL? = nil,
                decodeFrames: (@Sendable (URL, [Double]) async throws -> [HarnessResult.Frame])? = nil,
                music: HarnessMusicLibrary? = nil,
                check: (@Sendable (Project, String, [String]) throws -> JSONValue)? = nil,
                now: @Sendable @escaping () -> Date = { Date() },
                delay: @Sendable @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) throws {
        self.project = project; self.shared = shared; self.connector = connector; self.model = model
        self.estimatedUSD = estimatedUSD
        self.effort = effort; self.stepBudget = max(1, stepBudget); self.defaultMode = defaultMode; self.context = context
        self.projectURL = projectURL; self.decodeFrames = decodeFrames
        self.music = music; self.check = check; self.delay = delay; self.now = now
        prompt = try AgentChatPrompt(shared: shared)
    }

    public func updateProject(_ live: Project) {
        guard live.id == project.id else { return }
        project = live
    }

    public func send(_ request: AgentTurn.Request) async {
        if active { queue.append(request); return }
        if case .approvalRequired = status { queue.append(request); return }
        if case .question = status, suspended != nil { await resume(with: request); return }
        queue.append(request)
        await drain()
    }

    public func steer(_ request: AgentTurn.Request) async {
        if active && !stopping { steering.append(request) }
        else { await send(request) }
    }

    public func stop() { if active { stopping = true } }

    public func respond(to approval: AgentChatApproval, allow: Bool) async {
        guard !active, status == .approvalRequired(approval), approval.threadID == threadID else { return }
        setStatus(.idle)
        guard allow else { queue.removeAll(); steering.removeAll(); suspended = nil; return }
        keyApprovedThreads.insert(approval.threadID)
        if suspended != nil { await resume() } else { await drain() }
    }

    public func resume(with answer: AgentTurn.Request? = nil) async {
        guard !active, var run = suspended, var thread = project.agentThread,
              let last = thread.turns.last, last.id == run.turn.id else { return }
        if case .question = status, answer == nil { return }
        run.turn = last
        if let answer { steering.append(answer) }
        active = true; stopping = false
        if let blocker = await preflight() { setStatus(blocker); active = false; return }
        suspended = nil
        run.turn.state = .running
        thread.turns[thread.turns.count - 1].state = .running
        project.agentThread = thread
        await execute(run)
        active = false
        await drain()
    }

    private func drain() async {
        guard !active else { return }
        active = true
        defer { active = false }
        while !queue.isEmpty {
            if case .question = status { break }
            if case .approvalRequired = status { break }
            suspended = nil; stopping = false
            if let blocker = await preflight() {
                if case .approvalRequired = blocker {} else { queue.removeFirst() }
                setStatus(blocker)
                break
            }
            if stopping || Task.isCancelled { break }
            let request = queue.removeFirst()
            let turns = project.agentThread?.turns ?? []
            let ordinal = (turns.compactMap { Int($0.id.dropFirst()) }.max() ?? 0) + 1
            let turn = AgentTurn(id: "t\(ordinal)", createdAt: now(), request: request, connector: connector.id.rawValue, model: model)
            await execute(Run(turn: turn))
            steering.removeAll()
        }
    }

    private func execute(_ initial: Run) async {
        var run = initial
        next = []
        do {
            try save(run.turn)
            var index = 0
            var badReply = false
            while index < stepBudget || run.feedback != nil && run.didMatchRetry {
                if stopping || Task.isCancelled { break }
                if index > 0, let blocker = await preflight() {
                    try finish(&run, status: blocker, resumable: true)
                    return
                }
                run.steering += steering.map(AgentChatPrompt.json)
                steering.removeAll()
                setStatus(.running(run.turn.summary))
                let requestSnapshot = project
                let request = await makeRequest(run)
                guard !stopping, !Task.isCancelled else { break }
                let reply: AgentChatReply
                do {
                    let raw = try await complete(request)
                    guard !stopping, !Task.isCancelled else { break }
                    reply = try AgentChatReply(raw)
                    badReply = false
                } catch LLMError.invalidOutput(let reason) {
                    guard !stopping, !Task.isCancelled else { break }
                    if badReply { throw LLMError.invalidOutput(reason: reason) }
                    badReply = true
                    run.feedback = "Your reply did not match agent_step: \(reason) Reply again using the required schema."
                    continue
                }
                index += 1
                run.feedback = nil
                run.turn.summary = reply.say
                if !reply.done { setStatus(.running(reply.say)) }
                let stale = requestSnapshot != project
                for call in reply.calls {
                    if stopping || Task.isCancelled { break }
                    try await perform(call, run: &run, stale: stale)
                }
                if stopping || Task.isCancelled { break }
                if let question = reply.question, !run.asked, mode != .claude {
                    run.asked = true
                    try finish(&run, status: .question(question), resumable: true)
                    return
                }
                guard reply.done else { continue }
                if !steering.isEmpty, index < stepBudget { continue }
                let mismatch = AgentChatMatch.missing(in: reply.say, changes: run.turn.changes, revised: run.claims)
                if let mismatch, !run.didMatchRetry {
                    run.didMatchRetry = true
                    run.feedback = "Your summary mentions \(mismatch), but no \(mismatch) change was made. Fix it or correct the summary."
                    continue
                }
                next = reply.next
                if run.turn.check == nil, let check, let clip = openClipID,
                   let result = try? check(project, clip, []) { run.turn.check = Self.readCheck(result) }
                if let mismatch { appendCheck("Claude said it added \(mismatch), but nothing changed there.", to: &run.turn) }
                if let refusal = run.refusal { appendCheck("Couldn't make this change: \(refusal)", to: &run.turn) }
                try finish(&run, status: .finished)
                return
            }
            if stopping || Task.isCancelled {
                try finish(&run, status: .stopped, resumable: false)
            } else {
                try finish(&run, status: .budget(stepBudget), resumable: true)
            }
        } catch {
            let outcome: Status = stopping || Task.isCancelled ? .stopped : failure(error)
            do { try finish(&run, status: outcome, resumable: outcome != .stopped) }
            catch { setStatus(.failed("Couldn't save the chat turn. The project and paid output are intact.")) }
        }
    }

    private func complete(_ request: LLMRequest) async throws -> RawCompletion {
        let retries = [2, 8, 30]
        for seconds in retries {
            do { return try await connector.send(request, model: model) }
            catch let error as LLMError where error == .network || error == .timeout {
                guard !stopping, !Task.isCancelled else { throw CancellationError() }
                try await delay(.seconds(seconds))
                guard !stopping, !Task.isCancelled else { throw CancellationError() }
            }
        }
        return try await connector.send(request, model: model)
    }

    private func failure(_ error: Error) -> Status {
        switch error as? LLMError {
        case .modelNotFound(let name): .modelUnavailable(name)
        case .invalidOutput: .failed("Claude's reply couldn't be read. What's done is pending.")
        case .network, .timeout: .failed("Couldn't reach \(connector.id.rawValue). Nothing changed in this step.")
        case .cancelled: .stopped
        default: .failed("The chat step failed. The project and paid output are intact.")
        }
    }

    private var threadID: String { project.agentThread?.id ?? "agent-\(project.id)" }

    private func preflight() async -> Status? {
        guard [.claudeCode, .codex, .anthropic, .openai].contains(connector.id) else {
            return .unavailable(.unavailable(reason: "This connector isn't available for agent chat."))
        }
        let availability = await connector.status()
        guard availability == .ready else { return .unavailable(availability) }
        let signIn: CLISignIn
        switch connector.id {
        case .claudeCode, .codex:
            guard let billing = CLISignIn.agentChatBilling(await connector.knownCLIAuthMethod(), connector: connector.id) else {
                return .unavailable(.unavailable(reason: "VoxClip couldn't tell how this connector is signed in."))
            }
            signIn = billing
        default: signIn = .apiKey
        }
        guard signIn == .apiKey, !keyApprovedThreads.contains(threadID) else { return nil }
        return .approvalRequired(.init(connector: connector.id, model: model, estimatedUSD: estimatedUSD, threadID: threadID))
    }

    private func finish(_ run: inout Run, status outcome: Status, resumable: Bool = false) throws {
        switch outcome {
        case .finished:
            run.turn.state = mode == .claude || run.turn.changes.isEmpty && run.turn.offers.isEmpty ? .kept : .pending
        case .question:
            run.turn.state = run.turn.changes.isEmpty ? .running : .pending
        case .failed, .modelUnavailable:
            run.turn.state = run.turn.changes.isEmpty ? .failed : .partial
        default:
            run.turn.state = .stopped
        }
        try save(run.turn)
        if resumable { suspended = run }
        setStatus(outcome)
    }

    func save(_ turn: AgentTurn, in candidate: Project? = nil) throws {
        var basis = candidate ?? project
        let thread = basis.agentThread ?? AgentThread(id: "agent-\(project.id)", mode: mode)
        var checkpoint = turn
        if let current = thread.turns.last, current.id == turn.id {
            checkpoint.events = current.events
            let currentOffers = Dictionary(uniqueKeysWithValues: current.offers.map { ($0.id, $0) })
            checkpoint.offers = turn.offers.map { currentOffers[$0.id] ?? $0 }
        }
        basis.agentThread = thread
        project = try AgentTurns.record(checkpoint, in: basis, threadId: thread.id)
        onChange?()
    }

    var mode: AgentThread.Mode { project.agentThread?.mode ?? defaultMode }

    var openClipID: String? { context.clipID ?? project.edits.clips.first(where: \.selected)?.id }

    private func setStatus(_ value: Status) { status = value; onChange?() }

    func appendCheck(_ line: String, to turn: inout AgentTurn) {
        turn.check = .init(ok: false, lines: (turn.check?.lines ?? []) + [line])
    }

    static func readCheck(_ value: JSONValue) -> AgentTurn.Check? {
        guard let ok = value[ai: "ok"].aiBool else { return nil }
        return .init(ok: ok, lines: value[ai: "lines"].aiArray.compactMap(\.aiString))
    }

    private func makeRequest(_ run: Run) async -> LLMRequest {
        let instruction = prompt.instruction(digest: await digest(), thread: history(excluding: run.turn.id),
                                             message: AgentChatPrompt.json(run.turn.request), results: run.results,
                                             steering: run.steering, feedback: run.feedback)
        var request = LLMRequest(feature: .agentChat, system: prompt.system, instruction: instruction, schemaName: prompt.schemaName,
                                 schema: prompt.schema, maxOutputTokens: 4096, effort: effort, timeout: .seconds(120),
                                 tag: "agent-chat-v1", images: run.images)
        request.agentChatKeyApproved = keyApprovedThreads.contains(threadID)
        return request
    }
}
