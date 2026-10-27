import Foundation

/// Where a gallery tile's sample words come from; captions §15.2.
public enum CaptionGallerySampleSource: String, Codable, Sendable {
    /// The scope's caption page at the playhead.
    case page
    /// The style's `preview.text`: the scope has no caption words, or Settings hides transcript words.
    case preview
}

/// What a caption gallery tile draws: one caption state at a fixed moment (captions §15.2–15.3, design §6.1). Pure: no
/// I/O and no rendering. The apps lay `words` out over `duration` with the export renderer, in the style the tile shows,
/// and draw them at `time` under Reduce Motion.
public struct CaptionGallerySample: Sendable, Equatable {
    public var source: CaptionGallerySampleSource
    /// Word i spans [0.4 i, 0.4 i + 0.35]. The text is as stored (the corrected word, no transform) and nothing is
    /// marked for emphasis, so the style's own emphasis rule applies as it does in export.
    public var words: [CaptionInputWord]
    /// When to draw `words`; captions §15.3.
    public var time: Double

    public init(source: CaptionGallerySampleSource, words: [CaptionInputWord], time: Double) {
        self.source = source; self.words = words; self.time = time
    }

    /// The caption track duration for `words`.
    public var duration: Double { Double(words.count) * 0.4 + 0.5 }

    /// The tile sample of `style`, a library style, for a scope of the project at `playhead`, in the scope's edited
    /// time (captions §15.3). The words are the page the export would show (§6.1 paging with project overrides only for the selected tile,
    /// without the §6.2 fit, which needs glyph widths): the page at the playhead, the next page in a gap or before the
    /// first page, and the last page after it. Inside a word the tile is drawn in that word; otherwise at the caption
    /// card's key word and drawn moment (design §5.4.2). `preview.text` stands in when the scope has no caption words or
    /// `wordsVisible` (Settings → General → "Show transcript words on placeholders") is off; a tile never shows the
    /// project title. To follow a moving playhead, keep a `CaptionGalleryPages` instead.
    public static func make(project: Project, scope: CaptionCardScope, playhead: Double, style: CaptionStyle, wordsVisible: Bool,
                            resources: CaptionResources) -> CaptionGallerySample {
        CaptionGalleryPages(project: project, scope: scope, style: style, wordsVisible: wordsVisible, resources: resources).sample(at: playhead)
    }

    /// The style's own sample: `preview.text`, split at spaces, drawn `progress` (1 when absent) into word
    /// `min(preview.activeWord, n − 1)`, capped at 0.98 of it; captions §15.3.
    public static func preview(_ style: CaptionStyle) -> CaptionGallerySample {
        let words = style.preview.text.split(separator: " ").enumerated().map { index, text in
            CaptionInputWord(id: "preview-\(index)", text: String(text), start: Double(index) * 0.4, end: Double(index) * 0.4 + 0.35)
        }
        let active: Int = max(0, min(style.preview.activeWord, words.count - 1))
        let progress: Double = min(style.preview.progress ?? 1, 0.98)
        return .init(source: .preview, words: words, time: Double(active) * 0.4 + 0.35 * progress)
    }
}

/// One library style's caption pages over a scope, prepared once so that each playhead is a lookup (captions §15.3).
/// Preparing plans the scope and normalises every caption word, so keep the value while the project's transcript, edits
/// and captions, the scope, the style and the Settings switch stay the same, and call `sample(at:)` as the playhead moves.
public struct CaptionGalleryPages: Sendable {
    private struct Page: Sendable {
        /// The page's §8.1 interval on the scope's edited timeline.
        var start: Double, end: Double
        var sample: [CaptionInputWord]
        /// The page's words on the scope's edited timeline.
        var wordStarts: [Double], wordEnds: [Double]
        /// The caption card's drawn moment for the page (design §5.4.2).
        var keyTime: Double
    }

    private let preview: CaptionGallerySample
    private let pages: [Page]

    public init(project: Project, scope: CaptionCardScope, style: CaptionStyle, wordsVisible: Bool, resources: CaptionResources) {
        preview = CaptionGallerySample.preview(style)
        let overrides = style.id == project.captions.styleId ? project.captions.overrides : [:]
        guard wordsVisible, let copy = CaptionCardText.ScopeWords(project: project, scope: scope, style: style, overrides: overrides, resources: resources),
              !copy.words.isEmpty else { pages = []; return }
        let words = copy.words, layout = copy.style.layout
        let groups = CaptionLayoutEngine.pageGroups(count: words.count, layout: layout, raw: { words[$0].raw }, start: { words[$0].start },
                                                    end: { words[$0].end }) { _ in true }
        var pages: [Page] = []
        for (index, group) in groups.enumerated() {
            let page: [CaptionCardText.Candidate] = group.map { words[$0] }
            let next: Double = index + 1 < groups.count ? words[groups[index + 1][0]].start : .infinity
            let end = CaptionLayoutEngine.pageEnd(start: page[0].start, lastEnd: page[page.count - 1].end, next: next, layout: layout,
                                                  duration: copy.duration)
            let sample = page.enumerated().map { position, word in
                CaptionInputWord(id: word.id, text: word.text, start: Double(position) * 0.4, end: Double(position) * 0.4 + 0.35)
            }
            pages.append(Page(start: page[0].start, end: end, sample: sample, wordStarts: page.map(\.start), wordEnds: page.map(\.end),
                              keyTime: copy.card(source: .transcript, words: page).time))
        }
        self.pages = pages
    }

    /// The tile sample at `playhead`, in the scope's edited time; a playhead that is not finite counts as 0.
    public func sample(at playhead: Double) -> CaptionGallerySample {
        guard !pages.isEmpty else { return preview }
        let time = playhead.isFinite ? playhead : 0
        // Upper bound of the starts: one binary search gives both the visible and the following page (§8.2).
        var lower = 0, upper = pages.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if pages[middle].start <= time { lower = middle + 1 } else { upper = middle }
        }
        let visible = lower > 0 && time < pages[lower - 1].end
        let page = pages[visible ? lower - 1 : min(lower, pages.count - 1)]
        // §8.2: the active word is the page's last word that has started; the playhead is inside it until it ends.
        if visible, let active = page.wordStarts.lastIndex(where: { $0 <= time }), time < page.wordEnds[active] {
            return .init(source: .page, words: page.sample, time: Double(active) * 0.4 + 0.35 * 0.98)
        }
        return .init(source: .page, words: page.sample, time: page.keyTime)
    }
}
