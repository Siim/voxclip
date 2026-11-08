import Foundation

/// Numbers matched however they are written (voice-lab §8.11, ADR-R49). A recognizer writes "three hundred dollars" as
/// "$300" and a script may write "2026" where the voice says "twenty twenty six"; the take QA and the export check compare
/// words, so a numeral token on one side matches a run of English number words on the other when both say the same
/// number. Other languages have no spelled-number tables here: a numeral facing up to four other words alone in a gap of
/// the alignment is matched-unverified, neither matched nor a mismatch, and counted. The Windows Core has the same rules
/// (`SpokenNumbers.cs`); shared/fixtures/spoken-numbers/number-cases.json holds the vectors both replay.
public enum SpokenNumbers {
    /// A currency or percent a numeral carries ("$300", "50%") or a unit word after a number says.
    public enum Unit: String, Sendable { case dollar, euro, pound, percent }

    /// A number written in digits: "300", "$300", "1,000", "1.5", "21st", "50%", "300€".
    public struct Numeral: Sendable, Equatable {
        /// The value: the integer part with no leading zeros and the decimal part as written ("300", "1.5", "1000").
        public let value: String
        /// The integer part's digits as written, without separators ("007"); a digit-by-digit reading says these.
        public let digits: String
        public let ordinal: Bool
        public let unit: Unit?
        /// The readings this numeral matches: `c:` a cardinal value, `o:` an ordinal, `d:` digits read one by one.
        let keys: [String]

        init(value: String, digits: String, fraction: Bool, ordinal: Bool, unit: Unit?) {
            self.value = value; self.digits = digits; self.ordinal = ordinal; self.unit = unit
            keys = ordinal ? ["o:" + value] : fraction ? ["c:" + value] : ["c:" + value, "d:" + digits]
        }
    }

    /// One word of a transcript or a script: its text normalized for matching (`EditingPrimitives.normalizeForMatch`)
    /// and the number it writes in digits, if any.
    public struct Token: Sendable, Equatable {
        public var text: String
        public var numeral: Numeral?
        public init(text: String, numeral: Numeral? = nil) { self.text = text; self.numeral = numeral }
        /// One raw word: "$300," is the text "300" and the numeral 300 in dollars.
        public init(_ raw: String) {
            let composed = EditingPrimitives.nfc(raw)
            self.init(text: EditingPrimitives.normalizeForMatch(composed), numeral: SpokenNumbers.numeral(composed))
        }
    }

    /// The whitespace-separated words of `text` that keep a letter or a digit, in order.
    public static func tokens(_ text: String) -> [Token] {
        text.split(whereSeparator: \.isWhitespace).map { Token(String($0)) }.filter { !$0.text.isEmpty }
    }

    /// The pairs of an alignment and what was left unverified, as token indices.
    public struct Alignment: Sendable {
        /// Matched token pairs in order. A numeral matched to a run of words is paired with each word of the run, so an
        /// index may repeat on the numeral's side.
        public let pairs: [(expected: Int, recognized: Int)]
        /// The tokens of the gaps where a numeral faces words with no English number among them (another language).
        public let unverifiedExpected: [Int]
        public let unverifiedRecognized: [Int]
        /// How many such numbers there were.
        public let unverifiedNumbers: Int
        public let expectedCount: Int
        public let recognizedCount: Int

        public var matchedExpected: Int { Set(pairs.map(\.expected)).count }
        public var matchedRecognized: Int { Set(pairs.map(\.recognized)).count }
        /// The share of tokens matched, leaving unverified tokens out of both sides: 2 × pairs ÷ (expected + recognized)
        /// when no number is involved. 1 when every token is unverified.
        public var ratio: Double {
            let counted = expectedCount + recognizedCount - unverifiedExpected.count - unverifiedRecognized.count
            guard counted > 0 else { return 1 }
            return Double(matchedExpected + matchedRecognized) / Double(counted)
        }
        /// Every token on both sides is matched or unverified: the short-phrase exact rule (voice-lab §8.11).
        public var complete: Bool {
            matchedExpected + unverifiedExpected.count == expectedCount && matchedRecognized + unverifiedRecognized.count == recognizedCount
        }
    }

    /// The longest number-word run read against one numeral: "one hundred and twenty three thousand four hundred and
    /// fifty six" is 10 words.
    static let longestRun = 10
    /// The most words a numeral may face in another language's gap.
    static let longestUnverifiedRun = 4

    // MARK: Numerals

    static let leadingMarks: Set<UInt32> = [0x22, 0x27, 0x28, 0x5B, 0x7B, 0x201C, 0x2018]
    static let trailingMarks: Set<UInt32> = [0x2E, 0x2C, 0x21, 0x3F, 0x3B, 0x3A, 0x22, 0x27, 0x29, 0x5D, 0x7D, 0x201D, 0x2019, 0x2026]

    static func currency(_ scalar: UInt32) -> Unit? {
        switch scalar {
        case 0x24: .dollar
        case 0x20AC: .euro
        case 0xA3: .pound
        default: nil
        }
    }

    static func isDigit(_ scalar: UInt32) -> Bool { scalar >= 0x30 && scalar <= 0x39 }

    /// The number a raw word writes in digits, nil for anything else. Quotes, brackets and sentence punctuation around it
    /// are ignored; a currency sign may come before or after the digits, a percent sign or an ordinal suffix after them.
    /// Thousands separators are commas in groups of three; the decimal mark is a point.
    public static func numeral(_ raw: String) -> Numeral? {
        func text(_ values: some Sequence<UInt32>) -> String { String(String.UnicodeScalarView(values.compactMap(Unicode.Scalar.init))) }
        var scalars = raw.unicodeScalars.map(\.value)
        while let first = scalars.first, leadingMarks.contains(first) { scalars.removeFirst() }
        while let last = scalars.last, trailingMarks.contains(last) { scalars.removeLast() }
        var unit: Unit?
        if let first = scalars.first, let sign = currency(first) { unit = sign; scalars.removeFirst() }
        var index = 0
        var integer: [UInt32] = []
        var groups: [Int] = [0]
        while index < scalars.count, isDigit(scalars[index]) || (scalars[index] == 0x2C && index + 1 < scalars.count && isDigit(scalars[index + 1])) {
            if scalars[index] == 0x2C { groups.append(0) } else { integer.append(scalars[index]); groups[groups.count - 1] += 1 }
            index += 1
        }
        guard !integer.isEmpty else { return nil }
        if groups.count > 1 {
            guard (1...3).contains(groups[0]), groups.dropFirst().allSatisfy({ $0 == 3 }) else { return nil }
        }
        var fraction: [UInt32] = []
        if index + 1 < scalars.count, scalars[index] == 0x2E, isDigit(scalars[index + 1]) {
            index += 1
            while index < scalars.count, isDigit(scalars[index]) { fraction.append(scalars[index]); index += 1 }
        }
        let suffix = Array(scalars[index...])
        var ordinal = false
        if suffix.count == 1, unit == nil, suffix[0] == 0x25 {
            unit = .percent
        } else if suffix.count == 1, unit == nil, let sign = currency(suffix[0]) {
            unit = sign
        } else if suffix.count == 2, unit == nil, fraction.isEmpty {
            // ASCII letters only, so both Cores read the suffix alike.
            let letters = text(suffix.map { $0 >= 0x41 && $0 <= 0x5A ? $0 + 0x20 : $0 })
            guard ["st", "nd", "rd", "th"].contains(letters) else { return nil }
            ordinal = true
        } else if !suffix.isEmpty {
            return nil
        }
        let digits = text(integer)
        let trimmed = String(digits.drop { $0 == "0" })
        let whole = trimmed.isEmpty ? "0" : trimmed
        let value = fraction.isEmpty ? whole : whole + "." + text(fraction)
        return Numeral(value: value, digits: digits, fraction: !fraction.isEmpty, ordinal: ordinal, unit: unit)
    }

    // MARK: Number words

    enum Kind: Sendable { case unit, teen, tens, compound, scale, oh, article, and, point }
    struct Word: Sendable { let value: Int; let kind: Kind; let ordinal: Bool }

    static let lexicon: [String: Word] = {
        var words: [String: Word] = ["oh": Word(value: 0, kind: .oh, ordinal: false), "a": Word(value: 1, kind: .article, ordinal: false),
                                     "and": Word(value: 0, kind: .and, ordinal: false), "point": Word(value: 0, kind: .point, ordinal: false)]
        let units = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]
        let unitOrdinals = ["", "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth"]
        let teens = ["ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"]
        let teenOrdinals = ["tenth", "eleventh", "twelfth", "thirteenth", "fourteenth", "fifteenth", "sixteenth", "seventeenth",
                            "eighteenth", "nineteenth"]
        let tens = ["twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]
        let tensOrdinals = ["twentieth", "thirtieth", "fortieth", "fiftieth", "sixtieth", "seventieth", "eightieth", "ninetieth"]
        for (value, word) in units.enumerated() { words[word] = Word(value: value, kind: .unit, ordinal: false) }
        for (value, word) in unitOrdinals.enumerated() where value > 0 { words[word] = Word(value: value, kind: .unit, ordinal: true) }
        for (offset, word) in teens.enumerated() { words[word] = Word(value: 10 + offset, kind: .teen, ordinal: false) }
        for (offset, word) in teenOrdinals.enumerated() { words[word] = Word(value: 10 + offset, kind: .teen, ordinal: true) }
        for (offset, word) in tens.enumerated() {
            let value = 20 + 10 * offset
            words[word] = Word(value: value, kind: .tens, ordinal: false)
            words[tensOrdinals[offset]] = Word(value: value, kind: .tens, ordinal: true)
            // "twenty-six" is one token once its hyphen is stripped.
            for unit in 1...9 {
                words[word + units[unit]] = Word(value: value + unit, kind: .compound, ordinal: false)
                words[word + unitOrdinals[unit]] = Word(value: value + unit, kind: .compound, ordinal: true)
            }
        }
        for (value, word) in [(100, "hundred"), (1_000, "thousand"), (1_000_000, "million"), (1_000_000_000, "billion")] {
            words[word] = Word(value: value, kind: .scale, ordinal: false)
            words[word + "th"] = Word(value: value, kind: .scale, ordinal: true)
        }
        return words
    }()

    static func unitWord(_ text: String) -> Unit? {
        switch text {
        case "dollar", "dollars": .dollar
        case "euro", "euros": .euro
        case "pound", "pounds": .pound
        case "percent": .percent
        default: nil
        }
    }

    /// An English word that says a number by itself: never one of another language's words in an unverified gap.
    static func isNumberWord(_ text: String) -> Bool {
        guard let word = lexicon[text] else { return false }
        switch word.kind {
        case .unit, .teen, .tens, .compound, .scale: return true
        case .oh, .article, .and, .point: return false
        }
    }

    /// The digit a word says by itself in a digit run, a year or after "point": "zero", "oh", "one" … "nine".
    static func digit(_ text: String) -> Int? {
        guard let word = lexicon[text], !word.ordinal, word.kind == .unit || word.kind == .oh else { return nil }
        return word.value
    }

    /// A cardinal or ordinal reading of every word: "three hundred" c:300, "two thousand and twenty six" c:2026,
    /// "a hundred" c:100, "one point five" c:1.5, "twenty first" o:21.
    static func cardinalKey(_ words: [String]) -> String? {
        var total = 0, group = 0, part = 0
        var partKind: Kind?
        var hundred = false, ordinal = false, waiting = false
        var lastScale = Int.max
        for (index, text) in words.enumerated() {
            guard !ordinal, let word = lexicon[text] else { return nil }
            switch word.kind {
            case .article:
                guard index == 0, index + 1 < words.count, lexicon[words[index + 1]]?.kind == .scale else { return nil }
                part = 1; partKind = .unit; waiting = true
            case .and:
                guard partKind == nil, hundred || lastScale != Int.max, !waiting, index + 1 < words.count else { return nil }
                waiting = true
            case .point:
                guard !waiting, index + 1 < words.count else { return nil }
                var fraction = ""
                for following in words[(index + 1)...] {
                    guard let value = digit(following) else { return nil }
                    fraction += String(value)
                }
                return "c:" + String(total + group + part) + "." + fraction
            case .unit, .teen, .tens, .compound:
                // "zero" is a whole number by itself or before "point".
                if word.kind == .unit, word.value == 0 { guard index == 0, words.count == 1 || words[1] == "point" else { return nil } }
                if partKind == nil {
                    part = word.value; partKind = word.kind
                } else if partKind == .tens, word.kind == .unit, word.value > 0 {
                    part += word.value; partKind = .compound
                } else {
                    return nil
                }
                waiting = false; ordinal = word.ordinal
            case .scale:
                if word.value == 100 {
                    guard !hundred, partKind != nil, part >= 1 else { return nil }
                    group = part * 100; hundred = true
                } else {
                    let value = group + part
                    guard value >= 1, word.value < lastScale else { return nil }
                    total += value * word.value; group = 0; hundred = false; lastScale = word.value
                }
                part = 0; partKind = nil; waiting = false; ordinal = word.ordinal
            case .oh:
                return nil
            }
        }
        guard !waiting, partKind != nil || hundred || lastScale != Int.max else { return nil }
        return (ordinal ? "o:" : "c:") + String(total + group + part)
    }

    /// 10…99 in one word ("nineteen", "twenty", "twentysix") or two ("twenty six").
    static func twoDigits(_ words: ArraySlice<String>) -> Int? {
        let found = words.compactMap { lexicon[$0] }
        guard found.count == words.count, found.allSatisfy({ !$0.ordinal }) else { return nil }
        if found.count == 1, [.teen, .tens, .compound].contains(found[0].kind) { return found[0].value }
        if found.count == 2, found[0].kind == .tens, found[1].kind == .unit, found[1].value > 0 { return found[0].value + found[1].value }
        return nil
    }

    /// A year read in pairs: "twenty twenty six" c:2026, "nineteen ninety seven" c:1997, "nineteen oh five" c:1905,
    /// "nineteen hundred" c:1900.
    static func yearKey(_ words: [String]) -> String? {
        guard (2...4).contains(words.count) else { return nil }
        for split in 1...2 where split < words.count {
            guard let high = twoDigits(words[..<split]) else { continue }
            let rest = words[split...]
            var low: Int?
            if rest.count == 1, rest.first == "hundred" {
                low = 0
            } else if rest.count == 2, rest.first == "oh", let last = rest.last, let value = digit(last), value > 0 {
                low = value
            } else {
                low = twoDigits(rest)
            }
            if let low { return "c:" + String(high * 100 + low) }
        }
        return nil
    }

    /// Digits read one by one: "one two three" d:123, "two oh two six" d:2026.
    static func digitsKey(_ words: [String]) -> String? {
        guard words.count >= 2 else { return nil }
        var digits = ""
        for word in words {
            guard let value = digit(word) else { return nil }
            digits += String(value)
        }
        return "d:" + digits
    }

    /// Every reading of the whole run, in a fixed order, without repeats.
    static func readingKeys(_ words: [String]) -> [String] {
        var keys: [String] = []
        for key in [cardinalKey(words), yearKey(words), digitsKey(words)].compactMap({ $0 }) where !keys.contains(key) { keys.append(key) }
        return keys
    }

    // MARK: Alignment

    /// Words starting at one token that a single numeral on the other side may match: a number-word run with its
    /// readings, or a numeral followed by a unit word; either may end with a unit word ("dollars", "per cent").
    struct Group: Sendable {
        let length: Int
        let keys: [String]
        let numeral: Numeral?
        let unit: Unit?

        func matches(_ other: Numeral) -> Bool {
            if let unit, other.unit != unit { return false }
            if let numeral {
                return numeral.value == other.value && numeral.ordinal == other.ordinal && (numeral.unit == nil || numeral.unit == unit)
            }
            return keys.contains { other.keys.contains($0) }
        }
    }

    static func groups(_ tokens: [Token]) -> [[Group]] {
        tokens.indices.map { start in
            var found: [Group] = []
            for length in 1...longestRun where start + length <= tokens.count {
                let core: Group
                if let numeral = tokens[start].numeral {
                    guard length == 1 else { break }
                    core = Group(length: 1, keys: [], numeral: numeral, unit: nil)
                } else {
                    let last = tokens[start + length - 1]
                    guard last.numeral == nil, lexicon[last.text] != nil else { break }
                    let keys = readingKeys(tokens[start..<(start + length)].map(\.text))
                    guard !keys.isEmpty else { continue }
                    core = Group(length: length, keys: keys, numeral: nil, unit: nil)
                    found.append(core)
                }
                let next = start + length
                if next < tokens.count, tokens[next].numeral == nil, let unit = unitWord(tokens[next].text) {
                    found.append(Group(length: length + 1, keys: core.keys, numeral: core.numeral, unit: unit))
                }
                if next + 1 < tokens.count, tokens[next].text == "per", tokens[next + 1].text == "cent" {
                    found.append(Group(length: length + 2, keys: core.keys, numeral: core.numeral, unit: .percent))
                }
            }
            return found
        }
    }

    /// Whether two tokens are the same word: the same number for two numerals (a unit on one side only is fine), the
    /// same normalized bytes for two other words, never a numeral and another word.
    static func same(_ left: Token, _ right: Token) -> Bool {
        if let one = left.numeral, let other = right.numeral {
            return one.value == other.value && one.ordinal == other.ordinal && (one.unit == nil || other.unit == nil || one.unit == other.unit)
        }
        guard left.numeral == nil, right.numeral == nil else { return false }
        return left.text.utf8.elementsEqual(right.text.utf8)
    }

    /// The alignment that matches the most tokens on both sides, in order. A plain word pair counts two; a numeral
    /// matched to a run of n words counts 1 + n. Without numbers it is the longest common subsequence of equal tokens,
    /// with the same pairs the plain alignment chose. The gaps left over are then read for unverified numbers.
    public static func align(expected: [Token], recognized: [Token]) -> Alignment {
        let rows = expected.count, columns = recognized.count
        guard rows > 0, columns > 0 else {
            return Alignment(pairs: [], unverifiedExpected: [], unverifiedRecognized: [], unverifiedNumbers: 0,
                             expectedCount: rows, recognizedCount: columns)
        }
        // Number-word runs only matter against a numeral on the other side.
        let expectedGroups = recognized.contains { $0.numeral != nil } ? groups(expected) : [[Group]](repeating: [], count: rows)
        let recognizedGroups = expected.contains { $0.numeral != nil } ? groups(recognized) : [[Group]](repeating: [], count: columns)
        let width = columns + 1
        // score[(row * width) + column]: the most tokens matched in expected[row...] and recognized[column...].
        var score = [Int32](repeating: 0, count: (rows + 1) * width)
        for row in stride(from: rows - 1, through: 0, by: -1) {
            for column in stride(from: columns - 1, through: 0, by: -1) {
                let here = row * width + column
                var best = max(score[here + width], score[here + 1])
                if same(expected[row], recognized[column]) { best = max(best, score[here + width + 1] + 2) }
                if let numeral = expected[row].numeral {
                    for group in recognizedGroups[column] where group.matches(numeral) {
                        let gain = Int32(1 + group.length)
                        best = max(best, score[here + width + group.length] + gain)
                    }
                }
                if let numeral = recognized[column].numeral {
                    for group in expectedGroups[row] where group.matches(numeral) {
                        let gain = Int32(group.length + 1)
                        best = max(best, score[here + group.length * width + 1] + gain)
                    }
                }
                score[here] = best
            }
        }
        var pairs: [(expected: Int, recognized: Int)] = []
        var row = 0, column = 0
        while row < rows, column < columns {
            let here = row * width + column
            let target = score[here]
            if same(expected[row], recognized[column]), target == score[here + width + 1] + 2 {
                pairs.append((row, column)); row += 1; column += 1
                continue
            }
            if let numeral = expected[row].numeral, let group = recognizedGroups[column].first(where: {
                $0.matches(numeral) && target == score[here + width + $0.length] + Int32(1 + $0.length)
            }) {
                for offset in 0..<group.length { pairs.append((row, column + offset)) }
                row += 1; column += group.length
                continue
            }
            if let numeral = recognized[column].numeral, let group = expectedGroups[row].first(where: {
                $0.matches(numeral) && target == score[here + $0.length * width + 1] + Int32($0.length + 1)
            }) {
                for offset in 0..<group.length { pairs.append((row + offset, column)) }
                row += group.length; column += 1
                continue
            }
            if score[here + 1] >= score[here + width] { column += 1 } else { row += 1 }
        }
        return unverified(pairs: pairs, expected: expected, recognized: recognized)
    }

    /// Reads each gap between matches: one numeral alone on one side facing one to four words on the other, none of them
    /// a numeral or an English number word, is a number said in another language. Its tokens are unverified.
    static func unverified(pairs: [(expected: Int, recognized: Int)], expected: [Token], recognized: [Token]) -> Alignment {
        var unverifiedExpected: [Int] = [], unverifiedRecognized: [Int] = []
        var numbers = 0
        let anchors = [(expected: -1, recognized: -1)] + pairs + [(expected: expected.count, recognized: recognized.count)]
        func foreign(_ token: Token) -> Bool { token.numeral == nil && !isNumberWord(token.text) }
        for (left, right) in zip(anchors, anchors.dropFirst()) {
            let expectedGap = Array((left.expected + 1)..<max(left.expected + 1, right.expected))
            let recognizedGap = Array((left.recognized + 1)..<max(left.recognized + 1, right.recognized))
            let range = 1...longestUnverifiedRun
            if expectedGap.count == 1, expected[expectedGap[0]].numeral != nil, range.contains(recognizedGap.count),
               recognizedGap.allSatisfy({ foreign(recognized[$0]) }) {
                unverifiedExpected += expectedGap; unverifiedRecognized += recognizedGap; numbers += 1
            } else if recognizedGap.count == 1, recognized[recognizedGap[0]].numeral != nil, range.contains(expectedGap.count),
                      expectedGap.allSatisfy({ foreign(expected[$0]) }) {
                unverifiedExpected += expectedGap; unverifiedRecognized += recognizedGap; numbers += 1
            }
        }
        return Alignment(pairs: pairs, unverifiedExpected: unverifiedExpected, unverifiedRecognized: unverifiedRecognized,
                         unverifiedNumbers: numbers, expectedCount: expected.count, recognizedCount: recognized.count)
    }
}
