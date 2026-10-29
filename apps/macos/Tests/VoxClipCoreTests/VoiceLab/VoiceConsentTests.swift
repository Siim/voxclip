#if DEBUG
import Foundation
import Synchronization
import Testing
@_spi(Testing) @testable import VoxClipCore
@_spi(Testing) @testable import VoxClipMedia

private final class ConsentRequestLog: Sendable { let value = Mutex<[String]>([]) }
private final class ConsentTranscriptionCount: Sendable { let value = Mutex(0) }
private final class SpeakerAvailability: Sendable { let value = Mutex(true) }
private final class OperationRemote: Sendable {
    struct State { var present = false; var lists = 0; var posts = 0; var deletes = 0; var listFailure = false }
    let value = Mutex(State())
}
private final class OperationClock: Sendable {
    let value: Mutex<Date>
    init(_ date: Date) { value = Mutex(date) }
    func now() -> Date { value.withLock { $0 } }
    func advance(_ seconds: Double) { value.withLock { $0.addTimeInterval(seconds) } }
}

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
    private func client(_ calls: ConsentRequestLog, deletionStatus: Int = 200, verificationRequired: Bool = false, enforceCapabilities: Bool = true) -> ElevenLabsVoiceLab {
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
        return ElevenLabsVoiceLab(keys: SpeechTestKeys(value: "synthetic-consent-key"), session: URLSession(configuration: SpeechStubHTTP.configuration(for: base)), prices: VoiceLabPricingTests.catalogIfPresent, enforceCapabilities: enforceCapabilities)
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
    @Test(arguments: [VoiceConsentCheckpoint.deletionIntent, .remoteDeleted, .removeStatement, .audioRemoved, .tombstoneRecord, .saveTombstone, .clearDeletion]) func deletionResumesEveryDurableBoundary(step: VoiceConsentCheckpoint) async throws {
        let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = VoiceConsentStore(locations: SpeechTestFiles.locations(root), fault: { checkpoint in
            if checkpoint == step { throw CocoaError(.fileWriteUnknown) }
        })
        let record = try fixtureRecord(wav: wav); let calls = ConsentRequestLog()
        try await store.saveStatement(wav, recordID: record.id); try await store.save(record)
        let service = enroll(store: store, client: client(calls), check: .init(), raw: try await raw())
        await #expect(throws: (any Error).self) { try await service.delete(recordID: record.id, approved: true, enabled: true, now: now) }
        #expect(try await store.records().count == 1)
        if step != .deletionIntent { #expect(try await store.activeVoices().isEmpty) }
        let restarted = storage(root)
        let retry = client(calls, deletionStatus: 404)
        if step == .deletionIntent {
            _ = try await restarted.beginDeletion(record.id, region: .default, at: now)
        }
        try await VoiceOperationReconciler(store: restarted, client: retry).reconcile(force: true)
        let deleted = try await restarted.load(record.id)
        #expect(deleted.status == .deleted)
        #expect(deleted.samples == record.samples && deleted.statement.audioSha256 == record.statement.audioSha256)
        #expect(try await restarted.operations().filter { $0.kind == .delete && !$0.finished }.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: restarted.root.appendingPathComponent("\(record.id)/statement.wav").path))
        try await VoiceOperationReconciler(store: restarted, client: retry).reconcile(force: true)
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
            #expect(try await store.activeVoices().isEmpty)
            try await VoiceOperationReconciler(store: storage(root), client: client(calls, deletionStatus: 404)).reconcile(force: true)
            #expect(try await store.load(record.id).status == .deleted)
        }
    }
    @Test func paidCreateSaveFailureRetriesLocallyWithoutAnotherClone() async throws {
        let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let shouldFail = Mutex(true)
        let store = VoiceConsentStore(locations: SpeechTestFiles.locations(root), fault: { step in
            if step == .saveCreation && shouldFail.withLock({ $0 }) { throw CocoaError(.fileWriteUnknown) }
        })
        let calls = ConsentRequestLog(); let client = client(calls)
        _ = try await client.plan()
        let service = enroll(store: store, client: client, check: .init(embedder: Embedder(output: [1, 0]), calibratedThreshold: 0.8), raw: try await raw())
        let id = UUID().uuidString
        try await service.verify(recordID: id, statement: statement(), wav: wav, attestations: attestations, approved: true, enabled: true)
        let quote = try await service.prepare(recordID: id, displayName: "Example", samples: training(), enabled: true)
        do {
            _ = try await service.create(quote: quote, approved: true, enabled: true, appVersion: "0.1.0")
            Issue.record("Expected a recoverable local save failure")
        } catch let error as VoiceConsentSaveError {
            #expect(error.record.voiceId == "fixtureOwnVoice")
            shouldFail.withLock { $0 = false }
            try await VoiceOperationReconciler(store: store, client: client).reconcile(force: true)
            #expect(try await store.load(id) == error.record)
        }
        await #expect(throws: VoiceLabError.invalidInput) { try await service.create(quote: quote, approved: true, enabled: true, appVersion: "0.1.0") }
        #expect(calls.value.withLock { $0.filter { $0.hasPrefix("POST") }.count } == 1)
    }
    @Test(arguments: ["local-save", "timeout", "crash", "invalid-consent", "cancelled"]) func uncertainCreationReconcilesWithoutAnotherPost(mode: String) async throws {
        let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID().uuidString
        let calls = ConsentRequestLog(); let created = Mutex(false)
        let base = SpeechStubHTTP.register { request in
            let path = request.url?.path ?? ""
            calls.value.withLock { $0.append((request.httpMethod ?? "") + " " + path) }
            switch path {
            case "/v1/user/subscription": return (200, [:], Data(#"{"tier":"starter","status":"active","character_count":0,"character_limit":1000,"can_use_instant_voice_cloning":true,"voice_slots_used":0,"voice_limit":3}"#.utf8))
            case "/v1/voices/add":
                #expect(String(decoding: try VoiceLabRequestFixtures.body(request), as: UTF8.self).contains(id))
                created.withLock { $0 = true }
                if mode == "timeout" || mode == "invalid-consent" || mode == "cancelled" { throw URLError(.timedOut) }
                return (200, [:], Data(#"{"voice_id":"fixtureOwnVoice","requires_verification":false}"#.utf8))
            case "/v2/voices":
                let voice = "{\"voice_id\":\"fixtureOwnVoice\",\"name\":\"Example (VoxClip)\",\"category\":\"cloned\",\"is_owner\":true,\"labels\":{\"voxclip_record_id\":\"\(id)\"},\"voice_verification\":{\"is_verified\":true}}"
                return (200, [:], Data("{\"voices\":[\(created.withLock { $0 } ? voice : "")],\"has_more\":false}".utf8))
            case "/v1/voices/fixtureOwnVoice":
                created.withLock { $0 = false }; return (200, [:], Data(#"{"status":"ok"}"#.utf8))
            default: Issue.record("Unexpected recovery request"); return (500, [:], Data())
            }
        }
        let client = ElevenLabsVoiceLab(keys: SpeechTestKeys(value: "synthetic-recovery-key"), session: URLSession(configuration: SpeechStubHTTP.configuration(for: base)), prices: VoiceLabPricingTests.catalogIfPresent, enforceCapabilities: true)
        let store = VoiceConsentStore(locations: SpeechTestFiles.locations(root), fault: { step in
            if (mode == "local-save" && step == .saveCreation) || (mode == "crash" && step == .creationResult) { throw CocoaError(.fileWriteUnknown) }
        })
        _ = try await client.plan()
        let service = enroll(store: store, client: client, check: .init(embedder: Embedder(output: [1, 0]), calibratedThreshold: 0.8), raw: try await raw())
        try await service.verify(recordID: id, statement: statement(), wav: wav, attestations: attestations, approved: true, enabled: true)
        let quote = try await service.prepare(recordID: id, displayName: "Example", samples: training(), enabled: true)
        await #expect(throws: (any Error).self) { try await service.create(quote: quote, approved: true, enabled: true, appVersion: "0.1.0") }
        let restarted = storage(root)
        #expect(try await restarted.operations().filter { $0.kind == .create && !$0.finished }.count == 1)
        try await restarted.reconcileAbandonedEnrollments()
        if mode == "invalid-consent" { try await restarted.discardStatement(recordID: id) }
        if mode == "cancelled" {
            try await restarted.abandonEnrollment(recordID: id)
            #expect(!FileManager.default.fileExists(atPath: restarted.root.appendingPathComponent("\(id)/statement.wav").path))
        }
        try await VoiceOperationReconciler(store: restarted, client: client).reconcile(force: true)
        if mode == "local-save" { #expect(try await restarted.load(id).status == .active) }
        else { #expect(try await restarted.records().isEmpty) }
        #expect(try await restarted.operations().filter { $0.kind == .create && !$0.finished }.isEmpty)
        try await VoiceOperationReconciler(store: restarted, client: client).reconcile(force: true)
        #expect(calls.value.withLock { $0.filter { $0.hasPrefix("POST") }.count } == 1)
    }
    @Test func legacyClonePolicyCannotDispatch() async throws {
        let calls = ConsentRequestLog(); let client = client(calls)
        _ = try await client.plan()
        let policy = OwnVoicePolicy(recordID: UUID().uuidString, recordActive: true, providerConsentGranted: true, statementVerified: true, speakerMatched: true)
        let request = VoiceLabCloneRequest(displayName: "Example", language: "en", samples: [.init(role: .consentStatement, wav: wav), .init(role: .training, wav: wav)], createdAt: now, removeBackgroundNoise: false)
        let quote = try await client.prepareClone(request, policy: policy, requestID: UUID())
        await #expect(throws: VoiceLabError.consentRequired) {
            try await client.createOwnClone(request, policy: policy, requestID: quote.requestID, authorization: .init(quote: quote, approved: true))
        }
        #expect(calls.value.withLock { $0.filter { $0.hasPrefix("POST") }.isEmpty })
    }
    @Test(arguments: ["forged", "stale", "changed", "model-removed", "deleting", "valid-replay", "conversion-input"]) func dispatchRequiresCurrentOperationCapability(mode: String) async throws {
        let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = storage(root); let record = try fixtureRecord(wav: wav); let calls = ConsentRequestLog()
        try await store.saveStatement(wav, recordID: record.id); try await store.save(record)
        let base = SpeechStubHTTP.register { request in
            let path = request.url?.path ?? ""
            calls.value.withLock { $0.append((request.httpMethod ?? "") + " " + path) }
            switch path {
            case "/v1/models": return (200, [:], Data(#"[{"model_id":"speaker_tts","can_do_text_to_speech":true,"can_do_voice_conversion":true,"languages":[{"language_id":"en"}]}]"#.utf8))
            case "/v2/voices": return (200, [:], Data(#"{"voices":[{"voice_id":"fixtureOwnVoice","name":"Example","category":"cloned","is_owner":true,"voice_verification":{"is_verified":true}}],"has_more":false}"#.utf8))
            case "/v1/text-to-speech/fixtureOwnVoice/with-timestamps":
                let pcm = Data(repeating: 0, count: 4_800).base64EncodedString()
                return (200, [:], Data("{\"audio_base64\":\"\(pcm)\",\"alignment\":{\"characters\":[\"H\",\"i\"],\"character_start_times_seconds\":[0,0.02],\"character_end_times_seconds\":[0.02,0.04]}}".utf8))
            default: Issue.record("Unexpected capability request"); return (500, [:], Data())
            }
        }
        let client = ElevenLabsVoiceLab(keys: SpeechTestKeys(value: "synthetic-capability-key"), session: URLSession(configuration: SpeechStubHTTP.configuration(for: base)), prices: VoiceLabPricingTests.catalogIfPresent, enforceCapabilities: true)
        _ = try await client.models(); _ = try await client.voices()
        let initial = OwnVoicePolicy(recordID: record.id, cloneVoiceID: record.voiceId, recordActive: true, providerConsentGranted: true, statementVerified: true, speakerMatched: true)
        let options = VoiceLabSpeechOptions(seed: 7)
        let voice = VoiceLabVoiceChoice.own(voiceID: record.voiceId, policy: initial)
        let quote = try await client.prepareSynthesis(text: "Hi", modelID: "speaker_tts", voice: voice, language: "en", options: options, requestID: UUID())
        let present = SpeakerAvailability()
        let guardService = VoiceUseGuard(store: store, check: .init(embedder: SignEmbedding(present: present), calibratedThreshold: 0.8))
        if mode == "conversion-input" {
            let conversion = try await client.prepareConversion(audio: wav, modelID: "speaker_tts", voice: voice, language: "en", seed: 7, cleanAudioOn: false, requestID: UUID())
            let changed = VoiceLabRequestFixtures.wav(rate: 16_000, frames: 80_000, fill: 8_000)
            await #expect(throws: VoiceLabError.consentRequired) { try await guardService.authorizeConversion(quote: conversion, contentKey: "source", recordID: record.id, audio: changed, approved: true) }
            return
        }
        let policy = mode == "forged" ? initial : try await guardService.authorize(quote: quote, contentKey: "source", recordID: record.id, speech16k: [Float](repeating: 0.1, count: 160_000), approved: true)
        let authorizedVoice = VoiceLabVoiceChoice.own(voiceID: record.voiceId, policy: policy)
        if mode == "stale" { try await store.markDeleted(record.id, at: now) }
        if mode == "deleting" { _ = try await store.beginDeletion(record.id, region: .default, at: now) }
        if mode == "model-removed" { present.value.withLock { $0 = false } }
        let dispatchQuote = mode == "changed" ? try await client.prepareSynthesis(text: "Hi", modelID: "speaker_tts", voice: voice, language: "en", options: options, requestID: UUID()) : quote
        let dispatch: @Sendable () async throws -> Void = {
            _ = try await client.synthesize(text: "Hi", modelID: "speaker_tts", voice: authorizedVoice, language: "en", options: options, requestID: dispatchQuote.requestID, authorization: .init(quote: dispatchQuote, approved: true))
        }
        if mode == "valid-replay" {
            try await dispatch()
            await #expect(throws: (any Error).self) { try await dispatch() }
            #expect(calls.value.withLock { $0.filter { $0.hasPrefix("POST") }.count } == 1)
        } else {
            await #expect(throws: (any Error).self) { try await dispatch() }
            #expect(calls.value.withLock { $0.filter { $0.hasPrefix("POST") }.isEmpty })
        }
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
    @Test(arguments: ["recorded", "verified", "training", "quoted"]) func cancellationRemovesUncommittedStatement(step: String) async throws {
        let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = storage(root)
        let id = UUID().uuidString.lowercased()
        try await store.saveStatement(wav, recordID: id)
        if step != "recorded" {
            let transport = client(ConsentRequestLog())
            _ = try await transport.plan()
            let service = enroll(store: store, client: transport, check: .init(embedder: Embedder(output: [1, 0]), calibratedThreshold: 0.8), raw: try await raw())
            try await service.verify(recordID: id, statement: statement(), wav: wav, attestations: attestations, approved: true, enabled: true)
            if step == "quoted" { _ = try await service.prepare(recordID: id, displayName: "Example", samples: training(), enabled: true) }
            try await service.cancel(recordID: id)
        }
        try await store.abandonEnrollment(recordID: id)
        #expect(!FileManager.default.fileExists(atPath: store.root.appendingPathComponent("\(id)/statement.wav").path))
    }
    @Test func startupRemovesCrashFilesButPreservesDurableAndLiveStatements() async throws {
        let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let locations = SpeechTestFiles.locations(root)
        let store = storage(root); let record = try fixtureRecord(wav: wav)
        try await store.saveStatement(wav, recordID: record.id); try await store.save(record)
        let abandoned = UUID().uuidString.lowercased()
        try await store.saveStatement(wav, recordID: abandoned)
        let temporary = locations.cache.appendingPathComponent("voice-consent/stale")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        try wav.write(to: temporary.appendingPathComponent("statement.wav"))
        let restarted = storage(root)
        let live = UUID().uuidString.lowercased(); try await restarted.saveStatement(wav, recordID: live)
        try await restarted.reconcileAbandonedEnrollments()
        #expect(try await restarted.statement(recordID: record.id) == wav)
        #expect(try await restarted.statement(recordID: live) == wav)
        #expect(!FileManager.default.fileExists(atPath: temporary.path))
        #expect(!FileManager.default.fileExists(atPath: store.root.appendingPathComponent(abandoned).path))
        try await restarted.abandonEnrollment(recordID: record.id)
        #expect(try await restarted.statement(recordID: record.id) == wav)
        let current = locations.cache.appendingPathComponent("voice-consent/current")
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        try wav.write(to: current.appendingPathComponent("statement.wav"))
        try await restarted.reconcileAbandonedEnrollments()
        #expect(FileManager.default.fileExists(atPath: current.appendingPathComponent("statement.wav").path))
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

extension VoiceConsentTests {
    private func operationClient(_ remote: OperationRemote, nonce: String) -> ElevenLabsVoiceLab {
        let base = SpeechStubHTTP.register { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/v1/user/subscription"):
                return (200, [:], Data(#"{"tier":"starter","status":"active","character_count":0,"character_limit":1000,"can_use_instant_voice_cloning":true,"voice_slots_used":0,"voice_limit":3}"#.utf8))
            case ("POST", "/v1/voices/add"):
                remote.value.withLock { $0.posts += 1; $0.present = true }
                return (200, [:], Data(#"{"voice_id":"fixtureOwnVoice","requires_verification":false}"#.utf8))
            case ("GET", "/v2/voices"):
                let state = remote.value.withLock { $0.lists += 1; return $0 }
                if state.listFailure { return (500, [:], Data()) }
                let rows: [[String: Any]] = state.present ? [["voice_id": "fixtureOwnVoice", "name": "Example (VoxClip)", "category": "cloned", "is_owner": true, "labels": ["voxclip_record_id": nonce], "voice_verification": ["is_verified": true]]] : []
                return (200, [:], try JSONSerialization.data(withJSONObject: ["voices": rows, "has_more": false]))
            case ("DELETE", "/v1/voices/fixtureOwnVoice"):
                let existed = remote.value.withLock { state in state.deletes += 1; let present = state.present; state.present = false; return present }
                return (existed ? 200 : 404, [:], Data(#"{"status":"ok"}"#.utf8))
            default: Issue.record("Unexpected operation request"); return (500, [:], Data())
            }
        }
        return ElevenLabsVoiceLab(keys: SpeechTestKeys(value: "synthetic-journal-key"), session: URLSession(configuration: SpeechStubHTTP.configuration(for: base)), prices: VoiceLabPricingTests.catalogIfPresent, enforceCapabilities: true)
    }
    private func seedOperation(_ store: VoiceConsentStore, record: VoiceConsentRecord) async throws -> VoiceOperation {
        try await store.saveStatement(wav, recordID: record.id)
        return try await store.beginCreation(record: record.assigningVoice("pending", requiresVerification: true), requestID: UUID(), region: .default, at: now)
    }
    @Test(arguments: [VoiceConsentCheckpoint.saveDraft, .creationIntent, .creationDispatched, .creationResult, .saveRecord, .saveCreation, .clearCreation])
    func creationRestartsAtEveryWrite(step: VoiceConsentCheckpoint) async throws {
        let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let fired = Mutex(false)
        let store = VoiceConsentStore(locations: SpeechTestFiles.locations(root), fault: { checkpoint in
            if checkpoint == step { fired.withLock { $0 = true }; throw CocoaError(.fileWriteUnknown) }
        })
        let id = UUID().uuidString; let remote = OperationRemote(); let client = operationClient(remote, nonce: id)
        _ = try await client.plan()
        let service = enroll(store: store, client: client, check: .init(embedder: Embedder(output: [1, 0]), calibratedThreshold: 0.8), raw: try await raw())
        try await service.verify(recordID: id, statement: statement(), wav: wav, attestations: attestations, approved: true, enabled: true)
        let quote = try await service.prepare(recordID: id, displayName: "Example", samples: training(), enabled: true)
        await #expect(throws: (any Error).self) { try await service.create(quote: quote, approved: true, enabled: true, appVersion: "0.1.0") }
        #expect(fired.withLock { $0 })
        let restarted = storage(root)
        try await restarted.reconcileAbandonedEnrollments()
        let reconciler = VoiceOperationReconciler(store: restarted, client: client)
        try await reconciler.reconcile(force: true)
        try await reconciler.reconcile(force: true)
        #expect(try await restarted.operations().isEmpty)
        let shouldSave = [VoiceConsentCheckpoint.saveRecord, .saveCreation, .clearCreation].contains(step)
        if shouldSave {
            #expect(try await restarted.load(id).status == .active)
            #expect(try await restarted.statement(recordID: id) == wav)
        } else {
            #expect(!FileManager.default.fileExists(atPath: restarted.root.appendingPathComponent("\(id)/statement.wav").path))
            #expect(!remote.value.withLock { $0.present })
        }
        let expectedPosts = [VoiceConsentCheckpoint.saveDraft, .creationIntent, .creationDispatched].contains(step) ? 0 : 1
        #expect(remote.value.withLock { $0.posts } == expectedPosts)
    }
    @Test(arguments: [VoiceConsentCheckpoint.withdrawing, .removeStatement, .tombstoneRecord, .withdrawn, .clearCreation])
    func saveFailureWithdrawalRestartsAtEveryWrite(step: VoiceConsentCheckpoint) async throws {
        let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let record = try fixtureRecord(wav: wav); let initial = storage(root)
        let value = try await seedOperation(initial, record: record)
        _ = try await initial.transition(value.id, to: .dispatched, at: now)
        _ = try await initial.transition(value.id, to: .created, at: now, remoteVoiceID: record.voiceId, requiresVerification: false)
        let remote = OperationRemote(); remote.value.withLock { $0.present = true }
        let client = operationClient(remote, nonce: record.id)
        let fired = Mutex(false)
        let failing = VoiceConsentStore(locations: SpeechTestFiles.locations(root), fault: { checkpoint in
            if checkpoint == step { fired.withLock { $0 = true }; throw CocoaError(.fileWriteUnknown) }
        })
        do {
            try await failing.withdrawCreation(recordID: record.id)
            try await VoiceOperationReconciler(store: failing, client: client).reconcile(force: true)
        } catch {}
        #expect(fired.withLock { $0 })
        let restarted = storage(root)
        try await restarted.withdrawCreation(recordID: record.id)
        try await VoiceOperationReconciler(store: restarted, client: client).reconcile(force: true)
        #expect(try await restarted.operations().isEmpty)
        #expect(try await restarted.load(record.id).status == .deleted)
        #expect(!FileManager.default.fileExists(atPath: restarted.root.appendingPathComponent("\(record.id)/statement.wav").path))
        #expect(!remote.value.withLock { $0.present })
        #expect(remote.value.withLock { $0.posts } == 0)
    }
    @Test func emptyListThenLateAppearanceUsesBackoffWithoutKeepingAudio() async throws {
        let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = storage(root); let record = try fixtureRecord(wav: wav)
        let value = try await seedOperation(store, record: record)
        _ = try await store.transition(value.id, to: .dispatched, at: now)
        let remote = OperationRemote(); let clock = OperationClock(now)
        let reconciler = VoiceOperationReconciler(store: store, client: operationClient(remote, nonce: record.id), now: { clock.now() })
        try await reconciler.reconcile()
        #expect(try await store.operation(value.id).blocksCreation)
        #expect(!FileManager.default.fileExists(atPath: store.root.appendingPathComponent("\(record.id)/statement.wav").path))
        clock.advance(10); try await reconciler.reconcile()
        #expect(remote.value.withLock { $0.lists } == 1)
        remote.value.withLock { $0.present = true }
        clock.advance(21); try await reconciler.reconcile()
        #expect(try await store.operations().isEmpty)
        #expect(try await store.records().isEmpty)
        #expect(remote.value.withLock { $0.lists == 2 && $0.deletes == 1 && $0.posts == 0 && !$0.present })
    }
    @Test(arguments: [false, true]) func abandonmentIsBoundedEvenWhenListingFails(listFailure: Bool) async throws {
        let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = storage(root); let record = try fixtureRecord(wav: wav)
        let value = try await seedOperation(store, record: record)
        _ = try await store.transition(value.id, to: .dispatched, at: now)
        let remote = OperationRemote(); remote.value.withLock { $0.listFailure = listFailure }
        let clock = OperationClock(now.addingTimeInterval(24 * 60 * 60 + 1))
        let reconciler = VoiceOperationReconciler(store: store, client: operationClient(remote, nonce: record.id), now: { clock.now() })
        try await reconciler.reconcile()
        let abandoned = try await store.operation(value.id)
        #expect(abandoned.state == .abandoned && !abandoned.blocksCreation && abandoned.finished)
        #expect(!FileManager.default.fileExists(atPath: store.root.appendingPathComponent("\(record.id)/statement.wav").path))
        try await reconciler.reconcile(force: true)
        #expect(remote.value.withLock { $0.lists } == 1)
    }
    @Test func deletionJournalDoesNotDependOnARecordAndTreats404AsSuccess() async throws {
        let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = storage(root); let record = try fixtureRecord(wav: wav)
        try await store.saveStatement(wav, recordID: record.id); try await store.save(record)
        _ = try await store.beginDeletion(record.id, region: .default, at: now)
        try FileManager.default.removeItem(at: store.root.appendingPathComponent("\(record.id)/record.json"))
        let restarted = storage(root); let remote = OperationRemote()
        try await VoiceOperationReconciler(store: restarted, client: operationClient(remote, nonce: record.id)).reconcile(force: true)
        #expect(try await restarted.operations().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.root.appendingPathComponent("\(record.id)/statement.wav").path))
        #expect(remote.value.withLock { $0.deletes == 1 && $0.lists == 0 })
    }
    @Test func operationBlockingTransitionsAndJournalPrivacy() async throws {
        let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = storage(root); let record = try fixtureRecord(wav: wav)
        var value = try await seedOperation(store, record: record)
        #expect(!value.blocksCreation)
        value = try await store.transition(value.id, to: .dispatched, at: now)
        #expect(value.blocksCreation)
        value = try await store.transition(value.id, to: .created, at: now, remoteVoiceID: record.voiceId, requiresVerification: false)
        #expect(value.blocksCreation)
        value = try await store.transition(value.id, to: .withdrawing, at: now)
        #expect(!value.blocksCreation)
        await #expect(throws: VoiceConsentError.invalidRecord) { _ = try await store.transition(value.id, to: .dispatched, at: now) }
        let url = await store.operationsRoot.appendingPathComponent(value.id.uuidString + ".json")
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(object["record"] == nil && object["audio"] == nil && object["embedding"] == nil && object["statement"] == nil)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }
    @Test(arguments: [false, true]) func legacyDeletionWithoutARecordMigratesAndResumesIndependently(guardBeforeStartup: Bool) async throws {
        let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = storage(root); let record = try fixtureRecord(wav: wav)
        try await store.saveStatement(wav, recordID: record.id)
        var object: [String: Any] = ["region": "default", "requestedAt": now.timeIntervalSinceReferenceDate, "remoteDeleted": false]
        object["record"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record))
        let legacy = store.root.appendingPathComponent("\(record.id)/deletion.json")
        try JSONSerialization.data(withJSONObject: object).write(to: legacy)
        let restarted = storage(root)
        if guardBeforeStartup {
            await #expect(throws: VoiceConsentError.inactive) { try await restarted.validateUse(record) }
        }
        try await restarted.reconcileAbandonedEnrollments()
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        #expect(try await restarted.operations().count == 1)
        let remote = OperationRemote()
        try await VoiceOperationReconciler(store: restarted, client: operationClient(remote, nonce: record.id)).reconcile(force: true)
        #expect(try await restarted.load(record.id).status == .deleted)
        #expect(try await restarted.operations().isEmpty)
        #expect(remote.value.withLock { $0.deletes == 1 && $0.lists == 0 })
    }
    @Test(arguments: [VoiceConsentCheckpoint.removeDraft, .retryScheduled, .abandoned])
    func uncertaintyMetadataRestartsAtEveryWrite(step: VoiceConsentCheckpoint) async throws {
        let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let initial = storage(root); let record = try fixtureRecord(wav: wav)
        let value = try await seedOperation(initial, record: record)
        _ = try await initial.transition(value.id, to: .dispatched, at: now)
        let fired = Mutex(false)
        let failing = VoiceConsentStore(locations: SpeechTestFiles.locations(root), fault: { checkpoint in
            if checkpoint == step { fired.withLock { $0 = true }; throw CocoaError(.fileWriteUnknown) }
        })
        let clock = OperationClock(step == .abandoned ? now.addingTimeInterval(24 * 60 * 60) : now)
        let remote = OperationRemote(); let client = operationClient(remote, nonce: record.id)
        await #expect(throws: (any Error).self) { try await VoiceOperationReconciler(store: failing, client: client, now: { clock.now() }).reconcile() }
        #expect(fired.withLock { $0 })
        #expect(!FileManager.default.fileExists(atPath: initial.root.appendingPathComponent("\(record.id)/statement.wav").path))
        clock.advance(24 * 60 * 60 + 1)
        let restarted = storage(root)
        try await VoiceOperationReconciler(store: restarted, client: client, now: { clock.now() }).reconcile()
        #expect(try await restarted.operation(value.id).state == .abandoned)
        #expect(try await restarted.records().isEmpty)
    }
}
#endif
