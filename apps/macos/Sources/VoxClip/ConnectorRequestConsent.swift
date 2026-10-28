import AppKit
import VoxClipCore

extension AppModel {
    func authorizeConnectorRequest(_ provider: ProviderChoice, connector: any LLMConnector,
                                   action: ConnectorConsentAction, wordCount: Int = 0, parent: NSWindow? = nil,
                                   isCurrent: @escaping @MainActor () -> Bool = { true }) async throws -> Bool {
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
        guard isCurrent() else { return false }
        if provider.privacy != "thirdPartyCloud" || bool("llm.cloudConsent.\(provider.id)") { return true }
        let copy = consentCopy(provider, action: action, wordCount: wordCount)
        let title = action == .rewrite ? "Rewrite" : action == .test ? "Test" : "Find clips"
        let approved = await ConnectorConsentWait().confirm { [self] in
            if let connectorConsentOverride { return await connectorConsentOverride(provider, action, copy) }
            guard let window = parent ?? NSApp.keyWindow else { return false }
            return await RewriteApprovalSheet(title: title, copy: copy, parent: window).confirm()
        }
        guard approved, !Task.isCancelled, isCurrent() else { return false }
        set("llm.cloudConsent.\(provider.id)", .bool(true))
        return true
    }
}
