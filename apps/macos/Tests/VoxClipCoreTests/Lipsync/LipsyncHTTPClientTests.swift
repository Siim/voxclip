#if DEBUG
import Foundation
import Synchronization
import Testing
@testable import VoxClipCore

private final class LipsyncHTTPFixtureProtocol: URLProtocol {
    /// The single response task serializes client delivery; cross-thread stop state is locked.
    private struct Reference: @unchecked Sendable { let value: LipsyncHTTPFixtureProtocol }
    struct Reply: Sendable {
        var status = 200
        var headers: [String: String] = ["Content-Type": "video/mp4"]
        var chunks: [Data]
        var barrier: LipsyncFixtureBarrier?
        var redirect: URL?
    }
    static let replies = Mutex<[String: Reply]>([:])
    private struct WorkerState {
        var task: Task<Void, Never>?
        var stopped = false
    }
    private let worker = Mutex(WorkerState())
    static func register(_ reply: Reply) -> URL {
        let url = URL(string: "https://fixture.invalid/\(UUID().uuidString)/result.mp4")!
        replies.withLock { $0[url.absoluteString] = reply }
        return url
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let reply = Self.replies.withLock({ $0.removeValue(forKey: url.absoluteString) }),
              let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers) else {
            client?.urlProtocol(self, didFailWithError: LipsyncError.network); return
        }
        let task = Task.detached { [reference = Reference(value: self), reply, response] in
            let owner = reference.value
            guard !owner.worker.withLock({ $0.stopped }), !Task.isCancelled else { return }
            if let redirect = reply.redirect {
                owner.client?.urlProtocol(owner, wasRedirectedTo: URLRequest(url: redirect), redirectResponse: response)
                if !owner.worker.withLock({ $0.stopped }), !Task.isCancelled {
                    owner.client?.urlProtocolDidFinishLoading(owner)
                }
                return
            }
            owner.client?.urlProtocol(owner, didReceive: response, cacheStoragePolicy: .notAllowed)
            for chunk in reply.chunks {
                guard !owner.worker.withLock({ $0.stopped }), !Task.isCancelled else { return }
                owner.client?.urlProtocol(owner, didLoad: chunk)
            }
            if let barrier = reply.barrier { await barrier.block() }
            if !owner.worker.withLock({ $0.stopped }), !Task.isCancelled {
                owner.client?.urlProtocolDidFinishLoading(owner)
            }
        }
        worker.withLock { state in
            if state.stopped { task.cancel() } else { state.task = task }
        }
    }
    override func stopLoading() {
        worker.withLock { state in
            state.stopped = true
            state.task?.cancel()
            state.task = nil
        }
    }
}

@Suite("Lip-sync bounded streaming HTTP", .timeLimit(.minutes(1)))
struct LipsyncHTTPClientTests {
    private var http: URLSessionLipsyncHTTPClient {
        URLSessionLipsyncHTTPClient(configure: { $0.protocolClasses = [LipsyncHTTPFixtureProtocol.self] })
    }
    private var header: Data { Data([0, 0, 0, 16]) + Data("ftypisom".utf8) + Data([0, 0, 0, 0]) }

    @Test func validDownloadStreamsToPrivateAtomicDestination() async throws {
        let root = try LipsyncProviderFixtures.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let bytes = header + Data(repeating: 0, count: 64)
        let url = LipsyncHTTPFixtureProtocol.register(.init(chunks: [bytes.prefix(7), bytes.dropFirst(7)]))
        let destination = root.appendingPathComponent("result.mp4")
        try await http.download(URLRequest(url: url), to: destination, limit: 1_024)
        #expect(try Data(contentsOf: destination) == bytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["result.mp4"])
    }

    @Test(arguments: [true, false]) func claimedAndStreamedSizeLimitsRemovePartialFiles(declared: Bool) async throws {
        let root = try LipsyncProviderFixtures.directory(); defer { try? FileManager.default.removeItem(at: root) }
        var headers = ["Content-Type": "video/mp4"]
        if declared { headers["Content-Length"] = "4096" }
        let url = LipsyncHTTPFixtureProtocol.register(.init(headers: headers, chunks: [header, Data(repeating: 0, count: 128)]))
        await #expect(throws: LipsyncError.responseTooLarge) {
            try await http.download(URLRequest(url: url), to: root.appendingPathComponent("result.mp4"), limit: 32)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test(arguments: ["text/html", "application/octet-stream", "image/png"])
    func wrongMimeNeverPublishesAnMP4(mime: String) async throws {
        let root = try LipsyncProviderFixtures.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = LipsyncHTTPFixtureProtocol.register(.init(headers: ["Content-Type": mime], chunks: [header]))
        await #expect(throws: LipsyncError.invalidMedia) {
            try await http.download(URLRequest(url: url), to: root.appendingPathComponent("result.mp4"), limit: 1_024)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func cancellationClosesStreamAndRemovesPrivateStaging() async throws {
        let root = try LipsyncProviderFixtures.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let barrier = LipsyncFixtureBarrier()
        let url = LipsyncHTTPFixtureProtocol.register(.init(chunks: [header], barrier: barrier))
        let destination = root.appendingPathComponent("result.mp4"), http = http
        let task = Task { try await http.download(URLRequest(url: url), to: destination, limit: 1_024) }
        defer { task.cancel(); Task { await barrier.release() } }
        try await barrier.waitUntilEntered()
        task.cancel()
        await barrier.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func nonMP4AndTruncatedContentAreNotPublished() async throws {
        let root = try LipsyncProviderFixtures.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = LipsyncHTTPFixtureProtocol.register(.init(chunks: [Data("not an mp4 at all".utf8)]))
        await #expect(throws: LipsyncError.invalidMedia) {
            try await http.download(URLRequest(url: url), to: root.appendingPathComponent("result.mp4"), limit: 1_024)
        }
        let truncated = LipsyncHTTPFixtureProtocol.register(.init(headers: ["Content-Type": "video/mp4", "Content-Length": "32"], chunks: [header]))
        await #expect(throws: LipsyncError.invalidResponse) {
            try await http.download(URLRequest(url: truncated), to: root.appendingPathComponent("result.mp4"), limit: 1_024)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func redirectIsRefusedBeforeAnyTargetRequest() async throws {
        let root = try LipsyncProviderFixtures.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let target = URL(string: "https://127.0.0.1/never-requested")!
        let url = LipsyncHTTPFixtureProtocol.register(.init(status: 302, headers: ["Content-Type": "video/mp4", "Location": target.absoluteString],
                                                           chunks: [], redirect: target))
        await #expect(throws: LipsyncError.unsafeURL) {
            try await http.download(URLRequest(url: url), to: root.appendingPathComponent("result.mp4"), limit: 1_024)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func JSONBodiesAreBoundedAndEncodedResponsesAreRejected() async throws {
        let oversized = LipsyncHTTPFixtureProtocol.register(.init(headers: ["Content-Type": "application/json"], chunks: [Data(repeating: 32, count: 128)]))
        await #expect(throws: LipsyncError.responseTooLarge) { _ = try await http.send(URLRequest(url: oversized), limit: 32, permit: nil) }
        let encoded = LipsyncHTTPFixtureProtocol.register(.init(headers: ["Content-Type": "application/json", "Content-Encoding": "gzip"], chunks: [Data("{}".utf8)]))
        await #expect(throws: LipsyncError.invalidResponse) { _ = try await http.send(URLRequest(url: encoded), limit: 1_024, permit: nil) }
    }
}
#endif
