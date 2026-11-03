#if DEBUG
import Foundation
import Synchronization
import Testing
@testable import VoxClipCore
@_spi(Testing) @testable import VoxClipMedia

private final class TakeAccountKeys: KeyProvider, Sendable {
    private struct State {
        var value = "synthetic-take-account-a"
        var rotateOnRead = false
    }
    private let state = Mutex(State())
    func rotate() { state.withLock { $0.value = "synthetic-take-account-b" } }
    func rotateAfterNextRead() { state.withLock { $0.rotateOnRead = true } }
    func key(for provider: String) async throws -> String? {
        state.withLock { state in
            let value = state.value
            if state.rotateOnRead {
                state.rotateOnRead = false
                state.value = "synthetic-take-account-b"
            }
            return provider == "elevenlabs" ? value : nil
        }
    }
}

private final class TakeAccountRequests: Sendable {
    struct Entry: Sendable, Equatable {
        let method: String
        let path: String
        let usesOriginalAccount: Bool
        let usesOriginalRegion: Bool
    }
    let entries = Mutex<[Entry]>([])
    let dispatches = Mutex(0)
    var posts: [Entry] { entries.withLock { $0.filter { $0.method == "POST" } } }
    func record(_ request: URLRequest) {
        entries.withLock {
            $0.append(Entry(method: request.httpMethod ?? "", path: request.url?.path ?? "",
                usesOriginalAccount: request.value(forHTTPHeaderField: "xi-api-key") == "synthetic-take-account-a",
                usesOriginalRegion: request.url?.host == ElevenLabsRegion.default.baseURL.host))
        }
    }
}

private actor TakeAccountEmbedder: SpeakerEmbedder {
    nonisolated let modelID = "fixture-calibrated"
    nonisolated let dimension = 2
    func voicedSamples(_ pcm16k: [Float]) async throws -> [Float] { pcm16k }
    func embed(_ pcm16k: [Float]) async throws -> [Float] { [1, 0] }
}

@Suite("Take account binding", .serialized, .timeLimit(.minutes(2)), .offlineFixtures)
struct VoiceLabTakeAccountBindingTests {
    private struct Fixture {
        let root: URL
        let keys: TakeAccountKeys
        let requests: TakeAccountRequests
        let client: ElevenLabsVoiceLab
        let run: VoiceLabTakeRun
        let input: VoiceLabTakeInput
        let record: VoiceConsentRecord
    }
    private func fixture(creator: String? = "synthetic-take-account-a", region: ElevenLabsRegion = .default,
                         rotateAfterSynthesis: Bool = false, projectAttestation: Bool = false) async throws -> Fixture {
        let root = try SpeechTestFiles.directory()
        let store = VoiceConsentStore(locations: SpeechTestFiles.locations(root))
        let wav = VoiceLabRequestFixtures.wav(rate: 16_000, frames: projectAttestation ? 480_000 : 80_000, fill: 4_000)
        let recordFile = projectAttestation ? "consent-record-project.json" : "consent-record.json"
        var object = try #require(JSONSerialization.jsonObject(with: FixtureLoader.data("fixtures/voice-lab/\(recordFile)")) as? [String: Any])
        let referenceField = projectAttestation ? "projectConsent" : "statement"
        var reference = try #require(object[referenceField] as? [String: Any])
        reference["audioSha256"] = VoiceLabFingerprint.bytes(wav)
        object[referenceField] = reference
        if projectAttestation {
            var samples = try #require(object["samples"] as? [[String: Any]])
            samples[0]["sha256"] = VoiceLabFingerprint.bytes(wav)
            object["samples"] = samples
        }
        var speaker = try #require(object["speaker"] as? [String: Any])
        speaker["threshold"] = 0.45
        object["speaker"] = speaker
        var record = try JSONDecoder().decode(VoiceConsentRecord.self, from: JSONSerialization.data(withJSONObject: object))
        record.region = region
        record.creator = creator.map { .init(region: region, keyFingerprint: String(VoiceLabFingerprint.bytes(Data($0.utf8)).prefix(16))) }
        if projectAttestation { try await store.saveReferenceAudio(wav, recordID: record.id) }
        else { try await store.saveStatement(wav, recordID: record.id) }
        try await store.save(record)
        let keys = TakeAccountKeys(), requests = TakeAccountRequests()
        let base = SpeechStubHTTP.register { request in
            requests.record(request)
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/v1/models"):
                return (200, [:], Data(#"[{"model_id":"eleven_v3","name":"Speech","can_do_text_to_speech":true,"languages":[{"language_id":"en"}],"maximum_text_length_per_request":5000}]"#.utf8))
            case ("GET", "/v2/voices"):
                return (200, [:], Data(#"{"voices":[{"voice_id":"fixtureOwnVoice","name":"My voice","category":"cloned","is_owner":true}],"has_more":false}"#.utf8))
            case ("POST", "/v1/text-to-speech/fixtureOwnVoice/with-timestamps"):
                let body = try #require(JSONSerialization.jsonObject(with: VoiceLabRequestFixtures.body(request)) as? [String: Any])
                #expect(body["text"] as? String == "Hello")
                var pcm = Data()
                for index in 0..<98_640 {
                    var sample = Int16((sin(2 * Double.pi * 100 * Double(index) / 24_000) * 3_200).rounded()).littleEndian
                    withUnsafeBytes(of: &sample) { pcm.append(contentsOf: $0) }
                }
                let characters = Array("Hello").map(String.init)
                let starts = characters.indices.map { 0.1 + Double($0) * 3.91 / 5 }
                let ends = characters.indices.map { 0.1 + Double($0 + 1) * 3.91 / 5 }
                let reply = try JSONSerialization.data(withJSONObject: ["audio_base64": pcm.base64EncodedString(),
                    "alignment": ["characters": characters, "character_start_times_seconds": starts, "character_end_times_seconds": ends]])
                if rotateAfterSynthesis { keys.rotate() }
                return (200, [:], reply)
            case ("POST", "/v1/speech-to-text"):
                #expect(!(try VoiceLabRequestFixtures.body(request)).isEmpty)
                return (200, [:], Data(#"{"language_code":"eng","words":[{"type":"word","text":"Hello","start":0.65,"end":4.35}]}"#.utf8))
            default:
                Issue.record("Unexpected account-binding request")
                return (500, [:], Data())
            }
        }
        let client = ElevenLabsVoiceLab(keys: keys, session: URLSession(configuration: SpeechStubHTTP.configuration(for: base)),
            logger: SpeechTestLogger(), prices: VoiceLabPricingTests.catalogIfPresent, enforceCapabilities: true)
        let storage = VoiceLabTakeStorage(projectId: UUID().uuidString.lowercased(), paidRoot: root.appendingPathComponent("VoiceLab"),
            scratchRoot: root.appendingPathComponent("scratch"))
        let run = VoiceLabTakeRun(client: client, store: store,
            speaker: VoiceSpeakerCheck(embedder: TakeAccountEmbedder(), calibratedThreshold: 0.45), storage: storage,
            dispatchIfCurrent: { _, start in try start() }, inputsAreCurrent: { true })
        let source: [Float] = (0..<192_000).map { index in
            let seconds = Double(index) / 24_000
            let quiet = (1.9..<2.1).contains(seconds) || (5.9..<6.1).contains(seconds) || (6.5..<7.1).contains(seconds)
            return quiet ? 0.001 : Float(0.1 * sin(2 * Double.pi * 100 * seconds))
        }
        let items = [TimedWord(id: "before", text: "before", kind: .word, start: 0, end: 1.9),
            TimedWord(id: "old", text: "old", kind: .word, start: 2.1, end: 5.9),
            TimedWord(id: "after", text: "after", kind: .word, start: 6.1, end: 6.5),
            TimedWord(id: "last", text: "last", kind: .word, start: 7.1, end: 7.9)]
        let window = VoiceLabWindow(firstWordId: "old", lastWordId: "old", leftBridgeWordIds: [], rightBridgeWordIds: [], start: 2, end: 6,
            startSample: 48_000, endSample: 144_000, leftSeam: .init(kind: .hard, time: 2, sample: 48_000, fadeSamples: 288),
            rightSeam: .init(kind: .hard, time: 6, sample: 144_000, fadeSamples: 288))
        let input = VoiceLabTakeInput(text: "Hello", modelID: "eleven_v3", recordID: record.id, language: "en", seed: 7,
            contentKey: "synthetic-account-source", source: source, sourceSampleRate: 24_000, items: items, window: window,
            incomingSilence: nil, outgoingSilence: nil, providerConsent: true, hardJoinSmoothing: false)
        return Fixture(root: root, keys: keys, requests: requests, client: client, run: run, input: input, record: record)
    }

    @Test(arguments: ["recorded", "legacy", "project"])
    func matchingCreatorAndLegacyRecordsCompleteWithoutRebinding(consent: String) async throws {
        let fixture = try await fixture(creator: consent == "legacy" ? nil : "synthetic-take-account-a", projectAttestation: consent == "project")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        #expect(try await fixture.run.discover(language: "en").voices == [fixture.record])
        let quote = try await fixture.run.prepare(fixture.input, candidates: 1)
        try await fixture.run.approve(quote)
        let result = try await fixture.run.execute(quote, approved: true)
        #expect(result.end == .earlyStop)
        #expect(result.best != nil)
        #expect(fixture.requests.posts.map(\.path) == ["/v1/text-to-speech/fixtureOwnVoice/with-timestamps", "/v1/speech-to-text"])
        #expect(fixture.requests.entries.withLock { $0.allSatisfy { $0.usesOriginalAccount && $0.usesOriginalRegion } })
    }

    @Test(arguments: ["creator", "region", "legacy-region"])
    func discoveryFiltersAndPreparationRefusesForeignRecords(mismatch: String) async throws {
        let fixture = try await fixture(creator: mismatch == "legacy-region" ? nil :
            mismatch == "creator" ? "synthetic-take-account-b" : "synthetic-take-account-a",
            region: mismatch == "creator" ? .default : .eu)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        #expect(try await fixture.run.discover(language: "en").voices.isEmpty)
        await #expect(throws: VoiceConsentError.creatorMismatch) { try await fixture.run.prepare(fixture.input) }
        #expect(fixture.requests.posts.isEmpty)
    }

    @Test(arguments: [false, true])
    func rotationAfterDiscoveryRefusesPreparationAndRediscovery(legacy: Bool) async throws {
        let fixture = try await fixture(creator: legacy ? nil : "synthetic-take-account-a")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.run.discover(language: "en")
        let discoveredRequests = fixture.requests.entries.withLock { $0.count }
        fixture.keys.rotate()
        await #expect(throws: VoiceConsentError.creatorMismatch) { try await fixture.run.prepare(fixture.input) }
        await #expect(throws: VoiceConsentError.creatorMismatch) { try await fixture.run.discover(language: "en") }
        #expect(fixture.requests.entries.withLock { $0.count } == discoveredRequests)
    }

    @Test func rotationDuringPreparationDoesNotPublishAQuote() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.run.discover(language: "en")
        fixture.keys.rotateAfterNextRead()
        await #expect(throws: VoiceConsentError.creatorMismatch) { try await fixture.run.prepare(fixture.input) }
        #expect(await fixture.run.preparedSetID == nil)
        #expect(fixture.requests.posts.isEmpty)
    }

    @Test(arguments: [false, true])
    func rotationBeforeApprovalRefusesBothApprovalRoutes(batchApproval: Bool) async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.run.discover(language: "en")
        let quote = try await fixture.run.prepare(fixture.input)
        fixture.keys.rotate()
        if batchApproval {
            await #expect(throws: VoiceConsentError.creatorMismatch) { try await fixture.run.approve(quote) }
        } else {
            await #expect(throws: VoiceConsentError.creatorMismatch) { try await fixture.run.execute(quote, approved: true) }
        }
        #expect(fixture.requests.posts.isEmpty)
    }

    @Test func rotationAfterBatchApprovalCannotReuseItsAuthorization() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.run.discover(language: "en")
        let quote = try await fixture.run.prepare(fixture.input)
        try await fixture.run.approve(quote)
        fixture.keys.rotate()
        await #expect(throws: VoiceConsentError.creatorMismatch) { try await fixture.run.execute(quote, approved: true) }
        #expect(fixture.requests.posts.isEmpty)
    }

    @Test(arguments: [1, 2])
    func rotationAtTTSOrQATransportBoundarySendsNothingFurther(dispatch: Int) async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.run.discover(language: "en")
        let quote = try await fixture.run.prepare(fixture.input, candidates: 1)
        try await fixture.run.approve(quote)
        await fixture.client.useDispatchHook {
            let ordinal = fixture.requests.dispatches.withLock { $0 += 1; return $0 }
            if ordinal == dispatch { fixture.keys.rotate() }
        }
        let result = try await fixture.run.execute(quote, approved: true)
        #expect(result.end == .fatal)
        #expect((result.failure ?? result.rows.last?.failure) == .consent(.creatorMismatch))
        #expect(fixture.requests.posts.count == dispatch - 1)
        #expect(fixture.requests.entries.withLock { $0.allSatisfy { $0.usesOriginalAccount && $0.usesOriginalRegion } })
        if dispatch == 2 {
            #expect(result.rows.last?.receipt != nil)
            #expect(result.rows.last?.qaReceipt == nil)
            #expect(await fixture.run.paidAsset(for: quote.takes[0].synthesis.requestID) != nil)
        }
    }

    @Test(arguments: [false, true])
    func rotationAfterTTSKeepsPaidAudioButNeverUploadsQA(projectAttestation: Bool) async throws {
        let fixture = try await fixture(rotateAfterSynthesis: true, projectAttestation: projectAttestation)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.run.discover(language: "en")
        let quote = try await fixture.run.prepare(fixture.input, candidates: 1)
        let result = try await fixture.run.execute(quote, approved: true)
        #expect(result.end == .fatal)
        #expect(result.rows.last?.receipt != nil)
        #expect(result.rows.last?.failure == .consent(.creatorMismatch))
        #expect(fixture.requests.posts.map(\.path) == ["/v1/text-to-speech/fixtureOwnVoice/with-timestamps"])
        #expect(await fixture.run.paidAsset(for: quote.takes[0].synthesis.requestID) != nil)
    }
}
#endif
