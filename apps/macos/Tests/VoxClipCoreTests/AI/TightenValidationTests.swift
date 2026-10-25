import Foundation
import Testing
@testable import VoxClipCore

@Suite("Tighten validation")
struct TightenValidationTests {
    private var normativeSource: TightenTestSource {
        TightenTestSource(["So,", "um,", "we", "we", "went", "to", "the", "uh", "the", "store."], startingAt: 40)
    }

    @Test("T1 and T8 retain the later repeated words", arguments: ["So, we went to the store.", "so WE went to the store"])
    func rightmostAlignment(_ keep: String) throws {
        let result = try normativeSource.validate([TightenLineEdit(line: "[40-49]", keep: keep, kind: "filler")])
        #expect(result.proposals == [TightenProposal(
            lineLabel: "[40-49]", kind: "filler", cutWordIds: ["word-41", "word-42", "word-46", "word-47"], preselected: true
        )])
        #expect(result.rejectedCount == 0)
    }

    @Test("T2 rejects rewriting, insertion, translation, and reordering", arguments: [
        "So we went to the shop.", "So we quickly went to the store.", "store we went", "Me läksime poodi", "So we go to the store."
    ])
    func rejectNonSubsequence(_ keep: String) throws {
        let result = try normativeSource.validate([TightenLineEdit(line: "[40-49]", keep: keep, kind: "filler")])
        #expect(result.proposals.isEmpty)
        #expect(result.rejectedEdits.map(\.reason) == [.notSubsequence])
    }

    @Test("T3 preselects deletion of ten entries")
    func wholeNormativeLine() throws {
        let result = try normativeSource.validate([TightenLineEdit(line: "[40-49]", keep: "", kind: "false_start")])
        #expect(result.proposals.first?.cutWordIds == (40...49).map { "word-\($0)" })
        #expect(result.proposals.first?.preselected == true)
    }

    @Test("T4 requires review of a large partial deletion")
    func largePartialDeletion() throws {
        let result = try normativeSource.validate([TightenLineEdit(line: "[40-49]", keep: "store", kind: "repetition")])
        #expect(result.proposals.first?.cutWordIds == (40...48).map { "word-\($0)" })
        #expect(result.proposals.first?.preselected == false)
    }

    @Test("T5 accepts only exact emitted labels", arguments: ["[99-120]", "[40]", "[41-49]", "40-49", "[40-49] 0:00", ""])
    func unknownLabels(_ label: String) throws {
        let result = try normativeSource.validate([TightenLineEdit(line: label, keep: "", kind: "filler")])
        #expect(result.proposals.isEmpty)
        #expect(result.rejectedEdits.map(\.reason) == [.unknownLine])
    }

    @Test("Line labels are trimmed without changing their identity")
    func trimmedLabel() throws {
        let result = try normativeSource.validate([TightenLineEdit(line: "\n\t\u{2003}[40-49]\u{2003} ", keep: "", kind: "filler")])
        #expect(result.proposals.first?.lineLabel == "[40-49]")
        #expect(result.rejectedCount == 0)
    }

    @Test("T6 rejects a partial multi-token corrected entry")
    func splitWord() throws {
        let source = TightenTestSource(["going to", "win."], startingAt: 50)
        let result = try source.validate([TightenLineEdit(line: "[50-51]", keep: "going win", kind: "self_correction")])
        #expect(result.proposals.isEmpty)
        #expect(result.rejectedEdits.map(\.reason) == [.splitWord])
        let wholeEntry = try source.validate([TightenLineEdit(line: "[50-51]", keep: "going to", kind: "self_correction")])
        #expect(wholeEntry.proposals.first?.cutWordIds == ["word-51"])
        let deletedEntry = try source.validate([TightenLineEdit(line: "[50-51]", keep: "win", kind: "self_correction")])
        #expect(deletedEntry.proposals.first?.cutWordIds == ["word-50"])
    }

    @Test("T7 punctuation follows the preceding token-bearing entry")
    func normativePunctuation() throws {
        let source = TightenTestSource(["Well", "—", "um", "yes."], startingAt: 60)
        let result = try source.validate([TightenLineEdit(line: "[60-63]", keep: "Well yes.", kind: "filler")])
        #expect(result.proposals.first?.cutWordIds == ["word-62"])
    }

    @Test("Leading punctuation follows the first lexical entry; later punctuation follows the preceding one")
    func punctuationFate() throws {
        let source = TightenTestSource(["—", "«", "Well", "—", "um", "…", "yes.", ")"])
        let keptBeginning = try source.validate([TightenLineEdit(line: "[0-7]", keep: "Well yes", kind: "filler")])
        #expect(keptBeginning.proposals.first?.cutWordIds == ["word-4", "word-5"])
        let cutBeginning = try source.validate([TightenLineEdit(line: "[0-7]", keep: "yes", kind: "false_start")])
        #expect(cutBeginning.proposals.first?.cutWordIds == (0...5).map { "word-\($0)" })
    }

    @Test("NFC, invariant full Unicode lowercase, Unicode whitespace, and repeated edge stripping")
    func unicodeNormalization() throws {
        let source = TightenTestSource(["UM", "«E\u{301}TÉ!»", "İ", "Straße", "O’NEILL", "co-op", "3.14", "foo/bar", "ΟΣ"])
        let keep = "\u{00A0}ÉTÉ\tI\u{0307}\nstraße\u{2003}o’neill co-op 3.14 foo/bar ος\u{3000}"
        let result = try source.validate([TightenLineEdit(line: "[0-8]", keep: keep, kind: "filler")])
        #expect(result.proposals.first?.cutWordIds == ["word-0"])
        #expect(result.rejectedCount == 0)
    }

    @Test("Normalization does not case-fold, strip internal punctuation, or transliterate", arguments: [
        "strasse co-op O’Neill 3.14", "Straße coop O’Neill 3.14", "Straße co-op ONeill 3.14", "Straße co-op O’Neill 314"
    ])
    func preserveTokenIdentity(_ keep: String) throws {
        let source = TightenTestSource(["um", "Straße", "co-op", "O’Neill", "3.14"])
        let result = try source.validate([TightenLineEdit(line: "[0-4]", keep: keep, kind: "filler")])
        #expect(result.rejectedEdits.map(\.reason) == [.notSubsequence])
    }

    @Test("Review limits count entries, including punctuation, rather than tokens")
    func entryBasedReview() throws {
        let source = TightenTestSource(["one two three four five six", "yes", "—"])
        let result = try source.validate([TightenLineEdit(line: "[0-2]", keep: "yes", kind: "detour")])
        #expect(result.proposals.first?.cutWordIds == ["word-0"])
        #expect(result.proposals.first?.preselected == true)
    }

    @Test("Review threshold is strict, not inclusive", arguments: [6, 7])
    func fractionBoundary(_ cutCount: Int) throws {
        let source = TightenTestSource((0..<10).map { "token\($0)" })
        let keep = source.entries.dropFirst(cutCount).map(\.text).joined(separator: " ")
        let result = try source.validate([TightenLineEdit(line: "[0-9]", keep: keep, kind: "repetition")])
        #expect(result.proposals.first?.preselected == (cutCount == 6))
    }

    @Test("Whole-line review threshold is strict", arguments: [1, 12, 13])
    func wholeLineBoundary(_ count: Int) throws {
        let source = TightenTestSource(Array(repeating: "word", count: count))
        let result = try source.validate([TightenLineEdit(line: "[0-\(count - 1)]", keep: " \n\t", kind: "false_start")])
        #expect(result.proposals.first?.cutWordIds.count == count)
        #expect(result.proposals.first?.preselected == (count <= 12))
    }

    @Test("Unknown kinds are rejected without trimming or case coercion", arguments: ["unknown", "FILLER", " filler ", ""])
    func invalidKinds(_ kind: String) throws {
        let result = try normativeSource.validate([TightenLineEdit(line: "[40-49]", keep: "", kind: kind)])
        #expect(result.proposals.isEmpty)
        #expect(result.rejectedEdits.map(\.reason) == [.badKind])
    }

    @Test("All shared schema kinds are supported", arguments: ["filler", "false_start", "repetition", "self_correction", "detour"])
    func schemaKinds(_ kind: String) throws {
        let result = try normativeSource.validate([TightenLineEdit(line: "[40-49]", keep: "", kind: kind)])
        #expect(result.proposals.first?.kind == kind)
        #expect(result.rejectedCount == 0)
    }

    @Test("Duplicate labels are reserved even when the first edit is rejected or ignored")
    func duplicateLabels() throws {
        let badKind = try normativeSource.validate([
            TightenLineEdit(line: "[40-49]", keep: "", kind: "bad"),
            TightenLineEdit(line: " [40-49] ", keep: "store", kind: "filler")
        ])
        #expect(badKind.rejectedEdits.map(\.reason) == [.badKind, .duplicate])
        let noOp = try normativeSource.validate([
            TightenLineEdit(line: "[40-49]", keep: normativeSource.entries.map(\.text).joined(separator: " "), kind: "filler"),
            TightenLineEdit(line: "[40-49]", keep: "", kind: "filler")
        ])
        #expect(noOp.proposals.isEmpty)
        #expect(noOp.rejectedEdits.map(\.reason) == [.duplicate])
    }

    @Test("Proposals and rejection details retain response arrival order")
    func arrivalOrder() throws {
        var source = TightenTestSource(["um", "first", "uh", "second"])
        source.lines = [TightenTestSource.line(source.entries, positions: 0...1), TightenTestSource.line(source.entries, positions: 2...3)]
        let result = try source.validate([
            TightenLineEdit(line: "[2-3]", keep: "second", kind: "filler"),
            TightenLineEdit(line: "[90-91]", keep: "", kind: "filler"),
            TightenLineEdit(line: "[0-1]", keep: "first", kind: "filler"),
            TightenLineEdit(line: "[2-3]", keep: "", kind: "filler")
        ])
        #expect(result.proposals.map(\.lineLabel) == ["[2-3]", "[0-1]"])
        #expect(result.rejectedEdits.map(\.reason) == [.unknownLine, .duplicate])
    }

    @Test("Gaps in absolute indices never become synthetic cut IDs")
    func absoluteIndexGaps() throws {
        let source = TightenTestSource(["um", "we", "we", "went"], indices: [40, 43, 47, 49])
        let result = try source.validate([TightenLineEdit(line: "[40-49]", keep: "we went", kind: "filler")])
        #expect(result.proposals.first?.cutWordIds == ["word-40", "word-43"])
    }

    @Test("A reply can only match and cut entries from its emitted line")
    func emittedLineMembership() throws {
        var source = TightenTestSource(["um", "keep", "outside"])
        source.lines = [TightenTestSource.line(source.entries, positions: 0...1)]
        let invalid = try source.validate([TightenLineEdit(line: "[0-1]", keep: "outside", kind: "filler")])
        #expect(invalid.rejectedEdits.map(\.reason) == [.notSubsequence])
        let valid = try source.validate([TightenLineEdit(line: "[0-1]", keep: "", kind: "false_start")])
        #expect(valid.proposals.first?.cutWordIds == ["word-0", "word-1"])
    }

    @Test("One ineligible cut rejects the entire edit; kept ineligible words are never cut")
    func eligibility() throws {
        var source = normativeSource
        source.eligibleWordIds.remove("word-41")
        let result = try source.validate([TightenLineEdit(line: "[40-49]", keep: "So we went to the store", kind: "filler")])
        #expect(result.proposals.isEmpty)
        #expect(result.rejectedEdits.map(\.reason) == [.ineligibleWord])
        source.eligibleWordIds = ["word-41"]
        let safe = try source.validate([TightenLineEdit(line: "[40-49]", keep: "So we we went to the uh the store", kind: "filler")])
        #expect(safe.proposals.first?.cutWordIds == ["word-41"])
    }

    @Test("Injected shared configuration controls limits, punctuation, and the kind enum")
    func injectedConfiguration() throws {
        var config = try TightenTestPrompt.load()
        config = TightenTestPrompt.replacing(.number(0.9), at: ["limits", "reviewCutFraction"], in: config)
        let partial = try normativeSource.validate([TightenLineEdit(line: "[40-49]", keep: "store", kind: "filler")], config: config)
        #expect(partial.proposals.first?.preselected == true)
        config = TightenTestPrompt.replacing(.number(9), at: ["limits", "wholeLinePreselectMaxWords"], in: config)
        let whole = try normativeSource.validate([TightenLineEdit(line: "[40-49]", keep: "", kind: "filler")], config: config)
        #expect(whole.proposals.first?.preselected == false)
        config = TightenTestPrompt.replacing(.string("/"), at: ["normalization", "stripEdgeCharacters"], in: config)
        config = TightenTestPrompt.replacing(.array([.string("custom")]), at: ["output", "schema", "properties", "edits", "items", "properties", "kind", "enum"], in: config)
        let custom = try TightenTestSource(["um", "/yes/"]).validate([TightenLineEdit(line: "[0-1]", keep: "yes", kind: "custom")], config: config)
        #expect(custom.proposals.first?.cutWordIds == ["word-0"])
    }

    @Test("Malformed configuration fails closed", arguments: [JSONValue.null, .number(-0.1), .number(1.1), .number(.nan), .number(.infinity), .string("0.6")])
    func invalidConfiguration(_ fraction: JSONValue) throws {
        let config = TightenTestPrompt.replacing(fraction, at: ["limits", "reviewCutFraction"], in: try TightenTestPrompt.load())
        #expect(throws: TightenValidationError.invalidConfiguration) {
            try normativeSource.validate([], config: config)
        }
    }

    @Test("Invalid kind schema values fail closed", arguments: [
        JSONValue.array([]), .array([.string("filler"), .string("filler")]), .array([.number(1)]), .string("filler")
    ])
    func invalidKindConfiguration(_ kinds: JSONValue) throws {
        let path = ["output", "schema", "properties", "edits", "items", "properties", "kind", "enum"]
        let config = TightenTestPrompt.replacing(kinds, at: path, in: try TightenTestPrompt.load())
        #expect(throws: TightenValidationError.invalidConfiguration) {
            try normativeSource.validate([], config: config)
        }
    }

    @Test("Unsupported normalization and fractional whole-line limits fail closed")
    func invalidNormalizationConfiguration() throws {
        let prompt = try TightenTestPrompt.load()
        for (path, value) in [
            (["normalization", "unicode"], JSONValue.string("NFKC")),
            (["normalization", "case"], JSONValue.string("casefold")),
            (["limits", "wholeLinePreselectMaxWords"], JSONValue.number(12.5)),
            (["limits", "wholeLinePreselectMaxWords"], JSONValue.number(-1)),
            (["limits", "wholeLinePreselectMaxWords"], JSONValue.number(.infinity))
        ] {
            let config = TightenTestPrompt.replacing(value, at: path, in: prompt)
            #expect(throws: TightenValidationError.invalidConfiguration) {
                try normativeSource.validate([], config: config)
            }
        }
    }

    @Test("Malformed source snapshots cannot produce cuts", arguments: 0..<7)
    func invalidSource(_ variant: Int) throws {
        var source = TightenTestSource(["um", "yes"])
        switch variant {
        case 0: source.wordIds.removeValue(forKey: 0)
        case 1: source.wordIds[1] = source.wordIds[0]
        case 2: source.entries[1].index = 0
        case 3: source.lines[0].firstPos = -1
        case 4: source.lines[0].lastPos = 2
        case 5: source.lines[0].text = "[0-1] 0:00 different words"
        default: source.lines.append(source.lines[0])
        }
        #expect(throws: TightenValidationError.invalidSource) {
            try source.validate([TightenLineEdit(line: "[0-1]", keep: "yes", kind: "filler")])
        }
    }

    @Test("Empty input, no-op edits, and validation are deterministic")
    func noMutation() throws {
        let empty = try TightenTestSource([]).validate([])
        #expect(empty.proposals.isEmpty)
        #expect(empty.rejectedCount == 0)
        let source = normativeSource
        let entries = source.entries
        let wordIds = source.wordIds
        let lines = source.lines
        let eligible = source.eligibleWordIds
        let edits = [TightenLineEdit(line: "[40-49]", keep: "So we went to the store", kind: "filler")]
        #expect(try source.validate(edits) == source.validate(edits))
        #expect(source.entries == entries)
        #expect(source.wordIds == wordIds)
        #expect(source.lines == lines)
        #expect(source.eligibleWordIds == eligible)
        let noOp = try source.validate([TightenLineEdit(line: "[40-49]", keep: source.entries.map(\.text).joined(separator: " "), kind: "filler")])
        #expect(noOp.proposals.isEmpty)
        #expect(noOp.rejectedCount == 0)
    }
}
