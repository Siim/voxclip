import Foundation
import Testing
@testable import VoxClipCore

extension HTTPConnectorTests {
    @Test(arguments: [401, 403, 404])
    func retryHintsCannotOverrideTerminalErrors(_ status: Int) async throws {
        let harness = try HTTPHarness(.openai, replies: [.json("{}", status: status, headers: ["Retry-After": "40"])])
        defer { harness.finish() }
        let expected: LLMError = status == 404 ? .modelNotFound(harness.model) : .unauthorized
        await #expect(throws: expected) {
            try await harness.runner().test(on: harness.connector, model: harness.model)
        }
        #expect(harness.sleeps.durations.isEmpty)
        #expect(HTTPStubProtocol.requests.count == 1)
    }

    @Test(arguments: [429, 500, 502, 503, 504, 529])
    func transientHTTPStatusesRetryExactlyThreeTimes(_ status: Int) async throws {
        let failure = HTTPReply.json(#"{"error":{"message":"temporarily busy"}}"#, status: status)
        let harness = try HTTPHarness(.openai, replies: [failure, failure, failure])
        defer { harness.finish() }
        let expected: LLMError = status == 429 ? .rateLimited(retryAfter: nil) : [503, 529].contains(status) ? .overloaded : .server(status: status)
        await #expect(throws: expected) {
            try await harness.connector.send(harness.catalog.connectionTest(for: .openai), model: harness.model)
        }
        #expect(harness.sleeps.durations == [.seconds(1), .seconds(2)])
        #expect(HTTPStubProtocol.requests.count == 3)
        let bodies = try HTTPStubProtocol.requests.map { try $0.json() }
        #expect(bodies.allSatisfy { $0 == bodies.first })
    }

    @Test
    func retrySuccessStopsImmediatelyAfterSuccessfulAttempt() async throws {
        let harness = try HTTPHarness(.openai, replies: [.json("{}", status: 502), HTTPFixtures.success(.openai)])
        defer { harness.finish() }
        let result = try await harness.connector.send(harness.catalog.connectionTest(for: .openai), model: harness.model)
        #expect(result.stop == .complete)
        #expect(harness.sleeps.durations == [.seconds(1)])
        #expect(HTTPStubProtocol.requests.count == 2)
    }

    @Test(arguments: ["retry-after", "retry-after-ms"])
    func numericRetryHintReplacesBackoff(_ header: String) async throws {
        let value = header == "retry-after" ? "3" : "1500"
        let harness = try HTTPHarness(.openai, replies: [.json("{}", status: 429, headers: [header: value]), HTTPFixtures.success(.openai)])
        defer { harness.finish() }
        _ = try await harness.connector.send(harness.catalog.connectionTest(for: .openai), model: harness.model)
        #expect(harness.sleeps.durations == [.milliseconds(header == "retry-after" ? 3000 : 1500)])
    }

    @Test
    func httpDateRetryHintReplacesBackoff() async throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let header = formatter.string(from: Date().addingTimeInterval(20))
        let harness = try HTTPHarness(.openai, replies: [.json("{}", status: 429, headers: ["Retry-After": header]), HTTPFixtures.success(.openai)])
        defer { harness.finish() }
        _ = try await harness.connector.send(harness.catalog.connectionTest(for: .openai), model: harness.model)
        let duration = try #require(harness.sleeps.durations.first)
        #expect(duration > .seconds(15))
        #expect(duration <= .seconds(20))
        #expect(harness.sleeps.durations.count == 1)
    }

    @Test(arguments: [30, 40])
    func retryAfterCeilingIsInclusive(_ seconds: Int) async throws {
        let replies: [HTTPReply] = seconds == 30 ? [.json("{}", status: 429, headers: ["Retry-After": "30"]), try HTTPFixtures.success(.openai)] : [.json("{}", status: 429, headers: ["Retry-After": "40"])]
        let harness = try HTTPHarness(.openai, replies: replies)
        defer { harness.finish() }
        let request = try harness.catalog.connectionTest(for: .openai)
        if seconds == 30 {
            _ = try await harness.connector.send(request, model: harness.model)
            #expect(harness.sleeps.durations == [.seconds(30)])
            #expect(HTTPStubProtocol.requests.count == 2)
        } else {
            await #expect(throws: LLMError.rateLimited(retryAfter: 40)) { try await harness.connector.send(request, model: harness.model) }
            #expect(harness.sleeps.durations.isEmpty)
            #expect(HTTPStubProtocol.requests.count == 1)
        }
    }

    @Test(arguments: [3, 45])
    func geminiRetryInfoIsHonoredWithoutWaiting(_ seconds: Int) async throws {
        let body = try HTTPFixtures.encode(["error": ["status": "RESOURCE_EXHAUSTED", "details": [["@type": "type.googleapis.com/google.rpc.RetryInfo", "retryDelay": "\(seconds)s"]]]])
        var replies: [HTTPReply] = [.json(body, status: 429)]
        if seconds <= 30 { replies.append(try HTTPFixtures.success(.gemini)) }
        let harness = try HTTPHarness(.gemini, replies: replies)
        defer { harness.finish() }
        let request = try harness.catalog.connectionTest(for: .gemini)
        if seconds > 30 {
            await #expect(throws: LLMError.rateLimited(retryAfter: 45)) { try await harness.connector.send(request, model: harness.model) }
            #expect(harness.sleeps.durations.isEmpty)
            #expect(HTTPStubProtocol.requests.count == 1)
        } else {
            _ = try await harness.connector.send(request, model: harness.model)
            #expect(harness.sleeps.durations == [.seconds(3)])
        }
        #expect(HTTPStubProtocol.requests.allSatisfy { !($0.request.url?.absoluteString.contains("key=") ?? true) })
    }

    @Test
    func connectionLostRetriesBeforeAResponse() async throws {
        let harness = try HTTPHarness(.openai, replies: [.transport(.networkConnectionLost), .transport(.networkConnectionLost), HTTPFixtures.success(.openai)])
        defer { harness.finish() }
        _ = try await harness.connector.send(harness.catalog.connectionTest(for: .openai), model: harness.model)
        #expect(harness.sleeps.durations == [.seconds(1), .seconds(2)])
        #expect(HTTPStubProtocol.requests.count == 3)
    }

    @Test(arguments: [URLError.Code.timedOut, .cancelled, .notConnectedToInternet, .cannotFindHost, .secureConnectionFailed])
    func terminalTransportErrorsNeverRetry(_ code: URLError.Code) async throws {
        let harness = try HTTPHarness(.openai, replies: [.transport(code)])
        defer { harness.finish() }
        let expected: LLMError = code == .timedOut ? .timeout : code == .cancelled ? .cancelled : .network
        await #expect(throws: expected) {
            try await harness.connector.send(harness.catalog.connectionTest(for: .openai), model: harness.model)
        }
        #expect(harness.sleeps.durations.isEmpty)
        #expect(HTTPStubProtocol.requests.count == 1)
    }

    @Test
    func cancellationDuringBackoffMakesNoFurtherRequest() async throws {
        let harness = try HTTPHarness(.openai, replies: [.json("{}", status: 429)], cancelSleep: true)
        defer { harness.finish() }
        await #expect(throws: LLMError.cancelled) {
            try await harness.connector.send(harness.catalog.connectionTest(for: .openai), model: harness.model)
        }
        #expect(harness.sleeps.durations == [.seconds(1)])
        #expect(HTTPStubProtocol.requests.count == 1)
    }

    @Test
    func anthropicUnexpectedBetaRetriesWithoutHeaderAndRemembersSessionDecision() async throws {
        let rejected = HTTPReply.json(#"{"error":{"type":"invalid_request_error","message":"Unexpected anthropic-beta value"}}"#, status: 400)
        let harness = try HTTPHarness(.anthropic, replies: [rejected, HTTPFixtures.success(.anthropic), HTTPFixtures.success(.anthropic)])
        defer { harness.finish() }
        let canonical = try HTTPFixtures.f1()
        _ = try await harness.connector.send(canonical, model: harness.model)
        _ = try await harness.connector.send(canonical, model: harness.model)
        let requests = HTTPStubProtocol.requests
        #expect(requests.count == 3)
        #expect(requests.first?.request.value(forHTTPHeaderField: "anthropic-beta") != nil)
        #expect(try requests.first?.json()[ai: "fallbacks"].aiString == "default")
        for captured in requests.dropFirst() {
            #expect(captured.request.value(forHTTPHeaderField: "anthropic-beta") == nil)
            #expect(try captured.json()[ai: "fallbacks"] == .null)
        }
        #expect(harness.sleeps.durations.isEmpty)
    }

    @Test(arguments: [ConnectorID.anthropic, .gemini])
    func runnerFallsBackAfterThreeOverloadAttempts(_ id: ConnectorID) async throws {
        let catalog = try HTTPFixtures.catalog()
        let chosen = try #require(catalog.connector(id)[ai: "defaultModel"].aiString)
        let fallback = try #require(catalog.fallback(for: id, model: chosen))
        let overload = HTTPReply.json(id == .anthropic ? #"{"error":{"type":"overloaded_error"}}"# : #"{"error":{"status":"UNAVAILABLE"}}"#, status: id == .anthropic ? 529 : 503)
        let harness = try HTTPHarness(id, replies: [overload, overload, overload, HTTPFixtures.success(id, model: fallback)])
        defer { harness.finish() }
        let result = try await harness.runner().test(on: harness.connector, model: chosen)
        #expect(result.passed)
        #expect(result.usedFallback)
        #expect(result.model == fallback)
        #expect(harness.sleeps.durations == [.seconds(1), .seconds(2)])
        let requests = HTTPStubProtocol.requests
        #expect(requests.count == 4)
        if id == .gemini {
            #expect(requests.prefix(3).allSatisfy { $0.request.url?.path.contains(chosen) == true })
            #expect(requests.last?.request.url?.path.contains(fallback) == true)
        } else {
            #expect(try requests.prefix(3).allSatisfy { try $0.json()[ai: "model"].aiString == chosen })
            #expect(try requests.last?.json()[ai: "model"].aiString == fallback)
        }
    }

    @Test
    func fallbackGetsItsOwnThreeAttemptBudgetAndNoThirdModel() async throws {
        let overload = HTTPReply.json(#"{"error":{"type":"overloaded_error"}}"#, status: 529)
        let harness = try HTTPHarness(.anthropic, replies: Array(repeating: overload, count: 6))
        defer { harness.finish() }
        await #expect(throws: LLMError.overloaded) {
            try await harness.runner().test(on: harness.connector, model: harness.model)
        }
        #expect(harness.sleeps.durations == [.seconds(1), .seconds(2), .seconds(1), .seconds(2)])
        let models = try HTTPStubProtocol.requests.map { try $0.json()[ai: "model"].aiString }
        #expect(models.count == 6)
        #expect(Set(models.prefix(3)) == [harness.model])
        #expect(Set(models.suffix(3)) == [harness.catalog.fallback(for: .anthropic, model: harness.model)])
    }

    @Test(arguments: [ConnectorID.anthropic, .openai])
    func quotaFailureDoesNotRetryOrInvokeRunnerFallback(_ id: ConnectorID) async throws {
        let quota = id == .anthropic ? HTTPReply.json(#"{"error":{"type":"billing_error"}}"#, status: 402) : .json(#"{"error":{"code":"insufficient_quota"}}"#, status: 429, headers: ["Retry-After": "40"])
        let harness = try HTTPHarness(id, replies: [quota])
        defer { harness.finish() }
        await #expect(throws: LLMError.quotaExceeded) {
            try await harness.runner().test(on: harness.connector, model: harness.model)
        }
        #expect(harness.sleeps.durations.isEmpty)
        #expect(HTTPStubProtocol.requests.count == 1)
    }
}
