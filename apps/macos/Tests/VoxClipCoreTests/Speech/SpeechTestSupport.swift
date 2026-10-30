import Foundation
import Synchronization
import VoxClipCore

struct SpeechTestKeys: KeyProvider {
    let value: String?
    func key(for provider: String) async throws -> String? { value }
}

struct SpeechTestCatalog: ModelCatalog {
    let entries: [ModelDescriptor]
    func models() async throws -> [ModelDescriptor] { entries }
    func model(id: String) async throws -> ModelDescriptor {
        guard let model = entries.first(where: { $0.id == id }) else { throw VoxClipError.modelMissing(id) }
        return model
    }
}

enum SpeechTestFiles {
    static func catalog() throws -> BundledModelCatalog {
        BundledModelCatalog(shared: SharedResources(root: try FixtureLoader.sharedRoot()))
    }
    static func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-speech-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static func locations(_ root: URL) -> DataLocations { DataLocations(environment: ["VOXCLIP_DATA_DIR": root.path]) }
    static func request(_ root: URL, language: LanguageChoice = .forced("et"), options: TranscriptionOptions = TranscriptionOptions()) throws -> TranscriptionRequest {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let wav = root.appendingPathComponent("audio-16k.wav")
        try Data("synthetic audio bytes".utf8).write(to: wav)
        return TranscriptionRequest(plan: TranscriptionPlan(engine: .elevenlabs, language: language, options: options), audio: ExtractedAudio(wav16k: wav, sampleCount: 64000, durationSeconds: 4), contentKey: "synthetic-content")
    }
    static func model(_ source: URL, data: Data, hash: String? = nil, id: String = "test-model", requires: [String] = []) -> ModelDescriptor {
        let file = ModelFile(role: "model", name: "model.bin", url: source, bytes: Int64(data.count), sha256: hash ?? SpeechSHA256.hex(data))
        return ModelDescriptor(id: id, displayName: "Test model", engine: .whispercpp, files: [file], totalBytes: file.bytes, languages: ["en"], requires: requires, license: "MIT", attribution: "Synthetic test fixture", sourcePage: source, publisher: "VoxClip tests")
    }
}

enum SpeechTestWait {
    /// Polls a condition without a deadline; the suite time limit ends a test that never gets there.
    static func until(_ condition: () async -> Bool) async throws {
        while await !condition() { try await Task.sleep(for: .milliseconds(1)) }
    }
    /// Awaits an unstructured task and cancels it if the test is cancelled, so the time limit also
    /// ends a job stuck in a queue instead of leaving the run waiting on it.
    static func value<T: Sendable>(_ task: Task<T, any Error>) async throws -> T {
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}

actor SpeechTestLogger: Redacting {
    private var redactor = Redactor()
    private(set) var entries: [LogEntry] = []
    func register(secret: String) { redactor.register(secret: secret) }
    func redact(_ message: String) -> String { redactor.redact(message) }
    func write(_ entry: LogEntry) {
        entries.append(LogEntry(level: entry.level, category: entry.category, message: redactor.redact(entry.message)))
    }
}

final class SpeechStubHTTP: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (Int, [String: String], Data)
    private struct LoadingThread: @unchecked Sendable {
        let thread = Thread.current
        func fail(_ stub: SpeechStubHTTP, code: URLError.Code) {
            stub.perform(#selector(SpeechStubHTTP.fail(_:)), on: thread, with: URLError(code) as NSError, waitUntilDone: false)
        }
    }
    final class WriteAcknowledgement: Sendable {
        private struct State {
            var written = false
            var action: (@Sendable () -> Void)?
        }
        private let state = Mutex(State())

        func onWrite(_ action: @escaping @Sendable () -> Void) {
            let written = state.withLock { state in
                if state.written { return true }
                state.action = action
                return false
            }
            if written { action() }
        }

        func acknowledge() {
            let action = state.withLock { state -> (@Sendable () -> Void)? in
                state.written = true
                defer { state.action = nil }
                return state.action
            }
            action?()
        }
    }
    struct Reply: Sendable {
        let status: Int
        let headers: [String: String]
        let body: Data
        var failure: URLError.Code? = nil
        var failureAfterWrite: WriteAcknowledgement? = nil
        /// Leaves the reply open after `body`, as a server that stops sending does, without blocking the loading thread
        /// that every stubbed session shares. The task then ends only when it is cancelled.
        var stalls = false
    }
    private let stopped = Mutex(false)
    static let handlers = Mutex<[String: @Sendable (URLRequest) throws -> Reply]>([:])
    static func register(_ handler: @escaping Handler) -> URL {
        registerStream { request in
            let (status, headers, body) = try handler(request)
            return Reply(status: status, headers: headers, body: body)
        }
    }
    static func registerStream(_ handler: @escaping @Sendable (URLRequest) throws -> Reply) -> URL {
        let host = "stub-\(UUID().uuidString.lowercased()).invalid"
        handlers.withLock { $0[host] = handler }
        return URL(string: "https://\(host)")!
    }
    static func configuration(for handler: URL? = nil) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SpeechStubHTTP.self]
        if let host = handler?.host { configuration.httpAdditionalHeaders = ["X-VoxClip-Test-Handler": host] }
        return configuration
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let host = request.value(forHTTPHeaderField: "X-VoxClip-Test-Handler") ?? request.url?.host,
                  let handler = Self.handlers.withLock({ $0[host] }) else {
                var details: [String: Any] = [NSLocalizedDescriptionKey: "No SpeechStubHTTP handler for \(request.httpMethod ?? "GET") \(request.url?.absoluteString ?? "")."]
                if let url = request.url { details[NSURLErrorFailingURLErrorKey] = url }
                throw URLError(.badURL, userInfo: details)
            }
            let reply = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.body)
            if reply.stalls { return }
            if let failure = reply.failure {
                if let acknowledgement = reply.failureAfterWrite {
                    let loadingThread = LoadingThread()
                    acknowledgement.onWrite { [weak self] in
                        if let self { loadingThread.fail(self, code: failure) }
                    }
                } else {
                    fail(URLError(failure) as NSError)
                }
                return
            }
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    @objc private func fail(_ error: NSError) {
        guard !stopped.withLock({ $0 }) else { return }
        client?.urlProtocol(self, didFailWithError: error)
    }
    override func stopLoading() { stopped.withLock { $0 = true } }
}
