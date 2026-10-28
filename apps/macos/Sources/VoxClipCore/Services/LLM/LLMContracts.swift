import Foundation

/// Connector identity; AI §3.1.
public enum ConnectorID: String, Codable, Sendable, Hashable, CaseIterable {
    case anthropic
    case openai
    case xai
    case gemini
    case ollama
    case lmstudio
    case appleFoundation = "apple-foundation"
    case claudeCode = "claude-code"
    case codex
}

/// Canonical feature; AI §3.1.
public enum LLMFeature: String, Codable, Sendable, Hashable, CaseIterable {
    case clipFinder
    case aiTighten
    case voiceRewrite
    case test
}

/// Reasoning policy; AI §3.1.
public enum Effort: String, Codable, Sendable, Hashable, CaseIterable {
    case low
    case medium
    case high
}

/// Canonical request; AI §3.1. Credentials never enter this value.
public struct LLMRequest: Sendable, Equatable {
    public var feature: LLMFeature
    public var system: String
    public var cachedBlock: String?
    public var instruction: String
    public var schemaName: String
    public var schema: JSONValue
    public var maxOutputTokens: Int
    public var effort: Effort?
    public var timeout: Duration
    public var language: String?
    public var tag: String
    public init(feature: LLMFeature, system: String, cachedBlock: String? = nil, instruction: String, schemaName: String, schema: JSONValue, maxOutputTokens: Int, effort: Effort? = nil, timeout: Duration, language: String? = nil, tag: String) {
        self.feature = feature
        self.system = system
        self.cachedBlock = cachedBlock
        self.instruction = instruction
        self.schemaName = schemaName
        self.schema = schema
        self.maxOutputTokens = maxOutputTokens
        self.effort = effort
        self.timeout = timeout
        self.language = language
        self.tag = tag
    }
}

/// Completion termination; AI §3.1.
public enum StopKind: Sendable, Equatable { case complete, truncated, refused(category: String?) }

/// Provider token accounting; AI §3.1.
public struct LLMUsage: Codable, Sendable, Equatable {
    /// input; Provider token accounting; AI §3.1.
    public var input: Int?
    /// output; Provider token accounting; AI §3.1.
    public var output: Int?
    /// cacheRead; Provider token accounting; AI §3.1.
    public var cacheRead: Int?
    /// cacheWrite; Provider token accounting; AI §3.1.
    public var cacheWrite: Int?

    /// Creates an explicit value without I/O or generated identifiers.
    public init(input: Int? = nil, output: Int? = nil, cacheRead: Int? = nil, cacheWrite: Int? = nil) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }

    private enum CodingKeys: String, CodingKey {
        case input
        case output
        case cacheRead
        case cacheWrite
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.input = try values.decodeIfPresent(Int.self, forKey: .input) ?? nil
        self.output = try values.decodeIfPresent(Int.self, forKey: .output) ?? nil
        self.cacheRead = try values.decodeIfPresent(Int.self, forKey: .cacheRead) ?? nil
        self.cacheWrite = try values.decodeIfPresent(Int.self, forKey: .cacheWrite) ?? nil
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(self.input, forKey: .input)
        try values.encode(self.output, forKey: .output)
        try values.encode(self.cacheRead, forKey: .cacheRead)
        try values.encode(self.cacheWrite, forKey: .cacheWrite)
    }

}

/// One-model completion; AI §3.1.
public struct RawCompletion: Sendable, Equatable {
    public var text: String?
    public var object: JSONValue?
    public var model: String
    public var stop: StopKind
    public var usage: LLMUsage?
    public var requestID: String?
    public init(text: String? = nil, object: JSONValue? = nil, model: String, stop: StopKind, usage: LLMUsage? = nil, requestID: String? = nil) {
        self.text = text
        self.object = object
        self.model = model
        self.stop = stop
        self.usage = usage
        self.requestID = requestID
    }
}

/// Validated feature result; AI §3.1.
public struct LLMResult: Sendable, Equatable {
    public var object: JSONValue
    public var droppedItems: Int
    public var model: String
    public var usedFallback: Bool
    public var usage: LLMUsage?
    public var requestID: String?
    public init(object: JSONValue, droppedItems: Int, model: String, usedFallback: Bool, usage: LLMUsage? = nil, requestID: String? = nil) {
        self.object = object
        self.droppedItems = droppedItems
        self.model = model
        self.usedFallback = usedFallback
        self.usage = usage
        self.requestID = requestID
    }
}

/// Capability status; AI §3.1. Skeleton reports unavailable rather than ready.
public enum ConnectorStatus: Sendable, Equatable {
    case ready, needsKey, noModels, cliMissing, cliSignedOut
    case notRunning(url: String)
    case unavailable(reason: String)
    case cliTooOld(version: String, missing: [String])
}
/// Model choice; AI §3.1 and §9.
public struct LLMModel: Codable, Sendable, Hashable {
    public enum Source: String, Codable, Sendable { case curated, discovered, custom }
    public let id: String
    public let name: String
    public let tier: String?
    public let contextTokens: Int?
    public let source: Source
    public init(id: String, name: String, tier: String? = nil, contextTokens: Int? = nil, source: Source) { self.id = id; self.name = name; self.tier = tier; self.contextTokens = contextTokens; self.source = source }
}
/// Connector service; AI §3.1. Each actor's immutable id is nonisolated.
public protocol LLMConnector: Sendable {
    var id: ConnectorID { get }
    func status() async -> ConnectorStatus
    func knownCLIAuthMethod() async -> String?
    func models(refresh: Bool) async throws -> [LLMModel]
    func contextTokens(model: String) async -> Int?
    func send(_ request: LLMRequest, model: String) async throws -> RawCompletion
}
extension LLMConnector {
    public func knownCLIAuthMethod() async -> String? { nil }
}
/// Dependency-injected secrets; architecture §2.1, §9.4 and AI §8.1. No persistence requirement.
public protocol KeyProvider: Sendable { func key(for provider: String) async throws -> String? }
/// Non-secret provider catalog and policy; AI §3.1 and §9.
public struct LLMCatalog: Sendable, Equatable {
    public var document: JSONValue
    public init(document: JSONValue) { self.document = document }
}
/// Shared runner, including retries and validation; AI §3.1 and §4.
public actor LLMRunner {
    let keys: any KeyProvider
    let catalog: LLMCatalog
    let log: any Redacting
    private var active = false
    public init(keys: any KeyProvider, catalog: LLMCatalog, log: any Redacting) { self.keys = keys; self.catalog = catalog; self.log = log }
    public func run(_ request: LLMRequest, on connector: any LLMConnector, model: String) async throws -> LLMResult {
        guard !active else { throw LLMError.unavailable(reason: "An AI request is already running.") }
        active = true
        defer { active = false }
        do {
            try Task.checkCancellation()
            try await checkStatus(connector)
            let account = LLMKeyDestination.pinned[connector.id]?.account
            if let account {
                do {
                    if let key = try await keys.key(for: account) { await log.register(secret: AIText.trim(key)) }
                    try Task.checkCancellation()
                } catch is CancellationError { throw LLMError.cancelled }
                catch LLMError.cancelled { throw LLMError.cancelled }
                catch { throw LLMError.missingKey }
            }
            do { return try await validated(request, connector: connector, model: model, fallback: false) }
            catch let failure as LLMError {
                guard permitsFallback(failure, id: connector.id), let fallback = catalog.fallback(for: connector.id, model: model) else { throw failure }
                return try await validated(request, connector: connector, model: fallback, fallback: true)
            }
        } catch {
            let failure = try await logFailure(error, connector: connector, feature: request.feature, model: model)
            throw failure
        }
    }

    func preflight(_ connector: any LLMConnector, feature: LLMFeature = .clipFinder, model: String = "") async throws {
        do { try await checkStatus(connector) }
        catch {
            let failure = try await logFailure(error, connector: connector, feature: feature, model: model)
            throw failure
        }
    }

    private func logFailure(_ error: any Error, connector: any LLMConnector, feature: LLMFeature, model: String) async throws -> LLMError {
        let failure: LLMError
        if Task.isCancelled || error is CancellationError { failure = .cancelled }
        else if let value = error as? LLMError { failure = value }
        else { throw error }
        let config = catalog.connector(connector.id)
        let userMessage = failure.userMessage(label: config[ai: "label"].aiString ?? connector.id.rawValue, model: model, feature: feature,
                                             installHint: config[ai: "cli"][ai: "installHint"].aiString ?? "",
                                             signInHint: config[ai: "cli"][ai: "signInHint"].aiString ?? "",
                                             cli: connector.id == .claudeCode ? "Claude Code" : connector.id == .codex ? "Codex" : nil) ?? ""
        let detail = AIText.prefix(await log.redact(userMessage), utf16: 200)
        let message = await log.redact("llm connector=\(connector.id.rawValue) error=\(failure.caseName) code=\(failure.code.rawValue) message=\(detail)")
        await log.write(LogEntry(level: failure == .cancelled ? .info : .error, category: "llm", message: message))
        return failure
    }

    private func checkStatus(_ connector: any LLMConnector) async throws {
        let status = await connector.status()
        try Task.checkCancellation()
        switch status {
        case .ready: return
        case .needsKey: throw LLMError.missingKey
        case .noModels: throw LLMError.noModels
        case .cliMissing: throw LLMError.cliMissing
        case .cliSignedOut: throw LLMError.cliSignedOut
        case .cliTooOld(let version, let missing): throw LLMError.cliTooOld(version: version, missing: missing)
        case .notRunning(let url): throw LLMError.notRunning(url: url)
        case .unavailable(let reason): throw LLMError.unavailable(reason: reason)
        }
    }

    private func permitsFallback(_ failure: LLMError, id: ConnectorID) -> Bool {
        guard id != .claudeCode, id != .ollama, id != .lmstudio, id != .appleFoundation else { return false }
        switch failure {
        case .rateLimited, .overloaded: return true
        case .planLimit: return id == .codex
        default: return false
        }
    }

    private func validated(_ request: LLMRequest, connector: any LLMConnector, model: String, fallback: Bool) async throws -> LLMResult {
        var current = request
        for correction in 0...1 {
            try Task.checkCancellation()
            let raw = try await connector.send(current, model: model)
            try Task.checkCancellation()
            do {
                let parsed = try CanonicalResponseParser.validate(raw, schema: request.schema)
                return LLMResult(object: parsed.object, droppedItems: parsed.droppedItems, model: raw.model, usedFallback: fallback || nativeFallback(connector: connector.id, requested: model, actual: raw.model), usage: raw.usage, requestID: raw.requestID)
            } catch LLMError.invalidOutput(let reason) {
                guard correction == 0 else { throw LLMError.invalidOutput(reason: reason) }
                current.instruction += "\n\nYour previous reply was not valid JSON for the required schema (\(reason)). Reply with only the JSON object."
            }
        }
        throw LLMError.invalidOutput(reason: "not JSON")
    }

    private func nativeFallback(connector: ConnectorID, requested: String, actual: String) -> Bool {
        if connector == .anthropic { return requested != actual }
        guard connector == .claudeCode, requested != "default", requested != actual,
              let fallback = catalog.fallback(for: connector, model: requested) else { return false }
        return !claudeModelsMatch(requested, actual) && claudeModelsMatch(fallback, actual)
    }

    private func claudeModelsMatch(_ selected: String, _ actual: String) -> Bool {
        if selected == actual { return true }
        let base = selected.components(separatedBy: "[").first ?? selected
        guard ["sonnet", "opus", "haiku"].contains(base) else { return false }
        return actual == base || actual.hasPrefix("claude-\(base)-")
    }
}
/// Catalog-backed connector adapter; AI §3.1.
public actor StubLLMConnector: LLMConnector {
    public nonisolated let id: ConnectorID
    private var implementation: (any LLMConnector)?
    private let factory: (@Sendable () throws -> any LLMConnector)?
    public init(id: ConnectorID) { self.id = id; self.factory = nil }
    public init(id: ConnectorID, keys: any KeyProvider, catalog: LLMCatalog, log: any Redacting, baseURL: URL? = nil, cliPath: String? = nil, cacheURL: URL? = DataLocations().cache.appendingPathComponent("llm-models.json")) {
        self.id = id
        self.factory = {
            switch id {
            case .claudeCode, .codex:
                return CLIConnector(id: id, catalog: catalog, log: log, executable: cliPath.map { URL(fileURLWithPath: $0) }, appVersion: AppVersion.current)
            case .appleFoundation:
                throw LLMError.unavailable(reason: "Use the native FoundationModelsConnector from VoxClipMedia.")
            default:
                return try HTTPConnector(id: id, keys: keys, catalog: catalog, log: log, baseURL: baseURL, appVersion: AppVersion.current, cacheURL: cacheURL)
            }
        }
    }
    public func status() async -> ConnectorStatus {
        do { return await (try resolve()).status() }
        catch { return .unavailable(reason: "VoxClip is missing its AI configuration. Reinstall VoxClip.") }
    }
    public func knownCLIAuthMethod() async -> String? {
        guard let cli = implementation as? CLIConnector else { return nil }
        return await cli.lastAuthMethod
    }
    public func models(refresh: Bool) async throws -> [LLMModel] { try await resolve().models(refresh: refresh) }
    public func contextTokens(model: String) async -> Int? {
        guard let connector = try? resolve() else { return nil }
        return await connector.contextTokens(model: model)
    }
    public func send(_ request: LLMRequest, model: String) async throws -> RawCompletion { try await resolve().send(request, model: model) }

    private func resolve() throws -> any LLMConnector {
        if let implementation { return implementation }
        if let factory {
            let connector = try factory()
            implementation = connector
            return connector
        }
        let shared = try SharedResources.locate()
        let catalog = try LLMCatalog(shared: shared)
        let log = RedactingLogger(homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
        let connector: any LLMConnector
        switch id {
        case .claudeCode, .codex: connector = CLIConnector(id: id, catalog: catalog, log: log, appVersion: AppVersion.current)
        case .appleFoundation: throw LLMError.unavailable(reason: "Use the native FoundationModelsConnector from VoxClipMedia.")
        default: connector = try HTTPConnector(id: id, keys: LLMEnvironmentKeyProvider(catalog: catalog), catalog: catalog, log: log, appVersion: AppVersion.current, cacheURL: DataLocations().cache.appendingPathComponent("llm-models.json"))
        }
        implementation = connector
        return connector
    }
}
/// Presets are read verbatim from shared/prompts; AI §11.
public actor ClipFinder {
    let runner: LLMRunner
    let shared: SharedResources
    var active = false
    var lastRun: ClipFinderRunSummary?
    public private(set) var lastUsedFallback: Bool?
    public init(runner: LLMRunner, shared: SharedResources) { self.runner = runner; self.shared = shared }
    public func presets() async throws -> [ClipPreset] { try loadPrompt().presets }
    public func find(_ request: ClipFinderRequest, connector: any LLMConnector, model: String) async throws -> ProjectAIResult {
        lastUsedFallback = nil
        do {
            let result = try await execute(request, connector: connector, model: model)
            lastUsedFallback = lastRun?.usedFallback
            return result
        }
        catch is CancellationError { throw LLMError.cancelled }
    }
}

/// Detailed connector taxonomy, mapped to architecture codes at the feature boundary; AI §5–5.1.
public enum LLMError: Error, Sendable, Equatable {
    case noConnector, missingKey, unauthorized, quotaExceeded, overloaded, network, timeout, contextTooLong, truncated, noModels, cliMissing, cliSignedOut, cancelled
    case rateLimited(retryAfter: Double?)
    case planLimit(message: String?)
    case server(status: Int)
    case modelNotFound(String)
    case badRequest(status: Int, message: String)
    case refused(category: String?)
    case invalidOutput(reason: String)
    case unsupportedLanguage(String)
    case notRunning(url: String)
    case cliTooOld(version: String, missing: [String])
    case cliFailed(String)
    case unavailable(reason: String)
}
