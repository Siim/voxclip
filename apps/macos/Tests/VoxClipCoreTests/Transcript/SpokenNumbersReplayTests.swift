import Foundation
import Testing
@testable import VoxClipCore

/// Numbers matched however they are written (voice-lab §8.11, ADR-R49), replayed from
/// shared/fixtures/spoken-numbers/number-cases.json, which tools/fixtures/spoken-numbers/generate_number_cases.py writes
/// and the Windows Core replays too.
@Suite(.offlineFixtures) struct SpokenNumbersReplayTests {
    static let path = "fixtures/spoken-numbers/number-cases.json"

    struct Cases: Decodable {
        struct Parsed: Decodable { let value: String; let digits: String; let ordinal: Bool; let unit: String? }
        struct NumeralRow: Decodable { let raw: String; let numeral: Parsed? }
        struct AlignmentRow: Decodable {
            let id: String, category: String, expected: String, recognized: String
            let expectedTokens: [String], recognizedTokens: [String], pairs: [[Int]]
            let unverifiedExpected: [Int], unverifiedRecognized: [Int], unverifiedNumbers: Int
            let ratio: Double, complete: Bool
        }
        struct TakeRow: Decodable {
            let id: String, expected: String, recognized: [String], transcriptMatch: Double, passed: Bool, unverifiedNumbers: Int
        }
        struct Constants: Decodable { let longestRun: Int; let longestUnverifiedRun: Int }
        let schema: String
        let caseCount: Int
        let counts: [String: Int]
        let constants: Constants
        let numerals: [NumeralRow]
        let alignments: [AlignmentRow]
        let takeChecks: [TakeRow]
    }

    static func cases() throws -> Cases { try JSONDecoder().decode(Cases.self, from: FixtureLoader.data(path)) }

    @Test func theFileHasItsSchemaKeysAndCount() throws {
        let object = try #require(try JSONSerialization.jsonObject(with: FixtureLoader.data(Self.path)) as? [String: Any])
        #expect(Set(object.keys) == ["schema", "description", "constants", "caseCount", "counts", "numerals", "alignments", "takeChecks"])
        let cases = try Self.cases()
        #expect(cases.schema == "voxclip-spoken-numbers-cases/1")
        #expect(cases.caseCount == 79)
        #expect(cases.caseCount == cases.numerals.count + cases.alignments.count + cases.takeChecks.count)
        #expect(cases.counts.values.reduce(0, +) == cases.alignments.count)
        #expect(Set(cases.counts.keys) == ["cardinal", "yearPair", "digits", "ordinal", "separators", "currency", "percent", "units",
                                          "nonMatch", "otherLanguage", "plain"])
        #expect(cases.constants.longestRun == SpokenNumbers.longestRun)
        #expect(cases.constants.longestUnverifiedRun == SpokenNumbers.longestUnverifiedRun)
    }

    @Test func numeralsParseAsTheGeneratorSays() throws {
        for row in try Self.cases().numerals {
            let parsed = SpokenNumbers.numeral(row.raw)
            #expect(parsed?.value == row.numeral?.value, "\(row.raw)")
            #expect(parsed?.digits == row.numeral?.digits, "\(row.raw)")
            #expect(parsed?.ordinal == row.numeral?.ordinal, "\(row.raw)")
            #expect(parsed?.unit?.rawValue == row.numeral?.unit, "\(row.raw)")
        }
    }

    @Test func everyAlignmentReplays() throws {
        for row in try Self.cases().alignments {
            let expected = SpokenNumbers.tokens(row.expected), recognized = SpokenNumbers.tokens(row.recognized)
            #expect(expected.map(\.text) == row.expectedTokens, "\(row.id)")
            #expect(recognized.map(\.text) == row.recognizedTokens, "\(row.id)")
            let alignment = SpokenNumbers.align(expected: expected, recognized: recognized)
            #expect(alignment.pairs.map { [$0.expected, $0.recognized] } == row.pairs, "\(row.id)")
            #expect(alignment.unverifiedExpected == row.unverifiedExpected, "\(row.id)")
            #expect(alignment.unverifiedRecognized == row.unverifiedRecognized, "\(row.id)")
            #expect(alignment.unverifiedNumbers == row.unverifiedNumbers, "\(row.id)")
            #expect(alignment.ratio == row.ratio, "\(row.id): \(alignment.ratio)")
            #expect(alignment.complete == row.complete, "\(row.id)")
        }
    }

    @Test func everyTakeCheckReplays() throws {
        let samples: [Float] = (0..<16_000).map { Float(0.1 * sin(2 * Double.pi * 220 * Double($0) / 16_000)) }
        for row in try Self.cases().takeChecks {
            let qa = try VoiceLabTakeQuality.evaluate(expected: row.expected, recognized: row.recognized, mixed: samples, sampleRate: 16_000,
                                                      seams: [], speakerScore: 0.9, threshold: 0.45)
            #expect(qa.values.transcriptMatch == row.transcriptMatch, "\(row.id): \(String(describing: qa.values.transcriptMatch))")
            #expect(!qa.failures.contains(.transcript) == row.passed, "\(row.id)")
            #expect(qa.unverifiedNumbers == row.unverifiedNumbers, "\(row.id)")
        }
    }
}

/// Each rule on its own, both ways round.
struct SpokenNumbersTests {
    static func matches(_ expected: String, _ recognized: String) -> Bool {
        let alignment = SpokenNumbers.align(expected: SpokenNumbers.tokens(expected), recognized: SpokenNumbers.tokens(recognized))
        return alignment.complete && alignment.unverifiedNumbers == 0
    }

    @Test(arguments: [
        ("three hundred", "300"), ("two thousand twenty six", "2026"), ("one point five", "1.5"), ("a hundred", "100"),
        ("twenty twenty six", "2026"), ("nineteen ninety seven", "1997"), ("one two three", "123"), ("third", "3rd"),
        ("twenty first", "21st"), ("one thousand", "1,000"), ("three hundred dollars", "$300"), ("twenty euros", "€20"),
        ("five pounds", "£5"), ("fifty percent", "50%"), ("three hundred dollar bill", "$300 bill"), ("twenty-six", "26"),
    ])
    func eachReadingMatchesBothWays(words: String, numeral: String) {
        #expect(Self.matches(words, numeral), "\(words) / \(numeral)")
        #expect(Self.matches(numeral, words), "\(numeral) / \(words)")
    }

    @Test(arguments: [
        ("three hundred", "30"), ("twenty twenty six", "2025"), ("three hundred dollars", "$30"), ("one point five", "15"),
        ("third", "3"), ("three", "3rd"), ("three hundred euros", "$300"), ("one two three", "124"),
    ])
    func aWrongNumberStaysAMismatch(words: String, numeral: String) {
        #expect(!Self.matches(words, numeral), "\(words) / \(numeral)")
        #expect(!Self.matches(numeral, words), "\(numeral) / \(words)")
    }

    @Test func aNumeralAgainstAnotherLanguageIsUnverified() {
        let alignment = SpokenNumbers.align(expected: SpokenNumbers.tokens("il a 300 ans"), recognized: SpokenNumbers.tokens("il a trois cents ans"))
        #expect(alignment.unverifiedNumbers == 1 && alignment.unverifiedExpected == [2] && alignment.unverifiedRecognized == [2, 3])
        #expect(alignment.complete && alignment.ratio == 1)
        // English number words in the gap are never another language: "three hundred" for "30" stays a mismatch.
        let english = SpokenNumbers.align(expected: SpokenNumbers.tokens("we had 30 people"), recognized: SpokenNumbers.tokens("we had three hundred people"))
        #expect(english.unverifiedNumbers == 0 && !english.complete)
    }

    @Test func theTakeQAPassesAShortPhraseThatSaysTheNumber() throws {
        let samples: [Float] = (0..<16_000).map { Float(0.1 * sin(2 * Double.pi * 220 * Double($0) / 16_000)) }
        func failures(_ heard: [String]) throws -> [VoiceLabTakeQAFailure] {
            try VoiceLabTakeQuality.evaluate(expected: "$300 is enough", recognized: heard, mixed: samples, sampleRate: 16_000,
                                             seams: [], speakerScore: 0.9, threshold: 0.45).failures
        }
        #expect(try failures(["three", "hundred", "dollars", "is", "enough"]).isEmpty)
        #expect(try failures(["$30", "is", "enough"]) == [.transcript])
        #expect(try VoiceLabTakeQuality.transcriptRatio(expected: ["$300", "is", "enough"], recognized: ["three", "hundred", "dollars", "is", "enough"]) == 1)
    }
}
