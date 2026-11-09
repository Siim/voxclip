import AppKit
import SwiftUI
import VoxClipCore

/// "Talk back to Claude" under the focused change's paragraph (design.md §6.3, ux/rewrite-chat mockup frame A with D's
/// version arrows and B's "3 more versions" bubble). In the transcript's flow, indented to the text column, with a 2 pt
/// `change.add` rule at 45 % and no box. The last two turns, "‹ 2 of 2 ›" with what Keep will voice, the bubbles, the
/// input and its cost line. The transcript keeps its height free under the paragraph (`TranscriptNSTextView.updateThread`).
@MainActor struct RewriteThreadView: View {
    let model: EditorModel
    let width: CGFloat
    /// The rule's colour: `change.add` at 45 %.
    static let ruleOpacity = 0.45
    static let ruleWidth: CGFloat = 2
    static let inset: CGFloat = 12

    var body: some View {
        if let display = model.rewriteThreadDisplay {
            content(display)
                .padding(.leading, Self.inset)
                .padding(.vertical, 2)
                .frame(width: width, alignment: .leading)
                .overlay(alignment: .leading) {
                    Rectangle().fill(DesignValues.color("change.add").opacity(Self.ruleOpacity)).frame(width: Self.ruleWidth).accessibilityHidden(true)
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(display.label)
                .accessibilityIdentifier("voxclip.rewriteThread")
        }
    }

    private func content(_ display: RewriteThreadDisplay) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(display.turns.enumerated()), id: \.offset) { _, turn in TurnLine(turn: turn) }
            versionRow(display)
            ClipStyleFlowLayout(spacing: VCTokens.spacingChipGap) {
                RewriteThreadBubble(title: display.keep, kind: .keep, identifier: "voxclip.rewriteThread.keep") { model.pressRewriteThreadBubble(display.keep) }
                    .help("Keep this change (⌘↩)")
                ForEach(display.steps, id: \.self) { step in
                    RewriteThreadBubble(title: step, kind: .claude, identifier: "voxclip.rewriteThread.step.\(step)") { model.pressRewriteThreadBubble(step) }
                }
                ForEach(display.steady, id: \.self) { title in
                    RewriteThreadBubble(title: title, kind: .steady, identifier: "voxclip.rewriteThread.bubble.\(title)") { model.pressRewriteThreadBubble(title) }
                }
            }
            .disabled(display.sending)
            ConnectorConfirmationView(confirmation: model.rewriteThread.confirmation, model: model)
            inputRow(display)
            if let error = display.error {
                HStack(alignment: .firstTextBaseline, spacing: VCTokens.spacingRowGap) {
                    Text(error).font(VCType.callout.font()).foregroundStyle(DesignValues.color("status.dangerForeground"))
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Try Again") { model.retryRewriteThread() }.buttonStyle(.link).font(VCType.callout.font())
                        .accessibilityIdentifier("voxclip.rewriteThread.tryAgain")
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("voxclip.rewriteThread.error")
            }
        }
        .onAppear { model.rewriteThread.follow(display.key) }
        .onChange(of: display.key) { _, key in model.rewriteThread.follow(key) }
    }

    /// "‹ 2 of 2 ›" (D's arrows), then what Keep will voice.
    private func versionRow(_ display: RewriteThreadDisplay) -> some View {
        HStack(spacing: 4) {
            arrow("chevron.left", label: "Previous version", enabled: display.version > 1 && !display.sending) { model.switchRewriteThreadVersion(by: -1) }
            Text(display.versionLine).font(VCType.callout.font()).monospacedDigit().foregroundStyle(DesignValues.color("text.secondary"))
                .accessibilityLabel("Version \(display.version) of \(display.versions)")
            arrow("chevron.right", label: "Next version", enabled: display.version < display.versions && !display.sending) { model.switchRewriteThreadVersion(by: 1) }
            Text(display.phrasesLine).font(VCType.callout.font()).foregroundStyle(DesignValues.color("text.secondary")).padding(.leading, 2)
                .help(model.changeFit(display.ordinal, text: model.changeText(display.ordinal)) ?? "")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Versions")
        .accessibilityIdentifier("voxclip.rewriteThread.versions")
    }

    private func arrow(_ symbol: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
                .foregroundStyle(DesignValues.color(enabled ? "text.primary" : "text.disabled"))
                .frame(width: 18, height: 18)
                .overlay(Capsule().strokeBorder(DesignValues.color("line.default"), lineWidth: 1))
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(label + (symbol == "chevron.left" ? " (⌥←)" : " (⌥→)"))
        .accessibilityLabel(label)
        .accessibilityIdentifier("voxclip.rewriteThread.\(symbol == "chevron.left" ? "previous" : "next")")
    }

    /// The input with ↵, or the one-line spinner and Stop while Claude works; the cost line beside it in text.tertiary.
    private func inputRow(_ display: RewriteThreadDisplay) -> some View {
        HStack(alignment: .center, spacing: VCTokens.spacingRowGap) {
            if display.sending {
                HStack(spacing: VCTokens.spacingLabelGap) {
                    ProgressView().controlSize(.small)
                    Text("Claude is working on it").font(VCType.body.font()).foregroundStyle(DesignValues.color("text.secondary")).lineLimit(1)
                    Spacer(minLength: VCTokens.spacingRowGap)
                    Button("Stop") { model.stopRewriteThread() }.buttonStyle(.link).font(VCType.callout.font())
                        .accessibilityIdentifier("voxclip.rewriteThread.stop")
                }
                .padding(.horizontal, VCTokens.spacingFieldPaddingX).frame(minHeight: 30)
                .background(DesignValues.color("bg.input"), in: .rect(cornerRadius: 10))
                .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(DesignValues.color("line.edge"), lineWidth: 1) }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Claude is working on it")
                .accessibilityIdentifier("voxclip.rewriteThread.working")
            } else {
                RewriteThreadInputBox(model: model, ordinal: display.ordinal)
            }
            if !display.costLine.isEmpty {
                Text(display.costLine).font(VCType.small.font()).foregroundStyle(DesignValues.color("text.tertiary")).lineLimit(1).fixedSize()
                    .accessibilityIdentifier("voxclip.rewriteThread.cost")
            }
        }
    }
}

/// "You" or "✦ Claude", then the words (the mockup's 13 pt lines).
private struct TurnLine: View {
    let turn: RewriteThread.Turn
    var body: some View {
        let you = turn.speaker == .you
        (Text(you ? "You" : "\u{2726} Claude").fontWeight(.semibold).foregroundStyle(you ? DesignValues.color("text.secondary") : DesignValues.accentText)
         + Text("  " + turn.text).foregroundStyle(DesignValues.color("text.primary")))
            .font(VCType.body.font())
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel((you ? "You: " : "Claude: ") + turn.text)
    }
}

/// One bubble (the mockup's `.bubble`): a 24 pt capsule. "✓ That's it, keep it" on `change.add`; Claude's own with a ✦ and
/// the AI accent's outline; the steady ones on `bg.muted`.
struct RewriteThreadBubble: View {
    enum Kind { case keep, claude, steady }
    let title: String
    let kind: Kind
    let identifier: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if kind == .claude { Text("\u{2726}").foregroundStyle(DesignValues.accentText) }
                Text(title).foregroundStyle(DesignValues.color("text.primary"))
            }
            .font(.system(size: 12, weight: kind == .keep ? .semibold : .regular))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(minHeight: 24)
            .background(fill, in: .capsule)
            .overlay(Capsule().strokeBorder(edge, lineWidth: 1))
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(kind == .claude ? "\(title), suggested by Claude" : title)
        .accessibilityIdentifier(identifier)
    }
    private var fill: Color {
        kind == .keep ? DesignValues.color("change.add").opacity(0.22) : DesignValues.color("bg.muted")
    }
    private var edge: Color {
        switch kind {
        case .keep: DesignValues.color("change.add").opacity(0.55)
        case .claude: DesignValues.accentText.opacity(0.55)
        case .steady: DesignValues.color("line.default")
        }
    }
}

/// The input's box: 1 to 4 lines of `RewriteThreadInputField`, the ↵ hint at its end, radius 10 (the mockup's `.input`).
private struct RewriteThreadInputBox: View {
    let model: EditorModel
    let ordinal: Int
    @State private var height: CGFloat = RewriteThreadInputField.height(lines: 1)
    var body: some View {
        HStack(alignment: .bottom, spacing: VCTokens.spacingLabelGap) {
            RewriteThreadInputField(model: model, ordinal: ordinal, height: $height).frame(height: height)
            Text("\u{21A9}").font(VCType.label.nsMonoFont).foregroundStyle(DesignValues.color("text.tertiary"))
                .padding(.horizontal, 6).frame(height: 16)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(DesignValues.color("line.edge"), lineWidth: 1))
                .padding(.bottom, 7)
                .accessibilityHidden(true)
        }
        .padding(.leading, 4).padding(.trailing, 8)
        .background(DesignValues.color("bg.input"), in: .rect(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(DesignValues.color("line.edge"), lineWidth: 1) }
    }
}

private extension VCType {
    var nsMonoFont: Font { Font(nsMono()) }
}

/// The thread's text field: an AppKit text view, so its keys are exactly the thread's (design.md §6.3): ↵ sends, ⇧↵ adds a
/// line, Esc folds the thread, ⌥← and ⌥→ switch versions while it is empty, and ⌘↩ and ⌘⌫ keep or undo the change.
struct RewriteThreadInputField: NSViewRepresentable {
    let model: EditorModel
    let ordinal: Int
    @Binding var height: CGFloat
    static let placeholder = "Tell Claude what to change\u{2026}"
    static let font = VCType.body.nsFont()
    static let insetY: CGFloat = 6
    static func lineHeight() -> CGFloat { (font.ascender - font.descender + font.leading).rounded(.up) + 2 }
    static func height(lines: Int) -> CGFloat { lineHeight() * CGFloat(max(1, min(4, lines))) + insetY * 2 }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RewriteThreadInputField
        var focusRequest: Int
        init(_ parent: RewriteThreadInputField) { self.parent = parent; focusRequest = 0 }
        @MainActor func textDidChange(_ notification: Notification) {
            guard let text = notification.object as? RewriteThreadInputTextView else { return }
            parent.model.rewriteThread.text = text.string
            text.needsDisplay = true
            parent.measure(text)
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false; scroll.hasVerticalScroller = false; scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true; scroll.borderType = .noBorder
        let text = RewriteThreadInputTextView(usingTextLayoutManager: true)
        text.model = model
        text.delegate = context.coordinator
        text.font = Self.font
        text.textColor = DesignValues.nsColor("text.primary")
        text.insertionPointColor = DesignValues.nsColor("text.primary")
        text.drawsBackground = false; text.isRichText = false; text.allowsUndo = true
        text.isAutomaticQuoteSubstitutionEnabled = false; text.isAutomaticDashSubstitutionEnabled = false
        text.textContainerInset = NSSize(width: 4, height: Self.insetY)
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false; text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.focusRingType = .none
        text.string = model.rewriteThread.text
        text.setAccessibilityLabel("Tell Claude what to change about change \(ordinal)")
        text.setAccessibilityIdentifier("voxclip.rewriteThread.input")
        scroll.documentView = text
        context.coordinator.focusRequest = model.rewriteThread.focusRequest
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let text = scroll.documentView as? RewriteThreadInputTextView else { return }
        text.model = model
        if text.string != model.rewriteThread.text { text.string = model.rewriteThread.text; text.needsDisplay = true; measure(text) }
        let request = model.rewriteThread.focusRequest
        if context.coordinator.focusRequest != request {
            context.coordinator.focusRequest = request
            Task { @MainActor [weak text] in
                guard let text, let window = text.window else { return }
                window.makeFirstResponder(text)
                text.setSelectedRange(NSRange(location: (text.string as NSString).length, length: 0))
            }
        }
    }

    /// 1 to 4 lines of the text as it wraps now; past 4 the field scrolls.
    func measure(_ text: NSTextView) {
        guard let manager = text.textLayoutManager else { return }
        manager.ensureLayout(for: manager.documentRange)
        let used = manager.usageBoundsForTextContainer.height
        let lines = Int((used / Self.lineHeight()).rounded(.up))
        let next = Self.height(lines: lines)
        if abs(next - height) > 0.5 { Task { @MainActor in height = next } }
    }
}

/// The input's text view: the thread's keys before the text system's, and the placeholder while empty.
final class RewriteThreadInputTextView: NSTextView {
    weak var model: EditorModel?
    override var acceptsFirstResponder: Bool { true }
    /// The keys the thread owns; false leaves the event to the text system.
    func handleThreadKey(_ event: NSEvent) -> Bool {
        guard let model else { return false }
        let flags = event.modifierFlags.intersection([.command, .option, .shift, .control])
        let returnKey = event.keyCode == 36 || event.keyCode == 76
        switch (flags, event.keyCode) {
        case (.command, _) where returnKey: model.keepFocusedChange(); returnToTranscript(); return true
        case (.command, 51): model.excludeFocusedChange(); returnToTranscript(); return true
        case (.shift, _) where returnKey: insertText("\n", replacementRange: selectedRange()); return true
        case ([], _) where returnKey:
            model.sendRewriteThread(string, fromInput: true); return true
        case ([], 53): model.foldRewriteThread(); returnToTranscript(); return true
        case (.option, 123), (.option, 124):
            guard string.isEmpty else { return false }
            model.switchRewriteThreadVersion(by: event.keyCode == 123 ? -1 : 1); return true
        default: return false
        }
    }
    override func keyDown(with event: NSEvent) {
        if !hasMarkedText(), handleThreadKey(event) { return }
        super.keyDown(with: event)
    }
    /// ⌘↩ and ⌘⌫ keep their Keep and Undo meanings with the input focused, before any menu's key equivalent.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .shift, .control])
        if window?.firstResponder === self, flags == .command, [36, 76, 51].contains(event.keyCode), handleThreadKey(event) { return true }
        return super.performKeyEquivalent(with: event)
    }
    override func cancelOperation(_ sender: Any?) { model?.foldRewriteThread(); returnToTranscript() }
    /// The keys go back to the transcript, which then walks and reviews changes again.
    private func returnToTranscript() {
        guard let window else { return }
        var view: NSView? = superview
        while let current = view, !(current is TranscriptNSTextView) { view = current.superview }
        if let transcript = view { window.makeFirstResponder(transcript) }
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: font ?? RewriteThreadInputField.font, .foregroundColor: DesignValues.nsColor("text.tertiary")]
        let origin = CGPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0), y: textContainerInset.height)
        (RewriteThreadInputField.placeholder as NSString).draw(at: origin, withAttributes: attributes)
    }
}
