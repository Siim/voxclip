import AppKit
import VoxClipCore

extension NSAttributedString.Key {
    static let vcRounded = Self("voxclip.rounded")
    static let vcRadius = Self("voxclip.radius")
    static let vcTimecode = Self("voxclip.timecode")
    static let vcStrike = Self("voxclip.strike")
    static let vcUnderline = Self("voxclip.underline")
    static let vcUnderlineColor = Self("voxclip.underlineColor")
}

struct TranscriptSpan: Equatable {
    let id: String
    let range: NSRange
    let pause: Bool
    var ids: [String] = []
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
        return position < spans.count ? spans[position] : spans.last
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
}

@MainActor final class TranscriptRenderer {
    weak var text: TranscriptNSTextView?
    private(set) var appearance: TranscriptAppearance?
    private(set) var attributes: [String: [NSAttributedString.Key: Any]] = [:]
    private var ranges: [String: NSTextRange] = [:]
    private var words: [String: TimedWord] = [:]
    private var positions: [String: Int] = [:]
    private var corrected: Set<String> = []
    private var displayedText: [String: String] = [:]
    private(set) var storageRevision = 0
    private(set) var attributeUpdates = 0

    func rebuild(model: EditorModel) {
        guard let text, let storage = text.textStorage else { return }
        let value = NSMutableAttributedString(string: "")
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = (model.textSize * DesignValues.transcriptLineHeightRatio).rounded()
        paragraph.maximumLineHeight = paragraph.minimumLineHeight
        paragraph.paragraphSpacing = DesignValues.transcriptParagraphGap
        paragraph.baseWritingDirection = .natural
        let body: [NSAttributedString.Key: Any] = [.font: DesignValues.transcriptFont(size: model.textSize), .foregroundColor: DesignValues.nsColor("text.primary"), .paragraphStyle: paragraph]
        let mono: [NSAttributedString.Key: Any] = [.font: DesignValues.monoFont(11), .foregroundColor: DesignValues.nsColor("text.muted"), .paragraphStyle: paragraph]
        var spans: [TranscriptSpan] = []
        let transcript = model.words
        var position = 0
        words = [:]; positions = [:]; displayedText = [:]
        corrected = Set(model.project.edits.corrections.keys)
        while position < transcript.count {
            let word = transcript[position]
            let newParagraph = position == 0 || word.speaker != transcript[position - 1].speaker || (word.start - transcript[position - 1].end >= 1.5 && ".?!…".contains(transcript[position - 1].text.last ?? " "))
            if newParagraph && value.length > 0 { value.append(NSAttributedString(string: "\n")) }
            if !model.showCuts && model.cutWordIDs.contains(word.id) {
                var end = position + 1
                while end < transcript.count && model.cutWordIDs.contains(transcript[end].id) { end += 1 }
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
            if newParagraph {
                value.addAttribute(.vcTimecode, value: NSAttributedString(string: timecode(word.start), attributes: [.font: DesignValues.monoFont(10), .foregroundColor: DesignValues.nsColor("text.tertiary")]), range: NSRange(location: range.location, length: min(1, range.length)))
            }
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
        if let previous, previous.scope == state.scope, previous.query == state.query, previous.lowConfidence == state.lowConfidence {
            var ids = previous.cutWords.symmetricDifference(state.cutWords)
            ids.formUnion(previous.cutPauses.symmetricDifference(state.cutPauses))
            ids.formUnion(previous.fillers.symmetricDifference(state.fillers))
            if previous.playing != state.playing {
                if let id = previous.playing { ids.insert(id) }
                if let id = state.playing { ids.insert(id) }
            }
            changed = ids
        } else { changed = Set(text.map.spans.map(\.id)) }
        for id in changed {
            guard let span = text.map.span(id: id) else { continue }
            attributes[span.id] = style(span, state: state)
            apply(span)
        }
        if !changed.isEmpty { text.needsDisplay = true }
    }

    private func style(_ span: TranscriptSpan, state: TranscriptAppearance) -> [NSAttributedString.Key: Any] {
        let cut = span.pause ? state.cutPauses.contains(span.id) : state.cutWords.contains(span.id)
        var result: [NSAttributedString.Key: Any] = [.foregroundColor: DesignValues.nsColor(cut ? "word.cut" : "text.primary"), .vcStrike: cut]
        if !span.ids.isEmpty || span.pause {
            // Pause tokens and collapsed "⋯ N cut" runs are text.muted on pause.background, cut or
            // not; a cut pause keeps its cut.stroke strike.
            result[.foregroundColor] = DesignValues.nsColor("text.muted")
            result[.vcRounded] = DesignValues.nsColor("pause.background"); result[.vcRadius] = 6.0
            if !span.ids.isEmpty { result[.vcStrike] = false }
            return result
        }
        if let scope = state.scope, let position = positions[span.id], !scope.contains(position) { result[.foregroundColor] = DesignValues.nsColor("text.primary").withAlphaComponent(0.35) }
        if cut { result[.foregroundColor] = DesignValues.nsColor("word.cut") }
        if state.fillers.contains(span.id) && !cut {
            result[.vcUnderline] = 1
            result[.vcUnderlineColor] = DesignValues.nsColor("word.filler")
        } else if !cut, state.lowConfidence, let confidence = words[span.id]?.conf, confidence < 0.6 {
            result[.vcUnderline] = 2
            result[.vcUnderlineColor] = DesignValues.nsColor("word.lowConfidence")
        }
        if !state.query.isEmpty, displayedText[span.id]?.localizedCaseInsensitiveContains(state.query) == true { result[.backgroundColor] = DesignValues.nsColor("pause.background") }
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
