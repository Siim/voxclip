import Foundation

/// What a price is looked up by: provider, operation, the endpoint where a provider prices endpoints separately, and
/// the unit the caller counts in; voice-lab §3.2.
public struct VoiceLabPricedOperation: Sendable, Hashable {
    public var provider: String
    public var operation: String
    public var endpoint: String?
    public var unit: String

    public init(provider: String, operation: String, endpoint: String? = nil, unit: String) {
        self.provider = provider; self.operation = operation; self.endpoint = endpoint; self.unit = unit
    }

    public static let elevenLabsSpeechToText = Self(provider: "elevenlabs", operation: "speechToText", unit: "second")
    public static let elevenLabsAudioIsolation = Self(provider: "elevenlabs", operation: "audioIsolation", unit: "second")
    public static let elevenLabsVoiceChange = Self(provider: "elevenlabs", operation: "voiceChange", unit: "second")
    public static let elevenLabsTextToSpeech = Self(provider: "elevenlabs", operation: "textToSpeech", unit: "character")
    public static let elevenLabsForcedAlignment = Self(provider: "elevenlabs", operation: "forcedAlignment", unit: "second")
    public static let elevenLabsCreateClone = Self(provider: "elevenlabs", operation: "createClone", unit: "call")
    public static let elevenLabsDeleteClone = Self(provider: "elevenlabs", operation: "deleteClone", unit: "call")
    public static let syncsoLipsync = Self(provider: "syncso", operation: "lipsync", unit: "second")
    /// `endpoint` is the fal endpoint id, such as `fal-ai/latentsync`; the model is passed separately.
    public static func falLipsync(endpoint: String) -> Self { Self(provider: "fal", operation: "lipsync", endpoint: endpoint, unit: "second") }
}

/// `shared/catalog/voice-lab.json` (`voxclip-voice-lab-prices/1`), validated as a whole; voice-lab §3.2.
public struct VoiceLabPriceCatalog: Sendable, Equatable {
    public static let format = "voxclip-voice-lab-prices/1"

    public enum Formula: String, Sendable { case perHour, perMinute, perSecond, perThousandCharacters, flatThenPerSecond, zero, estimateApi }

    public struct Entry: Sendable, Equatable {
        public let provider: String
        public let operation: String
        public let model: String?
        public let endpoint: String?
        public let unit: String
        public let formula: Formula
        /// The day the price was checked; a priced estimate's basis is `list-<checked>`.
        public let checked: String
        public let source: String
        let usd: [String: Decimal]
        let credits: [String: Decimal]?
    }

    public let entries: [Entry]

    /// Throws `sharedResourcesMissing` for any defect: a guessed price is worse than no price.
    public init(data: Data) throws {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(root.keys).isSubset(of: ["schema", "description", "entries"]), root["schema"] as? String == Self.format,
              let rows = root["entries"] as? [[String: Any]], !rows.isEmpty else { throw VoxClipError.sharedResourcesMissing }
        entries = try rows.map(Self.entry)
        for (index, entry) in entries.enumerated() {
            for other in entries[..<index] where other.provider == entry.provider && other.operation == entry.operation
                && other.endpoint == entry.endpoint && (other.model == nil || entry.model == nil || other.model == entry.model) {
                throw VoxClipError.sharedResourcesMissing
            }
        }
    }

    /// The one entry that can price this request, or nil when the price is unknown.
    public func entry(for operation: VoiceLabPricedOperation, model: String?) -> Entry? {
        entries.first { $0.provider == operation.provider && $0.operation == operation.operation && $0.endpoint == operation.endpoint
            && ($0.model == nil || $0.model == model) }
    }

    private static let entryKeys: Set<String> = ["provider", "operation", "model", "endpoint", "unit", "formula", "usdParameters",
                                                 "creditsParameters", "checked", "source"]

    private static func entry(_ row: [String: Any]) throws -> Entry {
        func text(_ key: String, _ pattern: String) throws -> String {
            guard let value = row[key] as? String, matches(value, pattern) else { throw VoxClipError.sharedResourcesMissing }
            return value
        }
        func optional(_ key: String, _ pattern: String) throws -> String? { row[key] == nil ? nil : try text(key, pattern) }
        func prices(_ key: String) throws -> [String: Decimal]? {
            guard let value = row[key] else { return nil }
            guard let object = value as? [String: Any] else { throw VoxClipError.sharedResourcesMissing }
            return try object.mapValues { item in
                guard let string = item as? String, let price = VoiceLabMoney.parse(string, wholeDigits: 9, fractionDigits: 8) else {
                    throw VoxClipError.sharedResourcesMissing
                }
                return price
            }
        }
        guard Set(row.keys).isSubset(of: entryKeys), let formula = (row["formula"] as? String).flatMap(Formula.init(rawValue:)),
              let usd = try prices("usdParameters") else { throw VoxClipError.sharedResourcesMissing }
        let unit = try text("unit", "second|character|call"), credits = try prices("creditsParameters")
        let usdKeys = Set(usd.keys), creditKeys = credits.map { Set($0.keys) }
        let valid: Bool
        switch formula {
        case .perHour: valid = unit == "second" && usdKeys == ["perHour"] && credits == nil
        case .perMinute: valid = unit == "second" && usdKeys == ["perMinute"] && (creditKeys ?? ["perMinute"]) == ["perMinute"]
        case .perSecond: valid = unit == "second" && usdKeys == ["perSecond"] && credits == nil
        case .perThousandCharacters:
            valid = unit == "character" && usdKeys == ["perThousandCharacters"] && (creditKeys ?? ["perCharacter"]) == ["perCharacter"]
        case .flatThenPerSecond: valid = unit == "second" && usdKeys == ["flat", "includedSeconds", "perSecond"] && credits == nil
        case .zero: valid = usdKeys.isEmpty && credits == nil
        case .estimateApi: valid = unit == "second" && usdKeys.isSubset(of: ["minPerSecond", "maxPerSecond"]) && credits == nil
        }
        guard valid else { throw VoxClipError.sharedResourcesMissing }
        return Entry(provider: try text("provider", "[a-z0-9]+(?:-[a-z0-9]+)*"), operation: try text("operation", "[a-z][A-Za-z0-9]{0,63}"),
                     model: try optional("model", "[A-Za-z0-9][A-Za-z0-9_.-]{0,127}"), endpoint: try optional("endpoint", "[a-z0-9][a-z0-9._/-]{0,127}"),
                     unit: unit, formula: formula, checked: try text("checked", "[0-9]{4}-[0-9]{2}-[0-9]{2}"),
                     source: try text("source", "https://[^\\s]+"), usd: usd, credits: credits)
    }

    private static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: "\\A(?:" + pattern + ")\\z", options: .regularExpression) != nil
    }
}

/// A live provider price (voice-lab §3.3) that replaces a catalog estimate's amount.
public enum VoiceLabProviderPriceBasis: String, Sendable { case providerEstimate = "provider-estimate", providerPricingAPI = "provider-pricing-api" }

public struct VoiceLabProviderPrice: Sendable, Equatable {
    public var usd: Decimal
    public var credits: Int?
    public var basis: VoiceLabProviderPriceBasis
    public init(usd: Decimal, credits: Int? = nil, basis: VoiceLabProviderPriceBasis) { self.usd = usd; self.credits = credits; self.basis = basis }
}

/// Pure catalog estimates; voice-lab §3.1 and §3.2. `shared/fixtures/voice-lab/pricing-cases-README.md` pins every rule.
public enum VoiceLabPricing {
    /// `CANDIDATES` (§8.3): the most takes one estimate covers.
    public static let maximumCandidates = 3
    public static let maximumUnits = 1_000_000.0
    /// The discovered credit multiplier must fall in this range; anything else is invalid input, never a guess.
    public static let characterMultiplierRange = 0.01...100.0
    public static let unknownBasis = "unknown"

    /// The estimate for `units` of `operation`, or an unknown price (nil `usd`, basis `unknown`) when the catalog has no
    /// entry. TTS bills `characters × candidates` at the model's own list price. The multiplier from `GET /v1/models`
    /// `model_rates.character_cost_multiplier` (1 when absent) scales credits only, because each catalog row already is
    /// that model's price. Other operations take one candidate and ignore the multiplier. A lip sync of zero seconds is
    /// invalid input: the caller refuses an empty window before it asks.
    public static func estimate(operation: VoiceLabPricedOperation, model: String?, units: Double, candidates: Int = 1,
                                characterMultiplier: Double? = nil, catalog: VoiceLabPriceCatalog) throws -> CostEstimate {
        guard units.isFinite, units >= 0, units <= maximumUnits,
              !["character", "call"].contains(operation.unit) || units.rounded(.towardZero) == units,
              operation.operation != "lipsync" || units > 0,
              (1...maximumCandidates).contains(candidates),
              characterMultiplier.map(characterMultiplierRange.contains) ?? true,
              let amount = VoiceLabMoney.exact(units) else { throw VoiceLabError.invalidInput }
        let unknown = CostEstimate(provider: operation.provider, operation: operation.operation, units: units, unit: operation.unit,
                                   basis: unknownBasis)
        guard let entry = catalog.entry(for: operation, model: model) else { return unknown }
        guard entry.unit == operation.unit, candidates == 1 || entry.formula == .perThousandCharacters else { throw VoiceLabError.invalidInput }
        func usd(_ name: String) -> Decimal { entry.usd[name] ?? 0 }
        var billed = units
        var credits: Decimal?
        let value: Decimal
        switch entry.formula {
        case .estimateApi: return unknown
        case .zero: value = 0
        case .perHour: value = amount * usd("perHour") / 3_600
        case .perMinute:
            value = amount * usd("perMinute") / 60
            credits = entry.credits?["perMinute"].map { amount * $0 / 60 }
        case .perSecond: value = amount * usd("perSecond")
        case .flatThenPerSecond: value = usd("flat") + max(0, amount - usd("includedSeconds")) * usd("perSecond")
        case .perThousandCharacters:
            guard let multiplier = VoiceLabMoney.exact(characterMultiplier ?? 1) else { throw VoiceLabError.invalidInput }
            let characters = amount * Decimal(candidates)
            billed = units * Double(candidates)
            value = characters * usd("perThousandCharacters") / 1_000
            credits = entry.credits?["perCharacter"].map { characters * multiplier * $0 }
        }
        return CostEstimate(provider: operation.provider, operation: operation.operation, units: billed, unit: operation.unit,
                            usd: VoiceLabMoney.usd(value), credits: credits.map { VoiceLabMoney.wholeUp($0) }, basis: "list-" + entry.checked)
    }

    /// The typed hook for §3.3 live sources (fal pricing API, sync.so estimate API), which are not called yet: the
    /// provider's amount replaces `usd`, `credits` and `basis`; the rest of the estimate stays.
    public static func applying(_ price: VoiceLabProviderPrice, to estimate: CostEstimate) throws -> CostEstimate {
        guard price.usd >= 0, !price.usd.isNaN, (price.credits ?? 0) >= 0 else { throw VoiceLabError.invalidInput }
        var result = estimate
        result.usd = VoiceLabMoney.usd(price.usd)
        result.credits = price.credits
        result.basis = price.basis.rawValue
        return result
    }
}

/// Decimal helpers shared by pricing, presentation and the ledger; never binary floating point for money.
enum VoiceLabMoney {
    static let usdDecimalPlaces = 10

    /// A plain non-negative decimal string, `(0|[1-9][0-9]*)(\.[0-9]+)?`, within the digit limits; nil otherwise.
    static func parse(_ text: String, wholeDigits: Int, fractionDigits: Int) -> Decimal? {
        let bytes = Array(text.utf8)
        let point = bytes.firstIndex(of: UInt8(ascii: "."))
        let whole = bytes[..<(point ?? bytes.endIndex)]
        let fraction: ArraySlice<UInt8> = point.map { bytes[($0 + 1)...] } ?? []
        func digits(_ part: ArraySlice<UInt8>) -> Bool { part.allSatisfy { (0x30...0x39).contains($0) } }
        guard !whole.isEmpty, whole.count <= wholeDigits, digits(whole), whole.count == 1 || whole.first != 0x30,
              point == nil || (!fraction.isEmpty && fraction.count <= fractionDigits && digits(fraction)) else { return nil }
        return Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))
    }

    /// The shortest decimal that reads back as the same double, as Swift prints it; .NET's `ToString("R")` and Python's
    /// `repr` give the same digits, so both Cores price identical inputs identically.
    static func exact(_ value: Double) -> Decimal? {
        guard value.isFinite else { return nil }
        // A zero significand with a minus sign is NaN in NSDecimal, so -0.0 must not reach the initializer below.
        if value == 0 { return 0 }
        var text = Substring(value.description)
        let negative = text.hasPrefix("-")
        if negative { text = text.dropFirst() }
        var exponent = 0
        if let marker = text.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            guard let power = Int(text[text.index(after: marker)...]) else { return nil }
            exponent = power
            text = text[..<marker]
        }
        var digits = String(text)
        if let point = text.firstIndex(of: ".") {
            let fraction = text[text.index(after: point)...]
            exponent -= fraction.count
            digits = String(text[..<point]) + fraction
        }
        guard let significand = UInt64(digits) else { return nil }
        return Decimal(sign: negative ? .minus : .plus, exponent: exponent, significand: Decimal(significand))
    }

    /// Plain digits without an exponent or trailing fractional zeros: 0.30 is "0.3", 10.0 is "10".
    static func canonical(_ value: Decimal) -> String {
        var text = value.description
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        return text == "-0" ? "0" : text
    }

    static func rounded(_ value: Decimal, scale: Int, _ mode: NSDecimalNumber.RoundingMode) -> Decimal {
        var input = value, output = Decimal()
        NSDecimalRound(&output, &input, scale, mode)
        return output
    }

    /// Half away from zero at 10 decimal places.
    static func usd(_ value: Decimal) -> Decimal { rounded(value, scale: usdDecimalPlaces, .plain) }

    /// Rounds a non-negative amount up to a whole number.
    static func wholeUp(_ value: Decimal) -> Int { NSDecimalNumber(decimal: rounded(value, scale: 0, .up)).intValue }

    static func power(_ exponent: Int) -> Decimal { Decimal(sign: .plus, exponent: exponent, significand: 1) }

    /// A whole amount with a comma between thousands.
    static func grouped(_ whole: Decimal) -> String {
        var digits = Array(canonical(whole))
        var index = digits.count - 3
        while index > 0 { digits.insert(",", at: index); index -= 3 }
        return String(digits)
    }
}
