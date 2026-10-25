import Foundation
import CoreText
import CoreGraphics
import CryptoKit
import VoxClipCore

final class CaptionFontLibrary {
    let shared: SharedResources
    let resources: CaptionResources
    private var fonts: [String: CGFont] = [:]
    private var outlines: [String: [UInt32: CGPath]] = [:]
    private struct FontKey: Hashable {
        var file: String
        var kern: Bool
        var liga: Bool
        var calt: Bool
    }
    private var textFonts: [FontKey: CTFont] = [:]
    private var pairTables: [String: OpenTypePairPlacement] = [:]
    private var legacyTables: [String: OpenTypeLegacyKerning] = [:]
    private var loadedPairTables: Set<String> = []

    init(shared: SharedResources, resources: CaptionResources? = nil) throws {
        self.shared = shared
        self.resources = try resources ?? .load(shared: shared)
    }

    func font(_ file: String, features: CaptionFontFeatures = .init()) throws -> CTFont {
        let key = FontKey(file: file, kern: features.kern, liga: features.liga, calt: features.calt)
        if let font = textFonts[key] { return font }
        let record = try resources.font(file)
        let graphics: CGFont
        if let cached = fonts[file] { graphics = cached }
        else {
            let url = shared.root.appendingPathComponent("fonts").appendingPathComponent(record.path)
            guard let data = try? Data(contentsOf: url) else { throw VoxClipError.sharedResourcesMissing }
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard digest == record.sha256, CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) != nil,
                  let provider = CGDataProvider(data: data as CFData), let font = CGFont(provider) else {
                throw VoxClipError.sharedResourcesMissing
            }
            fonts[file] = font; graphics = font
        }
        let settings: [[CFString: Any]] = [("kern", features.kern), ("liga", features.liga), ("calt", features.calt)].map {
            [kCTFontOpenTypeFeatureTag: $0.0, kCTFontOpenTypeFeatureValue: $0.1 ? 1 : 0]
        }
        let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontCascadeListAttribute: [] as [CTFontDescriptor], kCTFontFeatureSettingsAttribute: settings] as CFDictionary)
        let font = CTFontCreateWithGraphicsFont(graphics, Double(record.unitsPerEm), nil, descriptor)
        textFonts[key] = font
        return font
    }

    func placements(file: String, font: CTFont, glyphs: [ShapedGlyph]) -> [Int] {
        loadPairTables(file: file, font: font)
        return pairTables[file]?.horizontalPlacements(glyphs) ?? legacyTables[file]?.horizontalPlacements(glyphs) ?? Array(repeating: 0, count: glyphs.count)
    }

    func advances(file: String, font: CTFont, glyphs: [ShapedGlyph]) -> [Int] {
        loadPairTables(file: file, font: font)
        return pairTables[file]?.horizontalAdvances(glyphs) ?? legacyTables[file]?.horizontalAdvances(glyphs) ?? Array(repeating: 0, count: glyphs.count)
    }

    private func loadPairTables(file: String, font: CTFont) {
        if loadedPairTables.insert(file).inserted {
            if let table = CTFontCopyTable(font, CTFontTableTag(0x47504F53), []) {
                pairTables[file] = OpenTypePairPlacement(bytes: Array(table as Data))
            } else if let table = CTFontCopyTable(font, CTFontTableTag(0x6B65726E), []) {
                legacyTables[file] = OpenTypeLegacyKerning(bytes: Array(table as Data))
            }
        }
    }

    func outline(file: String, glyph: UInt32) throws -> CGPath? {
        if let cached = outlines[file]?[glyph] { return cached }
        guard glyph <= UInt16.max else { throw CaptionFailure.invalid("Glyph id") }
        let font = try font(file)
        guard let path = CTFontCreatePathForGlyph(font, CGGlyph(glyph), nil) else { return nil }
        outlines[file, default: [:]][glyph] = path
        return path
    }
}

public actor CoreTextShaper: GlyphShaper {
    let shared: SharedResources
    private var library: CaptionFontLibrary?
    private struct RunKey: Hashable {
        var text: String
        var file: String
        var language: String?
        var kern: Bool
        var liga: Bool
        var calt: Bool
        var clusters: [Int]
    }
    private var cache: [RunKey: ShapedRun] = [:]
    private var cacheOrder: [RunKey] = []
    private(set) var cacheHits = 0
    public init(shared: SharedResources) { self.shared = shared }
    init(shared: SharedResources, resources: CaptionResources) {
        self.shared = shared
        library = try? CaptionFontLibrary(shared: shared, resources: resources)
    }

    public func shape(_ request: GlyphShapeRequest) async throws -> [ShapedRun] {
        if library == nil { library = try CaptionFontLibrary(shared: shared) }
        let library = library!
        let cascade = try CaptionFontCascade.resolve(request, resources: library.resources)
        let primary = try library.resources.font(request.fontFile)
        var result: [ShapedRun] = []
        for segment in cascade.runs {
            try Task.checkCancellation()
            let key = RunKey(text: segment.text, file: segment.file, language: request.language, kern: request.kern, liga: request.liga, calt: request.calt, clusters: segment.clusters)
            if var cached = cache[key] {
                cacheHits += 1
                let sum = cached.glyphs.reduce(0) { $0 + $1.advance }
                cached.units = cached.unitsPerEm == primary.unitsPerEm ? sum : (2 * sum * primary.unitsPerEm + cached.unitsPerEm) / (2 * cached.unitsPerEm)
                result.append(cached); continue
            }
            let record = try library.resources.font(segment.file)
            let hasBarrier = segment.text.unicodeScalars.contains { $0.value == 0x200C }
            let font = try library.font(segment.file, features: .init(kern: request.kern && !hasBarrier, liga: request.liga, calt: request.calt))
            var attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTLanguageAttributeName as String): request.language ?? "und",
                NSAttributedString.Key(kCTWritingDirectionAttributeName as String): [0]]
            if !request.kern || hasBarrier { attributes[NSAttributedString.Key(kCTKernAttributeName as String)] = 0.0 }
            var utf16Clusters: [Int] = []
            var utf16Positions: [Int] = [], hidden: [(position: Int, cluster: Int)] = []
            var boundaries = [0]
            var scalars: [Unicode.Scalar] = []
            for (index, scalar) in segment.text.unicodeScalars.enumerated() {
                let ignorable = scalar.value == 0x200C || scalar.value == 0x200D || (0xFE00...0xFE0F).contains(scalar.value)
                if ignorable {
                    hidden.append((index, segment.clusters[index]))
                    if scalar.value == 0x200C, boundaries.last != utf16Clusters.count { boundaries.append(utf16Clusters.count) }
                    continue
                }
                scalars.append(scalar)
                utf16Clusters += Array(repeating: segment.clusters[index], count: scalar.utf16.count)
                utf16Positions += Array(repeating: index, count: scalar.utf16.count)
            }
            if boundaries.last != utf16Clusters.count { boundaries.append(utf16Clusters.count) }
            let text = NSAttributedString(string: String(String.UnicodeScalarView(scalars)), attributes: attributes)
            var output: [ShapedGlyph] = []
            var sourcePositions: [Int] = []
            for (start, end) in zip(boundaries, boundaries.dropFirst()) {
                let line = CTLineCreateWithAttributedString(text.attributedSubstring(from: NSRange(location: start, length: end - start)))
                var pen = 0.0
                for run in CTLineGetGlyphRuns(line) as! [CTRun] {
                    let runAttributes = CTRunGetAttributes(run) as NSDictionary
                    guard let usedFont = runAttributes[kCTFontAttributeName] as! CTFont?, CTFontCopyPostScriptName(usedFont) == CTFontCopyPostScriptName(font) else {
                        throw CaptionFailure.noGlyphs
                    }
                    let count = CTRunGetGlyphCount(run)
                    var glyphs = [CGGlyph](repeating: 0, count: count), advances = [CGSize](repeating: .zero, count: count)
                    var positions = [CGPoint](repeating: .zero, count: count), indices = [CFIndex](repeating: 0, count: count)
                    CTRunGetGlyphs(run, CFRange(), &glyphs); CTRunGetBaseAdvancesAndOrigins(run, CFRange(), &advances, nil)
                    CTRunGetPositions(run, CFRange(), &positions); CTRunGetStringIndices(run, CFRange(), &indices)
                    for index in 0..<count {
                        let position = start + indices[index]
                        guard indices[index] >= 0, position < end, glyphs[index] != 0 else { throw CaptionFailure.noGlyphs }
                        sourcePositions.append(utf16Positions[position])
                        output.append(.init(id: UInt32(glyphs[index]), advance: CaptionMath.roundHalfUp(advances[index].width),
                                            offsetX: CaptionMath.roundHalfUp(positions[index].x - pen), offsetY: CaptionMath.roundHalfUp(positions[index].y), cluster: utf16Clusters[position]))
                        pen += advances[index].width
                    }
                }
            }
            var sum = output.reduce(0) { $0 + $1.advance }
            if request.kern {
                let placements = library.placements(file: segment.file, font: font, glyphs: output)
                let advances = hasBarrier ? library.advances(file: segment.file, font: font, glyphs: output) : []
                for index in output.indices {
                    output[index].advance += hasBarrier ? advances[index] : placements[index] - (index + 1 < output.count ? placements[index + 1] : 0)
                    output[index].offsetX += placements[index]
                }
                if hasBarrier { sum = output.reduce(0) { $0 + $1.advance } }
            }
            var space: UniChar = 0x20, spaceGlyph: CGGlyph = 0
            if !hidden.isEmpty, CTFontGetGlyphsForCharacters(font, &space, &spaceGlyph, 1), spaceGlyph != 0 {
                for item in hidden.reversed() {
                    let insertion = sourcePositions.firstIndex(where: { $0 > item.position }) ?? output.count
                    output.insert(.init(id: UInt32(spaceGlyph), advance: 0, offsetX: 0, offsetY: 0, cluster: item.cluster), at: insertion)
                    sourcePositions.insert(item.position, at: insertion)
                }
            }
            let units = record.unitsPerEm == primary.unitsPerEm ? sum : (2 * sum * primary.unitsPerEm + record.unitsPerEm) / (2 * record.unitsPerEm)
            let shaped = ShapedRun(file: segment.file, text: segment.text, unitsPerEm: record.unitsPerEm, units: units, glyphs: output)
            if cacheOrder.count >= 4096 { cache.removeValue(forKey: cacheOrder.removeFirst()) }
            cache[key] = shaped; cacheOrder.append(key)
            result.append(shaped)
        }
        return result
    }
}
