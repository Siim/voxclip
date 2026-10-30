import Foundation
import Testing
@testable import VoxClipCore

extension HTTPConnectorTests {
    @Test(arguments: HTTPFixtures.connectors)
    func f1RequestMatchesCompleteParsedJSONGolden(_ id: ConnectorID) async throws {
        let harness = try HTTPHarness(id, replies: HTTPFixtures.localDetails(id) + [HTTPFixtures.success(id)])
        defer { harness.finish() }
        let canonical = try HTTPFixtures.f1()
        _ = try await harness.connector.send(canonical, model: harness.model)
        let captured = try #require(HTTPStubProtocol.requests.last)
        #expect(try captured.json() == HTTPFixtures.golden(id, request: canonical, model: harness.model))
        #expect(captured.request.httpMethod == "POST")
        #expect(captured.request.timeoutInterval == 180)
        #expect(captured.request.value(forHTTPHeaderField: "User-Agent") == "VoxClip/9.8.7 (macOS)")
        #expect(captured.request.value(forHTTPHeaderField: "content-type") == "application/json")
        #expect(captured.request.httpShouldHandleCookies == false)
        #expect(captured.request.cachePolicy == .reloadIgnoringLocalCacheData)
        let paths: [ConnectorID: String] = [.anthropic: "/v1/messages", .openai: "/v1/responses", .xai: "/v1/chat/completions", .gemini: "/v1beta/models/\(harness.model):generateContent", .ollama: "/api/chat", .lmstudio: "/v1/chat/completions"]
        #expect(captured.request.url?.path == paths[id])
        #expect(captured.request.url?.host == URL(string: harness.catalog.connector(id)[ai: "baseUrl"].aiString ?? "")?.host)
        #expect(captured.request.url?.query == nil)
        if id == .anthropic {
            #expect(captured.request.value(forHTTPHeaderField: "x-api-key") == "test")
            #expect(captured.request.value(forHTTPHeaderField: "anthropic-version") == "2026-10-21")
            #expect(captured.request.value(forHTTPHeaderField: "anthropic-beta") == "server-side-fallback-2026-07-01")
        } else if id == .gemini {
            #expect(captured.request.value(forHTTPHeaderField: "x-goog-api-key") == "test")
            #expect(captured.request.value(forHTTPHeaderField: "Authorization") == nil)
        } else if id == .ollama || id == .lmstudio {
            #expect(captured.request.value(forHTTPHeaderField: "Authorization") == nil)
        } else {
            #expect(captured.request.value(forHTTPHeaderField: "Authorization") == "Bearer test")
        }
    }

    @Test(arguments: HTTPFixtures.connectors)
    func connectionTestOmitsAbsentCachedBlock(_ id: ConnectorID) async throws {
        let harness = try HTTPHarness(id, replies: HTTPFixtures.localDetails(id) + [HTTPFixtures.success(id)])
        defer { harness.finish() }
        let canonical = try harness.catalog.connectionTest(for: id)
        _ = try await harness.connector.send(canonical, model: harness.model)
        let captured = try #require(HTTPStubProtocol.requests.last)
        #expect(try captured.json() == HTTPFixtures.golden(id, request: canonical, model: harness.model))
        #expect(captured.request.timeoutInterval == 30)
        let body = try captured.json()
        #expect(body[ai: "prompt_cache_key"] == .null)
        if id == .anthropic {
            let content = try #require(body[ai: "messages"].aiArray.first)[ai: "content"].aiArray
            #expect(content.count == 1)
            #expect(content.first?[ai: "cache_control"] == .null)
        }
    }

    @Test(arguments: [ConnectorID.anthropic, .openai, .xai, .gemini])
    func cloudRequestsNeverSendForbiddenParameters(_ id: ConnectorID) async throws {
        let harness = try HTTPHarness(id, replies: [HTTPFixtures.success(id)])
        defer { harness.finish() }
        _ = try await harness.connector.send(HTTPFixtures.f1(), model: harness.model)
        let body = try #require(HTTPStubProtocol.requests.last).json()
        let forbidden = ["temperature", "top_p", "top_k", "thinking", "tool_choice", "reasoning_effort", "responseSchema", "topP", "topK", "thinkingBudget"] + (id == .gemini ? [] : ["thinkingConfig"])
        func HTTPCheck(_ value: JSONValue) {
            if let object = value.aiObject {
                for (key, child) in object where key != "schema" && key != "responseJsonSchema" {
                    #expect(!forbidden.contains(key), "Forbidden parameter: \(key)")
                    HTTPCheck(child)
                }
            }
            for child in value.aiArray { HTTPCheck(child) }
        }
        HTTPCheck(body)
    }

    @Test(arguments: [ConnectorID.anthropic, .openai])
    func unrecognizedCustomModelOmitsEffort(_ id: ConnectorID) async throws {
        let harness = try HTTPHarness(id, replies: [HTTPFixtures.success(id)])
        defer { harness.finish() }
        _ = try await harness.connector.send(HTTPFixtures.f1(), model: "custom-chat")
        let captured = try #require(HTTPStubProtocol.requests.last)
        let body = try captured.json()
        #expect(body[ai: "model"].aiString == "custom-chat")
        #expect(body[ai: "reasoning"] == .null)
        #expect(body[ai: "output_config"][ai: "effort"] == .null)
        #expect(body[ai: "fallbacks"] == .null)
        #expect(captured.request.value(forHTTPHeaderField: "anthropic-beta") == nil)
        if id == .anthropic {
            #expect(body[ai: "output_config"][ai: "format"][ai: "schema"] == (try HTTPFixtures.f1()).schema)
        }
    }

    @Test(arguments: ["claude-fable-5-custom", "claude-opus-5-custom", "gpt-6-custom", "o9-custom"])
    func recognizedCustomReasoningModelIncludesEffort(_ model: String) async throws {
        let id: ConnectorID = model.hasPrefix("claude-") ? .anthropic : .openai
        let harness = try HTTPHarness(id, replies: [HTTPFixtures.success(id)])
        defer { harness.finish() }
        _ = try await harness.connector.send(HTTPFixtures.f1(), model: model)
        let body = try #require(HTTPStubProtocol.requests.last).json()
        #expect((id == .anthropic ? body[ai: "output_config"][ai: "effort"] : body[ai: "reasoning"][ai: "effort"]).aiString == "medium")
    }

    @Test
    func geminiStripsModelPrefixEscapesPathAndKeepsKeyOutOfURL() async throws {
        let harness = try HTTPHarness(.gemini, replies: [HTTPFixtures.success(.gemini)])
        defer { harness.finish() }
        _ = try await harness.connector.send(HTTPFixtures.f1(), model: "models/gemini custom/preview?beta#one")
        let captured = try #require(HTTPStubProtocol.requests.last)
        let url = try #require(captured.request.url)
        #expect(url.absoluteString.contains("/gemini%20custom%2Fpreview%3Fbeta%23one:generateContent"))
        #expect(url.query == nil)
        #expect(url.fragment == nil)
        #expect(!url.absoluteString.contains("key="))
        #expect(!url.absoluteString.contains("test"))
        #expect(captured.request.value(forHTTPHeaderField: "x-goog-api-key") == "test")
    }

    @Test(arguments: [true, false])
    func ollamaContextRoundsUpAndDisablesOnlyAdvertisedThinking(_ thinking: Bool) async throws {
        let harness = try HTTPHarness(.ollama, replies: HTTPFixtures.localDetails(.ollama, context: 16384, thinking: thinking) + [HTTPFixtures.success(.ollama)])
        defer { harness.finish() }
        var canonical = try HTTPFixtures.f1()
        canonical.instruction += String(repeating: "é", count: 5000)
        _ = try await harness.connector.send(canonical, model: harness.model)
        let requests = HTTPStubProtocol.requests
        #expect(requests.first?.request.url?.path == "/api/show")
        #expect(try requests.first?.json() == .object(["model": .string(harness.model)]))
        let body = try #require(requests.last).json()
        #expect(body == (try HTTPFixtures.golden(.ollama, request: canonical, model: harness.model, context: 16384, thinking: thinking)))
        let context = try #require(body[ai: "options"][ai: "num_ctx"].aiInt)
        #expect(context > 8192)
        #expect(context <= 16384)
        #expect(context % 1024 == 0)
        #expect(body[ai: "options"][ai: "num_predict"].aiInt == 4096)
        #expect(body[ai: "think"] == (thinking ? .bool(false) : .null))
        #expect(await harness.connector.contextTokens(model: harness.model) == 16384)
        #expect(HTTPStubProtocol.requests.count == 2)
    }

    @Test
    func ollamaRejectsOversizedContextWithoutGenerating() async throws {
        let harness = try HTTPHarness(.ollama, replies: HTTPFixtures.localDetails(.ollama, context: 4096))
        defer { harness.finish() }
        await #expect(throws: LLMError.contextTooLong) {
            try await harness.connector.send(HTTPFixtures.f1(), model: harness.model)
        }
        #expect(HTTPStubProtocol.requests.count == 1)
        #expect(HTTPStubProtocol.requests.first?.request.url?.path == "/api/show")
    }
}
