import Foundation

public enum LLMConnectors {
    public static func make(_ id: ConnectorID, catalog: LLMCatalog, keys: any KeyProvider,
                            processes: any ProcessRunner, settings: SettingsDocument) -> any LLMConnector {
        let config = catalog.connector(id)
        let label = config[ai: "label"].aiString ?? id.rawValue
        guard config != .null else {
            return UnavailableLLMConnector(id: id, reason: "VoxClip is missing its AI configuration. Reinstall VoxClip.")
        }
        do { try catalog.validateKeylessAuth(for: id) }
        catch {
            return UnavailableLLMConnector(id: id, reason: "VoxClip is missing its AI configuration. Reinstall VoxClip.")
        }
        guard config[ai: "enabled"].aiBool != false else {
            return UnavailableLLMConnector(id: id, reason: "\(label) is not enabled.")
        }
        if id == .appleFoundation { return StubLLMConnector(id: .appleFoundation) }
        let log = RedactingLogger(homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
        if id == .claudeCode || id == .codex {
            let path = settings.values["llm.cliPath.\(id.rawValue)"]?.aiString ?? ""
            return CLIConnector(id: id, runner: processes, catalog: catalog, log: log,
                                executable: path.isEmpty ? nil : URL(fileURLWithPath: path))
        }
        do {
            let value = id == .ollama || id == .lmstudio
                ? settings.values["llm.baseUrl.\(id.rawValue)"]?.aiString ?? "" : ""
            let baseURL: URL?
            if value.isEmpty { baseURL = nil }
            else {
                guard let parsed = URL(string: value) else {
                    throw LLMError.unavailable(reason: "\(label)'s server address in Settings isn't valid.")
                }
                baseURL = parsed
            }
            return try HTTPConnector(id: id, keys: keys, catalog: catalog, log: log, baseURL: baseURL,
                                     cacheURL: DataLocations().cache.appendingPathComponent("llm-models.json"))
        } catch {
            let failure = error as? LLMError ?? .unavailable(reason: "VoxClip is missing its AI configuration. Reinstall VoxClip.")
            return UnavailableLLMConnector(id: id, reason: failure.userMessage(label: label, includeEditsSaved: false) ?? "")
        }
    }
}

private struct UnavailableLLMConnector: LLMConnector {
    let id: ConnectorID
    let reason: String

    func status() async -> ConnectorStatus { .unavailable(reason: reason) }
    func models(refresh: Bool) async throws -> [LLMModel] { throw LLMError.unavailable(reason: reason) }
    func contextTokens(model: String) async -> Int? { nil }
    func send(_ request: LLMRequest, model: String) async throws -> RawCompletion {
        throw LLMError.unavailable(reason: reason)
    }
}
