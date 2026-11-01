import AppKit
import VoxClipCore

/// The overview ruler at the transcript's right edge (notes.md §5), like an editor's
/// scrollbar: the whole take from top to bottom, with the visible window, the open clip, the
/// selection and AI words as marks by take time. It is decorative for VoiceOver, which reads
/// the same facts from the transcript, its rotors and the status bar, and it passes clicks on.
@MainActor final class TranscriptOverviewRuler: NSView {
    enum Kind: Equatable { case clip, ai, selection }
    /// A mark from `lower` to `upper`, as fractions of the take.
    struct Mark: Equatable {
        let kind: Kind
        let lower: Double
        let upper: Double
    }
    static let width: CGFloat = 10
    /// The gap between the ruler and the pane's right edge or the legacy scroller.
    static let edge: CGFloat = 2
    /// The take runs from 4 pt below the ruler's top to 4 pt above its bottom.
    static let inset: CGFloat = 4

    var marks: [Mark] = [] { didSet { if marks != oldValue { needsDisplay = true } } }
    /// The take time the visible lines span, as fractions of the take.
    var visibleSpan: ClosedRange<Double>? { didSet { if visibleSpan != oldValue { needsDisplay = true } } }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }

    /// The take's length: the source's, or the last word's end when that is later.
    static func duration(_ model: EditorModel) -> Double { max(model.sourceDuration, model.words.last?.end ?? 0) }

    /// The marks for the editor's state, computed once per update: the open clip, enabled AI
    /// passages and the selected words' extent.
    static func marks(model: EditorModel) -> [Mark] {
        let duration = duration(model), words = model.words
        guard duration > 0 else { return [] }
        var marks: [Mark] = []
        func add(_ kind: Kind, _ start: Double, _ end: Double) {
            marks.append(Mark(kind: kind, lower: min(1, max(0, start / duration)), upper: min(1, max(0, max(start, end) / duration))))
        }
        if let scope = model.scopeBounds, words.indices.contains(scope.lowerBound), words.indices.contains(scope.upperBound) {
            add(.clip, words[scope.lowerBound].start, words[scope.upperBound].end)
        }
        for segment in model.project.voiceLab.segments where segment.enabled { add(.ai, segment.replace.start, segment.replace.end) }
        let selected = model.selectedWordIDs.compactMap { model.index($0) }
        if let first = selected.min(), let last = selected.max() { add(.selection, words[first].start, words[last].end) }
        return marks
    }

    /// The rows a kind's marks fill in a ruler `height` tall, merged per point: each mark is
    /// at least 2 pt tall, and marks less than a point apart draw as one.
    static func rows(_ marks: [Mark], kind: Kind, height: CGFloat) -> [ClosedRange<CGFloat>] {
        let span = max(0, height - inset * 2)
        var rows: [ClosedRange<CGFloat>] = []
        for mark in marks.filter({ $0.kind == kind }).sorted(by: { $0.lower < $1.lower }) {
            let top = inset + span * mark.lower, bottom = max(inset + span * mark.upper, top + 2)
            if let last = rows.last, top <= last.upperBound + 1 { rows[rows.count - 1] = last.lowerBound...max(last.upperBound, bottom) }
            else { rows.append(top...bottom) }
        }
        return rows
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let ink = DesignValues.nsColor("text.primary").cgColor
        context.setFillColor(ink.copy(alpha: 0.03) ?? ink)
        context.fill(CGRect(x: 0, y: 0, width: 1, height: bounds.height))
        let span = max(0, bounds.height - Self.inset * 2)
        func fill(_ rect: CGRect, _ color: CGColor, radius: CGFloat) {
            context.setFillColor(color)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: min(radius, rect.width / 2), cornerHeight: min(radius, rect.height / 2), transform: nil))
            context.fillPath()
        }
        if let visible = visibleSpan {
            let top = Self.inset + span * visible.lowerBound
            fill(CGRect(x: 1, y: top, width: 8, height: max(2, span * (visible.upperBound - visible.lowerBound))), ink.copy(alpha: 0.06) ?? ink, radius: 2)
        }
        let clip = DesignValues.nsColor("clip.label").cgColor
        let layers: [(Kind, CGFloat, CGFloat, CGColor)] = [(.clip, 1, 2, clip.copy(alpha: 0.45) ?? clip), (.ai, 4, 5, DesignValues.nsColor("ai.tint").cgColor),
                                                           (.selection, 4, 5, DesignValues.nsColor("tint.default").cgColor)]
        for (kind, x, width, color) in layers {
            for row in Self.rows(marks, kind: kind, height: bounds.height) {
                fill(CGRect(x: x, y: row.lowerBound, width: width, height: row.upperBound - row.lowerBound), color, radius: 1)
            }
        }
    }
}

/// The transcript's scroll view. The overview ruler is a sibling of the scroller, not a
/// scroller (impl-plan item 24): the overlay scroller draws over it while scrolling, and with
/// "Always show scroll bars" the ruler sits left of the legacy scroller.
@MainActor final class TranscriptScrollView: NSScrollView {
    let overviewRuler = TranscriptOverviewRuler(frame: .zero)
    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(overviewRuler)
    }
    required init?(coder: NSCoder) { nil }
    override func tile() {
        super.tile()
        let legacy = scrollerStyle == .legacy && hasVerticalScroller && verticalScroller?.isHidden == false
        let right = legacy ? verticalScroller?.frame.minX ?? bounds.maxX : bounds.maxX
        let frame = NSRect(x: right - TranscriptOverviewRuler.edge - TranscriptOverviewRuler.width, y: 0, width: TranscriptOverviewRuler.width, height: bounds.height)
        if overviewRuler.frame != frame { overviewRuler.frame = frame }
        if let scroller = verticalScroller, let ruler = subviews.firstIndex(of: overviewRuler), let index = subviews.firstIndex(of: scroller), ruler > index {
            addSubview(overviewRuler, positioned: .below, relativeTo: scroller)
        }
    }
}
