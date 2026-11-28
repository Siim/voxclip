import VoxClipCore

actor ScriptedConnector: LLMConnector {
    struct Exhausted: Error {}
    typealias Reply = @Sendable (LLMRequest, String) async throws -> RawCompletion

    nonisolated let id: ConnectorID
    private let script: [Reply]
    private(set) var requests: [LLMRequest] = []

    init(id: ConnectorID = .claudeCode, script: [Reply]) {
        self.id = id
        self.script = script
    }

    init(id: ConnectorID = .claudeCode, replies: [JSONValue]) {
        self.init(id: id, script: replies.map { reply in
            { _, model in RawCompletion(object: reply, model: model, stop: .complete) }
        })
    }

    func status() -> ConnectorStatus { .ready }
    func models(refresh: Bool) -> [LLMModel] { [] }
    func contextTokens(model: String) -> Int? { nil }

    func send(_ request: LLMRequest, model: String) async throws -> RawCompletion {
        let index = requests.count
        requests.append(request)
        guard script.indices.contains(index) else { throw Exhausted() }
        return try await script[index](request, model)
    }
}
