import Foundation

/// Captioned word on the edited timeline; editing §2.8.
public struct CaptionWord: Codable, Sendable, Equatable {
    /// id; Captioned word on the edited timeline; editing §2.8.
    public var id: String
    /// text; Captioned word on the edited timeline; editing §2.8.
    public var text: String
    /// start; Captioned word on the edited timeline; editing §2.8.
    public var start: Double
    /// end; Captioned word on the edited timeline; editing §2.8.
    public var end: Double

    /// Creates an explicit value without I/O or generated identifiers.
    public init(id: String, text: String, start: Double, end: Double) {
        self.id = id
        self.text = text
        self.start = start
        self.end = end
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case text
        case start
        case end
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try values.decode(String.self, forKey: .id)
        self.text = try values.decode(String.self, forKey: .text)
        self.start = try values.decode(Double.self, forKey: .start)
        self.end = try values.decode(Double.self, forKey: .end)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(self.id, forKey: .id)
        try values.encode(self.text, forKey: .text)
        try values.encode(self.start, forKey: .start)
        try values.encode(self.end, forKey: .end)
    }

}

/// Framework-free top-left geometry; captions §7.
public struct CaptionRect: Codable, Sendable, Equatable {
    /// x; Framework-free top-left geometry; captions §7.
    public var x: Double
    /// y; Framework-free top-left geometry; captions §7.
    public var y: Double
    /// width; Framework-free top-left geometry; captions §7.
    public var width: Double
    /// height; Framework-free top-left geometry; captions §7.
    public var height: Double

    /// Creates an explicit value without I/O or generated identifiers.
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    private enum CodingKeys: String, CodingKey {
        case x
        case y
        case width
        case height
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.x = try values.decode(Double.self, forKey: .x)
        self.y = try values.decode(Double.self, forKey: .y)
        self.width = try values.decode(Double.self, forKey: .width)
        self.height = try values.decode(Double.self, forKey: .height)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(self.x, forKey: .x)
        try values.encode(self.y, forKey: .y)
        try values.encode(self.width, forKey: .width)
        try values.encode(self.height, forKey: .height)
    }

}

/// Framework-free point; captions §7.
public struct CaptionPoint: Codable, Sendable, Equatable {
    /// x; Framework-free point; captions §7.
    public var x: Double
    /// y; Framework-free point; captions §7.
    public var y: Double

    /// Creates an explicit value without I/O or generated identifiers.
    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    private enum CodingKeys: String, CodingKey {
        case x
        case y
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.x = try values.decode(Double.self, forKey: .x)
        self.y = try values.decode(Double.self, forKey: .y)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(self.x, forKey: .x)
        try values.encode(self.y, forKey: .y)
    }

}

/// Integer primary-font units and grapheme cluster index; captions §4.3.
public struct ShapedGlyph: Codable, Sendable, Equatable {
    /// id; Integer primary-font units and grapheme cluster index; captions §4.3.
    public var id: UInt32
    /// advance; Integer primary-font units and grapheme cluster index; captions §4.3.
    public var advance: Int
    /// offsetX; Integer primary-font units and grapheme cluster index; captions §4.3.
    public var offsetX: Int
    /// offsetY; Integer primary-font units and grapheme cluster index; captions §4.3.
    public var offsetY: Int
    /// cluster; Integer primary-font units and grapheme cluster index; captions §4.3.
    public var cluster: Int

    /// Creates an explicit value without I/O or generated identifiers.
    public init(id: UInt32, advance: Int, offsetX: Int = 0, offsetY: Int = 0, cluster: Int) {
        self.id = id
        self.advance = advance
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.cluster = cluster
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case advance
        case offsetX
        case offsetY
        case cluster
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try values.decode(UInt32.self, forKey: .id)
        self.advance = try values.decode(Int.self, forKey: .advance)
        self.offsetX = try values.decodeIfPresent(Int.self, forKey: .offsetX) ?? 0
        self.offsetY = try values.decodeIfPresent(Int.self, forKey: .offsetY) ?? 0
        self.cluster = try values.decode(Int.self, forKey: .cluster)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(self.id, forKey: .id)
        try values.encode(self.advance, forKey: .advance)
        try values.encode(self.offsetX, forKey: .offsetX)
        try values.encode(self.offsetY, forKey: .offsetY)
        try values.encode(self.cluster, forKey: .cluster)
    }

}

/// Single-font shaping result; captions §4.3–4.4.
public struct ShapedRun: Codable, Sendable, Equatable {
    /// file; Single-font shaping result; captions §4.3–4.4.
    public var file: String
    /// text; Single-font shaping result; captions §4.3–4.4.
    public var text: String
    /// unitsPerEm; Single-font shaping result; captions §4.3–4.4.
    public var unitsPerEm: Int
    /// units; Single-font shaping result; captions §4.3–4.4.
    public var units: Int
    /// glyphs; Single-font shaping result; captions §4.3–4.4.
    public var glyphs: [ShapedGlyph]

    /// Creates an explicit value without I/O or generated identifiers.
    public init(file: String, text: String, unitsPerEm: Int, units: Int, glyphs: [ShapedGlyph]) {
        self.file = file
        self.text = text
        self.unitsPerEm = unitsPerEm
        self.units = units
        self.glyphs = glyphs
    }

    private enum CodingKeys: String, CodingKey {
        case file
        case text
        case unitsPerEm
        case units
        case glyphs
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.file = try values.decode(String.self, forKey: .file)
        self.text = try values.decode(String.self, forKey: .text)
        self.unitsPerEm = try values.decode(Int.self, forKey: .unitsPerEm)
        self.units = try values.decode(Int.self, forKey: .units)
        self.glyphs = try values.decode([ShapedGlyph].self, forKey: .glyphs)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(self.file, forKey: .file)
        try values.encode(self.text, forKey: .text)
        try values.encode(self.unitsPerEm, forKey: .unitsPerEm)
        try values.encode(self.units, forKey: .units)
        try values.encode(self.glyphs, forKey: .glyphs)
    }

}

/// Caption layout input with integer advances; captions §4–6.
public struct ShapedWord: Codable, Sendable, Equatable {
    /// word; Caption layout input with integer advances; captions §4–6.
    public var word: CaptionWord
    /// runs; Caption layout input with integer advances; captions §4–6.
    public var runs: [ShapedRun]
    /// units; Caption layout input with integer advances; captions §4–6.
    public var units: Int
    /// clusters; Caption layout input with integer advances; captions §4–6.
    public var clusters: Int
    /// droppedClusters; Caption layout input with integer advances; captions §4–6.
    public var droppedClusters: [String]

    /// Creates an explicit value without I/O or generated identifiers.
    public init(word: CaptionWord, runs: [ShapedRun], units: Int, clusters: Int, droppedClusters: [String] = []) {
        self.word = word
        self.runs = runs
        self.units = units
        self.clusters = clusters
        self.droppedClusters = droppedClusters
    }

    private enum CodingKeys: String, CodingKey {
        case word
        case runs
        case units
        case clusters
        case droppedClusters
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.word = try values.decode(CaptionWord.self, forKey: .word)
        self.runs = try values.decode([ShapedRun].self, forKey: .runs)
        self.units = try values.decode(Int.self, forKey: .units)
        self.clusters = try values.decode(Int.self, forKey: .clusters)
        self.droppedClusters = try values.decodeIfPresent([String].self, forKey: .droppedClusters) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(self.word, forKey: .word)
        try values.encode(self.runs, forKey: .runs)
        try values.encode(self.units, forKey: .units)
        try values.encode(self.clusters, forKey: .clusters)
        try values.encode(self.droppedClusters, forKey: .droppedClusters)
    }

}

/// Per-word shaper request, no implicit system fallback; captions §4.3–4.4.
public struct GlyphShapeRequest: Codable, Sendable, Equatable {
    /// text; Per-word shaper request, no implicit system fallback; captions §4.3–4.4.
    public var text: String
    /// fontFile; Per-word shaper request, no implicit system fallback; captions §4.3–4.4.
    public var fontFile: String
    /// fallbackFiles; Per-word shaper request, no implicit system fallback; captions §4.3–4.4.
    public var fallbackFiles: [String]
    /// language; Per-word shaper request, no implicit system fallback; captions §4.3–4.4.
    public var language: String?
    /// kern; Per-word shaper request, no implicit system fallback; captions §4.3–4.4.
    public var kern: Bool
    /// liga; Per-word shaper request, no implicit system fallback; captions §4.3–4.4.
    public var liga: Bool
    /// calt; Per-word shaper request, no implicit system fallback; captions §4.3–4.4.
    public var calt: Bool

    /// Creates an explicit value without I/O or generated identifiers.
    public init(text: String, fontFile: String, fallbackFiles: [String] = [], language: String? = nil, kern: Bool = true, liga: Bool = true, calt: Bool = true) {
        self.text = text
        self.fontFile = fontFile
        self.fallbackFiles = fallbackFiles
        self.language = language
        self.kern = kern
        self.liga = liga
        self.calt = calt
    }

    private enum CodingKeys: String, CodingKey {
        case text
        case fontFile
        case fallbackFiles
        case language
        case kern
        case liga
        case calt
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.text = try values.decode(String.self, forKey: .text)
        self.fontFile = try values.decode(String.self, forKey: .fontFile)
        self.fallbackFiles = try values.decodeIfPresent([String].self, forKey: .fallbackFiles) ?? []
        self.language = try values.decodeIfPresent(String.self, forKey: .language) ?? nil
        self.kern = try values.decodeIfPresent(Bool.self, forKey: .kern) ?? true
        self.liga = try values.decodeIfPresent(Bool.self, forKey: .liga) ?? true
        self.calt = try values.decodeIfPresent(Bool.self, forKey: .calt) ?? true
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(self.text, forKey: .text)
        try values.encode(self.fontFile, forKey: .fontFile)
        try values.encode(self.fallbackFiles, forKey: .fallbackFiles)
        try values.encode(self.language, forKey: .language)
        try values.encode(self.kern, forKey: .kern)
        try values.encode(self.liga, forKey: .liga)
        try values.encode(self.calt, forKey: .calt)
    }

}

/// Platform shaping seam; architecture §2.1 and captions §4.3. Implementations may load bundled fonts, never UI state.
public protocol GlyphShaper: Sendable {
    func shape(_ request: GlyphShapeRequest) async throws -> [ShapedRun]
}

/// Line layout output; captions §6.3 and §7.4.
public struct CaptionLine: Codable, Sendable, Equatable {
    /// words; Line layout output; captions §6.3 and §7.4.
    public var words: [Int]
    /// units; Line layout output; captions §6.3 and §7.4.
    public var units: Int
    /// rect; Line layout output; captions §6.3 and §7.4.
    public var rect: CaptionRect
    /// baseline; Line layout output; captions §6.3 and §7.4.
    public var baseline: Double

    /// Creates an explicit value without I/O or generated identifiers.
    public init(words: [Int], units: Int, rect: CaptionRect, baseline: Double) {
        self.words = words
        self.units = units
        self.rect = rect
        self.baseline = baseline
    }

    private enum CodingKeys: String, CodingKey {
        case words
        case units
        case rect
        case baseline
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.words = try values.decode([Int].self, forKey: .words)
        self.units = try values.decode(Int.self, forKey: .units)
        self.rect = try values.decode(CaptionRect.self, forKey: .rect)
        self.baseline = try values.decode(Double.self, forKey: .baseline)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(self.words, forKey: .words)
        try values.encode(self.units, forKey: .units)
        try values.encode(self.rect, forKey: .rect)
        try values.encode(self.baseline, forKey: .baseline)
    }

}

/// Page layout snapshot; captions §6–8.
public struct CaptionPage: Codable, Sendable, Equatable {
    /// index; Page layout snapshot; captions §6–8.
    public var index: Int
    /// words; Page layout snapshot; captions §6–8.
    public var words: [CaptionWord]
    /// start; Page layout snapshot; captions §6–8.
    public var start: Double
    /// end; Page layout snapshot; captions §6–8.
    public var end: Double
    /// fontPx; Page layout snapshot; captions §6–8.
    public var fontPx: Double
    /// lines; Page layout snapshot; captions §6–8.
    public var lines: [CaptionLine]
    /// wordRects; Page layout snapshot; captions §6–8.
    public var wordRects: [CaptionRect]
    /// block; Page layout snapshot; captions §6–8.
    public var block: CaptionRect
    /// visual; Page layout snapshot; captions §6–8.
    public var visual: CaptionRect

    /// Creates an explicit value without I/O or generated identifiers.
    public init(index: Int, words: [CaptionWord], start: Double, end: Double, fontPx: Double, lines: [CaptionLine] = [], wordRects: [CaptionRect] = [], block: CaptionRect, visual: CaptionRect) {
        self.index = index
        self.words = words
        self.start = start
        self.end = end
        self.fontPx = fontPx
        self.lines = lines
        self.wordRects = wordRects
        self.block = block
        self.visual = visual
    }

    private enum CodingKeys: String, CodingKey {
        case index
        case words
        case start
        case end
        case fontPx
        case lines
        case wordRects
        case block
        case visual
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.index = try values.decode(Int.self, forKey: .index)
        self.words = try values.decode([CaptionWord].self, forKey: .words)
        self.start = try values.decode(Double.self, forKey: .start)
        self.end = try values.decode(Double.self, forKey: .end)
        self.fontPx = try values.decode(Double.self, forKey: .fontPx)
        self.lines = try values.decodeIfPresent([CaptionLine].self, forKey: .lines) ?? []
        self.wordRects = try values.decodeIfPresent([CaptionRect].self, forKey: .wordRects) ?? []
        self.block = try values.decode(CaptionRect.self, forKey: .block)
        self.visual = try values.decode(CaptionRect.self, forKey: .visual)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(self.index, forKey: .index)
        try values.encode(self.words, forKey: .words)
        try values.encode(self.start, forKey: .start)
        try values.encode(self.end, forKey: .end)
        try values.encode(self.fontPx, forKey: .fontPx)
        try values.encode(self.lines, forKey: .lines)
        try values.encode(self.wordRects, forKey: .wordRects)
        try values.encode(self.block, forKey: .block)
        try values.encode(self.visual, forKey: .visual)
    }

}

/// Immutable edited caption snapshot; architecture §4.6.
public struct CaptionTrack: Codable, Sendable, Equatable {
    /// words; Immutable edited caption snapshot; architecture §4.6.
    public var words: [CaptionWord]
    /// pages; Immutable edited caption snapshot; architecture §4.6.
    public var pages: [CaptionPage]

    /// Creates an explicit value without I/O or generated identifiers.
    public init(words: [CaptionWord] = [], pages: [CaptionPage] = []) {
        self.words = words
        self.pages = pages
    }

    private enum CodingKeys: String, CodingKey {
        case words
        case pages
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.words = try values.decodeIfPresent([CaptionWord].self, forKey: .words) ?? []
        self.pages = try values.decodeIfPresent([CaptionPage].self, forKey: .pages) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(self.words, forKey: .words)
        try values.encode(self.pages, forKey: .pages)
    }

    public static func build(plan: EditPlan, transcript: Transcript, corrections: [String: String], style: CaptionStyle, transforms: CaptionTextOptions) throws -> CaptionTrack { throw VoxClipError.notImplemented("mac-captions") }
}

/// User text transform toggles; captions §3.1.
public struct CaptionTextOptions: Codable, Sendable, Equatable {
    /// uppercase; User text transform toggles; captions §3.1.
    public var uppercase: Bool
    /// removePunctuation; User text transform toggles; captions §3.1.
    public var removePunctuation: Bool

    /// Creates an explicit value without I/O or generated identifiers.
    public init(uppercase: Bool = false, removePunctuation: Bool = false) {
        self.uppercase = uppercase
        self.removePunctuation = removePunctuation
    }

    private enum CodingKeys: String, CodingKey {
        case uppercase
        case removePunctuation
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.uppercase = try values.decodeIfPresent(Bool.self, forKey: .uppercase) ?? false
        self.removePunctuation = try values.decodeIfPresent(Bool.self, forKey: .removePunctuation) ?? false
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(self.uppercase, forKey: .uppercase)
        try values.encode(self.removePunctuation, forKey: .removePunctuation)
    }

}

/// Shared render snapshot; captions §13, no CoreGraphics objects cross actors.
public struct CaptionRasterRequest: Codable, Sendable, Equatable {
    /// page; Shared render snapshot; captions §13, no CoreGraphics objects cross actors.
    public var page: CaptionPage
    /// style; Shared render snapshot; captions §13, no CoreGraphics objects cross actors.
    public var style: CaptionStyle
    /// time; Shared render snapshot; captions §13, no CoreGraphics objects cross actors.
    public var time: Double
    /// width; Shared render snapshot; captions §13, no CoreGraphics objects cross actors.
    public var width: Int
    /// height; Shared render snapshot; captions §13, no CoreGraphics objects cross actors.
    public var height: Int
    /// reduceMotion; Shared render snapshot; captions §13, no CoreGraphics objects cross actors.
    public var reduceMotion: Bool

    /// Creates an explicit value without I/O or generated identifiers.
    public init(page: CaptionPage, style: CaptionStyle, time: Double, width: Int, height: Int, reduceMotion: Bool = false) {
        self.page = page
        self.style = style
        self.time = time
        self.width = width
        self.height = height
        self.reduceMotion = reduceMotion
    }

    private enum CodingKeys: String, CodingKey {
        case page
        case style
        case time
        case width
        case height
        case reduceMotion
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.page = try values.decode(CaptionPage.self, forKey: .page)
        self.style = try values.decode(CaptionStyle.self, forKey: .style)
        self.time = try values.decode(Double.self, forKey: .time)
        self.width = try values.decode(Int.self, forKey: .width)
        self.height = try values.decode(Int.self, forKey: .height)
        self.reduceMotion = try values.decodeIfPresent(Bool.self, forKey: .reduceMotion) ?? false
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(self.page, forKey: .page)
        try values.encode(self.style, forKey: .style)
        try values.encode(self.time, forKey: .time)
        try values.encode(self.width, forKey: .width)
        try values.encode(self.height, forKey: .height)
        try values.encode(self.reduceMotion, forKey: .reduceMotion)
    }

}

/// Premultiplied RGBA raster, top-left origin, gamma-encoded sRGB; captions §13.1.
public struct CaptionRaster: Codable, Sendable, Equatable {
    /// width; Premultiplied RGBA raster, top-left origin, gamma-encoded sRGB; captions §13.1.
    public var width: Int
    /// height; Premultiplied RGBA raster, top-left origin, gamma-encoded sRGB; captions §13.1.
    public var height: Int
    /// bytesPerRow; Premultiplied RGBA raster, top-left origin, gamma-encoded sRGB; captions §13.1.
    public var bytesPerRow: Int
    /// rgba; Premultiplied RGBA raster, top-left origin, gamma-encoded sRGB; captions §13.1.
    public var rgba: Data

    /// Creates an explicit value without I/O or generated identifiers.
    public init(width: Int, height: Int, bytesPerRow: Int, rgba: Data) {
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.rgba = rgba
    }

    private enum CodingKeys: String, CodingKey {
        case width
        case height
        case bytesPerRow
        case rgba
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.width = try values.decode(Int.self, forKey: .width)
        self.height = try values.decode(Int.self, forKey: .height)
        self.bytesPerRow = try values.decode(Int.self, forKey: .bytesPerRow)
        self.rgba = try values.decode(Data.self, forKey: .rgba)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(self.width, forKey: .width)
        try values.encode(self.height, forKey: .height)
        try values.encode(self.bytesPerRow, forKey: .bytesPerRow)
        try values.encode(self.rgba, forKey: .rgba)
    }

}

/// One caption renderer for preview, export and goldens; architecture §2.1 and captions §1.2, §13.
public protocol CaptionRasterizer: Sendable { func rasterize(_ request: CaptionRasterRequest) async throws -> CaptionRaster }
/// Pure caption pipeline seams; captions §3, §6, §7 and §11.2.
public enum CaptionTextTransformer {
    public static func apply(_ text: String, style: CaptionStyle, options: CaptionTextOptions) throws -> String { throw VoxClipError.notImplemented("mac-captions") }
}
/// Paging over shaped integer advances; captions §6.1–6.2.
public enum CaptionPager {
    public static func pages(words: [ShapedWord], style: CaptionStyle, width: Int, height: Int) throws -> [CaptionPage] { throw VoxClipError.notImplemented("mac-captions") }
}
/// Deterministic line breaking; captions §6.3.
public enum CaptionLineBreaker {
    public static func lines(words: [ShapedWord], style: CaptionStyle, limitUnits: Int) throws -> [CaptionLine] { throw VoxClipError.notImplemented("mac-captions") }
}
/// Safe-area placement and clamping; captions §7.
public enum CaptionPlacement {
    public static func place(page: CaptionPage, style: CaptionStyle, position: CaptionPosition?, width: Int, height: Int) throws -> CaptionPage { throw VoxClipError.notImplemented("mac-captions") }
}
/// Pure easing curves; captions §11.2.
public enum CaptionEasing {
    public static func evaluate(_ easing: CaptionAnimEasing, progress: Double) throws -> Double { throw VoxClipError.notImplemented("mac-captions") }
}
