import Foundation

public actor HTTPConnector: LLMConnector {
    public nonisolated let id: ConnectorID
    let catalog: LLMCatalog
    let keys: any KeyProvider
    let log: any Redacting
    let session: URLSession
    let baseURL: URL
    let keyDestination: LLMKeyDestination?
    let appVersion: String
    let sleep: @Sendable (Duration) async throws -> Void
    let cacheURL: URL?
    var cachedModels: [LLMModel]?
    var details: [String: JSONValue] = [:]
    var contexts: [String: Int] = [:]
    var betaAvailable = true
    var active = false
    public internal(set) var refreshWarning: String?
    public var selectedModel: String?
    public internal(set) var assumedContextModels: Set<String> = []

    public init(id: ConnectorID, keys: any KeyProvider, catalog: LLMCatalog, log: any Redacting, baseURL: URL? = nil, session: URLSession? = nil, appVersion: String = AppVersion.current, cacheURL: URL? = nil, sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) throws {
        guard [.anthropic, .openai, .xai, .gemini, .ollama, .lmstudio].contains(id) else { throw LLMError.noConnector }
        self.id = id
        self.keys = keys
        self.catalog = catalog
        self.log = log
        self.appVersion = appVersion
        self.cacheURL = cacheURL
        self.sleep = sleep
        let keyDestination = LLMKeyDestination.pinned[id]
        self.keyDestination = keyDestination
        let allowsOverride = keyDestination == nil
        let configured = (allowsOverride ? baseURL : nil) ?? URL(string: catalog.connector(id)[ai: "baseUrl"].aiString ?? "")
        guard let configured, ["http", "https"].contains(configured.scheme?.lowercased() ?? ""), configured.host?.isEmpty == false, configured.user == nil, configured.password == nil, configured.query == nil, configured.fragment == nil else {
            let label = catalog.connector(id)[ai: "label"].aiString ?? id.rawValue
            throw LLMError.unavailable(reason: "\(label)'s server address in Settings isn't valid.")
        }
        self.baseURL = configured
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForResource = id == .ollama || id == .lmstudio ? 630 : 210
            self.session = URLSession(configuration: configuration)
        }
    }

    public func status() async -> ConnectorStatus {
        do {
            try catalog.validateKeylessAuth(for: id)
            if keyDestination != nil {
                try validateKeyDestination(baseURL)
                return try await apiKey() == nil ? .needsKey : .ready
            }
            let path = id == .ollama ? "/api/version" : "/v1/models"
            _ = try await fetch(path: path, timeout: 3)
            let listed = try await refreshModels(timeout: 3)
            return listed.isEmpty ? .noModels : .ready
        } catch let failure as LLMError {
            switch failure {
            case .cancelled: return .unavailable(reason: "")
            case .missingKey, .unauthorized:
                if keyDestination != nil { return .needsKey }
                return .unavailable(reason: "VoxClip is missing its AI configuration. Reinstall VoxClip.")
            case .badRequest(let status, _) where id == .ollama || id == .lmstudio:
                return .unavailable(reason: "\(catalog.connector(id)[ai: "label"].aiString ?? id.rawValue) rejected the request (\(status)).")
            case .noModels: return .noModels
            case .notRunning(let url): return .notRunning(url: url)
            case .modelNotFound("") where id == .ollama || id == .lmstudio:
                return .unavailable(reason: "\(catalog.connector(id)[ai: "label"].aiString ?? id.rawValue)'s server address in Settings isn't valid.")
            default: return .unavailable(reason: failure.userMessage(label: catalog.connector(id)[ai: "label"].aiString ?? id.rawValue, includeEditsSaved: false) ?? "")
            }
        } catch is CancellationError { return .unavailable(reason: "") }
        catch {
            if id == .ollama || id == .lmstudio { return .notRunning(url: baseURL.absoluteString) }
            if keyDestination != nil { return .needsKey }
            return .unavailable(reason: "VoxClip is missing its AI configuration. Reinstall VoxClip.")
        }
    }

    public func contextTokens(model: String) async -> Int? {
        if let context = contexts[model] { return context }
        if id == .ollama {
            if let info = try? await fetch(path: "/api/show", body: .object(["model": .string(model)]), timeout: 15) {
                details[model] = info
                let context = info[ai: "model_info"].aiObject?.first { $0.key.hasSuffix(".context_length") }?.value.aiInt ?? 4096
                contexts[model] = context
                return context
            }
            return 4096
        }
        if id == .lmstudio {
            let escaped = escapedModel(model)
            do {
                let info = try await fetch(path: "/api/v0/models/\(escaped)", timeout: 15)
                let loaded = info[ai: "loaded_context_length"].aiInt.flatMap { $0 > 0 ? $0 : nil }
                if info[ai: "state"].aiString == "loaded",
                   let context = loaded ?? info[ai: "max_context_length"].aiInt, context > 0 {
                    contexts[model] = context
                    return context
                }
            } catch LLMError.modelNotFound {
            } catch { return nil }
            assumedContextModels.insert(model)
            contexts[model] = 4096
            return 4096
        }
        return cachedModels?.first { $0.id == model }?.contextTokens ?? catalog.curatedModels(for: id).first { $0.id == model }?.contextTokens
    }

    public func send(_ request: LLMRequest, model: String) async throws -> RawCompletion {
        try catalog.validateKeylessAuth(for: id)
        guard !active else { throw LLMError.unavailable(reason: "An AI request is already running.") }
        active = true
        defer { active = false }
        if id == .ollama || id == .lmstudio { _ = await contextTokens(model: model) }
        let retry = catalog.document[ai: "policy"][ai: "retry"]
        let attempts = request.feature == .voiceRewrite ? 1 : max(1, retry[ai: "attempts"].aiInt ?? 3)
        let backoffs = retry[ai: "backoffSeconds"].aiArray.compactMap(\.aiDouble)
        let statuses = retry[ai: "retryStatuses"].aiArray.compactMap(\.aiInt)
        let retryStatuses = retry[ai: "retryStatuses"] == .null ? [429, 500, 502, 503, 504, 529] : statuses
        let maxRetryAfter = retry[ai: "maxRetryAfterSeconds"].aiDouble ?? 30
        func backoff(_ attempt: Int) -> Double { backoffs.indices.contains(attempt) ? backoffs[attempt] : Double(attempt + 1) }
        var attempt = 0
        var betaRetried = false
        while attempt < attempts {
            try checkCancellation()
            let wire = try await makeRequest(request, model: model)
            let started = ContinuousClock.now
            do {
                let (data, response) = try await transport(wire)
                guard let http = response as? HTTPURLResponse else { throw LLMError.network }
                let value = CanonicalResponseParser.envelope(data) ?? .null
                if (200..<300).contains(http.statusCode) {
                    let raw = try parseResponse(value, requestedModel: model, response: http)
                    await record(request, model: raw.model, attempt: attempt + 1, status: http.statusCode, started: started, raw: raw)
                    return raw
                }
                await record(request, model: model, attempt: attempt + 1, status: http.statusCode, started: started)
                let errorText = value[ai: "error"][ai: "message"].aiString ?? value[ai: "error"].aiString ?? ""
                if request.feature != .voiceRewrite, id == .anthropic, http.statusCode == 400, wire.value(forHTTPHeaderField: "anthropic-beta") != nil, !betaRetried,
                   errorText.lowercased().contains("anthropic-beta"), errorText.lowercased().contains("unexpected") {
                    betaAvailable = false
                    betaRetried = true
                    continue
                }
                let failure = await mapError(value, status: http.statusCode, model: model)
                let hint = retryDelay(response: http, value: value)
                if case .quotaExceeded = failure { throw failure }
                if case .timeout = failure { throw failure }
                guard retryStatuses.contains(http.statusCode) else { throw failure }
                if let hint, hint > maxRetryAfter { throw LLMError.rateLimited(retryAfter: hint) }
                guard attempt + 1 < attempts else {
                    if case .rateLimited = failure { throw LLMError.rateLimited(retryAfter: hint) }
                    throw failure
                }
                try await wait(hint ?? backoff(attempt))
                attempt += 1
            } catch let failure as URLError {
                await record(request, model: model, attempt: attempt + 1, status: 0, started: started)
                if Task.isCancelled || failure.code == .cancelled { throw LLMError.cancelled }
                if failure.code == .timedOut { throw LLMError.timeout }
                if failure.code == .networkConnectionLost, attempt + 1 < attempts {
                    try await wait(backoff(attempt))
                    attempt += 1
                    continue
                }
                if id == .ollama || id == .lmstudio { throw LLMError.notRunning(url: baseURL.absoluteString) }
                throw LLMError.network
            } catch is CancellationError { throw LLMError.cancelled }
        }
        throw LLMError.network
    }

    func apiKey() async throws -> String? {
        try catalog.validateKeylessAuth(for: id)
        guard let keyDestination else { return nil }
        try validateKeyDestination(baseURL)
        let stored: String?
        do { stored = try await keys.key(for: keyDestination.account); try Task.checkCancellation() }
        catch is CancellationError { throw LLMError.cancelled }
        catch LLMError.cancelled { throw LLMError.cancelled }
        catch { throw LLMError.missingKey }
        guard let stored else { return nil }
        let key = AIText.trim(stored)
        guard !key.isEmpty else { return nil }
        await log.register(secret: key)
        return key
    }

    func authorizedRequest(url: URL, timeout: Double) async throws -> URLRequest {
        try catalog.validateKeylessAuth(for: id)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpShouldHandleCookies = false
        request.setValue("VoxClip/\(appVersion) (macOS)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        for (key, value) in catalog.connector(id)[ai: "headers"].aiObject ?? [:] { request.setValue(value.aiString, forHTTPHeaderField: key) }
        if let keyDestination {
            try validateKeyDestination(url)
            guard let key = try await apiKey() else { throw LLMError.missingKey }
            request.setValue(keyDestination.valueTemplate.replacingOccurrences(of: "{key}", with: key), forHTTPHeaderField: keyDestination.header)
        }
        return request
    }

    private func validateKeyDestination(_ url: URL) throws {
        guard let keyDestination, keyDestination.matches(catalog.connector(id)[ai: "auth"]),
              url.scheme?.lowercased() == "https", url.host?.lowercased() == keyDestination.host,
              url.user == nil, url.password == nil else {
            throw LLMError.unavailable(reason: "VoxClip is missing its AI configuration. Reinstall VoxClip.")
        }
    }

    func endpoint(_ path: String, query: [URLQueryItem] = []) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { throw LLMError.network }
        let prefix = components.percentEncodedPath.hasSuffix("/") ? String(components.percentEncodedPath.dropLast()) : components.percentEncodedPath
        components.percentEncodedPath = prefix + path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw LLMError.network }
        return url
    }

    func escapedModel(_ model: String) -> String {
        model.addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? ""
    }

    func fetch(path: String, query: [URLQueryItem] = [], body: JSONValue? = nil, timeout: Double = 15) async throws -> JSONValue {
        var request = try await authorizedRequest(url: endpoint(path, query: query), timeout: timeout)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.httpBody = try body?.aiEncoded()
        do {
            let (data, response) = try await transport(request)
            guard let http = response as? HTTPURLResponse else { throw LLMError.network }
            let value = CanonicalResponseParser.envelope(data) ?? .null
            guard (200..<300).contains(http.statusCode) else { throw await mapError(value, status: http.statusCode, model: "") }
            guard value != .null else { throw LLMError.invalidOutput(reason: "not JSON") }
            return value
        } catch let failure as URLError {
            if Task.isCancelled || failure.code == .cancelled { throw LLMError.cancelled }
            if failure.code == .timedOut { throw LLMError.timeout }
            if id == .ollama || id == .lmstudio { throw LLMError.notRunning(url: baseURL.absoluteString) }
            throw LLMError.network
        } catch is CancellationError { throw LLMError.cancelled }
    }

    func wait(_ seconds: Double) async throws {
        do { try await sleep(.seconds(seconds)); try checkCancellation() }
        catch is CancellationError { throw LLMError.cancelled }
    }

    private func transport(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let session = session
        return try await withThrowingTaskGroup(of: (Data, URLResponse).self) { group in
            group.addTask { try await session.data(for: request, delegate: AINoRedirect()) }
            group.addTask {
                try await Task.sleep(for: .seconds(max(0, request.timeoutInterval) + 30))
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw URLError(.cancelled) }
            try Task.checkCancellation()
            return result
        }
    }

    func checkCancellation() throws { if Task.isCancelled { throw LLMError.cancelled } }

    func record(_ request: LLMRequest, model: String, attempt: Int, status: Int, started: ContinuousClock.Instant, raw: RawCompletion? = nil) async {
        func safe(_ value: String) -> String { String(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(128)) }
        var message = "llm connector=\(id.rawValue) model=\(safe(model)) feature=\(request.feature.rawValue) tag=\"\(safe(request.tag))\" attempt=\(attempt) status=\(status) ms=\(Int(aiDurationSeconds(started.duration(to: .now)) * 1000))"
        if let usage = raw?.usage {
            if let input = usage.input { message += " in=\(input)" }
            if let output = usage.output { message += " out=\(output)" }
            if let cacheRead = usage.cacheRead { message += " cacheRead=\(cacheRead)" }
            if let cacheWrite = usage.cacheWrite { message += " cacheWrite=\(cacheWrite)" }
        }
        if let requestID = raw?.requestID { message += " requestId=\(safe(requestID))" }
        await log.write(LogEntry(level: .info, category: "llm", message: await log.redact(message)))
    }
}

private final class AINoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}
