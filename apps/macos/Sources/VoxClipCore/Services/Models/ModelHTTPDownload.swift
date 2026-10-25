import Foundation
import Synchronization

struct SpeechHTTPFailure: Error {
    let status: Int
    let retryAfter: Double?
    var retryable: Bool { status == 429 || status >= 500 }
    static func delay(_ value: String?) -> Double? {
        guard let value else { return nil }
        if let seconds = Double(value) { return min(30, max(0, seconds)) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value).map { min(30, max(0, $0.timeIntervalSinceNow)) }
    }
}

final class ModelHTTPDownload: NSObject, URLSessionDataDelegate {
    struct State {
        var handle: FileHandle?
        var hash = SpeechSHA256()
        var received: Int64 = 0
        var failure: (any Error)?
        var continuation: CheckedContinuation<Void, any Error>?
        var task: URLSessionDataTask?
        var cancelled = false
    }
    let state = Mutex(State())
    let cancelled = Mutex(false)
    let file: ModelFile
    let partial: URL
    let progress: @Sendable (Int64) -> Void
    init(file: ModelFile, partial: URL, progress: @escaping @Sendable (Int64) -> Void) { self.file = file; self.partial = partial; self.progress = progress }

    static func run(file: ModelFile, partial: URL, configuration: URLSessionConfiguration, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let delegate = ModelHTTPDownload(file: file, partial: partial, progress: progress)
        let config = configuration.copy() as! URLSessionConfiguration
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 10_800
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: queue)
        defer { session.invalidateAndCancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.state.withLock { state in
                    state.continuation = continuation
                    var request = URLRequest(url: file.url)
                    let offset = (try? FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? NSNumber)?.int64Value ?? 0
                    if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
                    request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                    state.task = session.dataTask(with: request)
                    if state.cancelled { state.task?.cancel() }
                    state.task?.resume()
                }
            }
        } onCancel: {
            delegate.cancelled.withLock { $0 = true }
            delegate.state.withLock { state in state.cancelled = true; state.task?.cancel() }
        }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        var allow = false
        state.withLock { state in
            do {
                guard let http = response as? HTTPURLResponse else { throw VoxClipError.providerError("Invalid model response") }
                guard http.statusCode == 200 || http.statusCode == 206 else { throw SpeechHTTPFailure(status: http.statusCode, retryAfter: SpeechHTTPFailure.delay(http.value(forHTTPHeaderField: "Retry-After"))) }
                if !FileManager.default.fileExists(atPath: partial.path) { FileManager.default.createFile(atPath: partial.path, contents: nil) }
                let handle = try FileHandle(forUpdating: partial)
                state.handle = handle
                if http.statusCode == 200 { try handle.truncate(atOffset: 0) }
                let offset = try handle.seekToEnd()
                if http.statusCode == 206 {
                    let range = http.value(forHTTPHeaderField: "Content-Range")?.replacingOccurrences(of: "bytes ", with: "").split(separator: "/") ?? []
                    let bounds = range.first?.split(separator: "-") ?? []
                    guard range.count == 2, bounds.count == 2,
                          Int64(bounds[0]) == Int64(offset), let last = Int64(bounds[1]),
                          last >= Int64(offset), last < file.bytes,
                          Int64(range[1]) == file.bytes else { throw VoxClipError.providerError("Invalid model resume range") }
                }
                try handle.seek(toOffset: 0)
                while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
                    if cancelled.withLock({ $0 }) { throw VoxClipError.cancelled }
                    state.hash.update(chunk)
                }
                try handle.seekToEnd()
                state.received = Int64(offset)
                allow = true
            } catch { state.failure = error }
        }
        completionHandler(allow ? .allow : .cancel)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let received = state.withLock { state -> Int64? in
            guard state.failure == nil else { return nil }
            do {
                guard state.received + Int64(data.count) <= file.bytes else { throw VoxClipError.modelChecksumMismatch(file.name) }
                try state.handle?.write(contentsOf: data)
                state.hash.update(data)
                state.received += Int64(data.count)
                return state.received
            } catch { state.failure = error; dataTask.cancel(); return nil }
        }
        if let received { progress(received) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        state.withLock { state in
            try? state.handle?.close()
            var failure = state.failure ?? error
            if failure == nil && (state.received != file.bytes || state.hash.hexDigest() != file.sha256) {
                failure = VoxClipError.modelChecksumMismatch(file.name)
            }
            if (failure as? VoxClipError)?.code == .modelChecksumMismatch {
                try? FileManager.default.removeItem(at: partial)
            }
            if let failure { state.continuation?.resume(throwing: failure) } else { state.continuation?.resume() }
            state.continuation = nil; state.task = nil; state.handle = nil
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(request.url?.scheme == "https" ? request : nil)
    }
}
