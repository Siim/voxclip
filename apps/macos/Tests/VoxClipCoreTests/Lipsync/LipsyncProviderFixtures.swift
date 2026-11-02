#if DEBUG
import Foundation
import Synchronization
import Testing
@testable import VoxClipCore

actor LipsyncFixtureBarrier {
    private var entered = false
    private var released = false
    private var started: [UUID: TestContinuation<Void>] = [:]
    private var pending: TestContinuation<Void>?
    func block() async {
        entered = true
        for continuation in started.values { continuation.resume() }
        started.removeAll()
        if !released { await withTestDeadline { pending = $0 } }
    }
    func waitUntilEntered() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            if !entered {
                await withTestDeadline { started[id] = $0 }
                try Task.checkCancellation()
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }
    private func cancelWaiter(_ id: UUID) { started.removeValue(forKey: id)?.resume() }
    func release() { released = true; pending?.resume(); pending = nil }
}

actor LipsyncFixtureHTTP: LipsyncHTTPClient {
    enum Reply: Sendable {
        case json(Int, String)
        case held(String, LipsyncFixtureBarrier)
        case network
    }
    private var replies: [Reply]
    private(set) var requests: [URLRequest] = []
    private(set) var downloads: [URLRequest] = []
    init(_ replies: [Reply]) { self.replies = replies }
    func send(_ request: URLRequest, limit: Int, permit: VoiceDispatchPermit?) async throws -> LipsyncHTTPResponse {
        try Task.checkCancellation()
        if let permit { try permit.start {} }
        requests.append(request)
        guard !replies.isEmpty else { Issue.record("Unexpected fixture request"); throw LipsyncError.network }
        switch replies.removeFirst() {
        case .json(let status, let body): return .init(status: status, body: Data(body.utf8))
        case .held(let body, let barrier): await barrier.block(); return .init(status: 200, body: Data(body.utf8))
        case .network: throw LipsyncError.network
        }
    }
    func download(_ request: URLRequest, to file: URL, limit: Int) async throws {
        downloads.append(request)
        throw LipsyncError.invalidMedia
    }
}

final class LipsyncFixtureClock: Sendable {
    struct State { var wall = Date(timeIntervalSince1970: 1_793_577_600); var uptime: Duration = .zero; var sleeps: [Duration] = [] }
    let state = Mutex(State())
    func now() -> Date { state.withLock { $0.wall } }
    func uptime() -> Duration { state.withLock { $0.uptime } }
    func advance(_ seconds: Double) { state.withLock { $0.wall.addTimeInterval(seconds); $0.uptime += .seconds(seconds) } }
    func sleep(_ duration: Duration) {
        state.withLock { state in
            state.sleeps.append(duration); state.uptime += duration
            state.wall.addTimeInterval(Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18)
        }
    }
}

actor LipsyncFixtureKeys: KeyProvider {
    var value = "synthetic-lipsync-fixture-key"
    func key(for provider: String) async throws -> String? { #expect(provider == "fal"); return value }
    func replace() { value = "synthetic-replaced-lipsync-fixture-key" }
}

actor LipsyncFixtureLog: Redacting {
    private var redactor = Redactor(homeDirectory: "/synthetic-home")
    private(set) var secrets: Set<String> = []
    private(set) var messages: [String] = []
    func register(secret: String) { secrets.insert(secret); redactor.register(secret: secret) }
    func redact(_ message: String) -> String { redactor.redact(message) }
    func write(_ entry: LogEntry) { messages.append(entry.message) }
}

enum LipsyncProviderFixtures {
    static let requestID = "11111111-2222-4333-8444-555555555555"
    static let result = URL(string: "https://v3.fal.media/files/fixture/result.mp4")!
    static func receipt(app: String = "fal-ai/latentsync", host: String = "queue.fal.run") -> String {
        """
        {"request_id":"\(requestID)","status_url":"https://\(host)/\(app)/requests/\(requestID)/status","response_url":"https://\(host)/\(app)/requests/\(requestID)","cancel_url":"https://\(host)/\(app)/requests/\(requestID)/cancel"}
        """
    }
    static let completed = #"{"status":"COMPLETED"}"#
    static let output = #"{"video":{"url":"https://v3.fal.media/files/fixture/result.mp4","content_type":"video/mp4","file_size":1200}}"#
    static let cleanup = #"{"cdn_delete_results":[{"link":"https://v3.fal.media/files/fixture/result.mp4","exception":null}]}"#

    static func input(video: Bool = true, seconds: Double = 10, host: String = "fixture-bucket.s3.us-east-1.amazonaws.com") throws -> LipsyncSignedInput {
        let name = video ? "window.mp4" : "mixed.wav"
        var components = URLComponents(string: "https://\(host)/\(name)")!
        components.queryItems = [
            .init(name: "X-Amz-Algorithm", value: "AWS4-HMAC-SHA256"), .init(name: "X-Amz-Credential", value: "fixture/20261102/us-east-1/s3/aws4_request"),
            .init(name: "X-Amz-Date", value: "20261102T000000Z"), .init(name: "X-Amz-Expires", value: "86400"),
            .init(name: "X-Amz-SignedHeaders", value: "host"), .init(name: "X-Amz-Signature", value: String(repeating: "0", count: 64)),
            .init(name: "versionId", value: "fixture-immutable-object-version")
        ]
        return try LipsyncSignedInput(url: components.url!, sha256: String(repeating: video ? "a" : "b", count: 64),
                                     durationSeconds: seconds, contentType: video ? "video/mp4" : "audio/wav", byteCount: 1_200)
    }

    static func provider(_ http: LipsyncFixtureHTTP, clock: LipsyncFixtureClock = LipsyncFixtureClock(),
                         keys: LipsyncFixtureKeys = LipsyncFixtureKeys(), spend: VoiceLabSpendLedger? = nil,
                         logger: (any Redacting)? = nil) throws -> FalLipsyncProvider {
        let prices = try VoiceLabPriceCatalog.load(shared: SharedResources(root: FixtureLoader.sharedRoot()))
        return FalLipsyncProvider(keys: keys, prices: prices, http: http, logger: logger ?? RedactingLogger(homeDirectory: "/synthetic-home"),
                                 spend: spend, now: { clock.now() }, monotonic: { clock.uptime() }, sleep: { clock.sleep($0) })
    }

    static func quote(_ provider: FalLipsyncProvider, modelIndex: Int = 0, mode: SyncMode = .cutOff, seed: UInt32? = nil) async throws -> LipsyncQuote {
        try await provider.quote(model: provider.models[modelIndex], video: input(), audio: input(video: false),
                                 options: .init(syncMode: mode, seed: seed), fps: 30)
    }

    static func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("lipsync-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    static func consent(_ root: URL) async throws -> (VoiceConsentStore, String) {
        let locations = DataLocations(environment: ["VOXCLIP_DATA_DIR": root.path], home: root)
        let store = VoiceConsentStore(locations: locations)
        let wav = VoiceLabRequestFixtures.wav(rate: 16_000, frames: 80_000, fill: 4_000)
        var object = try #require(JSONSerialization.jsonObject(with: FixtureLoader.data("fixtures/voice-lab/consent-record.json")) as? [String: Any])
        var statement = try #require(object["statement"] as? [String: Any])
        statement["audioSha256"] = VoiceLabFingerprint.bytes(wav); object["statement"] = statement
        let record = try JSONDecoder().decode(VoiceConsentRecord.self, from: JSONSerialization.data(withJSONObject: object))
        try await store.saveStatement(wav, recordID: record.id); try await store.save(record)
        return (store, record.id)
    }

    static func approval(_ provider: FalLipsyncProvider, quote: LipsyncQuote, root: URL) async throws -> LipsyncApproval {
        let (store, id) = try await consent(root)
        return try await provider.approve(quote, consentStore: store, recordID: id, acceptsPaidJob: true, acceptsMediaTransfer: true)
    }
}
#endif
