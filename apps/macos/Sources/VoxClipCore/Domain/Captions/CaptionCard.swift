import Foundation

/// The part of a take a caption card shows; design §5.4.2.
public enum CaptionCardScope: Sendable, Hashable {
    case fullTake
    case clip(String)

    var outputScope: VoiceLabOutputScope {
        switch self {
        case .fullTake: .full
        case .clip(let id): .clip(id)
        }
    }
}

/// Where a caption card's words come from; design §5.4.2. `.none` means there is no card (stage black).
public enum CaptionCardSource: String, Codable, Sendable {
    case transcript, title, none
}

/// The surfaces that draw caption cards, with their line limit and plate rule; design §5.4.3.
public enum CaptionCardSurface: String, Codable, Sendable, CaseIterable {
    case homeTile, headerChip, sidebar, clipRow

    /// Lines the surface allows; a style with fewer lines keeps its own limit.
    public var lineLimit: Int { self == .headerChip ? 1 : 2 }
    /// Boxes, pills and plates are drawn on Home tiles and the header chip, never at sidebar sizes.
    public var drawsPlates: Bool { self == .homeTile || self == .headerChip }
}

/// One word of a caption card; design §5.4.2.
public struct CaptionCardWord: Codable, Sendable, Equatable {
    /// The caption word id, or "title-{i}" for the i-th word of the project title.
    public var id: String
    /// What the caption layout takes: the corrected word or the title word, with no transform.
    public var text: String
    /// The word after the style's case and punctuation and the bundled-font cascade (captions §3.1 and §4.4).
    public var display: String
    /// A filler or a stopword of the transcript language. Trailing weak words are trimmed.
    public var weak: Bool

    public init(id: String, text: String, display: String, weak: Bool) {
        self.id = id; self.text = text; self.display = display; self.weak = weak
    }
}

/// The words a media stand-in shows when there is no frame: the scope's opening caption page in the project's
/// caption style, or the project title while Settings hides transcript words; design §5.4.2. Pure: no I/O and no
/// rendering. The apps draw it with their caption renderer and fit it to the surface (§5.4.3).
public struct CaptionCardText: Codable, Sendable, Equatable {
    /// Words per card page, whatever the style allows.
    public static let maxWords = 4
    public static let none = CaptionCardText(source: .none, words: [], keyIndex: 0, styleMaxLines: 0, drawsAtLastWord: false, holdGapSec: 0)

    public var source: CaptionCardSource
    public var words: [CaptionCardWord]
    /// The key word: the first number, otherwise the first word that is not weak, otherwise the first word.
    public var keyIndex: Int
    /// The resolved style's `layout.maxLines`; 0 when there is no card.
    public var styleMaxLines: Int
    /// The style's reveal hides words after the active one (`word` or `char`), so the card is drawn at its last word.
    public var drawsAtLastWord: Bool
    /// The resolved style's `layout.holdGapSec`: how long a page stays after its last word; 0 when there is no card.
    public var holdGapSec: Double

    public init(source: CaptionCardSource, words: [CaptionCardWord], keyIndex: Int, styleMaxLines: Int, drawsAtLastWord: Bool,
                holdGapSec: Double) {
        self.source = source; self.words = words; self.keyIndex = keyIndex; self.styleMaxLines = styleMaxLines
        self.drawsAtLastWord = drawsAtLastWord; self.holdGapSec = holdGapSec
    }

    /// The most lines the card may use on a surface.
    public func maxLines(on surface: CaptionCardSurface) -> Int { min(surface.lineLimit, styleMaxLines) }

    /// The card as caption input at a fixed moment, like a gallery tile (captions §15.3): word i spans
    /// [0.4 i, 0.4 i + 0.35] and only the key word is emphasised, so it takes the style's emphasis.
    public var layoutWords: [CaptionInputWord] {
        words.enumerated().map { index, word in
            CaptionInputWord(id: word.id, text: word.text, start: Double(index) * 0.4, end: Double(index) * 0.4 + 0.35, emphasis: index == keyIndex)
        }
    }

    /// The caption track duration for `layoutWords`.
    public var duration: Double { words.isEmpty ? 0 : Double(words.count) * 0.4 + 0.5 }

    /// When to draw `layoutWords` (design §5.4.2): 0.35 × 0.98 into the key word, as a gallery tile is drawn
    /// (captions §15.3). The key word is then the active word (Karaoke fills up to it, Pop colours it, Neon dims the
    /// words after it), and the page is still visible for styles that hold nothing after their last word (Bold,
    /// Highlight). With `drawsAtLastWord` the card is drawn in its last word instead, at that word's end while the
    /// page holds after it, so a long Typewriter word shows its last character.
    public var time: Double {
        guard !words.isEmpty else { return 0 }
        let anchor = drawsAtLastWord ? words.count - 1 : keyIndex
        return Double(anchor) * 0.4 + (drawsAtLastWord && holdGapSec > 0 ? 0.35 : 0.35 * 0.98)
    }

    /// The fit's next shorter card (§5.4.3): the last word goes, then any weak words before it, keeping one word.
    /// Nil when one word is left.
    public func droppingLastWord() -> CaptionCardText? {
        guard words.count > 1 else { return nil }
        var shorter = Array(words.dropLast())
        while shorter.count > 1, shorter.last?.weak == true { shorter.removeLast() }
        return CaptionCardText(source: source, words: shorter, keyIndex: Self.keyIndex(shorter), styleMaxLines: styleMaxLines,
                               drawsAtLastWord: drawsAtLastWord, holdGapSec: holdGapSec)
    }

    /// The card for a scope of the project in `style`, the library style the project uses (the caller picks one when
    /// captions are off). The project's caption overrides apply; `wordsVisible` is Settings → General → "Show
    /// transcript words on placeholders".
    public static func make(project: Project, scope: CaptionCardScope, style: CaptionStyle, wordsVisible: Bool,
                            resources: CaptionResources) -> CaptionCardText {
        guard let copy = ScopeWords(project: project, scope: scope, style: style, overrides: project.captions.overrides, resources: resources), !copy.words.isEmpty else { return .none }
        var words = copy.words
        var layout = copy.style.layout
        layout.maxWords = min(layout.maxWords, maxWords)
        var source = CaptionCardSource.transcript
        if !wordsVisible {
            source = .title
            let tokens = CaptionTextRules.raw(project.title ?? "").split(separator: " ").map(String.init)
            words = tokens.enumerated().compactMap { copy.candidate("title-\($0.offset)", $0.element, 0, 0) }
            guard !words.isEmpty else { return .none }
            layout.breakOnGapSec = nil; layout.maxPageSec = nil
        }
        if copy.stopwords != nil, let lead = words.firstIndex(where: { !EditingPrimitives.filler($0.text) }) { words.removeFirst(lead) }
        let pages = CaptionLayoutEngine.pageGroups(count: words.count, layout: layout, raw: { words[$0].raw }, start: { words[$0].start },
                                                   end: { words[$0].end }) { _ in true }
        var page = pages[0]
        if copy.stopwords != nil {
            page = pages.first { $0.contains { !copy.weak(words[$0]) } } ?? pages[0]
            while page.count > 1, let last = page.last, copy.weak(words[last]) { page.removeLast() }
        }
        return copy.card(source: source, words: page.map { words[$0] })
    }

    struct Candidate {
        var id: String, text: String, raw: String, display: String, start: Double, end: Double
    }

    /// The scope's caption copy (editing §7.6) in the resolved style: the library style with the supplied overrides at the
    /// export frame, and only the words that normalisation and the bundled-font cascade leave a glyph (captions §3.1 and
    /// §4.4). Caption cards and gallery samples (captions §15.2) both start from it.
    struct ScopeWords {
        let style: CaptionStyle
        let tag: String
        let language: String
        let resources: CaptionResources
        /// The scope's edited duration, which ends the last caption page (captions §8.1).
        let duration: Double
        /// The transcript language's stopwords. Nil when the language has none, and then no word is weak.
        let stopwords: Set<String>?
        private(set) var words: [Candidate] = []

        /// Nil with no transcript, or when the style or the scope's plan cannot be built.
        init?(project: Project, scope: CaptionCardScope, style: CaptionStyle, overrides: [String: JSONValue], resources: CaptionResources) {
            guard let transcript = project.transcript else { return nil }
            let tag = transcript.language ?? "und", frame = CaptionCardText.exportFrame(project)
            let input = CaptionLayoutInput(style: style.id, frame: .init(width: frame.width, height: frame.height), language: tag, duration: 0,
                captions: .init(overrides: overrides, position: project.captions.position,
                                 positionByAspect: project.captions.positionByAspect), words: [])
            guard let resolved = try? CaptionStyleResolver.resolution(style, input: input, resources: resources).style,
                  let plan = try? VoiceLabOutputPlanner.build(project, scope: scope.outputScope) else { return nil }
            self.style = resolved; self.tag = tag; language = CaptionTextRules.language(tag); self.resources = resources
            duration = plan.duration; stopwords = resources.stopwords[language]
            words = plan.captions.compactMap { candidate($0.id, $0.text, $0.start, $0.end) }
        }

        /// The word as a caption page holds it, or nil when nothing of it is drawn.
        func candidate(_ id: String, _ text: String, _ start: Double, _ end: Double) -> Candidate? {
            let normalised = CaptionTextRules.normalize(text, options: style.text, language: tag, resources: resources)
            let request = GlyphShapeRequest(text: normalised, fontFile: style.font.file, fallbackFiles: style.font.fallbackFiles, language: tag)
            guard !normalised.isEmpty, let runs = try? CaptionFontCascade.resolve(request, resources: resources).runs, !runs.isEmpty else { return nil }
            return Candidate(id: id, text: text, raw: CaptionTextRules.raw(text), display: runs.map(\.text).joined(), start: start, end: end)
        }

        /// A filler or a stopword of the transcript language (design §5.4.2).
        func weak(_ word: Candidate) -> Bool {
            guard let stopwords else { return false }
            return EditingPrimitives.filler(word.text) || stopwords.contains(CaptionTextRules.matchingKey(word.display, language: language, resources: resources))
        }

        /// The card of `words` in this style, with its key word and drawn moment (design §5.4.2).
        func card(source: CaptionCardSource, words: [Candidate]) -> CaptionCardText {
            let card = words.map { CaptionCardWord(id: $0.id, text: $0.text, display: $0.display, weak: weak($0)) }
            let reveal = style.reveal?.unit ?? .page
            return CaptionCardText(source: source, words: card, keyIndex: CaptionCardText.keyIndex(card), styleMaxLines: style.layout.maxLines,
                                   drawsAtLastWord: reveal == .word || reveal == .char, holdGapSec: style.layout.holdGapSec)
        }
    }

    static func keyIndex(_ words: [CaptionCardWord]) -> Int {
        words.firstIndex { $0.display.unicodeScalars.contains { $0.properties.generalCategory == .decimalNumber } }
            ?? words.firstIndex { !$0.weak } ?? 0
    }

    /// The project's export frame (architecture §4.1), which picks the style's aspect overrides.
    static func exportFrame(_ project: Project) -> PixelSize {
        let fallback = PixelSize(width: 1920, height: 1080)
        let source = project.media.source.video.map(OutputSizing.orientedSize) ?? fallback
        return (try? OutputSizing.outputSize(source: source, aspect: project.export.aspect)) ?? fallback
    }
}
