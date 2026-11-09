import Foundation

/// Talk back to Claude about one change (design.md §6.3 "Talk back to Claude", ai.md §12.12, ADR-R50): one request on the
/// chosen connector, answered with checked spoken words, a note and next steps. It never voices, prices or applies
/// anything: the thread puts a new version in the change's place through the local edit, and only the version that is
/// kept goes on to Rewrite's voice and price steps.
public struct RewriteFollowupService: Sendable {
    public let runner: LLMRunner
    public let prompt: RewriteFollowupPrompt
    public let catalog: LLMCatalog

    public init(runner: LLMRunner, prompt: RewriteFollowupPrompt, catalog: LLMCatalog) {
        self.runner = runner; self.prompt = prompt; self.catalog = catalog
    }

    /// The request `send` sends, for previews and tests.
    public func request(_ input: RewriteFollowupRequest, connector: ConnectorID) throws -> LLMRequest {
        try prompt.request(input, timeout: catalog.timeout(for: connector, feature: .voiceRewrite))
    }

    public func send(_ input: RewriteFollowupRequest, connector: any LLMConnector, model: String) async throws -> RewriteFollowupReply {
        let request = try request(input, connector: connector.id)
        let result = try await runner.run(request, on: connector, model: model)
        return try prompt.reply(result.object, for: input)
    }
}
