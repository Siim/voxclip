import Foundation

/// Caption style value and schema defaults; captions §2, shared/caption-styles/schema.json.
public struct CaptionStyle: Codable, Sendable, Equatable {
    /// Caption schema $schema.
    public var schemaURL: String?
    /// Caption schema schemaVersion.
    public var schemaVersion: Int
    /// Stable identifier. Equals the file name without .json. Stored in project files.
    public var id: String
    /// Gallery tile label (sentence case).
    public var name: String
    /// One sentence used as the accessibility label of the tile.
    public var description: String
    /// Gallery order, ascending; ties by id.
    public var order: Int
    /// Caption schema tags.
    public var tags: [String]
    /// Caption schema accent.
    public var accent: String?
    /// Caption schema font.
    public var font: CaptionFont
    /// Caption schema text.
    public var text: CaptionText
    /// Caption schema layout.
    public var layout: CaptionLayout
    /// Caption schema position.
    public var position: CaptionStylePosition
    /// Caption schema aspects.
    public var aspects: CaptionAspects?
    /// Caption schema fill.
    public var fill: CaptionPaint
    /// Caption schema stroke.
    public var stroke: CaptionStroke?
    /// Caption schema shadows.
    public var shadows: [CaptionShadow]
    /// Caption schema box.
    public var box: CaptionBox?
    /// Caption schema words.
    public var words: CaptionWordStates?
    /// Caption schema reveal.
    public var reveal: CaptionReveal?
    /// Caption schema animation.
    public var animation: CaptionAnimation?
    /// Caption schema emphasis.
    public var emphasis: CaptionEmphasis?
    /// Caption schema emoji.
    public var emoji: CaptionEmoji?
    /// Caption schema effects.
    public var effects: CaptionEffects?
    /// Caption schema preview.
    public var preview: CaptionPreview

    /// Creates an explicit value without I/O or generated identifiers.
    public init(schemaURL: String? = nil, schemaVersion: Int, id: String, name: String, description: String, order: Int = 500, tags: [String] = [], accent: String? = nil, font: CaptionFont, text: CaptionText, layout: CaptionLayout, position: CaptionStylePosition, aspects: CaptionAspects? = nil, fill: CaptionPaint, stroke: CaptionStroke? = nil, shadows: [CaptionShadow] = [], box: CaptionBox? = nil, words: CaptionWordStates? = nil, reveal: CaptionReveal? = nil, animation: CaptionAnimation? = nil, emphasis: CaptionEmphasis? = nil, emoji: CaptionEmoji? = nil, effects: CaptionEffects? = nil, preview: CaptionPreview) {
        self.schemaURL = schemaURL
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
        self.description = description
        self.order = order
        self.tags = tags
        self.accent = accent
        self.font = font
        self.text = text
        self.layout = layout
        self.position = position
        self.aspects = aspects
        self.fill = fill
        self.stroke = stroke
        self.shadows = shadows
        self.box = box
        self.words = words
        self.reveal = reveal
        self.animation = animation
        self.emphasis = emphasis
        self.emoji = emoji
        self.effects = effects
        self.preview = preview
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaURL = "$schema"
        case schemaVersion
        case id
        case name
        case description
        case order
        case tags
        case accent
        case font
        case text
        case layout
        case position
        case aspects
        case fill
        case stroke
        case shadows
        case box
        case words
        case reveal
        case animation
        case emphasis
        case emoji
        case effects
        case preview
    }

    public init(from decoder: any Decoder) throws {
        try CaptionDecoding.keys(decoder, allowed: CodingKeys.allCases.map(\.rawValue))
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try CaptionDecoding.nonNull(values, .schemaURL, decoder)
        self.schemaURL = try values.decodeIfPresent(String.self, forKey: .schemaURL) ?? nil
        self.schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        try CaptionDecoding.check(self.schemaVersion, decoder: decoder, message: "Invalid CaptionStyle.schemaVersion") { value in value == 1 }
        self.id = try values.decode(String.self, forKey: .id)
        try CaptionDecoding.check(self.id, decoder: decoder, message: "Invalid CaptionStyle.id") { value in value.range(of: "^[a-z0-9][a-z0-9-]{1,39}$", options: .regularExpression) != nil }
        self.name = try values.decode(String.self, forKey: .name)
        try CaptionDecoding.check(self.name, decoder: decoder, message: "Invalid CaptionStyle.name") { value in value.unicodeScalars.count >= 1 && value.unicodeScalars.count <= 24 }
        self.description = try values.decode(String.self, forKey: .description)
        try CaptionDecoding.check(self.description, decoder: decoder, message: "Invalid CaptionStyle.description") { value in value.unicodeScalars.count >= 1 && value.unicodeScalars.count <= 200 }
        try CaptionDecoding.nonNull(values, .order, decoder)
        self.order = try values.decodeIfPresent(Int.self, forKey: .order) ?? 500
        try CaptionDecoding.check(self.order, decoder: decoder, message: "Invalid CaptionStyle.order") { value in value >= 0 && value <= 999 }
        try CaptionDecoding.nonNull(values, .tags, decoder)
        self.tags = try values.decodeIfPresent([String].self, forKey: .tags) ?? []
        try CaptionDecoding.check(self.tags, decoder: decoder, message: "Invalid CaptionStyle.tags") { value in
            Set(value).count == value.count && value.allSatisfy { $0.range(of: "^[a-z0-9-]+$", options: .regularExpression) != nil }
        }
        try CaptionDecoding.nonNull(values, .accent, decoder)
        self.accent = try values.decodeIfPresent(String.self, forKey: .accent) ?? nil
        try CaptionDecoding.check(self.accent, decoder: decoder, message: "Invalid CaptionStyle.accent") { value in value.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) != nil }
        self.font = try values.decode(CaptionFont.self, forKey: .font)
        self.text = try values.decode(CaptionText.self, forKey: .text)
        self.layout = try values.decode(CaptionLayout.self, forKey: .layout)
        self.position = try values.decode(CaptionStylePosition.self, forKey: .position)
        try CaptionDecoding.nonNull(values, .aspects, decoder)
        self.aspects = try values.decodeIfPresent(CaptionAspects.self, forKey: .aspects) ?? nil
        self.fill = try values.decode(CaptionPaint.self, forKey: .fill)
        try CaptionDecoding.nonNull(values, .stroke, decoder)
        self.stroke = try values.decodeIfPresent(CaptionStroke.self, forKey: .stroke) ?? nil
        try CaptionDecoding.nonNull(values, .shadows, decoder)
        self.shadows = try values.decodeIfPresent([CaptionShadow].self, forKey: .shadows) ?? []
        try CaptionDecoding.check(self.shadows, decoder: decoder, message: "Invalid CaptionStyle.shadows") { value in value.count <= 4 }
        try CaptionDecoding.nonNull(values, .box, decoder)
        self.box = try values.decodeIfPresent(CaptionBox.self, forKey: .box) ?? nil
        try CaptionDecoding.nonNull(values, .words, decoder)
        self.words = try values.decodeIfPresent(CaptionWordStates.self, forKey: .words) ?? nil
        try CaptionDecoding.nonNull(values, .reveal, decoder)
        self.reveal = try values.decodeIfPresent(CaptionReveal.self, forKey: .reveal) ?? nil
        try CaptionDecoding.nonNull(values, .animation, decoder)
        self.animation = try values.decodeIfPresent(CaptionAnimation.self, forKey: .animation) ?? nil
        try CaptionDecoding.nonNull(values, .emphasis, decoder)
        self.emphasis = try values.decodeIfPresent(CaptionEmphasis.self, forKey: .emphasis) ?? nil
        try CaptionDecoding.nonNull(values, .emoji, decoder)
        self.emoji = try values.decodeIfPresent(CaptionEmoji.self, forKey: .emoji) ?? nil
        try CaptionDecoding.nonNull(values, .effects, decoder)
        self.effects = try values.decodeIfPresent(CaptionEffects.self, forKey: .effects) ?? nil
        self.preview = try values.decode(CaptionPreview.self, forKey: .preview)
        try validateSemantics()
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeIfPresent(self.schemaURL, forKey: .schemaURL)
        try values.encode(self.schemaVersion, forKey: .schemaVersion)
        try values.encode(self.id, forKey: .id)
        try values.encode(self.name, forKey: .name)
        try values.encode(self.description, forKey: .description)
        try values.encode(self.order, forKey: .order)
        try values.encode(self.tags, forKey: .tags)
        try values.encodeIfPresent(self.accent, forKey: .accent)
        try values.encode(self.font, forKey: .font)
        try values.encode(self.text, forKey: .text)
        try values.encode(self.layout, forKey: .layout)
        try values.encode(self.position, forKey: .position)
        try values.encodeIfPresent(self.aspects, forKey: .aspects)
        try values.encode(self.fill, forKey: .fill)
        try values.encodeIfPresent(self.stroke, forKey: .stroke)
        try values.encode(self.shadows, forKey: .shadows)
        try values.encodeIfPresent(self.box, forKey: .box)
        try values.encodeIfPresent(self.words, forKey: .words)
        try values.encodeIfPresent(self.reveal, forKey: .reveal)
        try values.encodeIfPresent(self.animation, forKey: .animation)
        try values.encodeIfPresent(self.emphasis, forKey: .emphasis)
        try values.encodeIfPresent(self.emoji, forKey: .emoji)
        try values.encodeIfPresent(self.effects, forKey: .effects)
        try values.encode(self.preview, forKey: .preview)
    }

}

/// Caption style value and schema defaults; captions §2, shared/caption-styles/schema.json.
public struct CaptionFont: Codable, Sendable, Equatable {
    /// File name of a font listed in shared/fonts/fonts.json.
    public var file: String
    /// Informational; must equal the manifest family of 'file'.
    public var family: String
    /// Informational; must equal the manifest nominal weight of 'file'.
    public var weight: Int
    /// Informational; must equal the manifest value.
    public var italic: Bool
    /// Font size as a fraction of the reference length (sizeRef).
    public var sizeSh: Double
    /// Caption schema sizeRef.
    public var sizeRef: CaptionFontSizeRef
    /// Multiplier on sizeSh. Built-in styles leave it at 1; the Size control writes it through the project's overrides patch.
    public var sizeScale: Double
    /// Caption schema letterSpacingEm.
    public var letterSpacingEm: Double
    /// Gap between words in em. When absent the gap is the font's space advance plus letter spacing.
    public var wordSpacingEm: Double?
    /// Caption schema lineHeightEm.
    public var lineHeightEm: Double
    /// Caption schema features.
    public var features: CaptionFontFeatures
    /// Tried in order after the primary file and before Noto Sans.
    public var fallbackFiles: [String]

    /// Creates an explicit value without I/O or generated identifiers.
    public init(file: String, family: String, weight: Int, italic: Bool = false, sizeSh: Double, sizeRef: CaptionFontSizeRef = .shortEdge, sizeScale: Double = 1, letterSpacingEm: Double = 0, wordSpacingEm: Double? = nil, lineHeightEm: Double = 1.2, features: CaptionFontFeatures = CaptionFontFeatures(), fallbackFiles: [String] = []) {
        self.file = file
        self.family = family
        self.weight = weight
        self.italic = italic
        self.sizeSh = sizeSh
        self.sizeRef = sizeRef
        self.sizeScale = sizeScale
        self.letterSpacingEm = letterSpacingEm
        self.wordSpacingEm = wordSpacingEm
        self.lineHeightEm = lineHeightEm
        self.features = features
        self.fallbackFiles = fallbackFiles
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case file
        case family
        case weight
        case italic
        case sizeSh
        case sizeRef
        case sizeScale
        case letterSpacingEm
        case wordSpacingEm
        case lineHeightEm
        case features
        case fallbackFiles
    }

    public init(from decoder: any Decoder) throws {
        try CaptionDecoding.keys(decoder, allowed: CodingKeys.allCases.map(\.rawValue))
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.file = try values.decode(String.self, forKey: .file)
        try CaptionDecoding.check(self.file, decoder: decoder, message: "Invalid CaptionFont.file") { value in value.range(of: "^[A-Za-z0-9_-]+\\.ttf$", options: .regularExpression) != nil }
        self.family = try values.decode(String.self, forKey: .family)
        self.weight = try values.decode(Int.self, forKey: .weight)
        try CaptionDecoding.check(self.weight, decoder: decoder, message: "Invalid CaptionFont.weight") { value in value >= 100 && value <= 1000 }
        try CaptionDecoding.nonNull(values, .italic, decoder)
        self.italic = try values.decodeIfPresent(Bool.self, forKey: .italic) ?? false
        self.sizeSh = try values.decode(Double.self, forKey: .sizeSh)
        try CaptionDecoding.check(self.sizeSh, decoder: decoder, message: "Invalid CaptionFont.sizeSh") { value in value >= 0.01 && value <= 0.3 }
        try CaptionDecoding.nonNull(values, .sizeRef, decoder)
        self.sizeRef = try values.decodeIfPresent(CaptionFontSizeRef.self, forKey: .sizeRef) ?? .shortEdge
        try CaptionDecoding.nonNull(values, .sizeScale, decoder)
        self.sizeScale = try values.decodeIfPresent(Double.self, forKey: .sizeScale) ?? 1
        try CaptionDecoding.check(self.sizeScale, decoder: decoder, message: "Invalid CaptionFont.sizeScale") { value in value >= 0.6 && value <= 1.6 }
        try CaptionDecoding.nonNull(values, .letterSpacingEm, decoder)
        self.letterSpacingEm = try values.decodeIfPresent(Double.self, forKey: .letterSpacingEm) ?? 0
        try CaptionDecoding.check(self.letterSpacingEm, decoder: decoder, message: "Invalid CaptionFont.letterSpacingEm") { value in value >= -0.2 && value <= 0.5 }
        try CaptionDecoding.nonNull(values, .wordSpacingEm, decoder)
        self.wordSpacingEm = try values.decodeIfPresent(Double.self, forKey: .wordSpacingEm) ?? nil
        try CaptionDecoding.check(self.wordSpacingEm, decoder: decoder, message: "Invalid CaptionFont.wordSpacingEm") { value in value >= 0 && value <= 1 }
        try CaptionDecoding.nonNull(values, .lineHeightEm, decoder)
        self.lineHeightEm = try values.decodeIfPresent(Double.self, forKey: .lineHeightEm) ?? 1.2
        try CaptionDecoding.check(self.lineHeightEm, decoder: decoder, message: "Invalid CaptionFont.lineHeightEm") { value in value >= 0.8 && value <= 2.5 }
        try CaptionDecoding.nonNull(values, .features, decoder)
        self.features = try values.decodeIfPresent(CaptionFontFeatures.self, forKey: .features) ?? CaptionFontFeatures()
        try CaptionDecoding.nonNull(values, .fallbackFiles, decoder)
        self.fallbackFiles = try values.decodeIfPresent([String].self, forKey: .fallbackFiles) ?? []
        try CaptionDecoding.check(self.fallbackFiles, decoder: decoder, message: "Invalid CaptionFont.fallbackFiles") { value in
            value.count <= 3 && value.allSatisfy { $0.range(of: "^[A-Za-z0-9_-]+\\.ttf$", options: .regularExpression) != nil }
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(self.file, forKey: .file)
        try values.encode(self.family, forKey: .family)
        try values.encode(self.weight, forKey: .weight)
        try values.encode(self.italic, forKey: .italic)
        try values.encode(self.sizeSh, forKey: .sizeSh)
        try values.encode(self.sizeRef, forKey: .sizeRef)
        try values.encode(self.sizeScale, forKey: .sizeScale)
        try values.encode(self.letterSpacingEm, forKey: .letterSpacingEm)
        try values.encodeIfPresent(self.wordSpacingEm, forKey: .wordSpacingEm)
        try values.encode(self.lineHeightEm, forKey: .lineHeightEm)
        try values.encode(self.features, forKey: .features)
        try values.encode(self.fallbackFiles, forKey: .fallbackFiles)
    }

}

/// Caption schema enum; captions §2.
public enum CaptionFontSizeRef: String, Codable, Sendable, Hashable, CaseIterable {
    case shortEdge
    case height
    case width
}

/// Caption style value and schema defaults; captions §2, shared/caption-styles/schema.json.
public struct CaptionFontFeatures: Codable, Sendable, Equatable {
    /// Caption schema kern.
    public var kern: Bool
    /// Caption schema liga.
    public var liga: Bool
    /// Caption schema calt.
    public var calt: Bool

    /// Creates an explicit value without I/O or generated identifiers.
    public init(kern: Bool = true, liga: Bool = true, calt: Bool = true) {
        self.kern = kern
        self.liga = liga
        self.calt = calt
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case kern
        case liga
        case calt
    }

    public init(from decoder: any Decoder) throws {
        try CaptionDecoding.keys(decoder, allowed: CodingKeys.allCases.map(\.rawValue))
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try CaptionDecoding.nonNull(values, .kern, decoder)
        self.kern = try values.decodeIfPresent(Bool.self, forKey: .kern) ?? true
        try CaptionDecoding.nonNull(values, .liga, decoder)
        self.liga = try values.decodeIfPresent(Bool.self, forKey: .liga) ?? true
        try CaptionDecoding.nonNull(values, .calt, decoder)
        self.calt = try values.decodeIfPresent(Bool.self, forKey: .calt) ?? true
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(self.kern, forKey: .kern)
        try values.encode(self.liga, forKey: .liga)
        try values.encode(self.calt, forKey: .calt)
    }

}

/// Caption style value and schema defaults; captions §2, shared/caption-styles/schema.json.
public struct CaptionText: Codable, Sendable, Equatable {
    /// Caption schema transform.
    public var transform: CaptionTextTransform
    /// Caption schema punctuation.
    public var punctuation: CaptionTextPunctuation
    /// Whether the user may change transform and punctuation.
    public var userOverridable: Bool

    /// Creates an explicit value without I/O or generated identifiers.
    public init(transform: CaptionTextTransform = .none, punctuation: CaptionTextPunctuation = .keep, userOverridable: Bool = true) {
        self.transform = transform
        self.punctuation = punctuation
        self.userOverridable = userOverridable
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case transform
        case punctuation
        case userOverridable
    }

    public init(from decoder: any Decoder) throws {
        try CaptionDecoding.keys(decoder, allowed: CodingKeys.allCases.map(\.rawValue))
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try CaptionDecoding.nonNull(values, .transform, decoder)
        self.transform = try values.decodeIfPresent(CaptionTextTransform.self, forKey: .transform) ?? .none
        try CaptionDecoding.nonNull(values, .punctuation, decoder)
        self.punctuation = try values.decodeIfPresent(CaptionTextPunctuation.self, forKey: .punctuation) ?? .keep
        try CaptionDecoding.nonNull(values, .userOverridable, decoder)
        self.userOverridable = try values.decodeIfPresent(Bool.self, forKey: .userOverridable) ?? true
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(self.transform, forKey: .transform)
        try values.encode(self.punctuation, forKey: .punctuation)
        try values.encode(self.userOverridable, forKey: .userOverridable)
    }

}

/// Caption schema enum; captions §2.
public enum CaptionTextTransform: String, Codable, Sendable, Hashable, CaseIterable {
    case `none`
    case uppercase
    case lowercase
}

/// Caption schema enum; captions §2.
public enum CaptionTextPunctuation: String, Codable, Sendable, Hashable, CaseIterable {
    case keep
    case stripKeepNumeric = "strip-keep-numeric"
}

/// Caption style value and schema defaults; captions §2, shared/caption-styles/schema.json.
public struct CaptionLayout: Codable, Sendable, Equatable {
    /// Caption schema maxWords.
    public var maxWords: Int
    /// Caption schema maxLines.
    public var maxLines: Int
    /// Maximum line advance width as a fraction of the frame width (further limited by the safe area).
    public var maxLineWidthW: Double
    /// Caption schema balance.
    public var balance: CaptionLayoutBalance
    /// Caption schema minShrink.
    public var minShrink: Double
    /// Caption schema breakOnSentence.
    public var breakOnSentence: Bool
    /// Caption schema breakOnComma.
    public var breakOnComma: Bool
    /// null disables gap breaks.
    public var breakOnGapSec: Double?
    /// null means no limit.
    public var maxPageSec: Double?
    /// Caption schema holdGapSec.
    public var holdGapSec: Double
    /// Caption schema minPageSec.
    public var minPageSec: Double
    /// Caption schema align.
    public var align: CaptionLayoutAlign
    /// Extra space between line boxes.
    public var lineGapEm: Double

    /// Creates an explicit value without I/O or generated identifiers.
    public init(maxWords: Int, maxLines: Int, maxLineWidthW: Double, balance: CaptionLayoutBalance = .balanced, minShrink: Double = 0.5, breakOnSentence: Bool = true, breakOnComma: Bool = false, breakOnGapSec: Double? = 0.6, maxPageSec: Double? = nil, holdGapSec: Double = 0.5, minPageSec: Double = 0.3, align: CaptionLayoutAlign = .center, lineGapEm: Double = 0) {
        self.maxWords = maxWords
        self.maxLines = maxLines
        self.maxLineWidthW = maxLineWidthW
        self.balance = balance
        self.minShrink = minShrink
        self.breakOnSentence = breakOnSentence
        self.breakOnComma = breakOnComma
        self.breakOnGapSec = breakOnGapSec
        self.maxPageSec = maxPageSec
        self.holdGapSec = holdGapSec
        self.minPageSec = minPageSec
        self.align = align
        self.lineGapEm = lineGapEm
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case maxWords
        case maxLines
        case maxLineWidthW
        case balance
        case minShrink
        case breakOnSentence
        case breakOnComma
        case breakOnGapSec
        case maxPageSec
        case holdGapSec
        case minPageSec
        case align
        case lineGapEm
    }

    public init(from decoder: any Decoder) throws {
        try CaptionDecoding.keys(decoder, allowed: CodingKeys.allCases.map(\.rawValue))
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.maxWords = try values.decode(Int.self, forKey: .maxWords)
        try CaptionDecoding.check(self.maxWords, decoder: decoder, message: "Invalid CaptionLayout.maxWords") { value in value >= 1 && value <= 16 }
        self.maxLines = try values.decode(Int.self, forKey: .maxLines)
        try CaptionDecoding.check(self.maxLines, decoder: decoder, message: "Invalid CaptionLayout.maxLines") { value in value >= 1 && value <= 3 }
        self.maxLineWidthW = try values.decode(Double.self, forKey: .maxLineWidthW)
        try CaptionDecoding.check(self.maxLineWidthW, decoder: decoder, message: "Invalid CaptionLayout.maxLineWidthW") { value in value >= 0.2 && value <= 1 }
        try CaptionDecoding.nonNull(values, .balance, decoder)
        self.balance = try values.decodeIfPresent(CaptionLayoutBalance.self, forKey: .balance) ?? .balanced
        try CaptionDecoding.nonNull(values, .minShrink, decoder)
        self.minShrink = try values.decodeIfPresent(Double.self, forKey: .minShrink) ?? 0.5
        try CaptionDecoding.check(self.minShrink, decoder: decoder, message: "Invalid CaptionLayout.minShrink") { value in value >= 0.3 && value <= 1 }
        try CaptionDecoding.nonNull(values, .breakOnSentence, decoder)
        self.breakOnSentence = try values.decodeIfPresent(Bool.self, forKey: .breakOnSentence) ?? true
        try CaptionDecoding.nonNull(values, .breakOnComma, decoder)
        self.breakOnComma = try values.decodeIfPresent(Bool.self, forKey: .breakOnComma) ?? false
        self.breakOnGapSec = values.contains(.breakOnGapSec) ? try values.decodeIfPresent(Double.self, forKey: .breakOnGapSec) : 0.6
        try CaptionDecoding.check(self.breakOnGapSec, decoder: decoder, message: "Invalid CaptionLayout.breakOnGapSec") { value in value >= 0 && value <= 10 }
        self.maxPageSec = try values.decodeIfPresent(Double.self, forKey: .maxPageSec) ?? nil
        try CaptionDecoding.check(self.maxPageSec, decoder: decoder, message: "Invalid CaptionLayout.maxPageSec") { value in value >= 0.5 && value <= 30 }
        try CaptionDecoding.nonNull(values, .holdGapSec, decoder)
        self.holdGapSec = try values.decodeIfPresent(Double.self, forKey: .holdGapSec) ?? 0.5
        try CaptionDecoding.check(self.holdGapSec, decoder: decoder, message: "Invalid CaptionLayout.holdGapSec") { value in value >= 0 && value <= 5 }
        try CaptionDecoding.nonNull(values, .minPageSec, decoder)
        self.minPageSec = try values.decodeIfPresent(Double.self, forKey: .minPageSec) ?? 0.3
        try CaptionDecoding.check(self.minPageSec, decoder: decoder, message: "Invalid CaptionLayout.minPageSec") { value in value >= 0 && value <= 5 }
        try CaptionDecoding.nonNull(values, .align, decoder)
        self.align = try values.decodeIfPresent(CaptionLayoutAlign.self, forKey: .align) ?? .center
        try CaptionDecoding.nonNull(values, .lineGapEm, decoder)
        self.lineGapEm = try values.decodeIfPresent(Double.self, forKey: .lineGapEm) ?? 0
        try CaptionDecoding.check(self.lineGapEm, decoder: decoder, message: "Invalid CaptionLayout.lineGapEm") { value in value >= 0 && value <= 2 }
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(self.maxWords, forKey: .maxWords)
        try values.encode(self.maxLines, forKey: .maxLines)
        try values.encode(self.maxLineWidthW, forKey: .maxLineWidthW)
        try values.encode(self.balance, forKey: .balance)
        try values.encode(self.minShrink, forKey: .minShrink)
        try values.encode(self.breakOnSentence, forKey: .breakOnSentence)
        try values.encode(self.breakOnComma, forKey: .breakOnComma)
        try values.encode(self.breakOnGapSec, forKey: .breakOnGapSec)
        try values.encode(self.maxPageSec, forKey: .maxPageSec)
        try values.encode(self.holdGapSec, forKey: .holdGapSec)
        try values.encode(self.minPageSec, forKey: .minPageSec)
        try values.encode(self.align, forKey: .align)
        try values.encode(self.lineGapEm, forKey: .lineGapEm)
    }

}

/// Caption schema enum; captions §2.
public enum CaptionLayoutBalance: String, Codable, Sendable, Hashable, CaseIterable {
    case greedy
    case balanced
}

/// Caption schema enum; captions §2.
public enum CaptionLayoutAlign: String, Codable, Sendable, Hashable, CaseIterable {
    case center
    case left
    case right
}

/// Caption style value and schema defaults; captions §2, shared/caption-styles/schema.json.
public struct CaptionStylePosition: Codable, Sendable, Equatable {
    /// Caption schema x.
    public var x: Double
    /// Caption schema y.
    public var y: Double
    /// Caption schema anchorX.
    public var anchorX: CaptionStylePositionAnchorX
    /// Caption schema anchorY.
    public var anchorY: CaptionStylePositionAnchorY
    /// Caption schema userDraggable.
    public var userDraggable: Bool

    /// Creates an explicit value without I/O or generated identifiers.
    public init(x: Double, y: Double, anchorX: CaptionStylePositionAnchorX = .center, anchorY: CaptionStylePositionAnchorY = .center, userDraggable: Bool = true) {
        self.x = x
        self.y = y
        self.anchorX = anchorX
        self.anchorY = anchorY
        self.userDraggable = userDraggable
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case x
        case y
        case anchorX
        case anchorY
        case userDraggable
    }

    public init(from decoder: any Decoder) throws {
        try CaptionDecoding.keys(decoder, allowed: CodingKeys.allCases.map(\.rawValue))
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.x = try values.decode(Double.self, forKey: .x)
        try CaptionDecoding.check(self.x, decoder: decoder, message: "Invalid CaptionStylePosition.x") { value in value >= 0 && value <= 1 }
        self.y = try values.decode(Double.self, forKey: .y)
        try CaptionDecoding.check(self.y, decoder: decoder, message: "Invalid CaptionStylePosition.y") { value in value >= 0 && value <= 1 }
        try CaptionDecoding.nonNull(values, .anchorX, decoder)
        self.anchorX = try values.decodeIfPresent(CaptionStylePositionAnchorX.self, forKey: .anchorX) ?? .center
        try CaptionDecoding.nonNull(values, .anchorY, decoder)
        self.anchorY = try values.decodeIfPresent(CaptionStylePositionAnchorY.self, forKey: .anchorY) ?? .center
        try CaptionDecoding.nonNull(values, .userDraggable, decoder)
        self.userDraggable = try values.decodeIfPresent(Bool.self, forKey: .userDraggable) ?? true
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(self.x, forKey: .x)
        try values.encode(self.y, forKey: .y)
        try values.encode(self.anchorX, forKey: .anchorX)
        try values.encode(self.anchorY, forKey: .anchorY)
        try values.encode(self.userDraggable, forKey: .userDraggable)
    }

}

/// Caption schema enum; captions §2.
public enum CaptionStylePositionAnchorX: String, Codable, Sendable, Hashable, CaseIterable {
    case center
    case left
    case right
}

/// Caption schema enum; captions §2.
public enum CaptionStylePositionAnchorY: String, Codable, Sendable, Hashable, CaseIterable {
    case center
    case top
    case bottom
}

/// Caption style value and schema defaults; captions §2, shared/caption-styles/schema.json.
public struct CaptionAspects: Codable, Sendable, Equatable {
    /// Caption schema portrait.
    public var portrait: CaptionAspectOverride?
    /// Caption schema square.
    public var square: CaptionAspectOverride?
    /// Caption schema landscape.
    public var landscape: CaptionAspectOverride?

    /// Creates an explicit value without I/O or generated identifiers.
    public init(portrait: CaptionAspectOverride? = nil, square: CaptionAspectOverride? = nil, landscape: CaptionAspectOverride? = nil) {
        self.portrait = portrait
        self.square = square
        self.landscape = landscape
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case portrait
        case square
        case landscape
    }

    public init(from decoder: any Decoder) throws {
        try CaptionDecoding.keys(decoder, allowed: CodingKeys.allCases.map(\.rawValue))
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try CaptionDecoding.nonNull(values, .portrait, decoder)
        self.portrait = try values.decodeIfPresent(CaptionAspectOverride.self, forKey: .portrait) ?? nil
        try CaptionDecoding.nonNull(values, .square, decoder)
        self.square = try values.decodeIfPresent(CaptionAspectOverride.self, forKey: .square) ?? nil
        try CaptionDecoding.nonNull(values, .landscape, decoder)
        self.landscape = try values.decodeIfPresent(CaptionAspectOverride.self, forKey: .landscape) ?? nil
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeIfPresent(self.portrait, forKey: .portrait)
        try values.encodeIfPresent(self.square, forKey: .square)
        try values.encodeIfPresent(self.landscape, forKey: .landscape)
    }

}

/// Caption style value and schema defaults; captions §2, shared/caption-styles/schema.json.
public struct CaptionAspectOverride: Codable, Sendable, Equatable {
    /// Caption schema sizeSh.
    public var sizeSh: Double?
    /// Caption schema x.
    public var x: Double?
    /// Caption schema y.
    public var y: Double?
    /// Caption schema maxLineWidthW.
    public var maxLineWidthW: Double?
    /// Caption schema maxWords.
    public var maxWords: Int?

    /// Creates an explicit value without I/O or generated identifiers.
    public init(sizeSh: Double? = nil, x: Double? = nil, y: Double? = nil, maxLineWidthW: Double? = nil, maxWords: Int? = nil) {
        self.sizeSh = sizeSh
        self.x = x
        self.y = y
        self.maxLineWidthW = maxLineWidthW
        self.maxWords = maxWords
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case sizeSh
        case x
        case y
        case maxLineWidthW
        case maxWords
    }

    public init(from decoder: any Decoder) throws {
        try CaptionDecoding.keys(decoder, allowed: CodingKeys.allCases.map(\.rawValue))
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try CaptionDecoding.nonNull(values, .sizeSh, decoder)
        self.sizeSh = try values.decodeIfPresent(Double.self, forKey: .sizeSh) ?? nil
        try CaptionDecoding.check(self.sizeSh, decoder: decoder, message: "Invalid CaptionAspectOverride.sizeSh") { value in value >= 0.01 && value <= 0.3 }
        try CaptionDecoding.nonNull(values, .x, decoder)
        self.x = try values.decodeIfPresent(Double.self, forKey: .x) ?? nil
        try CaptionDecoding.check(self.x, decoder: decoder, message: "Invalid CaptionAspectOverride.x") { value in value >= 0 && value <= 1 }
        try CaptionDecoding.nonNull(values, .y, decoder)
        self.y = try values.decodeIfPresent(Double.self, forKey: .y) ?? nil
        try CaptionDecoding.check(self.y, decoder: decoder, message: "Invalid CaptionAspectOverride.y") { value in value >= 0 && value <= 1 }
        try CaptionDecoding.nonNull(values, .maxLineWidthW, decoder)
        self.maxLineWidthW = try values.decodeIfPresent(Double.self, forKey: .maxLineWidthW) ?? nil
        try CaptionDecoding.check(self.maxLineWidthW, decoder: decoder, message: "Invalid CaptionAspectOverride.maxLineWidthW") { value in value >= 0.2 && value <= 1 }
        try CaptionDecoding.nonNull(values, .maxWords, decoder)
        self.maxWords = try values.decodeIfPresent(Int.self, forKey: .maxWords) ?? nil
        try CaptionDecoding.check(self.maxWords, decoder: decoder, message: "Invalid CaptionAspectOverride.maxWords") { value in value >= 1 && value <= 16 }
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeIfPresent(self.sizeSh, forKey: .sizeSh)
        try values.encodeIfPresent(self.x, forKey: .x)
        try values.encodeIfPresent(self.y, forKey: .y)
        try values.encodeIfPresent(self.maxLineWidthW, forKey: .maxLineWidthW)
        try values.encodeIfPresent(self.maxWords, forKey: .maxWords)
    }

}

/// Caption style value and schema defaults; captions §2, shared/caption-styles/schema.json.
public struct CaptionStroke: Codable, Sendable, Equatable {
    /// Full stroke line width (SVG stroke-width), centred on the outline and drawn under the fill, so widthEm/2 shows outside the glyph.
    public var widthEm: Double
    /// sRGB, gamma-encoded, straight alpha: #RRGGBB or #RRGGBBAA. '$accent' is the style accent (opaque); '$accent/AA' is the accent with alpha byte AA.
    public var color: String

    /// Creates an explicit value without I/O or generated identifiers.
    public init(widthEm: Double, color: String) {
        self.widthEm = widthEm
        self.color = color
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case widthEm
        case color
    }

    public init(from decoder: any Decoder) throws {
        try CaptionDecoding.keys(decoder, allowed: CodingKeys.allCases.map(\.rawValue))
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.widthEm = try values.decode(Double.self, forKey: .widthEm)
        try CaptionDecoding.check(self.widthEm, decoder: decoder, message: "Invalid CaptionStroke.widthEm") { value in value >= 0 && value <= 0.5 }
        self.color = try values.decode(String.self, forKey: .color)
        try CaptionDecoding.check(self.color, decoder: decoder, message: "Invalid CaptionStroke.color") { value in value.range(of: "^(#[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?|\\$accent(/[0-9A-Fa-f]{2})?)$", options: .regularExpression) != nil }
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(self.widthEm, forKey: .widthEm)
        try values.encode(self.color, forKey: .color)
    }

}

/// Caption style value and schema defaults; captions §2, shared/caption-styles/schema.json.
public struct CaptionShadow: Codable, Sendable, Equatable {
    /// Caption schema dxEm.
    public var dxEm: Double
    /// Caption schema dyEm.
    public var dyEm: Double
    /// Gaussian standard deviation in em; 0 is a hard shadow.
    public var sigmaEm: Double
    /// sRGB, gamma-encoded, straight alpha: #RRGGBB or #RRGGBBAA. '$accent' is the style accent (opaque); '$accent/AA' is the accent with alpha byte AA.
    public var color: String

    /// Creates an explicit value without I/O or generated identifiers.
    public init(dxEm: Double, dyEm: Double, sigmaEm: Double, color: String) {
        self.dxEm = dxEm
        self.dyEm = dyEm
        self.sigmaEm = sigmaEm
        self.color = color
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case dxEm
        case dyEm
        case sigmaEm
        case color
    }

    public init(from decoder: any Decoder) throws {
        try CaptionDecoding.keys(decoder, allowed: CodingKeys.allCases.map(\.rawValue))
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.dxEm = try values.decode(Double.self, forKey: .dxEm)
        try CaptionDecoding.check(self.dxEm, decoder: decoder, message: "Invalid CaptionShadow.dxEm") { value in value >= -1 && value <= 1 }
        self.dyEm = try values.decode(Double.self, forKey: .dyEm)
        try CaptionDecoding.check(self.dyEm, decoder: decoder, message: "Invalid CaptionShadow.dyEm") { value in value >= -1 && value <= 1 }
        self.sigmaEm = try values.decode(Double.self, forKey: .sigmaEm)
        try CaptionDecoding.check(self.sigmaEm, decoder: decoder, message: "Invalid CaptionShadow.sigmaEm") { value in value >= 0 && value <= 1 }
        self.color = try values.decode(String.self, forKey: .color)
        try CaptionDecoding.check(self.color, decoder: decoder, message: "Invalid CaptionShadow.color") { value in value.range(of: "^(#[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?|\\$accent(/[0-9A-Fa-f]{2})?)$", options: .regularExpression) != nil }
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(self.dxEm, forKey: .dxEm)
        try values.encode(self.dyEm, forKey: .dyEm)
        try values.encode(self.sigmaEm, forKey: .sigmaEm)
        try values.encode(self.color, forKey: .color)
    }

}

/// Caption style value and schema defaults; captions §2, shared/caption-styles/schema.json.
public struct CaptionBox: Codable, Sendable, Equatable {
    /// Caption schema scope.
    public var scope: CaptionBoxScope
    /// sRGB, gamma-encoded, straight alpha: #RRGGBB or #RRGGBBAA. '$accent' is the style accent (opaque); '$accent/AA' is the accent with alpha byte AA.
    public var color: String
    /// Caption schema paddingXEm.
    public var paddingXEm: Double
    /// Caption schema paddingYEm.
    public var paddingYEm: Double
    /// Caption schema radiusEm.
    public var radiusEm: Double
    /// Caption schema pill.
    public var pill: Bool
    /// Caption schema borderWidthEm.
    public var borderWidthEm: Double
    /// sRGB, gamma-encoded, straight alpha: #RRGGBB or #RRGGBBAA. '$accent' is the style accent (opaque); '$accent/AA' is the accent with alpha byte AA.
    public var borderColor: String?

    /// Creates an explicit value without I/O or generated identifiers.
    public init(scope: CaptionBoxScope, color: String, paddingXEm: Double = 0.4, paddingYEm: Double = 0.15, radiusEm: Double = 0.2, pill: Bool = false, borderWidthEm: Double = 0, borderColor: String? = nil) {
        self.scope = scope
        self.color = color
        self.paddingXEm = paddingXEm
        self.paddingYEm = paddingYEm
        self.radiusEm = radiusEm
        self.pill = pill
        self.borderWidthEm = borderWidthEm
        self.borderColor = borderColor
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case scope
        case color
        case paddingXEm
        case paddingYEm
        case radiusEm
        case pill
        case borderWidthEm
        case borderColor
    }

    public init(from decoder: any Decoder) throws {
        try CaptionDecoding.keys(decoder, allowed: CodingKeys.allCases.map(\.rawValue))
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.scope = try values.decode(CaptionBoxScope.self, forKey: .scope)
        self.color = try values.decode(String.self, forKey: .color)
        try CaptionDecoding.check(self.color, decoder: decoder, message: "Invalid CaptionBox.color") { value in value.range(of: "^(#[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?|\\$accent(/[0-9A-Fa-f]{2})?)$", options: .regularExpression) != nil }
        try CaptionDecoding.nonNull(values, .paddingXEm, decoder)
        self.paddingXEm = try values.decodeIfPresent(Double.self, forKey: .paddingXEm) ?? 0.4
        try CaptionDecoding.check(self.paddingXEm, decoder: decoder, message: "Invalid CaptionBox.paddingXEm") { value in value >= 0 && value <= 2 }
        try CaptionDecoding.nonNull(values, .paddingYEm, decoder)
        self.paddingYEm = try values.decodeIfPresent(Double.self, forKey: .paddingYEm) ?? 0.15
        try CaptionDecoding.check(self.paddingYEm, decoder: decoder, message: "Invalid CaptionBox.paddingYEm") { value in value >= 0 && value <= 2 }
        try CaptionDecoding.nonNull(values, .radiusEm, decoder)
        self.radiusEm = try values.decodeIfPresent(Double.self, forKey: .radiusEm) ?? 0.2
        try CaptionDecoding.check(self.radiusEm, decoder: decoder, message: "Invalid CaptionBox.radiusEm") { value in value >= 0 && value <= 2 }
        try CaptionDecoding.nonNull(values, .pill, decoder)
        self.pill = try values.decodeIfPresent(Bool.self, forKey: .pill) ?? false
        try CaptionDecoding.nonNull(values, .borderWidthEm, decoder)
        self.borderWidthEm = try values.decodeIfPresent(Double.self, forKey: .borderWidthEm) ?? 0
        try CaptionDecoding.check(self.borderWidthEm, decoder: decoder, message: "Invalid CaptionBox.borderWidthEm") { value in value >= 0 && value <= 0.5 }
        try CaptionDecoding.nonNull(values, .borderColor, decoder)
        self.borderColor = try values.decodeIfPresent(String.self, forKey: .borderColor) ?? nil
        try CaptionDecoding.check(self.borderColor, decoder: decoder, message: "Invalid CaptionBox.borderColor") { value in value.range(of: "^(#[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?|\\$accent(/[0-9A-Fa-f]{2})?)$", options: .regularExpression) != nil }
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(self.scope, forKey: .scope)
        try values.encode(self.color, forKey: .color)
        try values.encode(self.paddingXEm, forKey: .paddingXEm)
        try values.encode(self.paddingYEm, forKey: .paddingYEm)
        try values.encode(self.radiusEm, forKey: .radiusEm)
        try values.encode(self.pill, forKey: .pill)
        try values.encode(self.borderWidthEm, forKey: .borderWidthEm)
        try values.encodeIfPresent(self.borderColor, forKey: .borderColor)
    }

}

/// Caption schema enum; captions §2.
public enum CaptionBoxScope: String, Codable, Sendable, Hashable, CaseIterable {
    case page
    case line
    case word
}

/// Caption style value and schema defaults; captions §2, shared/caption-styles/schema.json.
public struct CaptionWordStates: Codable, Sendable, Equatable {
    /// Caption schema past.
    public var past: CaptionWordState?
    /// Caption schema active.
    public var active: CaptionWordState?
    /// Caption schema future.
    public var future: CaptionWordState?

    /// Creates an explicit value without I/O or generated identifiers.
    public init(past: CaptionWordState? = nil, active: CaptionWordState? = nil, future: CaptionWordState? = nil) {
        self.past = past
        self.active = active
        self.future = future
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case past
        case active
        case future
    }

    public init(from decoder: any Decoder) throws {
        try CaptionDecoding.keys(decoder, allowed: CodingKeys.allCases.map(\.rawValue))
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try CaptionDecoding.nonNull(values, .past, decoder)
        self.past = try values.decodeIfPresent(CaptionWordState.self, forKey: .past) ?? nil
        try CaptionDecoding.nonNull(values, .active, decoder)
        self.active = try values.decodeIfPresent(CaptionWordState.self, forKey: .active) ?? nil
        try CaptionDecoding.nonNull(values, .future, decoder)
        self.future = try values.decodeIfPresent(CaptionWordState.self, forKey: .future) ?? nil
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeIfPresent(self.past, forKey: .past)
        try values.encodeIfPresent(self.active, forKey: .active)
        try values.encodeIfPresent(self.future, forKey: .future)
    }

}

/// Caption style value and schema defaults; captions §2, shared/caption-styles/schema.json.
public struct CaptionWordState: Codable, Sendable, Equatable {
    /// Caption schema fill.
    public var fill: CaptionPaint?
    /// Caption schema opacity.
    public var opacity: Double?
    /// Drawn about the word centre; never changes layout.
    public var scale: Double?
    /// sRGB, gamma-encoded, straight alpha: #RRGGBB or #RRGGBBAA. '$accent' is the style accent (opaque); '$accent/AA' is the accent with alpha byte AA.
    public var strokeColor: String?
    /// Caption schema hideStroke.
    public var hideStroke: Bool?
    /// Caption schema box.
    public var box: CaptionWordBox?

    /// Creates an explicit value without I/O or generated identifiers.
    public init(fill: CaptionPaint? = nil, opacity: Double? = nil, scale: Double? = nil, strokeColor: String? = nil, hideStroke: Bool? = nil, box: CaptionWordBox? = nil) {
        self.fill = fill
        self.opacity = opacity
        self.scale = scale
        self.strokeColor = strokeColor
        self.hideStroke = hideStroke
        self.box = box
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case fill
        case opacity
        case scale
        case strokeColor
        case hideStroke
        case box
    }

    public init(from decoder: any Decoder) throws {
        try CaptionDecoding.keys(decoder, allowed: CodingKeys.allCases.map(\.rawValue))
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try CaptionDecoding.nonNull(values, .fill, decoder)
        self.fill = try values.decodeIfPresent(CaptionPaint.self, forKey: .fill) ?? nil
        try CaptionDecoding.nonNull(values, .opacity, decoder)
        self.opacity = try values.decodeIfPresent(Double.self, forKey: .opacity) ?? nil
        try CaptionDecoding.check(self.opacity, decoder: decoder, message: "Invalid CaptionWordState.opacity") { value in value >= 0 && value <= 1 }
        try CaptionDecoding.nonNull(values, .scale, decoder)
        self.scale = try values.decodeIfPresent(Double.self, forKey: .scale) ?? nil
        try CaptionDecoding.check(self.scale, decoder: decoder, message: "Invalid CaptionWordState.scale") { value in value >= 0.5 && value <= 2 }
        try CaptionDecoding.nonNull(values, .strokeColor, decoder)
        self.strokeColor = try values.decodeIfPresent(String.self, forKey: .strokeColor) ?? nil
        try CaptionDecoding.check(self.strokeColor, decoder: decoder, message: "Invalid CaptionWordState.strokeColor") { value in value.range(of: "^(#[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?|\\$accent(/[0-9A-Fa-f]{2})?)$", options: .regularExpression) != nil }
        try CaptionDecoding.nonNull(values, .hideStroke, decoder)
        self.hideStroke = try values.decodeIfPresent(Bool.self, forKey: .hideStroke) ?? nil
        try CaptionDecoding.nonNull(values, .box, decoder)
        self.box = try values.decodeIfPresent(CaptionWordBox.self, forKey: .box) ?? nil
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeIfPresent(self.fill, forKey: .fill)
        try values.encodeIfPresent(self.opacity, forKey: .opacity)
        try values.encodeIfPresent(self.scale, forKey: .scale)
        try values.encodeIfPresent(self.strokeColor, forKey: .strokeColor)
        try values.encodeIfPresent(self.hideStroke, forKey: .hideStroke)
        try values.encodeIfPresent(self.box, forKey: .box)
    }

}

/// Caption style value and schema defaults; captions §2, shared/caption-styles/schema.json.
public struct CaptionWordBox: Codable, Sendable, Equatable {
    /// sRGB, gamma-encoded, straight alpha: #RRGGBB or #RRGGBBAA. '$accent' is the style accent (opaque); '$accent/AA' is the accent with alpha byte AA.
    public var color: String
    /// Caption schema paddingXEm.
    public var paddingXEm: Double
    /// Caption schema paddingYEm.
    public var paddingYEm: Double
    /// Caption schema radiusEm.
    public var radiusEm: Double
    /// Caption schema pill.
    public var pill: Bool
    /// Caption schema borderWidthEm.
    public var borderWidthEm: Double
    /// sRGB, gamma-encoded, straight alpha: #RRGGBB or #RRGGBBAA. '$accent' is the style accent (opaque); '$accent/AA' is the accent with alpha byte AA.
    public var borderColor: String?

    /// Creates an explicit value without I/O or generated identifiers.
    public init(color: String, paddingXEm: Double = 0.4, paddingYEm: Double = 0.15, radiusEm: Double = 0.2, pill: Bool = false, borderWidthEm: Double = 0, borderColor: String? = nil) {
        self.color = color
        self.paddingXEm = paddingXEm
        self.paddingYEm = paddingYEm
        self.radiusEm = radiusEm
        self.pill = pill
        self.borderWidthEm = borderWidthEm
        self.borderColor = borderColor
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case color
        case paddingXEm
        case paddingYEm
        case radiusEm
        case pill
        case borderWidthEm
        case borderColor
    }

    public init(from decoder: any Decoder) throws {
        try CaptionDecoding.keys(decoder, allowed: CodingKeys.allCases.map(\.rawValue))
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.color = try values.decode(String.self, forKey: .color)
        try CaptionDecoding.check(self.color, decoder: decoder, message: "Invalid CaptionWordBox.color") { value in value.range(of: "^(#[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?|\\$accent(/[0-9A-Fa-f]{2})?)$", options: .regularExpression) != nil }
        try CaptionDecoding.nonNull(values, .paddingXEm, decoder)
        self.paddingXEm = try values.decodeIfPresent(Double.self, forKey: .paddingXEm) ?? 0.4
        try CaptionDecoding.check(self.paddingXEm, decoder: decoder, message: "Invalid CaptionWordBox.paddingXEm") { value in value >= 0 && value <= 2 }
        try CaptionDecoding.nonNull(values, .paddingYEm, decoder)
        self.paddingYEm = try values.decodeIfPresent(Double.self, forKey: .paddingYEm) ?? 0.15
        try CaptionDecoding.check(self.paddingYEm, decoder: decoder, message: "Invalid CaptionWordBox.paddingYEm") { value in value >= 0 && value <= 2 }
        try CaptionDecoding.nonNull(values, .radiusEm, decoder)
        self.radiusEm = try values.decodeIfPresent(Double.self, forKey: .radiusEm) ?? 0.2
        try CaptionDecoding.check(self.radiusEm, decoder: decoder, message: "Invalid CaptionWordBox.radiusEm") { value in value >= 0 && value <= 2 }
        try CaptionDecoding.nonNull(values, .pill, decoder)
        self.pill = try values.decodeIfPresent(Bool.self, forKey: .pill) ?? false
        try CaptionDecoding.nonNull(values, .borderWidthEm, decoder)
        self.borderWidthEm = try values.decodeIfPresent(Double.self, forKey: .borderWidthEm) ?? 0
        try CaptionDecoding.check(self.borderWidthEm, decoder: decoder, message: "Invalid CaptionWordBox.borderWidthEm") { value in value >= 0 && value <= 0.5 }
        try CaptionDecoding.nonNull(values, .borderColor, decoder)
        self.borderColor = try values.decodeIfPresent(String.self, forKey: .borderColor) ?? nil
        try CaptionDecoding.check(self.borderColor, decoder: decoder, message: "Invalid CaptionWordBox.borderColor") { value in value.range(of: "^(#[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?|\\$accent(/[0-9A-Fa-f]{2})?)$", options: .regularExpression) != nil }
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(self.color, forKey: .color)
        try values.encode(self.paddingXEm, forKey: .paddingXEm)
        try values.encode(self.paddingYEm, forKey: .paddingYEm)
        try values.encode(self.radiusEm, forKey: .radiusEm)
        try values.encode(self.pill, forKey: .pill)
        try values.encode(self.borderWidthEm, forKey: .borderWidthEm)
        try values.encodeIfPresent(self.borderColor, forKey: .borderColor)
    }

}

/// Caption style value and schema defaults; captions §2, shared/caption-styles/schema.json.
public struct CaptionReveal: Codable, Sendable, Equatable {
    /// Caption schema unit.
    public var unit: CaptionRevealUnit
    /// Caption schema maxCharsPerSec.
    public var maxCharsPerSec: Double
    /// Caption schema cursor.
    public var cursor: CaptionRevealCursor?

    /// Creates an explicit value without I/O or generated identifiers.
    public init(unit: CaptionRevealUnit = .page, maxCharsPerSec: Double = 30, cursor: CaptionRevealCursor? = nil) {
        self.unit = unit
        self.maxCharsPerSec = maxCharsPerSec
        self.cursor = cursor
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case unit
        case maxCharsPerSec
        case cursor
    }

    public init(from decoder: any Decoder) throws {
        try CaptionDecoding.keys(decoder, allowed: CodingKeys.allCases.map(\.rawValue))
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try CaptionDecoding.nonNull(values, .unit, decoder)
        self.unit = try values.decodeIfPresent(CaptionRevealUnit.self, forKey: .unit) ?? .page
        try CaptionDecoding.nonNull(values, .maxCharsPerSec, decoder)
        self.maxCharsPerSec = try values.decodeIfPresent(Double.self, forKey: .maxCharsPerSec) ?? 30
        try CaptionDecoding.check(self.maxCharsPerSec, decoder: decoder, message: "Invalid CaptionReveal.maxCharsPerSec") { value in value >= 1 && value <= 200 }
        try CaptionDecoding.nonNull(values, .cursor, decoder)
        self.cursor = try values.decodeIfPresent(CaptionRevealCursor.self, forKey: .cursor) ?? nil
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(self.unit, forKey: .unit)
        try values.encode(self.maxCharsPerSec, forKey: .maxCharsPerSec)
        try values.encodeIfPresent(self.cursor, forKey: .cursor)
    }

}

/// Caption schema enum; captions §2.
public enum CaptionRevealUnit: String, Codable, Sendable, Hashable, CaseIterable {
    case page
    case word
    case char
    case wipe
}

/// Caption style value and schema defaults; captions §2, shared/caption-styles/schema.json.
public struct CaptionRevealCursor: Codable, Sendable, Equatable {
    /// Caption schema widthEm.
    public var widthEm: Double
    /// sRGB, gamma-encoded, straight alpha: #RRGGBB or #RRGGBBAA. '$accent' is the style accent (opaque); '$accent/AA' is the accent with alpha byte AA.
    public var color: String
    /// Caption schema blinkHz.
    public var blinkHz: Double

    /// Creates an explicit value without I/O or generated identifiers.
    public init(widthEm: Double, color: String, blinkHz: Double = 2) {
        self.widthEm = widthEm
        self.color = color
        self.blinkHz = blinkHz
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case widthEm
        case color
        case blinkHz
    }

    public init(from decoder: any Decoder) throws {
        try CaptionDecoding.keys(decoder, allowed: CodingKeys.allCases.map(\.rawValue))
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.widthEm = try values.decode(Double.self, forKey: .widthEm)
        try CaptionDecoding.check(self.widthEm, decoder: decoder, message: "Invalid CaptionRevealCursor.widthEm") { value in value >= 0.01 && value <= 0.5 }
        self.color = try values.decode(String.self, forKey: .color)
        try CaptionDecoding.check(self.color, decoder: decoder, message: "Invalid CaptionRevealCursor.color") { value in value.range(of: "^(#[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?|\\$accent(/[0-9A-Fa-f]{2})?)$", options: .regularExpression) != nil }
        try CaptionDecoding.nonNull(values, .blinkHz, decoder)
        self.blinkHz = try values.decodeIfPresent(Double.self, forKey: .blinkHz) ?? 2
        try CaptionDecoding.check(self.blinkHz, decoder: decoder, message: "Invalid CaptionRevealCursor.blinkHz") { value in value >= 0 && value <= 10 }
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(self.widthEm, forKey: .widthEm)
        try values.encode(self.color, forKey: .color)
        try values.encode(self.blinkHz, forKey: .blinkHz)
    }

}

/// Caption style value and schema defaults; captions §2, shared/caption-styles/schema.json.
public struct CaptionAnimation: Codable, Sendable, Equatable {
    /// Caption schema pageIn.
    public var pageIn: CaptionAnim?
    /// Caption schema pageOut.
    public var pageOut: CaptionAnim?
    /// Caption schema wordIn.
    public var wordIn: CaptionAnim?
    /// Caption schema activeIn.
    public var activeIn: CaptionAnim?

    /// Creates an explicit value without I/O or generated identifiers.
    public init(pageIn: CaptionAnim? = nil, pageOut: CaptionAnim? = nil, wordIn: CaptionAnim? = nil, activeIn: CaptionAnim? = nil) {
        self.pageIn = pageIn
        self.pageOut = pageOut
        self.wordIn = wordIn
        self.activeIn = activeIn
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case pageIn
        case pageOut
        case wordIn
        case activeIn
    }

    public init(from decoder: any Decoder) throws {
        try CaptionDecoding.keys(decoder, allowed: CodingKeys.allCases.map(\.rawValue))
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try CaptionDecoding.nonNull(values, .pageIn, decoder)
        self.pageIn = try values.decodeIfPresent(CaptionAnim.self, forKey: .pageIn) ?? nil
        try CaptionDecoding.nonNull(values, .pageOut, decoder)
        self.pageOut = try values.decodeIfPresent(CaptionAnim.self, forKey: .pageOut) ?? nil
        try CaptionDecoding.nonNull(values, .wordIn, decoder)
        self.wordIn = try values.decodeIfPresent(CaptionAnim.self, forKey: .wordIn) ?? nil
        try CaptionDecoding.nonNull(values, .activeIn, decoder)
        self.activeIn = try values.decodeIfPresent(CaptionAnim.self, forKey: .activeIn) ?? nil
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeIfPresent(self.pageIn, forKey: .pageIn)
        try values.encodeIfPresent(self.pageOut, forKey: .pageOut)
        try values.encodeIfPresent(self.wordIn, forKey: .wordIn)
        try values.encodeIfPresent(self.activeIn, forKey: .activeIn)
    }

}

/// Caption style value and schema defaults; captions §2, shared/caption-styles/schema.json.
public struct CaptionAnim: Codable, Sendable, Equatable {
    /// Caption schema type.
    public var type: CaptionAnimType
    /// Caption schema durationSec.
    public var durationSec: Double
    /// Caption schema easing.
    public var easing: CaptionAnimEasing
    /// Caption schema fromScale.
    public var fromScale: Double
    /// Caption schema fromOffsetEm.
    public var fromOffsetEm: Double
    /// Caption schema overshoot.
    public var overshoot: Double

    /// Creates an explicit value without I/O or generated identifiers.
    public init(type: CaptionAnimType, durationSec: Double, easing: CaptionAnimEasing = .easeOutCubic, fromScale: Double = 0.8, fromOffsetEm: Double = 0.4, overshoot: Double = 1.70158) {
        self.type = type
        self.durationSec = durationSec
        self.easing = easing
        self.fromScale = fromScale
        self.fromOffsetEm = fromOffsetEm
        self.overshoot = overshoot
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case type
        case durationSec
        case easing
        case fromScale
        case fromOffsetEm
        case overshoot
    }

    public init(from decoder: any Decoder) throws {
        try CaptionDecoding.keys(decoder, allowed: CodingKeys.allCases.map(\.rawValue))
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try values.decode(CaptionAnimType.self, forKey: .type)
        self.durationSec = try values.decode(Double.self, forKey: .durationSec)
        try CaptionDecoding.check(self.durationSec, decoder: decoder, message: "Invalid CaptionAnim.durationSec") { value in value >= 0 && value <= 2 }
        try CaptionDecoding.nonNull(values, .easing, decoder)
        self.easing = try values.decodeIfPresent(CaptionAnimEasing.self, forKey: .easing) ?? .easeOutCubic
        try CaptionDecoding.nonNull(values, .fromScale, decoder)
        self.fromScale = try values.decodeIfPresent(Double.self, forKey: .fromScale) ?? 0.8
        try CaptionDecoding.check(self.fromScale, decoder: decoder, message: "Invalid CaptionAnim.fromScale") { value in value >= 0 && value <= 2 }
        try CaptionDecoding.nonNull(values, .fromOffsetEm, decoder)
        self.fromOffsetEm = try values.decodeIfPresent(Double.self, forKey: .fromOffsetEm) ?? 0.4
        try CaptionDecoding.check(self.fromOffsetEm, decoder: decoder, message: "Invalid CaptionAnim.fromOffsetEm") { value in value >= -2 && value <= 2 }
        try CaptionDecoding.nonNull(values, .overshoot, decoder)
        self.overshoot = try values.decodeIfPresent(Double.self, forKey: .overshoot) ?? 1.70158
        try CaptionDecoding.check(self.overshoot, decoder: decoder, message: "Invalid CaptionAnim.overshoot") { value in value >= 0 && value <= 4 }
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(self.type, forKey: .type)
        try values.encode(self.durationSec, forKey: .durationSec)
        try values.encode(self.easing, forKey: .easing)
        try values.encode(self.fromScale, forKey: .fromScale)
        try values.encode(self.fromOffsetEm, forKey: .fromOffsetEm)
        try values.encode(self.overshoot, forKey: .overshoot)
    }

}

/// Caption schema enum; captions §2.
public enum CaptionAnimType: String, Codable, Sendable, Hashable, CaseIterable {
    case `none`
    case fade
    case pop
    case zoom
    case slideUp = "slide-up"
}

/// Caption schema enum; captions §2.
public enum CaptionAnimEasing: String, Codable, Sendable, Hashable, CaseIterable {
    case linear
    case easeOutCubic
    case easeInOutCubic
    case easeOutBack
}

/// Caption style value and schema defaults; captions §2, shared/caption-styles/schema.json.
public struct CaptionEmphasis: Codable, Sendable, Equatable {
    /// v1 apps treat 'llm' as 'rule'.
    public var source: CaptionEmphasisSource
    /// Caption schema maxPerPage.
    public var maxPerPage: Int
    /// Caption schema minScore.
    public var minScore: Double
    /// Caption schema fill.
    public var fill: CaptionPaint?
    /// Cycled over emphasised words in caption order; overrides fill.
    public var palette: [String]?
    /// File name of a font listed in shared/fonts/fonts.json.
    public var fontFile: String?
    /// Changes layout width and drawing size.
    public var scale: Double

    /// Creates an explicit value without I/O or generated identifiers.
    public init(source: CaptionEmphasisSource = .none, maxPerPage: Int = 1, minScore: Double = 0, fill: CaptionPaint? = nil, palette: [String]? = nil, fontFile: String? = nil, scale: Double = 1) {
        self.source = source
        self.maxPerPage = maxPerPage
        self.minScore = minScore
        self.fill = fill
        self.palette = palette
        self.fontFile = fontFile
        self.scale = scale
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case source
        case maxPerPage
        case minScore
        case fill
        case palette
        case fontFile
        case scale
    }

    public init(from decoder: any Decoder) throws {
        try CaptionDecoding.keys(decoder, allowed: CodingKeys.allCases.map(\.rawValue))
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try CaptionDecoding.nonNull(values, .source, decoder)
        self.source = try values.decodeIfPresent(CaptionEmphasisSource.self, forKey: .source) ?? .none
        try CaptionDecoding.nonNull(values, .maxPerPage, decoder)
        self.maxPerPage = try values.decodeIfPresent(Int.self, forKey: .maxPerPage) ?? 1
        try CaptionDecoding.check(self.maxPerPage, decoder: decoder, message: "Invalid CaptionEmphasis.maxPerPage") { value in value >= 0 && value <= 4 }
        try CaptionDecoding.nonNull(values, .minScore, decoder)
        self.minScore = try values.decodeIfPresent(Double.self, forKey: .minScore) ?? 0
        try CaptionDecoding.check(self.minScore, decoder: decoder, message: "Invalid CaptionEmphasis.minScore") { value in value >= 0 && value <= 10 }
        try CaptionDecoding.nonNull(values, .fill, decoder)
        self.fill = try values.decodeIfPresent(CaptionPaint.self, forKey: .fill) ?? nil
        try CaptionDecoding.nonNull(values, .palette, decoder)
        self.palette = try values.decodeIfPresent([String].self, forKey: .palette) ?? nil
        try CaptionDecoding.check(self.palette, decoder: decoder, message: "Invalid CaptionEmphasis.palette") { value in
            value.count >= 1 && value.count <= 8 && value.allSatisfy {
                $0.range(of: "^(#[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?|\\$accent(/[0-9A-Fa-f]{2})?)$", options: .regularExpression) != nil
            }
        }
        try CaptionDecoding.nonNull(values, .fontFile, decoder)
        self.fontFile = try values.decodeIfPresent(String.self, forKey: .fontFile) ?? nil
        try CaptionDecoding.check(self.fontFile, decoder: decoder, message: "Invalid CaptionEmphasis.fontFile") { value in value.range(of: "^[A-Za-z0-9_-]+\\.ttf$", options: .regularExpression) != nil }
        try CaptionDecoding.nonNull(values, .scale, decoder)
        self.scale = try values.decodeIfPresent(Double.self, forKey: .scale) ?? 1
        try CaptionDecoding.check(self.scale, decoder: decoder, message: "Invalid CaptionEmphasis.scale") { value in value >= 0.5 && value <= 2 }
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(self.source, forKey: .source)
        try values.encode(self.maxPerPage, forKey: .maxPerPage)
        try values.encode(self.minScore, forKey: .minScore)
        try values.encodeIfPresent(self.fill, forKey: .fill)
        try values.encodeIfPresent(self.palette, forKey: .palette)
        try values.encodeIfPresent(self.fontFile, forKey: .fontFile)
        try values.encode(self.scale, forKey: .scale)
    }

}

/// Caption schema enum; captions §2.
public enum CaptionEmphasisSource: String, Codable, Sendable, Hashable, CaseIterable {
    case `none`
    case rule
    case manual
    case llm
}

/// Caption style value and schema defaults; captions §2, shared/caption-styles/schema.json.
public struct CaptionEmoji: Codable, Sendable, Equatable {
    /// Caption schema enabled.
    public var enabled: Bool
    /// Manual picks always apply; v1 apps treat 'llm' as 'rule'.
    public var source: CaptionEmojiSource
    /// Caption schema placement.
    public var placement: String
    /// Caption schema sizeEm.
    public var sizeEm: Double
    /// Caption schema gapEm.
    public var gapEm: Double
    /// Caption schema maxPerPage.
    public var maxPerPage: Int

    /// Creates an explicit value without I/O or generated identifiers.
    public init(enabled: Bool = false, source: CaptionEmojiSource = .rule, placement: String = "above-page", sizeEm: Double = 1.2, gapEm: Double = 0.15, maxPerPage: Int = 1) {
        self.enabled = enabled
        self.source = source
        self.placement = placement
        self.sizeEm = sizeEm
        self.gapEm = gapEm
        self.maxPerPage = maxPerPage
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case enabled
        case source
        case placement
        case sizeEm
        case gapEm
        case maxPerPage
    }

    public init(from decoder: any Decoder) throws {
        try CaptionDecoding.keys(decoder, allowed: CodingKeys.allCases.map(\.rawValue))
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try CaptionDecoding.nonNull(values, .enabled, decoder)
        self.enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        try CaptionDecoding.nonNull(values, .source, decoder)
        self.source = try values.decodeIfPresent(CaptionEmojiSource.self, forKey: .source) ?? .rule
        try CaptionDecoding.nonNull(values, .placement, decoder)
        self.placement = try values.decodeIfPresent(String.self, forKey: .placement) ?? "above-page"
        try CaptionDecoding.check(self.placement, decoder: decoder, message: "Invalid CaptionEmoji.placement") { value in value == "above-page" }
        try CaptionDecoding.nonNull(values, .sizeEm, decoder)
        self.sizeEm = try values.decodeIfPresent(Double.self, forKey: .sizeEm) ?? 1.2
        try CaptionDecoding.check(self.sizeEm, decoder: decoder, message: "Invalid CaptionEmoji.sizeEm") { value in value >= 0.5 && value <= 3 }
        try CaptionDecoding.nonNull(values, .gapEm, decoder)
        self.gapEm = try values.decodeIfPresent(Double.self, forKey: .gapEm) ?? 0.15
        try CaptionDecoding.check(self.gapEm, decoder: decoder, message: "Invalid CaptionEmoji.gapEm") { value in value >= 0 && value <= 1 }
        try CaptionDecoding.nonNull(values, .maxPerPage, decoder)
        self.maxPerPage = try values.decodeIfPresent(Int.self, forKey: .maxPerPage) ?? 1
        try CaptionDecoding.check(self.maxPerPage, decoder: decoder, message: "Invalid CaptionEmoji.maxPerPage") { value in value >= 0 && value <= 1 }
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(self.enabled, forKey: .enabled)
        try values.encode(self.source, forKey: .source)
        try values.encode(self.placement, forKey: .placement)
        try values.encode(self.sizeEm, forKey: .sizeEm)
        try values.encode(self.gapEm, forKey: .gapEm)
        try values.encode(self.maxPerPage, forKey: .maxPerPage)
    }

}

/// Caption schema enum; captions §2.
public enum CaptionEmojiSource: String, Codable, Sendable, Hashable, CaseIterable {
    case rule
    case manual
    case llm
}

/// Caption style value and schema defaults; captions §2, shared/caption-styles/schema.json.
public struct CaptionEffects: Codable, Sendable, Equatable {
    /// Caption schema rgbSplit.
    public var rgbSplit: CaptionEffectsRgbSplit?
    /// Caption schema jitter.
    public var jitter: CaptionEffectsJitter?

    /// Creates an explicit value without I/O or generated identifiers.
    public init(rgbSplit: CaptionEffectsRgbSplit? = nil, jitter: CaptionEffectsJitter? = nil) {
        self.rgbSplit = rgbSplit
        self.jitter = jitter
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case rgbSplit
        case jitter
    }

    public init(from decoder: any Decoder) throws {
        try CaptionDecoding.keys(decoder, allowed: CodingKeys.allCases.map(\.rawValue))
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try CaptionDecoding.nonNull(values, .rgbSplit, decoder)
        self.rgbSplit = try values.decodeIfPresent(CaptionEffectsRgbSplit.self, forKey: .rgbSplit) ?? nil
        try CaptionDecoding.nonNull(values, .jitter, decoder)
        self.jitter = try values.decodeIfPresent(CaptionEffectsJitter.self, forKey: .jitter) ?? nil
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeIfPresent(self.rgbSplit, forKey: .rgbSplit)
        try values.encodeIfPresent(self.jitter, forKey: .jitter)
    }

}

/// Caption style value and schema defaults; captions §2, shared/caption-styles/schema.json.
public struct CaptionEffectsRgbSplit: Codable, Sendable, Equatable {
    /// Caption schema offsetEm.
    public var offsetEm: Double
    /// sRGB, gamma-encoded, straight alpha: #RRGGBB or #RRGGBBAA. '$accent' is the style accent (opaque); '$accent/AA' is the accent with alpha byte AA.
    public var leftColor: String
    /// sRGB, gamma-encoded, straight alpha: #RRGGBB or #RRGGBBAA. '$accent' is the style accent (opaque); '$accent/AA' is the accent with alpha byte AA.
    public var rightColor: String

    /// Creates an explicit value without I/O or generated identifiers.
    public init(offsetEm: Double, leftColor: String, rightColor: String) {
        self.offsetEm = offsetEm
        self.leftColor = leftColor
        self.rightColor = rightColor
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case offsetEm
        case leftColor
        case rightColor
    }

    public init(from decoder: any Decoder) throws {
        try CaptionDecoding.keys(decoder, allowed: CodingKeys.allCases.map(\.rawValue))
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.offsetEm = try values.decode(Double.self, forKey: .offsetEm)
        try CaptionDecoding.check(self.offsetEm, decoder: decoder, message: "Invalid CaptionEffectsRgbSplit.offsetEm") { value in value >= 0 && value <= 0.2 }
        self.leftColor = try values.decode(String.self, forKey: .leftColor)
        try CaptionDecoding.check(self.leftColor, decoder: decoder, message: "Invalid CaptionEffectsRgbSplit.leftColor") { value in value.range(of: "^(#[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?|\\$accent(/[0-9A-Fa-f]{2})?)$", options: .regularExpression) != nil }
        self.rightColor = try values.decode(String.self, forKey: .rightColor)
        try CaptionDecoding.check(self.rightColor, decoder: decoder, message: "Invalid CaptionEffectsRgbSplit.rightColor") { value in value.range(of: "^(#[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?|\\$accent(/[0-9A-Fa-f]{2})?)$", options: .regularExpression) != nil }
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(self.offsetEm, forKey: .offsetEm)
        try values.encode(self.leftColor, forKey: .leftColor)
        try values.encode(self.rightColor, forKey: .rightColor)
    }

}

/// Caption style value and schema defaults; captions §2, shared/caption-styles/schema.json.
public struct CaptionEffectsJitter: Codable, Sendable, Equatable {
    /// Caption schema amplitudeEm.
    public var amplitudeEm: Double
    /// Caption schema rateHz.
    public var rateHz: Double
    /// Caption schema seed.
    public var seed: Int

    /// Creates an explicit value without I/O or generated identifiers.
    public init(amplitudeEm: Double, rateHz: Double, seed: Int) {
        self.amplitudeEm = amplitudeEm
        self.rateHz = rateHz
        self.seed = seed
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case amplitudeEm
        case rateHz
        case seed
    }

    public init(from decoder: any Decoder) throws {
        try CaptionDecoding.keys(decoder, allowed: CodingKeys.allCases.map(\.rawValue))
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.amplitudeEm = try values.decode(Double.self, forKey: .amplitudeEm)
        try CaptionDecoding.check(self.amplitudeEm, decoder: decoder, message: "Invalid CaptionEffectsJitter.amplitudeEm") { value in value >= 0 && value <= 0.1 }
        self.rateHz = try values.decode(Double.self, forKey: .rateHz)
        try CaptionDecoding.check(self.rateHz, decoder: decoder, message: "Invalid CaptionEffectsJitter.rateHz") { value in value >= 1 && value <= 60 }
        self.seed = try values.decode(Int.self, forKey: .seed)
        try CaptionDecoding.check(self.seed, decoder: decoder, message: "Invalid CaptionEffectsJitter.seed") { value in value >= 0 && value <= 4294967295 }
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(self.amplitudeEm, forKey: .amplitudeEm)
        try values.encode(self.rateHz, forKey: .rateHz)
        try values.encode(self.seed, forKey: .seed)
    }

}

/// Caption style value and schema defaults; captions §2, shared/caption-styles/schema.json.
public struct CaptionPreview: Codable, Sendable, Equatable {
    /// Sample words (space separated) used when no transcript phrase is available.
    public var text: String
    /// Caption schema activeWord.
    public var activeWord: Int
    /// Caption schema progress.
    public var progress: Double?
    /// Caption schema background.
    public var background: String?

    /// Creates an explicit value without I/O or generated identifiers.
    public init(text: String, activeWord: Int = 0, progress: Double? = nil, background: String? = nil) {
        self.text = text
        self.activeWord = activeWord
        self.progress = progress ?? 1
        self.background = background ?? "#3A3C45"
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case text
        case activeWord
        case progress
        case background
    }

    public init(from decoder: any Decoder) throws {
        try CaptionDecoding.keys(decoder, allowed: CodingKeys.allCases.map(\.rawValue))
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.text = try values.decode(String.self, forKey: .text)
        try CaptionDecoding.check(self.text, decoder: decoder, message: "Invalid CaptionPreview.text") { value in value.unicodeScalars.count >= 1 && value.unicodeScalars.count <= 60 }
        try CaptionDecoding.nonNull(values, .activeWord, decoder)
        self.activeWord = try values.decodeIfPresent(Int.self, forKey: .activeWord) ?? 0
        try CaptionDecoding.check(self.activeWord, decoder: decoder, message: "Invalid CaptionPreview.activeWord") { value in value >= 0 && value <= 15 }
        try CaptionDecoding.nonNull(values, .progress, decoder)
        self.progress = try values.decodeIfPresent(Double.self, forKey: .progress) ?? 1
        try CaptionDecoding.check(self.progress, decoder: decoder, message: "Invalid CaptionPreview.progress") { value in value >= 0 && value <= 1 }
        try CaptionDecoding.nonNull(values, .background, decoder)
        self.background = try values.decodeIfPresent(String.self, forKey: .background) ?? "#3A3C45"
        try CaptionDecoding.check(self.background, decoder: decoder, message: "Invalid CaptionPreview.background") { value in value.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) != nil }
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(self.text, forKey: .text)
        try values.encode(self.activeWord, forKey: .activeWord)
        try values.encodeIfPresent(self.progress, forKey: .progress)
        try values.encodeIfPresent(self.background, forKey: .background)
    }

}

/// Tagged solid/linear paint; captions §2.3 and schema $defs/paint.
public enum CaptionPaint: Codable, Sendable, Equatable {
    case solid(color: String)
    case linear(angleDeg: Double, space: CaptionPaintSpace, stops: [CaptionPaintStop])
    private enum CodingKeys: String, CodingKey, CaseIterable { case type, color, angleDeg, space, stops }
    public init(from decoder: any Decoder) throws {
        try CaptionDecoding.keys(decoder, allowed: CodingKeys.allCases.map(\.rawValue))
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let type = try values.decode(String.self, forKey: .type)
        try CaptionDecoding.keys(decoder, allowed: type == "solid" ? ["type", "color"] : ["type", "angleDeg", "space", "stops"])
        if type == "solid" {
            let color = try values.decode(String.self, forKey: .color)
            guard color.range(of: "^(#[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?|\\$accent(/[0-9A-Fa-f]{2})?)$", options: .regularExpression) != nil else { throw CaptionFailure.invalid("Paint colour") }
        } else if type == "linear" {
            let angle = try values.decode(Double.self, forKey: .angleDeg)
            let stops = try values.decode([CaptionPaintStop].self, forKey: .stops)
            guard (-360...360).contains(angle), (2...5).contains(stops.count), zip(stops, stops.dropFirst()).allSatisfy({ $0.offset <= $1.offset }) else { throw CaptionFailure.invalid("Gradient stops") }
            try CaptionDecoding.nonNull(values, .space, decoder)
        }
        switch type {
        case "solid": self = .solid(color: try values.decode(String.self, forKey: .color))
        case "linear": self = .linear(angleDeg: try values.decode(Double.self, forKey: .angleDeg), space: try values.decodeIfPresent(CaptionPaintSpace.self, forKey: .space) ?? .line, stops: try values.decode([CaptionPaintStop].self, forKey: .stops))
        default: throw DecodingError.dataCorruptedError(forKey: .type, in: values, debugDescription: "Unknown caption paint")
        }
    }
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .solid(let color): try values.encode("solid", forKey: .type); try values.encode(color, forKey: .color)
        case .linear(let angle, let space, let stops):
            try values.encode("linear", forKey: .type); try values.encode(angle, forKey: .angleDeg)
            try values.encode(space, forKey: .space); try values.encode(stops, forKey: .stops)
        }
    }
}
/// Gradient coordinate space; captions §10.4.
public enum CaptionPaintSpace: String, Codable, Sendable, Hashable, CaseIterable {
    case word
    case line
    case page
}
/// Opaque gradient stop; captions §10.4.
public struct CaptionPaintStop: Codable, Sendable, Equatable {
    /// offset; Opaque gradient stop; captions §10.4.
    public var offset: Double
    /// color; Opaque gradient stop; captions §10.4.
    public var color: String

    /// Creates an explicit value without I/O or generated identifiers.
    public init(offset: Double, color: String) {
        self.offset = offset
        self.color = color
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case offset
        case color
    }

    public init(from decoder: any Decoder) throws {
        try CaptionDecoding.keys(decoder, allowed: CodingKeys.allCases.map(\.rawValue))
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.offset = try values.decode(Double.self, forKey: .offset)
        try CaptionDecoding.check(self.offset, decoder: decoder, message: "Invalid CaptionPaintStop.offset") { value in value >= 0 && value <= 1 }
        self.color = try values.decode(String.self, forKey: .color)
        try CaptionDecoding.check(self.color, decoder: decoder, message: "Invalid CaptionPaintStop.color") { value in value.range(of: "^(#[0-9A-Fa-f]{6}([Ff]{2})?|\\$accent)$", options: .regularExpression) != nil }
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(self.offset, forKey: .offset)
        try values.encode(self.color, forKey: .color)
    }

}
