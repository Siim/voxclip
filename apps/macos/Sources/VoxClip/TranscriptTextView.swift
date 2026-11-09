import SwiftUI
import AppKit
import CoreText
import VoxClipCore

@MainActor struct TranscriptTextView: NSViewRepresentable {
    let model: EditorModel
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeNSView(context: Context) -> TranscriptScrollView { Self.makeScrollView(model: model, coordinator: context.coordinator) }
    /// The transcript's scroll view, text view, backdrop and overview ruler, as the editor
    /// shows them; the DEBUG pixel and performance checks build theirs here too.
    static func makeScrollView(model: EditorModel, coordinator: Coordinator, width: CGFloat = 640, height: CGFloat = 480) -> TranscriptScrollView {
        let scroll = TranscriptScrollView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        let text = TranscriptNSTextView(usingTextLayoutManager: true)
        text.frame = NSRect(x: 0, y: 0, width: width, height: height)
        text.minSize = .zero; text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.model = model; text.delegate = coordinator; text.textLayoutManager?.delegate = coordinator
        text.isEditable = false; text.isSelectable = true; text.isRichText = true; text.drawsBackground = false
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false; text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = false
        // Text starts at the gutter's edge, x 80 (notes.md §5).
        text.textContainer?.lineFragmentPadding = 0
        text.textContainer?.containerSize = NSSize(width: TranscriptNSTextView.measure(forPane: width), height: CGFloat.greatestFiniteMagnitude)
        text.textContainerInset = NSSize(width: TranscriptGutter.width, height: 8)
        // No native selection drawing: the selection layer draws it at text height (notes.md §5).
        // An empty dictionary is what stops TextKit 2 from filling the selection; a clear
        // background colour does not.
        text.selectedTextAttributes = [:]
        text.setAccessibilityLabel("Transcript. Select words, then Delete to cut. Return corrects spelling.")
        text.updateRotors(proposal: false)
        text.configureAccessibilityActions()
        text.installBackdrop()
        text.installSelectionLayer()
        text.installProposalLayer()
        text.relayViewportLayout()
        scroll.documentView = text; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        text.observeSelectionScrolling(scroll)
        coordinator.text = text
        let renderer = coordinator.renderer
        renderer.text = text
        text.renderer = renderer
        text.textLayoutManager?.renderingAttributesValidator = { [weak renderer] _, fragment in
            MainActor.assumeIsolated { renderer?.validate(fragment) }
        }
        return scroll
    }
    func updateNSView(_ scroll: TranscriptScrollView, context: Context) {
        guard let text = scroll.documentView as? TranscriptNSTextView else { return }
        let coordinator = context.coordinator
        coordinator.updating = true
        Self.render(model, coordinator: coordinator)
        scroll.overviewRuler.marks = TranscriptOverviewRuler.marks(model: model)
        Self.select(model: model, in: text)
        coordinator.updating = false; text.updateCorrection(); text.refreshSelectionBar()
        Self.showProposal(model, coordinator: coordinator, in: text)
        Self.scrollIfRequested(model, coordinator: coordinator, in: text)
    }

    /// Scope and Outline jumps share the existing scroll API; neither changes word selection.
    static func scrollIfRequested(_ model: EditorModel, coordinator: Coordinator, in text: TranscriptNSTextView) {
        if coordinator.scopeScrollRevision != model.scopeScrollRevision {
            coordinator.scopeScrollRevision = model.scopeScrollRevision
            let id = model.outlineScrollWordID ?? model.activeClip?.startWordId ?? model.words.first?.id
            if let id, let span = text.map.span(id: id) {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = EditorAccessibilityPolicy.system.transcriptScrollDuration
                    text.scrollRangeToVisible(span.range)
                }
            }
        }
    }

    /// Renders the model as the editor shows it: the paragraphs whose content changed (all
    /// with `force`), styled for the new appearance, then the styles that changed, the caret
    /// and the current paragraph. The DEBUG checks render through here too.
    static func render(_ model: EditorModel, coordinator: Coordinator, force: Bool = false) {
        let wasUpdating = coordinator.updating
        coordinator.updating = true
        defer { coordinator.updating = wasUpdating }
        let content = Coordinator.Content(model: model)
        let appearance = TranscriptAppearance(cutWords: model.cutWordIDs, cutPauses: model.cutPauseIDs, query: model.query, scope: model.scopeBounds, lowConfidence: model.app.bool("general.showLowConfidence"),
                                              activeClipID: model.activeClip?.id, playhead: model.sourceTime, changesPending: content.proposal?.pending ?? false)
        if force || coordinator.content != content {
            coordinator.content = content
            coordinator.renderer.rebuild(model: model, appearance: appearance)
        }
        coordinator.renderer.update(appearance)
    }
    /// Shows the model's selection in the text view and its selection layer: the selected
    /// words and pauses from the first to the last, less what cannot be selected, or none.
    static func select(model: EditorModel, in text: TranscriptNSTextView) {
        let selected = (model.selectedWordIDs.union(model.selectedPauseIDs)).compactMap { text.map.span(id: $0) }.filter(\.selectable).sorted { $0.range.location < $1.range.location }
        if let first = selected.first, let last = selected.last {
            let range = NSRange(location: first.range.location, length: NSMaxRange(last.range) - first.range.location)
            let ranges = text.map.selectionRanges(in: range).map { NSValue(range: $0) }
            if text.selectedRanges != ranges { text.selectedRanges = ranges }
        } else if let current = text.selectedRanges.first?.rangeValue, text.selectedRanges.count > 1 || current.length > 0 {
            text.selectedRanges = [NSValue(range: NSRange(location: current.location, length: 0))]
        }
        text.updateSelectionLayer()
    }
    /// After a render: the focused change's buttons, the Proposed changes rotor and, when the
    /// focus moved by key or rotor, the change scrolled into view.
    static func showProposal(_ model: EditorModel, coordinator: Coordinator, in text: TranscriptNSTextView) {
        text.updateRotors(proposal: coordinator.content?.proposal != nil)
        text.updateProposalButtons()
        text.updateThread()
        guard let proposal = model.proposal, coordinator.revealRevision != proposal.revealRevision else { return }
        coordinator.revealRevision = proposal.revealRevision
        if let focused = coordinator.content?.proposal?.focused, let range = coordinator.renderer.changeRange(focused) {
            text.scrollRangeToVisible(range)
            text.updateProposalButtons()
        }
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate, @preconcurrency NSTextLayoutManagerDelegate {
        /// What the text shows, beyond the take's words: when it changes, `rebuild` writes the
        /// paragraphs whose content changed. Folds follow the cuts, the open clip and the
        /// selection's removed ends, so all three are part of it, and so is a proposal's state;
        /// a playhead tick is not.
        struct Content: Equatable {
            var layout: Int, showsCuts: Bool, showsSurroundingContext: Bool, showPauses: Bool, textSize: Double, pauseThreshold: Double
            var scope: ClosedRange<Int>?, openEnds: [String], cutWords: Set<String>, cutPauses: Set<String>
            var proposal: TranscriptProposalDisplay?
            /// The focused change's Rewrite thread and the room it needs under its paragraph.
            var thread: EditorModel.RewriteThreadSlot?
            @MainActor init(model: EditorModel) {
                layout = model.transcriptLayoutRevision; showsCuts = model.showsCuts; showPauses = model.showPauses; textSize = model.textSize
                showsSurroundingContext = model.showsSurroundingContext
                pauseThreshold = model.project.edits.pauseThresholdSeconds; scope = model.scopeBounds; openEnds = model.openFoldEnds
                cutWords = model.cutWordIDs; cutPauses = model.cutPauseIDs
                proposal = model.proposalDisplay
                thread = model.rewriteThreadSlot(proposal)
            }
        }
        let model: EditorModel
        weak var text: TranscriptNSTextView?
        var content: Content?, updating = false
        var scopeScrollRevision = 0, revealRevision = 0
        let renderer = TranscriptRenderer()
        init(model: EditorModel) { self.model = model }
        func textView(_ textView: NSTextView, willChangeSelectionFromCharacterRanges old: [NSValue], toCharacterRanges proposed: [NSValue]) -> [NSValue] {
            guard !updating, let text = textView as? TranscriptNSTextView else { return proposed }
            let ranges = proposed.flatMap { text.map.selectionRanges(in: $0.rangeValue) }
            return ranges.isEmpty ? old : ranges.map { NSValue(range: $0) }
        }
        /// The selection's words and pauses: those of its selectable spans and of the folds
        /// between them, which `selectionRanges` leaves out of the ranges, so a drag across a
        /// fold holds what ⇧→ over it holds (notes.md §5).
        func textViewDidChangeSelection(_ notification: Notification) {
            guard !updating, let text else { return }
            let spans = text.map.selected(text.selectedRanges.map(\.rangeValue))
            var words = Set<String>(), pauses = Set<String>()
            for span in spans {
                if span.kind == .fold {
                    for id in span.ids { if model.pauseIndex[id] != nil { pauses.insert(id) } else { words.insert(id) } }
                } else if span.pause { pauses.insert(span.id) } else { words.formUnion(span.ids.isEmpty ? [span.id] : span.ids) }
            }
            model.selectedWordIDs = words
            model.selectedPauseIDs = pauses
            text.updateSelectionLayer()
            text.selectionDidChange()
            if !model.isPlaying, let id = spans.first?.id, let position = model.index(id) { model.seek(source: model.words[position].start) }
        }
        func textLayoutManager(_ manager: NSTextLayoutManager, textLayoutFragmentFor location: any NSTextLocation, in element: NSTextElement) -> NSTextLayoutFragment {
            let fragment = TranscriptLayoutFragment(textElement: element, range: element.elementRange)
            fragment.renderer = renderer
            return fragment
        }
    }
}

private struct TranscriptDrawingContext: @unchecked Sendable { let value: CGContext }
private struct TranscriptDrawingFragment: @unchecked Sendable { let value: TranscriptLayoutFragment }

@MainActor final class TranscriptLayoutFragment: NSTextLayoutFragment, @unchecked Sendable {
    weak var renderer: TranscriptRenderer?
    /// Reaches left over the gutter, where the fragment draws its timecode and line glyphs.
    override var renderingSurfaceBounds: CGRect {
        let reach = layoutFragmentFrame.minX + TranscriptGutter.width
        return super.renderingSurfaceBounds.union(CGRect(x: -reach, y: 0, width: reach, height: layoutFragmentFrame.height))
    }
    override func draw(at point: CGPoint, in context: CGContext) {
        let drawingContext = TranscriptDrawingContext(value: context)
        let fragment = TranscriptDrawingFragment(value: self)
        MainActor.assumeIsolated { fragment.value.drawTints(at: point, in: drawingContext.value) }
        super.draw(at: point, in: context)
        MainActor.assumeIsolated { fragment.value.drawDecorations(at: point, in: drawingContext.value) }
    }
    /// Behind the glyphs: a proposed change's new words on `change.add` at 19 % (notes.md §5),
    /// at the text's height, radius 2, one rect per line a run covers, without a trailing space.
    /// Tints are drawn, not background attributes, which would fill the line height square.
    private func drawTints(at point: CGPoint, in context: CGContext) {
        guard let renderer, let text = renderer.text, let content = textLayoutManager?.textContentManager, let elementRange = textElement?.elementRange else { return }
        let offset = content.offset(from: content.documentRange.location, to: elementRange.location)
        let font = renderer.font
        var rects: [CGRect] = []
        for line in textLineFragments {
            let lineRange = NSRange(location: offset + line.characterRange.location, length: line.characterRange.length)
            let string = line.attributedString.string as NSString
            for span in text.map.intersecting(lineRange) where span.kind == .inserted {
                let intersection = NSIntersectionRange(span.range, lineRange)
                guard intersection.length > 0 else { continue }
                var upper = NSMaxRange(intersection) - offset
                while upper > intersection.location - offset, upper - 1 < string.length, string.character(at: upper - 1) == 0x20 { upper -= 1 }
                let start = text.glyphX(line, local: intersection.location - offset), end = text.glyphX(line, local: upper)
                let baseline = point.y + line.typographicBounds.minY + line.glyphOrigin.y
                rects.append(CGRect(x: point.x + line.typographicBounds.minX + start, y: baseline - font.ascender, width: max(1, end - start), height: font.ascender - font.descender))
            }
        }
        guard !rects.isEmpty else { return }
        context.saveGState()
        context.setFillColor(DesignValues.nsColor("change.add").withAlphaComponent(TranscriptProposalLayer.addTint).cgColor)
        for rect in rects { context.addPath(CGPath(roundedRect: rect, cornerWidth: 2, cornerHeight: 2, transform: nil)) }
        context.fillPath()
        context.restoreGState()
    }
    /// Over the glyphs: the gutter, fold dots, the strike of removed words under Show cuts,
    /// underlines, correction dots and the AI marker. No playing-word fill and no filler
    /// underline (impl-plan items 11 and 19).
    private func drawDecorations(at point: CGPoint, in context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        guard let renderer, let text = renderer.text, let content = textLayoutManager?.textContentManager, let element = textElement, let elementRange = element.elementRange else { return }
        let offset = content.offset(from: content.documentRange.location, to: elementRange.location)
        let lines = textLineFragments
        // Each line's proposed-change marks, for its change bar and glyph and its neighbours' bars.
        let marks: [[TranscriptChangeMark]] = lines.map { line in
            let lineRange = NSRange(location: offset + line.characterRange.location, length: line.characterRange.length)
            return text.map.intersecting(lineRange).compactMap { NSIntersectionRange($0.range, lineRange).length > 0 ? $0.change : nil }
        }
        for (number, line) in lines.enumerated() {
            let lineRange = NSRange(location: offset + line.characterRange.location, length: line.characterRange.length)
            drawGutter(line: line, lineRange: lineRange, offset: offset, marks: marks[number], above: number > 0 ? marks[number - 1] : [],
                       below: number + 1 < lines.count ? marks[number + 1] : [], at: point, renderer: renderer, text: text, context: context)
            let baseline = point.y + line.typographicBounds.minY + line.glyphOrigin.y
            for span in text.map.intersecting(lineRange) {
                let intersection = NSIntersectionRange(span.range, lineRange)
                guard intersection.length > 0 else { continue }
                // A word after a fold starts the fold's full kern after its glyph (`glyphX`).
                let start = text.glyphX(line, local: intersection.location - offset)
                let end = text.glyphX(line, local: NSMaxRange(intersection) - offset)
                let rect = CGRect(x: point.x + line.typographicBounds.minX + min(start, end) - 2, y: point.y + line.typographicBounds.minY, width: max(4, abs(end - start) + 4), height: line.typographicBounds.height)
                switch span.kind {
                case .ai: drawMarker(span, rect: rect, renderer: renderer, context: context); continue
                case .inserted, .spacer: continue
                case .fold:
                    let glyph = span.range.location + TranscriptFold.glyphOffset
                    guard NSLocationInRange(glyph, lineRange) else { continue }
                    let left = point.x + line.typographicBounds.minX + line.locationForCharacter(at: glyph - offset).x
                    drawFold(centre: CGPoint(x: left + renderer.foldGap / 2, y: baseline - renderer.font.xHeight / 2), diameter: renderer.foldDot, hovered: text.hoveredFold == span.id, context: context)
                    continue
                case .comma, .text: break
                }
                let attributes = renderer.attributes[span.id] ?? [:]
                let fontIndex = min(line.attributedString.length - 1, max(0, intersection.location - offset))
                let font = line.attributedString.attribute(.font, at: fontIndex, effectiveRange: nil) as? NSFont ?? DesignValues.transcriptFont(size: DesignValues.transcriptTextSize)
                let lower = rect.minX + 2, upper = rect.maxX - 2
                if attributes[.vcStrike] as? Bool == true {
                    // A removed word under Show cuts: a 1 pt strike in its own grey (notes.md §5).
                    context.setStrokeColor(DesignValues.nsColor("word.gone").cgColor)
                    context.setLineWidth(1)
                    context.setLineDash(phase: 0, lengths: [])
                    context.move(to: CGPoint(x: lower, y: baseline - font.xHeight / 2))
                    context.addLine(to: CGPoint(x: upper, y: baseline - font.xHeight / 2)); context.strokePath()
                }
                if let underline = attributes[.vcUnderline] as? Int, let color = attributes[.vcUnderlineColor] as? NSColor {
                    let row = baseline - font.underlinePosition + 1
                    context.setStrokeColor(color.cgColor); context.setLineWidth(1)
                    context.setLineCap(.butt)
                    // An excluded change's place is dotted; low confidence and AI words are dashed.
                    context.setLineDash(phase: 0, lengths: underline == TranscriptChangeMark.slotUnderline ? [1, 2] : [4, 3])
                    context.move(to: CGPoint(x: lower, y: row)); context.addLine(to: CGPoint(x: upper, y: row)); context.strokePath()
                }
                if renderer.hasCorrection(span.id), intersection.location == span.range.location {
                    context.setFillColor(DesignValues.nsColor("word.correctionDot").cgColor)
                    context.fillEllipse(in: CGRect(x: point.x + line.typographicBounds.minX + start, y: rect.maxY - 2, width: 2, height: 2))
                }
            }
        }
    }

    /// A fold's dot (notes.md §5): 5 pt of `fold.dot` centred in the fold on the x-height;
    /// under the pointer `text.secondary` with a 3 pt halo of it at 18%.
    private func drawFold(centre: CGPoint, diameter: CGFloat, hovered: Bool, context: CGContext) {
        let radius = diameter / 2
        if hovered {
            let halo = radius + 3
            context.setFillColor(DesignValues.nsColor("text.secondary").withAlphaComponent(0.18).cgColor)
            context.fillEllipse(in: CGRect(x: centre.x - halo, y: centre.y - halo, width: halo * 2, height: halo * 2))
        }
        context.setFillColor(DesignValues.nsColor(hovered ? "text.secondary" : "fold.dot").cgColor)
        context.fillEllipse(in: CGRect(x: centre.x - radius, y: centre.y - radius, width: diameter, height: diameter))
    }

    /// The gutter of one line (notes.md §5): the paragraph's timecode on its first line,
    /// right-aligned at 42 in SF Mono 11 (gutter.text in the open clip, gutter.textOut
    /// outside, text.secondary for the playhead's paragraph); the line's one glyph at 49–63,
    /// a shown change's kind (voice waveform > pencil > scissors, in text.tertiary) above the
    /// AI voice waveform; and at 66 the 3 pt `change.add` bar on every line a pending change
    /// touches, the focused change's at 100 % and the others' at 50 %. A change's bar runs
    /// through its lines, from 4 pt below its first line's top to 4 pt above its last line's bottom.
    private func drawGutter(line: NSTextLineFragment, lineRange: NSRange, offset: Int, marks: [TranscriptChangeMark], above: [TranscriptChangeMark], below: [TranscriptChangeMark],
                            at point: CGPoint, renderer: TranscriptRenderer, text: TranscriptNSTextView, context: CGContext) {
        let left = point.x - layoutFragmentFrame.minX - text.textContainerOrigin.x
        let box = TranscriptGutter.visualBox(of: line, font: renderer.font).offsetBy(dx: 0, dy: point.y)
        if line.characterRange.location == 0, let index = renderer.paragraph(atCharacter: offset), renderer.paragraphs[index].offset == offset {
            let color = renderer.currentParagraph == index ? DesignValues.nsColor("text.secondary")
                : DesignValues.nsColor(renderer.isInScope(paragraph: index) ? "gutter.text" : "gutter.textOut")
            TranscriptGutter.drawTimecode(TranscriptGutter.timecode(renderer.paragraphs[index].start), color: color, right: left + TranscriptGutter.timecodeRight, box: box, in: context)
        }
        let shown = marks.filter { $0.role != .slot }
        let aiVoice = text.map.intersecting(lineRange).contains { renderer.aiWordIDs.contains($0.id) && NSIntersectionRange($0.range, lineRange).length > 0 }
        TranscriptGutter.glyph(marks: marks, aiVoice: aiVoice)?.draw(in: TranscriptGutter.glyphBox(left: left, line: box), context: context)
        func pending(_ marks: [TranscriptChangeMark], _ ordinal: Int) -> Bool { marks.contains { $0.ordinal == ordinal && $0.pending && $0.role != .slot } }
        let bars = Self.changeBars(shown)
        guard !bars.isEmpty else { return }
        context.saveGState()
        let add = DesignValues.nsColor("change.add")
        for (ordinal, focused) in bars {
            let top = pending(above, ordinal) ? box.minY : box.minY + TranscriptGutter.changeBarInset
            let bottom = pending(below, ordinal) ? box.maxY : box.maxY - TranscriptGutter.changeBarInset
            guard bottom > top else { continue }
            context.setFillColor(add.withAlphaComponent(focused ? 1 : 0.5).cgColor)
            let bar = CGRect(x: left + TranscriptGutter.changeBarX, y: top, width: TranscriptGutter.changeBarWidth, height: bottom - top)
            context.addPath(CGPath(roundedRect: bar, cornerWidth: TranscriptGutter.changeBarWidth / 2, cornerHeight: min(TranscriptGutter.changeBarWidth / 2, bar.height / 2), transform: nil))
            context.fillPath()
        }
        context.restoreGState()
    }

    /// One change bar per pending change on a line, the focused ones last so they draw on
    /// top, each group in ordinal order. Split into typed steps: as one chain it took the
    /// type checker about 3 s.
    private static func changeBars(_ marks: [TranscriptChangeMark]) -> [(ordinal: Int, focused: Bool)] {
        let byOrdinal: [Int: [TranscriptChangeMark]] = Dictionary(grouping: marks.filter(\.pending), by: \.ordinal)
        let bars: [(ordinal: Int, focused: Bool)] = byOrdinal.map { entry in (ordinal: entry.key, focused: entry.value.contains(where: \.focused)) }
        return bars.sorted { first, second in first.focused != second.focused ? second.focused : first.ordinal < second.ordinal }
    }

    /// The AI passage's marker before its words, until the AI tint replaces it (V19).
    private func drawMarker(_ span: TranscriptSpan, rect: CGRect, renderer: TranscriptRenderer, context: CGContext) {
        guard span.kind == .ai else { return }
        let accent = NSColor(DesignValues.accentText)
        let box = CGRect(x: rect.minX + 2, y: rect.midY - 8, width: 23, height: 16)
        context.setFillColor(NSColor(DesignValues.accentSoft).cgColor)
        let path = CGPath(roundedRect: box, cornerWidth: 4, cornerHeight: 4, transform: nil)
        context.addPath(path); context.fillPath()
        context.setStrokeColor(accent.cgColor); context.setLineWidth(1)
        context.setLineDash(phase: 0, lengths: [])
        context.addPath(path); context.strokePath()
        let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold)
        let colorKey = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
        let title = NSAttributedString(string: "AI", attributes: [.font: font, colorKey: accent.cgColor])
        let line = CTLineCreateWithAttributedString(title)
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        let baseline = box.midY + (font.ascender + font.descender) / 2
        context.saveGState()
        context.translateBy(x: box.midX - width / 2, y: baseline)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        context.textPosition = .zero
        CTLineDraw(line, context)
        context.restoreGState()
    }
}

/// Stands between a transcript's viewport layout controller and its text view. It passes
/// every delegate call on to the text view and, after each finished layout, lets the
/// transcript place its layers. NSTextView declares its viewport delegate methods only from
/// the macOS 27 SDK, so overriding them would not build with the macOS 26 SDK.
final class TranscriptViewportRelay: NSObject, NSTextViewportLayoutControllerDelegate {
    private weak var base: (any NSTextViewportLayoutControllerDelegate)?
    private let didLayout: @MainActor () -> Void
    init(base: (any NSTextViewportLayoutControllerDelegate)?, didLayout: @escaping @MainActor () -> Void) {
        self.base = base
        self.didLayout = didLayout
    }
    func viewportBounds(for controller: NSTextViewportLayoutController) -> CGRect {
        base?.viewportBounds(for: controller) ?? .zero
    }
    func textViewportLayoutController(_ controller: NSTextViewportLayoutController, configureRenderingSurfaceFor fragment: NSTextLayoutFragment) {
        base?.textViewportLayoutController(controller, configureRenderingSurfaceFor: fragment)
    }
    func textViewportLayoutControllerWillLayout(_ controller: NSTextViewportLayoutController) {
        base?.textViewportLayoutControllerWillLayout?(controller)
    }
    func textViewportLayoutControllerDidLayout(_ controller: NSTextViewportLayoutController) {
        base?.textViewportLayoutControllerDidLayout?(controller)
        let didLayout = didLayout
        MainActor.assumeIsolated { didLayout() }
    }
    /// Delegate methods the relay does not name, such as the macOS 27 rendering surface cache
    /// and set-needs-layout calls, go to the text view unchanged.
    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || base?.responds(to: selector) == true
    }
    override func forwardingTarget(for selector: Selector!) -> Any? { base }
}

@MainActor final class TranscriptNSTextView: NSTextView, NSTextFieldDelegate, @preconcurrency NSAccessibilityCustomRotorItemSearchDelegate {
    weak var model: EditorModel?

    /// The transcript measure (notes.md §1 and §4): the pane less the 80 gutter and 44 of
    /// right padding, kept between 480 and 680, and never wider than the pane after the
    /// gutter, so a narrow pane wraps rather than clips. Text starts after the gutter.
    static func measure(forPane width: Double) -> Double {
        let gutter = Double(TranscriptGutter.width)
        return max(120, min((width - gutter - Double(TranscriptGutter.trailing)).clamped(to: 480...Double(VCTokens.sizeTranscriptMeasureMax)), width - gutter))
    }
    /// A transcript that arrives after the editor showed, for example when transcription
    /// finishes, takes the keyboard focus the editor still wants. The viewport relay is
    /// checked here too, in case AppKit made the view its controller's delegate again.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        relayViewportLayout()
        guard let window, model?.wantsTranscriptFocus == true else { return }
        Task { @MainActor [weak self] in
            guard let self, self.window === window, let model = self.model, model.wantsTranscriptFocus else { return }
            if window.makeFirstResponder(self) { model.wantsTranscriptFocus = false }
        }
    }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let width = Self.measure(forPane: newSize.width)
        if let container = textContainer, !container.widthTracksTextView, abs(container.containerSize.width - width) > 0.5 {
            container.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        }
    }
    var map = TranscriptRangeMap()
    weak var renderer: TranscriptRenderer?
    private(set) var backdrop: TranscriptBackdropView?
    /// Adds the backdrop behind the text, selection and every other subview.
    func installBackdrop() {
        guard backdrop == nil else { return }
        let view = TranscriptBackdropView(frame: .zero)
        addSubview(view, positioned: .below, relativeTo: nil)
        backdrop = view
    }
    private(set) var selectionLayer: TranscriptSelectionLayer?
    private(set) var caret: TranscriptCaret?
    /// Adds the selection tint and the caret above the backdrop and behind the text.
    func installSelectionLayer() {
        guard selectionLayer == nil, let backdrop else { return }
        let layer = TranscriptSelectionLayer(frame: .zero), caret = TranscriptCaret(frame: .zero)
        layer.isHidden = true; caret.isHidden = true
        addSubview(layer, positioned: .above, relativeTo: backdrop)
        addSubview(caret, positioned: .above, relativeTo: layer)
        selectionLayer = layer; self.caret = caret
    }
    private var viewportRelay: TranscriptViewportRelay?
    /// Puts the relay between the viewport layout controller and this view, so each finished
    /// viewport layout also places the transcript's layers. Safe to call again: it rewraps
    /// only when AppKit has made the view the controller's delegate again.
    func relayViewportLayout() {
        guard let controller = textLayoutManager?.textViewportLayoutController else { return }
        if let viewportRelay, controller.delegate === viewportRelay { return }
        let relay = TranscriptViewportRelay(base: controller.delegate) { [weak self] in self?.placeLayers() }
        viewportRelay = relay
        controller.delegate = relay
    }
    /// Measures what follows the laid-out lines now. While the viewport is short of the
    /// visible rect (a scroll with no layout pass yet), it lays the viewport out first, so
    /// these never follow lines from before the scroll; that layout's relay call places them.
    func viewportDidLayout() {
        if let controller = textLayoutManager?.textViewportLayoutController, case let visible = visibleRect, !visible.isEmpty {
            // The viewport is in text container coordinates.
            let needed = visible.offsetBy(dx: -textContainerOrigin.x, dy: -textContainerOrigin.y)
            if !controller.viewportBounds.insetBy(dx: -1, dy: -1).contains(needed) { controller.layoutViewport() }
        }
        placeLayers()
    }
    /// After every viewport layout (scrolling, resizing, new text; the relay calls it), moves
    /// the backdrop, the selection, the caret and the overview ruler's visible window with the
    /// lines TextKit just placed. It never lays the viewport out itself: called from inside a
    /// layout, that would start another layout, and TextKit 2 does not stop the recursion.
    func placeLayers() {
        updateBackdrop()
        updateSelectionLayer()
        updateCaret()
        updateProposalButtons()
        updateThread()
        (enclosingScrollView as? TranscriptScrollView)?.overviewRuler.visibleSpan = visibleTakeSpan()
    }
    /// The laid-out line holding the character at `offset`, its fragment and the fragment's
    /// first character, or nil while TextKit has not laid it out (offscreen).
    private func laidOutLine(atCharacter offset: Int) -> (fragment: NSTextLayoutFragment, line: NSTextLineFragment, base: Int)? {
        guard let manager = textLayoutManager, let content = manager.textContentManager,
              let location = content.location(content.documentRange.location, offsetBy: offset),
              let fragment = manager.textLayoutFragment(for: location), fragment.state == .layoutAvailable,
              let element = fragment.textElement?.elementRange else { return nil }
        let base = content.offset(from: content.documentRange.location, to: element.location)
        guard let line = fragment.textLineFragments.first(where: { NSLocationInRange(offset - base, $0.characterRange) }) ?? fragment.textLineFragments.last else { return nil }
        return (fragment, line, base)
    }
    /// A character's x in its line. TextKit reports the place after a kerned glyph half way
    /// through the kern, so a word after a fold starts the fold's full kern after its glyph.
    /// A fold that ends the line before adds nothing: `index` then starts its line. Every x
    /// of a character that may follow a fold goes through here.
    func glyphX(_ line: NSTextLineFragment, local index: Int) -> CGFloat {
        let x = line.locationForCharacter(at: index).x
        let string = line.attributedString.string as NSString
        let first = line.characterRange.location
        var previous = index - 1
        if previous >= first, previous < string.length, string.character(at: previous) == 0x200B { previous -= 1 }
        guard previous >= first, previous < string.length, string.character(at: previous) == 0x2022,
              let kern = line.attributedString.attribute(.kern, at: previous, effectiveRange: nil) as? CGFloat else { return x }
        return x + kern / 2
    }
    /// The box of a range's characters on the line of its first, in this view: from
    /// `glyphX`, over the line's typographic height. Nil while the line is not laid out.
    func textBox(of range: NSRange) -> CGRect? {
        guard let (fragment, line, base) = laidOutLine(atCharacter: range.location) else { return nil }
        let lower = range.location - base, upper = min(NSMaxRange(range) - base, NSMaxRange(line.characterRange))
        let left = glyphX(line, local: lower), right = glyphX(line, local: max(lower, upper))
        let origin = textContainerOrigin
        return CGRect(x: origin.x + fragment.layoutFragmentFrame.minX + line.typographicBounds.minX + left, y: origin.y + fragment.layoutFragmentFrame.minY + line.typographicBounds.minY,
                      width: max(0, right - left), height: line.typographicBounds.height)
    }
    /// The selection at text height (notes.md §5): per visible line, from the first selected
    /// character to the last, the font's ascender to its descender, folds between selected
    /// words included.
    func selectionRects() -> [CGRect] {
        let ranges = selectedRanges.map(\.rangeValue).filter { $0.length > 0 }
        guard let first = ranges.first, let last = ranges.last, let manager = textLayoutManager, let content = manager.textContentManager, let renderer else { return [] }
        let documentStart = content.documentRange.location
        // The viewport's lines only; before any viewport layout, every laid-out line.
        let viewport = manager.textViewportLayoutController.viewportRange
        let start = max(first.location, viewport.map { content.offset(from: documentStart, to: $0.location) } ?? 0)
        let end = min(NSMaxRange(last), viewport.map { content.offset(from: documentStart, to: $0.endLocation) } ?? NSMaxRange(last))
        guard start < end, let location = content.location(documentStart, offsetBy: start) else { return [] }
        // The storage's own string: bridging `string` would copy the whole text on every viewport layout.
        guard let string = textStorage?.mutableString else { return [] }
        let origin = textContainerOrigin, font = renderer.font
        // A proposed change's new words and the Keep and Undo blank are not text the selection holds.
        let skipped = map.intersecting(NSRange(location: start, length: end - start)).filter { $0.kind == .inserted || $0.kind == .spacer }.map(\.range)
        var rects: [CGRect] = []
        manager.enumerateTextLayoutFragments(from: location, options: []) { fragment in
            guard let element = fragment.textElement?.elementRange else { return false }
            let base = content.offset(from: documentStart, to: element.location)
            guard base < end else { return false }
            for line in fragment.textLineFragments {
                let lineStart = base + line.characterRange.location
                let lineEnd = min(end, lineStart + line.characterRange.length)
                var pieces: [(Int, Int)] = []
                var lower = max(start, lineStart)
                for gap in skipped where NSMaxRange(gap) > lower && gap.location < lineEnd {
                    if gap.location > lower { pieces.append((lower, gap.location)) }
                    lower = max(lower, NSMaxRange(gap))
                }
                if lineEnd > lower { pieces.append((lower, lineEnd)) }
                for (first, last) in pieces {
                    var lower = first, upper = last
                    // A trailing or leading space, break or newline is not text.
                    while upper > lower, [0x20, 0x200B, 0x0A].contains(string.character(at: upper - 1)) { upper -= 1 }
                    while upper > lower, !skipped.isEmpty, [0x20, 0x200B].contains(string.character(at: lower)) { lower += 1 }
                    guard upper > lower else { continue }
                    let left = glyphX(line, local: lower - base), right = glyphX(line, local: upper - base)
                    let x = origin.x + fragment.layoutFragmentFrame.minX + line.typographicBounds.minX
                    let baseline = origin.y + fragment.layoutFragmentFrame.minY + line.typographicBounds.minY + line.glyphOrigin.y
                    rects.append(CGRect(x: x + left, y: baseline - font.ascender, width: max(1, right - left), height: font.ascender - font.descender))
                }
            }
            return true
        }
        return rects
    }
    func updateSelectionLayer() { selectionLayer?.show(selectionRects()) }

    // MARK: Folds

    /// The fold under the pointer, whose dot shows in text.secondary with a halo.
    private(set) var hoveredFold: String?
    private var hoverArea: NSTrackingArea?
    private var hoverTask: Task<Void, Never>?
    private var foldPopover: NSHostingView<FoldPopover>?
    /// The fold whose popover shows.
    private(set) var popoverFold: String?
    var foldPopoverVisible: Bool { foldPopover?.isHidden == false }
    #if DEBUG
    var foldPopoverAuditView: NSView? { foldPopoverVisible ? foldPopover : nil }
    #endif
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }
    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        hover(at: convert(event.locationInWindow, from: nil))
    }
    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hover(at: nil)
    }
    /// Hovering a fold lights its dot at once and shows its popover after a moment; the
    /// popover stays while the pointer moves into it.
    func hover(at point: CGPoint?) {
        if let point, let popover = foldPopover, !popover.isHidden, popover.frame.insetBy(dx: -4, dy: -4).contains(point) { return }
        let fold = point.flatMap(fold(at:))
        setHoveredFold(fold?.id)
        guard let fold else { hoverTask?.cancel(); hideFoldPopover(); return }
        guard popoverFold != fold.id || !foldPopoverVisible else { return }
        hideFoldPopover()
        hoverTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            guard !Task.isCancelled, self?.hoveredFold == fold.id else { return }
            self?.showFoldPopover(for: fold.id)
        }
    }
    private func setHoveredFold(_ id: String?) {
        guard hoveredFold != id else { return }
        let old = hoveredFold
        hoveredFold = id
        for fold in [old, id].compactMap({ $0 }) { renderer?.redisplay(span: fold) }
    }
    /// The fold whose dot box holds a point in this view: the fold's width, its line's height.
    func fold(at point: CGPoint) -> TranscriptSpan? {
        guard let manager = textLayoutManager, let content = manager.textContentManager, !map.isEmpty else { return nil }
        let origin = textContainerOrigin
        guard let fragment = manager.textLayoutFragment(for: CGPoint(x: point.x - origin.x, y: point.y - origin.y)), fragment.state == .layoutAvailable,
              let element = fragment.textElement?.elementRange else { return nil }
        let base = content.offset(from: content.documentRange.location, to: element.location)
        let y = point.y - origin.y - fragment.layoutFragmentFrame.minY
        guard let line = fragment.textLineFragments.first(where: { $0.typographicBounds.minY <= y && y < $0.typographicBounds.maxY }) else { return nil }
        let lineRange = NSRange(location: base + line.characterRange.location, length: line.characterRange.length)
        return map.intersecting(lineRange).first { span in
            span.kind == .fold && foldBox(span, fragment: fragment, line: line, base: base).map { $0.contains(point) } == true
        }
    }
    /// A fold's box in this view: from its glyph's start, the fold's width, over its line.
    func foldBox(_ span: TranscriptSpan) -> CGRect? {
        guard let (fragment, line, base) = laidOutLine(atCharacter: span.range.location + TranscriptFold.glyphOffset) else { return nil }
        return foldBox(span, fragment: fragment, line: line, base: base)
    }
    private func foldBox(_ span: TranscriptSpan, fragment: NSTextLayoutFragment, line: NSTextLineFragment, base: Int) -> CGRect? {
        let glyph = span.range.location + TranscriptFold.glyphOffset - base
        guard let renderer, NSLocationInRange(glyph, line.characterRange) else { return nil }
        let origin = textContainerOrigin
        let x = origin.x + fragment.layoutFragmentFrame.minX + line.typographicBounds.minX + line.locationForCharacter(at: glyph).x
        let y = origin.y + fragment.layoutFragmentFrame.minY + line.typographicBounds.minY
        return CGRect(x: x, y: y, width: renderer.foldGap, height: line.typographicBounds.height)
    }
    /// Shows a fold's popover under its line, its dot 22 pt from the popover's leading edge,
    /// or above the line when the pane has no room for it below.
    func showFoldPopover(for id: String) {
        guard let model, let span = map.span(id: id), span.kind == .fold, let box = foldBox(span), let line = lineBox(atCharacter: span.range.location + TranscriptFold.glyphOffset) else { return }
        let view = FoldPopover(items: model.foldItems(span.ids), description: model.foldDescription(span.ids), canRestore: model.capabilities.edit) { [weak self] in
            self?.hideFoldPopover()
            self?.model?.restoreFold(span.ids)
        }
        let host: NSHostingView<FoldPopover>
        if let foldPopover { host = foldPopover; host.rootView = view } else { host = NSHostingView(rootView: view); foldPopover = host; addSubview(host) }
        let size = host.fittingSize
        let visible = visibleRect
        let x = min(max(visible.minX + 4, box.midX - 22), visible.maxX - size.width - 4)
        let below = line.maxY + 2, above = line.minY - 2 - size.height
        let y = below + size.height <= visible.maxY || above < visible.minY ? below : above
        host.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
        host.isHidden = false
        popoverFold = id
    }
    func hideFoldPopover() {
        hoverTask?.cancel(); hoverTask = nil
        foldPopover?.isHidden = true
        popoverFold = nil
    }

    // MARK: Proposed changes

    private(set) var proposalLayer: TranscriptProposalLayer?
    private var rotorsShowProposal: Bool?
    /// The focused change's Rewrite thread (design.md §6.3 "Talk back to Claude"), under its paragraph.
    private(set) var threadHost: RewriteThreadHost?
    private var threadRenderScheduled = false
    var threadVisible: Bool { threadHost?.isHidden == false }
    /// Adds the focused change's Keep and Undo buttons above the text.
    func installProposalLayer() {
        guard proposalLayer == nil else { return }
        let layer = TranscriptProposalLayer(frame: .zero)
        layer.isHidden = true
        layer.perform = { [weak self] action in
            guard let self, let model = self.model else { return }
            switch action {
            case .keep: model.keepFocusedChange()
            case .undo: model.excludeFocusedChange()
            }
            self.window?.makeFirstResponder(self)
        }
        addSubview(layer)
        proposalLayer = layer
    }
    /// The Cuts, Pauses, Suggested fillers, Clips and AI words rotors, and Proposed changes while
    /// a proposal shows (design.md §15).
    func updateRotors(proposal: Bool) {
        guard rotorsShowProposal != proposal else { return }
        rotorsShowProposal = proposal
        let labels = ["Cuts", "Pauses", "Suggested fillers", "Clips", "AI words"] + (proposal ? ["Proposed changes"] : [])
        setAccessibilityCustomRotors(labels.map { NSAccessibilityCustomRotor(label: $0, itemSearchDelegate: self) })
    }
    /// Places the Keep and Undo buttons over the blank after the focused change (impl-plan item
    /// 23), centred on its line; hidden while that line is outside the viewport.
    func updateProposalButtons() {
        guard let layer = proposalLayer else { return }
        // Only a line in the viewport: asking TextKit for another paragraph's fragment would lay it out.
        guard let renderer, let id = renderer.spacerID, let span = map.span(id: id), span.kind == .spacer, !renderer.spacerActions.isEmpty,
              let manager = textLayoutManager, let content = manager.textContentManager, let viewport = manager.textViewportLayoutController.viewportRange,
              case let start = content.offset(from: content.documentRange.location, to: viewport.location),
              case let end = content.offset(from: content.documentRange.location, to: viewport.endLocation),
              span.range.location >= start, span.range.location <= end,
              let (fragment, line, base) = laidOutLine(atCharacter: span.range.location + TranscriptFold.glyphOffset),
              case let glyph = span.range.location + TranscriptFold.glyphOffset - base, NSLocationInRange(glyph, line.characterRange) else { layer.hide(); return }
        let origin = textContainerOrigin
        let x = origin.x + fragment.layoutFragmentFrame.minX + line.typographicBounds.minX + line.locationForCharacter(at: glyph).x
        let box = TranscriptGutter.visualBox(of: line, font: renderer.font).offsetBy(dx: origin.x + fragment.layoutFragmentFrame.minX, dy: origin.y + fragment.layoutFragmentFrame.minY)
        layer.show(renderer.spacerActions, blank: x, line: box)
    }
    /// Renders the model now, as `updateNSView` would, so a change focused from a click, the
    /// rotor or the Rewrite job's change list has its place in the text before it is measured.
    func renderNow() {
        guard let model, let coordinator = delegate as? TranscriptTextView.Coordinator else { return }
        coordinator.updating = true
        TranscriptTextView.render(model, coordinator: coordinator)
        coordinator.updating = false
        updateProposalButtons()
        updateThread()
    }
    /// The change whose new words lie under a point in this view.
    func insertedChange(at point: CGPoint) -> Int? {
        guard let manager = textLayoutManager, let content = manager.textContentManager, !map.isEmpty else { return nil }
        let origin = textContainerOrigin
        guard let fragment = manager.textLayoutFragment(for: CGPoint(x: point.x - origin.x, y: point.y - origin.y)), fragment.state == .layoutAvailable,
              let element = fragment.textElement?.elementRange else { return nil }
        let base = content.offset(from: content.documentRange.location, to: element.location)
        let y = point.y - origin.y - fragment.layoutFragmentFrame.minY
        guard let line = fragment.textLineFragments.first(where: { $0.typographicBounds.minY <= y && y < $0.typographicBounds.maxY }) else { return nil }
        let lineRange = NSRange(location: base + line.characterRange.location, length: line.characterRange.length)
        let left = origin.x + fragment.layoutFragmentFrame.minX + line.typographicBounds.minX
        return map.intersecting(lineRange).first { span in
            let overlap = NSIntersectionRange(span.range, lineRange)
            guard span.kind == .inserted, overlap.length > 0 else { return false }
            return point.x >= left + glyphX(line, local: overlap.location - base) && point.x <= left + glyphX(line, local: NSMaxRange(overlap) - base)
        }?.change?.ordinal
    }
    /// Places the focused change's thread under its paragraph's last line, indented to the text column, in the room the
    /// renderer keeps there (`TranscriptParagraphContent.threadGap`); hidden while that line is outside the viewport. A
    /// new height is kept and the paragraph written again on the next turn, never inside a layout.
    func updateThread() {
        guard let model, let renderer else { return }
        guard model.rewriteThreadSlot(model.proposalDisplay) != nil, let anchor = renderer.threadAnchor,
              let manager = textLayoutManager, let content = manager.textContentManager, let viewport = manager.textViewportLayoutController.viewportRange,
              case let start = content.offset(from: content.documentRange.location, to: viewport.location),
              case let end = content.offset(from: content.documentRange.location, to: viewport.endLocation),
              anchor >= start, anchor <= end, let (fragment, line, _) = laidOutLine(atCharacter: anchor) else {
            if threadHost?.isHidden == false { threadHost?.isHidden = true }
            if let model = self.model, model.rewriteThreadSlot(model.proposalDisplay) != nil, model.rewriteThread.height == 0 { measureThread(model) }
            return
        }
        let host = measureThread(model)
        let origin = textContainerOrigin
        let y = origin.y + fragment.layoutFragmentFrame.minY + line.typographicBounds.maxY + TranscriptRenderer.threadTop
        let frame = CGRect(x: origin.x, y: y.rounded(), width: host.rootView.width, height: CGFloat(model.rewriteThread.height))
        if host.frame != frame { host.frame = frame }
        if host.isHidden { host.isHidden = false }
    }
    /// The thread's view at the text column's width and its height there; a changed height renders the transcript again.
    @discardableResult private func measureThread(_ model: EditorModel) -> RewriteThreadHost {
        let width = (textContainer?.containerSize.width ?? 480).rounded(.down)
        let host: RewriteThreadHost
        if let threadHost {
            host = threadHost
            if host.rootView.width != width { host.rootView = RewriteThreadView(model: model, width: width) }
        } else {
            host = RewriteThreadHost(rootView: RewriteThreadView(model: model, width: width))
            host.isHidden = true
            host.onResize = { [weak self] in self?.scheduleThreadRender() }
            addSubview(host)
            threadHost = host
        }
        let height = Double(host.fittingSize.height.rounded(.up))
        if abs(model.rewriteThread.height - height) > 0.5 {
            model.rewriteThread.height = height
            scheduleThreadRender()
        }
        return host
    }
    #if DEBUG
    /// Measures and places the thread at once, its paragraph written with its room: the headless checks, which have no
    /// main-actor turns to wait for.
    func layoutThreadNow() { settleThread() }
    var threadAuditView: NSView? { threadVisible ? threadHost : nil }
    #endif
    /// The thread's height changed: its paragraph is written again on the main actor's next turn.
    private func scheduleThreadRender() {
        guard !threadRenderScheduled else { return }
        threadRenderScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            threadRenderScheduled = false
            if let model, model.rewriteThreadSlot(model.proposalDisplay) != nil, let host = threadHost {
                let height = Double(host.fittingSize.height.rounded(.up))
                if abs(model.rewriteThread.height - height) > 0.5 { model.rewriteThread.height = height }
            }
            renderNow()
        }
    }
    /// Return, F2, a click on a change's new words and VoiceOver's Talk to Claude: the change's thread opens and its
    /// input takes the keys; the change and its thread come into view first. ⌥E (`ownWords`) opens it with the input
    /// taking your own words. False where no thread shows.
    @discardableResult func openThread(_ ordinal: Int, ownWords: Bool = false) -> Bool {
        guard let model else { return false }
        if model.proposalDisplay?.focused != ordinal { model.focusChange(ordinal) }
        guard ownWords ? model.openRewriteThreadOwnWords() : model.openRewriteThreadInput() else { return false }
        renderNow()
        if let range = renderer?.changeRange(ordinal) { scrollRangeToVisible(range) }
        settleThread()
        if let host = threadHost, !host.isHidden { scrollToVisible(host.frame) }
        return true
    }
    /// Measures the thread, writes its paragraph with that room and places it, now: outside a layout pass only (a key, a
    /// click, a headless check).
    private func settleThread() {
        guard let model else { return }
        threadRenderScheduled = true
        defer { threadRenderScheduled = false }
        for _ in 0..<2 {
            measureThread(model)
            renderNow()
            textLayoutManager?.textViewportLayoutController.layoutViewport()
        }
        updateThread()
    }
    /// ⌘↩ keeps and ⌘⌫ undoes the focused change, ⌥↓ and ⌥↑ walk the changes, ⌥← and ⌥→ switch its
    /// thread's versions, and F2, or Return on the focused change or a selection in a change, opens its thread (impl-plan §3.2);
    /// ⌥E opens it for your own words. Returns false for any other key.
    private func handleChangeKey(_ event: NSEvent, model: EditorModel) -> Bool {
        guard let display = model.proposalDisplay else { return false }
        let flags = event.modifierFlags.intersection([.command, .option, .shift, .control])
        let returnKey = event.keyCode == 36 || event.keyCode == 76
        switch (flags, event.keyCode) {
        case (.command, _) where returnKey: model.keepFocusedChange(); return true
        case (.command, 51): model.excludeFocusedChange(); return true
        case (.option, 125), (.option, 126): model.focusNextChange(event.keyCode == 125 ? 1 : -1); return true
        case (.option, 123), (.option, 124):
            // ⌥← and ⌥→ switch the focused change's versions once its thread has more than one; else they walk sentences.
            guard let thread = model.rewriteThreadDisplay, thread.versions > 1 else { return false }
            model.switchRewriteThreadVersion(by: event.keyCode == 123 ? -1 : 1); return true
        case ([], 120):
            guard let focused = display.focused, !display.actions.isEmpty else { return false }
            return openThread(focused)
        case (.option, _) where event.charactersIgnoringModifiers?.lowercased() == "e":
            guard let focused = display.focused, !display.actions.isEmpty else { return false }
            return openThread(focused, ownWords: true)
        case ([], _) where returnKey:
            guard let ordinal = model.changeForReturn else { return false }
            return openThread(ordinal)
        default: return false
        }
    }
    @objc func accessibleKeepChange() -> Bool { model?.keepFocusedChange() ?? false }
    @objc func accessibleUndoChange() -> Bool { model?.excludeFocusedChange() ?? false }
    @objc func accessibleEditChange() -> Bool {
        guard let focused = model?.proposalDisplay?.focused else { return false }
        return openThread(focused)
    }
    @objc func accessibleOwnWords() -> Bool {
        guard let focused = model?.proposalDisplay?.focused else { return false }
        return openThread(focused, ownWords: true)
    }
    /// Places the caret (impl-plan item 19): 2 × 19 at 15 pt, from 15 above the baseline to 4
    /// below, centred on the start of the playhead's word. Hidden while its line is offscreen.
    func updateCaret() {
        guard let caret else { return }
        // Only a line in the viewport: asking TextKit for another paragraph's fragment would
        // lay it out, and a fragment made outside a layout pass misses its rendering attributes.
        guard let renderer, let offset = renderer.caretOffset, let manager = textLayoutManager, let content = manager.textContentManager,
              let viewport = manager.textViewportLayoutController.viewportRange,
              case let start = content.offset(from: content.documentRange.location, to: viewport.location),
              case let end = content.offset(from: content.documentRange.location, to: viewport.endLocation),
              offset >= start, offset <= end, let (fragment, line, base) = laidOutLine(atCharacter: offset) else {
            if !caret.isHidden { caret.isHidden = true }
            return
        }
        let scale = renderer.font.pointSize / DesignValues.transcriptTextSize
        let origin = textContainerOrigin
        let x = origin.x + fragment.layoutFragmentFrame.minX + line.typographicBounds.minX + glyphX(line, local: offset - base)
        let baseline = origin.y + fragment.layoutFragmentFrame.minY + line.typographicBounds.minY + line.glyphOrigin.y
        let frame = CGRect(x: x - 1, y: baseline - 15 * scale, width: 2, height: 19 * scale)
        if caret.frame != frame { caret.frame = frame }
        if caret.isHidden { caret.isHidden = false }
    }
    /// Places the open clip's band and range bar (notes.md §5) from its first and last lines.
    /// An end beyond the viewport is never laid out for this, so the band runs past the
    /// visible rect there; the visible part is always measured from laid-out lines.
    func updateBackdrop() {
        guard let backdrop else { return }
        guard let renderer, let id = renderer.appearance?.activeClipID, let clip = renderer.clipMarks[id], clip.range.length > 0,
              let manager = textLayoutManager, let content = manager.textContentManager, let viewport = manager.textViewportLayoutController.viewportRange else {
            backdrop.show(nil, visible: visibleRect, width: bounds.width); return
        }
        let start = content.offset(from: content.documentRange.location, to: viewport.location)
        let end = content.offset(from: content.documentRange.location, to: viewport.endLocation)
        let first = clip.range.location, last = NSMaxRange(clip.range) - 1
        guard last >= start, first <= end else { backdrop.show(nil, visible: visibleRect, width: bounds.width); return }
        let visible = visibleRect, beyond = TranscriptBackdropView.margin * 2
        let top = first >= start ? lineBox(atCharacter: first) : nil
        let bottom = last <= end ? lineBox(atCharacter: last) : nil
        let band = TranscriptBackdropView.Band(
            top: top.map { $0.minY - TranscriptGutter.bandOverhang } ?? visible.minY - beyond,
            bottom: bottom.map { $0.maxY + TranscriptGutter.bandOverhang } ?? visible.maxY + beyond,
            barTop: top.map { $0.minY + TranscriptGutter.rangeBarInset }, barBottom: bottom.map { $0.maxY - TranscriptGutter.rangeBarInset },
            suggested: clip.suggested)
        backdrop.show(band, visible: visible, width: bounds.width)
    }
    /// The centred box of the line holding the character at `offset`, in view coordinates.
    func lineBox(atCharacter offset: Int) -> CGRect? {
        guard let manager = textLayoutManager, let content = manager.textContentManager,
              let location = content.location(content.documentRange.location, offsetBy: offset) else { return nil }
        var box: CGRect?
        let origin = textContainerOrigin
        let font = renderer?.font ?? DesignValues.transcriptFont(size: DesignValues.transcriptTextSize)
        manager.enumerateTextLayoutFragments(from: location, options: [.ensuresLayout]) { fragment in
            guard let element = fragment.textElement?.elementRange else { return false }
            let local = offset - content.offset(from: content.documentRange.location, to: element.location)
            let line = fragment.textLineFragments.first { NSLocationInRange(local, $0.characterRange) } ?? fragment.textLineFragments.last
            box = line.map { TranscriptGutter.visualBox(of: $0, font: font).offsetBy(dx: origin.x + fragment.layoutFragmentFrame.minX, dy: origin.y + fragment.layoutFragmentFrame.minY) }
            return false
        }
        return box
    }
    /// The take time the visible lines span, as fractions of the take for the overview ruler.
    func visibleTakeSpan() -> ClosedRange<Double>? {
        guard let model, let manager = textLayoutManager, let content = manager.textContentManager, !map.isEmpty else { return nil }
        let duration = TranscriptOverviewRuler.duration(model)
        guard duration > 0 else { return nil }
        let origin = textContainerOrigin, visible = visibleRect
        func character(atY y: CGFloat, last: Bool) -> Int? {
            guard let fragment = manager.textLayoutFragment(for: CGPoint(x: 0, y: y - origin.y)), let element = fragment.textElement?.elementRange else { return nil }
            let base = content.offset(from: content.documentRange.location, to: element.location)
            let local = y - origin.y - fragment.layoutFragmentFrame.minY
            let line = fragment.textLineFragments.first { $0.typographicBounds.maxY > local } ?? fragment.textLineFragments.last
            guard let line else { return base }
            return base + (last ? max(line.characterRange.location, NSMaxRange(line.characterRange) - 1) : line.characterRange.location)
        }
        // The text's own extent, without the container inset above and below it.
        let usage = manager.usageBoundsForTextContainer.offsetBy(dx: origin.x, dy: origin.y)
        guard let first = character(atY: max(visible.minY, usage.minY), last: false), let last = character(atY: min(visible.maxY, usage.maxY) - 1, last: true),
              let lower = takeTime(atCharacter: first, end: false), let upper = takeTime(atCharacter: last, end: true) else { return nil }
        return min(1, max(0, lower / duration))...min(1, max(lower, upper) / duration)
    }
    /// The take time of the word or pause at a character: its start, or its end with `end`.
    func takeTime(atCharacter offset: Int, end: Bool) -> Double? {
        guard let model, let span = map.span(at: offset) else { return nil }
        if span.pause, let pause = model.pauseIndex[span.id] { return end ? pause.end : pause.start }
        let ids = span.ids.isEmpty ? [span.id] : span.ids
        guard let id = end ? ids.last : ids.first, let position = model.index(id) else { return nil }
        return end ? model.words[position].end : model.words[position].start
    }
    private var correction: NSTextField?
    private var correctionWordID: String?
    private var selectionBar: NSHostingView<SelectionBar>?
    /// The "Rewrite these words as" strip under the selection bar, open after "✦ Rewrite as ▾" (design.md §6.3.1).
    private var selectionStrip: NSHostingView<SelectionRewriteStrip>?
    private(set) var selectionStripOpen = false
    private var selectionTask: Task<Void, Never>?
    private var scrollingTokens: [NSObjectProtocol] = []
    private var selecting = false
    private var liveScrolling = false
    private var selectionDismissed = false
    private var barFocusRequest = 0
    private var barSignature = ""
    var selectionBarVisible: Bool { selectionBar?.isHidden == false }
    func refreshSelectionBar() {
        guard let model else { return }
        let display = model.proposalDisplay
        let signature = "\(model.selectedWordIDs.sorted()):\(model.selectedPauseIDs.sorted()):\(model.findVisible):\(model.correctionID ?? ""):\(model.cutWordIDs):\(model.cutPauseIDs):\(model.capabilities):\(model.rewriteAsksFirst):\(display?.focused ?? 0):\(display?.actions ?? [])"
        guard signature != barSignature else { return }
        barSignature = signature
        configureAccessibilityActions()
        scheduleSelectionBar()
    }
    func selectionDidChange() { selectionDismissed = false; scheduleSelectionBar() }
    override func viewWillMove(toSuperview newSuperview: NSView?) {
        if newSuperview == nil {
            hideSelectionBar()
            hideFoldPopover()
            for token in scrollingTokens { NotificationCenter.default.removeObserver(token) }
            scrollingTokens = []
        }
        super.viewWillMove(toSuperview: newSuperview)
    }
    func configureAccessibilityActions() {
        var actions = [NSAccessibilityCustomAction(name: "Play from here", target: self, selector: #selector(accessiblePlay))]
        if model?.capabilities.edit == true {
            actions += [NSAccessibilityCustomAction(name: "Make Clip", target: self, selector: #selector(accessibleMakeClip)), NSAccessibilityCustomAction(name: "Cut selected words", target: self, selector: #selector(accessibleCut)), NSAccessibilityCustomAction(name: "Restore selection", target: self, selector: #selector(accessibleRestore)), NSAccessibilityCustomAction(name: "Correct spelling", target: self, selector: #selector(accessibleCorrect))]
        }
        if model?.capabilities.ai == true { actions.append(NSAccessibilityCustomAction(name: "Rewrite", target: self, selector: #selector(accessibleRewrite))) }
        // Keep and Undo are reached here and through the Proposed changes rotor, not the buttons (impl-plan §3.7).
        if let display = model?.proposalDisplay, let focused = display.focused {
            for action in display.actions {
                actions.append(NSAccessibilityCustomAction(name: action == .keep ? "Keep change \(focused)" : "Undo change \(focused)", target: self,
                                                           selector: action == .keep ? #selector(accessibleKeepChange) : #selector(accessibleUndoChange)))
            }
            if model?.rewriteThreadDisplay != nil {
                actions.append(NSAccessibilityCustomAction(name: "Talk to Claude about change \(focused)", target: self, selector: #selector(accessibleEditChange)))
                actions.append(NSAccessibilityCustomAction(name: "Type your own words for change \(focused)", target: self, selector: #selector(accessibleOwnWords)))
            }
        }
        setAccessibilityCustomActions(actions)
    }
    func observeSelectionScrolling(_ scroll: NSScrollView) {
        for token in scrollingTokens { NotificationCenter.default.removeObserver(token) }
        scrollingTokens = [NotificationCenter.default.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: scroll, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.liveScrolling = true; self?.hideSelectionBar(); self?.hideFoldPopover() }
        }, NotificationCenter.default.addObserver(forName: NSScrollView.didEndLiveScrollNotification, object: scroll, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.liveScrolling = false; self?.scheduleSelectionBar() }
        }]
    }
    func hideSelectionBar(dismissed: Bool = false) {
        selectionTask?.cancel(); selectionTask = nil
        selectionBar?.isHidden = true
        selectionStrip?.isHidden = true
        selectionStripOpen = false
        if dismissed { selectionDismissed = true }
    }
    func scheduleSelectionBar() {
        selectionTask?.cancel()
        guard !selecting, !liveScrolling, !selectionDismissed, let model, model.correctionID == nil, !model.findVisible,
              !model.selectedWordIDs.isEmpty || !model.selectedPauseIDs.isEmpty else { hideSelectionBar(); return }
        selectionTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            guard !Task.isCancelled else { return }
            self?.showSelectionBar()
        }
    }
    func selectedLineRects() -> [CGRect] {
        guard let manager = textLayoutManager, let content = manager.textContentManager else { return [] }
        let ranges = selectedRanges.map(\.rangeValue).filter { $0.length > 0 }
        guard let first = ranges.first, let last = ranges.last,
              let location = content.location(content.documentRange.location, offsetBy: first.location) else { return [] }
        var rects: [CGRect] = []
        let origin = textContainerOrigin
        manager.enumerateTextLayoutFragments(from: location, options: [.ensuresLayout]) { fragment in
            guard let element = fragment.textElement?.elementRange else { return false }
            let offset = content.offset(from: content.documentRange.location, to: element.location)
            if offset > NSMaxRange(last) { return false }
            for line in fragment.textLineFragments {
                let lineRange = NSRange(location: offset + line.characterRange.location, length: line.characterRange.length)
                guard ranges.contains(where: { NSIntersectionRange($0, lineRange).length > 0 }) else { continue }
                let intersections = ranges.map { NSIntersectionRange($0, lineRange) }.filter { $0.length > 0 }
                let starts = intersections.map { glyphX(line, local: $0.location - offset) }
                let ends = intersections.map { glyphX(line, local: NSMaxRange($0) - offset) }
                let left = min(starts.min() ?? 0, ends.min() ?? 0)
                let right = max(starts.max() ?? 0, ends.max() ?? 0)
                let bounds = line.typographicBounds.offsetBy(dx: origin.x + fragment.layoutFragmentFrame.minX, dy: origin.y + fragment.layoutFragmentFrame.minY)
                rects.append(CGRect(x: bounds.minX + left, y: bounds.minY, width: max(1, right - left), height: bounds.height))
            }
            return true
        }
        return rects
    }
    #if DEBUG
    var selectionBarAuditView: NSView? { selectionBarVisible ? selectionBar : nil }
    var selectionStripView: NSView? { selectionStrip?.isHidden == false ? selectionStrip : nil }
    #endif
    func showSelectionBar(focus: Bool = false) {
        guard let model, !selecting, !liveScrolling, model.correctionID == nil, !model.findVisible else { return }
        if focus { barFocusRequest += 1; selectionDismissed = false }
        let view = SelectionBar(model: model, focusRequest: barFocusRequest, rewriteAs: { [weak self] in self?.toggleSelectionStrip() },
                                stripOpen: selectionStripOpen) { [weak self] in
            self?.hideSelectionBar(dismissed: true); self?.window?.makeFirstResponder(self)
        }
        let host: NSHostingView<SelectionBar>
        if let selectionBar { host = selectionBar; host.rootView = view } else {
            host = NSHostingView(rootView: view); host.isHidden = true; selectionBar = host; addSubview(host)
        }
        let size = CGSize(width: host.fittingSize.width, height: 36)
        let frame = selectionBarFrame(lineRects: selectedLineRects(), visibleRect: visibleRect, barSize: size, toolbarInset: visibleRect.minY)
        guard !frame.isEmpty else { host.isHidden = true; return }
        host.frame = frame
        placeSelectionStrip(under: frame)
        let wasHidden = host.isHidden
        host.isHidden = false
        let fade = EditorAccessibilityPolicy.system.crossfadeDuration
        if wasHidden && fade > 0 {
            host.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in context.duration = fade; host.animator().alphaValue = 1 }
        } else { host.alphaValue = 1 }
    }
    @objc func accessibleMakeClip() -> Bool { guard model?.capabilities.edit == true, model?.selectedIDs.isEmpty == false else { return false }; model?.makeClip(); return true }
    /// "✦ Rewrite as ▾": shows or hides the tone strip under the bar.
    func toggleSelectionStrip() {
        selectionStripOpen.toggle()
        showSelectionBar()
        if selectionStripOpen { model?.announce("Rewrite these words as. Your default is first.") }
    }
    /// The strip sits right under the bar, or above it when the bar is near the bottom; it hides with the bar.
    private func placeSelectionStrip(under bar: CGRect) {
        guard selectionStripOpen, let model else { selectionStrip?.isHidden = true; return }
        let view = SelectionRewriteStrip(model: model) { [weak self] in
            self?.hideSelectionBar(dismissed: true)
        }
        let host: NSHostingView<SelectionRewriteStrip>
        if let selectionStrip { host = selectionStrip; host.rootView = view } else {
            host = NSHostingView(rootView: view); selectionStrip = host; addSubview(host)
        }
        let size = host.fittingSize
        let x = min(max(bar.minX, visibleRect.minX + 4), max(visibleRect.minX + 4, visibleRect.maxX - size.width - 4))
        var frame = CGRect(x: x, y: bar.maxY + 6, width: size.width, height: size.height)
        if frame.maxY > visibleRect.maxY { frame.origin.y = bar.minY - 6 - size.height }
        host.frame = frame
        host.isHidden = false
    }
    @objc func accessibleRewrite() -> Bool { guard model?.capabilities.ai == true, model?.selectedIDs.isEmpty == false else { return false }; model?.rewriteShortcut(); return true }
    @objc func accessibleCut() -> Bool { guard let model, model.capabilities.edit, !model.selectedIDs.isEmpty || !model.selectedPauseIDs.isEmpty else { return false }; model.cutSelection(); return true }
    @objc func accessibleRestore() -> Bool { guard let model, model.capabilities.edit else { return false }; model.cutSelection(restore: true); return true }
    @objc func accessibleCorrect() -> Bool { guard let model, model.capabilities.edit, !model.selectedIDs.isEmpty else { return false }; model.beginCorrection(); updateCorrection(); return true }
    @objc func accessiblePlay() -> Bool { guard let model else { return false }; model.transport(" ", shift: true); return true }
    func rotor(_ rotor: NSAccessibilityCustomRotor, resultFor parameters: NSAccessibilityCustomRotor.SearchParameters) -> NSAccessibilityCustomRotor.ItemResult? {
        guard let model else { return nil }
        if rotor.label == "Proposed changes" { return changeRotor(parameters, model: model) }
        let clipStarts = Set(model.sortedClips.compactMap { map.span(id: $0.startWordId)?.id })
        let candidates = map.spans.filter { span in
            switch rotor.label {
            case "Cuts": model.project.edits.cutWordIds.contains(span.id) || model.project.edits.cutPauseIds.contains(span.id)
            case "Pauses": span.pause
            case "Suggested fillers": model.fillerIDs.contains(span.id)
            case "Clips": clipStarts.contains(span.id)
            case "AI words": model.voiceLabPlan?.pieces.contains { piece in
                guard piece.kind == .synth, let position = model.index(span.id), let rate = model.voiceLabPlan?.sampleRate else { return false }
                let word = model.words[position]
                return word.start >= Double(piece.sourceStartSample) / rate && word.end <= Double(piece.sourceEndSample) / rate
            } ?? false
            default: false
            }
        }
        let location = parameters.currentItem?.targetRange.location ?? NSNotFound
        let next = parameters.searchDirection == .next
        let span = next ? candidates.first { location == NSNotFound || $0.range.location > location } : candidates.last { location == NSNotFound || $0.range.location < location }
        guard let span else { return nil }
        let result = NSAccessibilityCustomRotor.ItemResult(targetElement: self)
        result.targetRange = span.range
        result.customLabel = rotor.label == "Clips" ? clipNames(startingAt: span, model: model) : "\(spoken(span)), \(rotor.label)"
        return result
    }
    /// The Proposed changes rotor (impl-plan §3.7): each shown change in transcript order, read
    /// "Proposed change 1 of 5: removed to, to the; inserted your, in the". Landing on one focuses
    /// it, so its Keep and Undo custom actions act on it.
    private func changeRotor(_ parameters: NSAccessibilityCustomRotor.SearchParameters, model: EditorModel) -> NSAccessibilityCustomRotor.ItemResult? {
        guard let display = model.proposalDisplay, let renderer else { return nil }
        let items = display.shown.compactMap { shown in renderer.changeRange(shown.ordinal).map { (shown, $0) } }
        let location = parameters.currentItem?.targetRange.location ?? NSNotFound
        let item = parameters.searchDirection == .next ? items.first { location == NSNotFound || $0.1.location > location } : items.last { location == NSNotFound || $0.1.location < location }
        guard let (shown, _) = item else { return nil }
        if shown.ordinal != display.focused {
            model.focusChange(shown.ordinal, announcing: false)
            renderNow()
        }
        guard let range = renderer.changeRange(shown.ordinal) else { return nil }
        let result = NSAccessibilityCustomRotor.ItemResult(targetElement: self)
        result.targetRange = range
        result.customLabel = shown.description
        return result
    }
    /// The Clips rotor names the clips that start at a word as the Explorer does ("Clip 1,
    /// Title" or "Suggested clip 3, Title"), since the transcript no longer marks them.
    private func clipNames(startingAt span: TranscriptSpan, model: EditorModel) -> String {
        model.sortedClips.filter { map.span(id: $0.startWordId) == span }.map { clip in
            let number = model.clipNumber(clip.id) ?? 1
            return "\(model.isSuggestion(clip.id) ? "Suggested clip" : "Clip") \(number), \(clip.title ?? "Untitled clip")"
        }.joined(separator: "; ")
    }
    override func accessibilityString(for range: NSRange) -> String? {
        map.intersecting(range).filter { $0.selectable || $0.kind == .fold || $0.kind == .inserted }.map(spoken).joined(separator: " ")
    }
    override func accessibilityAttributedString(for range: NSRange) -> NSAttributedString? {
        let words = map.intersecting(range).filter(\.selectable)
        if words.count == 1, let span = words.first, NSIntersectionRange(span.range, range) == span.range, range.length <= span.range.length + 1 {
            return NSAttributedString(string: spoken(span))
        }
        guard let base = super.accessibilityAttributedString(for: range) else { return nil }
        guard base.length == range.length else { return base }
        let result = NSMutableAttributedString(attributedString: base)
        for span in map.intersecting(range) {
            let overlap = NSIntersectionRange(span.range, range)
            guard overlap.length > 0 else { continue }
            let local = NSRange(location: overlap.location - range.location, length: overlap.length)
            if span.kind == .fold {
                // A fold reads as what it removed: "1 cut: uh, pause 1.4 seconds".
                result.replaceCharacters(in: local, with: String(repeating: " ", count: local.length))
                if let model { result.addAttribute(.accessibilityCustomText, value: [model.foldDescription(span.ids)], range: local) }
                continue
            }
            if span.kind == .ai || span.kind == .spacer { result.replaceCharacters(in: local, with: String(repeating: " ", count: local.length)); continue }
            if span.pause, overlap.location == span.range.location { result.replaceCharacters(in: NSRange(location: local.location, length: 1), with: " ") }
            let states = accessibilityStates(span)
            if !states.isEmpty { result.addAttribute(.accessibilityCustomText, value: states, range: local) }
        }
        return result
    }
    override func accessibilityValue() -> String? {
        let value = NSMutableString(string: string)
        for span in map.spans where (span.kind == .ai || span.kind == .fold || span.kind == .spacer) && NSMaxRange(span.range) <= value.length {
            value.replaceCharacters(in: span.range, with: String(repeating: " ", count: span.range.length))
        }
        return value as String
    }
    override func accessibilitySelectedText() -> String? {
        let ranges = selectedRanges.map(\.rangeValue)
        guard let first = ranges.first, let last = ranges.last else { return "" }
        let selection = NSUnionRange(first, last)
        return selection.length == 0 ? "" : accessibilityString(for: selection)
    }
    func spoken(_ span: TranscriptSpan) -> String {
        if span.kind == .fold, let model { return model.foldDescription(span.ids) }
        let states = accessibilityStates(span)
        if span.pause, !states.isEmpty { return states.joined(separator: ", ") }
        return ([(string as NSString).substring(with: span.range)] + states).joined(separator: ", ")
    }
    private func aiModified(_ span: TranscriptSpan) -> Bool {
        guard let model, !span.pause, let position = model.index(span.id) else { return false }
        let word = model.words[position]
        return model.project.voiceLab.segments.contains { segment in
            segment.enabled && segment.hasAISpeech && word.start >= segment.replace.start && word.end <= segment.replace.end
        }
    }
    private func accessibilityStates(_ span: TranscriptSpan) -> [String] {
        guard let model else { return [] }
        // A proposed change's new words, and the words it removes: "in the, proposed", "to, proposed
        // removal", read alike by word and as a line's attributed text.
        if span.kind == .inserted { return ["proposed"] }
        if span.pause {
            guard let pause = model.pauseIndex[span.id] else { return [] }
            return ["pause \(toFixed1(pause.duration)) seconds"] + (model.cutPauseIDs.contains(span.id) ? ["cut"] : [])
        }
        let modified = aiModified(span)
        var states: [String] = []
        if span.change?.role == .old { states.append("proposed removal") }
        // An accepted replacement never inherits the dormant source words' cut state.
        if !modified && model.cutWordIDs.contains(span.id) { states.append("cut") }
        if model.playingWordID.map({ span.id == $0 || span.ids.contains($0) }) == true { states.append("playing") }
        if modified { states.append("AI modified") }
        return states
    }
    override func keyDown(with event: NSEvent) {
        model?.focusedPane = .transcript
        if let row = model?.sendConfirmation, row.isPresented {
            if event.keyCode == 53 { row.cancel(); return }
            if (event.keyCode == 36 || event.keyCode == 76), event.modifierFlags.contains(.command) {
                _ = row.pressReturn(timestamp: event.timestamp, now: ProcessInfo.processInfo.systemUptime, isRepeat: event.isARepeat, command: true)
                return
            }
        }
        if event.keyCode == 53, model?.rewrite != nil { model?.closeRewrite(); return }
        guard let model, !hasMarkedText(), correction == nil else { super.keyDown(with: event); return }
        if event.keyCode == 53, foldPopoverVisible { hideFoldPopover(); return }
        if handleChangeKey(event, model: model) { return }
        if event.keyCode == 53, selectionBarVisible { hideSelectionBar(dismissed: true); return }
        if event.keyCode == 53 { model.activate(nil); return }
        if EditorPane.entersSelectionBar(code: event.keyCode, modifiers: event.modifierFlags) {
            if !model.selectedIDs.isEmpty { showSelectionBar(focus: true); return }
        }
        let shift = event.modifierFlags.contains(.shift)
        if event.modifierFlags.contains(.command) {
            if event.charactersIgnoringModifiers?.lowercased() == "k" {
                let modifiers = event.modifierFlags.intersection([.command, .option, .shift, .control])
                if modifiers == [.command, .shift] { model.requestFindClips(from: .clipBar) }
                else if modifiers == [.command, .option] { model.makeClip() }
                else if modifiers == .command {
                    let shell = (window?.windowController as? ShellWindowController)?.shell ?? model.app.shell
                    shell.openCommandPalette()
                }
                else { super.keyDown(with: event) }
                return
            }
            if shift, event.charactersIgnoringModifiers?.lowercased() == "r" { hideSelectionBar(dismissed: true); model.rewriteShortcut(); return }
            if event.keyCode == 126, let first = model.words.first { model.select(first.id); return }
            if event.keyCode == 125, let last = model.words.last { model.select(last.id); return }
            super.keyDown(with: event); return
        }
        switch event.keyCode {
        case 51, 117:
            if shift { model.cutSelection(restore: true) }
            else { model.toggleSelectionCut() }
        case 123: model.step(-1, extend: shift, sentence: event.modifierFlags.contains(.option))
        case 124: model.step(1, extend: shift, sentence: event.modifierFlags.contains(.option))
        case 115: if let first = model.words.first { model.select(first.id) }
        case 119: if let last = model.words.last { model.select(last.id) }
        default:
            let key = event.charactersIgnoringModifiers ?? ""
            if [" ", "j", "k", "l", "p", "c", "i", "o", "[", "]", "\r", "\u{1b}"].contains(key.lowercased()) { model.transport(key, shift: shift) } else { super.keyDown(with: event) }
        }
    }
    override func mouseDown(with event: NSEvent) {
        finishCorrection()
        hideFoldPopover()
        // A click on a proposed change's new words focuses it and opens its thread (design.md §6.3.5, §6.3).
        if event.clickCount == 1, event.modifierFlags.isDisjoint(with: [.shift, .command, .option, .control]), let model,
           let ordinal = insertedChange(at: convert(event.locationInWindow, from: nil)) {
            hideSelectionBar()
            window?.makeFirstResponder(self)
            model.focusChange(ordinal)
            renderNow()
            if model.proposalDisplay?.actions.isEmpty == false { openThread(ordinal) }
            return
        }
        // A click on a fold opens it and selects what it holds (notes.md §5).
        if event.clickCount == 1, event.modifierFlags.isDisjoint(with: [.shift, .command, .option, .control]), let model,
           let fold = fold(at: convert(event.locationInWindow, from: nil)) {
            hideSelectionBar()
            model.expandFold(fold.ids)
            window?.makeFirstResponder(self)
            scheduleSelectionBar()
            return
        }
        selecting = true; selectionDismissed = false; hideSelectionBar()
        super.mouseDown(with: event)
        selecting = false
        if event.clickCount == 2 { model?.beginCorrection(); updateCorrection() }
        if event.modifierFlags.contains(.option) { model?.transport(" ", shift: true) }
        scheduleSelectionBar()
    }
    override func mouseDragged(with event: NSEvent) { hideSelectionBar(); super.mouseDragged(with: event) }
    override func mouseUp(with event: NSEvent) { super.mouseUp(with: event); selecting = false; scheduleSelectionBar() }
    override func copy(_ sender: Any?) { model?.copySelection() }
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        for (title, action) in [("Cut", #selector(cutWords)), ("Restore", #selector(restoreWords)), ("Correct spelling…", #selector(correctWord)), ("Play from here", #selector(playHere)), ("Preview this cut", #selector(previewCut)), ("Make clip from selection", #selector(makeClip)), ("Copy text", #selector(copy(_:)))] { let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; menu.addItem(item) }
        let rewrite = NSMenuItem(title: model?.rewriteAsksFirst == true ? "Rewrite…" : "Rewrite", action: #selector(rewriteWords), keyEquivalent: "r")
        rewrite.keyEquivalentModifierMask = [.command, .shift]; rewrite.target = self; menu.addItem(rewrite)
        if let model, model.app.voiceLabRewriteEnabled, let segment = voiceLabSegment {
            let enabled = model.capabilities.edit && !model.capabilities.exporting && !model.capabilities.aiBusy
            menu.addItem(.separator())
            for (title, selector) in [(segment.enabled ? "Turn off" : "Turn on", #selector(toggleVoiceLab)), ("Delete AI passage", #selector(deleteVoiceLab))] {
                let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
                item.target = self; item.isEnabled = enabled; menu.addItem(item)
            }
            for index in segment.candidates.indices where segment.candidates[index].rejected == nil {
                let item = NSMenuItem(title: "Choose take \(index + 1)", action: #selector(chooseVoiceLab(_:)), keyEquivalent: "")
                item.tag = index; item.target = self; item.isEnabled = enabled
                item.state = index == segment.selectedCandidateIndex ? .on : .off
                menu.addItem(item)
            }
        }
        return menu
    }
    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if [#selector(toggleVoiceLab), #selector(deleteVoiceLab), #selector(chooseVoiceLab(_:))].contains(item.action) {
            return model?.app.voiceLabRewriteEnabled == true && voiceLabSegment != nil && model?.capabilities.edit == true && model?.capabilities.exporting == false && model?.capabilities.aiBusy == false
        }
        if item.action == #selector(rewriteWords) { return model?.capabilities.ai == true && model?.selectedIDs.isEmpty == false }
        if [#selector(cutWords), #selector(restoreWords)].contains(item.action) {
            return model?.capabilities.edit == true && (model?.selectedIDs.isEmpty == false || model?.selectedPauseIDs.isEmpty == false)
        }
        if [#selector(correctWord), #selector(makeClip)].contains(item.action) {
            return model?.capabilities.edit == true && model?.selectedIDs.isEmpty == false
        }
        return super.validateUserInterfaceItem(item)
    }
    @objc private func cutWords() { model?.cutSelection() }
    @objc private func restoreWords() { model?.cutSelection(restore: true) }
    @objc private func correctWord() { model?.beginCorrection(); updateCorrection() }
    @objc private func playHere() { model?.transport(" ", shift: true) }
    @objc private func previewCut() { model?.transport("p") }
    @objc private func makeClip() { model?.makeClip() }
    @objc private func rewriteWords() { model?.runRewrite() }
    private var voiceLabSegment: VoiceLabSegment? {
        guard let model else { return nil }
        return model.project.voiceLab.segments.first { segment in
            model.selectedWordIDs.contains { id in
                guard let position = model.index(id) else { return false }
                return model.words[position].start >= segment.replace.start && model.words[position].end <= segment.replace.end
            }
        }
    }
    @objc private func toggleVoiceLab() {
        guard let segment = voiceLabSegment else { return }
        try? model?.applyVoiceLab(.setEnabled(segmentID: segment.id, enabled: !segment.enabled))
    }
    @objc private func deleteVoiceLab() {
        guard let segment = voiceLabSegment else { return }
        try? model?.applyVoiceLab(.delete(segmentID: segment.id))
    }
    @objc private func chooseVoiceLab(_ sender: NSMenuItem) {
        guard let segment = voiceLabSegment else { return }
        try? model?.applyVoiceLab(.chooseCandidate(segmentID: segment.id, index: sender.tag))
    }
    func updateCorrection() {
        guard let model, let id = model.correctionID, let span = map.span(id: id) else { removeCorrectionField(refocus: correctionHasFocus); return }
        if correction != nil, correctionWordID != id { removeCorrectionField(refocus: false) }
        guard correction == nil, let window else { return }
        hideSelectionBar()
        // The word's own box, so a word after a fold is not half its kern short (`glyphX`).
        let rect = textBox(of: span.range) ?? convert(window.convertFromScreen(firstRect(forCharacterRange: span.range, actualRange: nil)), from: nil)
        let field = NSTextField(frame: CGRect(x: rect.minX, y: rect.minY, width: max(90, rect.width + 24), height: 28))
        field.stringValue = model.correctionText; field.font = DesignValues.transcriptFont(size: model.textSize); field.delegate = self; field.setAccessibilityLabel("Correct spelling, audio stays the same")
        addSubview(field); correction = field; correctionWordID = id; window.makeFirstResponder(field); field.selectText(nil)
    }
    #if DEBUG
    /// Installs a correction field without a window, for the headless correction tests.
    var correctionFieldForTests: NSTextField? {
        get { correction }
        set { correction = newValue; correctionWordID = model?.correctionID; if let newValue { newValue.delegate = self; addSubview(newValue) } }
    }
    #endif
    private var correctionHasFocus: Bool { correction?.currentEditor().map { window?.firstResponder === $0 } ?? false }
    /// Forgets the field before removing it, so the end-editing notice its removal sends is ignored.
    private func removeCorrectionField(refocus: Bool) {
        guard let field = correction else { return }
        correction = nil; correctionWordID = nil
        field.removeFromSuperview()
        if refocus { window?.makeFirstResponder(self) }
    }
    /// A click elsewhere or focus leaving the field ends the correction like an inline rename (EditorModel.endCorrection).
    private func finishCorrection() {
        guard let field = correction else { return }
        removeCorrectionField(refocus: false)
        model?.correctionText = field.stringValue
        model?.endCorrection()
    }
    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, field === correction else { return }
        model?.correctionText = field.stringValue
    }
    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, field === correction else { return }
        finishCorrection()
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard let model, let field = correction else { return false }
        switch selector {
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)): model.correctionText = field.stringValue; model.saveCorrection(advance: selector == #selector(NSResponder.insertTab(_:)))
        case #selector(NSResponder.cancelOperation(_:)): model.endCorrection(keep: false)
        default: return false
        }
        removeCorrectionField(refocus: true); updateCorrection(); return true
    }
}

/// The Rewrite thread's hosting view: its size changes as turns, bubbles and input lines come and go, and the transcript
/// keeps that much room under the paragraph.
@MainActor final class RewriteThreadHost: NSHostingView<RewriteThreadView> {
    var onResize: (() -> Void)?
    required init(rootView: RewriteThreadView) { super.init(rootView: rootView) }
    @MainActor @preconcurrency required init?(coder: NSCoder) { nil }
    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        onResize?()
    }
}
