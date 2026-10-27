import Foundation

public struct CaptionInputWord: Codable, Sendable, Equatable {
    public var id: String
    public var text: String
    public var start: Double
    public var end: Double
    public var emphasis: Bool?
    public var emoji: String?
    public init(id: String, text: String, start: Double, end: Double, emphasis: Bool? = nil, emoji: String? = nil) {
        self.id = id; self.text = text; self.start = start; self.end = end; self.emphasis = emphasis; self.emoji = emoji
    }
}

public struct CaptionLayoutInput: Codable, Sendable, Equatable {
    public struct Frame: Codable, Sendable, Equatable {
        public var width: Int
        public var height: Int
        public init(width: Int, height: Int) { self.width = width; self.height = height }
    }
    public struct Settings: Codable, Sendable, Equatable {
        public var overrides: [String: JSONValue]
        public var position: CaptionPosition?
        public var positionByAspect: [String: CaptionPosition]
        public init(overrides: [String: JSONValue] = [:], position: CaptionPosition? = nil, positionByAspect: [String: CaptionPosition] = [:]) {
            self.overrides = overrides; self.position = position; self.positionByAspect = positionByAspect
        }
    }
    public var style: String
    public var frame: Frame
    public var language: String
    public var duration: Double
    public var captions: Settings
    public var words: [CaptionInputWord]
    public init(style: String, frame: Frame, language: String, duration: Double, captions: Settings = .init(), words: [CaptionInputWord]) {
        self.style = style; self.frame = frame; self.language = language; self.duration = duration; self.captions = captions; self.words = words
    }
}

public struct CaptionMeasuredWord: Sendable, Equatable {
    public var sourceIndex: Int
    public var input: CaptionInputWord
    public var raw: String
    public var shaped: ShapedWord
    public var emphasisPoints: Int
    public var emphasisCandidate: Bool
    public var emphasisShaped: ShapedWord?
}

public struct CaptionBoxGeometry: Sendable, Equatable {
    public var kind: CaptionBoxScope
    public var word: Int?
    public var rect: CaptionRect
    public var radius: Double
}

public struct CaptionEmojiGeometry: Sendable, Equatable {
    public var word: Int
    public var codepoints: String
    public var rect: CaptionRect
}

public struct CaptionPageLayout: Sendable, Equatable {
    public var page: CaptionPage
    public var indices: [Int]
    public var fontPx64: Int
    public var shrunk: Bool
    public var emphasised: [Int: String?]
    public var emoji: CaptionEmojiGeometry?
    public var boxes: [CaptionBoxGeometry]
    public var clampShift: CaptionPoint
}

public struct CaptionLayoutResult: Sendable, Equatable {
    public var input: CaptionLayoutInput
    public var style: CaptionStyle
    public var aspect: String
    public var preset: String?
    public var fontPx64: Int
    public var limitPx: Double
    public var limitPx64: Int
    public var unitsPerEm: Int
    public var gapUnits: Int
    public var safeRect: CaptionRect
    public var words: [CaptionMeasuredWord]
    public var dropped: [CaptionDroppedWord]
    public var pages: [CaptionPageLayout]
    public var font: CaptionFontRecord
    public var track: CaptionTrack { CaptionTrack(words: words.map(\.shaped.word), pages: pages.map(\.page)) }
    public func page(at editedTime: Double) -> CaptionPage? {
        guard editedTime.isFinite else { return nil }
        var lower = 0, upper = pages.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if pages[middle].page.start <= editedTime { lower = middle + 1 }
            else { upper = middle }
        }
        guard lower > 0, editedTime < pages[lower - 1].page.end else { return nil }
        return pages[lower - 1].page
    }
}

public struct CaptionDroppedWord: Codable, Sendable, Equatable {
    public var sourceIndex: Int
    public var text: String
    public var reason: String
}

public enum CaptionStyleResolver {
    public struct Resolution: Sendable {
        public var style: CaptionStyle
        public var rejectedOverrides: Bool
        public init(style: CaptionStyle, rejectedOverrides: Bool) {
            self.style = style; self.rejectedOverrides = rejectedOverrides
        }
    }

    public static func aspect(width: Int, height: Int) -> String {
        if 10 * width < 9 * height { return "portrait" }
        if 9 * width > 10 * height { return "landscape" }
        return "square"
    }

    public static func preset(width: Int, height: Int) -> String? {
        if 16 * width == 9 * height { return "9:16" }
        if 9 * width == 16 * height { return "16:9" }
        return width == height ? "1:1" : nil
    }

    public static func resolve(_ original: CaptionStyle, input: CaptionLayoutInput) throws -> CaptionStyle {
        try resolution(original, input: input).style
    }

    public static func resolution(_ original: CaptionStyle, input: CaptionLayoutInput, resources: CaptionResources? = nil) throws -> Resolution {
        func checked(_ input: CaptionLayoutInput) throws -> CaptionStyle {
            let style = try patched(original, input: input)
            try style.validateSemantics()
            if let resources { try resources.validate(style: style) }
            return style
        }
        do {
            return try .init(style: checked(input), rejectedOverrides: false)
        } catch {
            guard !input.captions.overrides.isEmpty else { throw error }
            var fallback = input
            fallback.captions.overrides = [:]
            return try .init(style: checked(fallback), rejectedOverrides: true)
        }
    }

    static func patched(_ original: CaptionStyle, input: CaptionLayoutInput) throws -> CaptionStyle {
        var style = original
        let aspect = aspect(width: input.frame.width, height: input.frame.height)
        let override = aspect == "portrait" ? style.aspects?.portrait : aspect == "square" ? style.aspects?.square : style.aspects?.landscape
        if let override {
            style.font.sizeSh = override.sizeSh ?? style.font.sizeSh
            style.position.x = override.x ?? style.position.x
            style.position.y = override.y ?? style.position.y
            style.layout.maxWords = override.maxWords ?? style.layout.maxWords
            style.layout.maxLineWidthW = override.maxLineWidthW ?? style.layout.maxLineWidthW
        }
        var patch = input.captions.overrides
        let forbidden: Set<String> = ["$schema", "schemaVersion", "id", "name", "description", "order", "tags", "aspects", "preview"]
        guard forbidden.isDisjoint(with: patch.keys) else { throw CaptionFailure.invalid("Unpatchable style property") }
        if !style.text.userOverridable, case .object(var text) = patch["text"] {
            text.removeValue(forKey: "transform"); text.removeValue(forKey: "punctuation"); patch["text"] = .object(text)
        }
        if !patch.isEmpty {
            let encoder = JSONEncoder()
            let json = try JSONDecoder().decode(JSONValue.self, from: encoder.encode(style))
            style = try JSONDecoder().decode(CaptionStyle.self, from: encoder.encode(merge(json, patch: .object(patch))))
        }
        let preset = preset(width: input.frame.width, height: input.frame.height)
        let position = preset.flatMap { input.captions.positionByAspect[$0] } ?? input.captions.position
        if style.position.userDraggable, let position {
            guard position.x.isFinite, position.y.isFinite, (0...1).contains(position.x), (0...1).contains(position.y) else {
                throw CaptionFailure.invalid("Caption position")
            }
            style.position.x = position.x; style.position.y = position.y
        }
        return style
    }

    static func merge(_ target: JSONValue, patch: JSONValue) -> JSONValue {
        guard case .object(let patch) = patch else { return patch }
        var result: [String: JSONValue] = [:]
        if case .object(let object) = target { result = object }
        for (key, value) in patch {
            if value == .null { result.removeValue(forKey: key) }
            else { result[key] = merge(result[key] ?? .null, patch: value) }
        }
        return .object(result)
    }
}

extension CaptionStyle {
    public func resolved(overrides: [String: JSONValue], frame: PixelSize) throws -> CaptionStyle {
        let input = CaptionLayoutInput(style: id, frame: .init(width: frame.width, height: frame.height),
            language: "und", duration: 0, captions: .init(overrides: overrides), words: [])
        let style = try CaptionStyleResolver.patched(self, input: input)
        try style.validateSemantics()
        return style
    }
}

public enum CaptionLayoutEngine {
    public static func build(input: CaptionLayoutInput, style original: CaptionStyle, resources: CaptionResources, shaper: any GlyphShaper, resolvedStyle: Bool = false) async throws -> CaptionLayoutResult {
        try Task.checkCancellation()
        guard (1...32768).contains(input.frame.width), (1...32768).contains(input.frame.height),
              input.duration.isFinite, input.duration >= 0,
              input.words.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start }),
              zip(input.words, input.words.dropFirst()).allSatisfy({ $0.start <= $1.start }) else {
            throw CaptionFailure.invalid("Caption input")
        }
        var style = try resolvedStyle ? original : CaptionStyleResolver.resolution(original, input: input, resources: resources).style
        if resolvedStyle {
            try style.validateSemantics()
            try resources.validate(style: style)
            if style.position.userDraggable, let position = input.captions.position {
                guard position.x.isFinite, position.y.isFinite, (0...1).contains(position.x), (0...1).contains(position.y) else {
                    throw CaptionFailure.invalid("Caption position")
                }
                style.position.x = position.x; style.position.y = position.y
            }
        }
        let font = try resources.font(style.font.file)
        let width = Double(input.frame.width), height = Double(input.frame.height)
        let aspect = CaptionStyleResolver.aspect(width: input.frame.width, height: input.frame.height)
        let portrait = aspect == "portrait"
        let left = portrait ? 0.06 : 0.05, right = portrait ? 0.06 : 0.05
        let top = portrait ? 0.06 : 0.05, bottom = portrait ? 0.10 : 0.07
        let safe = CaptionRect(x: width * left, y: height * top, width: width * (1 - right) - width * left, height: height * (1 - bottom) - height * top)
        let reference = style.font.sizeRef == .shortEdge ? min(width, height) : style.font.sizeRef == .height ? height : width
        let font64 = max(1, CaptionMath.roundHalfUp(style.font.sizeSh * reference * style.font.sizeScale * 64))
        let fontPx = Double(font64) / 64
        let padX = style.box.map { $0.scope == .word ? 0 : $0.paddingXEm * fontPx } ?? 0
        let limit = min(style.layout.maxLineWidthW * width, safe.width - 2 * padX)
        let limit64 = Int(floor(limit * 64))
        let spacing = CaptionMath.roundHalfUp(style.font.letterSpacingEm * Double(font.unitsPerEm))
        let gap = style.font.wordSpacingEm.map { CaptionMath.roundHalfUp($0 * Double(font.unitsPerEm)) } ?? font.spaceAdvance + spacing
        var words: [CaptionMeasuredWord] = [], dropped: [CaptionDroppedWord] = []
        let language = CaptionTextRules.language(input.language)
        let emphasis = style.emphasis ?? CaptionEmphasis()
        for (index, word) in input.words.enumerated() {
            try Task.checkCancellation()
            let display = CaptionTextRules.normalize(word.text, options: style.text, language: input.language, resources: resources)
            guard !display.isEmpty else { dropped.append(.init(sourceIndex: index, text: word.text, reason: "empty")); continue }
            let shaped: ShapedWord
            do {
                shaped = try await measure(display, word: word, fontFile: style.font.file, style: style, language: input.language, resources: resources, shaper: shaper)
            } catch CaptionFailure.noGlyphs {
                dropped.append(.init(sourceIndex: index, text: word.text, reason: "no-glyphs")); continue
            }
            guard !shaped.runs.isEmpty else { dropped.append(.init(sourceIndex: index, text: word.text, reason: "no-glyphs")); continue }
            let scalars = shaped.word.text.unicodeScalars
            let letters = scalars.filter(CaptionTextRules.letterOrNumber).count
            let key = CaptionTextRules.matchingKey(shaped.word.text, language: language, resources: resources)
            let points = (scalars.contains { $0.properties.generalCategory == .decimalNumber } ? 300 : 0) +
                (letters >= 6 ? 100 : 0) + (resources.stopwords[language]?.contains(key) == true ? 0 : 100) + min(letters, 99)
            let candidate = emphasis.source != .none && (word.emphasis == true ||
                (word.emphasis == nil && [.rule, .llm].contains(emphasis.source) && points >= CaptionMath.roundHalfUp(emphasis.minScore * 100)))
            var emph: ShapedWord?
            if candidate {
                do {
                    emph = try await measure(shaped.word.text, word: word, fontFile: emphasis.fontFile ?? style.font.file, style: style, language: input.language, resources: resources, shaper: shaper)
                } catch CaptionFailure.noGlyphs {
                    dropped.append(.init(sourceIndex: index, text: word.text, reason: "no-glyphs")); continue
                }
                emph!.units = CaptionMath.roundHalfUp(Double(emph!.units) * emphasis.scale)
            }
            words.append(.init(sourceIndex: index, input: word, raw: CaptionTextRules.raw(word.text), shaped: shaped,
                               emphasisPoints: points, emphasisCandidate: candidate, emphasisShaped: emph))
        }
        let fits: (Int) -> Bool = { $0 * font64 <= limit64 * font.unitsPerEm }
        func pagingWidth(_ index: Int) -> Int { max(words[index].shaped.units, words[index].emphasisShaped?.units ?? 0) }
        func pageFits(_ indices: [Int]) -> Bool {
            let widths = indices.map(pagingWidth)
            let lines = breakLines(widths: widths, gap: gap, balanced: style.layout.balance == .balanced, fits: fits)
            return lines.count <= style.layout.maxLines && (indices.count == 1 || lines.allSatisfy { fits(lineUnits($0, widths, gap)) })
        }
        let groups = pageGroups(count: words.count, layout: style.layout, raw: { words[$0].raw }, start: { words[$0].input.start },
                                end: { words[$0].input.end }, fits: pageFits)
        var paletteIndex = 0
        var previousEmoji: String?
        var pages: [CaptionPageLayout] = []
        for (pageIndex, indices) in groups.enumerated() {
            try Task.checkCancellation()
            let manual = indices.filter { emphasis.source != .none && words[$0].input.emphasis == true }
            let rules = indices.filter { words[$0].emphasisCandidate && words[$0].input.emphasis == nil }.sorted {
                words[$0].emphasisPoints == words[$1].emphasisPoints ? $0 < $1 : words[$0].emphasisPoints > words[$1].emphasisPoints
            }
            let chosen = (manual + rules.prefix(max(0, emphasis.maxPerPage - manual.count))).sorted()
            var emphasised: [Int: String?] = [:]
            for index in chosen {
                if let palette = emphasis.palette, !palette.isEmpty { emphasised[index] = .some(palette[paletteIndex % palette.count]); paletteIndex += 1 }
                else { emphasised[index] = .some(nil) }
            }
            var emoji: (Int, String)?
            if style.emoji?.enabled == true {
                if let index = indices.first(where: { words[$0].input.emoji != nil }) { emoji = (index, words[index].input.emoji!) }
                else if (style.emoji?.maxPerPage ?? 1) >= 1, style.emoji?.source != .manual {
                    for index in indices {
                        let key = CaptionTextRules.matchingKey(words[index].shaped.word.text, language: language, resources: resources)
                        if let code = resources.emoji(for: key, language: language), code != previousEmoji { emoji = (index, code); break }
                    }
                }
            }
            previousEmoji = emoji?.1
            let start = words[indices[0]].input.start
            let next = pageIndex + 1 < groups.count ? words[groups[pageIndex + 1][0]].input.start : Double.infinity
            var end = min(words[indices.last!].input.end + style.layout.holdGapSec, next)
            if end - start < style.layout.minPageSec { end = min(start + style.layout.minPageSec, next) }
            end = min(end, input.duration)
            let widths = indices.map { emphasised.keys.contains($0) ? words[$0].emphasisShaped!.units : words[$0].shaped.units }
            let lines = breakLines(widths: widths, gap: gap, balanced: style.layout.balance == .balanced, fits: fits)
            let shrunk = indices.count == 1 && !fits(widths[0])
            let page64 = shrunk ? max(Int(ceil(Double(font64) * style.layout.minShrink)), min(font64, limit64 * font.unitsPerEm / widths[0])) : font64
            pages.append(place(index: pageIndex, indices: indices, words: words, widths: widths, lines: lines, style: style, font: font, gap: gap, font64: page64,
                               start: start, end: end, safe: safe, width: width, height: height, emphasised: emphasised, emoji: emoji, shrunk: shrunk))
        }
        return .init(input: input, style: style, aspect: aspect, preset: CaptionStyleResolver.preset(width: input.frame.width, height: input.frame.height),
                     fontPx64: font64, limitPx: limit, limitPx64: limit64, unitsPerEm: font.unitsPerEm, gapUnits: gap, safeRect: safe,
                     words: words, dropped: dropped, pages: pages, font: font)
    }

    static func measure(_ text: String, word: CaptionInputWord, fontFile: String, style: CaptionStyle, language: String, resources: CaptionResources, shaper: any GlyphShaper) async throws -> ShapedWord {
        let request = GlyphShapeRequest(text: text, fontFile: fontFile, fallbackFiles: style.font.fallbackFiles, language: language,
                                        kern: style.font.features.kern, liga: style.font.features.liga, calt: style.font.features.calt)
        var runs = try await shaper.shape(request)
        let primary = try resources.font(style.font.file)
        for index in runs.indices {
            let sum = runs[index].glyphs.reduce(0) { $0 + $1.advance }
            let upem = runs[index].unitsPerEm
            runs[index].units = upem == primary.unitsPerEm ? sum : (2 * sum * primary.unitsPerEm + upem) / (2 * upem)
        }
        let glyphCount = runs.reduce(0) { $0 + $1.glyphs.count }
        let units = runs.reduce(0) { $0 + $1.units } + max(0, glyphCount - 1) * CaptionMath.roundHalfUp(style.font.letterSpacingEm * Double(primary.unitsPerEm))
        let display = runs.map(\.text).joined()
        let cascade = try CaptionFontCascade.resolve(request, resources: resources)
        return ShapedWord(word: CaptionWord(id: word.id, text: display, start: word.start, end: word.end), runs: runs, units: units, clusters: cascade.clusters, droppedClusters: cascade.dropped)
    }

    /// Captions §6.1 paging over normalised words. `fits` is the §6.2 page fit test; caption cards, which have no
    /// glyph widths yet, pass one that always fits (design §5.4.2).
    static func pageGroups(count: Int, layout: CaptionLayout, raw: (Int) -> String, start: (Int) -> Double, end: (Int) -> Double,
                           fits: ([Int]) -> Bool) -> [[Int]] {
        var groups: [[Int]] = [], current: [Int] = []
        for index in 0..<count {
            if let previous = current.last, let first = current.first {
                let split = current.count >= layout.maxWords ||
                    (layout.breakOnSentence && CaptionTextRules.sentenceEnd(raw(previous))) ||
                    (layout.breakOnComma && current.count >= 2 && CaptionTextRules.clauseEnd(raw(previous))) ||
                    layout.breakOnGapSec.map { start(index) - end(previous) >= $0 } == true ||
                    layout.maxPageSec.map { end(index) - start(first) > $0 } == true || !fits(current + [index])
                if split { groups.append(current); current = [] }
            }
            current.append(index)
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }

    static func lineUnits(_ indices: [Int], _ widths: [Int], _ gap: Int) -> Int {
        indices.reduce(0) { $0 + widths[$1] } + gap * max(0, indices.count - 1)
    }

    static func breakLines(widths: [Int], gap: Int, balanced: Bool, fits: (Int) -> Bool) -> [[Int]] {
        guard !widths.isEmpty else { return [] }
        var lines = [[0]], units = widths[0]
        for index in widths.indices.dropFirst() {
            if fits(units + gap + widths[index]) { lines[lines.count - 1].append(index); units += gap + widths[index] }
            else { lines.append([index]); units = widths[index] }
        }
        guard balanced, (2...3).contains(lines.count), lines.allSatisfy({ fits(lineUnits($0, widths, gap)) }) else { return lines }
        var best = lines, bestWidth = Int.max
        func consider(_ breaks: [Int]) {
            let bounds = [0] + breaks + [widths.count]
            let parts = (0..<(bounds.count - 1)).map { Array(bounds[$0]..<bounds[$0 + 1]) }
            let sizes = parts.map { lineUnits($0, widths, gap) }
            if sizes.allSatisfy(fits), let maximum = sizes.max(), maximum < bestWidth { best = parts; bestWidth = maximum }
        }
        for first in 1..<widths.count {
            if lines.count == 2 { consider([first]) }
            else if first + 1 < widths.count { for second in (first + 1)..<widths.count { consider([first, second]) } }
        }
        return best
    }

    static func place(index: Int, indices: [Int], words: [CaptionMeasuredWord], widths: [Int], lines: [[Int]], style: CaptionStyle,
                      font: CaptionFontRecord, gap: Int, font64: Int, start: Double, end: Double, safe: CaptionRect, width: Double, height: Double,
                      emphasised: [Int: String?], emoji: (Int, String)?, shrunk: Bool) -> CaptionPageLayout {
        let fontPx = Double(font64) / 64
        func px(_ units: Int) -> Double { Double(units) * fontPx / Double(font.unitsPerEm) }
        let padX = style.box.map { $0.scope == .word ? 0 : $0.paddingXEm * fontPx } ?? 0
        let padY = style.box.map { $0.scope == .word ? 0 : $0.paddingYEm * fontPx } ?? 0
        let lineUnits = lines.map { self.lineUnits($0, widths, gap) }, lineWidths = lineUnits.map(px)
        let blockWidth = lineWidths.max() ?? 0, lineHeight = style.font.lineHeightEm * fontPx
        let pitch = lineHeight + style.layout.lineGapEm * fontPx, blockHeight = lineHeight + Double(max(0, lines.count - 1)) * pitch
        let visualWidth = blockWidth + 2 * padX, visualHeight = blockHeight + 2 * padY
        let anchorX = style.position.x * width, anchorY = style.position.y * height
        let visualX = anchorX - (style.position.anchorX == .center ? visualWidth / 2 : style.position.anchorX == .right ? visualWidth : 0)
        let visualY = anchorY - (style.position.anchorY == .center ? visualHeight / 2 : style.position.anchorY == .bottom ? visualHeight : 0)
        let emojiSize = emoji == nil ? 0 : Double(CaptionMath.roundHalfUp((style.emoji?.sizeEm ?? 1.2) * fontPx))
        let emojiX = visualX + visualWidth / 2 - emojiSize / 2
        let emojiY = visualY - (style.emoji?.gapEm ?? 0.15) * fontPx - emojiSize
        func shift(_ lower: Double, _ upper: Double, _ safeLower: Double, _ safeUpper: Double) -> Double {
            if upper - lower > safeUpper - safeLower { return (safeLower + safeUpper) / 2 - (lower + upper) / 2 }
            if lower < safeLower { return safeLower - lower }
            if upper > safeUpper { return safeUpper - upper }
            return 0
        }
        let shiftX = shift(emoji == nil ? visualX : min(visualX, emojiX), emoji == nil ? visualX + visualWidth : max(visualX + visualWidth, emojiX + emojiSize), safe.x, safe.x + safe.width)
        let shiftY = shift(emoji == nil ? visualY : min(visualY, emojiY), visualY + visualHeight, safe.y, safe.y + safe.height)
        let blockX = Double(CaptionMath.roundHalfUp(visualX + shiftX + padX)), blockY = Double(CaptionMath.roundHalfUp(visualY + shiftY + padY))
        let cap = Double(font.capHeight) / Double(font.unitsPerEm) * fontPx
        var outputLines: [CaptionLine] = [], rects: [CaptionRect] = []
        var boxes: [CaptionBoxGeometry] = []
        let block = CaptionRect(x: blockX, y: blockY, width: blockWidth, height: blockHeight)
        let visual = CaptionRect(x: blockX - padX, y: blockY - padY, width: visualWidth, height: visualHeight)
        func boxGeometry(_ rect: CaptionRect, _ box: CaptionBox, word: Int? = nil) -> CaptionBoxGeometry {
            .init(kind: box.scope, word: word, rect: rect, radius: box.pill ? rect.height / 2 : min(box.radiusEm * fontPx, rect.width / 2, rect.height / 2))
        }
        if let box = style.box, box.scope == .page { boxes.append(boxGeometry(visual, box)) }
        for (lineIndex, localIndices) in lines.enumerated() {
            let top = blockY + Double(lineIndex) * pitch
            let baseline = top + lineHeight / 2 + cap / 2
            let lineWidth = lineWidths[lineIndex]
            let lineX = blockX + (style.layout.align == .center ? (blockWidth - lineWidth) / 2 : style.layout.align == .right ? blockWidth - lineWidth : 0)
            let lineRect = CaptionRect(x: lineX, y: top, width: lineWidth, height: lineHeight)
            outputLines.append(.init(words: localIndices.map { indices[$0] }, units: lineUnits[lineIndex], rect: lineRect, baseline: baseline))
            if let box = style.box, box.scope == .line { boxes.append(boxGeometry(.init(x: lineX - padX, y: top - padY, width: lineWidth + 2 * padX, height: lineHeight + 2 * padY), box)) }
            var prefix = 0
            for local in localIndices {
                let rect = CaptionRect(x: lineX + px(prefix), y: top, width: px(widths[local]), height: lineHeight)
                rects.append(rect); prefix += widths[local] + gap
                if let box = style.box, box.scope == .word {
                    let paddingX = box.paddingXEm * fontPx, paddingY = box.paddingYEm * fontPx
                    boxes.append(boxGeometry(.init(x: rect.x - paddingX, y: rect.y - paddingY, width: rect.width + 2 * paddingX, height: rect.height + 2 * paddingY), box, word: indices[local]))
                }
            }
        }
        let emojiRect = emoji.map { CaptionEmojiGeometry(word: $0.0, codepoints: $0.1,
            rect: .init(x: Double(CaptionMath.roundHalfUp(blockX - padX + visualWidth / 2 - emojiSize / 2)),
                        y: Double(CaptionMath.roundHalfUp(blockY - padY - (style.emoji?.gapEm ?? 0.15) * fontPx - emojiSize)), width: emojiSize, height: emojiSize)) }
        let page = CaptionPage(index: index, words: indices.map { words[$0].shaped.word }, start: start, end: end, fontPx: fontPx, lines: outputLines, wordRects: rects, block: block, visual: visual)
        return .init(page: page, indices: indices, fontPx64: font64, shrunk: shrunk, emphasised: emphasised, emoji: emojiRect, boxes: boxes, clampShift: .init(x: shiftX, y: shiftY))
    }
}
