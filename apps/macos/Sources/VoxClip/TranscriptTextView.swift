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
        text.selectedTextAttributes = TranscriptNSTextView.selectionAttributes
        text.setAccessibilityLabel("Transcript. Select words, then Delete to cut. Return corrects spelling.")
        text.setAccessibilityCustomRotors(["Cuts", "Pauses", "Suggested fillers", "Clips", "AI words"].map { NSAccessibilityCustomRotor(label: $0, itemSearchDelegate: text) })
        text.configureAccessibilityActions()
        text.installBackdrop()
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
        let signature = "\(model.transcriptLayoutRevision):\(model.showCuts):\(model.showPauses):\(model.textSize):\(model.project.edits.pauseThresholdSeconds)"
        coordinator.updating = true
        if coordinator.signature != signature || !model.showCuts && coordinator.hiddenCuts != model.cutWordIDs {
            coordinator.signature = signature
            coordinator.hiddenCuts = model.cutWordIDs
            coordinator.renderer.rebuild(model: model)
        }
        coordinator.renderer.update(TranscriptAppearance(cutWords: model.cutWordIDs, cutPauses: model.cutPauseIDs, fillers: model.fillerIDs, playing: model.playingWordID, query: model.query, scope: model.scopeBounds, lowConfidence: model.app.bool("general.showLowConfidence"), activeClipID: model.activeClip?.id, playhead: model.sourceTime))
        scroll.overviewRuler.marks = TranscriptOverviewRuler.marks(model: model)
        let selected = (model.selectedWordIDs.union(model.selectedPauseIDs)).compactMap { text.map.span(id: $0) }.sorted { $0.range.location < $1.range.location }
        if let first = selected.first, let last = selected.last {
            let range = NSRange(location: first.range.location, length: NSMaxRange(last.range) - first.range.location)
            let ranges = text.map.selectionRanges(in: range).map { NSValue(range: $0) }
            if text.selectedRanges != ranges { text.selectedRanges = ranges }
        }
        coordinator.updating = false; text.updateCorrection(); text.refreshSelectionBar()
        if coordinator.scopeScrollRevision != model.scopeScrollRevision {
            coordinator.scopeScrollRevision = model.scopeScrollRevision
            let id = model.activeClip?.startWordId ?? model.words.first?.id
            if let id, let span = text.map.span(id: id) {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = EditorAccessibilityPolicy.system.transcriptScrollDuration
                    text.scrollRangeToVisible(span.range)
                }
            }
        }
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate, @preconcurrency NSTextLayoutManagerDelegate {
        let model: EditorModel
        weak var text: TranscriptNSTextView?
        var signature = "", updating = false
        var hiddenCuts: Set<String> = []
        var scopeScrollRevision = 0
        let renderer = TranscriptRenderer()
        init(model: EditorModel) { self.model = model }
        func textView(_ textView: NSTextView, willChangeSelectionFromCharacterRanges old: [NSValue], toCharacterRanges proposed: [NSValue]) -> [NSValue] {
            guard !updating, let text = textView as? TranscriptNSTextView else { return proposed }
            let ranges = proposed.flatMap { text.map.selectionRanges(in: $0.rangeValue) }
            return ranges.isEmpty ? old : ranges.map { NSValue(range: $0) }
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard !updating, let text else { return }
            let spans = text.selectedRanges.flatMap { text.map.intersecting($0.rangeValue).filter(\.selectable) }; model.selectedWordIDs = Set(spans.filter { !$0.pause }.flatMap { $0.ids.isEmpty ? [$0.id] : $0.ids })
            model.selectedPauseIDs = Set(spans.filter(\.pause).map(\.id))
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
        MainActor.assumeIsolated { fragment.value.drawDecorations(at: point, in: drawingContext.value, foreground: false) }
        super.draw(at: point, in: context)
        MainActor.assumeIsolated { fragment.value.drawDecorations(at: point, in: drawingContext.value, foreground: true) }
    }
    private func drawDecorations(at point: CGPoint, in context: CGContext, foreground: Bool) {
        context.saveGState()
        defer { context.restoreGState() }
        if let renderer, let text = renderer.text, let content = textLayoutManager?.textContentManager, let element = textElement, let elementRange = element.elementRange {
            let offset = content.offset(from: content.documentRange.location, to: elementRange.location)
            for line in textLineFragments {
                let lineRange = NSRange(location: offset + line.characterRange.location, length: line.characterRange.length)
                if foreground { drawGutter(line: line, lineRange: lineRange, offset: offset, at: point, renderer: renderer, text: text, context: context) }
                for span in text.map.intersecting(lineRange) {
                    let intersection = NSIntersectionRange(span.range, lineRange)
                    guard intersection.length > 0 else { continue }
                    let start = line.locationForCharacter(at: intersection.location - offset)
                    let end = line.locationForCharacter(at: NSMaxRange(intersection) - offset)
                    let rect = CGRect(x: point.x + line.typographicBounds.minX + min(start.x, end.x) - 2, y: point.y + line.typographicBounds.minY, width: max(4, abs(end.x - start.x) + 4), height: line.typographicBounds.height)
                    let attributes = renderer.attributes[span.id] ?? [:]
                    if foreground, !span.selectable {
                        drawMarker(span, rect: rect, renderer: renderer, context: context)
                        continue
                    }
                    if !foreground, let color = attributes[.vcRounded] as? NSColor {
                        let radius = CGFloat((attributes[.vcRadius] as? NSNumber)?.doubleValue ?? 4)
                        context.setFillColor(color.cgColor); context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)); context.fillPath()
                    }
                    guard foreground else { continue }
                    let fontIndex = min(line.attributedString.length - 1, max(0, intersection.location - offset))
                    let font = line.attributedString.attribute(.font, at: fontIndex, effectiveRange: nil) as? NSFont ?? DesignValues.transcriptFont(size: DesignValues.transcriptTextSize)
                    let baseline = point.y + line.typographicBounds.minY + line.glyphOrigin.y
                    let lower = rect.minX + 2, upper = rect.maxX - 2
                    if attributes[.vcStrike] as? Bool == true {
                        context.setStrokeColor(DesignValues.nsColor("cut.stroke").cgColor)
                        context.setLineWidth(DesignValues.dimension("stroke.cutStrike", fallback: 1.5))
                        context.setLineDash(phase: 0, lengths: [])
                        context.move(to: CGPoint(x: lower, y: baseline - font.xHeight / 2))
                        context.addLine(to: CGPoint(x: upper, y: baseline - font.xHeight / 2)); context.strokePath()
                    }
                    if let underline = attributes[.vcUnderline] as? Int, let color = attributes[.vcUnderlineColor] as? NSColor {
                        let row = baseline - font.underlinePosition + 1
                        context.setStrokeColor(color.cgColor); context.setLineWidth(underline == 1 ? 1.5 : 1)
                        context.setLineCap(underline == 1 ? .round : .butt)
                        context.setLineDash(phase: 0, lengths: underline == 1 ? [0.5, 2.5] : [4, 3])
                        context.move(to: CGPoint(x: lower, y: row)); context.addLine(to: CGPoint(x: upper, y: row)); context.strokePath()
                    }
                    if renderer.hasCorrection(span.id), intersection.location == span.range.location {
                        context.setFillColor(DesignValues.nsColor("word.correctionDot").cgColor)
                        context.fillEllipse(in: CGRect(x: point.x + line.typographicBounds.minX + start.x, y: rect.maxY - 2, width: 2, height: 2))
                    }
                }
            }
        }
    }

    /// The gutter of one line (notes.md §5): the paragraph's timecode on its first line,
    /// right-aligned at 42 in SF Mono 11 (gutter.text in the open clip, gutter.textOut
    /// outside, text.secondary for the playhead's paragraph), and the line's glyph at 49–63.
    /// The change bar at 66 stays empty until proposals draw hunks.
    private func drawGutter(line: NSTextLineFragment, lineRange: NSRange, offset: Int, at point: CGPoint, renderer: TranscriptRenderer, text: TranscriptNSTextView, context: CGContext) {
        let left = point.x - layoutFragmentFrame.minX - text.textContainerOrigin.x
        let box = TranscriptGutter.visualBox(of: line, font: renderer.font).offsetBy(dx: 0, dy: point.y)
        if line.characterRange.location == 0, let index = renderer.paragraph(atCharacter: offset), renderer.paragraphs[index].offset == offset {
            let color = renderer.currentParagraph == index ? DesignValues.nsColor("text.secondary")
                : DesignValues.nsColor(renderer.isInScope(paragraph: index) ? "gutter.text" : "gutter.textOut")
            TranscriptGutter.drawTimecode(TranscriptGutter.timecode(renderer.paragraphs[index].start), color: color, right: left + TranscriptGutter.timecodeRight, box: box, in: context)
        }
        if text.map.intersecting(lineRange).contains(where: { renderer.aiWordIDs.contains($0.id) && NSIntersectionRange($0.range, lineRange).length > 0 }) {
            GutterGlyph.aiVoice.draw(in: TranscriptGutter.glyphBox(left: left, line: box), context: context)
        }
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

@MainActor final class TranscriptNSTextView: NSTextView, NSTextFieldDelegate, @preconcurrency NSAccessibilityCustomRotorItemSearchDelegate {
    weak var model: EditorModel?
    /// Selected words read in text.primary on the platform selection (selection.text), so
    /// cut and filler colours never sit on it; Increase Contrast takes the system's pair.
    static let selectionAttributes: [NSAttributedString.Key: Any] = {
        let primary = DesignValues.nsColor("text.primary")
        let text = NSColor(name: NSColor.Name("voxclip.selectedTranscriptText")) { appearance in
            appearance.bestMatch(from: [.accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua, .aqua, .darkAqua])?.rawValue.contains("HighContrast") == true ? .selectedTextColor : primary
        }
        return [.backgroundColor: NSColor.selectedTextBackgroundColor, .foregroundColor: text]
    }()

    /// The transcript measure (notes.md §1 and §4): the pane less the 80 gutter and 44 of
    /// right padding, kept between 480 and 680, and never wider than the pane after the
    /// gutter, so a narrow pane wraps rather than clips. Text starts after the gutter.
    static func measure(forPane width: Double) -> Double {
        let gutter = Double(TranscriptGutter.width)
        return max(120, min((width - gutter - Double(TranscriptGutter.trailing)).clamped(to: 480...Double(VCTokens.sizeTranscriptMeasureMax)), width - gutter))
    }
    /// A transcript that arrives after the editor showed, for example when transcription
    /// finishes, takes the keyboard focus the editor still wants.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
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
    /// Every viewport layout (scrolling, resizing, new text) moves the backdrop and the
    /// overview ruler's visible window with the lines TextKit just placed.
    override func textViewportLayoutControllerDidLayout(_ controller: NSTextViewportLayoutController) {
        super.textViewportLayoutControllerDidLayout(controller)
        updateBackdrop()
        (enclosingScrollView as? TranscriptScrollView)?.overviewRuler.visibleSpan = visibleTakeSpan()
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
        guard let model, let manager = textLayoutManager, let content = manager.textContentManager, !map.spans.isEmpty else { return nil }
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
        let signature = "\(model.selectedWordIDs.sorted()):\(model.selectedPauseIDs.sorted()):\(model.findVisible):\(model.correctionID ?? ""):\(model.cutWordIDs):\(model.cutPauseIDs):\(model.capabilities):\(model.app.voiceLabRewriteEnabled)"
        guard signature != barSignature else { return }
        barSignature = signature
        configureAccessibilityActions()
        scheduleSelectionBar()
    }
    func selectionDidChange() { selectionDismissed = false; scheduleSelectionBar() }
    override func viewWillMove(toSuperview newSuperview: NSView?) {
        if newSuperview == nil {
            hideSelectionBar()
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
        if model?.capabilities.ai == true && model?.app.voiceLabRewriteEnabled == true { actions.append(NSAccessibilityCustomAction(name: "Rewrite", target: self, selector: #selector(accessibleRewrite))) }
        setAccessibilityCustomActions(actions)
    }
    func observeSelectionScrolling(_ scroll: NSScrollView) {
        for token in scrollingTokens { NotificationCenter.default.removeObserver(token) }
        scrollingTokens = [NotificationCenter.default.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: scroll, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.liveScrolling = true; self?.hideSelectionBar() }
        }, NotificationCenter.default.addObserver(forName: NSScrollView.didEndLiveScrollNotification, object: scroll, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.liveScrolling = false; self?.scheduleSelectionBar() }
        }]
    }
    func hideSelectionBar(dismissed: Bool = false) {
        selectionTask?.cancel(); selectionTask = nil
        selectionBar?.isHidden = true
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
                let starts = intersections.map { line.locationForCharacter(at: $0.location - offset).x }
                let ends = intersections.map { line.locationForCharacter(at: NSMaxRange($0) - offset).x }
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
    #endif
    func showSelectionBar(focus: Bool = false) {
        guard let model, !selecting, !liveScrolling, model.correctionID == nil, !model.findVisible else { return }
        if focus { barFocusRequest += 1; selectionDismissed = false }
        let view = SelectionBar(model: model, focusRequest: barFocusRequest) { [weak self] in
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
        let wasHidden = host.isHidden
        host.isHidden = false
        let fade = EditorAccessibilityPolicy.system.crossfadeDuration
        if wasHidden && fade > 0 {
            host.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in context.duration = fade; host.animator().alphaValue = 1 }
        } else { host.alphaValue = 1 }
    }
    @objc func accessibleMakeClip() -> Bool { guard model?.capabilities.edit == true, model?.selectedIDs.isEmpty == false else { return false }; model?.makeClip(); return true }
    @objc func accessibleRewrite() -> Bool { guard model?.capabilities.ai == true && model?.app.voiceLabRewriteEnabled == true, model?.selectedIDs.isEmpty == false else { return false }; model?.beginRewrite(entry: .context); return true }
    @objc func accessibleCut() -> Bool { guard let model, model.capabilities.edit, !model.selectedIDs.isEmpty || !model.selectedPauseIDs.isEmpty else { return false }; model.cutSelection(); return true }
    @objc func accessibleRestore() -> Bool { guard let model, model.capabilities.edit else { return false }; model.cutSelection(restore: true); return true }
    @objc func accessibleCorrect() -> Bool { guard let model, model.capabilities.edit, !model.selectedIDs.isEmpty else { return false }; model.beginCorrection(); updateCorrection(); return true }
    @objc func accessiblePlay() -> Bool { guard let model else { return false }; model.transport(" ", shift: true); return true }
    func rotor(_ rotor: NSAccessibilityCustomRotor, resultFor parameters: NSAccessibilityCustomRotor.SearchParameters) -> NSAccessibilityCustomRotor.ItemResult? {
        guard let model else { return nil }
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
    /// The Clips rotor names the clips that start at a word as the Explorer does ("Clip 1,
    /// Title" or "Suggested clip 3, Title"), since the transcript no longer marks them.
    private func clipNames(startingAt span: TranscriptSpan, model: EditorModel) -> String {
        model.sortedClips.filter { map.span(id: $0.startWordId) == span }.map { clip in
            let number = model.clipNumber(clip.id) ?? 1
            return "\(model.isSuggestion(clip.id) ? "Suggested clip" : "Clip") \(number), \(clip.title ?? "Untitled clip")"
        }.joined(separator: "; ")
    }
    override func accessibilityString(for range: NSRange) -> String? {
        map.intersecting(range).filter(\.selectable).map(spoken).joined(separator: " ")
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
            if !span.selectable { result.replaceCharacters(in: local, with: String(repeating: " ", count: local.length)); continue }
            if span.pause || collapsedCut(span), overlap.location == span.range.location { result.replaceCharacters(in: NSRange(location: local.location, length: 1), with: " ") }
            let states = accessibilityStates(span)
            if !states.isEmpty { result.addAttribute(.accessibilityCustomText, value: states, range: local) }
        }
        return result
    }
    override func accessibilityValue() -> String? {
        let value = NSMutableString(string: string)
        for span in map.spans where !span.selectable && NSMaxRange(span.range) <= value.length {
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
        let states = accessibilityStates(span)
        if span.pause || collapsedCut(span), !states.isEmpty { return states.joined(separator: ", ") }
        return ([(string as NSString).substring(with: span.range)] + states).joined(separator: ", ")
    }
    /// A run of cut words shown as "⋯ n cut". An accepted Voice Lab replacement also lists its source words but reads as words.
    private func collapsedCut(_ span: TranscriptSpan) -> Bool { !span.ids.isEmpty && !aiModified(span) }
    private func aiModified(_ span: TranscriptSpan) -> Bool {
        guard let model, !span.pause, let position = model.index(span.id) else { return false }
        let word = model.words[position]
        return model.project.voiceLab.segments.contains { segment in
            segment.enabled && word.start >= segment.replace.start && word.end <= segment.replace.end
        }
    }
    private func accessibilityStates(_ span: TranscriptSpan) -> [String] {
        guard let model else { return [] }
        if span.pause {
            guard let pause = model.pauseIndex[span.id] else { return [] }
            return ["pause \(toFixed1(pause.duration)) seconds"] + (model.cutPauseIDs.contains(span.id) ? ["cut"] : [])
        }
        if collapsedCut(span) { return [span.ids.count == 1 ? "1 cut word" : "\(span.ids.count) cut words"] }
        let modified = aiModified(span)
        var states: [String] = []
        // An accepted replacement never inherits the dormant source words' cut state.
        if !modified && model.cutWordIDs.contains(span.id) { states.append("cut") }
        if model.playingWordID.map({ span.id == $0 || span.ids.contains($0) }) == true { states.append("playing") }
        if modified { states.append("AI modified") }
        return states
    }
    override func keyDown(with event: NSEvent) {
        model?.focusedPane = .transcript
        if event.keyCode == 53, model?.rewrite != nil { model?.closeRewrite(); return }
        guard let model, !hasMarkedText(), correction == nil else { super.keyDown(with: event); return }
        if event.keyCode == 53, selectionBarVisible { hideSelectionBar(dismissed: true); return }
        if event.keyCode == 53 { model.activate(nil); return }
        if EditorPane.entersSelectionBar(code: event.keyCode, modifiers: event.modifierFlags) {
            if !model.selectedIDs.isEmpty { showSelectionBar(focus: true); return }
        }
        let shift = event.modifierFlags.contains(.shift)
        if event.modifierFlags.contains(.command) {
            if event.charactersIgnoringModifiers?.lowercased() == "k" {
                if shift { model.requestFindClips(from: .overflow) } else { model.makeClip() }
                return
            }
            if shift, event.charactersIgnoringModifiers?.lowercased() == "r" { model.beginRewrite(entry: .shortcut); return }
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
        if model?.app.voiceLabRewriteEnabled == true { let item = NSMenuItem(title: "Rewrite…", action: #selector(rewriteWords), keyEquivalent: "r"); item.keyEquivalentModifierMask = [.command, .shift]; item.target = self; menu.addItem(item) }
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
        if item.action == #selector(rewriteWords) { return model?.app.voiceLabRewriteEnabled == true && model?.capabilities.ai == true && model?.selectedIDs.isEmpty == false }
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
    @objc private func rewriteWords() { model?.beginRewrite(entry: .context) }
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
        let rect = convert(window.convertFromScreen(firstRect(forCharacterRange: span.range, actualRange: nil)), from: nil)
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
