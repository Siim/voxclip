import Foundation

public enum CaptionFailure: Error, LocalizedError, Sendable, Equatable {
    case invalid(String)
    case missingContext(String)
    case noGlyphs
    public var errorDescription: String? {
        switch self {
        case .invalid(let message), .missingContext(let message): message
        case .noGlyphs: "Some characters can't be shown in this caption style."
        }
    }
}

enum CaptionDecoding {
    struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    static func keys(_ decoder: any Decoder, allowed: [String]) throws {
        let values = try decoder.container(keyedBy: Key.self)
        for key in values.allKeys where !allowed.contains(key.stringValue) {
            throw DecodingError.dataCorruptedError(forKey: key, in: values, debugDescription: "Unknown caption property")
        }
    }

    static func nonNull<KeyType: CodingKey>(_ values: KeyedDecodingContainer<KeyType>, _ key: KeyType, _ decoder: any Decoder) throws {
        if values.contains(key), try values.decodeNil(forKey: key) {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath + [key], debugDescription: "Null is not permitted"))
        }
    }

    static func check<Value>(_ value: Value?, decoder: any Decoder, message: String, predicate: (Value) -> Bool) throws {
        if let value, !predicate(value) {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: message))
        }
    }
}

public enum CaptionMath {
    public static func roundHalfUp(_ value: Double) -> Int {
        let lower = floor(value)
        return Int(lower) + (value - lower >= 0.5 ? 1 : 0)
    }

    public static func clamp(_ value: Double, _ lower: Double = 0, _ upper: Double = 1) -> Double {
        min(upper, max(lower, value))
    }

    public static func frameTime(index: Int64, fpsNum: Int64, fpsDen: Int64) throws -> Double {
        let product = index.multipliedReportingOverflow(by: fpsDen)
        guard index >= 0, fpsNum > 0, fpsDen > 0, !product.overflow else { throw CaptionFailure.invalid("Frame time") }
        return Double(product.partialValue) / Double(fpsNum)
    }

    public static func ease(_ easing: CaptionAnimEasing, _ progress: Double, overshoot: Double = 1.70158) -> Double {
        let clamped = clamp(progress)
        if clamped == 0 || clamped == 1 { return clamped }
        switch easing {
        case .linear: return clamped
        case .easeOutCubic: return 1 - pow(1 - clamped, 3)
        case .easeInOutCubic: return clamped < 0.5 ? 4 * pow(clamped, 3) : 1 - pow(-2 * clamped + 2, 3) / 2
        case .easeOutBack: return 1 + (overshoot + 1) * pow(clamped - 1, 3) + overshoot * pow(clamped - 1, 2)
        }
    }

    public static func progress(_ time: Double, _ start: Double, _ duration: Double) -> Double {
        duration <= 0 ? 1 : clamp((time - start) / duration)
    }

    public static func jitterKey(time: Double, rateHz: Double) -> UInt32 {
        let tick = floor(time * rateHz + 1e-6)
        guard tick.isFinite else { return 0 }
        let reduced = tick.truncatingRemainder(dividingBy: 4294967296)
        return UInt32(reduced < 0 ? reduced + 4294967296 : reduced)
    }
}

public struct Mulberry32: Sendable {
    public var state: UInt32
    public init(seed: UInt32) { state = seed }
    public mutating func next() -> Double {
        state &+= 0x6D2B79F5
        var value = state
        value = (value ^ (value >> 15)) &* (value | 1)
        value = (value &+ ((value ^ (value >> 7)) &* (value | 61))) ^ value
        return Double(value ^ (value >> 14)) / 4294967296.0
    }
}

public struct CaptionFontRecord: Codable, Sendable, Equatable {
    public var file: String
    public var path: String
    public var family: String
    public var weight: Int
    public var italic: Bool
    public var sha256: String
    public var unitsPerEm: Int
    public var capHeight: Int
    public var spaceAdvance: Int
    public var coverage: [[Int]]
    public func covers(_ scalar: Unicode.Scalar) -> Bool {
        coverage.contains { $0.count == 2 && $0[0] <= scalar.value && scalar.value <= $0[1] }
    }
}

public struct CaptionResources: Sendable {
    public let fonts: [String: CaptionFontRecord]
    public let upper: [UInt32: UInt32]
    public let lower: [UInt32: UInt32]
    public let stopwords: [String: Set<String>]
    public let emoji: [String: [String: String]]

    public init(fontManifest: Data, caseMap: Data, stopwords: Data, emojiKeywords: Data) throws {
        struct Manifest: Decodable { var fonts: [CaptionFontRecord] }
        struct CaseMap: Decodable { var upper: [[UInt32]]; var lower: [[UInt32]] }
        struct Stops: Decodable { var languages: [String: [String]] }
        struct Emoji: Decodable { var languages: [String: [String: String]] }
        let decoder = JSONDecoder()
        let records = try decoder.decode(Manifest.self, from: fontManifest).fonts
        guard Set(records.map(\.file)).count == records.count,
              records.allSatisfy({ $0.unitsPerEm > 0 && !$0.path.contains("..") && !$0.path.hasPrefix("/") }) else {
            throw CaptionFailure.invalid("Font manifest")
        }
        fonts = Dictionary(uniqueKeysWithValues: records.map { ($0.file, $0) })
        let mappings = try decoder.decode(CaseMap.self, from: caseMap)
        guard (mappings.upper + mappings.lower).allSatisfy({ $0.count == 2 && Unicode.Scalar($0[0]) != nil && Unicode.Scalar($0[1]) != nil }) else {
            throw CaptionFailure.invalid("Case map")
        }
        upper = Dictionary(mappings.upper.map { ($0[0], $0[1]) }, uniquingKeysWith: { first, _ in first })
        lower = Dictionary(mappings.lower.map { ($0[0], $0[1]) }, uniquingKeysWith: { first, _ in first })
        self.stopwords = try decoder.decode(Stops.self, from: stopwords).languages.mapValues(Set.init)
        emoji = try decoder.decode(Emoji.self, from: emojiKeywords).languages
    }

    public func font(_ file: String) throws -> CaptionFontRecord {
        guard let font = fonts[file] else { throw CaptionFailure.invalid("Unbundled font: \(file)") }
        return font
    }

    public func validate(style: CaptionStyle) throws {
        let primary = try font(style.font.file)
        guard primary.family == style.font.family, primary.weight == style.font.weight, primary.italic == style.font.italic else {
            throw CaptionFailure.invalid("Style font metadata does not match manifest")
        }
        for file in style.font.fallbackFiles { _ = try font(file) }
        if let file = style.emphasis?.fontFile { _ = try font(file) }
    }

    public func emoji(for key: String, language: String) -> String? {
        guard let table = emoji[language], !key.isEmpty else { return nil }
        if let exact = table[key] { return exact }
        return table.keys.filter { $0.hasSuffix("*") && $0.count >= 4 && key.hasPrefix($0.dropLast()) }
            .sorted { $0.count == $1.count ? $0 < $1 : $0.count > $1.count }.first.flatMap { table[$0] }
    }
}

public enum CaptionTextRules {
    public static func language(_ language: String) -> String {
        String(String.UnicodeScalarView(language.split(separator: "-").first.map(String.init)?.unicodeScalars.map {
            (65...90).contains($0.value) ? Unicode.Scalar($0.value + 32)! : $0
        } ?? []))
    }

    public static func whitespace(_ scalar: Unicode.Scalar) -> Bool {
        (9...13).contains(scalar.value) || (0x2000...0x200A).contains(scalar.value) ||
            [0x20, 0x85, 0xA0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000].contains(scalar.value)
    }

    public static func raw(_ text: String) -> String {
        var result = ""
        var pendingSpace = false
        for scalar in text.precomposedStringWithCanonicalMapping.unicodeScalars {
            if whitespace(scalar) { pendingSpace = !result.isEmpty }
            else {
                if pendingSpace { result.append(" "); pendingSpace = false }
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    public static func punctuation(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation, .initialPunctuation, .finalPunctuation, .otherPunctuation: return true
        default: return false
        }
    }

    public static func letterOrNumber(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter, .decimalNumber, .letterNumber, .otherNumber: return true
        default: return false
        }
    }

    public static func abbreviation(_ text: String) -> Bool {
        text.range(of: "^(\\p{L}\\.){2,}$", options: .regularExpression) != nil
    }

    public static func strip(_ text: String) -> String {
        if abbreviation(text) { return text }
        let scalars = Array(text.unicodeScalars)
        var result = ""
        for (index, scalar) in scalars.enumerated() {
            let previous = index > 0 ? scalars[index - 1] : nil
            let next = index + 1 < scalars.count ? scalars[index + 1] : nil
            let alphanumeric = previous.map(letterOrNumber) == true && next.map(letterOrNumber) == true
            let numeric = previous?.properties.generalCategory == .decimalNumber && next?.properties.generalCategory == .decimalNumber
            let keep = !punctuation(scalar) || "%#@&".unicodeScalars.contains(scalar) ||
                ("'’‐‑–—-./·".unicodeScalars.contains(scalar) && alphanumeric) ||
                (",:".unicodeScalars.contains(scalar) && numeric) ||
                ("-–".unicodeScalars.contains(scalar) && index == 0 && next?.properties.generalCategory == .decimalNumber)
            if keep { result.unicodeScalars.append(scalar) }
        }
        return result
    }

    public static func caseMap(_ text: String, transform: CaptionTextTransform, language: String, resources: CaptionResources) -> String {
        if transform == .none { return text }
        let turkic = ["tr", "az"].contains(self.language(language))
        let table = transform == .uppercase ? resources.upper : resources.lower
        var result = ""
        for scalar in text.unicodeScalars {
            if transform == .uppercase && scalar.value == 0xDF { result += "SS" }
            else if turkic && transform == .uppercase && scalar.value == 0x69 { result += "İ" }
            else if turkic && transform == .lowercase && scalar.value == 0x49 { result += "ı" }
            else if turkic && transform == .lowercase && scalar.value == 0x130 { result += "i" }
            else { result.unicodeScalars.append(Unicode.Scalar(table[scalar.value] ?? scalar.value)!) }
        }
        return result
    }

    public static func normalize(_ text: String, options: CaptionText, language: String, resources: CaptionResources) -> String {
        let collapsed = raw(text)
        return raw(caseMap(options.punctuation == .keep ? collapsed : strip(collapsed), transform: options.transform, language: language, resources: resources))
    }

    public static func matchingKey(_ text: String, language: String, resources: CaptionResources) -> String {
        String(String.UnicodeScalarView(caseMap(text, transform: .lowercase, language: language, resources: resources).unicodeScalars.filter { !punctuation($0) && !whitespace($0) }))
    }

    public static func sentenceEnd(_ text: String) -> Bool {
        let value = raw(text)
        return !abbreviation(value) && value.range(of: "[.!?…。！？][\"'”’)\\]»]*$", options: .regularExpression) != nil
    }

    public static func clauseEnd(_ text: String) -> Bool {
        raw(text).range(of: "[,;:—–][\"'”’)\\]»]*$", options: .regularExpression) != nil
    }
}

extension CaptionStyle {
    public func validateSemantics() throws {
        guard id != "off", schemaVersion == 1, words?.past?.box == nil, words?.future?.box == nil,
              reveal?.cursor == nil || reveal?.unit == .char,
              preview.activeWord < CaptionTextRules.raw(preview.text).split(separator: " ").count else {
            throw CaptionFailure.invalid("Caption style semantics")
        }
        if let box, box.borderWidthEm > 0, box.borderColor == nil { throw CaptionFailure.invalid("Box border colour") }
        if let box = words?.active?.box, box.borderWidthEm > 0, box.borderColor == nil { throw CaptionFailure.invalid("Word border colour") }
        if let emphasis, emphasis.source != .none, emphasis.fill == nil, emphasis.palette == nil, emphasis.fontFile == nil, emphasis.scale == 1 {
            throw CaptionFailure.invalid("Emphasis needs an appearance")
        }
        let encoded = try JSONEncoder().encode(self)
        if accent == nil, String(decoding: encoded, as: UTF8.self).contains("$accent") { throw CaptionFailure.invalid("Missing accent") }
    }
}
