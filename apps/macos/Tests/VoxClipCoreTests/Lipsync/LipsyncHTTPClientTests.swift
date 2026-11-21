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
        var observe: (@Sendable (URLRequest) -> Void)?
        /// After a refused redirect, deliver the 3xx itself as the response (as URLSession does over the network).
        var deliverRedirect = false
    }
    static let replies = Mutex<[String: [Reply]]>([:])
    private struct WorkerState {
        var task: Task<Void, Never>?
        var stopped = false
    }
    private let worker = Mutex(WorkerState())
    static func register(_ reply: Reply) -> URL {
        let url = URL(string: "https://fixture.invalid/\(UUID().uuidString)/result.mp4")!
        register([reply], for: url)
        return url
    }
    static func register(_ sequence: [Reply], for url: URL) {
        replies.withLock { $0[url.absoluteString] = sequence }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let reply = Self.replies.withLock({ replies -> Reply? in
            guard var remaining = replies.removeValue(forKey: url.absoluteString), !remaining.isEmpty else { return nil }
            let reply = remaining.removeFirst()
            if !remaining.isEmpty { replies[url.absoluteString] = remaining }
            return reply
        }),
              let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers) else {
            client?.urlProtocol(self, didFailWithError: LipsyncError.network); return
        }
        reply.observe?(request)
        let task = Task.detached { [reference = Reference(value: self), reply, response] in
            let owner = reference.value
            guard !owner.worker.withLock({ $0.stopped }), !Task.isCancelled else { return }
            if let redirect = reply.redirect {
                owner.client?.urlProtocol(owner, wasRedirectedTo: URLRequest(url: redirect), redirectResponse: response)
                if reply.deliverRedirect, !owner.worker.withLock({ $0.stopped }), !Task.isCancelled {
                    owner.client?.urlProtocol(owner, didReceive: response, cacheStoragePolicy: .notAllowed)
                    for chunk in reply.chunks { owner.client?.urlProtocol(owner, didLoad: chunk) }
                }
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

@Suite("Lip-sync bounded streaming HTTP", .timeLimit(.minutes(1)), .offlineFixtures)
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

    @Test func JSONBodiesAreBoundedBeforeAndAfterDecoding() async throws {
        let oversized = LipsyncHTTPFixtureProtocol.register(.init(headers: ["Content-Type": "application/json"], chunks: [Data(repeating: 32, count: 128)]))
        await #expect(throws: LipsyncError.responseTooLarge) { _ = try await http.send(URLRequest(url: oversized), limit: 32, permit: nil) }
        let decodedOversized = LipsyncHTTPFixtureProtocol.register(.init(headers: ["Content-Type": "application/json",
            "Content-Encoding": "gzip", "Content-Length": "28"], chunks: [Data(repeating: 32, count: 128)]))
        await #expect(throws: LipsyncError.responseTooLarge) { _ = try await http.send(URLRequest(url: decodedOversized), limit: 32, permit: nil) }
        let encodedOversized = LipsyncHTTPFixtureProtocol.register(.init(headers: ["Content-Type": "application/json",
            "Content-Encoding": "gzip", "Content-Length": "4096"], chunks: [Data("{}".utf8)]))
        await #expect(throws: LipsyncError.responseTooLarge) { _ = try await http.send(URLRequest(url: encodedOversized), limit: 32, permit: nil) }
    }

    /// A JSON request asks for gzip or deflate itself, so URLSession never offers br (which the transfer refuses); an answer
    /// in an encoding nobody asked for is still refused. A media download asks for identity.
    @Test(arguments: ["br", "gzip, deflate", "identity-bogus"]) func unsupportedEncodingsAreRejected(encoding: String) async {
        let asked = Mutex<String?>(nil)
        let url = LipsyncHTTPFixtureProtocol.register(.init(headers: ["Content-Type": "application/json", "Content-Encoding": encoding],
            chunks: [Data("{}".utf8)], observe: { request in asked.withLock { $0 = request.value(forHTTPHeaderField: "Accept-Encoding") } }))
        await #expect(throws: LipsyncError.invalidResponse) { _ = try await http.send(URLRequest(url: url), limit: 1_024, permit: nil) }
        #expect(asked.withLock { $0 } == "gzip, deflate")
    }

    @Test func aJSONRequestAsksForGzipOrDeflateAndADownloadForIdentity() async throws {
        let root = try LipsyncProviderFixtures.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let asked = Mutex<[String?]>([])
        let observe: @Sendable (URLRequest) -> Void = { request in asked.withLock { $0.append(request.value(forHTTPHeaderField: "Accept-Encoding")) } }
        let json = LipsyncHTTPFixtureProtocol.register(.init(headers: ["Content-Type": "application/json"], chunks: [Data("{}".utf8)], observe: observe))
        _ = try await http.send(URLRequest(url: json), limit: 1_024, permit: nil)
        let media = LipsyncHTTPFixtureProtocol.register(.init(chunks: [header], observe: observe))
        try await http.download(URLRequest(url: media), to: root.appendingPathComponent("result.mp4"), limit: 1_024)
        #expect(asked.withLock { $0 } == ["gzip, deflate", "identity"])
    }

    /// A refused redirect's 3xx then arrives as the response: it stays unsafeURL. Before: the JSON call saw "HTTP 302" (at a
    /// submit, "charge unknown") and a download a file-check failure.
    @Test func aRefusedRedirectOfAJSONRequestStaysUnsafe() async throws {
        let target = URL(string: "https://127.0.0.1/never-requested")!
        let url = LipsyncHTTPFixtureProtocol.register(.init(status: 302, headers: ["Content-Type": "application/json", "Location": target.absoluteString],
                                                           chunks: [Data("{}".utf8)], redirect: target, deliverRedirect: true))
        await #expect(throws: LipsyncError.unsafeURL) { _ = try await http.send(URLRequest(url: url), limit: 1_024, permit: nil) }
        let root = try LipsyncProviderFixtures.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let media = LipsyncHTTPFixtureProtocol.register(.init(status: 302, headers: ["Content-Type": "text/html", "Location": target.absoluteString],
                                                             chunks: [Data("moved".utf8)], redirect: target, deliverRedirect: true))
        await #expect(throws: LipsyncError.unsafeURL) {
            try await http.download(URLRequest(url: media), to: root.appendingPathComponent("result.mp4"), limit: 1_024)
        }
    }

    /// An upload or a media download gets 60 s plus its bytes at 2 Mbit/s in all, never a fixed two minutes: a 300 MB
    /// window upload has 1,260 s. JSON stays at 30 s.
    @Test func transferTimeoutsScaleWithTheBytes() async throws {
        let big = URLSessionLipsyncHTTPClient.timeouts(upload: true, download: false, bytes: 300_000_000, requested: 60)
        #expect(big.resource > 120 && big.resource == 1_260 && big.request == 120)
        let result = URLSessionLipsyncHTTPClient.timeouts(upload: false, download: true, bytes: LipsyncLimits.maximumVideoBytes, requested: 60)
        #expect(result.resource > 2_000 && result.request == 30)
        let json = URLSessionLipsyncHTTPClient.timeouts(upload: false, download: false, bytes: 1_024, requested: 30)
        #expect(json.request == 30 && json.resource == 30)
        // The configuration a real PUT gets.
        let seen = Mutex<[TimeInterval]>([])
        let client = URLSessionLipsyncHTTPClient(configure: { configuration in
            configuration.protocolClasses = [LipsyncHTTPFixtureProtocol.self]
            seen.withLock { $0.append(configuration.timeoutIntervalForResource) }
        })
        let target = LipsyncHTTPFixtureProtocol.register(.init(status: 200, headers: [:], chunks: []))
        var put = URLRequest(url: target)
        put.httpMethod = "PUT"; put.httpBody = Data(count: 2_500_000)
        _ = try await client.send(put, limit: 1_024, permit: nil)
        #expect(seen.withLock { $0 } == [70])
    }

    @Test func compressedMediaIsNotPublished() async throws {
        let root = try LipsyncProviderFixtures.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = LipsyncHTTPFixtureProtocol.register(.init(headers: ["Content-Type": "video/mp4", "Content-Encoding": "gzip"],
                                                           chunks: [header]))
        await #expect(throws: LipsyncError.invalidResponse) {
            try await http.download(URLRequest(url: url), to: root.appendingPathComponent("result.mp4"), limit: 1_024)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func nonJSONErrorsKeepStatusButSuccessfulHTMLIsRejected() async throws {
        let headers = ["Content-Type": "text/html; charset=utf-8"], chunks = [Data("<html>Gateway error</html>".utf8)]
        let rejected = LipsyncHTTPFixtureProtocol.register(.init(status: 429, headers: headers, chunks: chunks))
        let reply = try await http.send(URLRequest(url: rejected), limit: 1_024, permit: nil)
        #expect(reply.status == 429 && reply.contentType == "text/html")
        let intercepted = LipsyncHTTPFixtureProtocol.register(.init(headers: headers, chunks: chunks))
        await #expect(throws: LipsyncError.invalidResponse) { _ = try await http.send(URLRequest(url: intercepted), limit: 1_024, permit: nil) }
    }

    @Test func falUploadAndQueueRepliesWorkThroughURLSessionTransport() async throws {
        typealias Fixture = LipsyncHTTPFixtureProtocol
        let root = try LipsyncProviderFixtures.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let (video, audio) = try LipsyncProviderFixtures.uploadFiles(root)
        let (store, record) = try await LipsyncProviderFixtures.consent(root)
        let initiate = URL(string: "https://rest.fal.ai/storage/upload/initiate?storage_type=fal-cdn-v3")!
        let submit = URL(string: "https://queue.fal.run/fal-ai/sync-lipsync/v3")!
        let observed = Mutex<[URLRequest]>([])
        let observe: @Sendable (URLRequest) -> Void = { request in observed.withLock { $0.append(request) } }
        let initiationReplies = ["window.mp4", "mixed.wav"].map { name -> Fixture.Reply in
            let token = UUID().uuidString
            let upload = URL(string: "https://storage.fal.ai/upload/\(name)?signature=\(token)")!
            let input = "https://v3b.fal.media/files/b/fixture/\(name)"
            Fixture.register([.init(status: 204, headers: [:], chunks: [], observe: observe)], for: upload)
            let document = Data("""
                {"upload_url":"\(upload.absoluteString)","file_url":"\(input)"}
                """.utf8)
            return .init(headers: ["Content-Type": "Application/JSON; charset=utf-8", "Content-Encoding": "gzip",
                                   "Content-Length": String(document.count - 17)],
                         chunks: [Data(document.prefix(15)), Data(document.dropFirst(15))], observe: observe)
        }
        Fixture.register(initiationReplies, for: initiate)
        let receipt = #"{"status":"IN_QUEUE","request_id":"\#(LipsyncProviderFixtures.requestID)","status_url":null,"cancel_url":null}"#
        Fixture.register([.init(headers: ["Content-Type": "application/json"],
            chunks: [Data(receipt.utf8)], observe: observe)], for: submit)
        let provider = try LipsyncProviderFixtures.provider(http)
        let (quote, approval) = try await provider.prepareApprovedUpload(video: video, audio: audio,
            options: .init(syncMode: .cutOff), fps: 30, consentStore: store, recordID: record,
            acceptsPaidJob: true, acceptsMediaTransfer: true)
        let job = try await provider.submit(quote, approval: approval)
        #expect(job.remoteID == LipsyncProviderFixtures.requestID)
        let rootPath = "/fal-ai/sync-lipsync/requests/\(job.remoteID)"
        #expect(job.responseURL?.path == rootPath)
        #expect(job.statusURL?.path == rootPath + "/status")
        #expect(job.cancelURL?.path == rootPath + "/cancel")
        #expect(await provider.status(quoteID: quote.id)?.billing == .accepted)
        let requests = observed.withLock { $0 }
        #expect(requests.map(\.httpMethod) == ["POST", "PUT", "POST", "PUT", "POST"])
        #expect(requests.map { $0.value(forHTTPHeaderField: "Authorization") != nil } == [true, false, true, false, true])
        #expect(requests.map { $0.value(forHTTPHeaderField: "Content-Type") } ==
            ["application/json", "video/mp4", "application/json", "audio/wav", "application/json"])
    }
}
#endif
