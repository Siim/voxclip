import Foundation
import Synchronization
import Testing
@testable import VoxClipCore

extension HTTPConnectorTests {
    @Test func voiceRewriteNeverRetriesAPaidCompletion() async throws {
        let harness = try HTTPHarness(.openai, replies: [.json("{\"error\":{\"message\":\"busy\"}}", status: 429)])
        defer { harness.session.invalidateAndCancel() }
        var request = try harness.catalog.connectionTest(for: .openai)
        request.feature = .voiceRewrite
        await #expect(throws: LLMError.rateLimited(retryAfter: nil)) {
            try await harness.connector.send(request, model: harness.model)
        }
        #expect(HTTPStubProtocol.requests.count == 1)
        #expect(harness.sleeps.durations.isEmpty)
    }

    @Test func voiceRewriteNetworkLossDoesNotRetry() async throws {
        let harness = try HTTPHarness(.openai, replies: [.transport(.networkConnectionLost)])
        defer { harness.finish() }
        var request = try harness.catalog.connectionTest(for: .openai)
        request.feature = .voiceRewrite
        await #expect(throws: LLMError.network) { try await harness.connector.send(request, model: harness.model) }
        #expect(HTTPStubProtocol.requests.count == 1)
        #expect(harness.sleeps.durations.isEmpty)
    }

    @Test func voiceRewriteAnthropicBetaRejectionDoesNotFallback() async throws {
        let rejected = HTTPReply.json(#"{"error":{"type":"invalid_request_error","message":"Unexpected anthropic-beta value"}}"#, status: 400)
        let harness = try HTTPHarness(.anthropic, replies: [rejected])
        defer { harness.finish() }
        var request = try HTTPFixtures.f1()
        request.feature = .voiceRewrite
        do { _ = try await harness.connector.send(request, model: harness.model); Issue.record("Expected beta rejection") }
        catch LLMError.badRequest {}
        #expect(HTTPStubProtocol.requests.count == 1)
        // ai.md §12.8: the rewrite asks for no server-side fallback model at all.
        let sent = try #require(HTTPStubProtocol.requests.first)
        #expect(sent.request.value(forHTTPHeaderField: "anthropic-beta") == nil)
        #expect(try sent.json()[ai: "fallbacks"] == .null)
        #expect(harness.sleeps.durations.isEmpty)
    }

    @Test(arguments: [ConnectorID.ollama, .lmstudio])
    func stoppedServerGatesBeforePlanningAndRecovers(_ id: ConnectorID) async throws {
        for execute in [false, true] {
            let harness = try HTTPHarness(id, replies: [.transport(.cannotConnectToHost)])
            defer { harness.session.invalidateAndCancel() }
            let finder = ClipFinder(runner: harness.runner(), shared: try SharedResources(root: FixtureLoader.sharedRoot()))
            let request = try aiReviewClipRequest()
            await #expect(throws: LLMError.notRunning(url: id == .ollama ? "http://127.0.0.1:11434" : "http://127.0.0.1:1234")) {
                if execute { _ = try await finder.find(request, connector: harness.connector, model: "small") }
                else { _ = try await finder.prepare(request, connector: harness.connector, model: "small") }
            }
            #expect(HTTPStubProtocol.requests.count == 1)
            let errors = await harness.log.entries.filter { $0.level == .error && $0.category == "llm" }
            #expect(errors.count == 1)
            #expect(errors.first?.message.contains("error=notRunning code=providerError") == true)
            #expect(await harness.connector.assumedContextModels.isEmpty)
            let ready = aiReviewReadyReplies(id)
            let completion: HTTPReply = id == .ollama ? .json(#"{"message":{"content":"{\"clips\":[]}"},"done_reason":"stop"}"#) :
                .json(#"{"choices":[{"message":{"content":"{\"clips\":[]}"},"finish_reason":"stop"}]}"#)
            HTTPStubProtocol.install(ready + (execute ? Array(ready.prefix(id == .ollama ? 3 : 2)) + [completion] : []))
            if execute {
                #expect(try await finder.find(request, connector: harness.connector, model: "small").clips.isEmpty)
                let generation = try #require(HTTPStubProtocol.requests.last)
                let body = try generation.json()
                if id == .ollama {
                    #expect(body[ai: "options"][ai: "num_ctx"].aiInt == 4096)
                    #expect(body[ai: "options"][ai: "num_predict"].aiInt == 1024)
                } else { #expect(body[ai: "max_tokens"].aiInt == 1024) }
            } else {
                let prepared = try await finder.prepare(request, connector: harness.connector, model: "small")
                #expect(prepared.count == 1)
                #expect(prepared.first?.maxOutputTokens == 1024)
            }
            harness.finish()
        }
    }

    @Test(arguments: [URLError.Code.cannotConnectToHost, .timedOut, .networkConnectionLost, .cancelled])
    func lmStudioDoesNotCacheTransportAssumptions(_ failure: URLError.Code) async throws {
        let harness = try HTTPHarness(.lmstudio, replies: [.transport(failure), .json(#"{"state":"loaded","loaded_context_length":32768}"#)])
        defer { harness.finish() }
        #expect(await harness.connector.contextTokens(model: "local") == nil)
        #expect(await harness.connector.assumedContextModels.isEmpty)
        #expect(await harness.connector.contextTokens(model: "local") == 32768)
        #expect(await harness.connector.assumedContextModels.isEmpty)
        #expect(HTTPStubProtocol.requests.count == 2)
    }

    @Test(arguments: [200, 404])
    func lmStudioCachesOnlyAnsweredMissingContext(_ status: Int) async throws {
        let harness = try HTTPHarness(.lmstudio, replies: [.json("{}", status: status)])
        defer { harness.finish() }
        #expect(await harness.connector.contextTokens(model: "local") == 4096)
        #expect(await harness.connector.assumedContextModels == ["local"])
        #expect(await harness.connector.contextTokens(model: "local") == 4096)
        #expect(HTTPStubProtocol.requests.count == 1)
    }

    @Test(arguments: [ConnectorID.anthropic, .openai, .xai, .gemini])
    func keyProviderFailuresNeverBecomeLocalServerErrors(_ id: ConnectorID) async throws {
        let catalog = try HTTPFixtures.catalog()
        let connector = try HTTPConnector(id: id, keys: AIReviewFailingKeys(), catalog: catalog, log: HTTPLog())
        #expect(await connector.status() == .needsKey)
        await #expect(throws: LLMError.missingKey) { try await connector.send(catalog.connectionTest(for: id), model: "model") }
    }

    @Test(arguments: [ConnectorID.anthropic, .openai, .xai, .gemini])
    func authenticatedRequestsIgnoreURLOverrides(_ id: ConnectorID) async throws {
        for address in ["https://example.invalid", "http://example.invalid", "http://127.0.0.1", "http://localhost", "http://[::1]", "file:///invalid"] {
            let harness = try HTTPHarness(id, replies: [.json("{}"), HTTPFixtures.success(id)], baseURL: URL(string: address))
            defer { harness.finish() }
            let config = harness.catalog.connector(id)
            #expect(await harness.connector.baseURL.absoluteString == config[ai: "baseUrl"].aiString)
            _ = try await harness.connector.fetch(path: "/fixture", timeout: 3)
            _ = try await harness.connector.send(harness.catalog.connectionTest(for: id), model: harness.model)
            let requests = HTTPStubProtocol.requests
            #expect(requests.count == 2)
            let header = try #require(config[ai: "auth"][ai: "header"].aiString)
            let value = try #require(config[ai: "auth"][ai: "valueTemplate"].aiString).replacingOccurrences(of: "{key}", with: "test")
            for captured in requests {
                #expect(captured.request.url?.host == URL(string: config[ai: "baseUrl"].aiString ?? "")?.host)
                #expect(captured.request.value(forHTTPHeaderField: header) == value)
            }
        }
    }

    @Test(arguments: [ConnectorID.anthropic, .openai, .xai, .gemini])
    func missingCatalogKeyAccountCannotReportNeedsKey(_ id: ConnectorID) async throws {
        var document = try #require(HTTPFixtures.catalog().document.aiObject)
        document["connectors"] = .array(document["connectors"]!.aiArray.map { entry in
            guard entry[ai: "id"].aiString == id.rawValue, var fields = entry.aiObject,
                  var auth = fields["auth"]?.aiObject else { return entry }
            auth.removeValue(forKey: "keyAccount")
            fields["auth"] = .object(auth)
            return .object(fields)
        })
        let connector = try HTTPConnector(id: id, keys: AIReviewFailingKeys(), catalog: LLMCatalog(document: .object(document)), log: HTTPLog())
        #expect(await connector.status() == .unavailable(reason: "VoxClip is missing its AI configuration. Reinstall VoxClip."))
    }

    @Test(arguments: [ConnectorID.ollama, .lmstudio], [401, 403])
    func localAuthenticationRejectionIsNotAMissingKey(_ id: ConnectorID, status: Int) async throws {
        let reply = HTTPReply.json(#"{"error":{"message":"Authentication required"}}"#, status: status)
        let harness = try HTTPHarness(id, replies: [reply])
        defer { harness.finish() }
        let label = harness.catalog.connector(id)[ai: "label"].aiString ?? id.rawValue
        let reason = "\(label) rejected the request (\(status))."
        #expect(await harness.connector.status() == .unavailable(reason: reason))
        HTTPStubProtocol.install([reply])
        let runner = LLMRunner(keys: HTTPKeys(), catalog: harness.catalog, log: HTTPLog())
        do {
            _ = try await runner.test(on: harness.connector, model: "local")
            Issue.record("Rejected local server passed preflight")
        } catch let failure as LLMError {
            #expect(failure == .unavailable(reason: reason))
            #expect(failure.code == .providerError)
            #expect(failure.userMessage(label: label) == reason + " Your edits are saved.")
        }
        #expect(HTTPStubProtocol.requests.count == 1)
        HTTPStubProtocol.install([reply, reply])
        await #expect(throws: LLMError.unavailable(reason: reason)) {
            try await harness.connector.send(harness.catalog.connectionTest(for: id), model: "local")
        }
    }

    @Test(arguments: [ConnectorID.ollama, .lmstudio], [400, 401, 403])
    func localAuthenticationErrorBodiesNeverRejectKeys(_ id: ConnectorID, status: Int) async throws {
        let reply = HTTPReply.json(#"{"error":{"type":"authentication_error","message":"Authentication required"}}"#, status: status)
        let harness = try HTTPHarness(id, replies: [reply])
        defer { harness.finish() }
        let label = harness.catalog.connector(id)[ai: "label"].aiString ?? id.rawValue
        let reason = "\(label) rejected the request (\(status))."
        #expect(await harness.connector.status() == .unavailable(reason: reason))
        #expect(HTTPStubProtocol.requests.count == 1)
        HTTPStubProtocol.install([reply])
        await #expect(throws: LLMError.unavailable(reason: reason)) {
            try await harness.runner().test(on: harness.connector, model: "local")
        }
        HTTPStubProtocol.install([reply, reply])
        let failure: LLMError = status == 400 ? .badRequest(status: status, message: "Authentication required") : .unavailable(reason: reason)
        await #expect(throws: failure) {
            try await harness.connector.send(harness.catalog.connectionTest(for: id), model: "local")
        }
        #expect(failure.code == .providerError)
        #expect(failure.userMessage(label: label)?.contains("API key") == false)
        #expect(HTTPStubProtocol.requests.count == 2)
    }

    @Test(arguments: [ConnectorID.ollama, .lmstudio])
    func localProbe404ReportsInvalidServerAddress(_ id: ConnectorID) async throws {
        let reply = HTTPReply.json("{}", status: 404)
        let harness = try HTTPHarness(id, replies: [reply])
        defer { harness.finish() }
        let label = harness.catalog.connector(id)[ai: "label"].aiString ?? id.rawValue
        let reason = "\(label)'s server address in Settings isn't valid."
        #expect(await harness.connector.status() == .unavailable(reason: reason))
        #expect(HTTPStubProtocol.requests.count == 1)
        #expect(HTTPStubProtocol.requests.first?.request.url?.path == (id == .ollama ? "/api/version" : "/v1/models"))
        HTTPStubProtocol.install([reply])
        do {
            _ = try await harness.runner().test(on: harness.connector, model: "local")
            Issue.record("Invalid local address passed the connection test")
        } catch let failure as LLMError {
            #expect(failure == .unavailable(reason: reason))
            #expect(failure.code == .providerError)
            #expect(failure.userMessage(label: label) == reason + " Your edits are saved.")
        }
        #expect(HTTPStubProtocol.requests.count == 1)
    }

    @Test func statusReasonsAppendEditsSavedOnlyOnce() async throws {
        let harness = try HTTPHarness(.ollama, replies: [.transport(.timedOut)])
        defer { harness.finish() }
        guard case .unavailable(let reason) = await harness.connector.status() else { Issue.record("Expected timeout status"); return }
        #expect(!reason.contains("Your edits are saved."))
        let message = try #require(LLMError.unavailable(reason: reason).userMessage(label: "Ollama"))
        #expect(message.components(separatedBy: "Your edits are saved.").count == 2)
    }

    @Test func cancellationDuringOllamaPreflightIsSilentCancellation() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AIReviewBlockedHTTP.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        AIReviewBlockedHTTP.started.withLock { $0 = false }
        let catalog = try HTTPFixtures.catalog()
        let log = HTTPLog()
        let connector = try HTTPConnector(id: .ollama, keys: HTTPKeys(), catalog: catalog, log: log, session: session)
        let task = Task { try await LLMRunner(keys: HTTPKeys(), catalog: catalog, log: log).test(on: connector, model: "small") }
        defer { task.cancel() }
        for _ in 0..<200 {
            if AIReviewBlockedHTTP.started.withLock({ $0 }) { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(AIReviewBlockedHTTP.started.withLock { $0 })
        task.cancel()
        await #expect(throws: LLMError.cancelled) { try await task.value }
        let entries = await log.entries
        #expect(entries.count == 1)
        #expect(entries.allSatisfy { $0.level == .info && $0.message.contains("code=cancelled") })
    }

    @Test func emptyRetryStatusesDisableRetries() async throws {
        var document = try #require(HTTPFixtures.catalog().document.aiObject)
        var policy = try #require(document["policy"]?.aiObject)
        var retry = try #require(policy["retry"]?.aiObject)
        retry["retryStatuses"] = .array([])
        policy["retry"] = .object(retry)
        document["policy"] = .object(policy)
        let catalog = LLMCatalog(document: .object(document))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HTTPStubProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let sleeps = HTTPSleeps()
        let connector = try HTTPConnector(id: .openai, keys: HTTPKeys(), catalog: catalog, log: HTTPLog(), session: session, sleep: { try sleeps.sleep($0) })
        HTTPStubProtocol.install([.json("{}", status: 500)])
        await #expect(throws: LLMError.server(status: 500)) { try await connector.send(catalog.connectionTest(for: .openai), model: "custom") }
        #expect(HTTPStubProtocol.requests.count == 1)
        #expect(sleeps.durations.isEmpty)
    }

    @Test func retryPolicyComesFromCatalog() async throws {
        var document = try #require(HTTPFixtures.catalog().document.aiObject)
        var policy = try #require(document["policy"]?.aiObject)
        policy["retry"] = .object(["attempts": .number(2), "backoffSeconds": .array([.number(7)]),
            "retryStatuses": .array([.number(500)]), "maxRetryAfterSeconds": .number(1)])
        document["policy"] = .object(policy)
        let catalog = LLMCatalog(document: .object(document))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HTTPStubProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let sleeps = HTTPSleeps()
        let connector = try HTTPConnector(id: .openai, keys: HTTPKeys(), catalog: catalog, log: HTTPLog(), session: session, sleep: { try sleeps.sleep($0) })
        let request = try catalog.connectionTest(for: .openai)
        HTTPStubProtocol.install([.json("{}", status: 500), .json("{}", status: 500)])
        await #expect(throws: LLMError.server(status: 500)) { try await connector.send(request, model: "custom") }
        #expect(HTTPStubProtocol.requests.count == 2)
        #expect(sleeps.durations == [.seconds(7)])
        HTTPStubProtocol.install([.json("{}", status: 503)])
        await #expect(throws: LLMError.overloaded) { try await connector.send(request, model: "custom") }
        #expect(HTTPStubProtocol.requests.count == 1)
        HTTPStubProtocol.install([.json("{}", status: 500, headers: ["retry-after": "2"])])
        await #expect(throws: LLMError.rateLimited(retryAfter: 2)) { try await connector.send(request, model: "custom") }
        #expect(HTTPStubProtocol.requests.count == 1)
    }
}

private func aiReviewReadyReplies(_ id: ConnectorID) -> [HTTPReply] {
    if id == .ollama {
        return [.json(#"{"version":"test"}"#), .json(#"{"models":[{"name":"small"}]}"#),
            .json(#"{"model_info":{"small.context_length":4096},"capabilities":["completion"]}"#)]
    }
    return [.json(#"{"data":[{"id":"small"}]}"#), .json(#"{"data":[{"id":"small"}]}"#), .json(#"{"loaded_context_length":4096}"#)]
}

private func aiReviewClipRequest() throws -> ClipFinderRequest {
    let words = (0..<30).map { TimedWord(id: "w\($0)", text: "word", start: Double($0), end: Double($0) + 0.5) }
    let transcript = Transcript(words: words, language: "en", durationSeconds: 30, engine: EngineRef(id: .whispercpp, engineVersion: "fixture"), rawKey: "fixture", createdAt: Date(timeIntervalSince1970: 0))
    return ClipFinderRequest(transcript: transcript, preset: try AIClipTestData.preset(.best))
}

private struct AIReviewFailingKeys: KeyProvider {
    struct Failure: Error {}
    func key(for provider: String) async throws -> String? { throw Failure() }
}

private final class AIReviewBlockedHTTP: URLProtocol, @unchecked Sendable {
    static let started = Mutex(false)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.started.withLock { $0 = true } }
    override func stopLoading() {}
}
