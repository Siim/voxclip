import Foundation

/// The pure Fix with AI rules of voice-lab §8.1: sanitising, line matching, duplicates, deletions, Core's own length and the
/// checkThis badge. Labels and keys compare as scalar sequences, never by canonical equivalence.
/// Vectors: `shared/fixtures/voice-lab/patch-rewrite-cases.json`.
enum PatchRewriteValidator {
    /// One edit's text holds at most 2,000 UTF-8 bytes, and the kept edits' texts at most 20,000 together.
    static let maxEditBytes = 2_000
    static let maxTextBytes = 20_000

    struct Result: Equatable {
        var edits: [PatchRewriteEdit] = []
        var unknownLines = 0
        var duplicateLines = 0
        var malformedItems = 0
    }

    /// `items` already passed structural validation (ai.md §2.3). `sources` are the entry texts and the instruction. A malformed
    /// edit is dropped and counted before line matching; it never fails the reply.
    static func validate(_ items: [JSONValue], ranges: [PatchRewriteLineRange], sources: [String]) -> Result {
        let byLine = Dictionary(ranges.map { (Array($0.line.unicodeScalars), $0) }, uniquingKeysWith: { first, _ in first })
        let known = Sources(sources)
        var seen: Set<[Unicode.Scalar]> = []
        var result = Result()
        for item in items {
            guard let raw = item[ai: "line"].aiString, let text = item[ai: "text"].aiString, let reason = item[ai: "reason"].aiString,
                  !hasControl(text), !hasControl(reason), text.utf8.count <= maxEditBytes else { result.malformedItems += 1; continue }
            let line = AIText.trim(raw)
            let label = Array(line.unicodeScalars)
            guard let range = byLine[label] else { result.unknownLines += 1; continue }
            guard seen.insert(label).inserted else { result.duplicateLines += 1; continue }
            let length = VoiceLabTextLength.length(text)
            let deletion = AIText.trim(text).isEmpty
            result.edits.append(PatchRewriteEdit(line: line, text: text, reason: reason, length: length,
                                                 inRange: deletion || (range.minChars...range.maxChars).contains(length),
                                                 checkThis: known.flags(text), isDeletion: deletion))
        }
        return result
    }

    /// A control character (Cc) other than tab.
    private static func hasControl(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.properties.generalCategory == .control && $0 != "\t" }
    }

    /// The tokens and digit runs of the transcript and the instruction, which an edit's own may repeat without a badge.
    struct Sources {
        private static let sentenceEnd = #"[.!?。！？]["'”’)]*\z"#
        private static let urlMarker: [Unicode.Scalar] = [":", "/", "/"]
        private var keys: Set<[Unicode.Scalar]> = []
        private var digitRuns: Set<[Unicode.Scalar]> = []

        init(_ texts: [String]) {
            for text in texts {
                let normal = EditingPrimitives.nfc(text)
                digitRuns.formUnion(Self.digitRuns(normal))
                keys.formUnion(EditingPrimitives.splitWords(normal).map(Self.key))
            }
        }

        /// True when NFC `text` holds a digit run, a URL, or a capitalised token not at a sentence start, that no source has.
        func flags(_ text: String) -> Bool { flaggedTokens(text).contains(true) }

        /// The rule of `flags` for each `splitWords` token of NFC `text`, in order: the token holds a digit run no source has,
        /// or is a URL or a capitalised token not at a sentence start that does not appear. A digit run never spans white
        /// space, so `flags` is true exactly when one token is. `ScopeRewriteDiff` gives each hunk the flags of its own tokens.
        func flaggedTokens(_ text: String) -> [Bool] {
            let tokens = EditingPrimitives.splitWords(EditingPrimitives.nfc(text))
            return tokens.indices.map { (index: Int) -> Bool in
                let token = tokens[index]
                if Self.digitRuns(token).contains(where: { !digitRuns.contains($0) }) { return true }
                let key = Self.key(token)
                if Self.isURL(token), !keys.contains(key) { return true }
                let atStart = index == 0 || tokens[index - 1].range(of: Self.sentenceEnd, options: .regularExpression) != nil
                return !atStart && Self.isCapitalised(token) && !keys.contains(key)
            }
        }

        /// normalizeForMatch (editing §4.7) without its lowercase step: equal keys mean equal normalizeForMatch, and case counts.
        static func key(_ token: String) -> [Unicode.Scalar] {
            token.unicodeScalars.filter { isLetter($0) || isNumber($0) }
        }

        static func digitRuns(_ text: String) -> [[Unicode.Scalar]] {
            var runs: [[Unicode.Scalar]] = []
            var run: [Unicode.Scalar] = []
            for scalar in text.unicodeScalars {
                if scalar.properties.generalCategory == .decimalNumber { run.append(scalar) }
                else if !run.isEmpty { runs.append(run); run = [] }
            }
            return run.isEmpty ? runs : runs + [run]
        }

        /// A token holding "://", or starting with "www." in either ASCII case once leading non-letters and non-digits are skipped.
        static func isURL(_ token: String) -> Bool {
            if Array(token.unicodeScalars).firstRange(of: urlMarker) != nil { return true }
            let start = token.unicodeScalars.drop { !isLetter($0) && !isNumber($0) }.prefix(4).map(\.value)
            return start.count == 4 && start.prefix(3).allSatisfy { $0 == 0x77 || $0 == 0x57 } && start[3] == 0x2E
        }

        static func isCapitalised(_ token: String) -> Bool {
            guard let letter = token.unicodeScalars.first(where: isLetter) else { return false }
            return [.uppercaseLetter, .titlecaseLetter].contains(letter.properties.generalCategory)
        }

        private static func isLetter(_ scalar: Unicode.Scalar) -> Bool {
            [.uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter].contains(scalar.properties.generalCategory)
        }

        private static func isNumber(_ scalar: Unicode.Scalar) -> Bool {
            [.decimalNumber, .letterNumber, .otherNumber].contains(scalar.properties.generalCategory)
        }
    }
}
