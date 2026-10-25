import Foundation

public enum EditingPrimitives {
    public static func jsRound(_ value: Double) -> Double {
        let lower = floor(value)
        return value - lower >= 0.5 ? lower + 1 : lower
    }

    static func fixedOneDigits(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "0.0" }
        if value >= 1e21 { return value.description }
        let bits = value.bitPattern
        let exponentBits = Int((bits >> 52) & 0x7ff)
        let mantissa = (bits & 0x000f_ffff_ffff_ffff) | (exponentBits == 0 ? 0 : 1 << 52)
        let exponent = exponentBits == 0 ? -1074 : exponentBits - 1023 - 52
        let rounded: UInt64
        if exponent >= 0 {
            var digits = String(mantissa).utf8.map { Int($0 - 48) }
            for _ in 0..<exponent {
                var carry = 0
                for index in digits.indices.reversed() {
                    let doubled = digits[index] * 2 + carry
                    digits[index] = doubled % 10
                    carry = doubled / 10
                }
                if carry > 0 { digits.insert(carry, at: 0) }
            }
            return digits.map(String.init).joined() + ".0"
        } else if -exponent > 60 {
            rounded = 0
        } else {
            let shift = -exponent
            rounded = (10 * mantissa + (UInt64(1) << (shift - 1))) >> shift
        }
        return "\(rounded / 10).\(rounded % 10)"
    }

    public static func isJSWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09...0x0d, 0x20, 0xa0, 0x1680, 0x2000...0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000, 0xfeff: true
        default: false
        }
    }

    public static func jsTrim(_ text: String) -> String {
        let scalars = text.unicodeScalars
        let start = scalars.firstIndex { !isJSWhitespace($0) } ?? scalars.endIndex
        let end = scalars.lastIndex { !isJSWhitespace($0) }.map { scalars.index(after: $0) } ?? start
        return String(scalars[start..<end])
    }

    public static func splitWords(_ text: String) -> [String] {
        text.unicodeScalars.split(whereSeparator: isJSWhitespace).map(String.init)
    }

    public static func normalizeForMatch(_ text: String) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            let lower = scalar.value == 0x130 ? "i" : scalar.properties.lowercaseMapping
            for lowered in lower.unicodeScalars {
                switch lowered.properties.generalCategory {
                case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
                     .decimalNumber, .letterNumber, .otherNumber: result.unicodeScalars.append(lowered)
                default: break
                }
            }
        }
        return result
    }

    static func stableSorted<Value>(_ values: [Value], by key: (Value) -> Double) -> [Value] {
        values.enumerated().sorted {
            let left = key($0.element), right = key($1.element)
            return left == right ? $0.offset < $1.offset : left < right
        }.map(\.element)
    }

    static func filler(_ text: String) -> Bool {
        var bytes = Array(text.utf8)
        if let last = bytes.last, [UInt8(44), 46, 33, 63].contains(last) { bytes.removeLast() }
        bytes = bytes.map { (65...90).contains($0) ? $0 + 32 : $0 }
        for (prefix, repeated) in [([UInt8(117)], UInt8(109)), ([117], 104), ([101, 114], 109), ([104, 109], 109)] {
            if bytes.count > prefix.count, bytes.starts(with: prefix), bytes.dropFirst(prefix.count).allSatisfy({ $0 == repeated }) { return true }
        }
        return false
    }
}

public func toFixed1(_ value: Double) -> String { EditingPrimitives.fixedOneDigits(value) }

public func detectPauses(_ words: [TimedWord], thresholdSeconds: Double) throws -> [Pause] {
    guard thresholdSeconds.isFinite, thresholdSeconds > 0 else { throw VoxClipError.projectUnreadable("Invalid pause threshold") }
    guard words.count > 1 else { return [] }
    return (0..<(words.count - 1)).compactMap { index in
        let before = words[index], after = words[index + 1]
        guard after.start - before.end >= thresholdSeconds else { return nil }
        return Pause(id: "pause-after-" + before.id, afterIndex: index, start: before.end, end: after.start)
    }
}

public func isFillerText(_ text: String) throws -> Bool { EditingPrimitives.filler(text) }

public func alignTranscriptWords(_ words: [RawWord], finalText: String) throws -> [RawWord] {
    let tokens = EditingPrimitives.splitWords(finalText)
    let matches = tokens.count == words.count && zip(words, tokens).allSatisfy {
        EditingPrimitives.normalizeForMatch($0.text) == EditingPrimitives.normalizeForMatch($1)
    }
    return words.enumerated().compactMap { index, word in
        var result = word
        if matches { result.text = tokens[index] }
        guard !EditingPrimitives.jsTrim(result.text).isEmpty, let start = result.start, let end = result.end,
              start.isFinite, end.isFinite, start >= 0, end > start else { return nil }
        return result
    }
}

public func estimateTranscriptWords(_ text: String, start: Double, end: Double) throws -> [RawWord] {
    let tokens = EditingPrimitives.splitWords(text)
    guard !tokens.isEmpty, start.isFinite, end.isFinite, end > start else { return [] }
    let length = tokens.reduce(0) { $0 + $1.utf16.count }
    var consumed = 0
    return tokens.map { token in
        let wordStart = start + Double(consumed) / Double(length) * (end - start)
        consumed += token.utf16.count
        let wordEnd = start + Double(consumed) / Double(length) * (end - start)
        return RawWord(text: token, start: wordStart, end: wordEnd, conf: 0)
    }
}
