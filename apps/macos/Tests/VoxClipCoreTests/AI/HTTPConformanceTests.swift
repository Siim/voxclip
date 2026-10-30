import Foundation
import Testing
@testable import VoxClipCore

extension HTTPConnectorTests {
    @Test(arguments: ["gemini-3.5-flash-lite", "gemini-3.8-flash", "gemini-3.1-pro-preview"])
    func geminiCuratedModelsRetainCompatibleSchemaField(_ model: String) async throws {
        let harness = try HTTPHarness(.gemini, replies: [HTTPFixtures.success(.gemini)])
        defer { harness.finish() }
        let request = try harness.catalog.connectionTest(for: .gemini)
        _ = try await harness.connector.send(request, model: model)
        let generation = try #require(HTTPStubProtocol.requests.last).json()[ai: "generationConfig"]
        #expect(generation[ai: "responseJsonSchema"] == request.schema)
        #expect(generation[ai: "responseMimeType"].aiString == "application/json")
        #expect(generation[ai: "responseFormat"] == .null)
        #expect(generation[ai: "responseSchema"] == .null)
    }

    @Test
    func geminiUsageIncludesBilledThinkingTokens() async throws {
        let harness = try HTTPHarness(.gemini, replies: [.json(#"{"candidates":[{"finishReason":"STOP","content":{"parts":[{"text":"{}"}]}}],"usageMetadata":{"candidatesTokenCount":12,"thoughtsTokenCount":80}}"#)])
        defer { harness.finish() }
        let response = try await harness.connector.send(harness.catalog.connectionTest(for: .gemini), model: harness.model)
        #expect(response.usage?.output == 92)
        let body = try #require(HTTPStubProtocol.requests.last).json()
        #expect(body[ai: "generationConfig"][ai: "maxOutputTokens"].aiInt == 2048)
        #expect(body[ai: "generationConfig"][ai: "thinkingConfig"][ai: "thinkingLevel"].aiString == "LOW")
        #expect(body[ai: "generationConfig"][ai: "thinkingConfig"][ai: "thinkingBudget"] == .null)
    }

    @Test(arguments: ["FINISH_REASON_UNSPECIFIED", "STOP", "MAX_TOKENS", "SAFETY", "RECITATION", "LANGUAGE", "OTHER", "BLOCKLIST", "PROHIBITED_CONTENT", "SPII", "MALFORMED_FUNCTION_CALL", "IMAGE_SAFETY", "IMAGE_PROHIBITED_CONTENT", "IMAGE_OTHER", "NO_IMAGE", "IMAGE_RECITATION", "UNEXPECTED_TOOL_CALL", "TOO_MANY_TOOL_CALLS", "MISSING_THOUGHT_SIGNATURE", "MALFORMED_RESPONSE", "ESCALATION", "PUP_LIMITED_DISABLED", "CONTINUATION", "", "FUTURE_REASON"])
    func geminiFinishReasonsNeverCompleteUnlessStopped(_ reason: String) async throws {
        let reply = try HTTPFixtures.encode(["candidates": [["finishReason": reason, "content": ["parts": [["text": HTTPFixtures.completion]]]]]])
        let harness = try HTTPHarness(.gemini, replies: [.json(reply)])
        defer { harness.finish() }
        let refused = ["SAFETY", "RECITATION", "LANGUAGE", "OTHER", "BLOCKLIST", "PROHIBITED_CONTENT", "SPII", "IMAGE_SAFETY", "IMAGE_PROHIBITED_CONTENT", "IMAGE_OTHER", "IMAGE_RECITATION", "ESCALATION"]
        if reason == "STOP" || reason == "MAX_TOKENS" || reason == "CONTINUATION" || refused.contains(reason) {
            let result = try await harness.connector.send(harness.catalog.connectionTest(for: .gemini), model: harness.model)
            #expect(result.stop == (reason == "STOP" ? .complete : refused.contains(reason) ? .refused(category: reason) : .truncated))
        } else {
            let expected: LLMError = reason == "PUP_LIMITED_DISABLED" ? .unavailable(reason: "Google Gemini has limited or disabled this account for prohibited use.") : .server(status: 500)
            await #expect(throws: expected) { try await harness.runner().test(on: harness.connector, model: harness.model) }
        }
        #expect(HTTPStubProtocol.requests.count == 1)
    }

    @Test(arguments: ["server_error", "rate_limit_exceeded", "invalid_prompt", "bio_policy", "misalignment_policy_violation", "image_content_policy_violation", "vector_store_timeout", "data_residency_mismatch", "invalid_image", "invalid_image_format", "invalid_base64_image", "invalid_image_url", "image_too_large", "image_too_small", "image_parse_error", "invalid_image_mode", "image_file_too_large", "unsupported_image_media_type", "empty_image_file", "failed_to_download_image", "image_file_not_found", "unknown", "model_not_found", "context_length_exceeded", "insufficient_quota"])
    func openAIFailedResponseUsesDocumentedCodesWithoutRetries(_ code: String) async throws {
        let harness = try HTTPHarness(.openai, replies: [.json(try HTTPFixtures.encode(["status": "failed", "error": ["code": code]]))])
        defer { harness.finish() }
        let expected: LLMError
        switch code {
        case "rate_limit_exceeded": expected = .rateLimited(retryAfter: nil)
        case "invalid_prompt", "bio_policy", "misalignment_policy_violation", "image_content_policy_violation": expected = .refused(category: code)
        case "data_residency_mismatch": expected = .unavailable(reason: "OpenAI can't serve this request in the configured data region.")
        case "invalid_image", "invalid_image_format", "invalid_base64_image", "invalid_image_url", "image_too_large", "image_too_small", "image_parse_error", "invalid_image_mode", "image_file_too_large", "unsupported_image_media_type", "empty_image_file", "failed_to_download_image", "image_file_not_found": expected = .badRequest(status: 400, message: "OpenAI couldn't process an image in the request.")
        default: expected = .server(status: 500)
        }
        await #expect(throws: expected) { try await harness.connector.send(harness.catalog.connectionTest(for: .openai), model: harness.model) }
        #expect(HTTPStubProtocol.requests.count == 1)
        #expect(harness.sleeps.durations.isEmpty)
    }

    @Test
    func anthropicContextExhaustionDoesNotCorrectPartialJSON() async throws {
        let harness = try HTTPHarness(.anthropic, replies: [.json(#"{"stop_reason":"model_context_window_exceeded","content":[{"type":"text","text":"{"}]}"#)])
        defer { harness.finish() }
        await #expect(throws: LLMError.truncated) {
            try await harness.runner().test(on: harness.connector, model: harness.model)
        }
        #expect(HTTPStubProtocol.requests.count == 1)
    }

    @Test(arguments: ["not-loaded", "loading", "", "loaded"])
    func lmStudioRequiresLoadedStateForWorkingContext(_ state: String) async throws {
        let harness = try HTTPHarness(.lmstudio, replies: [.json("{\"state\":\"\(state)\",\"max_context_length\":131072}")])
        defer { harness.finish() }
        #expect(await harness.connector.contextTokens(model: "local") == (state == "loaded" ? 131072 : 4096))
        #expect(await harness.connector.assumedContextModels.contains("local") == (state != "loaded"))
    }

    @Test(arguments: [8192, 0, -1])
    func lmStudioPrefersOnlyPositiveLoadedContext(_ loaded: Int) async throws {
        let harness = try HTTPHarness(.lmstudio, replies: [.json("{\"state\":\"loaded\",\"loaded_context_length\":\(loaded),\"max_context_length\":131072}")])
        defer { harness.finish() }
        #expect(await harness.connector.contextTokens(model: "local") == (loaded > 0 ? loaded : 131072))
    }
}
