import Foundation
import Testing
@testable import VoxClipCore

struct ProjectNormalizationTests {
    @Test func legacyProjectNormalizesBeforeValidationAndWritesCanonicalText() throws {
        let input = try FixtureLoader.data("fixtures/projects/normalization/legacy-nfc.voxclip")
        let expectedData = try FixtureLoader.data("fixtures/projects/normalization/legacy-nfc.expected.json")
        let (project, warnings) = try JSONProjectStore.decodeReportingWarnings(input)
        let expected = try JSONProjectStore.decode(expectedData)
        #expect(warnings.isEmpty)
        let encoded = try JSONProjectStore.encode(project)
        #expect(encoded == (try JSONProjectStore.encode(expected)))
        let saved = try JSONProjectStore.decode(encoded)
        #expect(saved.transcript?.words.first?.text.unicodeScalars.map(\.value) == [0xAC01])
        #expect(saved.edits.corrections["w5"]?.unicodeScalars.map(\.value) == [0xAC04])
        #expect(saved.transcript?.words.map(\.id) == expected.transcript?.words.map(\.id))
        #expect(saved.transcript?.words.map(\.start) == expected.transcript?.words.map(\.start))
        #expect(saved.transcript?.words.map(\.end) == expected.transcript?.words.map(\.end))
    }

    @Test func unicode16CompositesStayAndCompose() {
        for (input, expected) in [([0x16D68], [0x16D68]), ([0x16D69], [0x16D69]), ([0x16D6A], [0x16D6A]),
                                  ([0x16D67, 0x16D67], [0x16D68]), ([0x105D2, 0x307], [0x105C9])] {
            let text = String(String.UnicodeScalarView(input.compactMap { Unicode.Scalar($0) }))
            #expect(EditingPrimitives.nfc(text).unicodeScalars.map { Int($0.value) } == expected)
        }
    }
}
