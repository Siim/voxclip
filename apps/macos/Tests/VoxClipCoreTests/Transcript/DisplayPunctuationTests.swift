import Testing
@testable import VoxClipCore

/// The filler-comma rule (ux/v2 notes.md §5, impl-plan V8b): a comma folds with the filler
/// after it, never with a pause alone or at a paragraph's end. Display only.
@Suite("Display punctuation")
struct DisplayPunctuationTests {
    @Test func aCommaFoldsOnlyBeforeAFoldThatRemovesAFillerWithAWordAfterIt() {
        #expect(DisplayPunctuation.foldsComma("include,", foldRemovesFiller: true, wordFollows: true), "include, uh, um, source → include • source")
        #expect(!DisplayPunctuation.foldsComma("speaking,", foldRemovesFiller: false, wordFollows: true), "speaking, [pause] it keeps its comma")
        #expect(!DisplayPunctuation.foldsComma("subscription,", foldRemovesFiller: true, wordFollows: false), "a fold that ends the paragraph keeps it")
        #expect(!DisplayPunctuation.foldsComma("include", foldRemovesFiller: true, wordFollows: true), "no comma, nothing to fold")
        #expect(!DisplayPunctuation.foldsComma("end.", foldRemovesFiller: true, wordFollows: true), "only commas fold")
        #expect(!DisplayPunctuation.foldsComma(",", foldRemovesFiller: true, wordFollows: true), "a lone comma is the word itself")
    }

    @Test func fullWidthAndIdeographicCommasFoldToo() {
        #expect(DisplayPunctuation.foldsComma("それで、", foldRemovesFiller: true, wordFollows: true) && DisplayPunctuation.withoutComma("それで、") == "それで")
        #expect(DisplayPunctuation.foldsComma("然后，", foldRemovesFiller: true, wordFollows: true) && DisplayPunctuation.withoutComma("然后，") == "然后")
    }

    @Test func withoutCommaDropsOneTrailingCommaOnly() {
        #expect(DisplayPunctuation.withoutComma("include,") == "include")
        #expect(DisplayPunctuation.withoutComma("uh,") == "uh")
        #expect(DisplayPunctuation.withoutComma("well,,") == "well,")
        #expect(DisplayPunctuation.withoutComma("source") == "source" && DisplayPunctuation.withoutComma(",") == ",")
    }
}
