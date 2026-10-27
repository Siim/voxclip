import Foundation
import Testing
@testable import VoxClipCore

/// Replays shared/fixtures/clips/manual-titles.json, a manual clip's title (design §6.2), as VoxClip.Core's
/// ManualClipTitleTests does.
@Suite struct ManualClipTitleTests {
    struct Fixture: Decodable {
        struct Case: Decodable {
            let id: String
            let words: [String]
            let expected: String?
        }
        let fixture: String
        let maxWords: Int
        let maxCodePoints: Int
        let cases: [Case]
    }

    @Test func everyManualClipTitleCase() throws {
        let fixture = try JSONDecoder().decode(Fixture.self, from: FixtureLoader.data("fixtures/clips/manual-titles.json"))
        #expect(fixture.fixture == "voxclip-manual-clip-titles/1")
        #expect(fixture.maxWords == EditingAlgorithms.clipTitleWords)
        #expect(fixture.maxCodePoints == EditingLimits.maxClipTitleScalars)
        #expect(fixture.cases.count >= 10)
        for item in fixture.cases {
            let title = EditingAlgorithms.clipTitle(item.words)
            // Scalars, not String ==, which treats canonically equivalent text as equal; the vector means the exact text.
            let actual = title.map { Array($0.unicodeScalars) }
            let expected = item.expected.map { Array($0.unicodeScalars) }
            #expect(actual == expected, "\(item.id)")
            // Whatever the helper returns is already a title the reducer stores unchanged.
            guard let title else { continue }
            #expect(EditingPrimitives.jsTrim(title) == title, "\(item.id)")
            #expect(title.unicodeScalars.count <= EditingLimits.maxClipTitleScalars, "\(item.id)")
        }
    }

    /// Any sequence of the selection's words works: a slice of the transcript, or a lazy filter over it.
    @Test func anySequenceOfWordsWorks() {
        let words = (1...1_000).map { "w\($0)" }
        #expect(EditingAlgorithms.clipTitle(words[3...]) == "w4 w5 w6 w7 w8 w9 w10")
        #expect(EditingAlgorithms.clipTitle(words.lazy.filter { $0.hasSuffix("0") }) == "w10 w20 w30 w40 w50 w60 w70")
    }
}
