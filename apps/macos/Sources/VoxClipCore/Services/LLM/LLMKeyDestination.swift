import Foundation

struct LLMKeyDestination: Sendable {
    let account: String
    let host: String
    let header: String
    let valueTemplate: String
    let environmentVariable: String

    static let pinned: [ConnectorID: LLMKeyDestination] = [
        .anthropic: .init(account: "llm-api-key-anthropic", host: "api.anthropic.com", header: "x-api-key", valueTemplate: "{key}", environmentVariable: "VOXCLIP_ANTHROPIC_API_KEY"),
        .openai: .init(account: "llm-api-key-openai", host: "api.openai.com", header: "Authorization", valueTemplate: "Bearer {key}", environmentVariable: "VOXCLIP_OPENAI_API_KEY"),
        .xai: .init(account: "llm-api-key-xai", host: "api.x.ai", header: "Authorization", valueTemplate: "Bearer {key}", environmentVariable: "VOXCLIP_XAI_API_KEY"),
        .gemini: .init(account: "llm-api-key-gemini", host: "generativelanguage.googleapis.com", header: "x-goog-api-key", valueTemplate: "{key}", environmentVariable: "VOXCLIP_GEMINI_API_KEY")
    ]

    func matches(_ auth: JSONValue) -> Bool {
        auth[ai: "keyAccount"].aiString == account && auth[ai: "header"].aiString == header &&
            auth[ai: "valueTemplate"].aiString == valueTemplate &&
            (auth[ai: "debugEnvVar"].aiString == nil || auth[ai: "debugEnvVar"].aiString == environmentVariable)
    }
}

extension LLMCatalog {
    func validateKeylessAuth(for id: ConnectorID) throws {
        guard LLMKeyDestination.pinned[id] == nil else { return }
        let auth = connector(id)[ai: "auth"]
        if auth == .null { return }
        guard let fields = auth.aiObject, fields["type"] == .string("none"),
              ["keyAccount", "header", "valueTemplate", "debugEnvVar"].allSatisfy({ fields[$0] == nil }) else {
            throw LLMError.unavailable(reason: "VoxClip is missing its AI configuration. Reinstall VoxClip.")
        }
    }
}
