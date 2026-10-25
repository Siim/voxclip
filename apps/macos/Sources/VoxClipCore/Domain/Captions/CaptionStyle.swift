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

    private enum CodingKeys: String, CodingKey {
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
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaURL = try values.decodeIfPresent(String.self, forKey: .schemaURL) ?? nil
        self.schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        self.id = try values.decode(String.self, forKey: .id)
        self.name = try values.decode(String.self, forKey: .name)
        self.description = try values.decode(String.self, forKey: .description)
        self.order = try values.decodeIfPresent(Int.self, forKey: .order) ?? 500
        self.tags = try values.decodeIfPresent([String].self, forKey: .tags) ?? []
        self.accent = try values.decodeIfPresent(String.self, forKey: .accent) ?? nil
        self.font = try values.decode(CaptionFont.self, forKey: .font)
        self.text = try values.decode(CaptionText.self, forKey: .text)
        self.layout = try values.decode(CaptionLayout.self, forKey: .layout)
        self.position = try values.decode(CaptionStylePosition.self, forKey: .position)
        self.aspects = try values.decodeIfPresent(CaptionAspects.self, forKey: .aspects) ?? nil
        self.fill = try values.decode(CaptionPaint.self, forKey: .fill)
        self.stroke = try values.decodeIfPresent(CaptionStroke.self, forKey: .stroke) ?? nil
        self.shadows = try values.decodeIfPresent([CaptionShadow].self, forKey: .shadows) ?? []
        self.box = try values.decodeIfPresent(CaptionBox.self, forKey: .box) ?? nil
        self.words = try values.decodeIfPresent(CaptionWordStates.self, forKey: .words) ?? nil
        self.reveal = try values.decodeIfPresent(CaptionReveal.self, forKey: .reveal) ?? nil
        self.animation = try values.decodeIfPresent(CaptionAnimation.self, forKey: .animation) ?? nil
        self.emphasis = try values.decodeIfPresent(CaptionEmphasis.self, forKey: .emphasis) ?? nil
        self.emoji = try values.decodeIfPresent(CaptionEmoji.self, forKey: .emoji) ?? nil
        self.effects = try values.decodeIfPresent(CaptionEffects.self, forKey: .effects) ?? nil
        self.preview = try values.decode(CaptionPreview.self, forKey: .preview)
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

    private enum CodingKeys: String, CodingKey {
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
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.file = try values.decode(String.self, forKey: .file)
        self.family = try values.decode(String.self, forKey: .family)
        self.weight = try values.decode(Int.self, forKey: .weight)
        self.italic = try values.decodeIfPresent(Bool.self, forKey: .italic) ?? false
        self.sizeSh = try values.decode(Double.self, forKey: .sizeSh)
        self.sizeRef = try values.decodeIfPresent(CaptionFontSizeRef.self, forKey: .sizeRef) ?? .shortEdge
        self.sizeScale = try values.decodeIfPresent(Double.self, forKey: .sizeScale) ?? 1
        self.letterSpacingEm = try values.decodeIfPresent(Double.self, forKey: .letterSpacingEm) ?? 0
        self.wordSpacingEm = try values.decodeIfPresent(Double.self, forKey: .wordSpacingEm) ?? nil
        self.lineHeightEm = try values.decodeIfPresent(Double.self, forKey: .lineHeightEm) ?? 1.2
        self.features = try values.decodeIfPresent(CaptionFontFeatures.self, forKey: .features) ?? CaptionFontFeatures()
        self.fallbackFiles = try values.decodeIfPresent([String].self, forKey: .fallbackFiles) ?? []
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

    private enum CodingKeys: String, CodingKey {
        case kern
        case liga
        case calt
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.kern = try values.decodeIfPresent(Bool.self, forKey: .kern) ?? true
        self.liga = try values.decodeIfPresent(Bool.self, forKey: .liga) ?? true
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

    private enum CodingKeys: String, CodingKey {
        case transform
        case punctuation
        case userOverridable
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.transform = try values.decodeIfPresent(CaptionTextTransform.self, forKey: .transform) ?? .none
        self.punctuation = try values.decodeIfPresent(CaptionTextPunctuation.self, forKey: .punctuation) ?? .keep
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

    private enum CodingKeys: String, CodingKey {
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
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.maxWords = try values.decode(Int.self, forKey: .maxWords)
        self.maxLines = try values.decode(Int.self, forKey: .maxLines)
        self.maxLineWidthW = try values.decode(Double.self, forKey: .maxLineWidthW)
        self.balance = try values.decodeIfPresent(CaptionLayoutBalance.self, forKey: .balance) ?? .balanced
        self.minShrink = try values.decodeIfPresent(Double.self, forKey: .minShrink) ?? 0.5
        self.breakOnSentence = try values.decodeIfPresent(Bool.self, forKey: .breakOnSentence) ?? true
        self.breakOnComma = try values.decodeIfPresent(Bool.self, forKey: .breakOnComma) ?? false
        self.breakOnGapSec = values.contains(.breakOnGapSec) ? try values.decodeIfPresent(Double.self, forKey: .breakOnGapSec) : 0.6
        self.maxPageSec = try values.decodeIfPresent(Double.self, forKey: .maxPageSec) ?? nil
        self.holdGapSec = try values.decodeIfPresent(Double.self, forKey: .holdGapSec) ?? 0.5
        self.minPageSec = try values.decodeIfPresent(Double.self, forKey: .minPageSec) ?? 0.3
        self.align = try values.decodeIfPresent(CaptionLayoutAlign.self, forKey: .align) ?? .center
        self.lineGapEm = try values.decodeIfPresent(Double.self, forKey: .lineGapEm) ?? 0
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

    private enum CodingKeys: String, CodingKey {
        case x
        case y
        case anchorX
        case anchorY
        case userDraggable
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.x = try values.decode(Double.self, forKey: .x)
        self.y = try values.decode(Double.self, forKey: .y)
        self.anchorX = try values.decodeIfPresent(CaptionStylePositionAnchorX.self, forKey: .anchorX) ?? .center
        self.anchorY = try values.decodeIfPresent(CaptionStylePositionAnchorY.self, forKey: .anchorY) ?? .center
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

    private enum CodingKeys: String, CodingKey {
        case portrait
        case square
        case landscape
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.portrait = try values.decodeIfPresent(CaptionAspectOverride.self, forKey: .portrait) ?? nil
        self.square = try values.decodeIfPresent(CaptionAspectOverride.self, forKey: .square) ?? nil
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

    private enum CodingKeys: String, CodingKey {
        case sizeSh
        case x
        case y
        case maxLineWidthW
        case maxWords
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.sizeSh = try values.decodeIfPresent(Double.self, forKey: .sizeSh) ?? nil
        self.x = try values.decodeIfPresent(Double.self, forKey: .x) ?? nil
        self.y = try values.decodeIfPresent(Double.self, forKey: .y) ?? nil
        self.maxLineWidthW = try values.decodeIfPresent(Double.self, forKey: .maxLineWidthW) ?? nil
        self.maxWords = try values.decodeIfPresent(Int.self, forKey: .maxWords) ?? nil
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

    private enum CodingKeys: String, CodingKey {
        case widthEm
        case color
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.widthEm = try values.decode(Double.self, forKey: .widthEm)
        self.color = try values.decode(String.self, forKey: .color)
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

    private enum CodingKeys: String, CodingKey {
        case dxEm
        case dyEm
        case sigmaEm
        case color
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.dxEm = try values.decode(Double.self, forKey: .dxEm)
        self.dyEm = try values.decode(Double.self, forKey: .dyEm)
        self.sigmaEm = try values.decode(Double.self, forKey: .sigmaEm)
        self.color = try values.decode(String.self, forKey: .color)
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

    private enum CodingKeys: String, CodingKey {
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
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.scope = try values.decode(CaptionBoxScope.self, forKey: .scope)
        self.color = try values.decode(String.self, forKey: .color)
        self.paddingXEm = try values.decodeIfPresent(Double.self, forKey: .paddingXEm) ?? 0.4
        self.paddingYEm = try values.decodeIfPresent(Double.self, forKey: .paddingYEm) ?? 0.15
        self.radiusEm = try values.decodeIfPresent(Double.self, forKey: .radiusEm) ?? 0.2
        self.pill = try values.decodeIfPresent(Bool.self, forKey: .pill) ?? false
        self.borderWidthEm = try values.decodeIfPresent(Double.self, forKey: .borderWidthEm) ?? 0
        self.borderColor = try values.decodeIfPresent(String.self, forKey: .borderColor) ?? nil
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

    private enum CodingKeys: String, CodingKey {
        case past
        case active
        case future
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.past = try values.decodeIfPresent(CaptionWordState.self, forKey: .past) ?? nil
        self.active = try values.decodeIfPresent(CaptionWordState.self, forKey: .active) ?? nil
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

    private enum CodingKeys: String, CodingKey {
        case fill
        case opacity
        case scale
        case strokeColor
        case hideStroke
        case box
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.fill = try values.decodeIfPresent(CaptionPaint.self, forKey: .fill) ?? nil
        self.opacity = try values.decodeIfPresent(Double.self, forKey: .opacity) ?? nil
        self.scale = try values.decodeIfPresent(Double.self, forKey: .scale) ?? nil
        self.strokeColor = try values.decodeIfPresent(String.self, forKey: .strokeColor) ?? nil
        self.hideStroke = try values.decodeIfPresent(Bool.self, forKey: .hideStroke) ?? nil
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

    private enum CodingKeys: String, CodingKey {
        case color
        case paddingXEm
        case paddingYEm
        case radiusEm
        case pill
        case borderWidthEm
        case borderColor
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.color = try values.decode(String.self, forKey: .color)
        self.paddingXEm = try values.decodeIfPresent(Double.self, forKey: .paddingXEm) ?? 0.4
        self.paddingYEm = try values.decodeIfPresent(Double.self, forKey: .paddingYEm) ?? 0.15
        self.radiusEm = try values.decodeIfPresent(Double.self, forKey: .radiusEm) ?? 0.2
        self.pill = try values.decodeIfPresent(Bool.self, forKey: .pill) ?? false
        self.borderWidthEm = try values.decodeIfPresent(Double.self, forKey: .borderWidthEm) ?? 0
        self.borderColor = try values.decodeIfPresent(String.self, forKey: .borderColor) ?? nil
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

    private enum CodingKeys: String, CodingKey {
        case unit
        case maxCharsPerSec
        case cursor
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.unit = try values.decodeIfPresent(CaptionRevealUnit.self, forKey: .unit) ?? .page
        self.maxCharsPerSec = try values.decodeIfPresent(Double.self, forKey: .maxCharsPerSec) ?? 30
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

    private enum CodingKeys: String, CodingKey {
        case widthEm
        case color
        case blinkHz
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.widthEm = try values.decode(Double.self, forKey: .widthEm)
        self.color = try values.decode(String.self, forKey: .color)
        self.blinkHz = try values.decodeIfPresent(Double.self, forKey: .blinkHz) ?? 2
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

    private enum CodingKeys: String, CodingKey {
        case pageIn
        case pageOut
        case wordIn
        case activeIn
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.pageIn = try values.decodeIfPresent(CaptionAnim.self, forKey: .pageIn) ?? nil
        self.pageOut = try values.decodeIfPresent(CaptionAnim.self, forKey: .pageOut) ?? nil
        self.wordIn = try values.decodeIfPresent(CaptionAnim.self, forKey: .wordIn) ?? nil
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

    private enum CodingKeys: String, CodingKey {
        case type
        case durationSec
        case easing
        case fromScale
        case fromOffsetEm
        case overshoot
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try values.decode(CaptionAnimType.self, forKey: .type)
        self.durationSec = try values.decode(Double.self, forKey: .durationSec)
        self.easing = try values.decodeIfPresent(CaptionAnimEasing.self, forKey: .easing) ?? .easeOutCubic
        self.fromScale = try values.decodeIfPresent(Double.self, forKey: .fromScale) ?? 0.8
        self.fromOffsetEm = try values.decodeIfPresent(Double.self, forKey: .fromOffsetEm) ?? 0.4
        self.overshoot = try values.decodeIfPresent(Double.self, forKey: .overshoot) ?? 1.70158
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

    private enum CodingKeys: String, CodingKey {
        case source
        case maxPerPage
        case minScore
        case fill
        case palette
        case fontFile
        case scale
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.source = try values.decodeIfPresent(CaptionEmphasisSource.self, forKey: .source) ?? .none
        self.maxPerPage = try values.decodeIfPresent(Int.self, forKey: .maxPerPage) ?? 1
        self.minScore = try values.decodeIfPresent(Double.self, forKey: .minScore) ?? 0
        self.fill = try values.decodeIfPresent(CaptionPaint.self, forKey: .fill) ?? nil
        self.palette = try values.decodeIfPresent([String].self, forKey: .palette) ?? nil
        self.fontFile = try values.decodeIfPresent(String.self, forKey: .fontFile) ?? nil
        self.scale = try values.decodeIfPresent(Double.self, forKey: .scale) ?? 1
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

    private enum CodingKeys: String, CodingKey {
        case enabled
        case source
        case placement
        case sizeEm
        case gapEm
        case maxPerPage
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        self.source = try values.decodeIfPresent(CaptionEmojiSource.self, forKey: .source) ?? .rule
        self.placement = try values.decodeIfPresent(String.self, forKey: .placement) ?? "above-page"
        self.sizeEm = try values.decodeIfPresent(Double.self, forKey: .sizeEm) ?? 1.2
        self.gapEm = try values.decodeIfPresent(Double.self, forKey: .gapEm) ?? 0.15
        self.maxPerPage = try values.decodeIfPresent(Int.self, forKey: .maxPerPage) ?? 1
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

    private enum CodingKeys: String, CodingKey {
        case rgbSplit
        case jitter
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.rgbSplit = try values.decodeIfPresent(CaptionEffectsRgbSplit.self, forKey: .rgbSplit) ?? nil
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

    private enum CodingKeys: String, CodingKey {
        case offsetEm
        case leftColor
        case rightColor
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.offsetEm = try values.decode(Double.self, forKey: .offsetEm)
        self.leftColor = try values.decode(String.self, forKey: .leftColor)
        self.rightColor = try values.decode(String.self, forKey: .rightColor)
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

    private enum CodingKeys: String, CodingKey {
        case amplitudeEm
        case rateHz
        case seed
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.amplitudeEm = try values.decode(Double.self, forKey: .amplitudeEm)
        self.rateHz = try values.decode(Double.self, forKey: .rateHz)
        self.seed = try values.decode(Int.self, forKey: .seed)
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
        self.progress = progress
        self.background = background
    }

    private enum CodingKeys: String, CodingKey {
        case text
        case activeWord
        case progress
        case background
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.text = try values.decode(String.self, forKey: .text)
        self.activeWord = try values.decodeIfPresent(Int.self, forKey: .activeWord) ?? 0
        self.progress = try values.decodeIfPresent(Double.self, forKey: .progress) ?? nil
        self.background = try values.decodeIfPresent(String.self, forKey: .background) ?? nil
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
    private enum CodingKeys: String, CodingKey { case type, color, angleDeg, space, stops }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let type = try values.decode(String.self, forKey: .type)
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

    private enum CodingKeys: String, CodingKey {
        case offset
        case color
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.offset = try values.decode(Double.self, forKey: .offset)
        self.color = try values.decode(String.self, forKey: .color)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(self.offset, forKey: .offset)
        try values.encode(self.color, forKey: .color)
    }

}
