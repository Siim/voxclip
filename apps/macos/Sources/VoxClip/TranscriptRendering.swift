import AppKit
import VoxClipCore

extension NSAttributedString.Key {
    static let vcRounded = Self("voxclip.rounded")
    static let vcRadius = Self("voxclip.radius")
    /// A rendering attribute set only to redraw a fragment whose gutter changed.
    static let vcGutter = Self("voxclip.gutter")
    static let vcStrike = Self("voxclip.strike")
    static let vcUnderline = Self("voxclip.underline")
    static let vcUnderlineColor = Self("voxclip.underlineColor")
}

enum TranscriptSpanKind: Equatable {
    case text
    case ai
}

struct TranscriptSpan: Equatable {
    let id: String
    let range: NSRange
    let pause: Bool
    var ids: [String] = []
    var kind: TranscriptSpanKind = .text
    var selectable: Bool { kind == .text }
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

struct TranscriptRangeMap {
    let spans: [TranscriptSpan]
    private let byID: [String: Int]
    init(spans: [TranscriptSpan]) {
        self.spans = spans
        var index: [String: Int] = [:]
        for (position, span) in spans.enumerated() {
            index[span.id] = position
            for id in span.ids { index[id] = position }
        }
        byID = index
    }
    func span(id: String) -> TranscriptSpan? { byID[id].map { spans[$0] } }
    private func lowerBound(_ offset: Int) -> Int {
        var lower = 0, upper = spans.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if NSMaxRange(spans[middle].range) <= offset { lower = middle + 1 } else { upper = middle }
        }
        return lower
    }
    func span(at offset: Int) -> TranscriptSpan? {
        let position = lowerBound(offset)
        if let next = spans.dropFirst(position).first(where: \.selectable) { return next }
        return spans.prefix(position).last(where: \.selectable)
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
    func intersecting(_ range: NSRange) -> ArraySlice<TranscriptSpan> {
        let lower = lowerBound(range.location)
        guard lower < spans.count else { return [] }
        var upper = lower
        while upper < spans.count && (spans[upper].range.location < NSMaxRange(range) || range.length == 0 && upper == lower) { upper += 1 }
        return spans[lower..<upper]
    }
}

struct TranscriptAppearance: Equatable {
    var cutWords: Set<String> = []
    var cutPauses: Set<String> = []
    var fillers: Set<String> = []
    var playing: String?
    var query = ""
    var scope: ClosedRange<Int>?
    var lowConfidence = false
    var activeClipID: String?
    /// The playhead in take seconds: its paragraph's timecode is the current one (notes.md §2).
    var playhead: Double = 0
}

@MainActor final class TranscriptRenderer {
    weak var text: TranscriptNSTextView?
    private(set) var appearance: TranscriptAppearance?
    private(set) var attributes: [String: [NSAttributedString.Key: Any]] = [:]
    private var ranges: [String: NSTextRange] = [:]
    private var words: [String: TimedWord] = [:]
    private var positions: [String: Int] = [:]
    private var wordIDs: [String] = []
    private var corrected: Set<String> = []
    private var displayedText: [String: String] = [:]
    private(set) var clipMarks: [String: TranscriptClipMark] = [:]
    private(set) var aiWordIDs: Set<String> = []
    /// The body font, whose glyphs the gutter centres its line boxes on.
    private(set) var font = DesignValues.transcriptFont(size: DesignValues.transcriptTextSize)
    /// The take's display paragraphs in text order; they never reflow per clip (notes.md §5).
    private(set) var paragraphs: [TranscriptParagraph] = []
    /// The paragraph holding the playhead, whose timecode reads in text.secondary.
    private(set) var currentParagraph: Int?
    private(set) var storageRevision = 0
    private(set) var attributeUpdates = 0
    /// Spans whose style a scope change recomputed: only those whose in-clip state changed.
    private(set) var scopeRestyles = 0
    private var gutterRevision = 0

    func rebuild(model: EditorModel) {
        guard let text, let storage = text.textStorage else { return }
        let value = NSMutableAttributedString(string: "")
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = (model.textSize * DesignValues.transcriptLineHeightRatio).rounded()
        paragraph.maximumLineHeight = paragraph.minimumLineHeight
        paragraph.paragraphSpacing = DesignValues.transcriptParagraphGap
        paragraph.baseWritingDirection = .natural
        font = DesignValues.transcriptFont(size: model.textSize)
        let body: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: DesignValues.nsColor("word.text"), .paragraphStyle: paragraph]
        let mono: [NSAttributedString.Key: Any] = [.font: DesignValues.monoFont(13), .foregroundColor: DesignValues.nsColor("text.muted"), .paragraphStyle: paragraph]
        var spans: [TranscriptSpan] = []
        let transcript = model.words
        let clips = model.sortedClips
        let clipStarts = Set(clips.map(\.startWordId)), clipEnds = Set(clips.map(\.endWordId))
        let breaks = Set(TranscriptParagraphs.split(words: transcript).map(\.lowerBound))
        let replacements = model.project.voiceLab.segments.filter(\.enabled)
        aiWordIDs = Set(transcript.filter { word in
            replacements.contains { segment in
                word.start >= segment.replace.start && word.end <= segment.replace.end
            }
        }.map(\.id))
        func marker(_ id: String, kind: TranscriptSpanKind, width: CGFloat, glyph: String = " ") {
            var attributes = body
            let glyphWidth = (glyph as NSString).size(withAttributes: [.font: DesignValues.transcriptFont(size: model.textSize)]).width
            attributes[.kern] = max(0, width - glyphWidth)
            attributes[.foregroundColor] = NSColor.clear
            spans.append(TranscriptSpan(id: id, range: NSRange(location: value.length, length: glyph.utf16.count), pause: false, kind: kind))
            value.append(NSAttributedString(string: glyph, attributes: attributes))
        }
        var position = 0
        var paragraphs: [TranscriptParagraph] = []
        words = [:]; positions = [:]; displayedText = [:]
        wordIDs = transcript.map(\.id)
        corrected = Set(model.project.edits.corrections.keys)
        while position < transcript.count {
            let word = transcript[position]
            // Paragraphs come from the words alone (impl-plan item 22). A break inside an AI
            // passage, which reads as one span, is not shown.
            if breaks.contains(position) {
                if value.length > 0 { value.append(NSAttributedString(string: "\n")) }
                paragraphs.append(TranscriptParagraph(offset: value.length, firstWord: position, start: word.start))
            }
            if let segment = replacements.first(where: { $0.replace.firstWordId == word.id }) {
                marker("ai:\(segment.id)", kind: .ai, width: 27)
            }
            if let segment = replacements.first(where: { $0.replace.firstWordId == word.id }), let replacement = segment.words {
                let end = (transcript.firstIndex { $0.id == segment.replace.lastWordId } ?? position) + 1
                let ids = transcript[position..<end].map(\.id)
                let content = replacement.map(\.text).joined(separator: " ")
                let range = NSRange(location: value.length, length: content.utf16.count)
                spans.append(TranscriptSpan(id: word.id, range: range, pause: false, ids: ids))
                value.append(NSAttributedString(string: content + " ", attributes: body))
                words[word.id] = word; positions[word.id] = position; displayedText[word.id] = content
                position = end
                continue
            }
            if !model.showCuts && model.cutWordIDs.contains(word.id) && !aiWordIDs.contains(word.id) {
                var end = position + 1
                while end < transcript.count && model.cutWordIDs.contains(transcript[end].id) && !breaks.contains(end) && !clipStarts.contains(transcript[end].id) && !clipEnds.contains(transcript[end - 1].id) { end += 1 }
                let token = "⋯ \(end - position) cut"
                spans.append(TranscriptSpan(id: word.id, range: NSRange(location: value.length, length: token.utf16.count), pause: false, ids: transcript[position..<end].map(\.id)))
                value.append(NSAttributedString(string: token + " ", attributes: mono))
                position = end
                continue
            }
            words[word.id] = word; positions[word.id] = position
            let content = model.text(word)
            displayedText[word.id] = content
            let range = NSRange(location: value.length, length: content.utf16.count)
            value.append(NSAttributedString(string: content + " ", attributes: body))
            if corrected.contains(word.id) { value.addAttribute(.toolTip, value: "Heard as: \(word.text)", range: range) }
            else if model.fillerIDs.contains(word.id) { value.addAttribute(.toolTip, value: "Filler · Delete to cut", range: range) }
            spans.append(TranscriptSpan(id: word.id, range: range, pause: false))
            if model.showPauses, let pause = model.pauseByAfterIndex[position] {
                let duration = toFixed1(pause.duration)
                let token = "‖\u{00A0}\(duration)s"
                let range = NSRange(location: value.length, length: token.utf16.count)
                value.append(NSAttributedString(string: token, attributes: mono))
                value.addAttribute(.toolTip, value: "pause \(duration) seconds", range: range)
                value.append(NSAttributedString(string: " ", attributes: body))
                spans.append(TranscriptSpan(id: pause.id, range: range, pause: true))
            }
            position += 1
        }
        let oldFont = storage.length > 0 ? storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont : nil
        if storage.length == 0 || oldFont?.pointSize != CGFloat(model.textSize) {
            storage.setAttributedString(value)
        } else {
            Self.replaceChangedParagraphs(storage, with: value)
        }
        text.map = TranscriptRangeMap(spans: spans)
        self.paragraphs = paragraphs
        var marks: [String: TranscriptClipMark] = [:]
        for clip in clips {
            guard let first = text.map.span(id: clip.startWordId), let last = text.map.span(id: clip.endWordId), first.range.location <= last.range.location else { continue }
            marks[clip.id] = TranscriptClipMark(range: NSRange(location: first.range.location, length: NSMaxRange(last.range) - first.range.location), suggested: clip.origin == .ai && !clip.selected)
        }
        clipMarks = marks
        ranges = [:]; attributes = [:]; appearance = nil
        if let manager = text.textLayoutManager { manager.invalidateRenderingAttributes(for: manager.documentRange) }
        storageRevision += 1
    }

    private static func replaceChangedParagraphs(_ storage: NSTextStorage, with value: NSAttributedString) {
        let old = Array(storage.string.utf16), new = Array(value.string.utf16)
        guard old != new else { return }
        var prefix = 0
        while prefix < min(old.count, new.count), old[prefix] == new[prefix] { prefix += 1 }
        while prefix > 0 && old[prefix - 1] != 10 { prefix -= 1 }
        var suffix = 0
        while suffix < min(old.count, new.count) - prefix, old[old.count - suffix - 1] == new[new.count - suffix - 1] { suffix += 1 }
        while suffix > 0 && old[old.count - suffix - 1] != 10 { suffix -= 1 }
        storage.replaceCharacters(in: NSRange(location: prefix, length: old.count - prefix - suffix), with: value.attributedSubstring(from: NSRange(location: prefix, length: new.count - prefix - suffix)))
    }

    func update(_ state: TranscriptAppearance) {
        guard let text else { return }
        let previous = appearance
        appearance = state
        let changed: Set<String>
        var scopeRuns: [Range<Int>] = []
        if let previous, previous.query == state.query, previous.lowConfidence == state.lowConfidence {
            var ids = previous.cutWords.symmetricDifference(state.cutWords)
            ids.formUnion(previous.cutPauses.symmetricDifference(state.cutPauses))
            ids.formUnion(previous.fillers.symmetricDifference(state.fillers))
            if previous.playing != state.playing {
                if let id = previous.playing { ids.insert(id) }
                if let id = state.playing { ids.insert(id) }
            }
            changed = ids
            // A tab switch or a trim restyles only the words whose in-clip state changed (impl-plan §3.1).
            if previous.scope != state.scope { scopeRuns = Self.scopeDifference(previous.scope, state.scope, count: wordIDs.count) }
        } else { changed = Set(text.map.spans.map(\.id)) }
        for run in scopeRuns { restyle(run, state: state) }
        for id in changed {
            guard let span = text.map.span(id: id) else { continue }
            attributes[span.id] = style(span, state: state)
            apply(span)
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
        guard let text, let manager = text.textLayoutManager, let first = text.map.span(id: wordIDs[run.lowerBound]),
              let last = text.map.span(id: wordIDs[run.upperBound - 1]) else { return }
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
    /// The paragraph's characters, up to the next paragraph's first.
    func characters(ofParagraph index: Int) -> NSRange {
        let end = index + 1 < paragraphs.count ? paragraphs[index + 1].offset : (text?.textStorage?.length ?? paragraphs[index].offset)
        return NSRange(location: paragraphs[index].offset, length: max(0, end - paragraphs[index].offset))
    }
    /// True when the paragraph holds a word of the open clip, or no clip is open (Full Take).
    func isInScope(paragraph index: Int) -> Bool {
        guard let scope = appearance?.scope else { return true }
        let words = paragraphs[index].firstWord..<(index + 1 < paragraphs.count ? paragraphs[index + 1].firstWord : wordIDs.count)
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
    private func textRange(_ range: NSRange) -> NSTextRange? {
        guard let content = text?.textLayoutManager?.textContentManager, let start = content.location(content.documentRange.location, offsetBy: range.location),
              let end = content.location(start, offsetBy: range.length) else { return nil }
        return NSTextRange(location: start, end: end)
    }

    private func style(_ span: TranscriptSpan, state: TranscriptAppearance) -> [NSAttributedString.Key: Any] {
        if !span.selectable { return [.foregroundColor: NSColor.clear] }
        let inside = state.scope.map { scope in positions[span.id].map(scope.contains) ?? true } ?? true
        if aiWordIDs.contains(span.id) {
            // AI words read in t1 like proposed words (notes.md §5), and in word.outside beyond the clip.
            var result: [NSAttributedString.Key: Any] = [.foregroundColor: DesignValues.nsColor(inside ? "text.primary" : "word.outside"),
                .vcStrike: false, .vcUnderline: 3, .vcUnderlineColor: NSColor(DesignValues.accentText)]
            if state.playing.map({ span.id == $0 || span.ids.contains($0) }) == true {
                result[.vcRounded] = DesignValues.nsColor("word.playingBackground"); result[.vcRadius] = 4.0
                result[.foregroundColor] = DesignValues.nsColor("word.playingForeground")
            }
            return result
        }
        let cut = span.pause ? state.cutPauses.contains(span.id) : state.cutWords.contains(span.id)
        var result: [NSAttributedString.Key: Any] = [.foregroundColor: DesignValues.nsColor(cut ? "word.cut" : inside ? "word.text" : "word.outside"), .vcStrike: cut]
        if !span.ids.isEmpty || span.pause {
            // Pause tokens and collapsed "⋯ N cut" runs are text.muted on pause.background, cut or
            // not; a cut pause keeps its cut.stroke strike.
            result[.foregroundColor] = DesignValues.nsColor("text.muted")
            if cut || !span.ids.isEmpty { result[.vcRounded] = DesignValues.nsColor("pause.background"); result[.vcRadius] = 6.0 }
            if !span.ids.isEmpty { result[.vcStrike] = false }
            return result
        }
        if state.fillers.contains(span.id) && !cut {
            result[.vcUnderline] = 1
            result[.vcUnderlineColor] = DesignValues.nsColor("word.filler")
        } else if !cut, state.lowConfidence, let confidence = words[span.id]?.conf, confidence < 0.6 {
            result[.vcUnderline] = 2
            result[.vcUnderlineColor] = DesignValues.nsColor("word.lowConfidence")
        }
        if !state.query.isEmpty, displayedText[span.id]?.localizedCaseInsensitiveContains(state.query) == true { result[.backgroundColor] = DesignValues.nsColor("pause.background") }
        if aiWordIDs.contains(span.id) {
            result[.vcUnderline] = 3
            result[.vcUnderlineColor] = NSColor(DesignValues.accentText)
        }
        if state.playing == span.id {
            result[.vcRounded] = DesignValues.nsColor("word.playingBackground"); result[.vcRadius] = 4.0
            result[.foregroundColor] = DesignValues.nsColor("word.playingForeground")
        }
        return result
    }

    private func apply(_ span: TranscriptSpan) {
        guard let manager = text?.textLayoutManager, let content = manager.textContentManager, let attributes = attributes[span.id] else { return }
        let range: NSTextRange
        if let cached = ranges[span.id] { range = cached }
        else {
            guard let start = content.location(content.documentRange.location, offsetBy: span.range.location), let end = content.location(start, offsetBy: span.range.length), let value = NSTextRange(location: start, end: end) else { return }
            range = value; ranges[span.id] = range
        }
        manager.setRenderingAttributes(attributes.filter { $0.key == .foregroundColor || $0.key == .backgroundColor }, for: range)
        attributeUpdates += 1
    }

    func validate(_ fragment: NSTextLayoutFragment) {
        guard let manager = fragment.textLayoutManager, let content = manager.textContentManager, let elementRange = fragment.textElement?.elementRange, let text else { return }
        let offset = content.offset(from: content.documentRange.location, to: elementRange.location)
        let length = content.offset(from: elementRange.location, to: elementRange.endLocation)
        guard offset != NSNotFound, length > 0 else { return }
        for span in text.map.intersecting(NSRange(location: offset, length: length)) { apply(span) }
    }
    func hasCorrection(_ id: String) -> Bool { corrected.contains(id) }
}
