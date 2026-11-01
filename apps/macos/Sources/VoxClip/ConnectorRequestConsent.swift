import AppKit
import VoxClipCore

/// A sheet shown before an LLM send. `privacy` is the one-time consent per connector (ai.md §4.8); `cost` is the
/// confirmation an API-key send shows every time (voice-lab.md §3.1, user decision 1).
struct LLMSendSheet: Equatable {
    enum Reason: Equatable { case privacy, cost }
    let reason: Reason
    let title: String
    let message: String
    /// The default button. Cancel is always the other one.
    let confirm: String
}

extension ProviderChoice {
    /// Whose pricing applies to a send (`VoiceLabCostPresentation.kind(forLLMSendTo:signIn:providerName:)`): the vendor
    /// behind an installed CLI, else the catalog label.
    var pricingName: String { id == "claude-code" ? "Anthropic" : id == "codex" ? "OpenAI" : label }
    /// The short name of an installed CLI, nil for other connectors.
    var cliName: String? { id == "claude-code" ? "Claude Code" : id == "codex" ? "Codex" : nil }

    /// The confirmation for a send that asks every time: an API-key connector, or a CLI signed in with an API key.
    /// `price` is C8's unknown-price sentence. `wordCount` is the transcript's words for Find clips and the scope's for
    /// Rewrite; a Rewrite's `rewrite` names its scope (design.md R0b: "Rewrite clip 1?", "Sends the 118 words of clip 1 …").
    func costSheet(action: ConnectorConsentAction, wordCount: Int, rewrite: DirectorScope? = nil, price: String) -> LLMSendSheet {
        let target = cliName.map { "\($0), billed to the API key it is signed in with" } ?? "\(label) with your key"
        let words = wordCount == 1 ? "1 word" : "\(wordCount) words"
        switch action {
        case .findClips:
            return LLMSendSheet(reason: .cost, title: "Find clips?",
                message: "Sends this project's transcript (\(words), no audio or video) to \(target).\n\n\(price)", confirm: "Find Clips")
        case .rewrite:
            let scope = rewrite ?? DirectorScope(kind: .selection(inClip: false), wordCount: wordCount)
            return LLMSendSheet(reason: .cost, title: "\(scope.title)?", message: "Sends \(scope.words) to \(target).\n\n\(price)", confirm: "Rewrite")
        case .test:
            return LLMSendSheet(reason: .cost, title: "Send a test request?",
                message: "Sends a short test request to \(target). Nothing from your projects is sent.\n\n\(price)", confirm: "Test")
        }
    }
}

extension AppModel {
    /// The sign-in an installed CLI reported when it was last detected at its current path; nil for other connectors and
    /// for a CLI that is signed out, not checked yet or signed in by a method VoxClip does not recognise (ai.md §6.8, §6.9).
    func cliSignIn(_ connector: ConnectorID) -> CLISignIn? {
        knownCLIAuthMethods[connector.rawValue + ":" + string("llm.cliPath.\(connector.rawValue)")].flatMap(CLISignIn.init(rawValue:))
    }

    /// How an LLM send through `connector` presents its cost now (C8): inline for a send that costs nothing extra, confirm
    /// for an API key or a CLI signed in with one. Nil for a CLI with no known sign-in (signed out, not detected yet, or a
    /// method VoxClip does not recognise): that send neither starts nor asks (ai.md §4.8), so the Rewrite verb reads
    /// "Rewrite" with no price sentence (design §6.3.1), although C8 would confirm such a send.
    func llmSendKind(_ connector: ConnectorID) -> VoiceLabCostPresentation.Kind? {
        let signIn = cliSignIn(connector)
        if (connector == .claudeCode || connector == .codex) && signIn == nil { return nil }
        let name = providers.first { $0.id == connector.rawValue }?.pricingName ?? connector.rawValue
        return VoiceLabCostPresentation.kind(forLLMSendTo: connector, signIn: signIn, providerName: name)
    }

    /// The one route every LLM send takes: Find clips, Rewrite and Settings → Test. It detects the connector (ai.md
    /// §4.8: readiness first, so a CLI's sign-in is fresh), shows the one-time privacy consent before the connector's
    /// first send, and then asks C8's `kind(forLLMSendTo:signIn:providerName:)`. An inline send starts at once; a
    /// confirming send shows the cost sheet on every send and is never remembered. False sends nothing.
    func authorizeConnectorRequest(_ provider: ProviderChoice, connector: any LLMConnector,
                                   action: ConnectorConsentAction, wordCount: Int = 0, rewrite: DirectorScope? = nil, parent: NSWindow? = nil,
                                   isCurrent: @escaping @MainActor () -> Bool = { true }) async throws -> Bool {
        let serverHost = localServerHost(provider)
        guard let status = await connectorStatus(provider, using: connector) else { return false }
        try Task.checkCancellation()
        switch status {
        case .ready: break
        case .needsKey: throw LLMError.missingKey
        case .noModels: throw LLMError.noModels
        case .cliMissing: throw LLMError.cliMissing
        case .cliSignedOut: throw LLMError.cliSignedOut
        case .cliTooOld(let version, let missing): throw LLMError.cliTooOld(version: version, missing: missing)
        case .notRunning(let url): throw LLMError.notRunning(url: url)
        case .unavailable(let reason): throw LLMError.unavailable(reason: reason)
        }
        func stillCurrent() -> Bool { !Task.isCancelled && isCurrent() && localServerHost(provider) == serverHost }
        guard stillCurrent() else { return false }
        let consented = (provider.privacy != "thirdPartyCloud" && serverHost == nil) || bool("llm.cloudConsent.\(provider.id)")
        if !consented {
            let title = action == .rewrite ? "Rewrite" : action == .test ? "Test" : "Find clips"
            let privacy = LLMSendSheet(reason: .privacy, title: title, message: consentCopy(provider, action: action, wordCount: wordCount), confirm: "Continue")
            guard await present(privacy, provider: provider, action: action, parent: parent), stillCurrent() else { return false }
            set("llm.cloudConsent.\(provider.id)", .bool(true))
        }
        // No send without a known sign-in (ai.md §4.8). Detection reports such a CLI as signed out, but another detection
        // can forget the method while the consent sheet is up.
        guard let kind = llmSendKind(connector.id) else { return false }
        guard case .confirm(let price) = kind else { return true }
        let cost = provider.costSheet(action: action, wordCount: wordCount, rewrite: rewrite, price: price)
        return await present(cost, provider: provider, action: action, parent: parent) && stillCurrent()
    }

    private func present(_ sheet: LLMSendSheet, provider: ProviderChoice, action: ConnectorConsentAction, parent: NSWindow?) async -> Bool {
        await ConnectorConsentWait().confirm { [self] in
            if let connectorConsentOverride { return await connectorConsentOverride(provider, action, sheet) }
            guard let window = parent ?? NSApp.keyWindow else { return false }
            return await RewriteApprovalSheet(title: sheet.title, copy: sheet.message, confirm: sheet.confirm, parent: window).confirm()
        }
    }
}
