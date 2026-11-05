import Foundation

/// A checked Ask Claude answer and where it came from (ai.md §18).
public struct AskClaudeResult: Sendable, Equatable {
    public let answer: AskClaudeAnswer
    public let model: String
    public let usedFallback: Bool
    /// Reply items the shared response parser dropped before validation because their types were wrong.
    public let droppedItems: Int
    public let usage: LLMUsage?
    public let promptVersion: Int
    public let promptSHA256: String
}

/// Ask Claude (ai.md §18): one instruction on a selection, clip or time range, answered with toolbox operations at extra
/// high effort and checked op by op. It never applies, generates or bills anything: the change list applies the free
/// operations as one undo group and keeps paid ones behind their priced click.
public struct AskClaudeService: Sendable {
    public let runner: LLMRunner
    public let prompt: AskClaudePrompt
    public let catalog: LLMCatalog

    public init(runner: LLMRunner, prompt: AskClaudePrompt, catalog: LLMCatalog) { self.runner = runner; self.prompt = prompt; self.catalog = catalog }

    /// The request `ask` sends, for previews and tests.
    public func request(_ instruction: String, selection: AskClaudeSelection, project: Project, detections: [AskClaudeDetection],
                        aspect: String, connector: ConnectorID) throws -> LLMRequest {
        let scope = try AskClaudeScope.resolve(selection, in: project)
        return prompt.request(instruction, scope: scope, project: project, detections: detections, aspect: aspect,
                              timeout: catalog.timeout(for: connector, feature: .askClaude), language: project.transcript?.language)
    }

    public func ask(_ instruction: String, selection: AskClaudeSelection, project: Project, detections: [AskClaudeDetection], aspect: String,
                    connector: any LLMConnector, model: String) async throws -> AskClaudeResult {
        guard !AIText.trim(instruction).isEmpty else { throw VoiceLabError.invalidInput }
        let scope = try AskClaudeScope.resolve(selection, in: project)
        let request = prompt.request(instruction, scope: scope, project: project, detections: detections, aspect: aspect,
                                     timeout: catalog.timeout(for: connector.id, feature: .askClaude), language: project.transcript?.language)
        let result = try await runner.run(request, on: connector, model: model)
        let answer = AskClaudeValidator(prompt: prompt, scope: scope, project: project, detections: detections).answer(result.object)
        return AskClaudeResult(answer: answer, model: result.model, usedFallback: result.usedFallback, droppedItems: result.droppedItems,
                               usage: result.usage, promptVersion: prompt.promptVersion, promptSHA256: prompt.sha256)
    }
}
