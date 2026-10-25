import Foundation
import FoundationModels
import VoxClipCore

/// On-device text-only connector; AI §6.7, architecture §2.1. Never falls back to cloud.
public actor FoundationModelsConnector: LLMConnector, LLMTokenCounting {
    public nonisolated let id: ConnectorID = .appleFoundation
    private let runtime: FoundationModelsRuntime
    private let shared: SharedResources?
    private let log: any Redacting

    public init() {
        runtime = .system
        shared = nil
        log = RedactingLogger(homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
    }

    public init(log: any Redacting) {
        runtime = .system
        shared = nil
        self.log = log
    }

    init(runtime: FoundationModelsRuntime, shared: SharedResources, log: any Redacting = RedactingLogger(homeDirectory: "")) {
        self.runtime = runtime
        self.shared = shared
        self.log = log
    }

    public func status() async -> ConnectorStatus {
        do {
            _ = try configuration()
            return runtime.status()
        } catch LLMError.unavailable(let reason) { return .unavailable(reason: reason) }
        catch { return .unavailable(reason: "VoxClip is missing its AI configuration. Reinstall VoxClip.") }
    }

    public func models(refresh: Bool) async throws -> [LLMModel] {
        let configuration = try configuration()
        return configuration.models.map {
            LLMModel(id: $0.id, name: $0.name, tier: $0.tier,
                     contextTokens: runtime.contextSize(), source: .curated)
        }
    }

    public func contextTokens(model: String) async -> Int? {
        runtime.contextSize()
    }

    public func send(_ request: LLMRequest, model: String) async throws -> RawCompletion {
        try await send(request, model: model, clipBudget: nil)
    }

    /// Allows the window planner to supply its exact k without changing the canonical schema.
    public func send(_ request: LLMRequest, model: String, clipBudget: Int?) async throws -> RawCompletion {
        do {
            try Task.checkCancellation()
            let configuration = try configuration()
            let language = try FoundationModelsLocale.language(for: request, supports: runtime.supportsLocale)
            if case .unavailable(let reason) = runtime.status() {
                throw LLMError.unavailable(reason: reason)
            }
            guard configuration.models.contains(where: { $0.id == model }) else {
                throw LLMError.modelNotFound(model)
            }
            guard request.maxOutputTokens > 0 else {
                throw LLMError.badRequest(status: 400, message: "The output token budget must be positive.")
            }
            let budget = try clipBudget ?? inferredClipBudget(for: request)
            let schema = try FoundationModelsSchema.make(request.schema, name: request.schemaName, clipBudget: budget)
            let maxOutput = min(request.maxOutputTokens, configuration.maxOutputTokensCap)
            let runtime = self.runtime
            let log = self.log
            return try await FoundationModelsExecution.withTimeout(request.timeout) {
                try await FoundationModelsExecution.generate(
                    request, model: model, schema: schema, maxOutput: maxOutput,
                    language: language, runtime: runtime, log: log
                )
            }
        } catch {
            if Task.isCancelled || error is CancellationError { throw LLMError.cancelled }
            throw error
        }
    }

    /// Uses Apple's tokenizer on 26.4+, and the specification's conservative estimate earlier.
    public func tokenCount(for text: String) async throws -> Int {
        do {
            try Task.checkCancellation()
            return try await runtime.tokenCount(text)
        } catch {
            if Task.isCancelled || error is CancellationError { throw LLMError.cancelled }
            throw FoundationModelsFailure.classify(error, language: nil).error
        }
    }

    private func configuration() throws -> FoundationModelsConfiguration.Connector {
        try FoundationModelsConfiguration.connector(shared: shared ?? SharedResources.locate())
    }

    private func inferredClipBudget(for request: LLMRequest) throws -> Int? {
        guard request.feature == .clipFinder else { return nil }
        return try FoundationModelsConfiguration.clipBudget(
            instruction: request.instruction, shared: shared ?? SharedResources.locate()
        )
    }
}

struct FoundationModelsRuntime: Sendable {
    var status: @Sendable () -> ConnectorStatus
    var contextSize: @Sendable () -> Int
    var supportsLocale: @Sendable (Locale) -> Bool
    var tokenCount: @Sendable (String) async throws -> Int
    var generate: @Sendable (LLMRequest, GenerationSchema, Int) async throws -> String
    var sleep: @Sendable (Duration) async throws -> Void

    static let system = FoundationModelsRuntime(
        status: { status(for: SystemLanguageModel.default.availability) },
        contextSize: { SystemLanguageModel.default.contextSize },
        supportsLocale: { SystemLanguageModel.default.supportsLocale($0) },
        tokenCount: { text in
            if #available(macOS 26.4, *) {
                return try await SystemLanguageModel.default.tokenCount(for: text)
            }
            return Int(ceil(Double(text.utf8.count) / 2.2))
        },
        generate: { request, schema, maxOutput in
            let session = LanguageModelSession(model: .default, instructions: request.system)
            let response = try await session.respond(
                to: prompt(for: request), schema: schema, options: options(maxOutput: maxOutput)
            )
            return response.content.jsonString
        },
        sleep: { try await Task.sleep(for: $0) }
    )

    static func prompt(for request: LLMRequest) -> String {
        request.cachedBlock.map { $0 + "\n\n" + request.instruction } ?? request.instruction
    }

    static func options(maxOutput: Int) -> GenerationOptions {
        // Xcode 27's initializer is back-deployed to macOS 26. Xcode 26's SDK
        // only declares `sampling:`, so select the API at compile time.
        #if compiler(>=6.4)
        return GenerationOptions(samplingMode: .greedy, maximumResponseTokens: maxOutput)
        #else
        return GenerationOptions(sampling: .greedy, maximumResponseTokens: maxOutput)
        #endif
    }

    static func status(for availability: SystemLanguageModel.Availability) -> ConnectorStatus {
        switch availability {
        case .available: return .ready
        case .unavailable(.deviceNotEligible):
            return .unavailable(reason: "This Mac can't run Apple Intelligence.")
        case .unavailable(.appleIntelligenceNotEnabled):
            return .unavailable(reason: "Turn on Apple Intelligence in System Settings to use the on-device model.")
        case .unavailable(.modelNotReady):
            return .unavailable(reason: "Apple's on-device model is still downloading. Try again later.")
        case .unavailable:
            return .unavailable(reason: "Apple's on-device model is unavailable.")
        }
    }
}
