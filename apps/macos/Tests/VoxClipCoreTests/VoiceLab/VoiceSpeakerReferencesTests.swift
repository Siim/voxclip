#if DEBUG
import Foundation
import Testing
@_spi(Testing) @testable import VoxClipCore
@_spi(Testing) @testable import VoxClipMedia

/// A scripted speaker model: speech filled with the value `a` is the unit vector at `a × 100` degrees. The fixture
/// record's owner is [1, 0] with τ 0.8, so up to 36.87° passes against the statement.
private struct AngleEmbedder: SpeakerEmbedder {
    let modelID = "fixture-calibrated"
    let dimension = 2
    func voicedSamples(_ pcm16k: [Float]) async throws -> [Float] { pcm16k }
    func embed(_ pcm16k: [Float]) async throws -> [Float] {
        let radians = Double(pcm16k.first ?? 0) * 100 * .pi / 180
        return [Float(cos(radians)), Float(sin(radians))]
    }
}

/// "Let a video teach your voice" (voice-lab §6.9, ADR-R41): references learned from the owner's own videos, one hop.
@Suite("Voice references learned from the owner's videos", .serialized, .offlineFixtures)
struct VoiceSpeakerReferencesTests {
    private static func vector(_ degrees: Double) -> [Float] {
        let radians = degrees * .pi / 180
        return [Float(cos(radians)), Float(sin(radians))]
    }
    /// Four seconds of speech the angle embedder reads as `degrees`.
    private static func speech(_ degrees: Double) -> [Float] { [Float](repeating: Float(degrees / 100), count: 64_000) }
    private static let date = Date(timeIntervalSince1970: 1_793_900_000)
    private var wav: Data { VoiceLabRequestFixtures.wav(rate: 16_000, frames: 80_000, fill: 4_000) }

    private func fixtureRecord() throws -> VoiceConsentRecord {
        var json = try #require(JSONSerialization.jsonObject(with: FixtureLoader.data("fixtures/voice-lab/consent-record.json")) as? [String: Any])
        var statement = try #require(json["statement"] as? [String: Any]); statement["audioSha256"] = VoiceLabFingerprint.bytes(wav); json["statement"] = statement
        return try JSONDecoder().decode(VoiceConsentRecord.self, from: JSONSerialization.data(withJSONObject: json))
    }
    private func store(_ root: URL) async throws -> (VoiceConsentStore, VoiceConsentRecord) {
        let record = try fixtureRecord()
        let store = VoiceConsentStore(locations: SpeechTestFiles.locations(root))
        try await store.saveStatement(wav, recordID: record.id); try await store.save(record)
        return (store, record)
    }
    private func reference(_ degrees: Double, key: String, model: String = "fixture-calibrated", score: Double? = nil) -> VoiceConsentRecord.Speaker.Reference {
        .init(embedding: VoiceConsentRecord.encodeEmbedding(Self.vector(degrees)), contentKey: key, addedAt: VoiceConsentRecord.timestamp(Self.date),
              statementScore: score ?? cos(degrees * .pi / 180), model: model)
    }

    // MARK: The record's wire

    @Test func referencesAreAnAdditiveFieldOfTheSpeaker() throws {
        let record = try fixtureRecord()
        #expect(record.speaker.references == nil, "a record written before references decodes without them")
        let plain = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any]
        #expect((plain?["speaker"] as? [String: Any])?.keys.sorted() == ["embedding", "model", "threshold"], "no references key until one is learned")

        let learned = record.replacingSpeaker(record.speaker.replacingReferences([reference(20, key: "car-video")]))
        try learned.validate()
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(learned)) as? [String: Any]
        let references = try #require((json?["speaker"] as? [String: Any])?["references"] as? [[String: Any]])
        #expect(references.count == 1)
        #expect(references[0].keys.sorted() == ["addedAt", "contentKey", "embedding", "model", "statementScore"])
        #expect(references[0]["contentKey"] as? String == "car-video")
        #expect(references[0]["addedAt"] as? String == "2026-11-05T17:33:20Z")
        let decoded = try JSONDecoder().decode(VoiceConsentRecord.self, from: JSONEncoder().encode(learned))
        #expect(decoded == learned)
        // Learning or forgetting doesn't change what a run was approved for.
        #expect(decoded.withoutReferences == record)
        #expect(record.replacingSpeaker(record.speaker.replacingReferences([])).speaker.references == nil)
    }

    @Test func malformedReferencesRefuseTheRecord() throws {
        let record = try fixtureRecord()
        func refuses(_ references: [VoiceConsentRecord.Speaker.Reference]) -> Bool {
            (try? record.replacingSpeaker(record.speaker.replacingReferences(references)).validate()) == nil
        }
        #expect(refuses([reference(10, key: "a"), reference(20, key: "a")]), "one per project")
        #expect(refuses((0..<17).map { reference(Double($0), key: "p\($0)") }), "at most 16")
        #expect(refuses([reference(10, key: "")]))
        #expect(refuses([reference(10, key: "../x")]))
        #expect(refuses([.init(embedding: "AAAA", contentKey: "a", addedAt: "2026-11-05T00:00:00Z", statementScore: 0.9, model: "fixture-calibrated")]))
        #expect(refuses([.init(embedding: VoiceConsentRecord.encodeEmbedding(Self.vector(10)), contentKey: "a", addedAt: "yesterday", statementScore: 0.9, model: "fixture-calibrated")]))
        #expect(!refuses((0..<16).map { reference(Double($0), key: "p\($0)") }))
        // A deleted record keeps no references.
        var deleted = record.replacingSpeaker(record.speaker.replacingReferences([reference(10, key: "a")]))
        deleted.status = .deleted; deleted.deletedAt = "2026-11-05T00:00:00Z"
        #expect((try? deleted.validate()) == nil)
    }

    // MARK: One hop

    @Test func aReferenceThatDoesNotPassAgainstTheStatementIsRejectedAndNeverStored() async throws {
        let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let (store, record) = try await store(root)
        // 60° scores 0.5 against the owner [1, 0]: below τ 0.8.
        await #expect(throws: VoiceSpeakerReferences.Refusal.notTheOwner) {
            try await store.learnReference(recordID: record.id, embedding: Self.vector(60), contentKey: "car-video", model: "fixture-calibrated")
        }
        #expect(try await store.load(record.id).speaker.references == nil)
        // Another speaker model never teaches this record.
        await #expect(throws: VoiceSpeakerReferences.Refusal.otherModel) {
            try await store.learnReference(recordID: record.id, embedding: Self.vector(10), contentKey: "car-video", model: "another-model")
        }
        let learned = try await store.learnReference(recordID: record.id, embedding: Self.vector(30), contentKey: "car-video", model: "fixture-calibrated", at: Self.date)
        #expect(learned.speaker.references?.map(\.contentKey) == ["car-video"])
        #expect(abs((learned.speaker.references?[0].statementScore ?? 0) - cos(30 * .pi / 180)) < 1e-6)
        #expect(try await store.load(record.id) == learned)
    }

    @Test func aReferenceIsNeverCheckedAgainstAnotherReference() throws {
        let record = try fixtureRecord()
        // A reference at 60° written by hand, with a forged score: it fails against the statement when re-checked, so it is
        // never used, and 90° (30° from it) stays blocked. One that passes (30°) carries 60° but not 90°.
        let forged = record.speaker.replacingReferences([reference(60, key: "forged", score: 0.95)])
        #expect(VoiceSpeakerReferences.usable(forged).isEmpty)
        #expect(try VoiceSpeakerReferences.match(Self.vector(90), speaker: forged) == nil)
        let real = record.speaker.replacingReferences([reference(30, key: "car-video")])
        #expect(try VoiceSpeakerReferences.match(Self.vector(10), speaker: real)?.viaReference == false, "the statement is tried first")
        let viaReference = try #require(try VoiceSpeakerReferences.match(Self.vector(60), speaker: real))
        #expect(viaReference.viaReference)
        guard case .reference(_, let key) = viaReference else { Issue.record("not a reference match"); return }
        #expect(key == "car-video")
        #expect(try VoiceSpeakerReferences.match(Self.vector(90), speaker: real) == nil, "60° from the reference: blocked, τ unchanged")
    }

    // MARK: The bound

    @Test func onePerProjectTheBestScoringIsKept() throws {
        let speaker = try fixtureRecord().speaker
        let first = try VoiceSpeakerReferences.learning(Self.vector(30), contentKey: "car", model: "fixture-calibrated", at: Self.date, into: speaker)
        #expect(throws: VoiceSpeakerReferences.Refusal.notBetter) {
            try VoiceSpeakerReferences.learning(Self.vector(35), contentKey: "car", model: "fixture-calibrated", at: Self.date, into: first)
        }
        let better = try VoiceSpeakerReferences.learning(Self.vector(-20), contentKey: "car", model: "fixture-calibrated", at: Self.date, into: first)
        #expect(better.references?.count == 1)
        #expect(abs((better.references?[0].statementScore ?? 0) - cos(20 * .pi / 180)) < 1e-6)
    }

    @Test func overTheBoundTheMostRedundantReferenceGoes() throws {
        var speaker = try fixtureRecord().speaker
        // Sixteen projects spread from −30° to 30°, then one more at 0.5°: two references now sit half a degree apart,
        // and one of that pair goes (the lower-scoring), keeping the spread.
        for index in 0..<16 {
            speaker = try VoiceSpeakerReferences.learning(Self.vector(-30 + Double(index) * 4), contentKey: "p\(index)", model: "fixture-calibrated",
                                                          at: Self.date, into: speaker)
        }
        #expect(speaker.references?.count == VoiceSpeakerReferences.bound)
        speaker = try VoiceSpeakerReferences.learning(Self.vector(2.5), contentKey: "extra", model: "fixture-calibrated", at: Self.date, into: speaker)
        let keys = Set(speaker.references?.map(\.contentKey) ?? [])
        #expect(keys.count == 16)
        // 2° (p8) and 2.5° (extra) are the closest pair; 2° scores higher, so 2.5° goes.
        #expect(keys.contains("p8") && !keys.contains("extra"))
    }

    @Test func aModelChangeDropsThemAll() throws {
        let record = try fixtureRecord()
        let old = record.speaker.replacingReferences([reference(10, key: "a", model: "old-model"), reference(20, key: "b", model: "old-model")])
        try record.replacingSpeaker(old).validate()
        #expect(VoiceSpeakerReferences.usable(old).isEmpty, "references from another model are never used")
        #expect(try VoiceSpeakerReferences.match(Self.vector(60), speaker: old) == nil)
        let learned = try VoiceSpeakerReferences.learning(Self.vector(30), contentKey: "c", model: "fixture-calibrated", at: Self.date, into: old)
        #expect(learned.references?.map(\.contentKey) == ["c"])
    }

    // MARK: The Media guard

    @Test func theGuardPassesThroughAReferenceAndForgetBlocksAgain() async throws {
        let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let (store, record) = try await store(root)
        let useGuard = VoiceUseGuard(store: store, check: .init(embedder: AngleEmbedder(), calibratedThreshold: 0.8))
        // Phrase 1 at 60° (0.5 against the statement) and phrase 3 at 30° (0.866) of the same video.
        await #expect(throws: VoiceConsentError.voiceOwnerMismatch) {
            try await useGuard.authorize(contentKey: "car-video", recordID: record.id, speech16k: Self.speech(60), approved: true)
        }
        let verdicts = await useGuard.screen(contentKey: "car-video", recordID: record.id, speech: [Self.speech(60), Self.speech(30)])
        #expect(verdicts.count == 2)
        #expect(verdicts[1] == .passes(.statement(score: try VoiceSpeakerReferences.match(Self.vector(30), speaker: record.speaker)!.score)))
        guard case .passes(.reference(let score, let key)) = verdicts[0] else { Issue.record("phrase 1 should pass through the reference: \(verdicts)"); return }
        #expect(key == "car-video" && score >= 0.8)
        #expect(try await store.load(record.id).speaker.references?.count == 1)
        // The run's own guard at dispatch agrees.
        _ = try await useGuard.authorize(contentKey: "car-video", recordID: record.id, speech16k: Self.speech(60), approved: true)
        // Forget: the cached pass depended on the reference, so phrase 1 is judged afresh and blocked again.
        try await store.forgetReferences(recordID: record.id)
        await #expect(throws: VoiceConsentError.voiceOwnerMismatch) {
            try await useGuard.authorize(contentKey: "car-video", recordID: record.id, speech16k: Self.speech(60), approved: true)
        }
        let again = await useGuard.screen(contentKey: "car-video", recordID: record.id, speech: [Self.speech(60)])
        #expect(again == [.blocked(.voiceOwnerMismatch)], "phrase 1 alone teaches nothing and stays blocked")
    }

    @Test func aGuestStaysBlockedEvenWithReferences() async throws {
        let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let (store, record) = try await store(root)
        let useGuard = VoiceUseGuard(store: store, check: .init(embedder: AngleEmbedder(), calibratedThreshold: 0.8))
        // The owner's 30° phrase teaches the video's reference; the guest at 120° is 90° from it.
        let verdicts = await useGuard.screen(contentKey: "car-video", recordID: record.id, speech: [Self.speech(30), Self.speech(120)])
        #expect(verdicts[1] == .blocked(.voiceOwnerMismatch))
        #expect(try await store.load(record.id).speaker.references?.count == 1)
        await #expect(throws: VoiceConsentError.voiceOwnerMismatch) {
            try await useGuard.authorize(contentKey: "car-video", recordID: record.id, speech16k: Self.speech(120), approved: true)
        }
        // Too little speech to check is settled too.
        let short = await useGuard.screen(contentKey: "car-video", recordID: record.id, speech: [[Float](repeating: 0.3, count: 8_000)])
        #expect(short == [.blocked(.speakerMismatch)])
    }

    @Test func deletingTheVoiceRemovesItsReferences() async throws {
        let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let (store, record) = try await store(root)
        try await store.learnReference(recordID: record.id, embedding: Self.vector(20), contentKey: "car-video", model: "fixture-calibrated")
        try await store.removeFromVoxClipOnly(record.id)
        let tombstone = try await store.load(record.id)
        #expect(tombstone.status == .deleted)
        #expect(tombstone.speaker.references == nil)
        #expect(tombstone.speaker.embedding == record.speaker.embedding, "the audit trail stays")
        await #expect(throws: VoiceConsentError.inactive) {
            try await store.learnReference(recordID: record.id, embedding: Self.vector(20), contentKey: "car-video", model: "fixture-calibrated")
        }
    }
}
#endif
