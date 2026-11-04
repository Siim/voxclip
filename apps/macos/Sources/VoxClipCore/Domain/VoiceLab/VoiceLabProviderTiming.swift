import Foundation

/// Why provider or recovered word timing could not be mapped to the typed words (voice-lab §8.5). The check name, the
/// character index and the two scalars at a text mismatch are logged in every build; the text never is.
public struct VoiceLabTimingFailure: Error, Equatable, Sendable {
    public let check: String
    public let index: Int?
    public let typedScalar: UInt32?
    public let providerScalar: UInt32?
    public init(check: String, index: Int? = nil, typedScalar: UInt32? = nil, providerScalar: UInt32? = nil) {
        self.check = check; self.index = index; self.typedScalar = typedScalar; self.providerScalar = providerScalar
    }
    /// `check=… index=… typed=U+… provider=U+…`, the release log's redacted evidence.
    public var logFields: String {
        func code(_ value: UInt32?) -> String { value.map { String(format: "U+%04X", $0) } ?? "none" }
        return "check=\(check) index=\(index.map(String.init) ?? "none") typed=\(code(typedScalar)) provider=\(code(providerScalar))"
    }
}

/// Maps provider character timing, or a transcription's word timing, to the typed words (voice-lab §8.5 "Tolerant
/// timing" and "Timing recovery"). Equal words keep their own times; a quirk that a correct reply can produce
/// (case, punctuation, apostrophes, whitespace, bracket directions, number/symbol expansion, a small overrun, a small
/// overlap) is accepted. Words that actually differ are refused. The result holds one timing per typed token with a
/// space between tokens, so `VoiceLabAlignment.words` rebuilds exactly the typed tokens.
public enum VoiceLabProviderTiming {
    /// Character times may end this far past the PCM; they are clamped to it.
    public static let overrunTolerance = 0.25
    /// A character may start this much before the one before it (rounding), never more.
    public static let orderTolerance = 0.001

    struct Token { var text: String; var folded: String; var start: Double; var end: Double }

    /// The first differing Unicode scalar of the typed and provider texts, for the release log.
    public static func firstMismatch(typed: String, provider: String) -> (index: Int, typed: UInt32?, provider: UInt32?) {
        let left = Array(typed.unicodeScalars), right = Array(provider.unicodeScalars)
        let index = (0..<max(left.count, right.count)).first { $0 >= left.count || $0 >= right.count || left[$0] != right[$0] } ?? 0
        return (index, index < left.count ? left[index].value : nil, index < right.count ? right[index].value : nil)
    }

    /// Provider `alignment` or `normalized_alignment` arrays, mapped to `typedText` (bracket tags removed).
    public static func retime(characters: [String], starts: [Double], ends: [Double], typedText: String,
                              duration: Double) throws -> [VoiceLabCharacterTiming] {
        guard !characters.isEmpty, characters.count == starts.count, starts.count == ends.count else {
            throw VoiceLabTimingFailure(check: "alignment_count_mismatch")
        }
        var latestStart = 0.0
        for index in characters.indices {
            let start = starts[index], end = ends[index]
            guard start.isFinite, end.isFinite, start >= 0, end >= start, start >= latestStart - orderTolerance else {
                throw VoiceLabTimingFailure(check: "alignment_time_order", index: index)
            }
            guard end <= duration + overrunTolerance else { throw VoiceLabTimingFailure(check: "alignment_end_beyond_duration", index: index) }
            latestStart = max(latestStart, start)
        }
        var scalars: [Unicode.Scalar] = [], scalarStarts: [Double] = [], scalarEnds: [Double] = []
        for index in characters.indices {
            let list = Array(characters[index].unicodeScalars)
            guard !list.isEmpty else { continue }
            let start = min(starts[index], duration), end = min(ends[index], duration)
            let step = (end - start) / Double(list.count)
            for (offset, scalar) in list.enumerated() {
                scalars.append(scalar)
                scalarStarts.append(start + step * Double(offset))
                scalarEnds.append(start + step * Double(offset + 1))
            }
        }
        blankBrackets(&scalars)
        var tokens: [Token] = []
        var buffer = String.UnicodeScalarView(), start = 0.0, end = 0.0
        func flush() {
            guard !buffer.isEmpty else { return }
            let text = String(buffer)
            tokens.append(Token(text: text, folded: fold(text), start: start, end: end))
            buffer = String.UnicodeScalarView()
        }
        for index in scalars.indices {
            if VoiceLabAlignment.isWhiteSpace(scalars[index]) { flush(); continue }
            if buffer.isEmpty { start = scalarStarts[index]; end = scalarEnds[index] }
            buffer.append(scalars[index]); end = max(end, scalarEnds[index])
        }
        flush()
        return try map(tokens, typedText: typedText, allowsWordGaps: false)
    }

    /// A transcription's words (the take's Scribe QA or the local transcriber) mapped to `typedText`. Words the
    /// transcription heard differently share their span; the word check, not timing, decides whether they differ.
    public static func recovered(_ words: [VoiceLabWord], typedText: String) throws -> [VoiceLabCharacterTiming] {
        var tokens: [Token] = []
        for word in words {
            guard word.start.isFinite, word.end.isFinite, word.end >= word.start, word.start >= 0 else { continue }
            for piece in word.text.unicodeScalars.split(whereSeparator: VoiceLabAlignment.isWhiteSpace) {
                let text = String(piece)
                tokens.append(Token(text: text, folded: fold(text), start: word.start, end: word.end))
            }
        }
        guard tokens.contains(where: { !$0.folded.isEmpty }) else { throw VoiceLabTimingFailure(check: "recovery_no_words") }
        return try map(tokens, typedText: typedText, allowsWordGaps: true)
    }

    static func fold(_ text: String) -> String { EditingPrimitives.normalizeForMatch(EditingPrimitives.nfc(text)) }

    /// A typed token a provider may say as other words: it holds a digit or a symbol ("21", "$12", "50%", "&").
    static func expands(_ token: String) -> Bool {
        token.unicodeScalars.contains { scalar in
            switch scalar.properties.generalCategory {
            case .decimalNumber, .letterNumber, .otherNumber, .currencySymbol, .mathSymbol, .otherSymbol: true
            default: "%&@#/+".unicodeScalars.contains(scalar)
            }
        }
    }

    /// Bracket expressions are directions, never typed words: their scalars become spaces.
    static func blankBrackets(_ scalars: inout [Unicode.Scalar]) {
        var open: Int?
        for index in scalars.indices {
            switch scalars[index] {
            case "[": open = index
            case "]":
                if let first = open { for inner in first...index { scalars[inner] = " " } }
                open = nil
            case "\r", "\n": open = nil
            default: break
            }
        }
    }

    private static func map(_ source: [Token], typedText: String, allowsWordGaps: Bool) throws -> [VoiceLabCharacterTiming] {
        let typed = VoiceLabAudioTags.strippingTags(typedText).unicodeScalars.split(whereSeparator: VoiceLabAlignment.isWhiteSpace).map(String.init)
        guard !typed.isEmpty else { throw VoiceLabTimingFailure(check: "alignment_text_mismatch") }
        let folded = typed.map(fold)
        // Longest common subsequence of folded tokens, walked forward; a tie drops the provider token first.
        let width = folded.count + 1
        var lengths = [Int](repeating: 0, count: (source.count + 1) * width)
        for left in source.indices.reversed() {
            for right in folded.indices.reversed() {
                let cell = left * width + right
                lengths[cell] = source[left].folded == folded[right] ? lengths[cell + width + 1] + 1 : max(lengths[cell + width], lengths[cell + 1])
            }
        }
        var result: [Token] = []
        var removed: [Token] = [], inserted: [Int] = []
        var left = 0, right = 0
        func next(after index: Int) -> Double? {
            var probe = index, other = right
            while probe < source.count && other < folded.count {
                if source[probe].folded == folded[other] { return source[probe].start }
                if lengths[(probe + 1) * width + other] >= lengths[probe * width + other + 1] { probe += 1 } else { other += 1 }
            }
            return nil
        }
        func flush() throws {
            guard !inserted.isEmpty || !removed.isEmpty else { return }
            defer { removed = []; inserted = [] }
            let previous = result.last?.end ?? 0
            let spoken = removed.contains { !$0.folded.isEmpty }
            let words = inserted.filter { !folded[$0].isEmpty }
            if !allowsWordGaps {
                if inserted.isEmpty && spoken { throw VoiceLabTimingFailure(check: "alignment_words_mismatch", index: result.count) }
                if !words.isEmpty && (!spoken || !words.allSatisfy({ expands(typed[$0]) })) {
                    throw VoiceLabTimingFailure(check: "alignment_words_mismatch", index: words[0])
                }
            }
            guard !inserted.isEmpty else { return }
            let first: Double, last: Double
            if let head = removed.first, let tail = removed.last {
                first = max(previous, head.start); last = max(first, tail.end)
            } else {
                first = previous; last = max(previous, next(after: left) ?? previous)
            }
            let total = Double(inserted.reduce(0) { $0 + max(1, typed[$1].unicodeScalars.count) })
            var cursor = first
            for (offset, index) in inserted.enumerated() {
                let end = offset == inserted.count - 1 ? last : cursor + (last - first) * Double(max(1, typed[index].unicodeScalars.count)) / total
                result.append(Token(text: typed[index], folded: folded[index], start: cursor, end: end))
                cursor = end
            }
        }
        while left < source.count || right < folded.count {
            if left < source.count && right < folded.count && source[left].folded == folded[right] {
                try flush()
                let previous = result.last?.end ?? 0
                let start = max(previous, source[left].start)
                result.append(Token(text: typed[right], folded: folded[right], start: start, end: max(start, source[left].end)))
                left += 1; right += 1
            } else if right >= folded.count || (left < source.count && lengths[(left + 1) * width + right] >= lengths[left * width + right + 1]) {
                removed.append(source[left]); left += 1
            } else {
                inserted.append(right); right += 1
            }
        }
        try flush()
        guard result.count == typed.count else { throw VoiceLabTimingFailure(check: "alignment_words_mismatch") }
        return result.enumerated().flatMap { index, word in
            let separator = index == 0 ? [] : [VoiceLabCharacterTiming(character: " ", start: word.start, end: word.start)]
            return separator + [VoiceLabCharacterTiming(character: word.text, start: word.start, end: word.end)]
        }
    }
}
