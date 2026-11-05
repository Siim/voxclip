import AppKit
import Observation
import VoxClipCore

/// The one inline row for a connector request. A first API-key send combines privacy and billing in one click.
struct ConnectorSendPrompt: Equatable {
    enum Reason: Equatable { case privacy, cost }
    let reason: Reason
    let title: String
    var message: String
    let confirm: String
    var details: [String] = []
    var note = ""
    var pricingName = ""
    var pricingURL: URL?
    var firstUse = false
    var providerID = ""
    var providerName = ""
    var needsKey = false
    var billed: Bool { reason == .cost }
    var cancel: String { firstUse ? "Not now" : "Cancel" }
}

/// Shared by the billed Send and Transcribe buttons. Timestamps use AppKit's monotonic event clock.
struct PaidSendKeyGuard {
    private(set) var appearedAt: TimeInterval
    init(now: TimeInterval = ProcessInfo.processInfo.systemUptime) { appearedAt = now }
    mutating func reset(now: TimeInterval = ProcessInfo.processInfo.systemUptime) { appearedAt = now }
    func accepts(timestamp: TimeInterval, now: TimeInterval, isRepeat: Bool, command: Bool) -> Bool {
        !isRepeat && (command || timestamp >= appearedAt + 0.5 && now >= timestamp)
    }
}

/// One slot per editor (or Settings). Cancellation is request-scoped so an old task cannot close a newer row.
@MainActor @Observable final class ConnectorConfirmation {
    private(set) var prompt: ConnectorSendPrompt?
    private(set) var requestID: UUID?
    private(set) var keyGuard = PaidSendKeyGuard()
    var key = ""
    private(set) var keyError: String?
    private(set) var savingKey = false
    var onFinish: (@MainActor (Bool) -> Void)?
    @ObservationIgnored private var continuation: CheckedContinuation<Bool, Never>?
    @ObservationIgnored private var save: (@MainActor (String) async throws -> Void)?
    @ObservationIgnored private var current: @MainActor () -> Bool = { true }
    var isPresented: Bool { prompt != nil }

    func present(_ prompt: ConnectorSendPrompt, isCurrent: @escaping @MainActor () -> Bool,
                 saveKey: @escaping @MainActor (String) async throws -> Void) async -> Bool {
        cancel()
        let id = UUID()
        return await withTaskCancellationHandler {
            guard !Task.isCancelled else { return false }
            return await withCheckedContinuation { continuation in
                self.continuation = continuation; self.requestID = id
                self.prompt = prompt; self.current = isCurrent; self.save = saveKey
                key = ""; keyError = nil; savingKey = false; keyGuard.reset()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                if self?.requestID == id { self?.cancel() }
            }
        }
    }
    #if DEBUG
    func showForAudit(_ prompt: ConnectorSendPrompt) { cancel(); self.prompt = prompt; requestID = UUID(); keyGuard.reset() }
    #endif
    func approve() {
        guard let prompt, !prompt.needsKey, !savingKey, current() else { return }
        finish(true)
    }
    @discardableResult func pressReturn(timestamp: TimeInterval, now: TimeInterval, isRepeat: Bool, command: Bool) -> Bool {
        guard prompt != nil else { return false }
        if keyGuard.accepts(timestamp: timestamp, now: now, isRepeat: isRepeat, command: command) { approve() }
        return true // Swallow the opening/double Return as well as repeats.
    }
    func cancel() { finish(false) }
    private func finish(_ approved: Bool) {
        let pending = continuation, callback = onFinish
        let existed = prompt != nil
        continuation = nil; prompt = nil; requestID = nil; save = nil; current = { true }
        key = ""; keyError = nil; savingKey = false
        pending?.resume(returning: approved)
        if existed { callback?(approved) }
    }
    func saveKey() async {
        guard var prompt, let save, !savingKey, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let id = requestID
        savingKey = true; keyError = nil
        do {
            try await save(key)
            guard requestID == id else { return }
            key = ""; prompt.needsKey = false; self.prompt = prompt; keyGuard.reset()
        } catch {
            guard requestID == id else { return }
            keyError = "Couldn't save the key. Try saving it again."
        }
        if requestID == id { savingKey = false }
    }
}

extension ProviderChoice {
    var pricingName: String { id == "claude-code" ? "Anthropic" : id == "codex" ? "OpenAI" : label }
    var cliName: String? { id == "claude-code" ? "Claude Code" : id == "codex" ? "Codex" : nil }
    var pricingURL: URL? {
        let urls = ["anthropic": "https://claude.com/pricing#api", "claude-code": "https://claude.com/pricing#api",
                    "openai": "https://platform.openai.com/pricing/", "codex": "https://platform.openai.com/pricing/",
                    "gemini": "https://ai.google.dev/gemini-api/docs/pricing", "xai": "https://docs.x.ai/developers/pricing"]
        return urls[id].flatMap(URL.init(string:))
    }
    func confirmationPrompt(action: ConnectorConsentAction, wordCount: Int, rewrite: DirectorScope? = nil,
                            price: String, firstUse: Bool = false, model: String = "", verb: String? = nil,
                            serverHost: String? = nil) -> ConnectorSendPrompt {
        let billed = !price.isEmpty
        let actionName = verb ?? (action == .rewrite ? "Rewrite" : action == .test ? "Test" : "Find clips")
        let scope = rewrite ?? DirectorScope(kind: .selection(inClip: false), wordCount: wordCount)
        let words: String
        if action == .test { words = "a short test request" }
        else if action == .pickCaptions { words = "the words of these clips (\(wordCount) words)" }
        else if action == .findClips && verb != "Hook" { words = "this project's transcript (\(wordCount) words)" }
        else { words = scope.words }
        let target = cliName.map { "\($0), billed to the API key it is signed in with" }
            ?? serverHost.map { "the \(label) server at \($0)" } ?? "\(label) with your key"
        let sends = actionName == "Ask" ? "Ask sends your question and \(words)" : "\(actionName) sends \(words)"
        var prompt = ConnectorSendPrompt(reason: billed ? .cost : .privacy, title: "Confirm send",
            message: "\(sends) to \(target).", confirm: billed ? (firstUse ? "Allow and Send" : "Send") : "Allow and \(actionName)")
        prompt.firstUse = firstUse; prompt.providerID = id; prompt.providerName = shortName
        if billed {
            prompt.details = ["No audio or video. " + (model.isEmpty ? "" : "\(model). ") + "Asks before each send."]
            if firstUse { prompt.details.append("First time with \(shortName): allowing it covers Find clips, Rewrite and Tighten. Each send still asks.") }
            prompt.note = price; prompt.pricingName = pricingName; prompt.pricingURL = pricingURL
        } else if let cliName {
            prompt.message = "VoxClip will run your installed \(cliName) with your own sign-in."
            let plan = id == "codex" ? "ChatGPT" : "Claude"
            let subject = action == .test ? "A short test request is sent" : "\(words.prefix(1).uppercased())\(words.dropFirst()) are sent"
            let usage = action == .test ? "counts" : "count"
            prompt.details = ["\(subject) to \(pricingName) and \(usage) toward your \(plan) plan's usage. No audio or video."]
            prompt.note = "Asked once per AI. Later sends start at once."
        } else {
            prompt.details = ["No audio or video."]
            prompt.note = "Asked once per AI. Later sends start at once."
        }
        return prompt
    }
}

extension AppModel {
    func cliSignIn(_ connector: ConnectorID) -> CLISignIn? {
        knownCLIAuthMethods[connector.rawValue + ":" + string("llm.cliPath.\(connector.rawValue)")].flatMap(CLISignIn.init(rawValue:))
    }
    func llmSendKind(_ connector: ConnectorID) -> VoiceLabCostPresentation.Kind? {
        let signIn = cliSignIn(connector)
        if (connector == .claudeCode || connector == .codex) && signIn == nil { return nil }
        let name = providers.first { $0.id == connector.rawValue }?.pricingName ?? connector.rawValue
        return VoiceLabCostPresentation.kind(forLLMSendTo: connector, signIn: signIn, providerName: name)
    }

    /// Detection is not a request. First use and per-send billing share one inline row; saving a key never sends.
    func authorizeConnectorRequest(_ provider: ProviderChoice, connector: any LLMConnector,
                                   action: ConnectorConsentAction, wordCount: Int = 0, rewrite: DirectorScope? = nil,
                                   confirmation: ConnectorConfirmation? = nil, verb: String? = nil,
                                   isCurrent: @escaping @MainActor () -> Bool = { true }) async throws -> Bool {
        let serverHost = localServerHost(provider)
        guard let status = await connectorStatus(provider, using: connector) else { return false }
        try Task.checkCancellation()
        var needsKey = false
        switch status {
        case .ready: break
        case .needsKey: needsKey = true
        case .noModels: throw LLMError.noModels
        case .cliMissing: throw LLMError.cliMissing
        case .cliSignedOut: throw LLMError.cliSignedOut
        case .cliTooOld(let version, let missing): throw LLMError.cliTooOld(version: version, missing: missing)
        case .notRunning(let url): throw LLMError.notRunning(url: url)
        case .unavailable(let reason): throw LLMError.unavailable(reason: reason)
        }
        func stillCurrent() -> Bool { !Task.isCancelled && isCurrent() && localServerHost(provider) == serverHost }
        guard stillCurrent(), let kind = llmSendKind(connector.id) else { return false }
        let firstUse = (provider.privacy == "thirdPartyCloud" || serverHost != nil) && !bool("llm.cloudConsent.\(provider.id)")
        let price: String
        if case .confirm(let copy) = kind { price = copy } else { price = "" }
        guard firstUse || !price.isEmpty || needsKey else { return true }
        let modelID = string("llm.model.\(provider.id)", fallback: provider.defaultModel ?? "")
        let model = provider.models.first { $0.id == modelID }?.name ?? modelID
        var prompt = provider.confirmationPrompt(action: action, wordCount: wordCount, rewrite: rewrite,
            price: price, firstUse: firstUse, model: model, verb: verb, serverHost: serverHost)
        prompt.needsKey = needsKey
        let approved: Bool
        if let connectorConsentOverride { approved = await connectorConsentOverride(provider, action, prompt) }
        else {
            approved = await (confirmation ?? settingsSendConfirmation).present(prompt, isCurrent: stillCurrent) { [self] value in
                try await saveProviderKey(value, for: provider.id)
            }
        }
        guard approved, stillCurrent() else { return false }
        if needsKey {
            guard await connectorStatus(provider, using: connector) == .ready else { throw LLMError.missingKey }
            guard stillCurrent() else { return false }
        }
        if firstUse { set("llm.cloudConsent.\(provider.id)", .bool(true)) }
        return true
    }
}
