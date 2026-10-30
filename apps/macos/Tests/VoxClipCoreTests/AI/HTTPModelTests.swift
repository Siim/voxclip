import Foundation
import Testing
@testable import VoxClipCore

extension HTTPConnectorTests {
    @Test(arguments: HTTPFixtures.connectors)
    func curatedModelsAreAvailableOfflineWithoutImplicitRefresh(_ id: ConnectorID) async throws {
        let harness = try HTTPHarness(id, replies: [])
        defer { harness.finish() }
        let models = try await harness.connector.models(refresh: false)
        #expect(models == harness.catalog.curatedModels(for: id))
        #expect(HTTPStubProtocol.requests.isEmpty)
        if let model = models.first {
            #expect(await harness.connector.contextTokens(model: model.id) == model.contextTokens)
        }
    }

    @Test(arguments: HTTPFixtures.connectors)
    func failedRefreshPreservesCuratedListAndReportsWarning(_ id: ConnectorID) async throws {
        let harness = try HTTPHarness(id, replies: [.json(#"{"error":{"message":"unavailable"}}"#, status: 500)])
        defer { harness.finish() }
        let models = try await harness.connector.models(refresh: true)
        #expect(models == harness.catalog.curatedModels(for: id))
        let warning = await harness.connector.refreshWarning
        #expect(warning?.hasPrefix("Couldn't refresh:") == true)
        #expect(try await harness.connector.models(refresh: false) == models)
        #expect(HTTPStubProtocol.requests.count == 1)
        #expect(HTTPStubProtocol.requests.first?.request.httpMethod == "GET")
        #expect(HTTPStubProtocol.requests.first?.request.timeoutInterval == 15)
        #expect(harness.sleeps.durations.isEmpty)
    }

    /// The model-list cache records its fetch time in the canonical form (editing.md §10.1).
    @Test
    func refreshedModelListRecordsItsFetchTimeInCanonicalForm() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-model-list-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = directory.appendingPathComponent("llm-models.json")
        let harness = try HTTPHarness(.openai, replies: [.json(#"{"data":[{"id":"gpt-custom-one","created":2}]}"#)], cacheURL: cache)
        defer { harness.finish() }
        _ = try await harness.connector.models(refresh: true)
        let document = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: cache)) as? [String: Any])
        let fetchedAt = try #require((document["openai"] as? [String: Any])?["fetchedAt"] as? String)
        #expect(fetchedAt.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$"#, options: .regularExpression) != nil)
    }

    @Test
    func refreshedCacheSurvivesFailureAndSuccessfulRefreshClearsWarning() async throws {
        let first = HTTPReply.json(#"{"data":[{"id":"gpt-custom-one","created":2},{"id":"o9-custom","created":1}]}"#)
        let second = HTTPReply.json(#"{"data":[{"id":"gpt-custom-two","created":3}]}"#)
        let harness = try HTTPHarness(.openai, replies: [first, .json("{}", status: 503), second])
        defer { harness.finish() }
        let cached = try await harness.connector.models(refresh: true)
        #expect(cached.map(\.id) == ["gpt-custom-one", "o9-custom"])
        #expect(try await harness.connector.models(refresh: true) == cached)
        #expect(await harness.connector.refreshWarning != nil)
        #expect(try await harness.connector.models(refresh: false) == cached)
        let refreshed = try await harness.connector.models(refresh: true)
        #expect(refreshed.map(\.id) == ["gpt-custom-two"])
        #expect(await harness.connector.refreshWarning == nil)
        #expect(HTTPStubProtocol.requests.count == 3)
    }

    @Test
    func anthropicRefreshPaginatesMergesCuratedOrderAndReadsContext() async throws {
        let first = HTTPReply.json(#"{"data":[{"id":"claude-opus-5-5","max_input_tokens":200000},{"id":"custom-text","display_name":"Custom text","max_input_tokens":64000,"capabilities":{"structured_outputs":{"supported":true}}}],"has_more":true,"last_id":"cursor-one"}"#)
        let second = HTTPReply.json(#"{"data":[{"id":"claude-haiku-5-5","max_input_tokens":100000},{"id":"unstructured-model","capabilities":{"structured_outputs":{"supported":false}}}],"has_more":false,"last_id":"cursor-two"}"#)
        let harness = try HTTPHarness(.anthropic, replies: [first, second])
        defer { harness.finish() }
        await harness.connector.selectModel("claude-sonnet-5-5")
        let models = try await harness.connector.models(refresh: true)
        #expect(models.map(\.id) == ["claude-haiku-5-5", "claude-opus-5-5", "custom-text", "claude-sonnet-5-5"])
        #expect(models.prefix(2).allSatisfy { $0.source == .curated })
        #expect(models[2].source == .discovered)
        #expect(models[2].name == "Custom text")
        #expect(models.last?.name.hasSuffix("(not listed for this key)") == true)
        #expect(await harness.connector.contextTokens(model: "custom-text") == 64000)
        #expect(await harness.connector.contextTokens(model: "claude-opus-5-5") == 200000)
        let requests = HTTPStubProtocol.requests
        #expect(requests.count == 2)
        for captured in requests {
            #expect(captured.request.url?.path == "/v1/models")
            #expect(captured.request.httpMethod == "GET")
            #expect(captured.request.timeoutInterval == 15)
            #expect(captured.request.value(forHTTPHeaderField: "anthropic-version") == "2026-10-21")
            #expect(captured.request.value(forHTTPHeaderField: "x-api-key") == "test")
        }
        let firstQuery = URLComponents(url: try #require(requests.first?.request.url), resolvingAgainstBaseURL: false)?.queryItems
        let secondQuery = URLComponents(url: try #require(requests.last?.request.url), resolvingAgainstBaseURL: false)?.queryItems
        #expect(firstQuery?.contains(URLQueryItem(name: "limit", value: "100")) == true)
        #expect(firstQuery?.contains(where: { $0.name == "after_id" }) == false)
        #expect(secondQuery?.contains(URLQueryItem(name: "after_id", value: "cursor-one")) == true)
    }

    @Test
    func openaiRefreshFiltersNonChatModelsAndSortsNewDiscoveries() async throws {
        let data: [[String: Any]] = [
            ["id": "gpt-custom-old", "created": 1], ["id": "gpt-5.6-terra", "created": 3],
            ["id": "o9-custom", "created": 8], ["id": "gpt-custom-new", "created": 9],
            ["id": "gpt-5.6-luna", "created": 2], ["id": "other-chat", "created": 100]
        ] + ["audio", "realtime", "transcribe", "tts", "image", "search", "embedding", "moderation", "instruct"].map { ["id": "gpt-\($0)", "created": 200] }
        let harness = try HTTPHarness(.openai, replies: [.json(try HTTPFixtures.encode(["data": data]))])
        defer { harness.finish() }
        let models = try await harness.connector.models(refresh: true)
        #expect(models.map(\.id) == ["gpt-5.6-luna", "gpt-5.6-terra", "gpt-custom-new", "o9-custom", "gpt-custom-old"])
        #expect(models.prefix(2).allSatisfy { $0.source == .curated })
        #expect(models.suffix(3).allSatisfy { $0.source == .discovered })
    }

    @Test
    func xaiRefreshFiltersNonChatIDsAndPreservesProviderOrder() async throws {
        let identifiers = ["grok-custom-second", "grok-4.5", "grok-custom-first", "grok-4.3", "other-chat"] + ["image", "imagine", "video", "vision", "tts", "stt"].map { "grok-\($0)" }
        let harness = try HTTPHarness(.xai, replies: [.json(try HTTPFixtures.encode(["data": identifiers.map { ["id": $0] }]))])
        defer { harness.finish() }
        let models = try await harness.connector.models(refresh: true)
        #expect(models.map(\.id) == ["grok-4.3", "grok-4.5", "grok-custom-second", "grok-custom-first"])
    }

    @Test
    func geminiRefreshPaginatesFiltersAndNeverPlacesKeyInURL() async throws {
        let excluded = ["embedding", "image", "tts", "audio", "live", "aqa"].map { ["name": "models/gemini-\($0)", "supportedGenerationMethods": ["generateContent"]] as [String: Any] }
        let firstModels: [[String: Any]] = [
            ["name": "models/gemini-3.8-flash", "inputTokenLimit": 100000, "supportedGenerationMethods": ["generateContent"]],
            ["name": "models/gemini-embed-only", "supportedGenerationMethods": ["embedContent"]],
            ["name": "models/not-gemini-chat", "supportedGenerationMethods": ["generateContent"]]
        ] + excluded
        let first = HTTPReply.json(try HTTPFixtures.encode(["models": firstModels, "nextPageToken": "cursor two"]))
        let second = HTTPReply.json(#"{"models":[{"name":"models/gemini-custom","displayName":"Custom Gemini","inputTokenLimit":64000,"supportedGenerationMethods":["generateContent"]}]}"#)
        let harness = try HTTPHarness(.gemini, replies: [first, second])
        defer { harness.finish() }
        let models = try await harness.connector.models(refresh: true)
        #expect(models.map(\.id) == ["gemini-3.8-flash", "gemini-custom"])
        #expect(models.last?.name == "Custom Gemini")
        #expect(await harness.connector.contextTokens(model: "gemini-custom") == 64000)
        #expect(await harness.connector.contextTokens(model: "gemini-3.8-flash") == 100000)
        let requests = HTTPStubProtocol.requests
        #expect(requests.count == 2)
        for captured in requests {
            let url = try #require(captured.request.url)
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
            #expect(url.path == "/v1beta/models")
            #expect(captured.request.value(forHTTPHeaderField: "x-goog-api-key") == "test")
            #expect(query?.contains(URLQueryItem(name: "pageSize", value: "1000")) == true)
            #expect(!url.absoluteString.contains("key="))
            #expect(!url.absoluteString.contains("test"))
        }
        let query = URLComponents(url: try #require(requests.last?.request.url), resolvingAgainstBaseURL: false)?.queryItems
        #expect(query?.contains(URLQueryItem(name: "pageToken", value: "cursor two")) == true)
    }

    @Test
    func ollamaRefreshFiltersEmbeddingAndNonCompletionModels() async throws {
        let tags = HTTPReply.json(#"{"models":[{"name":"chat-one"},{"name":"embed-small"},{"name":"no-chat"},{"name":"chat-legacy"}]}"#)
        let first = HTTPReply.json(#"{"capabilities":["completion","thinking"],"model_info":{"architecture.context_length":16384}}"#)
        let rejected = HTTPReply.json(#"{"capabilities":["vision"],"model_info":{"architecture.context_length":8192}}"#)
        let legacy = HTTPReply.json(#"{"model_info":{"architecture.context_length":32768}}"#)
        let harness = try HTTPHarness(.ollama, replies: [tags, first, rejected, legacy])
        defer { harness.finish() }
        let models = try await harness.connector.models(refresh: true)
        #expect(models.map(\.id) == ["chat-one", "chat-legacy"])
        #expect(models.map(\.contextTokens) == [16384, 32768])
        #expect(models.allSatisfy { $0.source == .discovered })
        #expect(await harness.connector.contextTokens(model: "chat-one") == 16384)
        let requests = HTTPStubProtocol.requests
        #expect(requests.first?.request.url?.path == "/api/tags")
        #expect(try requests.dropFirst().map { try $0.json()[ai: "model"].aiString } == ["chat-one", "no-chat", "chat-legacy"])
        #expect(requests.dropFirst().allSatisfy { $0.request.httpMethod == "POST" && $0.request.url?.path == "/api/show" })
        #expect(requests.allSatisfy { $0.request.timeoutInterval == 15 })
    }

    @Test
    func lmstudioRefreshKeepsNonEmbeddingModelsInServerOrder() async throws {
        let harness = try HTTPHarness(.lmstudio, replies: [.json(#"{"data":[{"id":"local-second"},{"id":"embed-small"},{"id":"local-first"}]}"#)])
        defer { harness.finish() }
        let models = try await harness.connector.models(refresh: true)
        #expect(models.map(\.id) == ["local-second", "local-first"])
        #expect(models.allSatisfy { $0.source == .discovered })
        #expect(HTTPStubProtocol.requests.count == 1)
    }

    @Test(arguments: [0, 1, 2, 3])
    func lmstudioContextPrefersLoadedThenMaximumThenAssumes4096(_ scenario: Int) async throws {
        let replies: [HTTPReply] = [
            .json(#"{"state":"loaded","loaded_context_length":8192,"max_context_length":32768}"#),
            .json(#"{"state":"loaded","max_context_length":32768}"#),
            .json("{}"), .json("{}", status: 404)
        ]
        let harness = try HTTPHarness(.lmstudio, replies: [replies[scenario]])
        defer { harness.finish() }
        let expected = scenario == 0 ? 8192 : scenario == 1 ? 32768 : 4096
        #expect(await harness.connector.contextTokens(model: "local chat/model") == expected)
        #expect(await harness.connector.contextTokens(model: "local chat/model") == expected)
        #expect(HTTPStubProtocol.requests.count == 1)
        let captured = try #require(HTTPStubProtocol.requests.first)
        #expect(captured.request.url?.absoluteString.contains("/api/v0/models/local%20chat%2Fmodel") == true)
        #expect(captured.request.httpMethod == "GET")
        let assumed = await harness.connector.assumedContextModels
        #expect(assumed.contains("local chat/model") == (scenario >= 2))
    }

    @Test
    func anthropicCustomCapabilitiesEnableEffortAndUnstructuredSchemaInstruction() async throws {
        let list = HTTPReply.json(#"{"data":[{"id":"custom-chat","capabilities":{"effort":{"supported":true},"structured_outputs":{"supported":false}}}],"has_more":false}"#)
        let harness = try HTTPHarness(.anthropic, replies: [list, HTTPFixtures.success(.anthropic)])
        defer { harness.finish() }
        #expect(try await harness.connector.models(refresh: true) == [])
        let request = try HTTPFixtures.f1()
        _ = try await harness.connector.send(request, model: "custom-chat")
        let body = try #require(HTTPStubProtocol.requests.last).json()
        #expect(body[ai: "output_config"][ai: "effort"].aiString == "medium")
        #expect(body[ai: "output_config"][ai: "format"] == .null)
        let content = try #require(body[ai: "messages"].aiArray.first)[ai: "content"].aiArray
        #expect(content.last?[ai: "text"].aiString == request.instruction + "\n\nReply with only a JSON object that matches this JSON Schema: " + (try aiCompactCanonicalSchema(request.schema)))
    }

    @Test(arguments: [ConnectorID.anthropic, .openai, .xai, .gemini])
    func cloudStatusNeedsKeyWithoutSendingRequests(_ id: ConnectorID) async throws {
        let harness = try HTTPHarness(id, replies: [], key: nil)
        defer { harness.finish() }
        #expect(await harness.connector.status() == .needsKey)
        await #expect(throws: LLMError.missingKey) {
            try await harness.connector.send(harness.catalog.connectionTest(for: id), model: harness.model)
        }
        #expect(HTTPStubProtocol.requests.isEmpty)
    }

    @Test(arguments: [ConnectorID.ollama, .lmstudio])
    func localStatusReportsNotRunningOnConnectionRefused(_ id: ConnectorID) async throws {
        let baseURL = try #require(URL(string: "http://127.0.0.1:19876"))
        let harness = try HTTPHarness(id, replies: [.transport(.cannotConnectToHost)], baseURL: baseURL)
        defer { harness.finish() }
        #expect(await harness.connector.status() == .notRunning(url: baseURL.absoluteString))
        #expect(HTTPStubProtocol.requests.first?.request.timeoutInterval == 3)
    }

    @Test(arguments: [ConnectorID.ollama, .lmstudio])
    func localStatusReportsNoModelsWithoutGenerating(_ id: ConnectorID) async throws {
        let replies: [HTTPReply] = id == .ollama ? [.json(#"{"version":"test"}"#), .json(#"{"models":[]}"#)] : [.json(#"{"data":[]}"#), .json(#"{"data":[]}"#)]
        let harness = try HTTPHarness(id, replies: replies)
        defer { harness.finish() }
        #expect(await harness.connector.status() == .noModels)
        #expect(HTTPStubProtocol.requests.allSatisfy { $0.request.httpMethod == "GET" && $0.request.timeoutInterval == 3 })
        #expect(HTTPStubProtocol.requests.first?.request.url?.path == (id == .ollama ? "/api/version" : "/v1/models"))
    }
}
