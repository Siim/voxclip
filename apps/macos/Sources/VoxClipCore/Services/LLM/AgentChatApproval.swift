import Foundation

public struct AgentChatApproval: Sendable, Equatable {
    public enum Action: String, Sendable { case agentChat }

    public let action: Action = .agentChat
    public let connector: ConnectorID
    public let model: String
    public let estimatedUSD: ClosedRange<Decimal>?
    let threadID: String
    let nonce = UUID()

    public var billing: String {
        let key = connector == .openai || connector == .codex ? "OpenAI" : "Anthropic"
        return "Billed to your \(key) key"
    }
}

extension CLISignIn {
    static func agentChatBilling(_ raw: String?, connector: ConnectorID) -> CLISignIn? {
        guard let raw else { return nil }
        let method = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: "-", with: "_").replacingOccurrences(of: ".", with: "_")
        if ["api_key", "apikey"].contains(method) { return .apiKey }
        let plans = connector == .claudeCode ? ["plan", "claude_ai", "claudeai", "oauth", "oauth_token"] : ["plan", "chatgpt"]
        return plans.contains(method) ? .plan : nil
    }
}
