#if DEBUG
import Foundation
import Testing
@testable import VoxClipCore

/// Replays shared/fixtures/voice-lab/voice-references-cases.json (voice-lab §6.9, ADR-R41), which the Windows Core replays
/// too: which learned references the guard may use, how speech matches through them, and learning one. Pure binary64
/// arithmetic in a fixed order, so scores match the generator to the bit. Fails on an unknown kind.
@Suite("Voice reference vectors", .offlineFixtures)
struct VoiceSpeakerReferencesReplayTests {
    private struct Document: Decodable {
        let schema: String
        let constants: Constants
        let caseCount: Int
        let cases: [Case]
    }
    private struct Constants: Decodable { let bound: Int }
    private struct Case: Decodable {
        let kind: String
        let name: String
        let speaker: VoiceConsentRecord.Speaker
        let candidate: String?
        let embedding: String?
        let contentKey: String?
        let model: String?
        let at: String?
        let expected: Expected?
    }
    private struct Expected: Decodable {
        let contentKeys: [String]?
        let learnedCount: Int?
        let kind: String?
        let score: Double?
        let contentKey: String?
        let refusal: String?
        let statementScores: [Double]?
        let learnedScore: Double?
    }

    @Test func replaysEveryVoiceReferenceVector() throws {
        let document = try JSONDecoder().decode(Document.self, from: FixtureLoader.data("fixtures/voice-lab/voice-references-cases.json"))
        #expect(document.schema == "voxclip-voice-references/1")
        #expect(document.constants.bound == VoiceSpeakerReferences.bound)
        #expect(document.cases.count == document.caseCount)
        var kinds = Set<String>()
        for item in document.cases {
            kinds.insert(item.kind)
            switch item.kind {
            case "usable":
                let expected = try #require(item.expected, "\(item.name)")
                #expect(VoiceSpeakerReferences.usable(item.speaker).map(\.contentKey) == expected.contentKeys, "\(item.name)")
                #expect(VoiceSpeakerReferences.learnedCount(item.speaker) == expected.learnedCount, "\(item.name)")
            case "match":
                let candidate = try #require(VoiceConsentRecord.decodeEmbedding(item.candidate ?? ""), "\(item.name)")
                let match = try VoiceSpeakerReferences.match(candidate, speaker: item.speaker)
                guard let expected = item.expected else { #expect(match == nil, "\(item.name)"); continue }
                switch try #require(match, "\(item.name)") {
                case .statement(let score):
                    #expect(expected.kind == "statement" && expected.contentKey == nil && expected.score == score, "\(item.name)")
                case .reference(let score, let contentKey):
                    #expect(expected.kind == "reference" && expected.contentKey == contentKey && expected.score == score, "\(item.name)")
                }
            case "learning":
                let expected = try #require(item.expected, "\(item.name)")
                let embedding = try #require(VoiceConsentRecord.decodeEmbedding(item.embedding ?? ""), "\(item.name)")
                let date = try #require(ISO8601DateFormatter().date(from: item.at ?? ""), "\(item.name)")
                let contentKey = try #require(item.contentKey, "\(item.name)"), model = try #require(item.model, "\(item.name)")
                do {
                    let learned = try VoiceSpeakerReferences.learning(embedding, contentKey: contentKey, model: model, at: date, into: item.speaker)
                    #expect(expected.refusal == nil, "\(item.name)")
                    let references = try #require(learned.references, "\(item.name)")
                    #expect(references.map(\.contentKey) == expected.contentKeys, "\(item.name)")
                    #expect(references.map(\.statementScore) == expected.statementScores, "\(item.name)")
                    let added = try #require(references.first { $0.contentKey == item.contentKey }, "\(item.name)")
                    #expect(added.addedAt == item.at && added.statementScore == expected.learnedScore, "\(item.name)")
                    #expect(learned.replacingReferences([]) == item.speaker.replacingReferences([]), "\(item.name)")
                    try VoiceSpeakerReferences.validate(learned)
                } catch let refusal as VoiceSpeakerReferences.Refusal {
                    #expect(expected.refusal == "\(refusal)", "\(item.name)")
                }
            default:
                Issue.record("unknown kind \(item.kind) in \(item.name)")
            }
        }
        #expect(kinds == ["usable", "match", "learning"])
    }
}
#endif
