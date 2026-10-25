import Foundation
import FoundationModels
import Testing
import VoxClipCore
@testable import VoxClipMedia

enum FoundationModelsTestResources {
    struct Catalog: Decodable {
        struct Request: Decodable {
            var system: String
            var instruction: String
            var schemaName: String
            var schema: JSONValue
            var maxOutputTokens: Int
            var effort: Effort
            var expect: JSONValue
        }
        struct Policy: Decodable {
            struct Timeouts: Decodable { var test: Int }
            var timeoutsSeconds: Timeouts
        }
        var testRequest: Request
        var policy: Policy
    }

    struct Prompt: Decodable {
        struct Output: Decodable { var name: String; var schema: JSONValue }
        var output: Output
    }

    static func catalog() throws -> Catalog {
        try FixtureLoader.decode(Catalog.self, at: "catalog/llm-providers.json")
    }

    static func request() throws -> LLMRequest {
        let catalog = try catalog()
        let test = catalog.testRequest
        return LLMRequest(feature: .test, system: test.system, instruction: test.instruction,
                          schemaName: test.schemaName, schema: test.schema,
                          maxOutputTokens: test.maxOutputTokens, effort: test.effort,
                          timeout: .seconds(catalog.policy.timeoutsSeconds.test), language: "en", tag: "test")
    }

    static func reply() throws -> String {
        String(decoding: try JSONEncoder().encode(catalog().testRequest.expect), as: UTF8.self)
    }

    static func connector(runtime: FoundationModelsRuntime) throws -> FoundationModelsConnector {
        try FoundationModelsConnector(runtime: runtime, shared: SharedResources(root: FixtureLoader.sharedRoot()))
    }

    static func runtime(probe: FoundationModelsTestProbe) -> FoundationModelsRuntime {
        FoundationModelsRuntime(
            status: { .ready }, contextSize: { 12_345 },
            supportsLocale: { $0.language.languageCode?.identifier == "en" },
            tokenCount: { $0.utf8.count },
            generate: { _, _, maxOutput in try await probe.next(maxOutput: maxOutput) },
            sleep: { await probe.wait($0) }
        )
    }
}

actor FoundationModelsTestProbe {
    var responses: [Result<String, any Error>]
    private(set) var calls = 0
    private(set) var waits: [Duration] = []
    private(set) var outputCaps: [Int] = []

    init(_ responses: [Result<String, any Error>]) { self.responses = responses }

    func next(maxOutput: Int) throws -> String {
        calls += 1
        outputCaps.append(maxOutput)
        return try responses.removeFirst().get()
    }

    func wait(_ duration: Duration) { waits.append(duration) }
}

@Suite struct FoundationModelsConnectorTests {
    @Test(arguments: [false, true])
    func invalidCatalogAvailabilityNeverCallsApple(disabled: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("VoxClip-Apple-auth-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("catalog"), withIntermediateDirectories: true)
        var document = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf:
            FixtureLoader.sharedRoot().appendingPathComponent("catalog/llm-providers.json"))) as? [String: Any])
        var entries = try #require(document["connectors"] as? [[String: Any]])
        let index = try #require(entries.firstIndex { $0["id"] as? String == "apple-foundation" })
        if disabled { entries[index]["enabled"] = false }
        else { entries[index]["auth"] = ["type": "apiKey", "keyAccount": "llm-api-key-openai"] }
        document["connectors"] = entries
        try JSONSerialization.data(withJSONObject: document).write(to: root.appendingPathComponent("catalog/llm-providers.json"))
        let shared = try SharedResources(root: root)
        let reason = disabled ? "Apple Intelligence (on this Mac) is not enabled."
            : "VoxClip is missing its AI configuration. Reinstall VoxClip."
        let failure = LLMError.unavailable(reason: reason)
        let probe = FoundationModelsTestProbe([])
        let connector = FoundationModelsConnector(runtime: FoundationModelsTestResources.runtime(probe: probe), shared: shared)
        #expect(await connector.status() == .unavailable(reason: reason))
        await #expect(throws: failure) { try await connector.models(refresh: true) }
        await #expect(throws: failure) { try await connector.send(FoundationModelsTestResources.request(), model: "system") }
        #expect(await probe.calls == 0)
    }

    @Test func productionConnectionTestUsesEnglishAndThirtySeconds() async throws {
        let shared = try SharedResources(root: FixtureLoader.sharedRoot())
        let catalog = try LLMCatalog(shared: shared)
        let request = try catalog.connectionTest(for: .appleFoundation)
        #expect(request.language == "en")
        #expect(request.cachedBlock == nil)
        #expect(request.timeout == .seconds(30))
        let probe = FoundationModelsTestProbe([.success(try FoundationModelsTestResources.reply())])
        let connector = FoundationModelsConnector(runtime: FoundationModelsTestResources.runtime(probe: probe), shared: shared)
        let result = try await LLMRunner(keys: FoundationModelsReviewKeys(), catalog: catalog,
            log: RedactingLogger(homeDirectory: "")).test(on: connector, model: "system")
        #expect(result.passed)
        #expect(result.model == "system")
        #expect(await probe.calls == 1)
    }

    @Test func eachAppleAttemptLogsOnlyRedactedMetadata() async throws {
        let shared = try SharedResources(root: FixtureLoader.sharedRoot())
        let probe = FoundationModelsTestProbe([.failure(LLMError.rateLimited(retryAfter: nil)), .success(try FoundationModelsTestResources.reply())])
        let log = FoundationModelsReviewLog()
        await log.register(secret: "private-log-marker")
        let connector = FoundationModelsConnector(runtime: FoundationModelsTestResources.runtime(probe: probe), shared: shared, log: log)
        var request = try LLMCatalog(shared: shared).connectionTest(for: .appleFoundation)
        request.system = "DO_NOT_LOG_SYSTEM"
        request.cachedBlock = "DO_NOT_LOG_TRANSCRIPT"
        request.tag = "private-log-marker\nclips"
        _ = try await connector.send(request, model: "system")
        let entries = await log.entries
        #expect(entries.count == 2)
        #expect(entries[0].message.contains("attempt=1 status=failed"))
        #expect(entries[1].message.contains("attempt=2 status=0"))
        #expect(entries.allSatisfy { entry in
            entry.message.contains("connector=apple-foundation model=system feature=test") && entry.message.contains(" ms=") &&
                entry.message.contains("[REDACTED]") && !entry.message.contains("private-log-marker") &&
                !entry.message.contains("DO_NOT_LOG") && !entry.message.contains("echo") && !entry.message.contains("\n")
        })
    }

    @Test func availabilityMessages() {
        #expect(FoundationModelsRuntime.status(for: .available) == .ready)
        #expect(FoundationModelsRuntime.status(for: .unavailable(.deviceNotEligible)) ==
                .unavailable(reason: "This Mac can't run Apple Intelligence."))
        #expect(FoundationModelsRuntime.status(for: .unavailable(.appleIntelligenceNotEnabled)) ==
                .unavailable(reason: "Turn on Apple Intelligence in System Settings to use the on-device model."))
        #expect(FoundationModelsRuntime.status(for: .unavailable(.modelNotReady)) ==
                .unavailable(reason: "Apple's on-device model is still downloading. Try again later."))
    }

    @Test func contextAndModelsUseRuntimeSize() async throws {
        let probe = FoundationModelsTestProbe([])
        let connector = try FoundationModelsTestResources.connector(runtime: FoundationModelsTestResources.runtime(probe: probe))
        #expect(await connector.contextTokens(model: "system") == 12_345)
        let models = try await connector.models(refresh: true)
        #expect(models.map(\.id) == ["system"])
        #expect(models.first?.contextTokens == 12_345)
        #expect(try await connector.tokenCount(for: "abc") == 3)
        #expect(await probe.calls == 0)
    }

    @Test func unsupportedLocaleNeverGenerates() async throws {
        let probe = FoundationModelsTestProbe([])
        let connector = try FoundationModelsTestResources.connector(runtime: FoundationModelsTestResources.runtime(probe: probe))
        var request = try FoundationModelsTestResources.request()
        request.language = "et"
        await #expect(throws: LLMError.unsupportedLanguage("et")) {
            try await connector.send(request, model: "system")
        }
        #expect(await probe.calls == 0)
    }

    @Test func missingLanguageRecognizesTranscriptNotInstructions() throws {
        var request = try FoundationModelsTestResources.request()
        request.language = nil
        request.cachedBlock = "<transcript>\n[0-12] 0:00 This is an English recording about making clear and useful videos.\n(pause 2.3s)\n</transcript>"
        #expect(try FoundationModelsLocale.language(for: request) { $0.language.languageCode?.identifier == "en" } == "en")
        request.cachedBlock = nil
        #expect(throws: LLMError.unsupportedLanguage("unknown")) {
            try FoundationModelsLocale.language(for: request) { _ in true }
        }
    }

    @Test func languageRecognitionStopsAtTwoThousandWords() {
        let english = Array(repeating: "This recording explains the creative process and the decisions behind making useful videos.", count: 200)
        let estonian = Array(repeating: "See salvestus selgitab loomingulist protsessi ja kasulike videote tegemise otsuseid.", count: 1_000)
        #expect(FoundationModelsLocale.dominantLanguage(in: (english + estonian).joined(separator: " ")) == "en")
        #expect(FoundationModelsLocale.dominantLanguage(in: " \n\t") == nil)
    }

    @Test func unavailableNeverGenerates() async throws {
        let probe = FoundationModelsTestProbe([])
        var runtime = FoundationModelsTestResources.runtime(probe: probe)
        runtime.status = { .unavailable(reason: "Not ready") }
        let connector = try FoundationModelsTestResources.connector(runtime: runtime)
        let request = try FoundationModelsTestResources.request()
        await #expect(throws: LLMError.unavailable(reason: "Not ready")) {
            try await connector.send(request, model: "system")
        }
        #expect(await probe.calls == 0)
    }

    @Test func catalogRoundtripDecodesAndCapsOutput() async throws {
        let probe = FoundationModelsTestProbe([.success(try FoundationModelsTestResources.reply())])
        let connector = try FoundationModelsTestResources.connector(runtime: FoundationModelsTestResources.runtime(probe: probe))
        let request = try FoundationModelsTestResources.request()
        let result = try await connector.send(request, model: "system")
        #expect(result.object == (try FoundationModelsTestResources.catalog().testRequest.expect))
        #expect(result.model == "system")
        #expect(result.stop == .complete)
        #expect(result.text == nil)
        #expect(result.usage == nil)
        #expect(await probe.outputCaps == [1_500])
        #expect(FoundationModelsRuntime.prompt(for: request) == request.instruction)
        var cached = request
        cached.cachedBlock = ""
        #expect(FoundationModelsRuntime.prompt(for: cached) == "\n\n" + request.instruction)
    }

    @Test func greedyOptionsPreserveSmallerOutputBudget() {
        let options = FoundationModelsRuntime.options(maxOutput: 32)
        #expect(options.maximumResponseTokens == 32)
        #if compiler(>=6.4)
        #expect(options == GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 32))
        #else
        #expect(options == GenerationOptions(sampling: .greedy, maximumResponseTokens: 32))
        #endif
    }

    @Test func decodingPreservesFractionalNumbersForRunnerValidation() async throws {
        var expected = try FoundationModelsTestResources.catalog().testRequest.expect
        if case .object(var properties) = expected {
            properties["fraction"] = .number(5.5)
            expected = .object(properties)
        }
        let reply = String(decoding: try JSONEncoder().encode(expected), as: UTF8.self)
        let probe = FoundationModelsTestProbe([.success(reply)])
        let connector = try FoundationModelsTestResources.connector(runtime: FoundationModelsTestResources.runtime(probe: probe))
        var request = try FoundationModelsTestResources.request()
        request.maxOutputTokens = 32
        let result = try await connector.send(request, model: "system")
        #expect(result.object == expected)
        #expect(await probe.outputCaps == [32])
    }

    @Test func rateLimitsRetryTwiceAtTwoSeconds() async throws {
        let probe = FoundationModelsTestProbe(Array(repeating: .failure(LLMError.rateLimited(retryAfter: nil)), count: 3))
        let connector = try FoundationModelsTestResources.connector(runtime: FoundationModelsTestResources.runtime(probe: probe))
        let request = try FoundationModelsTestResources.request()
        await #expect(throws: LLMError.rateLimited(retryAfter: 2)) { try await connector.send(request, model: "system") }
        #expect(await probe.calls == 3)
        #expect(await probe.waits == [.seconds(2), .seconds(2)])
    }

    @Test func concurrencyRetriesThreeTimesAtOneSecond() async throws {
        let context = LanguageModelSession.GenerationError.Context(debugDescription: "busy")
        let failure = LanguageModelSession.GenerationError.concurrentRequests(context)
        let probe = FoundationModelsTestProbe(Array(repeating: .failure(failure), count: 4))
        let connector = try FoundationModelsTestResources.connector(runtime: FoundationModelsTestResources.runtime(probe: probe))
        let request = try FoundationModelsTestResources.request()
        await #expect(throws: LLMError.unavailable(reason: "Apple's on-device model is busy. Try again.")) {
            try await connector.send(request, model: "system")
        }
        #expect(await probe.calls == 4)
        #expect(await probe.waits == [.seconds(1), .seconds(1), .seconds(1)])
    }

    @Test func contextErrorReturnsToWindowPlannerWithoutRetry() async throws {
        let context = LanguageModelSession.GenerationError.Context(debugDescription: "too long")
        let probe = FoundationModelsTestProbe([.failure(LanguageModelSession.GenerationError.exceededContextWindowSize(context))])
        let connector = try FoundationModelsTestResources.connector(runtime: FoundationModelsTestResources.runtime(probe: probe))
        let request = try FoundationModelsTestResources.request()
        await #expect(throws: LLMError.contextTooLong) { try await connector.send(request, model: "system") }
        #expect(await probe.calls == 1)
        #expect(await probe.waits.isEmpty)
    }

    @Test func invalidJSONIsInvalidOutputNotUnavailable() async throws {
        let probe = FoundationModelsTestProbe([.success("{")])
        let connector = try FoundationModelsTestResources.connector(runtime: FoundationModelsTestResources.runtime(probe: probe))
        let request = try FoundationModelsTestResources.request()
        await #expect(throws: LLMError.invalidOutput(reason: "Apple's response was not valid JSON.")) {
            try await connector.send(request, model: "system")
        }
        #expect(await probe.calls == 1)
    }

    @Test func timeoutCancelsGenerationWithoutRetry() async throws {
        let probe = FoundationModelsTestProbe([])
        var runtime = FoundationModelsTestResources.runtime(probe: probe)
        runtime.generate = { _, _, _ in
            try await Task.sleep(for: .seconds(60))
            return ""
        }
        let connector = try FoundationModelsTestResources.connector(runtime: runtime)
        var request = try FoundationModelsTestResources.request()
        request.timeout = .milliseconds(20)
        await #expect(throws: LLMError.timeout) { try await connector.send(request, model: "system") }
        #expect(await probe.waits.isEmpty)
    }

    @Test func cancellationStopsGenerationSilently() async throws {
        let probe = FoundationModelsTestProbe([])
        let (started, continuation) = AsyncStream<Void>.makeStream()
        var runtime = FoundationModelsTestResources.runtime(probe: probe)
        runtime.generate = { _, _, _ in
            continuation.yield()
            try await Task.sleep(for: .seconds(60))
            return ""
        }
        let connector = try FoundationModelsTestResources.connector(runtime: runtime)
        let request = try FoundationModelsTestResources.request()
        let task = Task { try await connector.send(request, model: "system") }
        for await _ in started { break }
        task.cancel()
        await #expect(throws: LLMError.cancelled) { try await task.value }
        #expect(await probe.waits.isEmpty)
    }

    @Test func errorDescriptionsAreRedacted() {
        let error = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Authorization: Bearer private-value"])
        #expect(FoundationModelsFailure.classify(error, language: "en").error ==
                .unavailable(reason: "Authorization: Bearer [REDACTED]"))
    }

    #if compiler(>=6.4)
    @Test @available(macOS 27, *) func modernErrorsUseNewTaxonomy() {
        let context = LanguageModelError.contextSizeExceeded(.init(contextSize: 20, tokenCount: 21, debugDescription: "context"))
        #expect(FoundationModelsFailure.classify(context, language: "en").error == .contextTooLong)
        let timeout = LanguageModelError.timeout(.init(debugDescription: "timeout"))
        #expect(FoundationModelsFailure.classify(timeout, language: "en").error == .timeout)
        let refusal = LanguageModelError.guardrailViolation(.init(debugDescription: "guardrail"))
        #expect(FoundationModelsFailure.classify(refusal, language: "en").error == .refused(category: nil))
        let locale = LanguageModelError.unsupportedLanguageOrLocale(.init(languageCode: .init("et"), debugDescription: "locale"))
        #expect(FoundationModelsFailure.classify(locale, language: nil).error == .unsupportedLanguage("et"))
        #expect(FoundationModelsFailure.classify(LanguageModelSession.Error.concurrentRequests, language: "en").error ==
                .unavailable(reason: "Apple's on-device model is busy. Try again."))
    }
    #endif
}

private struct FoundationModelsReviewKeys: KeyProvider {
    func key(for provider: String) async throws -> String? { nil }
}

private actor FoundationModelsReviewLog: Redacting {
    var entries: [LogEntry] = []
    private var redactor = Redactor(homeDirectory: "")
    func register(secret: String) { redactor.register(secret: secret) }
    func redact(_ message: String) -> String { redactor.redact(message) }
    func write(_ entry: LogEntry) { entries.append(entry) }
}
