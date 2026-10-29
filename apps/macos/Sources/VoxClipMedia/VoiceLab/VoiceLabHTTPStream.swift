import Foundation
import Synchronization
import VoxClipCore

final class VoiceLabHTTPStream: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Event: Sendable { case response(HTTPURLResponse), data(Data) }
    let stream: AsyncThrowingStream<Event, any Error>
    private let continuation: AsyncThrowingStream<Event, any Error>.Continuation
    private let limit: Int
    private struct State {
        var response: HTTPURLResponse?
        var count = 0
        var complete = false
    }
    private let state = Mutex(State())
    var receivedResponse: HTTPURLResponse? { state.withLock { $0.response } }
    func completed(bytes: Int) -> Bool { state.withLock { $0.complete && $0.count == bytes } }
    init(limit: Int) {
        let pair = AsyncThrowingStream<Event, any Error>.makeStream()
        stream = pair.stream; continuation = pair.continuation; self.limit = limit
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse else {
            continuation.finish(throwing: VoiceLabError.malformedResponse); completionHandler(.cancel); return
        }
        state.withLock { $0.response = response }
        continuation.yield(.response(response)); completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let count = state.withLock { $0.count += data.count; return $0.count }
        guard count <= limit else {
            continuation.finish(throwing: VoiceLabError.responseTooLarge); dataTask.cancel(); return
        }
        continuation.yield(.data(data))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        state.withLock { $0.complete = error == nil }
        if let error { continuation.finish(throwing: error) } else { continuation.finish() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
