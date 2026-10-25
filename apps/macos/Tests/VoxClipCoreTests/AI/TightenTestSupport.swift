import Foundation
@testable import VoxClipCore

enum TightenTestPrompt {
    static func load() throws -> JSONValue {
        try FixtureLoader.decode(JSONValue.self, at: "prompts/ai-tighten.json")
    }

    static func replacing(_ value: JSONValue, at path: [String], in config: JSONValue) -> JSONValue {
        guard let key = path.first, case .object(var object) = config else { return value }
        object[key] = replacing(value, at: Array(path.dropFirst()), in: object[key] ?? .null)
        return .object(object)
    }
}

struct TightenTestSource {
    var entries: [ClipWord]
    var wordIds: [Int: String]
    var lines: [TranscriptLine]
    var eligibleWordIds: Set<String>

    init(_ texts: [String], startingAt start: Int = 0, indices: [Int]? = nil) {
        entries = texts.enumerated().map { position, text in
            ClipWord(index: indices?[position] ?? start + position, text: text, start: Double(position), end: Double(position) + 0.5)
        }
        wordIds = Dictionary(uniqueKeysWithValues: entries.map { ($0.index, "word-\($0.index)") })
        eligibleWordIds = Set(wordIds.values)
        lines = entries.isEmpty ? [] : [Self.line(entries, positions: 0...(entries.count - 1))]
    }

    init(_ input: TightenInput) {
        entries = input.entries
        wordIds = input.wordIds
        eligibleWordIds = input.eligibleWordIds
        lines = entries.isEmpty ? [] : [Self.line(entries, positions: 0...(entries.count - 1))]
    }

    static func line(_ entries: [ClipWord], positions: ClosedRange<Int>) -> TranscriptLine {
        let first = entries[positions.lowerBound]
        let last = entries[positions.upperBound]
        let text = entries[positions].map(\.text).joined(separator: " ")
        return TranscriptLine(
            firstPos: positions.lowerBound, lastPos: positions.upperBound,
            firstIndex: first.index, lastIndex: last.index, start: first.start, end: last.end,
            text: "[\(first.index)-\(last.index)] 0:00 \(text)"
        )
    }

    func validate(_ edits: [TightenLineEdit], config: JSONValue? = nil) throws -> TightenValidationResult {
        try TightenValidator.validate(
            edits, entries: entries, wordIds: wordIds, lines: lines,
            eligibleWordIds: eligibleWordIds, config: config ?? TightenTestPrompt.load()
        )
    }
}
