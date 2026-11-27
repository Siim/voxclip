import Foundation
import Testing
@testable import VoxClipCore

@Suite(.offlineFixtures) struct TakeMatchFixtures {
    private struct Vectors: Decodable {
        let constants: JSONValue
        let cases: [Vector]
    }

    private struct Vector: Decodable {
        let id: String
        let recordings: [Recording]
        let expected: JSONValue
    }

    private struct Recording: Decodable {
        let key: String
        let words: [TimedWord]
    }

    @Test func sharedVectorsReplayExactly() throws {
        let decoder = JSONDecoder()
        let data = try FixtureLoader.data("fixtures/recordings/take-match-cases.json")
        let vectors = try decoder.decode(Vectors.self, from: data)
        let constants: JSONValue = .object([
            "minimumSimilarity": .number(TakeMatch.minimumSimilarity),
            "minimumWordRatio": .number(TakeMatch.minimumWordRatio),
            "maximumWordRatio": .number(TakeMatch.maximumWordRatio),
            "sentencePauseSeconds": .number(TranscriptLineBoundary.pauseSeconds),
            "maxSentenceWords": .number(Double(TranscriptLineBoundary.maxWords)),
            "sentencePunctuation": .string(TranscriptLineBoundary.punctuation),
            "closingPunctuation": .string(TranscriptLineBoundary.closingPunctuation),
            "clauseBreaks": .string(TakeMatch.clauseBreaks),
            "maxRestartWords": .number(Double(TakeMatch.maxRestartWords)),
            "restartMajority": .number(TakeMatch.restartMajority),
            "falseStartSeconds": .number(TakeMatch.falseStartSeconds),
            "restartRunSeconds": .number(TakeMatch.restartRunSeconds),
            "minRestartRunWords": .number(Double(TakeMatch.minRestartRunWords)),
            "isolatedTailGapWords": .number(Double(TakeMatch.isolatedTailGapWords)),
            "restartPhrases": .object(TakeMatch.restartPhrases.mapValues { .array($0.map(JSONValue.string)) }),
        ])
        #expect(constants == vectors.constants)
        try #require(!vectors.cases.isEmpty)
        for vector in vectors.cases {
            let result = TakeMatch.build(vector.recordings.map { ($0.key, $0.words) })
            let actual = try decoder.decode(JSONValue.self, from: JSONEncoder().encode(result))
            #expect(actual == vector.expected, "\(vector.id)")
        }
    }

    @Test func sharedOpeningUsesOpaqueWordIds() {
        let primary = [TimedWord(id: "left:opaque", text: "Opening.", start: 0, end: 1)]
        let alternate = [TimedWord(id: "r2.w14", text: "opening!", start: 2, end: 3)]
        let result = TakeMatch.build([("first", primary), ("second", alternate)])
        #expect(result.beats.map { $0.takes.map(\.startWordId) } == [["left:opaque", "r2.w14"]])
    }
}
