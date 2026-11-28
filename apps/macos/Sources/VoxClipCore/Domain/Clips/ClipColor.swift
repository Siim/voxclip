import Foundation

public struct ClipColorAdjustments: Codable, Sendable, Equatable {
    public enum Control: String, CaseIterable, Sendable {
        case brightness, contrast, saturation, warmth

        public var label: String { rawValue.capitalized }
    }

    public static let range = -100...100
    public static let neutral = Self()

    public var brightness: Int
    public var contrast: Int
    public var saturation: Int
    public var warmth: Int

    public init(brightness: Int = 0, contrast: Int = 0, saturation: Int = 0, warmth: Int = 0) {
        self.brightness = brightness
        self.contrast = contrast
        self.saturation = saturation
        self.warmth = warmth
    }

    public subscript(_ control: Control) -> Int {
        get {
            switch control {
            case .brightness: brightness
            case .contrast: contrast
            case .saturation: saturation
            case .warmth: warmth
            }
        }
        set {
            let value = min(Self.range.upperBound, max(Self.range.lowerBound, newValue))
            switch control {
            case .brightness: brightness = value
            case .contrast: contrast = value
            case .saturation: saturation = value
            case .warmth: warmth = value
            }
        }
    }

    var isValid: Bool { self != .neutral && Control.allCases.allSatisfy { Self.range.contains(self[$0]) } }
}

/// The camera fix (looks spec §5.4): Exposure, Temperature and Tint, −100…+100. It corrects the picture before the look and
/// stays when the look changes.
public struct ClipColorFix: Sendable, Equatable {
    public static let neutral = Self()

    public var exposure: Int
    public var temperature: Int
    public var tint: Int

    public init(exposure: Int = 0, temperature: Int = 0, tint: Int = 0) {
        self.exposure = exposure
        self.temperature = temperature
        self.tint = tint
    }
}

/// A preset's tone curves (looks spec §5.6 stage T3): five Y values in thousandths at x = 0, ¼, ½, ¾ and 1, non-decreasing.
/// `master` acts on every channel, then the optional channel curves. Data only; at least one curve is present.
public struct ClipToneCurve: Codable, Sendable, Equatable {
    public static let channels = ["master", "red", "green", "blue"]
    public static let knots = 5
    public static let range = 0...1000

    public var master: [Int]?
    public var red: [Int]?
    public var green: [Int]?
    public var blue: [Int]?

    public init(master: [Int]? = nil, red: [Int]? = nil, green: [Int]? = nil, blue: [Int]? = nil) {
        self.master = master
        self.red = red
        self.green = green
        self.blue = blue
    }

    var isValid: Bool {
        let present = [master, red, green, blue].compactMap { $0 }
        return !present.isEmpty && present.allSatisfy { values in
            values.count == Self.knots && values.allSatisfy(Self.range.contains) && zip(values, values.dropFirst()).allSatisfy { $0 <= $1 }
        }
    }
}

/// A preset's split toning (looks spec §5.6 stage T4): a hue and strength for the shadows and the highlights, and the
/// balance between them. Data only.
public struct ClipSplitTone: Codable, Sendable, Equatable {
    public var shadowHue: Int
    public var shadowSaturation: Int
    public var highlightHue: Int
    public var highlightSaturation: Int
    public var balance: Int

    public init(shadowHue: Int, shadowSaturation: Int, highlightHue: Int, highlightSaturation: Int, balance: Int) {
        self.shadowHue = shadowHue
        self.shadowSaturation = shadowSaturation
        self.highlightHue = highlightHue
        self.highlightSaturation = highlightSaturation
        self.balance = balance
    }

    var isValid: Bool {
        (0...359).contains(shadowHue) && (0...359).contains(highlightHue) && (0...100).contains(shadowSaturation) &&
            (0...100).contains(highlightSaturation) && (-100...100).contains(balance)
    }
}

/// `clipControls[].colorGrade` (looks spec §8.1): the Fix, the look's new controls, Amount and a preset's toning, in whole
/// points, stored as expanded values so a project is self-contained. The object exists only when something is
/// non-neutral: a slider, a curve, a split tone, or an amount under 100; `preset` alone never creates it. Every slider key
/// is written; `preset`, `curve` and `splitTone` are omitted when absent, and `amount` at 100. Schema v8 only.
public struct ClipColorGrade: Codable, Sendable, Equatable {
    /// The nine sliders, in the order the file lists them.
    public enum Control: String, CaseIterable, Sendable {
        case exposure, temperature, tint, highlights, shadows, vibrance, fade, vignette, grain

        /// −100…+100, except Fade, Vignette and Grain, which only add (0…100).
        public var range: ClosedRange<Int> {
            switch self {
            case .fade, .vignette, .grain: 0...100
            default: -100...100
            }
        }

        /// The Fix: set by Auto or by hand, never by a preset.
        public var isFix: Bool { self == .exposure || self == .temperature || self == .tint }
    }

    public static let neutral = Self()
    public static let amountRange = 0...100
    /// A display-only preset ID: 1–40 ASCII letters and digits.
    static let presetPattern = #"\A[A-Za-z0-9]{1,40}\z"#

    /// The look this grade came from, for display only; the renderer never reads it. An ID this build doesn't know shows
    /// "Custom".
    public var preset: String?
    /// The look's strength, 0…100%; the Fix always applies in full.
    public var amount: Int
    public var exposure: Int
    public var temperature: Int
    public var tint: Int
    public var highlights: Int
    public var shadows: Int
    public var vibrance: Int
    public var fade: Int
    public var vignette: Int
    public var grain: Int
    public var curve: ClipToneCurve?
    public var splitTone: ClipSplitTone?

    public init(preset: String? = nil, amount: Int = 100, exposure: Int = 0, temperature: Int = 0, tint: Int = 0, highlights: Int = 0,
                shadows: Int = 0, vibrance: Int = 0, fade: Int = 0, vignette: Int = 0, grain: Int = 0, curve: ClipToneCurve? = nil,
                splitTone: ClipSplitTone? = nil) {
        self.preset = preset; self.amount = amount; self.exposure = exposure; self.temperature = temperature; self.tint = tint
        self.highlights = highlights; self.shadows = shadows; self.vibrance = vibrance; self.fade = fade; self.vignette = vignette
        self.grain = grain; self.curve = curve; self.splitTone = splitTone
    }

    public subscript(_ control: Control) -> Int {
        get {
            switch control {
            case .exposure: exposure
            case .temperature: temperature
            case .tint: tint
            case .highlights: highlights
            case .shadows: shadows
            case .vibrance: vibrance
            case .fade: fade
            case .vignette: vignette
            case .grain: grain
            }
        }
        set {
            let value = newValue.clamped(to: control.range)
            switch control {
            case .exposure: exposure = value
            case .temperature: temperature = value
            case .tint: tint = value
            case .highlights: highlights = value
            case .shadows: shadows = value
            case .vibrance: vibrance = value
            case .fade: fade = value
            case .vignette: vignette = value
            case .grain: grain = value
            }
        }
    }

    public var fix: ClipColorFix {
        get { ClipColorFix(exposure: exposure, temperature: temperature, tint: tint) }
        set { exposure = newValue.exposure; temperature = newValue.temperature; tint = newValue.tint }
    }

    /// The values a look tile compares (spec §8.3): everything but the preset, the amount and the Fix.
    public var lookValues: ClipColorGrade {
        var values = self
        values.preset = nil
        values.amount = 100
        values.fix = .neutral
        return values
    }

    /// Nothing to store: every slider 0, no toning, full amount. The preset is ignored.
    public var isNeutral: Bool { Control.allCases.allSatisfy { self[$0] == 0 } && curve == nil && splitTone == nil && amount == 100 }

    var isValid: Bool {
        !isNeutral && Self.amountRange.contains(amount) && Control.allCases.allSatisfy { $0.range.contains(self[$0]) } &&
            preset.map(Self.isPresetID) != false && curve?.isValid != false && splitTone?.isValid != false
    }

    static func isPresetID(_ id: String) -> Bool { id.range(of: presetPattern, options: .regularExpression) != nil }

    private enum CodingKeys: String, CodingKey {
        case preset, amount, exposure, temperature, tint, highlights, shadows, vibrance, fade, vignette, grain, curve, splitTone
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        preset = try values.decodeIfPresent(String.self, forKey: .preset)
        amount = try values.decodeIfPresent(Int.self, forKey: .amount) ?? 100
        exposure = try values.decode(Int.self, forKey: .exposure)
        temperature = try values.decode(Int.self, forKey: .temperature)
        tint = try values.decode(Int.self, forKey: .tint)
        highlights = try values.decode(Int.self, forKey: .highlights)
        shadows = try values.decode(Int.self, forKey: .shadows)
        vibrance = try values.decode(Int.self, forKey: .vibrance)
        fade = try values.decode(Int.self, forKey: .fade)
        vignette = try values.decode(Int.self, forKey: .vignette)
        grain = try values.decode(Int.self, forKey: .grain)
        curve = try values.decodeIfPresent(ClipToneCurve.self, forKey: .curve)
        splitTone = try values.decodeIfPresent(ClipSplitTone.self, forKey: .splitTone)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeIfPresent(preset, forKey: .preset)
        if amount != 100 { try values.encode(amount, forKey: .amount) }
        try values.encode(exposure, forKey: .exposure)
        try values.encode(temperature, forKey: .temperature)
        try values.encode(tint, forKey: .tint)
        try values.encode(highlights, forKey: .highlights)
        try values.encode(shadows, forKey: .shadows)
        try values.encode(vibrance, forKey: .vibrance)
        try values.encode(fade, forKey: .fade)
        try values.encode(vignette, forKey: .vignette)
        try values.encode(grain, forKey: .grain)
        try values.encodeIfPresent(curve, forKey: .curve)
        try values.encodeIfPresent(splitTone, forKey: .splitTone)
    }

    /// The strict reader both forms share (spec §8.1, §4.1), returning nil for anything it refuses. A project's object
    /// (`look: false`) writes all nine sliders, omits `amount` at 100 and is never neutral. A preset's `grade` in
    /// clip-looks.json (`look: true`) holds only the look's own keys, a missing one meaning 0: never the Fix, an amount
    /// or a preset.
    static func read(_ value: JSONValue, look: Bool) -> ClipColorGrade? {
        guard case .object(let fields) = value else { return nil }
        func integer(_ value: JSONValue?, _ range: ClosedRange<Int>) -> Int? {
            guard case .number(let number) = value, number.isFinite, number.rounded() == number,
                  (Double(range.lowerBound)...Double(range.upperBound)).contains(number) else { return nil }
            return Int(number)
        }
        let sliders = Control.allCases.filter { !look || !$0.isFix }.map(\.rawValue)
        let optional = ["curve", "splitTone"] + (look ? [] : ["preset", "amount"])
        guard Set(fields.keys).isSubset(of: Set(sliders + optional)), look || Set(sliders).isSubset(of: Set(fields.keys)) else { return nil }
        var grade = ClipColorGrade()
        for control in Control.allCases {
            guard let raw = fields[control.rawValue] else { continue }
            guard let point = integer(raw, control.range) else { return nil }
            grade[control] = point
        }
        if let raw = fields["preset"] {
            guard case .string(let id) = raw, isPresetID(id) else { return nil }
            grade.preset = id
        }
        if let raw = fields["amount"] {
            guard let amount = integer(raw, 0...99) else { return nil }
            grade.amount = amount
        }
        if let raw = fields["curve"] {
            guard case .object(let channels) = raw, !channels.isEmpty, Set(channels.keys).isSubset(of: Set(ClipToneCurve.channels)) else { return nil }
            var curve = ClipToneCurve()
            for (name, list) in channels {
                guard case .array(let items) = list else { return nil }
                let values = items.compactMap { integer($0, ClipToneCurve.range) }
                guard values.count == items.count else { return nil }
                switch name {
                case "master": curve.master = values
                case "red": curve.red = values
                case "green": curve.green = values
                default: curve.blue = values
                }
            }
            guard curve.isValid else { return nil }
            grade.curve = curve
        }
        if let raw = fields["splitTone"] {
            let keys = ["shadowHue", "shadowSaturation", "highlightHue", "highlightSaturation", "balance"]
            guard case .object(let tone) = raw, Set(tone.keys) == Set(keys) else { return nil }
            let points = keys.compactMap { integer(tone[$0], -100...359) }
            guard points.count == keys.count else { return nil }
            let split = ClipSplitTone(shadowHue: points[0], shadowSaturation: points[1], highlightHue: points[2], highlightSaturation: points[3],
                                      balance: points[4])
            guard split.isValid else { return nil }
            grade.splitTone = split
        }
        guard look || grade.isValid else { return nil }
        return grade
    }
}
