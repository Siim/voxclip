import Foundation
import Synchronization
import Testing
import VoxClipCore
@testable import VoxClipMedia

/// Replies in order and records every request; never touches the network.
final class StubMusicHTTP: MusicHTTP {
    struct Reply: Sendable {
        var status: Int
        var headers: [String: String] = [:]
        var body: Data
    }
    private let replies: Mutex<[Reply]>
    private let log = Mutex<[URLRequest]>([])
    init(_ replies: [Reply]) { self.replies = Mutex(replies) }
    var sent: [URLRequest] { log.withLock { $0 } }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        log.withLock { $0.append(request) }
        let reply = try replies.withLock { replies -> Reply in
            guard !replies.isEmpty else { throw VoxClipError.offline }
            return replies.removeFirst()
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        return (reply.body, response)
    }
}

struct StubMusicKeys: KeyProvider {
    var value: String? = "test-eleven-key"
    func key(for provider: String) async throws -> String? { provider == "elevenlabs" ? value : nil }
}

final class TestClock: Sendable {
    private let value = Mutex(ContinuousClock.now)
    var now: ContinuousClock.Instant { value.withLock { $0 } }
    func advance(_ duration: Duration) { value.withLock { $0 += duration } }
}

/// Hand-written in the shape of an anonymous Openverse audio search reply (fields as returned on 2026-11-04).
enum OpenverseFixture {
    static func row(_ id: String, license: String, title: String, tags: [String] = [], filetype: String = "mp32", duration: Int = 120_000,
                    url: String? = nil, landing: String? = nil, attribution: Bool = true, mature: Bool = false) -> [String: Any] {
        var row: [String: Any] = [
            "id": id, "title": title, "creator": "Artist " + id, "license": license, "license_version": "3.0",
            "foreign_landing_url": landing ?? "https://www.jamendo.com/track/\(id)",
            "url": url ?? "https://prod-1.storage.jamendo.com/?trackid=\(id)&format=mp32",
            "category": "music", "filetype": filetype, "duration": duration, "mature": mature, "genres": ["ambient"],
            "tags": tags.map { ["name": $0, "accuracy": NSNull()] }]
        if attribution { row["attribution"] = "\"\(title)\" by Artist \(id) is licensed under CC BY 3.0." }
        return row
    }

    static func reply(_ rows: [[String: Any]]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["result_count": rows.count, "page_count": 1, "page_size": 20, "page": 1, "results": rows])
    }

    static let mixed = reply([
        row("nc", license: "by-nc", title: "Calm noncommercial", tags: ["calm", "instrumental"]),
        row("sa", license: "by-sa", title: "Calm share alike", tags: ["calm", "instrumental"]),
        row("nd", license: "by-nd", title: "Calm no derivatives", tags: ["calm", "instrumental"]),
        row("ncsa", license: "by-nc-sa", title: "Calm both", tags: ["calm"]),
        row("song", license: "by", title: "Calm song", tags: ["calm", "vocals"]),
        row("piano", license: "by", title: "Quiet piano", tags: ["calm", "piano", "instrumental"]),
        row("zero", license: "cc0", title: "Zero", tags: ["ambient"], attribution: false),
        row("pd", license: "pdm", title: "Old march", tags: ["march"], filetype: "wav"),
        row("ogg", license: "cc0", title: "Ogg", filetype: "ogg"),
        row("http", license: "cc0", title: "Insecure", url: "http://example.com/a.mp3"),
        row("short", license: "cc0", title: "Blip", duration: 4_000),
        row("adult", license: "cc0", title: "Mature", mature: true),
        row("noattr", license: "by", title: "Uncredited", attribution: false)])
}

struct OpenverseMusicClientTests {
    @Test func searchSendsOnlyTheFreeLicensesForMusic() throws {
        let components = try #require(URLComponents(url: OpenverseMusicClient.searchURL(query: "calm piano"), resolvingAgainstBaseURL: false))
        #expect(components.scheme == "https" && components.host == "api.openverse.org" && components.path == "/v1/audio/")
        #expect(components.queryItems == [URLQueryItem(name: "q", value: "calm piano"), URLQueryItem(name: "license", value: "cc0,by,pdm"),
                                          URLQueryItem(name: "category", value: "music"), URLQueryItem(name: "page_size", value: "20")])
    }

    @Test func licenseFilteringDropsNoncommercialNoDerivativesAndShareAlike() throws {
        let candidates = try OpenverseMusicClient.parse(OpenverseFixture.mixed)
        #expect(candidates.map(\.id) == ["openverse-song", "openverse-piano", "openverse-zero", "openverse-pd"])
        #expect(candidates.allSatisfy { [.cc0, .by, .pdm].contains($0.license) && $0.source == .library })
        let piano = try #require(candidates.first { $0.id == "openverse-piano" })
        #expect(piano.fileExtension == "mp3" && piano.durationSeconds == 120 && piano.sourceUrl == "https://www.jamendo.com/track/piano")
        #expect(piano.attribution == "\"Quiet piano\" by Artist piano is licensed under CC BY 3.0.")
        #expect(candidates.first { $0.id == "openverse-pd" }?.fileExtension == "wav")
    }

    @Test func rankingPrefersInstrumentalMatchesAndCachesOneSearchPerQuery() async throws {
        let http = StubMusicHTTP([.init(status: 200, body: OpenverseFixture.mixed)])
        let client = OpenverseMusicClient(http: http)
        let first = try await client.search("calm piano", keywords: ["calm", "piano"], clipSeconds: 30)
        #expect(first.first?.id == "openverse-piano")
        #expect(first.last?.id == "openverse-song" || first.firstIndex { $0.id == "openverse-song" }! > 0)
        _ = try await client.search("Calm Piano", keywords: ["calm"], clipSeconds: 30)
        #expect(http.sent.count == 1)
        #expect(http.sent.first?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func rateLimitBacksOffUntilRetryAfterPasses() async throws {
        let clock = TestClock()
        let http = StubMusicHTTP([.init(status: 429, headers: ["Retry-After": "30"], body: Data()),
                                  .init(status: 200, body: OpenverseFixture.mixed)])
        let client = OpenverseMusicClient(http: http, clock: { clock.now })
        await #expect(throws: VoxClipError.self) { _ = try await client.search("calm") }
        await #expect(throws: VoxClipError.self) { _ = try await client.search("other") }
        #expect(http.sent.count == 1)
        clock.advance(.seconds(31))
        #expect(try await client.search("other").isEmpty == false)
        #expect(http.sent.count == 2)
    }

    @Test func rateLimitWithoutRetryAfterDoublesTheBackoff() async throws {
        let clock = TestClock()
        let http = StubMusicHTTP([.init(status: 429, body: Data()), .init(status: 429, body: Data()), .init(status: 200, body: OpenverseFixture.mixed)])
        let client = OpenverseMusicClient(http: http, clock: { clock.now })
        await #expect(throws: VoxClipError.self) { _ = try await client.search("a") }
        clock.advance(.seconds(16))
        await #expect(throws: VoxClipError.self) { _ = try await client.search("b") }
        clock.advance(.seconds(16))
        await #expect(throws: VoxClipError.self) { _ = try await client.search("c") }
        #expect(http.sent.count == 2)
        clock.advance(.seconds(15))
        #expect(try await client.search("c").count == 4)
    }

    @Test func downloadRefusesNonAudioReplies() async throws {
        let candidate = try #require(try OpenverseMusicClient.parse(OpenverseFixture.mixed).first)
        let http = StubMusicHTTP([.init(status: 200, headers: ["Content-Type": "text/html"], body: Data("<html>".utf8)),
                                  .init(status: 200, headers: ["Content-Type": "audio/mpeg"], body: Data([0x49, 0x44, 0x33, 4]))])
        let client = OpenverseMusicClient(http: http)
        await #expect(throws: VoxClipError.self) { _ = try await client.download(candidate) }
        #expect(try await client.download(candidate) == Data([0x49, 0x44, 0x33, 4]))
        #expect(http.sent.map(\.url) == [candidate.audioURL, candidate.audioURL])
    }
}

struct ElevenMusicClientTests {
    private func catalog() throws -> VoiceLabPriceCatalog {
        try VoiceLabPriceCatalog(data: Data(contentsOf: SharedResources.locate().root.appendingPathComponent("catalog/voice-lab.json")))
    }
    private static let mp3 = Data([0x49, 0x44, 0x33, 0x04]) + Data(repeating: 0, count: 300)

    @Test func requestMatchesTheComposeReference() throws {
        let client = ElevenMusicClient(keys: StubMusicKeys(), catalog: try catalog(), spend: nil, region: .eu, http: StubMusicHTTP([]))
        let quote = try client.quote(prompt: "  Warm lo-fi bed  ", clipSeconds: 41.2)
        #expect(quote.lengthSeconds == 42 && quote.prompt == "Warm lo-fi bed")
        let request = try client.request(for: quote, key: "k")
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://api.eu.residency.elevenlabs.io/v1/music?output_format=mp3_44100_128")
        #expect(request.value(forHTTPHeaderField: "xi-api-key") == "k")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let data = try #require(request.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(body.keys) == ["prompt", "music_length_ms", "model_id", "force_instrumental"])
        #expect(body["prompt"] as? String == "Warm lo-fi bed" && body["music_length_ms"] as? Int == 42_000)
        #expect(body["model_id"] as? String == "music_v1" && body["force_instrumental"] as? Bool == true)
    }

    @Test func pricingIsFifteenCentsAMinuteWithinThreeSecondsAndFiveMinutes() throws {
        let client = ElevenMusicClient(keys: StubMusicKeys(), catalog: try catalog(), spend: nil, http: StubMusicHTTP([]))
        #expect(try client.quote(prompt: "a", clipSeconds: 60).estimate.usd == Decimal(string: "0.15"))
        #expect(try client.quote(prompt: "a", clipSeconds: 1).lengthSeconds == 3)
        let long = try client.quote(prompt: "a", clipSeconds: 3_600)
        #expect(long.lengthSeconds == 300 && long.estimate.usd == Decimal(string: "0.75"))
        #expect(throws: VoxClipError.self) { try client.quote(prompt: "   ", clipSeconds: 10) }
    }

    @Test func composeSendsOnceRecordsTheSpendAndRefusesReuse() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-music-ledger-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ledger = VoiceLabSpendLedger(url: directory.appendingPathComponent("spend.json"))
        let http = StubMusicHTTP([.init(status: 200, headers: ["Content-Type": "audio/mpeg"], body: Self.mp3)])
        let client = ElevenMusicClient(keys: StubMusicKeys(), catalog: try catalog(), spend: ledger, http: http)
        let quote = try client.quote(prompt: "calm", clipSeconds: 60)
        #expect(try await client.compose(quote) == Self.mp3)
        #expect(await ledger.total(provider: "elevenlabs", at: Date())?.usd == Decimal(string: "0.15"))
        await #expect(throws: VoxClipError.self) { _ = try await client.compose(quote) }
        #expect(http.sent.count == 1)
    }

    @Test func failuresAreNeverRetriedOrCharged() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-music-ledger-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ledger = VoiceLabSpendLedger(url: directory.appendingPathComponent("spend.json"))
        let detail = Data(#"{"detail":[{"loc":["body","prompt"],"msg":"Prompt mentions a protected artist","type":"value_error"}]}"#.utf8)
        let http = StubMusicHTTP([.init(status: 422, body: detail), .init(status: 500, body: Data()), .init(status: 429, body: Data())])
        let client = ElevenMusicClient(keys: StubMusicKeys(), catalog: try catalog(), spend: ledger, http: http)
        await #expect(throws: VoxClipError.providerError("Eleven Music: Prompt mentions a protected artist", provider: "elevenlabs", status: 422)) {
            _ = try await client.compose(try client.quote(prompt: "calm", clipSeconds: 10))
        }
        #expect(http.sent.count == 1)
        await #expect(throws: VoxClipError.self) { _ = try await client.compose(try client.quote(prompt: "calm", clipSeconds: 10)) }
        await #expect(throws: VoxClipError.rateLimited("elevenlabs")) { _ = try await client.compose(try client.quote(prompt: "calm", clipSeconds: 10)) }
        #expect(http.sent.count == 3)
        #expect(await ledger.total(provider: "elevenlabs", at: Date())?.usd ?? 0 == 0)
    }

    @Test func staleOrKeylessQuotesSendNothing() async throws {
        let clock = TestClock()
        let http = StubMusicHTTP([])
        let client = ElevenMusicClient(keys: StubMusicKeys(), catalog: try catalog(), spend: nil, http: http, clock: { clock.now })
        let quote = try client.quote(prompt: "calm", clipSeconds: 10)
        clock.advance(.seconds(601))
        await #expect(throws: VoxClipError.self) { _ = try await client.compose(quote) }
        let keyless = ElevenMusicClient(keys: StubMusicKeys(value: nil), catalog: try catalog(), spend: nil, http: http)
        await #expect(throws: VoxClipError.keyMissing("elevenlabs")) { _ = try await keyless.compose(try keyless.quote(prompt: "calm", clipSeconds: 10)) }
        #expect(http.sent.isEmpty)
    }
}

struct MusicSuggestionServiceTests {
    @Test func bestThreeAcrossSourcesWithPricedGenerationAndOwnFile() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-music-folder-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["calm-evening.m4a", "rock.mp3", "notes.txt", "calm.ogg"] {
            FileManager.default.createFile(atPath: folder.appendingPathComponent(name).path, contents: Data([0]))
        }
        let catalog = try VoiceLabPriceCatalog(data: Data(contentsOf: SharedResources.locate().root.appendingPathComponent("catalog/voice-lab.json")))
        let eleven = ElevenMusicClient(keys: StubMusicKeys(), catalog: catalog, spend: nil, http: StubMusicHTTP([]))
        let service = MusicSuggestionService(library: OpenverseMusicClient(http: StubMusicHTTP([.init(status: 200, body: OpenverseFixture.mixed)])),
                                             eleven: eleven, hasElevenKey: { true }, folder: { folder })
        let result = await service.candidates(for: MusicBrief(mood: "calm piano", reason: "A reflective talk"), clipSeconds: 30)
        #expect(result.candidates.map(\.source) == [.library, .generated, .file])
        #expect(result.candidates[0].id == "openverse-piano" && result.candidates[0].reason == "A reflective talk")
        let generated = result.candidates[1]
        #expect(generated.needsGeneration && generated.estimate?.usd == Decimal(string: "0.075") && generated.title == "Calm piano")
        #expect(service.quote(for: generated)?.lengthSeconds == 30 && service.quote(for: generated) == nil)
        #expect(result.candidates[2].title == "calm-evening" && result.candidates[2].license == .own)
        #expect(MusicLibraryFolder.files(in: folder).map(\.title) == ["calm-evening", "rock"])
        #expect(result.notes.isEmpty)
    }

    @Test func offlineLibraryAndMissingKeyLeaveNotesNotDeadEnds() async throws {
        let catalog = try VoiceLabPriceCatalog(data: Data(contentsOf: SharedResources.locate().root.appendingPathComponent("catalog/voice-lab.json")))
        let service = MusicSuggestionService(library: OpenverseMusicClient(http: StubMusicHTTP([])),
                                             eleven: ElevenMusicClient(keys: StubMusicKeys(value: nil), catalog: catalog, spend: nil, http: StubMusicHTTP([])),
                                             hasElevenKey: { false }, folder: { nil })
        let result = await service.candidates(for: MusicBrief(mood: "upbeat"), clipSeconds: 20)
        #expect(result.candidates.isEmpty)
        #expect(result.notes[.library] == "You're offline, so only your own files are shown.")
        #expect(result.notes[.generated] == "Add an ElevenLabs key in Settings to make music for this clip.")
    }

    @Test func storedAssetsAreNamedByContentAndNeverOverwritten() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-music-store-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let pid = "5b7e0f7a-3c1d-4b8e-9a51-2f6d0c8e4a11"
        let first = try MusicAssetStore.store(Data([1, 2, 3]), title: "Café Night — Live!", fileExtension: "mp3", projectId: pid, dataRoot: root)
        #expect(first.file.hasPrefix(pid + "/music-cafe-night-live-") && first.file.hasSuffix(".mp3"))
        #expect(first.url.path.hasPrefix(root.appendingPathComponent("Music/" + pid).path))
        #expect(try MusicAssetStore.store(Data([1, 2, 3]), title: "Café Night — Live!", fileExtension: "mp3", projectId: pid, dataRoot: root) == first)
        #expect(throws: VoxClipError.self) { try MusicAssetStore.store(Data(), title: "x", fileExtension: "mp3", projectId: pid, dataRoot: root) }
        #expect(throws: VoxClipError.self) { try MusicAssetStore.store(Data([1]), title: "x", fileExtension: "ogg", projectId: pid, dataRoot: root) }
        let entry = try MusicAssetStore.entry(for: MusicCandidate(id: "x", source: .library, title: "Night", license: .by, attribution: "credit",
                                                                  sourceUrl: "https://example.com/1", fileExtension: "mp3"),
                                              stored: first, durationSeconds: 90, clipId: "clip-main")
        try MusicProject.validate(entry, projectId: pid)
        #expect(entry.gainDb == -20 && entry.ducking && entry.fadeInSeconds == 0.5 && entry.fadeOutSeconds == 1.5 && entry.prompt == nil)
    }
}
