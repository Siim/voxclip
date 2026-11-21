import Darwin
import Foundation
import Synchronization

package struct LipsyncHTTPResponse: Sendable {
    package let status: Int
    package let body: Data
    package let contentType: String?
    /// A 429 or 503's `Retry-After` in seconds (delta-seconds only; an HTTP date is ignored), at most 10 minutes.
    package let retryAfter: Double?
    package init(status: Int, body: Data, contentType: String? = "application/json", retryAfter: Double? = nil) {
        self.status = status; self.body = body; self.contentType = Self.mediaType(contentType)
        self.retryAfter = retryAfter.flatMap { $0.isFinite && $0 >= 0 ? min($0, 600) : nil }
    }

    static func retryAfter(_ header: String?) -> Double? {
        header.flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    }

    static func mediaType(_ header: String?) -> String? {
        header?.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first?
            .trimmingCharacters(in: .whitespaces).lowercased()
    }

    static func isJSON(_ mediaType: String?) -> Bool {
        guard let mediaType else { return false }
        return mediaType == "application/json" || (mediaType.hasPrefix("application/") && mediaType.hasSuffix("+json"))
    }
}

package protocol LipsyncHTTPClient: Sendable {
    func send(_ request: URLRequest, limit: Int, permit: VoiceDispatchPermit?) async throws -> LipsyncHTTPResponse
    func download(_ request: URLRequest, to file: URL, limit: Int) async throws
}

struct URLSessionLipsyncHTTPClient: LipsyncHTTPClient {
    var configure: @Sendable (URLSessionConfiguration) -> Void = { _ in }
    func send(_ request: URLRequest, limit: Int, permit: VoiceDispatchPermit?) async throws -> LipsyncHTTPResponse {
        var request = request
        // URLSession would otherwise offer its own list, br included, which the transfer refuses (it reads gzip and deflate).
        if request.value(forHTTPHeaderField: "Accept-Encoding") == nil { request.setValue("gzip, deflate", forHTTPHeaderField: "Accept-Encoding") }
        return try await LipsyncHTTPTransfer(limit: limit, upload: request.httpMethod == "PUT" && request.httpBody != nil,
                                             configure: configure).run(request, permit: permit)
    }

    /// The idle and whole-transfer timeouts. JSON: at most 30 s each (or the request's own, shorter, deadline). An upload or
    /// a media download waits up to 120 s or 30 s between bytes, and gets `LipsyncLimits.transferSeconds` of its bytes (the
    /// upload's body, a download's limit) in all: 60 s plus 2 Mbit/s, so a long window's upload or result is never cut off
    /// at a fixed two minutes.
    static func timeouts(upload: Bool, download: Bool, bytes: Int, requested: TimeInterval) -> (request: TimeInterval, resource: TimeInterval) {
        if upload { return (120, LipsyncLimits.transferSeconds(bytes)) }
        if download { return (min(30, requested), LipsyncLimits.transferSeconds(bytes)) }
        return (min(30, requested), min(30, requested))
    }

    func download(_ request: URLRequest, to file: URL, limit: Int) async throws {
        let staged = try LipsyncStagedFile(destination: file)
        defer { staged.discard() }
        var request = request
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        _ = try await LipsyncHTTPTransfer(limit: limit, descriptor: staged.descriptor, configure: configure).run(request, permit: nil)
        try Task.checkCancellation()
        var header = [UInt8](repeating: 0, count: 12)
        let headerCount = header.count
        guard pread(staged.descriptor, &header, headerCount, 0) == headerCount,
              Array(header[4..<8]) == Array("ftyp".utf8) else { throw LipsyncError.invalidMedia }
        try staged.commit()
    }
}

package final class LipsyncStagedFile: Sendable {
    package let descriptor: Int32
    package let temporaryURL: URL
    private let directory: Int32
    private let temporaryName: String
    private let finalName: String

    package init(destination: URL) throws {
        guard destination.isFileURL, destination.query == nil, destination.fragment == nil,
              !destination.path.contains("\0"), destination.pathExtension.lowercased() == "mp4",
              destination.lastPathComponent != ".", destination.lastPathComponent != ".." else { throw LipsyncError.unsafeFile }
        let directory = try LipsyncLocalPath.openDirectory(destination.deletingLastPathComponent())
        let temporaryName = ".lipsync-\(UUID().uuidString).partial.mp4"
        let descriptor = openat(directory, temporaryName, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { Darwin.close(directory); throw LipsyncError.unsafeFile }
        self.directory = directory; self.descriptor = descriptor; self.temporaryName = temporaryName
        self.finalName = destination.lastPathComponent
        self.temporaryURL = destination.deletingLastPathComponent().appendingPathComponent(temporaryName)
    }

    package func commit() throws {
        try Task.checkCancellation()
        var held = stat(), named = stat()
        guard fstat(descriptor, &held) == 0, fstatat(directory, temporaryName, &named, AT_SYMLINK_NOFOLLOW) == 0,
              held.st_mode & S_IFMT == S_IFREG, held.st_nlink == 1, named.st_mode & S_IFMT == S_IFREG,
              held.st_dev == named.st_dev, held.st_ino == named.st_ino, fsync(descriptor) == 0,
              linkat(directory, temporaryName, directory, finalName, 0) == 0 else { throw LipsyncError.unsafeFile }
        guard fsync(directory) == 0 else {
            unlinkat(directory, finalName, 0)
            throw LipsyncError.unsafeFile
        }
        unlinkat(directory, temporaryName, 0)
    }

    package func discard() { _ = unlinkat(directory, temporaryName, 0) }
    deinit { discard(); Darwin.close(descriptor); Darwin.close(directory) }
}

package enum LipsyncLocalPath {
    package static func openDirectory(_ url: URL) throws -> Int32 {
        do { return try LocalDirectory.openNoFollow(url) }
        catch { throw LipsyncError.unsafeFile }
    }
}

private final class LipsyncHTTPTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private struct State {
        var task: URLSessionDataTask?
        var continuation: CheckedContinuation<LipsyncHTTPResponse, any Error>?
        var response: HTTPURLResponse?
        var bytes = Data()
        var count = 0
        var cancelled = false
        var failure: LipsyncError?
    }
    private let state = Mutex(State())
    private let limit: Int
    private let descriptor: Int32?
    private let upload: Bool
    private let configure: @Sendable (URLSessionConfiguration) -> Void
    init(limit: Int, descriptor: Int32? = nil, upload: Bool = false, configure: @escaping @Sendable (URLSessionConfiguration) -> Void) {
        self.limit = limit; self.descriptor = descriptor; self.upload = upload; self.configure = configure
    }

    func run(_ request: URLRequest, permit: VoiceDispatchPermit?) async throws -> LipsyncHTTPResponse {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCache = nil; configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false; configuration.connectionProxyDictionary = [:]
        let timeouts = URLSessionLipsyncHTTPClient.timeouts(upload: upload, download: descriptor != nil,
                                     bytes: upload ? request.httpBody?.count ?? 0 : limit, requested: request.timeoutInterval)
        configuration.timeoutIntervalForRequest = timeouts.request
        configuration.timeoutIntervalForResource = timeouts.resource
        var request = request
        request.timeoutInterval = timeouts.request
        configure(configuration)
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request)
                let cancelled = state.withLock { state in
                    state.task = task; state.continuation = continuation
                    return state.cancelled
                }
                if cancelled { task.cancel(); task.resume(); return }
                do {
                    if let permit { try permit.start { task.resume() } } else { task.resume() }
                } catch {
                    state.withLock { $0.continuation = nil }
                    task.cancel()
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            let task = self.state.withLock { state in state.cancelled = true; return state.task }
            task?.cancel()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        let failure: LipsyncError?
        if let response = response as? HTTPURLResponse {
            let mime = LipsyncHTTPResponse.mediaType(response.value(forHTTPHeaderField: "Content-Type"))
            let encoding = contentEncoding(response)
            let declaredLength = response.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init)
            if response.expectedContentLength > Int64(limit) || (declaredLength ?? 0) > Int64(limit) { failure = .responseTooLarge }
            else if encoding != "identity" && (descriptor != nil || !["gzip", "deflate"].contains(encoding)) { failure = .invalidResponse }
            else if descriptor != nil && (response.statusCode != 200 || mime != "video/mp4") { failure = .invalidMedia }
            else if descriptor == nil && (200...299).contains(response.statusCode) && !upload &&
                !LipsyncHTTPResponse.isJSON(mime) { failure = .invalidResponse }
            else { failure = nil }
            // An earlier failure stands: a refused redirect's 3xx arrives here next and must stay unsafeURL.
            let kept = state.withLock { state -> LipsyncError? in
                state.response = response; state.failure = state.failure ?? failure
                return state.failure
            }
            completionHandler(kept == nil ? .allow : .cancel)
        } else {
            state.withLock { $0.failure = $0.failure ?? .invalidResponse }
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let failed = state.withLock { state in
            guard state.failure == nil, !state.cancelled else { return true }
            guard data.count <= limit - state.count else { state.failure = .responseTooLarge; return true }
            state.count += data.count
            if let descriptor {
                let success = data.withUnsafeBytes { buffer -> Bool in
                    var offset = 0
                    while offset < buffer.count {
                        let written = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                        if written < 0 && errno == EINTR { continue }
                        guard written > 0 else { return false }
                        offset += written
                    }
                    return true
                }
                if !success { state.failure = .unsafeFile; return true }
            } else { state.bytes.append(data) }
            return false
        }
        if failed { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let value = state.withLock { state -> (CheckedContinuation<LipsyncHTTPResponse, any Error>?, Result<LipsyncHTTPResponse, any Error>) in
            defer { state.continuation = nil }
            if state.cancelled { return (state.continuation, .failure(CancellationError())) }
            if let failure = state.failure { return (state.continuation, .failure(failure)) }
            guard error == nil, let response = state.response else { return (state.continuation, .failure(LipsyncError.network)) }
            if contentEncoding(response) == "identity", response.expectedContentLength >= 0,
               response.expectedContentLength != Int64(state.count) {
                return (state.continuation, .failure(LipsyncError.invalidResponse))
            }
            return (state.continuation, .success(LipsyncHTTPResponse(status: response.statusCode, body: state.bytes,
                contentType: response.value(forHTTPHeaderField: "Content-Type"),
                retryAfter: LipsyncHTTPResponse.retryAfter(response.value(forHTTPHeaderField: "Retry-After")))))
        }
        value.0?.resume(with: value.1)
    }

    private func contentEncoding(_ response: HTTPURLResponse) -> String {
        response.value(forHTTPHeaderField: "Content-Encoding")?.trimmingCharacters(in: .whitespaces).lowercased() ?? "identity"
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        state.withLock { $0.failure = .unsafeURL }
        completionHandler(nil)
    }
}
