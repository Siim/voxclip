import AppKit
import CoreText
import VoxClipCore

extension NSAttributedString.Key {
    /// A rendering attribute set only to redraw a fragment whose gutter or fold changed.
    static let vcGutter = Self("voxclip.gutter")
    static let vcStrike = Self("voxclip.strike")
    static let vcUnderline = Self("voxclip.underline")
    static let vcUnderlineColor = Self("voxclip.underlineColor")
}

enum TranscriptSpanKind: Equatable {
    case text
    case ai
    /// A run of removed words and pauses folded into one dot (ux/v2 notes.md §5): a word
    /// joiner, one glyph drawn clear and kerned to the fold's gap, and a zero-width space, so
    /// the dot stays on the line of the word before it. `ids` are the words and pauses it
    /// holds, in reading order.
    case fold
    /// A comma that folds with the filler after it (`DisplayPunctuation`), shown in
    /// `word.gone` under Show cuts or in an opened fold.
    case comma
}

struct TranscriptSpan: Equatable {
    let id: String
    let range: NSRange
    let pause: Bool
    var ids: [String] = []
    var kind: TranscriptSpanKind = .text
    var selectable: Bool { kind == .text }
    /// The same span `offset` characters later.
    func moved(by offset: Int) -> TranscriptSpan {
        offset == 0 ? self : TranscriptSpan(id: id, range: NSRange(location: range.location + offset, length: range.length), pause: pause, ids: ids, kind: kind)
    }
}

/// A fold's characters (ux/v2 notes.md §5): a word joiner glues it to the word before, the
/// glyph is drawn clear and kerned so the fold is `gap` wide, and the zero-width space after it
/// is where a line may break. No space surrounds it: it replaces the word space.
@MainActor enum TranscriptFold {
    static let joiner = "\u{2060}"
    static let glyph = "\u{2022}"
    static let breakAfter = "\u{200B}"
    static let text = joiner + glyph + breakAfter
    /// The glyph's offset in the fold's text.
    static let glyphOffset = 1
    /// The fold's width and its dot's diameter at the body size: 13 and 5 at 15 pt.
    static func gap(textSize: Double) -> CGFloat { 13 * textSize / DesignValues.transcriptTextSize }
    static func dot(textSize: Double) -> CGFloat { 5 * textSize / DesignValues.transcriptTextSize }
    /// The kern after the glyph that makes the fold `gap` wide in `font`.
    static func kern(font: NSFont, textSize: Double) -> CGFloat {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: glyph, attributes: [.font: font]))
        return gap(textSize: textSize) - CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }
}

/// A clip's characters in the transcript, from its first word to its last, for the backdrop's
/// band and range bar (notes.md §5). Suggested clips draw a dashed bar.
struct TranscriptClipMark: Equatable {
    let range: NSRange
    let suggested: Bool
}

/// One display paragraph of the take (`TranscriptParagraphs`): where its text starts, its
/// first word and that word's take time, which the gutter shows.
struct TranscriptParagraph: Equatable {
    let offset: Int
    let firstWord: Int
    let start: Double
}

/// What one display paragraph shows, as plain values (impl-plan §3.1): its words, folds,
/// corrections, pauses, AI replacements and folded commas, and so the open clip's extent,
/// Show cuts and the opened folds. `rebuild` writes a paragraph's text only when this
/// differs from what the storage holds, so a cut edits one paragraph and every other
/// paragraph keeps its text, spans and styles.
struct TranscriptParagraphContent: Equatable {
    struct Piece: Equatable {
        enum Kind: Equatable {
            /// A word, as corrected, without a comma that folds with the filler after it.
            /// Removed words show as words under Show cuts and in an opened fold.
            case word
            /// An accepted AI passage's words, standing for the source words in `ids`.
            case replacement
            /// A run of removed words and pauses in the open clip, one dot (`TranscriptFold`).
            case fold
            /// The comma a fold took from the word before it, shown again under Show cuts.
            case comma
            /// A pause length, "1.4 s": a cut pause under Show cuts or in an opened fold, and
            /// an uncut pause in the open clip while Show Pauses is on.
            case pause
            /// The kerned blank the AI marker draws over, before an AI passage.
            case aiMarker
        }
        var kind: Kind
        var id: String
        var text: String
        var ids: [String] = []
        var toolTip: String?
    }
    var firstWord: Int
    var start: Double
    var pieces: [Piece] = []
}

/// The transcript's spans by display paragraph (impl-plan §3.1). Each paragraph keeps its
/// spans with ranges from its own first character, plus that character's offset, so
/// replacing a paragraph rewrites only its spans and moves the later offsets. Lookups by id
/// are a dictionary hit and lookups by character two binary searches, before and after an
/// edit. Spans come out with document ranges.
struct TranscriptRangeMap {
    private struct Slot { let paragraph: Int; let index: Int }
    private var offsets: [Int] = []
    /// The document index of each paragraph's first span.
    private var firsts: [Int] = []
    private var local: [[TranscriptSpan]] = []
    private var slots: [String: Slot] = [:]
    private(set) var count = 0

    init() {}
    /// Paragraphs in text order, each with its first character's offset and its spans,
    /// whose ranges count from that character.
    init(paragraphs: [(offset: Int, spans: [TranscriptSpan])]) {
        offsets = paragraphs.map(\.offset)
        local = paragraphs.map(\.spans)
        firsts.reserveCapacity(local.count)
        slots.reserveCapacity(local.reduce(0) { $0 + $1.count + $1.reduce(0) { $0 + $1.ids.count } })
        for paragraph in local.indices {
            firsts.append(count)
            count += local[paragraph].count
            index(paragraph)
        }
    }

    var paragraphCount: Int { local.count }
    var isEmpty: Bool { count == 0 }
    /// Every span in text order, copied with document ranges: O(spans). Use `count`,
    /// `isEmpty`, `span(id:)` or `intersecting(_:)` on paths that run per frame.
    var spans: [TranscriptSpan] {
        var result: [TranscriptSpan] = []
        result.reserveCapacity(count)
        for paragraph in local.indices { result += local[paragraph].map { $0.moved(by: offsets[paragraph]) } }
        return result
    }
    /// The spans of one paragraph, in text order.
    func spans(inParagraph paragraph: Int) -> [TranscriptSpan] { local[paragraph].map { $0.moved(by: offsets[paragraph]) } }
    /// The span with this id, or the one standing for the word with this id (a fold or an AI replacement).
    func span(id: String) -> TranscriptSpan? {
        slots[id].map { local[$0.paragraph][$0.index].moved(by: offsets[$0.paragraph]) }
    }
    /// The span at a document index from 0 to `count - 1`.
    subscript(position: Int) -> TranscriptSpan {
        var lower = 0, upper = firsts.count
        while lower < upper { let middle = (lower + upper) / 2; if firsts[middle] <= position { lower = middle + 1 } else { upper = middle } }
        let paragraph = lower - 1
        return local[paragraph][position - firsts[paragraph]].moved(by: offsets[paragraph])
    }
    /// Replaces one paragraph's spans, whose ranges count from its first character; the
    /// paragraphs after it move by `lengthChange` characters.
    mutating func replace(paragraph: Int, with spans: [TranscriptSpan], lengthChange: Int) {
        for span in local[paragraph] {
            slots[span.id] = nil
            for id in span.ids { slots[id] = nil }
        }
        let added = spans.count - local[paragraph].count
        local[paragraph] = spans
        count += added
        index(paragraph)
        guard added != 0 || lengthChange != 0 else { return }
        for later in (paragraph + 1)..<local.count {
            firsts[later] += added
            offsets[later] += lengthChange
        }
    }
    private mutating func index(_ paragraph: Int) {
        for (position, span) in local[paragraph].enumerated() {
            let slot = Slot(paragraph: paragraph, index: position)
            slots[span.id] = slot
            for id in span.ids { slots[id] = slot }
        }
    }
    /// The document index of the first span ending after `offset`, or `count`.
    private func lowerBound(_ offset: Int) -> Int {
        var lower = 0, upper = offsets.count
        while lower < upper { let middle = (lower + upper) / 2; if offsets[middle] <= offset { lower = middle + 1 } else { upper = middle } }
        guard lower > 0 else { return 0 }
        let paragraph = lower - 1, spans = local[paragraph], within = offset - offsets[paragraph]
        var first = 0, last = spans.count
        while first < last { let middle = (first + last) / 2; if NSMaxRange(spans[middle].range) <= within { first = middle + 1 } else { last = middle } }
        return firsts[paragraph] + first
    }
    func span(at offset: Int) -> TranscriptSpan? {
        let position = lowerBound(offset)
        for next in position..<count where self[next].selectable { return self[next] }
        for previous in (0..<position).reversed() where self[previous].selectable { return self[previous] }
        return nil
    }
    func selectionRanges(in range: NSRange) -> [NSRange] {
        var selected = intersecting(range).filter(\.selectable)
        if selected.isEmpty, range.length == 0, let nearest = span(at: range.location) { selected = [nearest] }
        guard let first = selected.first, let last = selected.last else { return [] }
        let extent = NSRange(location: first.range.location, length: NSMaxRange(last.range) - first.range.location)
        var start = extent.location
        var result: [NSRange] = []
        for span in intersecting(extent) where !span.selectable {
            if span.range.location > start { result.append(NSRange(location: start, length: span.range.location - start)) }
            start = NSMaxRange(span.range)
        }
        if start < NSMaxRange(extent) { result.append(NSRange(location: start, length: NSMaxRange(extent) - start)) }
        return result
    }
    /// The spans a selection holds: the selectable spans in its ranges, then the folds in a
    /// gap between two ranges that holds nothing selectable. `selectionRanges` leaves those
    /// folds out of the ranges it snaps a selection to.
    func selected(_ ranges: [NSRange]) -> [TranscriptSpan] {
        let ranges = ranges.sorted { $0.location < $1.location }
        var result: [TranscriptSpan] = []
        for (index, range) in ranges.enumerated() {
            if index > 0 {
                let previous = NSMaxRange(ranges[index - 1])
                let gap = NSRange(location: previous, length: max(0, range.location - previous))
                let between = gap.length > 0 ? intersecting(gap).filter { NSIntersectionRange($0.range, gap).length > 0 } : []
                if !between.contains(where: \.selectable) { result += between.filter { $0.kind == .fold } }
            }
            result += intersecting(range).filter(\.selectable)
        }
        return result
    }
    func intersecting(_ range: NSRange) -> [TranscriptSpan] {
        let lower = lowerBound(range.location)
        var result: [TranscriptSpan] = []
        var position = lower
        while position < count {
            let span = self[position]
            guard span.range.location < NSMaxRange(range) || range.length == 0 && position == lower else { break }
            result.append(span)
            position += 1
        }
        return result
    }
}

/// What styles the transcript's spans without writing text: the cut state, Find's query,
/// the open clip and the playhead, which places the caret and marks the current paragraph.
struct TranscriptAppearance: Equatable {
    var cutWords: Set<String> = []
    var cutPauses: Set<String> = []
    var query = ""
    var scope: ClosedRange<Int>?
    var lowConfidence = false
    var activeClipID: String?
    /// The playhead in take seconds: its paragraph's timecode is the current one (notes.md §2).
    var playhead: Double = 0
}

/// Builds the transcript's text storage and styles its spans (impl-plan §3.1, V8a).
///
/// `rebuild` reads the take into one `TranscriptParagraphContent` per display paragraph and
/// writes the storage only for the paragraphs whose content changed, one edit each, so a cut,
/// a correction or a fold edits one paragraph. More than `separateEdits` changed paragraphs
/// (Cut Fillers, Show Pauses) are written in one edit over their extent. The whole document
/// is written again only for a new take, a new paragraph list (an AI passage over a paragraph
/// break), a new text size, or a change to more than half the paragraphs (Show cuts, or a tab
/// switch between Full Take and a clip, since text outside the open clip shows no folds).
/// Span styles (`attributes`) survive a rebuild, and so do the TextKit rendering attributes
/// of the text no edit replaced: TextKit moves rendering attributes with the edits, and a
/// replaced paragraph's new layout fragment is styled from `attributes` by the
/// rendering-attributes validator when TextKit lays it out, so offscreen paragraphs cost
/// nothing. `update` styles the spans whose state changed and applies them at once, because
/// TextKit 2 calls the validator only for fragments it creates, not again after
/// `invalidateRenderingAttributes(for:)`.
@MainActor final class TranscriptRenderer {
    weak var text: TranscriptNSTextView?
    private(set) var appearance: TranscriptAppearance?
    /// Each span's style for `appearance`, by span id.
    private(set) var attributes: [String: [NSAttributedString.Key: Any]] = [:]
    /// The take as the last rebuild read it, and its paragraph split.
    private var transcript: [TimedWord] = []
    private var split: [Range<Int>] = []
    private var wordIndex: [String: Int] = [:]
    private var corrections: [String: String] = [:]
    /// The storage's paragraphs: what each shows and its length without the line break.
    private var blocks: [(content: TranscriptParagraphContent, length: Int)] = []
    /// The text size the storage was built at.
    private var builtTextSize: Double?
    private(set) var clipMarks: [String: TranscriptClipMark] = [:]
    private(set) var aiWordIDs: Set<String> = []
    /// The body font, whose glyphs the gutter centres its line boxes on.
    private(set) var font = DesignValues.transcriptFont(size: DesignValues.transcriptTextSize)
    /// The take's display paragraphs in text order; they never reflow per clip (notes.md §5).
    private(set) var paragraphs: [TranscriptParagraph] = []
    /// The paragraph holding the playhead, whose timecode reads in text.secondary.
    private(set) var currentParagraph: Int?
    /// Rebuilds that changed the text storage.
    private(set) var storageRevision = 0
    /// Rebuilds that wrote the whole document.
    private(set) var documentRebuilds = 0
    /// Paragraphs whose text a rebuild replaced; a whole-document rebuild counts every paragraph.
    private(set) var paragraphReplacements = 0
    /// Storage edits rebuilds made: one per replaced paragraph up to `separateEdits`, else one.
    private(set) var storageEdits = 0
    /// The most changed paragraphs a rebuild writes one edit each; more are written in one
    /// edit over their extent. A TextKit edit costs time in proportion to the document's
    /// rendering attributes, about 1 ms at 10,000 words, and one edit over many paragraphs
    /// about as much as four, mostly laying out the viewport again.
    nonisolated static let separateEdits = 4
    /// Span styles a rebuild computed: the spans of replaced paragraphs, and words that
    /// became or stopped being AI words. Untouched paragraphs keep theirs.
    private(set) var rebuildStyles = 0
    /// Rendering attributes set on spans, by `update` and by the validator.
    private(set) var attributeUpdates = 0
    /// Spans whose style a scope change recomputed: only those whose in-clip state changed.
    private(set) var scopeRestyles = 0
    private var gutterRevision = 0
    /// A fold's width and its dot's diameter at the built text size (`TranscriptFold`).
    private(set) var foldGap = TranscriptFold.gap(textSize: DesignValues.transcriptTextSize)
    private(set) var foldDot = TranscriptFold.dot(textSize: DesignValues.transcriptTextSize)
    /// Where the caret stands for the playhead (item 19): the start of the word playing or
    /// the next one, the fold that holds it, or the end of the take. Nil with no words.
    private(set) var caretOffset: Int?
    /// Times the caret moved; a playhead tick moves it and restyles no span.
    private(set) var caretMoves = 0
    private var caretRevision = -1
    /// The appearance the last whole-document write styled every span for, until `update`.
    private var wholeStyle: TranscriptAppearance?

    /// Writes the paragraphs whose content changed. `pending`, the appearance the next
    /// `update` brings, styles the replaced paragraphs, so a whole-document write for a tab
    /// switch styles each span once rather than once here and again in the scope restyle.
    func rebuild(model: EditorModel, appearance pending: TranscriptAppearance? = nil) {
        guard let text, let storage = text.textStorage else { return }
        let styling = pending ?? appearance
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.minimumLineHeight = (model.textSize * DesignValues.transcriptLineHeightRatio).rounded()
        paragraphStyle.maximumLineHeight = paragraphStyle.minimumLineHeight
        paragraphStyle.paragraphSpacing = DesignValues.transcriptParagraphGap
        paragraphStyle.baseWritingDirection = .natural
        font = DesignValues.transcriptFont(size: model.textSize)
        foldGap = TranscriptFold.gap(textSize: model.textSize)
        foldDot = TranscriptFold.dot(textSize: model.textSize)
        let body: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: DesignValues.nsColor("word.text"), .paragraphStyle: paragraphStyle]
        // Pause lengths in SF Mono 11 (notes.md §2), scaled with the text and a point above the baseline.
        let mono: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: VCType.small.size * model.textSize / DesignValues.transcriptTextSize, weight: .regular), .foregroundColor: DesignValues.nsColor("word.gone"),
                                                   .baselineOffset: 1, .paragraphStyle: paragraphStyle]
        var marker = body
        marker[.kern] = max(0, 27 - (" " as NSString).size(withAttributes: [.font: font]).width)
        marker[.foregroundColor] = NSColor.clear
        var fold = body
        fold[.kern] = TranscriptFold.kern(font: font, textSize: model.textSize)
        fold[.foregroundColor] = NSColor.clear
        let styles = BuildStyles(body: body, mono: mono, marker: marker, fold: fold)

        // Arrays compare their buffers first, so an unchanged take costs nothing here.
        let words = model.words
        let newTake = words != transcript
        if newTake { transcript = words; split = TranscriptParagraphs.split(words: words) }
        wordIndex = model.wordIndex
        corrections = model.project.edits.corrections
        let replacements = model.project.voiceLab.segments.filter(\.enabled)
        let ai = replacements.isEmpty ? [] : Set(words.lazy.filter { word in
            replacements.contains { word.start >= $0.replace.start && word.end <= $0.replace.end }
        }.map(\.id))
        let aiChanged = aiWordIDs.symmetricDifference(ai)
        aiWordIDs = ai
        let contents = contents(model: model, replacements: replacements)

        let documentLength = blocks.reduce(max(0, blocks.count - 1)) { $0 + $1.length }
        let structural = newTake || blocks.count != contents.count || storage.length != documentLength
            || zip(blocks, contents).contains { $0.content.firstWord != $1.firstWord }
        let changed = structural ? Array(contents.indices) : contents.indices.filter { blocks[$0].content != contents[$0] }
        let whole = structural || builtTextSize != model.textSize || changed.count * 2 > contents.count
        var styled = Set<String>()
        if whole {
            let built = contents.map { build($0, styles: styles) }
            let value = NSMutableAttributedString()
            var offset = 0
            var mapped: [(offset: Int, spans: [TranscriptSpan])] = []
            mapped.reserveCapacity(built.count)
            for (position, paragraph) in built.enumerated() {
                if position > 0 { value.append(NSAttributedString(string: "\n")); offset += 1 }
                mapped.append((offset, paragraph.spans))
                value.append(paragraph.text)
                offset += paragraph.text.length
            }
            // The map and styles describe the new text before the storage holds it, so a layout,
            // validator call or selection change during the edit reads them in step.
            if structural { attributes = [:]; currentParagraph = nil }
            else { for index in changed { for span in text.map.spans(inParagraph: index) { forget(span) } } }
            text.map = TranscriptRangeMap(paragraphs: mapped)
            blocks = zip(contents, built).map { ($0, $1.text.length) }
            // With the coming appearance every span is styled for it, so `update` restyles none;
            // without it the untouched paragraphs keep theirs.
            for index in pending == nil ? changed : Array(contents.indices) { styled.formUnion(style(paragraph: index, state: styling)) }
            editing = true
            storage.setAttributedString(value)
            finishEdits()
            documentRebuilds += 1
            paragraphReplacements += contents.count
            storageEdits += 1
        } else if let first = changed.first, let last = changed.last {
            // More than `separateEdits` paragraphs are written in one edit from the first to the
            // last, the paragraphs between copied unchanged, since every TextKit edit costs time
            // in proportion to the document's rendering attributes (Cut Fillers, Show Pauses).
            let start = offset(ofParagraph: first)
            let batch = changed.count > Self.separateEdits
                ? NSMutableAttributedString(attributedString: storage.attributedSubstring(from: NSRange(location: start, length: offset(ofParagraph: last) + blocks[last].length - start)))
                : nil
            let extent = NSRange(location: start, length: batch?.length ?? 0)
            // Last paragraph first, so each edit's offset is still the storage's.
            editing = true
            defer { finishEdits() }
            for index in changed.reversed() {
                let old = blocks[index], built = build(contents[index], styles: styles)
                let range = NSRange(location: offset(ofParagraph: index), length: old.length)
                for span in text.map.spans(inParagraph: index) { forget(span) }
                text.map.replace(paragraph: index, with: built.spans, lengthChange: built.text.length - old.length)
                blocks[index] = (contents[index], built.text.length)
                styled.formUnion(style(paragraph: index, state: styling))
                if let batch { batch.replaceCharacters(in: NSRange(location: range.location - start, length: range.length), with: built.text) }
                else { storage.replaceCharacters(in: range, with: built.text); storageEdits += 1 }
            }
            if let batch { storage.replaceCharacters(in: extent, with: batch); storageEdits += 1 }
            paragraphReplacements += changed.count
        }
        builtTextSize = model.textSize
        if !changed.isEmpty || whole { storageRevision += 1 }
        var offset = 0
        paragraphs = blocks.map { block in
            defer { offset += block.length + 1 }
            return TranscriptParagraph(offset: offset, firstWord: block.content.firstWord, start: block.content.start)
        }
        // A whole-document write styled every span for `pending`: an `update` to it restyles nothing.
        wholeStyle = whole ? pending : nil
        // Words that became or stopped being AI words outside the replaced paragraphs restyle now.
        if let styling {
            for id in aiChanged where !styled.contains(id) {
                guard let span = text.map.span(id: id) else { continue }
                attributes[span.id] = style(span, state: styling)
                rebuildStyles += 1
                apply(span)
            }
        }
        var marks: [String: TranscriptClipMark] = [:]
        for clip in model.sortedClips {
            guard let first = text.map.span(id: clip.startWordId), let last = text.map.span(id: clip.endWordId), first.range.location <= last.range.location else { continue }
            marks[clip.id] = TranscriptClipMark(range: NSRange(location: first.range.location, length: NSMaxRange(last.range) - first.range.location), suggested: clip.origin == .ai && !clip.selected)
        }
        let backdropChanged = appearance?.activeClipID.map { marks[$0] != clipMarks[$0] } ?? false
        clipMarks = marks
        // Keep All, or undoing it, turns the open clip's bar solid or dashed without any
        // storage edit or viewport layout, and `update` places the backdrop again only when
        // the scope or the open clip changes.
        if backdropChanged { text.updateBackdrop() }
    }

    private struct BuildStyles {
        let body: [NSAttributedString.Key: Any]
        let mono: [NSAttributedString.Key: Any]
        let marker: [NSAttributedString.Key: Any]
        let fold: [NSAttributedString.Key: Any]
    }

    /// The take's display paragraphs as content. Paragraphs come from the words alone
    /// (impl-plan item 22); a break inside an AI passage, which reads as one span, is not
    /// shown.
    ///
    /// In the open clip (every word in Full Take), each run of removed words and pauses is one
    /// fold (notes.md §5), or, under Show cuts and in the fold the selection starts or ends
    /// in (`EditorModel.openFoldEnds`), its words and pause lengths. A run reaches over the
    /// pauses that show nothing and stops at a paragraph break and at the open clip's edges,
    /// where its removals end, so the band never starts or ends inside a fold; other clips'
    /// edges do not split it. A comma that only exists because a filler follows folds with
    /// it (`DisplayPunctuation`). Uncut pauses show only with Show Pauses. Outside the open
    /// clip the words read as said: no folds, no struck words and no pauses.
    private func contents(model: EditorModel, replacements: [VoiceLabSegment]) -> [TranscriptParagraphContent] {
        let words = transcript
        let cutWords = model.cutWordIDs, cutPauses = model.cutPauseIDs, fillers = model.fillerCandidateIDs
        let showsCuts = model.showsCuts, openEnds = model.openFoldEnds, scope = model.scopeBounds
        let pauses = model.pauseByAfterIndex, showPauses = model.showPauses
        var segments: [String: VoiceLabSegment] = [:]
        for segment in replacements where segments[segment.replace.firstWordId] == nil { segments[segment.replace.firstWordId] = segment }
        func inside(_ position: Int) -> Bool { scope?.contains(position) ?? true }
        func removed(_ position: Int) -> Bool { inside(position) && cutWords.contains(words[position].id) && !aiWordIDs.contains(words[position].id) }
        /// The pause after a word, when it is in the open clip: between two of its words.
        func pause(after position: Int) -> Pause? {
            guard let pause = pauses[position], inside(position), inside(position + 1) else { return nil }
            return pause
        }
        func pausePiece(_ pause: Pause) -> TranscriptParagraphContent.Piece {
            let duration = toFixed1(pause.duration)
            return .init(kind: .pause, id: pause.id, text: "\(duration)\u{00A0}s", toolTip: "pause \(duration) seconds")
        }
        var result: [TranscriptParagraphContent] = []
        result.reserveCapacity(split.count)
        for paragraph in split {
            var content = TranscriptParagraphContent(firstWord: paragraph.lowerBound, start: words[paragraph.lowerBound].start)
            var position = paragraph.lowerBound
            /// A cut pause after the word just shown starts a run there.
            var pendingPause: Pause?
            while position < paragraph.upperBound || pendingPause != nil {
                // A run of removed words and pauses: from a cut pause after a kept word, or from a removed word.
                if pendingPause != nil || removed(position) {
                    var ids: [String] = [], items: [TranscriptParagraphContent.Piece] = [], filler = false
                    /// An uncut pause shown after the run (Show Pauses) ends it and follows the fold.
                    var trailing: TranscriptParagraphContent.Piece?
                    if let pause = pendingPause { ids.append(pause.id); items.append(pausePiece(pause)); pendingPause = nil }
                    while position < paragraph.upperBound, removed(position) {
                        let word = words[position]
                        ids.append(word.id)
                        items.append(.init(kind: .word, id: word.id, text: corrections[word.id] ?? word.text))
                        filler = filler || fillers.contains(word.id)
                        position += 1
                        // The pause after a removed word: a cut one joins the run, an uncut one shown with Show Pauses ends it.
                        guard let pause = pause(after: position - 1) else { continue }
                        if cutPauses.contains(pause.id) { ids.append(pause.id); items.append(pausePiece(pause)) }
                        else if showPauses { trailing = pausePiece(pause); break }
                    }
                    let open = showsCuts || openEnds.contains(where: ids.contains)
                    // The kept word before the run reads without a comma that only exists because a filler follows.
                    let wordFollows = position < paragraph.upperBound
                    if let last = content.pieces.last, last.kind == .word, !cutWords.contains(last.id), wordIndex[last.id].map(inside) == true,
                       DisplayPunctuation.foldsComma(last.text, foldRemovesFiller: filler, wordFollows: wordFollows) {
                        content.pieces[content.pieces.count - 1].text = DisplayPunctuation.withoutComma(last.text)
                        if open { content.pieces.append(.init(kind: .comma, id: "comma:\(last.id)", text: String(last.text.last ?? ","))) }
                    }
                    if open { content.pieces += items } else if let first = ids.first { content.pieces.append(.init(kind: .fold, id: first, text: TranscriptFold.text, ids: ids)) }
                    if let trailing { content.pieces.append(trailing) }
                    continue
                }
                let word = words[position]
                if let segment = segments[word.id] {
                    content.pieces.append(.init(kind: .aiMarker, id: "ai:\(segment.id)", text: " "))
                    if let replacement = segment.words {
                        let end = max(position + 1, (wordIndex[segment.replace.lastWordId] ?? position) + 1)
                        content.pieces.append(.init(kind: .replacement, id: word.id, text: replacement.map(\.text).joined(separator: " "), ids: words[position..<end].map(\.id)))
                        position = end
                        continue
                    }
                }
                let corrected = corrections[word.id]
                content.pieces.append(.init(kind: .word, id: word.id, text: corrected ?? word.text, toolTip: corrected != nil ? "Heard as: \(word.text)" : nil))
                position += 1
                if let pause = pause(after: position - 1) {
                    if cutPauses.contains(pause.id) {
                        // A cut pause starts a run, also at the paragraph's end.
                        pendingPause = pause
                    } else if showPauses { content.pieces.append(pausePiece(pause)) }
                }
            }
            result.append(content)
        }
        return result
    }

    /// A paragraph's text, without its line break, and its spans counted from its first
    /// character. A word is followed by a space unless a fold or its folded comma comes next:
    /// a fold replaces the word space (notes.md §5).
    private func build(_ content: TranscriptParagraphContent, styles: BuildStyles) -> (text: NSAttributedString, spans: [TranscriptSpan]) {
        let value = NSMutableAttributedString()
        var spans: [TranscriptSpan] = []
        spans.reserveCapacity(content.pieces.count)
        let pieces = content.pieces
        for (index, piece) in pieces.enumerated() {
            let range = NSRange(location: value.length, length: piece.text.utf16.count)
            let next = index + 1 < pieces.count ? pieces[index + 1].kind : nil
            let space = next != .fold && next != .comma ? " " : ""
            switch piece.kind {
            case .aiMarker:
                spans.append(TranscriptSpan(id: piece.id, range: range, pause: false, kind: .ai))
                value.append(NSAttributedString(string: piece.text, attributes: styles.marker))
            case .word, .replacement:
                spans.append(TranscriptSpan(id: piece.id, range: range, pause: false, ids: piece.ids))
                value.append(NSAttributedString(string: piece.text + space, attributes: styles.body))
            case .comma:
                spans.append(TranscriptSpan(id: piece.id, range: range, pause: false, kind: .comma))
                value.append(NSAttributedString(string: piece.text + space, attributes: styles.body))
            case .fold:
                spans.append(TranscriptSpan(id: piece.id, range: range, pause: false, ids: piece.ids, kind: .fold))
                value.append(NSAttributedString(string: TranscriptFold.joiner, attributes: styles.body))
                value.append(NSAttributedString(string: TranscriptFold.glyph, attributes: styles.fold))
                value.append(NSAttributedString(string: TranscriptFold.breakAfter, attributes: styles.body))
            case .pause:
                spans.append(TranscriptSpan(id: piece.id, range: range, pause: true))
                value.append(NSAttributedString(string: piece.text, attributes: styles.mono))
                value.append(NSAttributedString(string: space, attributes: styles.body))
            }
            if let toolTip = piece.toolTip { value.addAttribute(.toolTip, value: toolTip, range: range) }
        }
        return (value, spans)
    }

    /// The storage offset of a paragraph's first character, from the paragraphs before it.
    private func offset(ofParagraph index: Int) -> Int { blocks[..<index].reduce(index) { $0 + $1.length } }
    private func forget(_ span: TranscriptSpan) { attributes[span.id] = nil }
    /// Styles a replaced paragraph's spans for the current appearance; the validator applies
    /// them when TextKit lays out the paragraph's new fragment.
    private func style(paragraph index: Int, state: TranscriptAppearance?) -> [String] {
        guard let text, let state else { return [] }
        let spans = text.map.spans(inParagraph: index)
        for span in spans { attributes[span.id] = style(span, state: state) }
        rebuildStyles += spans.count
        return spans.flatMap { [$0.id] + $0.ids }
    }

    func update(_ state: TranscriptAppearance) {
        guard let text else { return }
        let previous = appearance
        appearance = state
        let changed: Set<String>
        var scopeRuns: [Range<Int>] = []
        let fresh = wholeStyle == state
        wholeStyle = nil
        if fresh {
            // Every span was styled for this state as the document was written; TextKit's
            // validator applies them as it lays the new fragments out.
            changed = []
        } else if let previous, previous.query == state.query, previous.lowConfidence == state.lowConfidence {
            var ids = previous.cutWords.symmetricDifference(state.cutWords)
            ids.formUnion(previous.cutPauses.symmetricDifference(state.cutPauses))
            changed = ids
            // A tab switch or a trim restyles only the words whose in-clip state changed (impl-plan §3.1).
            if previous.scope != state.scope { scopeRuns = Self.scopeDifference(previous.scope, state.scope, count: transcript.count) }
        } else { changed = Set(text.map.spans.map(\.id)) }
        for run in scopeRuns { restyle(run, state: state) }
        for id in changed {
            guard let span = text.map.span(id: id) else { continue }
            attributes[span.id] = style(span, state: state)
            apply(span)
        }
        // The caret follows the playhead (item 19) with no span restyled: only its view moves.
        // It goes first: finding its line may lay out a fragment, whose validator would drop
        // the gutter redraw below.
        let caret = caretOffset(atTime: state.playhead)
        if caret != caretOffset || caretRevision != storageRevision {
            caretOffset = caret
            caretRevision = storageRevision
            caretMoves += 1
            text.updateCaret()
        }
        let current = paragraph(atTime: state.playhead)
        if current != currentParagraph {
            let old = currentParagraph
            currentParagraph = current
            // The current timecode changes colour; restyled words already redraw their paragraphs.
            for index in [old, current].compactMap({ $0 }) { redisplay(paragraph: index) }
        }
        if previous == nil || previous?.scope != state.scope || previous?.activeClipID != state.activeClipID { text.updateBackdrop() }
        if !changed.isEmpty || !scopeRuns.isEmpty { text.needsDisplay = true }
    }

    /// The caret's place for take time `seconds`: the start of the first word that ends after
    /// it, which is the word playing or, in a gap, the next one; the fold or AI passage holding
    /// that word; or the end of the last word.
    func caretOffset(atTime seconds: Double) -> Int? {
        guard let text, !transcript.isEmpty else { return nil }
        var lower = 0, upper = transcript.count
        while lower < upper { let middle = (lower + upper) / 2; if transcript[middle].end <= seconds { lower = middle + 1 } else { upper = middle } }
        guard lower < transcript.count else { return text.map.span(id: transcript[transcript.count - 1].id).map { NSMaxRange($0.range) } }
        return text.map.span(id: transcript[lower].id)?.range.location
    }

    /// The word positions whose in-clip state differs between two scopes, nil being the whole
    /// take: at most two runs, in order.
    nonisolated static func scopeDifference(_ old: ClosedRange<Int>?, _ new: ClosedRange<Int>?, count: Int) -> [Range<Int>] {
        let all = 0..<max(0, count)
        func runs(_ scope: ClosedRange<Int>?) -> Range<Int> { scope.map { Range($0).clamped(to: all) } ?? all }
        let first = runs(old), second = runs(new)
        guard first != second else { return [] }
        guard first.overlaps(second) else { return [first, second].filter { !$0.isEmpty }.sorted { $0.lowerBound < $1.lowerBound } }
        let leading = min(first.lowerBound, second.lowerBound)..<max(first.lowerBound, second.lowerBound)
        let trailing = min(first.upperBound, second.upperBound)..<max(first.upperBound, second.upperBound)
        return [leading, trailing].filter { !$0.isEmpty }
    }

    /// Restyles the words at `run`, which all changed in-clip state the same way: one
    /// rendering-attribute call sets their text colour, then only the spans styled
    /// otherwise (cuts, pauses, AI words, matches) are applied one by one.
    private func restyle(_ run: Range<Int>, state: TranscriptAppearance) {
        guard let text, let manager = text.textLayoutManager, let first = text.map.span(id: transcript[run.lowerBound].id),
              let last = text.map.span(id: transcript[run.upperBound - 1].id) else { return }
        let range = NSRange(location: first.range.location, length: NSMaxRange(last.range) - first.range.location)
        let inside = state.scope.map { $0.contains(run.lowerBound) } ?? true
        let color = DesignValues.nsColor(inside ? "word.text" : "word.outside")
        if let textRange = textRange(range) { manager.setRenderingAttributes([.foregroundColor: color], for: textRange) }
        for span in text.map.intersecting(range) {
            let style = style(span, state: state)
            attributes[span.id] = style
            scopeRestyles += 1
            if style[.foregroundColor] as? NSColor !== color || style[.backgroundColor] != nil { apply(span) }
        }
    }

    /// The paragraph whose text holds the character at `offset`.
    func paragraph(atCharacter offset: Int) -> Int? {
        var lower = 0, upper = paragraphs.count
        while lower < upper { let middle = (lower + upper) / 2; if paragraphs[middle].offset <= offset { lower = middle + 1 } else { upper = middle } }
        return lower > 0 ? lower - 1 : nil
    }
    /// The paragraph holding take time `seconds`: the last one starting at or before it, else the first.
    func paragraph(atTime seconds: Double) -> Int? {
        guard !paragraphs.isEmpty else { return nil }
        var lower = 0, upper = paragraphs.count
        while lower < upper { let middle = (lower + upper) / 2; if paragraphs[middle].start <= seconds { lower = middle + 1 } else { upper = middle } }
        return max(0, lower - 1)
    }
    /// True when the paragraph holds a word of the open clip, or no clip is open (Full Take).
    func isInScope(paragraph index: Int) -> Bool {
        guard let scope = appearance?.scope else { return true }
        let words = paragraphs[index].firstWord..<(index + 1 < paragraphs.count ? paragraphs[index + 1].firstWord : transcript.count)
        return words.overlaps(Range(scope))
    }
    /// Redraws the paragraph's fragment, so its gutter shows the current timecode's colour.
    /// A rendering attribute change is what redraws a fragment; the next restyle of the
    /// first word drops the attribute again.
    private func redisplay(paragraph index: Int) {
        guard index < paragraphs.count, let manager = text?.textLayoutManager, let range = textRange(NSRange(location: paragraphs[index].offset, length: 1)) else { return }
        gutterRevision += 1
        manager.addRenderingAttribute(.vcGutter, value: gutterRevision, for: range)
    }
    /// Redraws the fragment holding a span, as a fold's hover needs: a rendering attribute
    /// change is what makes TextKit draw a fragment again.
    func redisplay(span id: String) {
        guard let span = text?.map.span(id: id), let manager = text?.textLayoutManager, let range = textRange(span.range) else { return }
        gutterRevision += 1
        manager.addRenderingAttribute(.vcGutter, value: gutterRevision, for: range)
    }
    /// The TextKit range of a storage range. Locations count from the document's start, so
    /// they are made when needed rather than kept across edits.
    private func textRange(_ range: NSRange) -> NSTextRange? {
        guard let content = text?.textLayoutManager?.textContentManager, let start = content.location(content.documentRange.location, offsetBy: range.location),
              let end = content.location(start, offsetBy: range.length) else { return nil }
        return NSTextRange(location: start, end: end)
    }

    /// A span's style (notes.md §5): words in `word.text` in the open clip and `word.outside`
    /// beyond it; a removed word shown under Show cuts in `word.gone` with a 1 pt strike in the
    /// same grey; pause lengths in `word.gone`, or `text.tertiary` for an uncut pause; a folded
    /// comma in `word.gone`. Folds and the AI marker draw their own marks over clear glyphs.
    /// Outside the open clip a cut word reads as said, unstruck.
    private func style(_ span: TranscriptSpan, state: TranscriptAppearance) -> [NSAttributedString.Key: Any] {
        switch span.kind {
        case .ai, .fold: return [.foregroundColor: NSColor.clear]
        case .comma: return [.foregroundColor: DesignValues.nsColor("word.gone")]
        case .text: break
        }
        let inside = state.scope.map { scope in wordIndex[span.id].map(scope.contains) ?? true } ?? true
        if aiWordIDs.contains(span.id) {
            // AI words read in t1 like proposed words (notes.md §5), and in word.outside beyond the clip.
            return [.foregroundColor: DesignValues.nsColor(inside ? "text.primary" : "word.outside"), .vcStrike: false, .vcUnderline: 3, .vcUnderlineColor: NSColor(DesignValues.accentText)]
        }
        if span.pause { return [.foregroundColor: DesignValues.nsColor(state.cutPauses.contains(span.id) ? "word.gone" : "text.tertiary")] }
        let cut = inside && state.cutWords.contains(span.id)
        var result: [NSAttributedString.Key: Any] = [.foregroundColor: DesignValues.nsColor(cut ? "word.gone" : inside ? "word.text" : "word.outside"), .vcStrike: cut]
        let word = wordIndex[span.id].map { transcript[$0] }
        if !cut, state.lowConfidence, let confidence = word?.conf, confidence < 0.6 {
            result[.vcUnderline] = 2
            result[.vcUnderlineColor] = DesignValues.nsColor("word.lowConfidence")
        }
        if !state.query.isEmpty, let word, (corrections[span.id] ?? word.text).localizedCaseInsensitiveContains(state.query) { result[.backgroundColor] = DesignValues.nsColor("pause.background") }
        return result
    }

    private func apply(_ span: TranscriptSpan) {
        guard let manager = text?.textLayoutManager, let attributes = attributes[span.id], let range = textRange(span.range) else { return }
        manager.setRenderingAttributes(attributes.filter { $0.key == .foregroundColor || $0.key == .backgroundColor }, for: range)
        attributeUpdates += 1
    }

    /// Applies the styles of the spans in a fragment TextKit just laid out: every paragraph
    /// when the document is new, and a replaced paragraph after a rebuild.
    /// TextKit can lay a fragment out while a storage edit is still being processed (a
    /// selection the edit moved asks for it), and the edit then drops what the validator
    /// applied. Those spans are applied again once the edit is done (`finishEdits`).
    func validate(_ fragment: NSTextLayoutFragment) {
        guard let manager = fragment.textLayoutManager, let content = manager.textContentManager, let elementRange = fragment.textElement?.elementRange, let text else { return }
        let offset = content.offset(from: content.documentRange.location, to: elementRange.location)
        let length = content.offset(from: elementRange.location, to: elementRange.endLocation)
        guard offset != NSNotFound, length > 0 else { return }
        for span in text.map.intersecting(NSRange(location: offset, length: length)) {
            apply(span)
            if editing { validatedDuringEdits.insert(span.id) }
        }
    }
    private var editing = false
    private var validatedDuringEdits: Set<String> = []
    /// Applies again the spans TextKit validated during the edits just made.
    private func finishEdits() {
        editing = false
        guard !validatedDuringEdits.isEmpty, let text else { return }
        for id in validatedDuringEdits { if let span = text.map.span(id: id) { apply(span) } }
        validatedDuringEdits = []
    }
    func hasCorrection(_ id: String) -> Bool { corrections[id] != nil }
}
