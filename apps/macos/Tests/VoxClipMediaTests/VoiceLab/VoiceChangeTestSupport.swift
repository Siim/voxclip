#if DEBUG
import Foundation
import Synchronization
import Testing
@testable import VoxClipCore
@_spi(Testing) @testable import VoxClipMedia

enum VoiceChangeTestFiles {
    static func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voice-change-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    static func record(reference: Data? = nil) throws -> VoiceConsentRecord {
        let shared = try SharedResources.locate()
        let bytes = try Data(contentsOf: shared.root.appendingPathComponent("fixtures/voice-lab/consent-record.json"))
        guard let reference else { return try JSONDecoder().decode(VoiceConsentRecord.self, from: bytes) }
        var json = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        var statement = try #require(json["statement"] as? [String: Any])
        statement["audioSha256"] = VoiceLabFingerprint.bytes(reference)
        json["statement"] = statement
        return try JSONDecoder().decode(VoiceConsentRecord.self, from: JSONSerialization.data(withJSONObject: json))
    }
    static func samples(frames: Int, rate: Int, amplitude: Double = 0.15) -> [Float] {
        (0..<frames).map { Float(amplitude * sin(2 * Double.pi * 220 * Double($0) / Double(rate))) }
    }
    static func wave(frames: Int = 120_000, rate: Int = 24_000) throws -> Data {
        try VoiceLabTakeWAV.encode(samples(frames: frames, rate: rate), rate: rate)
    }
}

struct VoiceChangeTestKeys: KeyProvider {
    let value: String
    func key(for provider: String) async throws -> String? { value }
}

struct VoiceChangeTestEmbedder: SpeakerEmbedder {
    let modelID = "fixture-calibrated"
    let dimension = 2
    func embed(_ pcm16k: [Float]) async throws -> [Float] { [1, 0] }
    func voicedSamples(_ pcm16k: [Float]) async throws -> [Float] { pcm16k }
}

final class VoiceChangeTestLog: Sendable {
    let requests = Mutex<[String]>([])
    let accepted = Mutex<[UUID]>([])
    let dispatched = Mutex<[UUID]>([])
}

actor VoiceChangeTestSignal {
    private var signalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func signal() {
        signalled = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
    func wait() async {
        if signalled { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

final class VoiceChangeTestHTTP: URLProtocol, @unchecked Sendable {
    enum Mode: Sendable { case valid, malformed, failedBody, lostBody, oversized, denied, hold }
    struct Handler: Sendable { let mode: Mode; let log: VoiceChangeTestLog }
    static let handlers = Mutex<[String: Handler]>([:])
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let key = request.value(forHTTPHeaderField: "xi-api-key"),
              let handler = Self.handlers.withLock({ $0[key] }), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        let path = url.path
        handler.log.requests.withLock { $0.append(path) }
        let body: Data
        let status: Int
        var headers: [String: String] = [:]
        switch path {
        case "/v1/models":
            status = 200
            body = Data(#"[{"model_id":"eleven_multilingual_sts_v2","can_do_voice_conversion":true,"languages":[{"language_id":"en"}]}]"#.utf8)
        case "/v2/voices":
            status = 200
            body = Data(#"{"voices":[{"voice_id":"fixtureOwnVoice","name":"Example","category":"cloned","is_owner":true,"voice_verification":{"is_verified":true}}],"has_more":false}"#.utf8)
        case "/v1/voice-changer/fixtureOwnVoice":
            status = handler.mode == .denied ? 500 : 200
            headers["Content-Type"] = "audio/pcm"
            if handler.mode == .oversized { headers["Content-Length"] = "33554433" }
            body = handler.mode == .malformed || handler.mode == .lostBody ? Data() : Data(repeating: 1, count: 4_800)
        default:
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/2", headerFields: headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if path.hasPrefix("/v1/voice-changer/") {
            if handler.mode == .hold { return }
            if handler.mode == .failedBody {
                client?.urlProtocol(self, didLoad: Data([0, 1]))
                client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)); return
            }
        }
        if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

struct VoiceChangeTransportFixture: Sendable {
    let root: URL
    let client: ElevenLabsVoiceLab
    let store: VoiceConsentStore
    let record: VoiceConsentRecord
    let input: Data
    let guardService: VoiceUseGuard
    let ledger: VoiceLabSpendLedger
    let log: VoiceChangeTestLog
    let key: String

    static func make(mode: VoiceChangeTestHTTP.Mode = .valid) async throws -> Self {
        let root = try VoiceChangeTestFiles.directory()
        let input = try VoiceChangeTestFiles.wave()
        let record = try VoiceChangeTestFiles.record(reference: input)
        let store = VoiceConsentStore(locations: DataLocations(environment: ["VOXCLIP_DATA_DIR": root.path]))
        try await store.saveStatement(input, recordID: record.id)
        try await store.save(record)
        let key = "synthetic-conversion-test-\(UUID().uuidString)"
        let log = VoiceChangeTestLog()
        VoiceChangeTestHTTP.handlers.withLock { $0[key] = .init(mode: mode, log: log) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VoiceChangeTestHTTP.self]
        let ledger = VoiceLabSpendLedger(url: root.appendingPathComponent("spend.json"))
        let client = ElevenLabsVoiceLab(keys: VoiceChangeTestKeys(value: key), session: URLSession(configuration: configuration),
            prices: try VoiceLabPriceCatalog.load(shared: SharedResources.locate()), spend: ledger, enforceCapabilities: true)
        _ = try await client.models(); _ = try await client.voices()
        let check = VoiceSpeakerCheck(embedder: VoiceChangeTestEmbedder(), calibratedThreshold: record.speaker.threshold)
        return Self(root: root, client: client, store: store, record: record, input: input,
            guardService: VoiceUseGuard(store: store, check: check), ledger: ledger, log: log, key: key)
    }
    func clean() {
        _ = VoiceChangeTestHTTP.handlers.withLock { $0.removeValue(forKey: key) }
        try? FileManager.default.removeItem(at: root)
    }
    var initial: VoiceLabVoiceChoice {
        .own(voiceID: record.voiceId, policy: OwnVoicePolicy(recordID: record.id, cloneVoiceID: record.voiceId,
            recordActive: true, providerConsentGranted: true, statementVerified: true, speakerMatched: true))
    }
    func quote() async throws -> VoiceLabQuote {
        try await client.prepareConversion(audio: input, modelID: "eleven_multilingual_sts_v2", voice: initial,
            language: "en", seed: 7, cleanAudioOn: false, requestID: UUID())
    }
    func choice(_ quote: VoiceLabQuote) async throws -> VoiceLabVoiceChoice {
        let policy = try await guardService.authorizeConversion(quote: quote, contentKey: "synthetic-source",
            recordID: record.id, audio: input, approved: true)
        return .own(voiceID: record.voiceId, policy: policy)
    }
    func convert(_ quote: VoiceLabQuote, choice: VoiceLabVoiceChoice,
                 boundary: @escaping VoiceLabTakeDispatchBoundary,
                 accepted: @escaping @Sendable (UUID) async -> Void) async throws -> VoiceLabAudioResult {
        try await client.convert(audio: input, modelID: "eleven_multilingual_sts_v2", voice: choice, language: "en", seed: 7,
            cleanAudioOn: false, requestID: quote.requestID, authorization: .init(quote: quote, approved: true),
            dispatchIfCurrent: boundary, accepted: accepted)
    }
}
#endif
