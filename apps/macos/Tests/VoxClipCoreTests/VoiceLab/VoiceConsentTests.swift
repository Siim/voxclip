import Foundation
import Synchronization
import Testing
@testable import VoxClipCore

private final class ConsentRequestLog: Sendable { let value = Mutex<[String]>([]) }
private final class ConsentTranscriptionCount: Sendable { let value = Mutex(0) }
private final class SpeakerAvailability: Sendable { let value = Mutex(true) }

@Suite("Own-voice consent", .timeLimit(.minutes(2)))
struct VoiceConsentTests {
    struct FixedRNG: RandomNumberGenerator {
        var state: UInt64 = 41
        mutating func next() -> UInt64 { state = state &* 6_364_136_223_846_793_005 &+ 1; return state }
    }
    struct Embedder: SpeakerEmbedder {
        let modelID = "fixture-calibrated"
        let dimension = 2
        let output: [Float]
        func embed(_ pcm16k: [Float]) async throws -> [Float] { #expect(pcm16k.count == 48_000); return output }
    }
    private var now: Date { Date(timeIntervalSince1970: 1_793_275_200) }
    private var wav: Data { VoiceLabRequestFixtures.wav(rate: 16_000, frames: 80_000, fill: 4_000) }
    private func fixtureRecord(wav: Data) throws -> VoiceConsentRecord {
        var json = try #require(JSONSerialization.jsonObject(with: FixtureLoader.data("fixtures/voice-lab/consent-record.json")) as? [String: Any])
        var statement = try #require(json["statement"] as? [String: Any]); statement["audioSha256"] = VoiceLabFingerprint.bytes(wav); json["statement"] = statement
        return try JSONDecoder().decode(VoiceConsentRecord.self, from: JSONSerialization.data(withJSONObject: json))
    }
    private func statement() throws -> VoiceConsentStatement {
        let record = try fixtureRecord(wav: wav)
        return .init(language: record.statement.language, text: record.statement.text, nonce: record.statement.nonce)
    }
    private func raw() async throws -> RawTranscript {
        let base = SpeechStubHTTP.register { _ in Issue.record("Response mapping must not use HTTP"); return (500, [:], Data()) }
        let adapter = ElevenLabsTranscriber(keys: SpeechTestKeys(value: nil), session: URLSession(configuration: SpeechStubHTTP.configuration(for: base)), catalog: try SpeechTestFiles.catalog())
        return try await adapter.mapResponse(FixtureLoader.data("fixtures/voice-lab/consent-scribe.json"), diarize: false)
    }
    private func client(_ calls: ConsentRequestLog, deletionStatus: Int = 200, verificationRequired: Bool = false) -> ElevenLabsVoiceLab {
        let base = SpeechStubHTTP.register { request in
            let path = request.url?.path ?? ""
            calls.value.withLock { $0.append((request.httpMethod ?? "") + " " + path) }
            switch path {
            case "/v1/user/subscription": return (200, [:], Data(#"{"tier":"starter","status":"active","character_count":0,"character_limit":1000,"can_use_instant_voice_cloning":true,"voice_slots_used":0,"voice_limit":3}"#.utf8))
            case "/v1/voices/add":
                #expect(request.httpMethod == "POST")
                #expect(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data") == true)
                let body = try VoiceLabRequestFixtures.body(request)
                let text = String(decoding: body, as: UTF8.self)
                #expect(text.contains("consent-statement.wav")); #expect(text.contains("VoxClip own-voice clone. Consent sha256:"))
                return (200, [:], Data("{\"voice_id\":\"fixtureOwnVoice\",\"requires_verification\":\(verificationRequired)}".utf8))
            case "/v1/voices/fixtureOwnVoice":
                #expect(request.httpMethod == "DELETE")
                return (deletionStatus, [:], Data(#"{"status":"ok"}"#.utf8))
            default: Issue.record("Unexpected request"); return (500, [:], Data())
            }
        }
        return ElevenLabsVoiceLab(keys: SpeechTestKeys(value: "synthetic-consent-key"), session: URLSession(configuration: SpeechStubHTTP.configuration(for: base)), prices: VoiceLabPricingTests.catalogIfPresent)
    }
    private func storage(_ root: URL) -> VoiceConsentStore { VoiceConsentStore(locations: SpeechTestFiles.locations(root)) }
    private func enroll(store: VoiceConsentStore, client: ElevenLabsVoiceLab, check: VoiceSpeakerCheck, raw: RawTranscript, calls: ConsentTranscriptionCount = ConsentTranscriptionCount()) -> VoiceEnrollment {
        VoiceEnrollment(store: store, client: client, speaker: check) { _, language in
            calls.value.withLock { $0 += 1 }; #expect(language == "en"); return raw
        }
    }
    private var attestations: VoiceConsentRecord.Attestations { .init(ownVoice: true, adult: true, ownVideosOnly: true, acceptedAt: now) }
    private func training() -> [VoiceTrainingSample] {
        let audio = VoiceLabRequestFixtures.wav(rate: 16_000, frames: 240_000, fill: 4_000)
        return (0..<4).map { _ in .init(wav: audio, speech16k: [], seconds: 15, source: "readAloud", snrDb: 25) }
    }

    @Test func nonceIsDeterministicAndWithoutReplacement() throws {
        let shared = SharedResources(root: try FixtureLoader.sharedRoot())
        let text = try VoiceConsentText(shared: shared)
        let words = try String(contentsOf: shared.root.appendingPathComponent("voice-lab/nonce-words-en.txt"), encoding: .utf8).split(whereSeparator: \.isWhitespace).map(String.init)
        var first = FixedRNG(); var second = FixedRNG()
        let calendar = Calendar(identifier: .gregorian)
        let left = try text.statement(name: "  Example  ", language: "en", date: now, calendar: calendar, words: words, rng: &first)
        let right = try text.statement(name: "Example", language: "en", date: now, calendar: calendar, words: words, rng: &second)
        #expect(left == right); #expect(Set(left.nonce).count == 4); #expect(left.text.hasPrefix("My name is Example."))
    }
    @Test(arguments: ["en", "et"]) func sharedWordsAndDates(language: String) throws {
        let shared = SharedResources(root: try FixtureLoader.sharedRoot())
        let text = try VoiceConsentText(shared: shared)
        let words = try String(contentsOf: shared.root.appendingPathComponent("voice-lab/nonce-words-\(language).txt"), encoding: .utf8).split(whereSeparator: \.isWhitespace).map(String.init)
        var rng = FixedRNG()
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = calendar.date(from: DateComponents(year: 2026, month: 10, day: 29))!
        let statement = try text.statement(name: "Example", language: language, date: date, calendar: calendar, words: words, rng: &rng)
        #expect(words.count >= 500 && Set(words).count == words.count)
        #expect(statement.text.contains(language == "en" ? "29 October 2026" : "29. oktoober 2026"))
        #expect(statement.nonce.allSatisfy(words.contains))
        let script = try String(contentsOf: shared.root.appendingPathComponent("voice-lab/scripts-\(language).txt"), encoding: .utf8)
        #expect(script.split(whereSeparator: \.isWhitespace).count >= 150)
    }
    @Test func namesUseScalarsAndTrimBeforeControls() throws {
        #expect(try VoiceConsentText.displayName("\u{85} Name\n") == "Name")
        #expect(try VoiceConsentText.displayName("A\u{200B}") == "A\u{200B}")
        #expect(throws: VoiceConsentError.invalidName) { try VoiceConsentText.displayName(String(repeating: "o\u{303}", count: 31)) }
        #expect(throws: VoiceConsentError.invalidName) { try VoiceConsentText.displayName("A\nB") }
        #expect(throws: VoiceConsentError.invalidName) { try VoiceConsentText.displayName(" ") }
    }
    @Test func recordedScribeResponseMatches() async throws {
        let match = try VoiceStatementMatch.verify(await raw(), statement: statement())
        #expect(match.wer == 0); #expect(match.transcriptionId == "fixture-consent-response")
    }
    @Test func matchingRejectsLanguageNonceAndExcessErrors() async throws {
        let statement = try statement()
        var transcript = try await raw(); transcript.language = "et"
        #expect(throws: VoiceConsentError.statementMismatch) { try VoiceStatementMatch.verify(transcript, statement: statement) }
        transcript = try await raw(); transcript.tokens.removeLast()
        #expect(throws: VoiceConsentError.statementMismatch) { try VoiceStatementMatch.verify(transcript, statement: statement) }
        transcript = try await raw(); transcript.tokens = Array(transcript.tokens.suffix(4))
        #expect(throws: VoiceConsentError.statementMismatch) { try VoiceStatementMatch.verify(transcript, statement: statement) }
    }
    @Test func recordRoundTripKeepsNullAndSchema() async throws {
        let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = storage(root); let record = try fixtureRecord(wav: wav)
        try await store.saveStatement(wav, recordID: record.id); try await store.save(record)
        #expect(try await store.load(record.id) == record)
        #expect(try await store.activeVoices().count == 1)
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        #expect(json["deletedAt"] is NSNull); #expect(json["schema"] as? String == "voxclip-consent/1")
        #expect(json["statement"] != nil && json["speaker"] != nil && json["attestations"] != nil)
    }
    @Test(.enabled(if: SchemaPython.enabled, SchemaPython.skipReason))
    func encodedRecordAndSharedStatementsMatchSchemas() throws {
        let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let record = try fixtureRecord(wav: wav)
        let file = root.appendingPathComponent("record.json")
        try JSONEncoder().encode(record).write(to: file)
        try SchemaPython.validate([file, FixtureLoader.sharedRoot().appendingPathComponent("voice-lab/statements.json")])
    }
    @Test func storeRefusesAlteredAudio() async throws {
        let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = storage(root); let record = try fixtureRecord(wav: wav)
        try await store.saveStatement(wav, recordID: record.id); try await store.save(record)
        var altered = wav; altered[altered.count - 1] ^= 1
        try await store.saveStatement(altered, recordID: record.id)
        await #expect(throws: VoiceConsentError.invalidRecord) { try await store.load(record.id) }
    }
    @Test func storeRejectsPathTraversalAndLinks() async throws {
        let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = storage(root)
        await #expect(throws: VoiceConsentError.invalidRecord) { try await store.saveStatement(wav, recordID: "../outside") }
        try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
        let id = UUID().uuidString
        try FileManager.default.createSymbolicLink(at: store.root.appendingPathComponent(id), withDestinationURL: root)
        await #expect(throws: VoiceConsentError.invalidRecord) { try await store.saveStatement(wav, recordID: id) }
    }
    @Test func noUploadWithoutConsentAttestationsAndGate() async throws {
        let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let calls = ConsentRequestLog(); let transcriptions = ConsentTranscriptionCount()
        let service = enroll(store: storage(root), client: client(calls), check: .init(), raw: try await raw(), calls: transcriptions)
        let id = UUID().uuidString; let statement = try statement()
        await #expect(throws: VoiceLabError.consentRequired) { try await service.verify(recordID: id, statement: statement, wav: wav, attestations: attestations, approved: false, enabled: true) }
        await #expect(throws: VoiceLabError.consentRequired) { try await service.verify(recordID: id, statement: statement, wav: wav, attestations: attestations, approved: true, enabled: false) }
        let incomplete = VoiceConsentRecord.Attestations(ownVoice: true, adult: false, ownVideosOnly: true, acceptedAt: now)
        await #expect(throws: VoiceConsentError.attestationsRequired) { try await service.verify(recordID: id, statement: statement, wav: wav, attestations: incomplete, approved: true, enabled: true) }
        #expect(transcriptions.value.withLock { $0 } == 0); #expect(calls.value.withLock { $0.isEmpty })
    }
    @Test func threeAttemptsPerTenMinutes() async throws {
        let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let calls = ConsentRequestLog(); let transcriptions = ConsentTranscriptionCount()
        let service = enroll(store: storage(root), client: client(calls), check: .init(), raw: try await raw(), calls: transcriptions)
        let id = UUID().uuidString; let statement = try statement()
        for _ in 0..<3 { try await service.verify(recordID: id, statement: statement, wav: wav, attestations: attestations, approved: true, enabled: true, now: now) }
        await #expect(throws: VoiceConsentError.tooManyAttempts) { try await service.verify(recordID: id, statement: statement, wav: wav, attestations: attestations, approved: true, enabled: true, now: now.addingTimeInterval(599)) }
        try await service.verify(recordID: id, statement: statement, wav: wav, attestations: attestations, approved: true, enabled: true, now: now.addingTimeInterval(600))
        #expect(transcriptions.value.withLock { $0 } == 4)
    }
    @Test func unavailableSpeakerNeverCreates() async throws {
        let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let calls = ConsentRequestLog()
        let service = enroll(store: storage(root), client: client(calls), check: .init(embedder: Embedder(output: [1, 0])), raw: try await raw())
        let id = UUID().uuidString
        try await service.verify(recordID: id, statement: statement(), wav: wav, attestations: attestations, approved: true, enabled: true)
        await #expect(throws: VoiceConsentError.speakerUnavailable) { try await service.prepare(recordID: id, displayName: "Example", samples: training(), enabled: true) }
        #expect(calls.value.withLock { $0.isEmpty })
    }
    @Test func mismatchedSpeakerNeverUploadsSamples() async throws {
        let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let calls = ConsentRequestLog(); let store = storage(root); let client = client(calls)
        _ = try await client.plan()
        let check = VoiceSpeakerCheck(embedder: LengthEmbedding(), calibratedThreshold: 0.8)
        let service = enroll(store: store, client: client, check: check, raw: try await raw())
        let id = UUID().uuidString
        try await service.verify(recordID: id, statement: statement(), wav: wav, attestations: attestations, approved: true, enabled: true)
        let silent = VoiceLabRequestFixtures.wav(rate: 16_000, frames: 240_000)
        let samples = (0..<4).map { _ in VoiceTrainingSample(wav: silent, speech16k: [], seconds: 15, source: "readAloud", snrDb: 25) }
        await #expect(throws: VoiceConsentError.speakerMismatch) { try await service.prepare(recordID: id, displayName: "Example", samples: samples, enabled: true) }
        #expect(calls.value.withLock { $0 } == ["GET /v1/user/subscription"])
    }
    struct LengthEmbedding: SpeakerEmbedder {
        let modelID = "fixture-calibrated"
        let dimension = 2
        func embed(_ pcm16k: [Float]) async throws -> [Float] { [1, 0] }
    }
    private struct SignEmbedding: SpeakerEmbedder {
        let modelID = "fixture-calibrated"
        let dimension = 2
        let present: SpeakerAvailability
        func embed(_ pcm16k: [Float]) async throws -> [Float] { pcm16k[0] > 0 ? [1, 0] : [0, 1] }
        func validateAvailability() async throws { if !present.value.withLock({ $0 }) { throw VoiceConsentError.speakerUnavailable } }
    }
    @Test(arguments: [5, 10]) func filteringDropsOtherSpeakersAndEnforcesTenSeconds(acceptedSeconds: Int) async throws {
        let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let calls = ConsentRequestLog(); let store = storage(root); let client = client(calls)
        _ = try await client.plan()
        let check = VoiceSpeakerCheck(embedder: SignEmbedding(present: SpeakerAvailability()), calibratedThreshold: 0.8)
        let service = enroll(store: store, client: client, check: check, raw: try await raw())
        let id = UUID().uuidString
        try await service.verify(recordID: id, statement: statement(), wav: wav, attestations: attestations, approved: true, enabled: true)
        let good = VoiceLabRequestFixtures.wav(rate: 16_000, frames: acceptedSeconds * 16_000, fill: 4_000)
        let badFrames = (60 - acceptedSeconds) * 8_000
        let bad = VoiceLabRequestFixtures.wav(rate: 16_000, frames: badFrames, fill: -4_000)
        let samples = [VoiceTrainingSample(wav: good, speech16k: [], seconds: Double(acceptedSeconds), source: "readAloud", snrDb: 25)] + (0..<2).map { _ in VoiceTrainingSample(wav: bad, speech16k: [], seconds: Double(badFrames) / 16_000, source: "readAloud", snrDb: 25) }
        if acceptedSeconds < 10 {
            await #expect(throws: VoiceConsentError.speakerMismatch) { try await service.prepare(recordID: id, displayName: "Example", samples: samples, enabled: true) }
            #expect(calls.value.withLock { !$0.contains("POST /v1/voices/add") })
        } else {
            let quote = try await service.prepare(recordID: id, displayName: "Example", samples: samples, enabled: true)
            let record = try await service.create(quote: quote, approved: true, enabled: true, appVersion: "0.1.0")
            #expect(record.samples.count == 1)
            #expect(record.samples[0].seconds == 10)
        }
    }
    @Test func cachedGuardStillRequiresInstalledModel() async throws {
        let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = storage(root); let record = try fixtureRecord(wav: wav)
        try await store.saveStatement(wav, recordID: record.id); try await store.save(record)
        let present = SpeakerAvailability()
        let checker = SignEmbedding(present: present)
        let service = VoiceUseGuard(store: store, check: .init(embedder: checker, calibratedThreshold: 0.8))
        let audio = [Float](repeating: 0.1, count: 160_000)
        _ = try await service.authorize(contentKey: "content", recordID: record.id, speech16k: audio, approved: true)
        present.value.withLock { $0 = false }
        await #expect(throws: VoiceConsentError.speakerUnavailable) { try await service.authorize(contentKey: "content", recordID: record.id, speech16k: audio, approved: true) }
    }
    @Test func removedModelRefusesPreparedCloneBeforeUpload() async throws {
        let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let calls = ConsentRequestLog(); let store = storage(root); let client = client(calls)
        _ = try await client.plan()
        let present = SpeakerAvailability()
        let check = VoiceSpeakerCheck(embedder: SignEmbedding(present: present), calibratedThreshold: 0.8)
        let service = enroll(store: store, client: client, check: check, raw: try await raw())
        let id = UUID().uuidString
        try await service.verify(recordID: id, statement: statement(), wav: wav, attestations: attestations, approved: true, enabled: true)
        let quote = try await service.prepare(recordID: id, displayName: "Example", samples: training(), enabled: true)
        present.value.withLock { $0 = false }
        await #expect(throws: VoiceConsentError.speakerUnavailable) { try await service.create(quote: quote, approved: true, enabled: true, appVersion: "0.1.0") }
        #expect(calls.value.withLock { !$0.contains("POST /v1/voices/add") })
    }
    @Test func pendingVerificationOnlyActivatesOwnedVerifiedClone() async throws {
        let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = storage(root)
        var record = try fixtureRecord(wav: wav); record.status = .verificationRequired
        try await store.saveStatement(wav, recordID: record.id); try await store.save(record)
        let unowned = VoiceLabVoice(id: record.voiceId, name: "Other", category: "cloned", isOwner: false, requiresVerification: true, isVerified: true)
        try await store.refreshVerification([unowned])
        #expect(try await store.activeVoices().isEmpty)
        let owned = VoiceLabVoice(id: record.voiceId, name: "Mine", category: "cloned", isOwner: true, requiresVerification: true, isVerified: true)
        try await store.refreshVerification([owned])
        #expect(try await store.activeVoices().count == 1)
    }
    @Test func cancelledDeletionPreservesRecordAndMakesNoRequest() async throws {
        let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = storage(root); let record = try fixtureRecord(wav: wav); let calls = ConsentRequestLog()
        try await store.saveStatement(wav, recordID: record.id); try await store.save(record)
        let service = enroll(store: store, client: client(calls), check: .init(), raw: try await raw())
        await #expect(throws: VoiceLabError.consentRequired) { try await service.delete(recordID: record.id, approved: false, enabled: true) }
        #expect(calls.value.withLock { $0.isEmpty })
        #expect(try await store.load(record.id) == record)
    }
    @Test(arguments: [false, true]) func createAndDeleteUseExistingIVC(verificationRequired: Bool) async throws {
        let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let calls = ConsentRequestLog(); let store = storage(root); let client = client(calls, verificationRequired: verificationRequired)
        _ = try await client.plan()
        let check = VoiceSpeakerCheck(embedder: Embedder(output: [1, 0]), calibratedThreshold: 0.8)
        let service = enroll(store: store, client: client, check: check, raw: try await raw())
        let id = UUID().uuidString
        try await service.verify(recordID: id, statement: statement(), wav: wav, attestations: attestations, approved: true, enabled: true)
        let quote = try await service.prepare(recordID: id, displayName: "Example", samples: training(), enabled: true, now: now)
        await #expect(throws: VoiceLabError.consentRequired) { try await service.create(quote: quote, approved: false, enabled: true, appVersion: "0.1.0") }
        let record = try await service.create(quote: quote, approved: true, enabled: true, appVersion: "0.1.0")
        #expect(record.status == (verificationRequired ? .verificationRequired : .active))
        #expect(try await store.load(id) == record); #expect(record.samples.count == 4)
        #expect(try await store.activeVoices().count == (verificationRequired ? 0 : 1))
        try await service.delete(recordID: id, approved: true, enabled: true, now: now)
        let deleted = try await store.load(id)
        #expect(deleted.status == .deleted && deleted.deletedAt != nil && deleted.samples == record.samples)
        #expect(!FileManager.default.fileExists(atPath: store.root.appendingPathComponent(id + "/statement.wav").path))
        #expect(calls.value.withLock { $0 } == ["GET /v1/user/subscription", "POST /v1/voices/add", "DELETE /v1/voices/fixtureOwnVoice"])
    }
    @Test(arguments: [404, 500]) func deletionHandlesMissingAndFailure(status: Int) async throws {
        let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = storage(root); let record = try fixtureRecord(wav: wav); let calls = ConsentRequestLog()
        try await store.saveStatement(wav, recordID: record.id); try await store.save(record)
        let service = enroll(store: store, client: client(calls, deletionStatus: status), check: .init(), raw: try await raw())
        if status == 404 {
            try await service.delete(recordID: record.id, approved: true, enabled: true)
            #expect(try await store.load(record.id).status == .deleted)
        } else {
            await #expect(throws: VoiceLabError.providerFailure(500)) { try await service.delete(recordID: record.id, approved: true, enabled: true) }
            #expect(try await store.load(record.id).status == .active)
            #expect(try await store.statement(recordID: record.id) == wav)
        }
    }
    @Test func paidCreateSaveFailureRetriesLocallyWithoutAnotherClone() async throws {
        let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let calls = ConsentRequestLog(); let store = storage(root); let client = client(calls)
        _ = try await client.plan()
        let service = enroll(store: store, client: client, check: .init(embedder: Embedder(output: [1, 0]), calibratedThreshold: 0.8), raw: try await raw())
        let id = UUID().uuidString
        try await service.verify(recordID: id, statement: statement(), wav: wav, attestations: attestations, approved: true, enabled: true)
        let quote = try await service.prepare(recordID: id, displayName: "Example", samples: training(), enabled: true)
        let obstructed = store.root.appendingPathComponent(id + "/record.json", isDirectory: true)
        try FileManager.default.createDirectory(at: obstructed, withIntermediateDirectories: true)
        do {
            _ = try await service.create(quote: quote, approved: true, enabled: true, appVersion: "0.1.0")
            Issue.record("Expected a recoverable local save failure")
        } catch let error as VoiceConsentSaveError {
            #expect(error.record.voiceId == "fixtureOwnVoice")
            try FileManager.default.removeItem(at: obstructed)
            try await store.save(error.record)
            #expect(try await store.load(id) == error.record)
        }
        await #expect(throws: VoiceLabError.invalidInput) { try await service.create(quote: quote, approved: true, enabled: true, appVersion: "0.1.0") }
        #expect(calls.value.withLock { $0.filter { $0.hasPrefix("POST") }.count } == 1)
    }
    @Test func useTimeGuardAndDeletedCache() async throws {
        let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = storage(root); let record = try fixtureRecord(wav: wav)
        try await store.saveStatement(wav, recordID: record.id); try await store.save(record)
        let check = VoiceSpeakerCheck(embedder: Embedder(output: [1, 0]), calibratedThreshold: 0.8)
        let guardService = VoiceUseGuard(store: store, check: check)
        let audio = [Float](repeating: 0.1, count: 160_000)
        let policy = try await guardService.authorize(contentKey: "content", recordID: record.id, speech16k: audio, approved: true)
        try policy.validate()
        await #expect(throws: VoiceLabError.consentRequired) { try await guardService.authorize(contentKey: "content", recordID: record.id, speech16k: audio, approved: false) }
        try await store.markDeleted(record.id, at: now)
        await #expect(throws: VoiceConsentError.inactive) { try await guardService.authorize(contentKey: "content", recordID: record.id, speech16k: audio, approved: true) }
    }
    @Test func useTimeGuardRefusesDifferentSpeakerAndUncalibrated() async throws {
        let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = storage(root); let record = try fixtureRecord(wav: wav)
        try await store.saveStatement(wav, recordID: record.id); try await store.save(record)
        let audio = [Float](repeating: 0.1, count: 160_000)
        let missing = VoiceUseGuard(store: store)
        await #expect(throws: VoiceConsentError.speakerUnavailable) { try await missing.authorize(contentKey: "content", recordID: record.id, speech16k: audio, approved: true) }
        let other = VoiceUseGuard(store: store, check: .init(embedder: Embedder(output: [0, 1]), calibratedThreshold: 0.8))
        await #expect(throws: (any Error).self) { try await other.authorize(contentKey: "content", recordID: record.id, speech16k: audio, approved: true) }
    }
    @Test func betaGateAndSettingsValidation() throws {
        #expect(!VoiceLabGate.settingsVisible(enabled: false, internalBuild: false))
        #expect(VoiceLabGate.settingsVisible(enabled: false, internalBuild: true))
        #expect(VoiceLabGate.settingsVisible(enabled: true, internalBuild: false))
        #expect(!VoiceLabGate.canEnroll(enabled: true, busy: true))
        #expect(!VoiceLabGate.canEnroll(enabled: false, busy: false))
        #expect(VoiceLabGate.canEnroll(enabled: true, busy: false))
        try SettingsDocument(values: ["voiceLab.labelPosition": .string("bottom-left"), "voiceLab.c2pa": .bool(false)]).validate()
        #expect(throws: (any Error).self) { try SettingsDocument(values: ["voiceLab.labelPosition": .string("off")]).validate() }
    }
}
