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
    func models(refresh: Bool) async throws -> [LLMModel]
    func contextTokens(model: String) async -> Int?
    func send(_ request: LLMRequest, model: String) async throws -> RawCompletion
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
    public init(keys: any KeyProvider, catalog: LLMCatalog, log: any Redacting) {}
    public func run(_ request: LLMRequest, on connector: any LLMConnector, model: String) async throws -> LLMResult { throw VoxClipError.notImplemented("mac-ai") }
}
/// Safe connector placeholder; AI §3.1.
public actor StubLLMConnector: LLMConnector {
    public nonisolated let id: ConnectorID
    public init(id: ConnectorID) { self.id = id }
    public func status() async -> ConnectorStatus {
        // TODO(mac-ai)
        return .unavailable(reason: "mac-ai")
    }
    public func models(refresh: Bool) async throws -> [LLMModel] { throw VoxClipError.notImplemented("mac-ai") }
    public func contextTokens(model: String) async -> Int? {
        // TODO(mac-ai)
        return nil
    }
    public func send(_ request: LLMRequest, model: String) async throws -> RawCompletion { throw VoxClipError.notImplemented("mac-ai") }
}
/// Presets are read verbatim from shared/prompts; AI §11.
public actor ClipFinder {
    public init(runner: LLMRunner, shared: SharedResources) {}
    public func presets() async throws -> [ClipPreset] { throw VoxClipError.notImplemented("mac-ai") }
    public func find(_ request: ClipFinderRequest, connector: any LLMConnector, model: String) async throws -> [ClipSuggestion] { throw VoxClipError.notImplemented("mac-ai") }
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
