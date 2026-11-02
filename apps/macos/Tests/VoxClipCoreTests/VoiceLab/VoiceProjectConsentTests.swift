#if DEBUG
import Foundation
import Testing
@testable import VoxClipCore

@Suite("Project-audio consent", .offlineFixtures)
struct VoiceProjectConsentTests {
    private let now = Date(timeIntervalSince1970: 1_793_275_200)

    private struct Fixture {
        let record: VoiceConsentRecord
        let request: VoiceLabCloneRequest
        let quote: EnrollmentQuote
        var reference: Data { request.samples[0].wav }
        var recovery: VoiceEnrollmentRecovery {
            .init(quote: quote, request: request, record: record, trainingSeconds: 30)
        }
    }

    private func quote(_ request: VoiceLabCloneRequest, consent: VoiceConsentRecord.ProjectConsent,
                       attestations: VoiceConsentRecord.Attestations) throws -> EnrollmentQuote {
        let create = VoiceLabQuote(id: UUID(), operation: .createClone, requestID: UUID(),
                                  estimate: .init(provider: "elevenlabs", operation: "createClone", units: 1,
                                                  unit: "voice", usd: 0, basis: "Synthetic test price"),
                                  region: .default, endpoint: "v1/voices/add", languageMode: .explicit(request.language),
                                  fingerprint: "synthetic-prepared-quote", preparedAt: now)
        return try EnrollmentQuote(create: create, request: request, projectConsent: consent, attestations: attestations)
    }

    private func fixture() throws -> Fixture {
        let recordID = UUID().uuidString
        let wavs = [1_000, 2_000].map { VoiceLabRequestFixtures.wav(rate: 8_000, frames: 120_000, fill: $0) }
        let consent = VoiceConsentRecord.ProjectConsent(language: "en", audioSha256: VoiceLabFingerprint.bytes(wavs[0]))
        let attestations = VoiceConsentRecord.Attestations(ownVoice: true, adult: true, ownVideosOnly: true, acceptedAt: now)
        let request = VoiceLabCloneRequest(displayName: "Example", language: "en", samples: wavs.map { .init(role: .training, wav: $0) },
                                          createdAt: now, removeBackgroundNoise: false, recoveryNonce: recordID)
        let record = VoiceConsentRecord(schema: "voxclip-consent/2", recordId: recordID, provider: "elevenlabs", type: "ivc",
                                        voiceId: "pending", voiceName: "Example (VoxClip)", status: .verificationRequired,
                                        createdAt: VoiceConsentRecord.timestamp(now), deletedAt: nil, statement: nil,
                                        attestations: attestations, samples: wavs.map {
                                            .init(sha256: VoiceLabFingerprint.bytes($0), seconds: 15, source: "project", speakerScore: 0.95)
                                        }, speaker: .init(model: "fixture-calibrated", threshold: 0.8,
                                                          embedding: VoiceConsentRecord.encodeEmbedding([1, 0])),
                                        app: .init(version: "0.1.0", platform: "macos"),
                                        creator: .init(region: .default, keyFingerprint: "0123456789abcdef"), projectConsent: consent)
        return try Fixture(record: record, request: request, quote: quote(request, consent: consent, attestations: attestations))
    }

    private func object<Value: Encodable>(_ value: Value) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }

    private func decodeRecord(_ object: [String: Any]) throws -> VoiceConsentRecord {
        try JSONDecoder().decode(VoiceConsentRecord.self, from: JSONSerialization.data(withJSONObject: object))
    }

    @Test func legacyRecordAndAuditKeepTheirWireShape() throws {
        let data = try FixtureLoader.data("fixtures/voice-lab/consent-record.json")
        let original = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let record = try JSONDecoder().decode(VoiceConsentRecord.self, from: data)
        try record.validate()
        #expect(NSDictionary(dictionary: original).isEqual(to: try object(record)))
        #expect(record.consentMethod == .recordedStatement)
        #expect(record.projectConsent == nil)
        #expect(record.referenceAudioFile == "statement.wav")
        #expect(record.referenceAudioSHA256 == record.statement?.audioSha256)
        let audit = try VoiceConsentAudit(record: record)
        try audit.validate(recordID: record.id)
        let encoded = try object(audit)
        #expect(audit.consentMethod == .recordedStatement)
        #expect(encoded["statementSha256"] as? String == record.referenceAudioSHA256)
        #expect(encoded["referenceAudioSha256"] == nil && encoded["consentMethod"] == nil)
    }

    @Test func sharedProjectConsentFixtureRoundTripsWithoutRecordedEvidence() throws {
        let data = try FixtureLoader.data("fixtures/voice-lab/consent-record-project.json")
        let original = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let record = try JSONDecoder().decode(VoiceConsentRecord.self, from: data)
        try record.validate()
        #expect(NSDictionary(dictionary: original).isEqual(to: try object(record)))
        #expect(record.consentMethod == .projectAttestation)
        #expect(record.statement == nil)
        #expect(record.referenceAudioFile == "reference.wav")
        #expect(record.referenceAudioSHA256 == record.samples.first?.sha256)
        #expect(record.samples.reduce(0) { $0 + $1.seconds } == 30)
    }

    @Test func attestedRecordHasNoInventedRecordedEvidence() throws {
        let fixture = try fixture()
        let record = fixture.record
        try record.validate()
        let encoded = try object(record)
        let consent = try #require(encoded["projectConsent"] as? [String: Any])
        #expect(encoded["statement"] == nil)
        #expect(consent["text"] as? String == VoiceConsentRecord.ProjectConsent.text)
        #expect(consent["nonce"] == nil && consent["stt"] == nil)
        #expect(record.consentMethod == .projectAttestation && record.language == "en")
        #expect(record.referenceAudioFile == "reference.wav")
        #expect(record.referenceAudioSHA256 == record.samples.first?.sha256)
        #expect(try decodeRecord(encoded) == record)
        let audit = try VoiceConsentAudit(record: record)
        try audit.validate(recordID: record.id)
        let auditObject = try object(audit)
        #expect(audit.statementSha256 == nil && auditObject["statementSha256"] == nil)
        #expect(audit.referenceAudioSha256 == record.referenceAudioSHA256)
        #expect(auditObject["consentMethod"] as? String == "projectAttestation")
        #expect(try JSONDecoder().decode(VoiceConsentAudit.self, from: JSONEncoder().encode(audit)) == audit)
    }

    @Test(arguments: ["schema", "text", "file", "hash", "language", "statement", "missingConsent", "source", "score", "attestation", "timestamp", "tooShort", "tooLong"])
    func invalidEvidenceFailsClosed(mutation: String) throws {
        var encoded = try object(fixture().record)
        var consent = try #require(encoded["projectConsent"] as? [String: Any])
        var samples = try #require(encoded["samples"] as? [[String: Any]])
        var attestations = try #require(encoded["attestations"] as? [String: Any])
        switch mutation {
        case "schema": encoded["schema"] = "voxclip-consent/1"
        case "text": consent["text"] = "I was verified by a provider."
        case "file": consent["audioFile"] = "../reference.wav"
        case "hash": consent["audioSha256"] = String(repeating: "a", count: 64)
        case "language": consent["language"] = "invalid"
        case "statement":
            let legacy = try #require(JSONSerialization.jsonObject(with: FixtureLoader.data("fixtures/voice-lab/consent-record.json")) as? [String: Any])
            encoded["statement"] = legacy["statement"]
        case "source": samples[0]["source"] = "readAloud"
        case "score": samples[0]["speakerScore"] = 0.1
        case "attestation": attestations["ownVoice"] = false
        case "timestamp": attestations["acceptedAt"] = "invalid"
        case "tooShort": for index in samples.indices { samples[index]["seconds"] = 5 }
        case "tooLong": samples = Array(repeating: samples[0], count: 9)
        default: break
        }
        encoded["projectConsent"] = mutation == "missingConsent" ? nil : consent
        encoded["samples"] = samples; encoded["attestations"] = attestations
        let record = try decodeRecord(encoded)
        #expect(throws: VoiceConsentError.invalidRecord) { try record.validate() }
    }

    @Test func attestedQuoteHasOnlyCreationAndBindsConsent() throws {
        let fixture = try fixture()
        let consent = try #require(fixture.record.projectConsent)
        #expect(fixture.quote.verify == nil)
        #expect(fixture.quote.consentMethod == .projectAttestation)
        #expect(fixture.quote.estimate == fixture.quote.create.estimate)
        try fixture.quote.validate(request: fixture.request, projectConsent: consent, attestations: fixture.record.attestations)
        let decoded = try JSONDecoder().decode(EnrollmentQuote.self, from: JSONEncoder().encode(fixture.quote))
        #expect(decoded == fixture.quote)
        let later = VoiceConsentRecord.Attestations(ownVoice: true, adult: true, ownVideosOnly: true, acceptedAt: now.addingTimeInterval(1))
        #expect(throws: VoiceLabError.consentRequired) {
            try decoded.validate(request: fixture.request, projectConsent: consent, attestations: later)
        }
        #expect(throws: VoiceLabError.consentRequired) {
            try decoded.validate(request: fixture.request, statement: .init(language: "en", text: "not recorded", nonce: []))
        }
    }

    @Test func legacyQuoteKeepsItsWireShapeAndValidationRoute() throws {
        let fixture = try fixture()
        let statement = VoiceConsentStatement(language: "en", text: "Recorded fixture statement", nonce: ["amber", "birch", "cedar", "delta"])
        let request = VoiceLabCloneRequest(displayName: "Example", language: "en",
                                          samples: [.init(role: .consentStatement, wav: fixture.reference)] + fixture.request.samples,
                                          createdAt: now, removeBackgroundNoise: false, recoveryNonce: fixture.record.id)
        let legacy = try EnrollmentQuote(verify: nil, create: fixture.quote.create, request: request, statement: statement)
        let encoded = try object(legacy)
        #expect(encoded["method"] == nil)
        let decoded = try JSONDecoder().decode(EnrollmentQuote.self, from: JSONSerialization.data(withJSONObject: encoded))
        #expect(decoded.consentMethod == .recordedStatement)
        try decoded.validate(request: request, statement: statement)
        let consent = try #require(fixture.record.projectConsent)
        #expect(throws: VoiceLabError.consentRequired) {
            try decoded.validate(request: fixture.request, projectConsent: consent, attestations: fixture.record.attestations)
        }
    }

    @Test(arguments: ["bytes", "order", "role", "nonce", "name", "language", "createdAt", "noise"])
    func attestedQuoteBindsTheExactRequest(mutation: String) throws {
        let fixture = try fixture()
        var encoded = try object(fixture.request)
        var samples = try #require(encoded["samples"] as? [[String: Any]])
        switch mutation {
        case "bytes": samples[1]["wav"] = fixture.reference.base64EncodedString()
        case "order": samples.reverse()
        case "role": samples[0]["role"] = "consentStatement"
        case "nonce": encoded["recoveryNonce"] = UUID().uuidString
        case "name": encoded["displayName"] = "Other"
        case "language": encoded["language"] = "et"
        case "createdAt": encoded["createdAt"] = now.addingTimeInterval(1).timeIntervalSinceReferenceDate
        case "noise": encoded["removeBackgroundNoise"] = true
        default: break
        }
        encoded["samples"] = samples
        let request = try JSONDecoder().decode(VoiceLabCloneRequest.self, from: JSONSerialization.data(withJSONObject: encoded))
        let consent = try #require(fixture.record.projectConsent)
        #expect(throws: VoiceLabError.consentRequired) {
            try fixture.quote.validate(request: request, projectConsent: consent, attestations: fixture.record.attestations)
        }
    }

    @Test func referenceStoreRoundTripsAndRejectsTampering() async throws {
        let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = VoiceConsentStore(locations: SpeechTestFiles.locations(root))
        let fixture = try fixture()
        try await store.saveReferenceAudio(fixture.reference, recordID: fixture.record.id)
        #expect(try await store.referenceAudio(recordID: fixture.record.id) == fixture.reference)
        try await store.save(fixture.record)
        #expect(try await store.load(fixture.record.id) == fixture.record)
        let directory = store.root.appendingPathComponent(fixture.record.id)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("statement.wav").path))
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("reference.wav").path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        try fixture.request.samples[1].wav.write(to: directory.appendingPathComponent("reference.wav"))
        await #expect(throws: VoiceConsentError.invalidRecord) { try await store.load(fixture.record.id) }
        await #expect(throws: VoiceConsentError.invalidRecord) { try await store.referenceAudio(recordID: fixture.record.id) }
    }

    @Test func ambiguousOrSymlinkedReferenceIsRejected() async throws {
        let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = VoiceConsentStore(locations: SpeechTestFiles.locations(root))
        let fixture = try fixture()
        try await store.saveReferenceAudio(fixture.reference, recordID: fixture.record.id)
        await #expect(throws: VoiceConsentError.invalidRecord) { try await store.saveStatement(fixture.reference, recordID: fixture.record.id) }
        let directory = store.root.appendingPathComponent(fixture.record.id)
        try fixture.reference.write(to: directory.appendingPathComponent("statement.wav"))
        await #expect(throws: VoiceConsentError.invalidRecord) { try await store.referenceAudio(recordID: fixture.record.id) }
        try FileManager.default.removeItem(at: directory.appendingPathComponent("statement.wav"))
        try FileManager.default.removeItem(at: directory.appendingPathComponent("reference.wav"))
        let outside = root.appendingPathComponent("outside.wav")
        try fixture.reference.write(to: outside)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("reference.wav"), withDestinationURL: outside)
        await #expect(throws: VoiceConsentError.invalidRecord) { try await store.referenceAudio(recordID: fixture.record.id) }
    }

    @Test func trainingOnlyRecoverySurvivesRestartAndExpiresWithoutAudio() async throws {
        let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let locations = SpeechTestFiles.locations(root)
        let store = VoiceConsentStore(locations: locations)
        let fixture = try fixture()
        try await store.saveReferenceAudio(fixture.reference, recordID: fixture.record.id)
        try await store.saveEnrollmentRecovery(fixture.recovery)
        let restarted = VoiceConsentStore(locations: locations)
        let recovery = try #require(await restarted.enrollmentRecovery(recordID: fixture.record.id, now: now))
        #expect(recovery.request == fixture.request && recovery.record == fixture.record)
        #expect(recovery.quote.verify == nil && recovery.quote.consentMethod == .projectAttestation)
        #expect(try await restarted.recoverableEnrollments(now: now) == [fixture.record.id])
        #expect(try await restarted.enrollmentRecovery(recordID: fixture.record.id, now: now.addingTimeInterval(24 * 60 * 60)) == nil)
        #expect(!FileManager.default.fileExists(atPath: store.root.appendingPathComponent("\(fixture.record.id)/reference.wav").path))
    }

    @Test(arguments: ["duration", "trainingSeconds", "reference", "sampleCount", "sampleHash"])
    func recoveryRejectsMismatchedSampleAudit(mutation: String) async throws {
        let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = VoiceConsentStore(locations: SpeechTestFiles.locations(root))
        let fixture = try fixture()
        try await store.saveReferenceAudio(fixture.reference, recordID: fixture.record.id)
        var encoded = try object(fixture.recovery)
        var record = try #require(encoded["record"] as? [String: Any])
        var samples = try #require(record["samples"] as? [[String: Any]])
        switch mutation {
        case "duration": samples[0]["seconds"] = 16
        case "trainingSeconds": encoded["trainingSeconds"] = 31
        case "reference": try fixture.request.samples[1].wav.write(to: store.root.appendingPathComponent("\(fixture.record.id)/reference.wav"))
        case "sampleCount": samples.removeLast()
        case "sampleHash": samples[1]["sha256"] = String(repeating: "a", count: 64)
        default: break
        }
        record["samples"] = samples; encoded["record"] = record
        let recovery = try JSONDecoder().decode(VoiceEnrollmentRecovery.self, from: JSONSerialization.data(withJSONObject: encoded))
        await #expect(throws: VoiceConsentError.invalidRecord) { try await store.saveEnrollmentRecovery(recovery) }
    }

    @Test func attestedCreationRetainsDispatchAndDuplicateGuards() async throws {
        let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = VoiceConsentStore(locations: SpeechTestFiles.locations(root))
        let fixture = try fixture()
        try await store.saveReferenceAudio(fixture.reference, recordID: fixture.record.id)
        try await store.saveEnrollmentRecovery(fixture.recovery)
        let operation = try await store.beginClaimedCreation(record: fixture.record, requestID: fixture.quote.create.requestID, region: .default, at: now)
        await #expect(throws: VoiceConsentError.creationPending) { try await store.validateEnrollmentStart(recordID: fixture.record.id) }
        try await store.dispatchCreation(recordID: fixture.record.id, requestID: operation.id, statementHash: fixture.record.referenceAudioSHA256)
        try await store.validateCreation(recordID: fixture.record.id, requestID: operation.id, statementHash: fixture.record.referenceAudioSHA256)
        #expect(try await store.operation(operation.id).wasDispatched)
        #expect(try await store.enrollmentRecovery(recordID: fixture.record.id, now: now) != nil)
        #expect(try await store.recoverableEnrollments(now: now).isEmpty)
        let other = try self.fixture()
        try await store.saveReferenceAudio(other.reference, recordID: other.record.id)
        await #expect(throws: VoiceConsentError.creationPending) {
            try await store.beginClaimedCreation(record: other.record, requestID: other.quote.create.requestID, region: .default, at: now)
        }
        let completed = try await store.transition(operation.id, to: .created, at: now, remoteVoiceID: "fixtureVoice", requiresVerification: true)
        try await store.saveCreatedRecord(completed)
        let record = try await store.load(fixture.record.id)
        #expect(record.projectConsent == fixture.record.projectConsent && record.statement == nil)
        #expect(record.status == .verificationRequired)
        try await store.discardStatement(recordID: record.id)
        #expect(!FileManager.default.fileExists(atPath: store.root.appendingPathComponent("\(record.id)/reference.wav").path))
        await #expect(throws: (any Error).self) {
            try await store.validateCreation(recordID: record.id, requestID: operation.id, statementHash: record.referenceAudioSHA256)
        }
    }

    @Test func localRemovalKeepsAnAttestedAuditWithoutReferenceAudio() async throws {
        let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = VoiceConsentStore(locations: SpeechTestFiles.locations(root))
        let fixture = try fixture()
        let record = fixture.record.assigningVoice("fixtureVoice", requiresVerification: false)
        try await store.saveReferenceAudio(fixture.reference, recordID: record.id)
        try await store.save(record)
        try await store.validateUse(record)
        await #expect(throws: VoiceConsentError.creatorMismatch) {
            try await store.beginDeletion(record.id, region: .eu, at: now)
        }
        try await store.removeFromVoxClipOnly(record.id, at: now)
        let deleted = try await store.load(record.id)
        #expect(deleted.status == .deleted && deleted.projectConsent == record.projectConsent)
        #expect(deleted.creator == record.creator && deleted.statement == nil)
        #expect(try await store.activeVoices().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.root.appendingPathComponent("\(record.id)/reference.wav").path))
        let audit = try #require(await store.auditTombstone(recordID: record.id))
        #expect(audit.consentMethod == .projectAttestation && audit.statementSha256 == nil)
        #expect(audit.referenceAudioSha256 == record.referenceAudioSHA256)
        await #expect(throws: VoiceConsentError.inactive) { try await store.validateUse(record) }
    }
}
#endif
