import Foundation
import VoxClipCore

final class VoiceLabHTTPStream: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Event: Sendable { case response(HTTPURLResponse), data(Data) }
    let stream: AsyncThrowingStream<Event, any Error>
    private let continuation: AsyncThrowingStream<Event, any Error>.Continuation
    private let limit: Int
    private var count = 0
    init(limit: Int) {
        let pair = AsyncThrowingStream<Event, any Error>.makeStream()
        stream = pair.stream; continuation = pair.continuation; self.limit = limit
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse else {
            continuation.finish(throwing: VoiceLabError.malformedResponse); completionHandler(.cancel); return
        }
        continuation.yield(.response(response)); completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        count += data.count
        guard count <= limit else {
            continuation.finish(throwing: VoiceLabError.responseTooLarge); dataTask.cancel(); return
        }
        continuation.yield(.data(data))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error { continuation.finish(throwing: error) } else { continuation.finish() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
