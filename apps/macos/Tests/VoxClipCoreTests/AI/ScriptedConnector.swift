import VoxClipCore

actor ScriptedConnector: LLMConnector {
    struct Exhausted: Error {}
    typealias Reply = @Sendable (LLMRequest, String) async throws -> RawCompletion

    nonisolated let id: ConnectorID
    nonisolated let authMethod: String?
    private let script: [Reply]
    private(set) var requests: [LLMRequest] = []

    init(id: ConnectorID = .claudeCode, authMethod: String? = "plan", script: [Reply]) {
        self.id = id
        self.authMethod = authMethod
        self.script = script
    }

    init(id: ConnectorID = .claudeCode, authMethod: String? = "plan", replies: [JSONValue]) {
        self.init(id: id, authMethod: authMethod, script: replies.map { reply in
            { _, model in RawCompletion(object: reply, model: model, stop: .complete) }
        })
    }

    func status() -> ConnectorStatus { .ready }
    func knownCLIAuthMethod() -> String? { authMethod }
    func models(refresh: Bool) -> [LLMModel] { [] }
    func contextTokens(model: String) -> Int? { nil }

    func send(_ request: LLMRequest, model: String) async throws -> RawCompletion {
        let index = requests.count
        requests.append(request)
        guard script.indices.contains(index) else { throw Exhausted() }
        return try await script[index](request, model)
    }
}
