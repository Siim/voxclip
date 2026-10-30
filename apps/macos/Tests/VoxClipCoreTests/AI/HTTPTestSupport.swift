import CryptoKit
import Foundation
import Synchronization
import Testing
@testable import VoxClipCore

@Suite(.serialized, .httpStubs, .timeLimit(.minutes(1)))
struct HTTPConnectorTests {}

struct HTTPReply: Sendable {
    var status = 200
    var body: String
    var headers: [String: String] = [:]
    var failure: URLError.Code?
    var redirectURL: URL?

    static func json(_ body: String, status: Int = 200, headers: [String: String] = [:]) -> Self {
        Self(status: status, body: body, headers: headers)
    }

    static func transport(_ code: URLError.Code) -> Self {
        Self(body: "", failure: code)
    }

    static func redirect(to url: URL) -> Self {
        Self(status: 307, body: "", headers: ["Location": url.absoluteString], redirectURL: url)
    }
}

struct HTTPRecordedRequest: Sendable {
    let request: URLRequest
    let body: Data

    func json() throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: body)
    }
}

final class HTTPStubProtocol: URLProtocol, @unchecked Sendable {
    fileprivate struct HTTPState: Sendable {
        var replies: [HTTPReply] = []
        var requests: [HTTPRecordedRequest] = []
        var unexpected: [String] = []
    }

    /// One test case's replies and requests. Sessions from `configuration()` send its token, so a
    /// request only ever takes a reply that its own test installed.
    final class Scope: Sendable {
        static let header = "X-VoxClip-HTTP-Stub"
        let token = UUID().uuidString
        fileprivate let state = Mutex(HTTPState())

        var remaining: Int { state.withLock { $0.replies.count } }
        /// Requests that arrived with no reply left, as "METHOD URL".
        var unexpected: [String] { state.withLock { $0.unexpected } }
    }

    @TaskLocal private static var current: Scope?
    private static let scopes = Mutex<[String: Scope]>([:])

    private static var scope: Scope {
        if let current { return current }
        Issue.record("HTTPStubProtocol needs the .httpStubs trait on the test or its suite.")
        return Scope()
    }

    static func install(_ replies: [HTTPReply]) {
        scope.state.withLock { $0.replies = replies; $0.requests = [] }
    }

    static var requests: [HTTPRecordedRequest] {
        scope.state.withLock { $0.requests }
    }

    static var remaining: Int {
        scope.remaining
    }

    /// An ephemeral configuration whose requests reach only the current test's replies.
    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HTTPStubProtocol.self]
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        if let current { configuration.httpAdditionalHeaders = [Scope.header: current.token] }
        return configuration
    }

    /// Runs `body` with `scope` registered and current.
    static func withScope<Value>(_ scope: Scope, _ body: () async throws -> Value) async rethrows -> Value {
        scopes.withLock { $0[scope.token] = scope }
        defer { scopes.withLock { _ = $0.removeValue(forKey: scope.token) } }
        return try await $current.withValue(scope) { try await body() }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        let token = request.value(forHTTPHeaderField: Scope.header)
        var captured = request
        captured.setValue(nil, forHTTPHeaderField: Scope.header)
        let recorded = HTTPRecordedRequest(request: captured, body: body)
        let target = "\(request.httpMethod ?? "GET") \(request.url?.absoluteString ?? "")"
        // A session without a token belongs to the only test with a scope; with several, it is
        // ambiguous and fails rather than take another test's reply.
        let scope = Self.scopes.withLock { scopes in
            token.map { scopes[$0] } ?? (scopes.count == 1 ? scopes.values.first : nil)
        }
        let reply = scope?.state.withLock { state -> HTTPReply? in
            state.requests.append(recorded)
            guard !state.replies.isEmpty else { state.unexpected.append(target); return nil }
            return state.replies.removeFirst()
        }
        guard let reply else {
            var details: [String: Any] = [NSLocalizedDescriptionKey: "No stubbed reply for \(target)."]
            if let url = request.url { details[NSURLErrorFailingURLErrorKey] = url }
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable, userInfo: details))
            return
        }
        if let failure = reply.failure {
            client?.urlProtocol(self, didFailWithError: URLError(failure))
            return
        }
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers) else {
            Issue.record("Could not synthesize HTTP response")
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        if let redirectURL = reply.redirectURL {
            var redirected = request
            redirected.url = redirectURL
            redirected.httpBodyStream = nil
            redirected.httpBody = body.isEmpty ? nil : body
            client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Gives every test case its own HTTPStubProtocol scope and reports requests that found no reply.
struct HTTPStubScope: TestTrait, SuiteTrait, TestScoping {
    var isRecursive: Bool { true }

    func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
        let scope = HTTPStubProtocol.Scope()
        defer {
            if !scope.unexpected.isEmpty {
                Issue.record("Unexpected HTTP requests without a stubbed reply: \(scope.unexpected.joined(separator: ", "))")
            }
        }
        try await HTTPStubProtocol.withScope(scope) { try await function() }
    }
}

extension Trait where Self == HTTPStubScope {
    static var httpStubs: Self { Self() }
}

struct HTTPKeys: KeyProvider {
    var value: String? = "test"
    func key(for provider: String) async throws -> String? { value }
}

actor HTTPLog: Redacting {
    private var redactor = Redactor(homeDirectory: "")
    private(set) var registered: [String] = []
    private(set) var entries: [LogEntry] = []

    func register(secret: String) {
        registered.append(secret)
        redactor.register(secret: secret)
    }

    func redact(_ message: String) -> String { redactor.redact(message) }
    func write(_ entry: LogEntry) { entries.append(entry) }
}

final class HTTPSleeps: Sendable {
    private let values = Mutex<[Duration]>([])
    let cancel: Bool

    init(cancel: Bool = false) { self.cancel = cancel }

    func sleep(_ duration: Duration) throws {
        values.withLock { $0.append(duration) }
        if cancel { throw CancellationError() }
    }

    var durations: [Duration] { values.withLock { $0 } }
}

struct HTTPHarness: Sendable {
    let catalog: LLMCatalog
    let connector: HTTPConnector
    let keys: any KeyProvider
    let log: HTTPLog
    let sleeps: HTTPSleeps
    let session: URLSession

    init(_ id: ConnectorID, replies: [HTTPReply], key: String? = "test", cancelSleep: Bool = false, baseURL: URL? = nil, catalog: LLMCatalog? = nil, keys: (any KeyProvider)? = nil, cacheURL: URL? = nil) throws {
        HTTPStubProtocol.install(replies)
        self.catalog = try catalog ?? HTTPFixtures.catalog()
        self.keys = keys ?? HTTPKeys(value: key)
        log = HTTPLog()
        sleeps = HTTPSleeps(cancel: cancelSleep)
        session = URLSession(configuration: HTTPStubProtocol.configuration())
        let clock = sleeps
        connector = try HTTPConnector(id: id, keys: self.keys, catalog: self.catalog, log: log, baseURL: baseURL, session: session, appVersion: "9.8.7", cacheURL: cacheURL, sleep: { try clock.sleep($0) })
    }

    var model: String {
        catalog.connector(connector.id)[ai: "defaultModel"].aiString ?? (connector.id == .ollama ? "gemma4:12b" : "local-chat")
    }

    func runner() -> LLMRunner { LLMRunner(keys: keys, catalog: catalog, log: log) }

    func finish() {
        #expect(HTTPStubProtocol.remaining == 0)
        session.invalidateAndCancel()
    }
}

enum HTTPFixtures {
    static let connectors: [ConnectorID] = [.anthropic, .openai, .xai, .gemini, .ollama, .lmstudio]
    static let completion = #"{"ok":true,"echo":"voxclip"}"#

    static func catalog() throws -> LLMCatalog {
        LLMCatalog(document: try JSONDecoder().decode(JSONValue.self, from: FixtureLoader.data("catalog/llm-providers.json")))
    }

    static func f1() throws -> LLMRequest {
        let prompt = try JSONDecoder().decode(JSONValue.self, from: FixtureLoader.data("prompts/clip-finder.json"))
        let preset = try #require(prompt[ai: "presets"].aiArray.first { $0[ai: "id"].aiString == "best" })
        let transcript = """
        [0-5] 0:00 So, today I want to talk.
        (pause 2.3s)
        [6-10] 0:03 Um why cut by words?
        [11-12] 0:05 "It works."
        [13-15] 0:07 Fast and clean
        (pause 61.5s)
        [16-16] 1:10 Tere!
        [17-18] 1:10 Mis toimub?
        [19-59] 1:11 「本当 です。」 w21 w22 w23 w24 w25 w26 w27 w28 w29 w30 w31 w32 w33 w34 w35 w36 w37 w38 w39 w40 w41 w42 w43 w44 w45 w46 w47 w48 w49 w50 w51 w52 w53 w54 w55 w56 w57 w58 w59
        [60-65] 1:23 w60 w61 w62 w63 w64 w65
        (pause 114.5s)
        [66-66] 3:20 end.
        """
        let prefix = try #require(prompt[ai: "transcriptBlock"][ai: "prefix"].aiString)
        let suffix = try #require(prompt[ai: "transcriptBlock"][ai: "suffix"].aiString)
        let duration = try #require(prompt[ai: "request"][ai: "durationLine"].aiString)
        let instruction = try #require(preset[ai: "instruction"].aiString)
        return LLMRequest(feature: .clipFinder, system: try #require(prompt[ai: "system"].aiString), cachedBlock: prefix + transcript + suffix, instruction: duration.replacingOccurrences(of: "{duration}", with: "3:20") + "\n" + instruction, schemaName: try #require(prompt[ai: "output"][ai: "name"].aiString), schema: prompt[ai: "output"][ai: "schema"], maxOutputTokens: try #require(prompt[ai: "generation"][ai: "maxOutputTokens"].aiInt), effort: .medium, timeout: .seconds(180), tag: "clips/best")
    }

    static func encode(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    }

    static func success(_ id: ConnectorID, text: String = completion, model: String? = nil) throws -> HTTPReply {
        var body: [String: Any]
        switch id {
        case .anthropic:
            body = ["stop_reason": "end_turn", "content": [["type": "text", "text": text]], "usage": ["input_tokens": 17, "output_tokens": 9, "cache_read_input_tokens": 5, "cache_creation_input_tokens": 3]]
        case .openai:
            body = ["status": "completed", "output": [["type": "message", "content": [["type": "output_text", "text": text]]]], "usage": ["input_tokens": 17, "output_tokens": 9, "input_tokens_details": ["cached_tokens": 5]]]
        case .xai, .lmstudio:
            body = ["choices": [["finish_reason": "stop", "message": ["content": text]]], "usage": ["prompt_tokens": 17, "completion_tokens": 9, "prompt_tokens_details": ["cached_tokens": 5]]]
        case .gemini:
            body = ["candidates": [["finishReason": "STOP", "content": ["parts": [["text": text]]]]], "usageMetadata": ["promptTokenCount": 17, "candidatesTokenCount": 9, "cachedContentTokenCount": 5]]
        case .ollama:
            body = ["done_reason": "stop", "message": ["content": text], "prompt_eval_count": 17, "eval_count": 9]
        default:
            throw LLMError.noConnector
        }
        if let model { body["model"] = model }
        return .json(try encode(body), headers: ["request-id": "anthropic-request", "x-request-id": "http-request"])
    }

    static func localDetails(_ id: ConnectorID, context: Int = 32768, thinking: Bool = true) throws -> [HTTPReply] {
        switch id {
        case .ollama:
            return [.json(try encode(["model_info": ["gemma4.context_length": context], "capabilities": thinking ? ["completion", "thinking"] : ["completion"]]))]
        case .lmstudio:
            return [.json(try encode(["state": "loaded", "loaded_context_length": context, "max_context_length": 65536]))]
        default: return []
        }
    }

    static func error(_ id: ConnectorID, _ reply: HTTPReply, expected: LLMError) async throws {
        let harness = try HTTPHarness(id, replies: localDetails(id) + [reply])
        defer { harness.finish() }
        let request = try harness.catalog.connectionTest(for: id)
        await #expect(throws: expected) { try await harness.connector.send(request, model: harness.model) }
        #expect(harness.sleeps.durations.isEmpty)
        #expect(HTTPStubProtocol.requests.count == (id == .ollama || id == .lmstudio ? 2 : 1))
    }

    static func golden(_ id: ConnectorID, request: LLMRequest, model: String, context: Int = 32768, thinking: Bool = true) throws -> JSONValue {
        let schema = try JSONSerialization.jsonObject(with: request.schema.aiEncoded())
        let block = request.cachedBlock
        let user = block.map { $0 + "\n\n" + request.instruction } ?? request.instruction
        let messages: [[String: Any]] = [["role": "system", "content": request.system], ["role": "user", "content": user]]
        let format: [String: Any] = ["type": "json_schema", "json_schema": ["name": request.schemaName, "strict": true, "schema": schema]]
        var body: [String: Any]
        switch id {
        case .anthropic:
            var content: [[String: Any]] = block.map { [["type": "text", "text": $0, "cache_control": ["type": "ephemeral"]]] } ?? []
            content.append(["type": "text", "text": request.instruction])
            body = ["model": model, "max_tokens": request.maxOutputTokens, "system": request.system, "messages": [["role": "user", "content": content]], "output_config": ["effort": request.effort!.rawValue, "format": ["type": "json_schema", "schema": schema]], "fallbacks": "default"]
        case .openai:
            var content: [[String: Any]] = block.map { [["type": "input_text", "text": $0]] } ?? []
            content.append(["type": "input_text", "text": request.instruction])
            body = ["model": model, "instructions": request.system, "input": [["role": "user", "content": content]], "text": ["format": ["type": "json_schema", "name": request.schemaName, "strict": true, "schema": schema]], "max_output_tokens": request.maxOutputTokens, "reasoning": ["effort": request.effort!.rawValue], "store": false]
            if let block {
                let digest = SHA256.hash(data: Data(block.utf8)).map { String(format: "%02x", $0) }.joined()
                body["prompt_cache_key"] = "voxclip-" + digest.prefix(16)
            }
        case .xai:
            body = ["model": model, "max_completion_tokens": request.maxOutputTokens, "messages": messages, "response_format": format]
        case .gemini:
            var parts: [[String: Any]] = block.map { [["text": $0]] } ?? []
            parts.append(["text": request.instruction])
            body = ["systemInstruction": ["parts": [["text": request.system]]], "contents": [["role": "user", "parts": parts]], "generationConfig": ["maxOutputTokens": request.maxOutputTokens, "responseMimeType": "application/json", "responseJsonSchema": schema]]
            if let effort = request.effort {
                var generation = body["generationConfig"] as! [String: Any]
                generation["thinkingConfig"] = ["thinkingLevel": effort.rawValue.uppercased()]
                body["generationConfig"] = generation
            }
        case .ollama:
            let schemaText = String(decoding: try JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
            let estimated = [request.system, block ?? "", request.instruction, schemaText].reduce(0) { $0 + Int(ceil(Double($1.utf8.count) / 2.2)) }
            let maximum = min(request.maxOutputTokens, 4096)
            let needed = estimated + maximum + 256
            let rounded = Int(ceil(Double(needed) / 1024)) * 1024
            body = ["model": model, "stream": false, "messages": messages, "format": schema, "options": ["num_ctx": min(context, max(8192, rounded)), "num_predict": maximum, "temperature": 0], "keep_alive": "10m"]
            if thinking { body["think"] = false }
        case .lmstudio:
            body = ["model": model, "max_tokens": min(request.maxOutputTokens, 4096), "temperature": 0, "messages": messages, "response_format": format]
        default: throw LLMError.noConnector
        }
        return try JSONDecoder().decode(JSONValue.self, from: Data(encode(body).utf8))
    }
}
