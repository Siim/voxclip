import SwiftUI
import AppKit
import VoxClipCore

@MainActor struct TranscriptTextView: NSViewRepresentable {
    let model: EditorModel
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        let text = TranscriptNSTextView(usingTextLayoutManager: true)
        text.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        text.minSize = .zero; text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.model = model; text.delegate = context.coordinator; text.textLayoutManager?.delegate = context.coordinator
        text.isEditable = false; text.isSelectable = true; text.isRichText = true; text.drawsBackground = false
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false; text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = false
        text.textContainer?.containerSize = NSSize(width: TranscriptNSTextView.measure(forPane: 640), height: CGFloat.greatestFiniteMagnitude)
        text.textContainerInset = NSSize(width: VCTokens.spacingTranscriptGutter, height: 8)
        text.selectedTextAttributes = TranscriptNSTextView.selectionAttributes
        text.setAccessibilityLabel("Transcript. Select words, then Delete to cut. Return corrects spelling.")
        text.setAccessibilityCustomRotors(["Cuts", "Pauses", "Suggested fillers", "Clips", "AI words"].map { NSAccessibilityCustomRotor(label: $0, itemSearchDelegate: text) })
        text.setAccessibilityCustomActions([NSAccessibilityCustomAction(name: "Cut selected words", target: text, selector: #selector(TranscriptNSTextView.accessibleCut)), NSAccessibilityCustomAction(name: "Restore selection", target: text, selector: #selector(TranscriptNSTextView.accessibleRestore)), NSAccessibilityCustomAction(name: "Correct spelling", target: text, selector: #selector(TranscriptNSTextView.accessibleCorrect)), NSAccessibilityCustomAction(name: "Play from here", target: text, selector: #selector(TranscriptNSTextView.accessiblePlay))])
        scroll.documentView = text; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        context.coordinator.text = text
        let renderer = context.coordinator.renderer
        renderer.text = text
        text.textLayoutManager?.renderingAttributesValidator = { [weak renderer] _, fragment in
            MainActor.assumeIsolated { renderer?.validate(fragment) }
        }
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? TranscriptNSTextView else { return }
        let coordinator = context.coordinator
        let signature = "\(model.transcriptLayoutRevision):\(model.showCuts):\(model.showPauses):\(model.textSize):\(model.project.edits.pauseThresholdSeconds)"
        coordinator.updating = true
        if coordinator.signature != signature || !model.showCuts && coordinator.hiddenCuts != model.cutWordIDs {
            coordinator.signature = signature
            coordinator.hiddenCuts = model.cutWordIDs
            coordinator.renderer.rebuild(model: model)
        }
        coordinator.renderer.update(TranscriptAppearance(cutWords: model.cutWordIDs, cutPauses: model.cutPauseIDs, fillers: model.fillerIDs, playing: model.playingWordID, query: model.query, scope: model.scopeBounds, lowConfidence: model.app.bool("general.showLowConfidence"), activeClipID: model.activeClip?.id, rewrite: model.rewrite))
        let selected = (model.selectedWordIDs.union(model.selectedPauseIDs)).compactMap { text.map.span(id: $0) }.sorted { $0.range.location < $1.range.location }
        if let first = selected.first, let last = selected.last {
            let range = NSRange(location: first.range.location, length: NSMaxRange(last.range) - first.range.location)
            let ranges = text.map.selectionRanges(in: range).map { NSValue(range: $0) }
            if text.selectedRanges != ranges { text.selectedRanges = ranges }
        }
        coordinator.updating = false; text.updateCorrection()
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate, @preconcurrency NSTextLayoutManagerDelegate {
        let model: EditorModel
        weak var text: TranscriptNSTextView?
        var signature = "", updating = false
        var hiddenCuts: Set<String> = []
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
    override var renderingSurfaceBounds: CGRect { super.renderingSurfaceBounds.union(CGRect(x: -84, y: 0, width: 84, height: layoutFragmentFrame.height)) }
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
                func rect(for range: NSRange) -> CGRect {
                    let intersection = NSIntersectionRange(range, lineRange)
                    let start = line.locationForCharacter(at: intersection.location - offset)
                    let end = line.locationForCharacter(at: NSMaxRange(intersection) - offset)
                    return CGRect(x: point.x + line.typographicBounds.minX + min(start.x, end.x) - 2,
                                  y: point.y + line.typographicBounds.minY, width: max(4, abs(end.x - start.x) + 4), height: line.typographicBounds.height)
                }
                if !foreground {
                    for clip in renderer.clipMarks where NSIntersectionRange(clip.range, lineRange).length > 0 {
                        let selected = renderer.appearance?.activeClipID == clip.id
                        context.setStrokeColor((selected ? NSColor(DesignValues.accentText) : DesignValues.nsColor("line.strong")).cgColor)
                        context.setLineWidth(2)
                        context.setLineDash(phase: 0, lengths: clip.suggested ? [3, 3] : [])
                        let lower = point.y + line.typographicBounds.minY
                        let upper = lower + line.typographicBounds.height
                        context.move(to: CGPoint(x: point.x - 14, y: lower))
                        context.addLine(to: CGPoint(x: point.x - 14, y: upper))
                        context.strokePath()
                    }
                }
                let rewriting = text.map.intersecting(lineRange).filter { renderer.isRewriting($0.id) }
                if let first = rewriting.first, let last = rewriting.last {
                    let range = NSRange(location: first.range.location, length: NSMaxRange(last.range) - first.range.location)
                    let shape = CGPath(roundedRect: rect(for: range), cornerWidth: 4, cornerHeight: 4, transform: nil)
                    context.setLineDash(phase: 0, lengths: [])
                    context.addPath(shape)
                    if foreground { context.setStrokeColor(NSColor(DesignValues.accentText).cgColor); context.setLineWidth(1); context.strokePath() }
                    else { context.setFillColor(NSColor(DesignValues.accentSoft).cgColor); context.fillPath() }
                }
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
        if foreground, let paragraph = textElement as? NSTextParagraph, paragraph.attributedString.length > 0, let time = paragraph.attributedString.attribute(.vcTimecode, at: 0, effectiveRange: nil) as? NSAttributedString {
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            time.draw(at: CGPoint(x: point.x - 30 - time.size().width, y: point.y + 5))
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private func drawMarker(_ span: TranscriptSpan, rect: CGRect, renderer: TranscriptRenderer, context: CGContext) {
        let accent = NSColor(DesignValues.accentText)
        var box = CGRect(x: rect.minX + 2, y: rect.midY - 8, width: 16, height: 16)
        var label = ""
        var foreground = DesignValues.nsColor("text.secondary")
        var fill = DesignValues.nsColor("clip.badgeBackground")
        var outline: NSColor?
        var dashed = false
        switch span.kind {
        case .text: return
        case .badge(let number, let clipID, let suggested):
            label = String(number)
            dashed = suggested
            if renderer.appearance?.activeClipID == clipID {
                fill = DesignValues.accentFill
                foreground = DesignValues.nsColor("accent.on")
            }
            if suggested { outline = DesignValues.nsColor("line.strong") }
        case .bracket(let clipID, let suggested):
            context.setStrokeColor((renderer.appearance?.activeClipID == clipID ? accent : DesignValues.nsColor("line.strong")).cgColor)
            context.setLineWidth(1.5)
            context.setLineDash(phase: 0, lengths: suggested ? [3, 3] : [])
            let edge = rect.minX + 6
            context.move(to: CGPoint(x: edge - 4, y: box.minY))
            context.addLine(to: CGPoint(x: edge, y: box.minY))
            context.addLine(to: CGPoint(x: edge, y: box.maxY))
            context.addLine(to: CGPoint(x: edge - 4, y: box.maxY))
            context.strokePath()
            return
        case .ai:
            box.size.width = 23
            label = "AI"
            foreground = accent
            fill = NSColor(DesignValues.accentSoft)
            outline = accent
        }
        context.setFillColor(fill.cgColor)
        let path = CGPath(roundedRect: box, cornerWidth: 4, cornerHeight: 4, transform: nil)
        context.addPath(path); context.fillPath()
        if let outline {
            context.setStrokeColor(outline.cgColor); context.setLineWidth(1)
            context.setLineDash(phase: 0, lengths: dashed ? [3, 3] : [])
            context.addPath(path); context.strokePath()
        }
        let font = NSFont.monospacedSystemFont(ofSize: span.kind == .ai ? 10 : 11, weight: .semibold)
        let title = NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: foreground])
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        title.draw(at: CGPoint(x: box.midX - title.size().width / 2, y: box.midY - title.size().height / 2))
        NSGraphicsContext.restoreGraphicsState()
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

    /// The transcript measure (design §3.7): the pane less the 84 gutter and 32 of
    /// trailing padding, kept between 480 and 680, and never wider than the pane after
    /// the gutter, so a narrow pane wraps rather than clips. Text starts after the gutter.
    static func measure(forPane width: Double) -> Double {
        let gutter = Double(VCTokens.spacingTranscriptGutter)
        return max(120, min((width - gutter - 32).clamped(to: 480...Double(VCTokens.sizeTranscriptMeasureMax)), width - gutter))
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
    var map = TranscriptRangeMap(spans: [])
    private var correction: NSTextField?
    @objc func accessibleCut() -> Bool { guard let model, !model.selectedIDs.isEmpty || !model.selectedPauseIDs.isEmpty else { return false }; model.cutSelection(); return true }
    @objc func accessibleRestore() -> Bool { guard let model else { return false }; model.cutSelection(restore: true); return true }
    @objc func accessibleCorrect() -> Bool { guard let model, !model.selectedIDs.isEmpty else { return false }; model.beginCorrection(); updateCorrection(); return true }
    @objc func accessiblePlay() -> Bool { guard let model else { return false }; model.transport(" ", shift: true); return true }
    func rotor(_ rotor: NSAccessibilityCustomRotor, resultFor parameters: NSAccessibilityCustomRotor.SearchParameters) -> NSAccessibilityCustomRotor.ItemResult? {
        guard let model else { return nil }
        let candidates = map.spans.filter { span in
            switch rotor.label {
            case "Cuts": model.project.edits.cutWordIds.contains(span.id) || model.project.edits.cutPauseIds.contains(span.id)
            case "Pauses": span.pause
            case "Suggested fillers": model.fillerIDs.contains(span.id)
            case "Clips": model.sortedClips.contains { $0.startWordId == span.id }
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
        result.customLabel = "\(spoken(span)), \(rotor.label)"
        return result
    }
    override func accessibilityString(for range: NSRange) -> String? {
        map.intersecting(range).filter(\.selectable).map(spoken).joined(separator: " ")
    }
    private func spoken(_ span: TranscriptSpan) -> String {
        guard let model else { return (string as NSString).substring(with: span.range) }
        if span.pause, let pause = model.pauseIndex[span.id] {
            let suffix = model.cutPauseIDs.contains(span.id) ? ", cut" : ""
            return "pause \(toFixed1(pause.duration)) seconds\(suffix)"
        }
        var value = (string as NSString).substring(with: span.range)
        if let position = model.index(span.id), let plan = model.voiceLabPlan {
            let word = model.words[position]
            if plan.pieces.contains(where: { $0.kind == .synth && word.start >= Double($0.sourceStartSample) / plan.sampleRate && word.end <= Double($0.sourceEndSample) / plan.sampleRate }) { value += ", AI modified" }
        }
        return value
    }
    override func keyDown(with event: NSEvent) {
        guard let model, !hasMarkedText(), correction == nil else { super.keyDown(with: event); return }
        let shift = event.modifierFlags.contains(.shift)
        if event.modifierFlags.contains(.command) {
            if event.keyCode == 126, let first = model.words.first { model.select(first.id); return }
            if event.keyCode == 125, let last = model.words.last { model.select(last.id); return }
            super.keyDown(with: event); return
        }
        switch event.keyCode {
        case 51, 117: model.cutSelection(restore: shift)
        case 123: model.step(-1, extend: shift, sentence: event.modifierFlags.contains(.option))
        case 124: model.step(1, extend: shift, sentence: event.modifierFlags.contains(.option))
        case 115: if let first = model.words.first { model.select(first.id) }
        case 119: if let last = model.words.last { model.select(last.id) }
        default:
            let key = event.charactersIgnoringModifiers ?? ""
            if [" ", "j", "k", "l", "p", "c", "i", "o", "[", "]", "\r", "\u{1b}"].contains(key.lowercased()) { model.transport(key, shift: shift) } else { super.keyDown(with: event) }
        }
    }
    override func mouseDown(with event: NSEvent) { super.mouseDown(with: event); if event.clickCount == 2 { model?.beginCorrection(); updateCorrection() }; if event.modifierFlags.contains(.option) { model?.transport(" ", shift: true) } }
    override func copy(_ sender: Any?) { model?.copySelection() }
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        for (title, action) in [("Cut", #selector(cutWords)), ("Restore", #selector(restoreWords)), ("Correct spelling…", #selector(correctWord)), ("Play from here", #selector(playHere)), ("Preview this cut", #selector(previewCut)), ("Make clip from selection", #selector(makeClip)), ("Copy text", #selector(copy(_:)))] { let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; menu.addItem(item) }
        return menu
    }
    @objc private func cutWords() { model?.cutSelection() }
    @objc private func restoreWords() { model?.cutSelection(restore: true) }
    @objc private func correctWord() { model?.beginCorrection(); updateCorrection() }
    @objc private func playHere() { model?.transport(" ", shift: true) }
    @objc private func previewCut() { model?.transport("p") }
    @objc private func makeClip() { model?.makeClip() }
    func updateCorrection() {
        guard let model, let id = model.correctionID, let span = map.span(id: id) else { correction?.removeFromSuperview(); correction = nil; return }
        guard correction == nil, let window else { return }
        let rect = convert(window.convertFromScreen(firstRect(forCharacterRange: span.range, actualRange: nil)), from: nil)
        let field = NSTextField(frame: CGRect(x: rect.minX, y: rect.minY, width: max(90, rect.width + 24), height: 28))
        field.stringValue = model.correctionText; field.font = DesignValues.transcriptFont(size: model.textSize); field.delegate = self; field.setAccessibilityLabel("Correct spelling, audio stays the same")
        addSubview(field); correction = field; window.makeFirstResponder(field); field.selectText(nil)
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard let model, let field = correction else { return false }
        switch selector {
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)): model.correctionText = field.stringValue; model.saveCorrection(advance: selector == #selector(NSResponder.insertTab(_:)))
        case #selector(NSResponder.cancelOperation(_:)): model.correctionID = nil
        default: return false
        }
        field.removeFromSuperview(); correction = nil; window?.makeFirstResponder(self); updateCorrection(); return true
    }
}
