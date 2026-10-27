import Foundation

struct TightenLineEdit: Codable, Sendable, Equatable {
    var line: String
    var keep: String
    var kind: String

    init(line: String, keep: String, kind: String) {
        self.line = line
        self.keep = keep
        self.kind = kind
    }
}

struct TightenProposal: Codable, Sendable, Equatable {
    let lineLabel: String
    let kind: String
    let cutWordIds: [String]
    let preselected: Bool

    init(lineLabel: String, kind: String, cutWordIds: [String], preselected: Bool) {
        self.lineLabel = lineLabel
        self.kind = kind
        self.cutWordIds = cutWordIds
        self.preselected = preselected
    }
}

enum TightenRejectionReason: String, Codable, Sendable, Equatable {
    case unknownLine
    case duplicate
    case badKind
    case notSubsequence
    case splitWord
    case ineligibleWord
}

struct TightenRejectedEdit: Sendable, Equatable {
    let lineLabel: String
    let reason: TightenRejectionReason

    init(lineLabel: String, reason: TightenRejectionReason) {
        self.lineLabel = lineLabel
        self.reason = reason
    }
}

struct TightenValidationResult: Sendable, Equatable {
    let proposals: [TightenProposal]
    let rejectedEdits: [TightenRejectedEdit]
    var rejectedCount: Int { rejectedEdits.count }

    init(proposals: [TightenProposal], rejectedEdits: [TightenRejectedEdit] = []) {
        self.proposals = proposals
        self.rejectedEdits = rejectedEdits
    }
}

enum TightenValidationError: Error, Sendable, Equatable {
    case invalidConfiguration
    case invalidSource
}

struct TightenInput: Sendable, Equatable {
    let entries: [ClipWord]
    let wordIds: [Int: String]
    let eligibleWordIds: Set<String>

    init(
        transcript: Transcript,
        corrections: [String: String] = [:],
        cutWordIds: Set<String> = [],
        scope: ClipRange? = nil,
        maxWordTextLength: Int = 100
    ) throws {
        guard maxWordTextLength > 0 else { throw TightenValidationError.invalidConfiguration }
        var positions: [String: Int] = [:]
        for (position, word) in transcript.words.enumerated() {
            guard !word.id.isEmpty, positions.updateValue(position, forKey: word.id) == nil else {
                throw TightenValidationError.invalidSource
            }
        }
        var scopePositions: ClosedRange<Int>?
        if let scope {
            guard let start = positions[scope.startWordId], let end = positions[scope.endWordId], start <= end else {
                throw TightenValidationError.invalidSource
            }
            scopePositions = start...end
        }
        var entries: [ClipWord] = []
        var wordIds: [Int: String] = [:]
        for (position, word) in transcript.words.enumerated() {
            guard word.kind != .unlabeledSpeech, !cutWordIds.contains(word.id),
                  scopePositions?.contains(position) ?? true else { continue }
            let text = word.kind == .word ? corrections[word.id] ?? word.text : word.text
            var truncated = String.UnicodeScalarView()
            var length = 0
            for scalar in text.unicodeScalars {
                let scalarLength = scalar.value > 0xFFFF ? 2 : 1
                guard length + scalarLength <= maxWordTextLength else { break }
                truncated.append(scalar)
                length += scalarLength
            }
            entries.append(ClipWord(index: position, text: String(truncated), start: word.start, end: word.end))
            wordIds[position] = word.id
        }
        self.entries = entries
        self.wordIds = wordIds
        self.eligibleWordIds = Set(wordIds.values)
    }
}

enum TightenValidator {
    static func validate(
        _ edits: [TightenLineEdit],
        entries: [ClipWord],
        wordIds: [Int: String],
        lines: [TranscriptLine],
        eligibleWordIds: Set<String>,
        config: JSONValue
    ) throws -> TightenValidationResult {
        let rules = try TightenRules(config: config)
        let emittedLines = try sourceLines(entries: entries, wordIds: wordIds, lines: lines)
        var seenLabels: Set<String> = []
        var proposals: [TightenProposal] = []
        var rejectedEdits: [TightenRejectedEdit] = []

        for edit in edits {
            let label = AIText.trim(edit.line)
            guard let line = emittedLines[label] else {
                rejectedEdits.append(TightenRejectedEdit(lineLabel: label, reason: .unknownLine))
                continue
            }
            guard seenLabels.insert(label).inserted else {
                rejectedEdits.append(TightenRejectedEdit(lineLabel: label, reason: .duplicate))
                continue
            }
            guard rules.kinds.contains(edit.kind) else {
                rejectedEdits.append(TightenRejectedEdit(lineLabel: label, reason: .badKind))
                continue
            }
            let lineEntries = Array(entries[line.firstPos...line.lastPos])
            let entryTokens = lineEntries.map { rules.tokens($0.text) }
            let lineTokens = entryTokens.flatMap { $0 }
            let keepTokens = rules.tokens(edit.keep)
            var matched = Array(repeating: false, count: lineTokens.count)
            var cursor = lineTokens.count
            var isSubsequence = true
            for token in keepTokens.reversed() {
                while cursor > 0 && lineTokens[cursor - 1] != token { cursor -= 1 }
                guard cursor > 0 else {
                    isSubsequence = false
                    break
                }
                cursor -= 1
                matched[cursor] = true
            }
            guard isSubsequence else {
                rejectedEdits.append(TightenRejectedEdit(lineLabel: label, reason: .notSubsequence))
                continue
            }
            var kept: [Bool?] = []
            var tokenPosition = 0
            var splitWord = false
            for tokens in entryTokens {
                let matches = matched[tokenPosition..<(tokenPosition + tokens.count)].filter { $0 }.count
                if matches > 0 && matches < tokens.count { splitWord = true }
                kept.append(tokens.isEmpty ? nil : matches == tokens.count)
                tokenPosition += tokens.count
            }
            guard !splitWord else {
                rejectedEdits.append(TightenRejectedEdit(lineLabel: label, reason: .splitWord))
                continue
            }
            let firstFate = kept.compactMap { $0 }.first ?? false
            var precedingFate: Bool?
            for position in kept.indices {
                if let fate = kept[position] { precedingFate = fate }
                else { kept[position] = precedingFate ?? firstFate }
            }
            let cutEntries = lineEntries.indices.filter { kept[$0] == false }.map { lineEntries[$0] }
            guard !cutEntries.isEmpty else { continue }
            let cutIds = cutEntries.compactMap { wordIds[$0.index] }
            guard cutIds.allSatisfy({ eligibleWordIds.contains($0) }) else {
                rejectedEdits.append(TightenRejectedEdit(lineLabel: label, reason: .ineligibleWord))
                continue
            }
            let review = keepTokens.isEmpty
                ? lineEntries.count > rules.wholeLinePreselectMaxWords
                : Double(cutEntries.count) > rules.reviewCutFraction * Double(lineEntries.count)
            proposals.append(TightenProposal(lineLabel: label, kind: edit.kind, cutWordIds: cutIds, preselected: !review))
        }
        return TightenValidationResult(proposals: proposals, rejectedEdits: rejectedEdits)
    }

    private static func sourceLines(
        entries: [ClipWord], wordIds: [Int: String], lines: [TranscriptLine]
    ) throws -> [String: TranscriptLine] {
        var previousIndex = -1
        var seenIds: Set<String> = []
        for entry in entries {
            guard entry.index > previousIndex, let id = wordIds[entry.index], !id.isEmpty,
                  seenIds.insert(id).inserted else { throw TightenValidationError.invalidSource }
            previousIndex = entry.index
        }
        var emitted: [String: TranscriptLine] = [:]
        var seenPositions: Set<Int> = []
        for line in lines {
            guard line.firstPos >= 0, line.firstPos <= line.lastPos, line.lastPos < entries.count else {
                throw TightenValidationError.invalidSource
            }
            let label = "[\(line.firstIndex)-\(line.lastIndex)]"
            let parts = line.text.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
            guard entries[line.firstPos].index == line.firstIndex, entries[line.lastPos].index == line.lastIndex,
                  parts.count == 3, parts[0] == label,
                  parts[2] == entries[line.firstPos...line.lastPos].map(\.text).joined(separator: " "),
                  emitted.updateValue(line, forKey: label) == nil else {
                throw TightenValidationError.invalidSource
            }
            for position in line.firstPos...line.lastPos {
                guard seenPositions.insert(position).inserted else { throw TightenValidationError.invalidSource }
            }
        }
        return emitted
    }
}

private struct TightenRules {
    let kinds: Set<String>
    let edgeCharacters: Set<Unicode.Scalar>
    let reviewCutFraction: Double
    let wholeLinePreselectMaxWords: Int

    init(config: JSONValue) throws {
        guard case .string("NFC") = Self.value(config, at: ["normalization", "unicode"]),
              case .string("lowercase, invariant culture, full Unicode mapping") = Self.value(config, at: ["normalization", "case"]),
              case .string(let edges) = Self.value(config, at: ["normalization", "stripEdgeCharacters"]),
              case .number(let fraction) = Self.value(config, at: ["limits", "reviewCutFraction"]),
              fraction.isFinite, (0...1).contains(fraction),
              case .number(let wholeLineLimit) = Self.value(config, at: ["limits", "wholeLinePreselectMaxWords"]),
              let maximum = Int(exactly: wholeLineLimit), maximum >= 0,
              case .array(let enumValues) = Self.value(config, at: ["output", "schema", "properties", "edits", "items", "properties", "kind", "enum"])
        else { throw TightenValidationError.invalidConfiguration }
        let kinds = enumValues.compactMap { value -> String? in
            guard case .string(let kind) = value, !kind.isEmpty else { return nil }
            return kind
        }
        guard !kinds.isEmpty, kinds.count == enumValues.count, Set(kinds).count == kinds.count else {
            throw TightenValidationError.invalidConfiguration
        }
        self.kinds = Set(kinds)
        self.edgeCharacters = Set(edges.unicodeScalars)
        self.reviewCutFraction = fraction
        self.wholeLinePreselectMaxWords = maximum
    }

    func tokens(_ text: String) -> [String] {
        EditingPrimitives.splitWords(text).compactMap { part in
            let lower = EditingPrimitives.nfc(String(part)).lowercased(with: Locale(identifier: "en_US_POSIX"))
            var scalars = lower.unicodeScalars[...]
            while let first = scalars.first, edgeCharacters.contains(first) { scalars = scalars.dropFirst() }
            while let last = scalars.last, edgeCharacters.contains(last) { scalars = scalars.dropLast() }
            return scalars.isEmpty ? nil : String(scalars)
        }
    }

    private static func value(_ config: JSONValue, at path: [String]) -> JSONValue? {
        var current = config
        for key in path {
            guard case .object(let object) = current, let next = object[key] else { return nil }
            current = next
        }
        return current
    }
}
