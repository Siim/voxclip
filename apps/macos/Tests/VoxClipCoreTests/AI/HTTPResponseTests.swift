import Foundation
import Testing
import VoxClipCore

private struct HTTPStopFixture: Sendable {
    let id: ConnectorID
    let body: String
    let stop: StopKind

    static let all: [Self] = [
        Self(id: .anthropic, body: #"{"stop_reason":"refusal","stop_details":{"category":"safety"},"content":[]}"#, stop: .refused(category: "safety")),
        Self(id: .anthropic, body: #"{"stop_reason":"max_tokens","content":[{"type":"text","text":"partial"}]}"#, stop: .truncated),
        Self(id: .anthropic, body: #"{"stop_reason":"stop_sequence","content":[]}"#, stop: .complete),
        Self(id: .openai, body: #"{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"output":[]}"#, stop: .truncated),
        Self(id: .openai, body: #"{"status":"incomplete","incomplete_details":{"reason":"content_filter"},"output":[]}"#, stop: .refused(category: "content_filter")),
        Self(id: .openai, body: #"{"status":"completed","output":[{"type":"message","content":[{"type":"refusal","refusal":"Declined"}]}]}"#, stop: .refused(category: nil)),
        Self(id: .xai, body: #"{"choices":[{"finish_reason":"length","message":{"content":"partial"}}]}"#, stop: .truncated),
        Self(id: .xai, body: #"{"choices":[{"finish_reason":"stop","message":{"refusal":"Declined"}}]}"#, stop: .refused(category: nil)),
        Self(id: .lmstudio, body: #"{"choices":[{"finish_reason":"length","message":{"content":"partial"}}]}"#, stop: .truncated),
        Self(id: .lmstudio, body: #"{"choices":[{"finish_reason":"stop","message":{"refusal":"Declined"}}]}"#, stop: .refused(category: nil)),
        Self(id: .gemini, body: #"{"promptFeedback":{"blockReason":"BLOCKLIST"}}"#, stop: .refused(category: "BLOCKLIST")),
        Self(id: .gemini, body: #"{"candidates":[{"finishReason":"MAX_TOKENS","content":{"parts":[]}}]}"#, stop: .truncated),
        Self(id: .gemini, body: #"{"candidates":[{"finishReason":"CONTINUATION","content":{"parts":[]}}]}"#, stop: .truncated),
        Self(id: .gemini, body: #"{"candidates":[{"finishReason":"SAFETY","content":{"parts":[]}}]}"#, stop: .refused(category: "SAFETY")),
        Self(id: .gemini, body: #"{"candidates":[{"finishReason":"RECITATION","content":{"parts":[]}}]}"#, stop: .refused(category: "RECITATION")),
        Self(id: .gemini, body: #"{"candidates":[{"finishReason":"LANGUAGE","content":{"parts":[]}}]}"#, stop: .refused(category: "LANGUAGE")),
        Self(id: .gemini, body: #"{"candidates":[{"finishReason":"BLOCKLIST","content":{"parts":[]}}]}"#, stop: .refused(category: "BLOCKLIST")),
        Self(id: .gemini, body: #"{"candidates":[{"finishReason":"PROHIBITED_CONTENT","content":{"parts":[]}}]}"#, stop: .refused(category: "PROHIBITED_CONTENT")),
        Self(id: .gemini, body: #"{"candidates":[{"finishReason":"SPII","content":{"parts":[]}}]}"#, stop: .refused(category: "SPII")),
        Self(id: .gemini, body: #"{"candidates":[{"finishReason":"OTHER","content":{"parts":[]}}]}"#, stop: .refused(category: "OTHER")),
        Self(id: .ollama, body: #"{"done_reason":"length","message":{"content":"partial"}}"#, stop: .truncated)
    ]
}

private struct HTTPErrorFixture: Sendable {
    let id: ConnectorID
    let status: Int
    let body: String
    let expected: LLMError

    static let all: [Self] = [
        Self(id: .anthropic, status: 400, body: #"{"error":{"type":"invalid_request_error","message":"prompt is too long"}}"#, expected: .contextTooLong),
        Self(id: .anthropic, status: 400, body: #"{"error":{"type":"invalid_request_error","message":"too many tokens"}}"#, expected: .contextTooLong),
        Self(id: .anthropic, status: 401, body: #"{"error":{"type":"authentication_error"}}"#, expected: .unauthorized),
        Self(id: .anthropic, status: 402, body: #"{"error":{"type":"billing_error"}}"#, expected: .quotaExceeded),
        Self(id: .anthropic, status: 403, body: #"{"error":{"type":"permission_error"}}"#, expected: .unauthorized),
        Self(id: .anthropic, status: 404, body: #"{"error":{"type":"not_found_error"}}"#, expected: .modelNotFound("claude-opus-5-5")),
        Self(id: .anthropic, status: 413, body: #"{"error":{"type":"request_too_large"}}"#, expected: .contextTooLong),
        Self(id: .openai, status: 400, body: #"{"error":{"code":"context_length_exceeded"}}"#, expected: .contextTooLong),
        Self(id: .openai, status: 400, body: #"{"error":{"code":"model_not_found"}}"#, expected: .modelNotFound("gpt-5.6-terra")),
        Self(id: .openai, status: 401, body: #"{"error":{}}"#, expected: .unauthorized),
        Self(id: .openai, status: 403, body: #"{"error":{}}"#, expected: .unauthorized),
        Self(id: .openai, status: 404, body: #"{"error":{}}"#, expected: .modelNotFound("gpt-5.6-terra")),
        Self(id: .openai, status: 429, body: #"{"error":{"code":"insufficient_quota"}}"#, expected: .quotaExceeded),
        Self(id: .openai, status: 429, body: #"{"error":{"type":"insufficient_quota"}}"#, expected: .quotaExceeded),
        Self(id: .xai, status: 400, body: #"{"error":{"message":"Invalid API key"}}"#, expected: .unauthorized),
        Self(id: .xai, status: 400, body: #"{"error":{"message":"maximum context length exceeded"}}"#, expected: .contextTooLong),
        Self(id: .xai, status: 403, body: #"{"error":{}}"#, expected: .unauthorized),
        Self(id: .xai, status: 404, body: #"{"error":{}}"#, expected: .modelNotFound("grok-4.5")),
        Self(id: .gemini, status: 400, body: #"{"error":{"status":"INVALID_ARGUMENT","details":[{"reason":"API_KEY_INVALID"}]}}"#, expected: .unauthorized),
        Self(id: .gemini, status: 400, body: #"{"error":{"message":"exceeding the maximum number of tokens"}}"#, expected: .contextTooLong),
        Self(id: .gemini, status: 403, body: #"{"error":{"status":"PERMISSION_DENIED"}}"#, expected: .unauthorized),
        Self(id: .gemini, status: 404, body: #"{"error":{"status":"NOT_FOUND"}}"#, expected: .modelNotFound("gemini-3.8-flash")),
        Self(id: .gemini, status: 504, body: #"{"error":{"status":"DEADLINE_EXCEEDED"}}"#, expected: .timeout),
        Self(id: .ollama, status: 404, body: #"{"error":"model 'gemma4:12b' not found"}"#, expected: .modelNotFound("gemma4:12b")),
        Self(id: .ollama, status: 400, body: #"{"error":"model 'gemma4:12b' not found"}"#, expected: .modelNotFound("gemma4:12b")),
        Self(id: .lmstudio, status: 400, body: #"{"error":{"message":"No models loaded"}}"#, expected: .noModels)
    ]
}

extension HTTPConnectorTests {
    @Test(arguments: HTTPFixtures.connectors)
    func parsesSuccessfulTextUsageAndRequestID(_ id: ConnectorID) async throws {
        let harness = try HTTPHarness(id, replies: HTTPFixtures.localDetails(id) + [HTTPFixtures.success(id)])
        defer { harness.finish() }
        let result = try await harness.connector.send(harness.catalog.connectionTest(for: id), model: harness.model)
        #expect(result.text == HTTPFixtures.completion)
        #expect(result.stop == .complete)
        #expect(result.model == harness.model)
        #expect(result.usage?.input == 17)
        #expect(result.usage?.output == 9)
        #expect(result.usage?.cacheRead == (id == .ollama ? nil : 5))
        #expect(result.usage?.cacheWrite == (id == .anthropic ? 3 : nil))
        if id == .anthropic { #expect(result.requestID == "anthropic-request") }
        if id == .openai { #expect(result.requestID == "http-request") }
        let registered = await harness.log.registered
        #expect(registered.contains("test") || id == .ollama || id == .lmstudio)
        let entries = await harness.log.entries
        #expect(entries.count == 1)
        #expect(entries.allSatisfy { !$0.message.contains(HTTPFixtures.completion) })
    }

    @Test(arguments: HTTPStopFixture.all)
    fileprivate func mapsRefusalAndTruncationWithoutRetry(_ fixture: HTTPStopFixture) async throws {
        let harness = try HTTPHarness(fixture.id, replies: HTTPFixtures.localDetails(fixture.id) + [.json(fixture.body)])
        defer { harness.finish() }
        let result = try await harness.connector.send(harness.catalog.connectionTest(for: fixture.id), model: harness.model)
        #expect(result.stop == fixture.stop)
        #expect(harness.sleeps.durations.isEmpty)
    }

    @Test(arguments: HTTPErrorFixture.all)
    fileprivate func mapsProviderErrorsWithoutRetry(_ fixture: HTTPErrorFixture) async throws {
        try await HTTPFixtures.error(fixture.id, .json(fixture.body, status: fixture.status), expected: fixture.expected)
    }

    @Test
    func anthropicConcatenatesOnlyTextAndReportsAnsweringModel() async throws {
        let reply = HTTPReply.json(#"{"model":"claude-sonnet-5-5","stop_reason":"end_turn","content":[{"type":"thinking","thinking":"hidden"},{"type":"text","text":"first"},{"type":"server_side_fallback","model":"claude-sonnet-5-5"},{"type":"text","text":"second"}]}"#)
        let harness = try HTTPHarness(.anthropic, replies: [reply])
        defer { harness.finish() }
        let result = try await harness.connector.send(HTTPFixtures.f1(), model: harness.model)
        #expect(result.text == "firstsecond")
        #expect(result.model == "claude-sonnet-5-5")
        #expect(result.stop == .complete)
    }

    @Test
    func openaiConcatenatesMessagesAndIgnoresNonTextItems() async throws {
        let reply = HTTPReply.json(#"{"status":"completed","output":[{"type":"reasoning","content":[{"type":"output_text","text":"hidden"}]},{"type":"message","content":[{"type":"output_text","text":"first"},{"type":"annotation","text":"hidden"}]},{"type":"message","content":[{"type":"output_text","text":"second"}]}]}"#)
        let harness = try HTTPHarness(.openai, replies: [reply])
        defer { harness.finish() }
        let result = try await harness.connector.send(HTTPFixtures.f1(), model: harness.model)
        #expect(result.text == "firstsecond")
        #expect(result.stop == .complete)
    }

    @Test
    func geminiConcatenatesNonThoughtPartsFromFirstCandidate() async throws {
        let reply = HTTPReply.json(#"{"candidates":[{"finishReason":"STOP","content":{"parts":[{"text":"hidden","thought":true},{"text":"first"},{"text":"second","thought":false}]}},{"finishReason":"STOP","content":{"parts":[{"text":"other candidate"}]}}]}"#)
        let harness = try HTTPHarness(.gemini, replies: [reply])
        defer { harness.finish() }
        let result = try await harness.connector.send(HTTPFixtures.f1(), model: harness.model)
        #expect(result.text == "firstsecond")
        #expect(result.stop == .complete)
        #expect(HTTPStubProtocol.requests.allSatisfy { !($0.request.url?.absoluteString.contains("key=") ?? true) })
    }

    @Test(arguments: ["model_not_found", "context_length_exceeded", "insufficient_quota"])
    func openaiFailedEnvelopeMapsErrorEvenWithHTTP200(_ code: String) async throws {
        let harness = try HTTPHarness(.openai, replies: [.json(try HTTPFixtures.encode(["status": "failed", "error": ["code": code]]))])
        defer { harness.finish() }
        let expected: LLMError = code == "model_not_found" ? .modelNotFound(harness.model) : code == "insufficient_quota" ? .quotaExceeded : .contextTooLong
        await #expect(throws: expected) {
            try await harness.connector.send(harness.catalog.connectionTest(for: .openai), model: harness.model)
        }
        #expect(harness.sleeps.durations.isEmpty)
        #expect(HTTPStubProtocol.requests.count == 1)
    }

    @Test(arguments: [ConnectorID.anthropic, .openai, .xai, .gemini, .ollama, .lmstudio])
    func otherBadRequestsAreRedactedAndLimitedTo200Characters(_ id: ConnectorID) async throws {
        let raw = "Rejected x-api-key=test " + String(repeating: "x", count: 240)
        let harness = try HTTPHarness(id, replies: HTTPFixtures.localDetails(id) + [.json(try HTTPFixtures.encode(["error": ["message": raw]]), status: 400)])
        defer { harness.finish() }
        do {
            _ = try await harness.connector.send(harness.catalog.connectionTest(for: id), model: harness.model)
            Issue.record("Expected badRequest")
        } catch let failure as LLMError {
            guard case .badRequest(let status, let message) = failure else {
                Issue.record("Unexpected mapping: \(failure)")
                return
            }
            #expect(status == 400)
            #expect(message.utf16.count <= 200)
            #expect(message.contains("[REDACTED]"))
            #expect(!message.contains("test"))
        }
        #expect(harness.sleeps.durations.isEmpty)
    }
}
