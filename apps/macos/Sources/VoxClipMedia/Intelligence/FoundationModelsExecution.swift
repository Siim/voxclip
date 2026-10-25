import Foundation
import FoundationModels
import VoxClipCore

enum FoundationModelsExecution {
    static func withTimeout<Value: Sendable>(
        _ timeout: Duration, operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        guard timeout > .zero else { throw LLMError.timeout }
        return try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw LLMError.timeout
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw LLMError.cancelled }
            try Task.checkCancellation()
            return result
        }
    }

    static func generate(
        _ request: LLMRequest, model: String, schema: GenerationSchema, maxOutput: Int,
        language: String, runtime: FoundationModelsRuntime, log: any Redacting
    ) async throws -> RawCompletion {
        var rateRetries = 0
        var concurrencyRetries = 0
        var attempt = 0
        while true {
            try Task.checkCancellation()
            attempt += 1
            let started = ContinuousClock.now
            do {
                let json = try await runtime.generate(request, schema, maxOutput)
                try Task.checkCancellation()
                let object: JSONValue
                do { object = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)) }
                catch { throw LLMError.invalidOutput(reason: "Apple's response was not valid JSON.") }
                await record(request, model: model, attempt: attempt, status: "0", started: started, log: log)
                return RawCompletion(object: object, model: model, stop: .complete)
            } catch {
                await record(request, model: model, attempt: attempt, status: "failed", started: started, log: log)
                if Task.isCancelled || error is CancellationError { throw LLMError.cancelled }
                let failure = FoundationModelsFailure.classify(error, language: language)
                switch failure {
                case .rateLimited where rateRetries < 2:
                    rateRetries += 1
                    try await runtime.sleep(.seconds(2))
                case .concurrentRequests where concurrencyRetries < 3:
                    concurrencyRetries += 1
                    try await runtime.sleep(.seconds(1))
                default: throw failure.error
                }
            }
        }
    }

    private static func record(_ request: LLMRequest, model: String, attempt: Int, status: String, started: ContinuousClock.Instant, log: any Redacting) async {
        func safe(_ value: String) -> String { String(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(128)) }
        let elapsed = started.duration(to: .now).components
        let milliseconds = elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000
        let message = "llm connector=apple-foundation model=\(safe(model)) feature=\(request.feature.rawValue) tag=\"\(safe(request.tag))\" attempt=\(attempt) status=\(status) ms=\(milliseconds)"
        await log.write(LogEntry(level: .info, category: "llm", message: await log.redact(message)))
    }
}

enum FoundationModelsFailure {
    case rateLimited
    case concurrentRequests
    case terminal(LLMError)

    var error: LLMError {
        switch self {
        case .rateLimited: return .rateLimited(retryAfter: 2)
        case .concurrentRequests: return .unavailable(reason: "Apple's on-device model is busy. Try again.")
        case .terminal(let error): return error
        }
    }

    static func classify(_ error: any Error, language: String?) -> Self {
        if error is CancellationError { return .terminal(.cancelled) }
        if let error = error as? LLMError {
            if case .rateLimited = error { return .rateLimited }
            return .terminal(error)
        }
        // Xcode 26's SDK does not declare either macOS 27 error type.
        #if compiler(>=6.4)
        if #available(macOS 27, *) {
            if let error = error as? LanguageModelError {
                switch error {
                case .contextSizeExceeded: return .terminal(.contextTooLong)
                case .guardrailViolation, .refusal: return .terminal(.refused(category: nil))
                case .unsupportedLanguageOrLocale(let context):
                    return .terminal(.unsupportedLanguage(language ?? context.languageCode.identifier))
                case .rateLimited: return .rateLimited
                case .timeout: return .terminal(.timeout)
                default: return unavailable(error)
                }
            }
            if let error = error as? LanguageModelSession.Error, error == .concurrentRequests {
                return .concurrentRequests
            }
        }
        #endif
        if let error = error as? LanguageModelSession.GenerationError {
            switch error {
            case .exceededContextWindowSize: return .terminal(.contextTooLong)
            case .guardrailViolation, .refusal: return .terminal(.refused(category: nil))
            case .unsupportedLanguageOrLocale: return .terminal(.unsupportedLanguage(language ?? "unknown"))
            case .rateLimited: return .rateLimited
            case .concurrentRequests: return .concurrentRequests
            default: return unavailable(error)
            }
        }
        if let error = error as? URLError, error.code == .timedOut { return .terminal(.timeout) }
        return unavailable(error)
    }

    private static func unavailable(_ error: any Error) -> Self {
        let redactor = Redactor(homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
        return .terminal(.unavailable(reason: String(redactor.redact(error.localizedDescription).prefix(200))))
    }
}
