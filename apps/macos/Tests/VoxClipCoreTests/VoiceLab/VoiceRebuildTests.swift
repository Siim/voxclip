#if DEBUG
import Foundation
import Testing
@_spi(Testing) @testable import VoxClipCore

/// "Rebuild from my videos" (voice-lab §6.12, ADR-R42): which owner-verified pieces a rebuilt voice is made from, and
/// how the old voice's learned references reach the new one.
@Suite("Rebuild from my videos: the sample set", .offlineFixtures)
struct VoiceRebuildTests {
    private static func vector(_ degrees: Double) -> [Float] {
        let radians = degrees * .pi / 180
        return [Float(cos(radians)), Float(sin(radians))]
    }
    private func piece(_ video: String, start: Int = 0, seconds: Int = 20, snr: Double = 30, score: Double = 0.9, degrees: Double = 0) -> VoiceRebuild.Candidate {
        .init(video: video, startMs: start * 1_000, endMs: (start + seconds) * 1_000, snrDb: snr, score: score, embedding: Self.vector(degrees))
    }

    @Test func onlyTheOwnersCleanSpeechOfTheRightLengthIsUsed() {
        let candidates = [
            piece("a", score: 0.9),
            piece("b", score: 0.44),              // below τ against the consent embedding: never through a reference
            piece("c", snr: 19.9),                // under the clean-speech floor
            piece("d", seconds: 4),               // too short for a training file
            piece("e", seconds: 31),              // too long
            piece("f", score: .nan),
            piece("g", score: 0.45),              // exactly τ passes
        ]
        let plan = VoiceRebuild.pick(candidates, threshold: 0.45)
        #expect(plan.pieces.map(\.video).sorted() == ["a", "g"])
        #expect(plan.rejected == [.notTheOwner: 2, .noisy: 1, .length: 2])
        #expect(plan.totalMs == 40_000 && plan.videoCount == 2 && plan.enough)
    }

    @Test func everyVideoOnceBeforeAnyRepeatsThenTheMostDifferent() {
        // Video a has three clean pieces in one room; b and c one each in other rooms.
        let candidates = [
            piece("a", start: 0, snr: 40, score: 0.95, degrees: 0),
            piece("a", start: 30, snr: 39, score: 0.95, degrees: 1),
            piece("a", start: 60, snr: 38, score: 0.95, degrees: 25),
            piece("b", start: 0, snr: 25, score: 0.70, degrees: 30),
            piece("c", start: 0, snr: 22, score: 0.60, degrees: -30),
        ]
        let plan = VoiceRebuild.pick(candidates, threshold: 0.45)
        // Round 1: each video's cleanest piece, the best-scoring video first.
        #expect(plan.pieces.prefix(3).map(\.video) == ["a", "b", "c"])
        #expect(plan.pieces[0].startMs == 0)
        // Round 2: video a's piece at 25° is further from everything chosen than its piece at 1°.
        #expect(plan.pieces[3].startMs == 60_000 && plan.pieces[4].startMs == 30_000)
        #expect(plan.videoCount == 3 && plan.totalMs == 100_000)
        #expect(VoiceRebuild.summary(plan) == "1 min 40 s from 3 videos")
    }

    @Test func theSetStaysWithinTheClientsLimits() {
        // 30 owner pieces of 5 s across 30 videos: 24 files at most, even under 120 s.
        let many = (0..<30).map { piece("v\($0)", seconds: 5, score: 0.9 - Double($0) / 1_000) }
        let files = VoiceRebuild.pick(many, threshold: 0.45)
        #expect(files.fileCount == VoiceRebuild.maximumFiles && files.totalMs == 120_000 && files.rejected[.full] == 6)
        // Long pieces stop at 120 s; a piece that would pass it is skipped and a later, shorter one still fits.
        let long = [piece("a", seconds: 30, score: 0.99), piece("b", seconds: 30, score: 0.98), piece("c", seconds: 30, score: 0.97),
                    piece("d", seconds: 25, score: 0.96), piece("e", seconds: 10, score: 0.95), piece("f", seconds: 5, score: 0.94)]
        let seconds = VoiceRebuild.pick(long, threshold: 0.45)
        #expect(seconds.pieces.map(\.video) == ["a", "b", "c", "d", "f"])
        #expect(seconds.totalMs == 120_000 && seconds.rejected[.full] == 1)
        // The kept consent clip counts toward both limits.
        let kept = VoiceRebuild.pick(long, threshold: 0.45, keptMs: 20_000)
        #expect(kept.fileCount == kept.pieces.count + 1)
        #expect(kept.pieces.map(\.video) == ["a", "b", "c", "e"] && kept.totalMs == 120_000 && kept.rejected[.full] == 2)
        #expect(VoiceRebuild.summary(kept) == "2 min from 4 videos and your consent clip")
        // Under 30 s in all is not enough.
        #expect(!VoiceRebuild.pick([piece("a", seconds: 29)], threshold: 0.45).enough)
        #expect(VoiceRebuild.amount(59_999) == "59 s" && VoiceRebuild.amount(120_000) == "2 min")
    }

    // MARK: The old voice's references

    private var wav: Data { VoiceLabRequestFixtures.wav(rate: 16_000, frames: 80_000, fill: 4_000) }
    private func record(id: String, degrees: Double, voiceID: String) throws -> VoiceConsentRecord {
        var json = try #require(JSONSerialization.jsonObject(with: FixtureLoader.data("fixtures/voice-lab/consent-record.json")) as? [String: Any])
        json["recordId"] = id; json["voiceId"] = voiceID
        var statement = try #require(json["statement"] as? [String: Any]); statement["audioSha256"] = VoiceLabFingerprint.bytes(wav); json["statement"] = statement
        var speaker = try #require(json["speaker"] as? [String: Any])
        speaker["threshold"] = 0.45; speaker["embedding"] = VoiceConsentRecord.encodeEmbedding(Self.vector(degrees)); json["speaker"] = speaker
        return try JSONDecoder().decode(VoiceConsentRecord.self, from: JSONSerialization.data(withJSONObject: json))
    }

    @Test func referencesReachTheNewVoiceOnlyWhenTheyPassItsOwnEmbedding() async throws {
        let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = VoiceConsentStore(locations: SpeechTestFiles.locations(root))
        let old = try record(id: "11111111-1111-4111-8111-111111111111", degrees: 0, voiceID: "oldVoice")
        let new = try record(id: "22222222-2222-4222-8222-222222222222", degrees: -30, voiceID: "newVoice")
        for item in [old, new] { try await store.saveStatement(wav, recordID: item.id); try await store.save(item) }
        // Learned against the old voice: 20° (car) and 60° (street) both pass one hop against [1, 0] at τ 0.45.
        try await store.learnReference(recordID: old.id, embedding: Self.vector(20), contentKey: "car", model: "fixture-calibrated")
        try await store.learnReference(recordID: old.id, embedding: Self.vector(60), contentKey: "street", model: "fixture-calibrated")
        #expect(VoiceSpeakerReferences.learnedCount(try await store.load(old.id).speaker) == 2)
        // Against the new voice at −30°: the car reference is 50° away (passes), the street one 90° (dropped). The old
        // record's own embedding, and the other reference, never vouch for it.
        #expect(try await store.carryReferences(from: old.id, to: new.id) == 1)
        let carried = try await store.load(new.id)
        #expect(carried.speaker.references?.map(\.contentKey) == ["car"])
        let score = try #require(carried.speaker.references?.first?.statementScore)
        #expect(abs(score - cos(50 * .pi / 180)) < 1e-6, "scored against the new record's own embedding")
        // The old voice keeps its own until it is deleted.
        #expect(try await store.load(old.id).speaker.references?.count == 2)
        // A voice made with the same statement keeps every reference.
        let same = try record(id: "33333333-3333-4333-8333-333333333333", degrees: 0, voiceID: "sameVoice")
        try await store.saveStatement(wav, recordID: same.id); try await store.save(same)
        #expect(try await store.carryReferences(from: old.id, to: same.id) == 2)
    }
}
#endif
