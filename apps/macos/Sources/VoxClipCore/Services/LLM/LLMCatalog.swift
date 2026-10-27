import Foundation

extension LLMCatalog {
    public static func load(shared: SharedResources) throws -> LLMCatalog {
        try LLMCatalog(shared: shared)
    }

    public init(shared: SharedResources) throws {
        let data = try Data(contentsOf: shared.root.appendingPathComponent("catalog/llm-providers.json"))
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        guard value[ai: "schemaVersion"].aiInt == 1 else { throw VoxClipError.sharedResourcesMissing }
        self.init(document: value)
    }

    public func connector(_ id: ConnectorID) -> JSONValue {
        document[ai: "connectors"].aiArray.first { $0[ai: "id"].aiString == id.rawValue } ?? .null
    }

    public func curatedModels(for id: ConnectorID) -> [LLMModel] {
        connector(id)[ai: "models"].aiArray.compactMap { item in
            guard let modelID = item[ai: "id"].aiString else { return nil }
            return LLMModel(id: modelID, name: item[ai: "name"].aiString ?? modelID, tier: item[ai: "tier"].aiString, contextTokens: item[ai: "contextTokens"].aiInt, source: .curated)
        }
    }

    func resolvedContextTokens(connector: any LLMConnector, model: String, models: [LLMModel]? = nil) async throws -> Int {
        if let context = await connector.contextTokens(model: model) { return context }
        let choices: [LLMModel]
        if let models { choices = models } else { choices = try await connector.models(refresh: false) }
        if let context = choices.first(where: { $0.id == model })?.contextTokens { return context }
        if let context = curatedModels(for: connector.id).first(where: { $0.id == model })?.contextTokens { return context }
        switch connector.id {
        case .ollama, .lmstudio: return 4_096
        case .appleFoundation: throw LLMError.unavailable(reason: "The runtime context size is unavailable.")
        default: return 128_000
        }
    }

    public func fallback(for id: ConnectorID, model: String) -> String? {
        connector(id)[ai: "fallbackOrder"].aiArray.compactMap(\.aiString).first { $0 != model }
    }

    public func timeout(for id: ConnectorID, feature: LLMFeature) -> Duration {
        let policy = document[ai: "policy"][ai: "timeoutsSeconds"]
        let kind: String
        switch id {
        case .claudeCode, .codex: kind = feature == .test ? "cliTest" : "cli"
        case .ollama, .lmstudio: kind = feature == .test ? "test" : "localServer"
        case .appleFoundation: kind = feature == .test ? "test" : "appleFoundation"
        default: kind = feature == .test ? "test" : "cloud"
        }
        return .seconds(policy[ai: kind].aiDouble ?? 180)
    }

    public func connectionTest(for id: ConnectorID) throws -> LLMRequest {
        let test = document[ai: "testRequest"]
        guard let system = test[ai: "system"].aiString, let instruction = test[ai: "instruction"].aiString,
              CanonicalResponseParser.validateSchemaSubset(test[ai: "schema"]) else { throw VoxClipError.sharedResourcesMissing }
        return LLMRequest(feature: .test, system: system, instruction: instruction, schemaName: test[ai: "schemaName"].aiString ?? "connection_test", schema: test[ai: "schema"], maxOutputTokens: test[ai: "maxOutputTokens"].aiInt ?? 2048, effort: .low, timeout: timeout(for: id, feature: .test), language: "en", tag: "test")
    }
}

public struct LLMConnectionTestResult: Sendable, Equatable {
    public var passed: Bool
    public var model: String
    public var usedFallback: Bool
    public var seconds: Double
}

extension LLMRunner {
    public func test(on connector: any LLMConnector, model: String) async throws -> LLMConnectionTestResult {
        let started = ContinuousClock.now
        let result = try await run(catalog.connectionTest(for: connector.id), on: connector, model: model)
        let duration = started.duration(to: .now).components
        return LLMConnectionTestResult(passed: result.object[ai: "ok"].aiBool == true && AIText.trim(result.object[ai: "echo"].aiString ?? "").lowercased() == "voxclip", model: result.model, usedFallback: result.usedFallback, seconds: Double(duration.seconds) + Double(duration.attoseconds) / 1e18)
    }
}

internal func aiUserContent(_ request: LLMRequest) -> String {
    request.cachedBlock.map { $0 + "\n\n" + request.instruction } ?? request.instruction
}

internal func aiDurationSeconds(_ duration: Duration) -> Double {
    let parts = duration.components
    return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
}
