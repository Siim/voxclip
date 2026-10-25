import Foundation
import Testing
@testable import VoxClipCore

@Suite("Tighten input")
struct TightenInputTests {
    private func transcript(_ words: [TimedWord]) -> Transcript {
        Transcript(
            words: words, durationSeconds: Double(words.count + 1),
            engine: EngineRef(id: .whispercpp, engineVersion: "fixture"), rawKey: "fixture",
            createdAt: Date(timeIntervalSince1970: 0)
        )
    }

    private func word(_ position: Int, _ text: String, kind: WordKind = .word) -> TimedWord {
        TimedWord(id: "word-\(position)", text: text, kind: kind, start: Double(position), end: Double(position) + 0.5)
    }

    @Test("Input preserves absolute gaps, applies word corrections, and excludes unlabeled speech")
    func scopedEntries() throws {
        let source = transcript([
            word(0, "outside"), word(1, "um"), word(2, "deleted"), word(3, "mumble", kind: .unlabeledSpeech),
            word(4, "gonna"), word(5, "(laughs)", kind: .event), word(6, "outside")
        ])
        let original = source
        let corrections = ["word-4": "going to", "word-5": "not an event correction", "word-3": "not speech"]
        let cuts: Set<String> = ["word-2"]
        let scope = ClipRange(id: "scope", startWordId: "word-1", endWordId: "word-5")
        let input = try TightenInput(transcript: source, corrections: corrections, cutWordIds: cuts, scope: scope)
        #expect(input.entries.map(\.index) == [1, 4, 5])
        #expect(input.entries.map(\.text) == ["um", "going to", "(laughs)"])
        #expect(input.wordIds == [1: "word-1", 4: "word-4", 5: "word-5"])
        #expect(input.eligibleWordIds == ["word-1", "word-4", "word-5"])
        #expect(input.entries.map(\.start) == [1, 4, 5])
        #expect(input.entries.map(\.end) == [1.5, 4.5, 5.5])
        let result = try TightenTestSource(input).validate([TightenLineEdit(line: "[1-5]", keep: "going to (laughs)", kind: "filler")])
        #expect(result.proposals.first?.cutWordIds == ["word-1"])
        #expect(source == original)
        #expect(corrections["word-4"] == "going to")
        #expect(cuts == ["word-2"])
        #expect(scope.startWordId == "word-1")
    }

    @Test("Cut endpoints still define the inclusive scope")
    func cutScopeEndpoints() throws {
        let source = transcript([word(0, "outside"), word(1, "cut"), word(2, "inside"), word(3, "cut"), word(4, "outside")])
        let input = try TightenInput(
            transcript: source, cutWordIds: ["word-1", "word-3"],
            scope: ClipRange(id: "scope", startWordId: "word-1", endWordId: "word-3")
        )
        #expect(input.entries.map(\.index) == [2])
    }

    @Test("Rebuilding after apply cannot propose an already-cut word")
    func rebuildAfterApply() throws {
        let source = transcript([word(0, "um"), word(1, "hello")])
        let original = source
        let firstInput = try TightenInput(transcript: source)
        let first = try TightenTestSource(firstInput).validate([TightenLineEdit(line: "[0-1]", keep: "hello", kind: "filler")])
        let cuts = Set(try #require(first.proposals.first).cutWordIds)
        let secondInput = try TightenInput(transcript: source, cutWordIds: cuts)
        #expect(secondInput.entries.map(\.index) == [1])
        let stale = try TightenTestSource(secondInput).validate([TightenLineEdit(line: "[0-1]", keep: "", kind: "filler")])
        #expect(stale.rejectedEdits.map(\.reason) == [.unknownLine])
        let second = try TightenTestSource(secondInput).validate([TightenLineEdit(line: "[1-1]", keep: "", kind: "false_start")])
        #expect(second.proposals.first?.cutWordIds == ["word-1"])
        #expect(source == original)
    }

    @Test("Input text length uses UTF-16 and never splits a surrogate pair")
    func surrogateSafeTextLimit() throws {
        let firstText = String(repeating: "a", count: 99) + "😀tail"
        let secondText = String(repeating: "b", count: 98) + "😀tail"
        let input = try TightenInput(transcript: transcript([word(0, firstText), word(1, secondText)]))
        #expect(input.entries[0].text == String(repeating: "a", count: 99))
        #expect(input.entries[1].text == String(repeating: "b", count: 98) + "😀")
        #expect(input.entries[1].text.utf16.count == 100)
        #expect(!input.entries.contains { $0.text.contains("\u{FFFD}") })
    }

    @Test("Empty, all-cut, and unlabeled-only inputs stay empty")
    func emptyInputs() throws {
        #expect(try TightenInput(transcript: transcript([])).entries.isEmpty)
        #expect(try TightenInput(transcript: transcript([word(0, "um")]), cutWordIds: ["word-0"]).entries.isEmpty)
        #expect(try TightenInput(transcript: transcript([word(0, "mumble", kind: .unlabeledSpeech)])).entries.isEmpty)
    }

    @Test("Invalid scope endpoints and ambiguous IDs fail closed")
    func invalidInput() throws {
        let source = transcript([word(0, "um"), word(1, "yes")])
        for scope in [
            ClipRange(id: "scope", startWordId: "missing", endWordId: "word-1"),
            ClipRange(id: "scope", startWordId: "word-1", endWordId: "word-0")
        ] {
            #expect(throws: TightenValidationError.invalidSource) {
                try TightenInput(transcript: source, scope: scope)
            }
        }
        #expect(throws: TightenValidationError.invalidSource) {
            try TightenInput(transcript: transcript([word(0, "um"), word(0, "yes")]))
        }
        #expect(throws: TightenValidationError.invalidConfiguration) {
            try TightenInput(transcript: source, maxWordTextLength: 0)
        }
    }
}
