#if DEBUG
import Foundation
import Testing
@testable import VoxClipCore

/// Replays shared/fixtures/voice-lab/voice-rebuild-cases.json (voice-lab §6.12, ADR-R44; the per-video floor of §6.13), which the
/// Windows Core replays too: the pieces a rebuilt voice is made from, in send order, what was left out, and the line shown first.
/// Pure binary64 arithmetic in a fixed order, so the diversity round's cosines match the generator to the bit.
@Suite("Voice rebuild vectors", .offlineFixtures)
struct VoiceRebuildReplayTests {
    private struct Document: Decodable {
        let schema: String
        let constants: Constants
        let caseCount: Int
        let cases: [Case]
    }
    private struct Constants: Decodable {
        let threshold: Double
        let maximumFiles: Int
        let minimumTotalMs: Int
        let maximumTotalMs: Int
        let minimumPieceMs: Int
        let maximumPieceMs: Int
        let minimumSnrDb: Double
        let perVideoMinimumSnrDb: Double
        let candidatesPerVideo: Int
    }
    private struct Candidate: Decodable {
        let video: String
        let startMs: Int
        let endMs: Int
        let snrDb: Double
        let score: Double
        let embedding: String
    }
    private struct Expected: Decodable {
        let pieces: [Piece]
        let keptMs: Int?
        let rejected: [String: Int]
        let totalMs: Int
        let videoCount: Int
        let fileCount: Int
        let enough: Bool
        let summary: String
    }
    private struct Piece: Decodable, Equatable {
        let video: String
        let startMs: Int
        init(video: String, startMs: Int) { self.video = video; self.startMs = startMs }
        init(from decoder: any Decoder) throws {
            var container = try decoder.unkeyedContainer()
            video = try container.decode(String.self)
            startMs = try container.decode(Int.self)
        }
    }
    private struct Case: Decodable {
        let kind: String
        let name: String
        let threshold: Double?
        let keptMs: Int?
        let minimumSnrDb: Double?
        let candidates: [Candidate]?
        let milliseconds: [Int]?
    }

    private func data() throws -> Data { try FixtureLoader.data("fixtures/voice-lab/voice-rebuild-cases.json") }

    @Test func theVectorsHaveTheirShapeAndTheCoresConstants() throws {
        let object = try #require(try JSONSerialization.jsonObject(with: data()) as? [String: Any])
        #expect(Set(object.keys) == ["schema", "description", "constants", "caseCount", "cases"])
        let document = try JSONDecoder().decode(Document.self, from: data())
        #expect(document.schema == "voxclip-voice-rebuild/1")
        #expect(document.cases.count == document.caseCount)
        let constants = document.constants
        #expect(constants.maximumFiles == VoiceRebuild.maximumFiles)
        #expect(constants.minimumTotalMs == VoiceRebuild.minimumTotalMs)
        #expect(constants.maximumTotalMs == VoiceRebuild.maximumTotalMs)
        #expect(constants.minimumPieceMs == VoiceRebuild.minimumPieceMs)
        #expect(constants.maximumPieceMs == VoiceRebuild.maximumPieceMs)
        #expect(constants.minimumSnrDb == VoiceRebuild.minimumSnrDb)
        #expect(constants.perVideoMinimumSnrDb == VoicePerVideo.minimumSnrDb)
        #expect(constants.candidatesPerVideo == VoiceRebuild.candidatesPerVideo)
    }

    @Test func replaysEveryRebuildVector() throws {
        let raw = try #require(try JSONSerialization.jsonObject(with: data()) as? [String: Any])
        let rawCases = try #require(raw["cases"] as? [[String: Any]])
        let document = try JSONDecoder().decode(Document.self, from: data())
        var kinds = Set<String>()
        for (index, item) in document.cases.enumerated() {
            kinds.insert(item.kind)
            let expectedJSON = try JSONSerialization.data(withJSONObject: try #require(rawCases[index]["expected"]))
            switch item.kind {
            case "pick":
                let expected = try JSONDecoder().decode(Expected.self, from: expectedJSON)
                let candidates = try (item.candidates ?? []).map { candidate -> VoiceRebuild.Candidate in
                    let embedding = try #require(VoiceConsentRecord.decodeEmbedding(candidate.embedding), "\(item.name)")
                    return VoiceRebuild.Candidate(video: candidate.video, startMs: candidate.startMs, endMs: candidate.endMs,
                                                  snrDb: candidate.snrDb, score: candidate.score, embedding: embedding)
                }
                let threshold = try #require(item.threshold, "\(item.name)")
                let floor = try #require(item.minimumSnrDb, "\(item.name)")
                let plan = VoiceRebuild.pick(candidates, threshold: threshold, keptMs: item.keptMs, minimumSnrDb: floor)
                let pieces = plan.pieces.map { Piece(video: $0.video, startMs: $0.startMs) }
                #expect(pieces == expected.pieces, "\(item.name)")
                #expect(plan.keptMs == expected.keptMs, "\(item.name)")
                var rejected: [String: Int] = [:]
                for (reason, count) in plan.rejected { rejected[reason.rawValue] = count }
                #expect(rejected == expected.rejected, "\(item.name)")
                #expect(plan.totalMs == expected.totalMs, "\(item.name)")
                #expect(plan.videoCount == expected.videoCount, "\(item.name)")
                #expect(plan.fileCount == expected.fileCount, "\(item.name)")
                #expect(plan.enough == expected.enough, "\(item.name)")
                #expect(VoiceRebuild.summary(plan) == expected.summary, "\(item.name)")
            case "amount":
                let expected = try JSONDecoder().decode([String].self, from: expectedJSON)
                let amounts = (item.milliseconds ?? []).map { VoiceRebuild.amount($0) }
                #expect(amounts == expected, "\(item.name)")
            default:
                Issue.record("unknown kind \(item.kind) in \(item.name)")
            }
        }
        #expect(kinds == ["pick", "amount"])
    }
}
#endif
