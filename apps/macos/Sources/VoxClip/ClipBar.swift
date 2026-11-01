import AppKit
import VoxClipCore

// The clip bar (ux/v2 notes.md §1, the mockup's `.cbar`; impl-plan V3b): 34 high under the tab
// row, on the editor surface with a hairline below. For a clip or Full Take it holds the verbs
// Rewrite, Tighten and Hook, the Ask field and the harness picker; for a suggested clip it holds
// "Suggested clip", Keep ⇧⌘↩ and Dismiss. A control that cannot act is not shown (design.md
// §1.6), and with no editable scope (no transcript, a Versions window) the bar is empty; while the
// video is missing or a relink waits for Use It, the verbs and the Ask field show dimmed, as v5 f24
// draws the read-only editor (lead decision 7), and the status bar says why. Phase 0 meanings
// (impl-plan item 1): Rewrite and Ask run Rewrite on the scope now (V13: the selection, else the
// tab's clip, else Full Take) with the field's text as the instruction; Tighten cuts the scope's
// fillers and pauses as one undo step; Hook finds hook clips in the take with one click.

/// What the bar holds: nothing, a scope's verbs (the tab's clip, nil for Full Take), a suggestion's Keep and Dismiss, or
/// the scope's verbs dimmed while the editor only reads until its video is found or confirmed.
enum ClipBarVariant: Equatable {
    case hidden
    case scope(String?)
    case suggestion(String)
    case readOnly(String?)
}

/// The mockup's `.cbar`, `.verb`, `.ask` and `.btn` measurements, in points.
enum ClipBarMetrics {
    static let leading: CGFloat = 12, trailing: CGFloat = 10, gap: CGFloat = 2
    /// Every control's target is 24 high (impl-plan §3.7); Keep's and Dismiss's drawn `.btn` chip is 22 inside it.
    static let control: CGFloat = 24, suggestionButton: CGFloat = 22
    /// The Ask field starts 6 past the gap after Hook; its text 8 + 13 (sparkles) + 7 in; the picker 3 from its end.
    static let askMargin: CGFloat = 6, askLeading: CGFloat = 8, askIcon: CGFloat = 13, askIconGap: CGFloat = 7, askTrailing: CGFloat = 3
    /// Keep sits 6 past the gap after the label.
    static let keepMargin: CGFloat = 6
    /// Under this bar width the verbs show their icons only, with tooltips (impl-plan §3.5).
    static let iconsBelow: CGFloat = 600
    /// Under this bar width the Ask field collapses into an "Ask…" button that opens it in a popover.
    static let askButtonBelow: CGFloat = 440
    /// The Ask field keeps this much room for its text before the picker shows its first word only.
    static let askTextMinimum: CGFloat = 96
    /// The instruction's limit (`PatchRewriteRequest.instruction`, voice-lab.md §8.1).
    static let instructionBytes = 1_000
}

/// The bar. `render` follows the model and the tab; `layout` places what shows for the bar's width.
@MainActor final class ClipBarView: NSView, NSTextFieldDelegate, NSPopoverDelegate {
    let model: EditorModel
    let shell: WorkspaceShell
    let rewrite = ClipBarButton(style: .verb, symbol: "sparkles", label: "Rewrite", identifier: "voxclip.clipBar.rewrite")
    let tighten = ClipBarButton(style: .verb, symbol: "arrow.right.and.line.vertical.and.arrow.left", label: "Tighten", identifier: "voxclip.clipBar.tighten")
    let hook = ClipBarButton(style: .verb, symbol: "bolt", label: "Hook", identifier: "voxclip.clipBar.hook")
    /// Under 440 the Ask field is this button, which opens it in a popover.
    let askButton = ClipBarButton(style: .verb, symbol: nil, label: "Ask…", identifier: "voxclip.clipBar.askButton")
    let ask = ClipBarAskField()
    let picker: HarnessPicker
    /// "Rewriting…" in Rewrite's place while its run goes, and "Finding clips…" in Hook's (design.md §3.1 states).
    let rewriting = ClipBarStatusView(text: "Rewriting…", identifier: "voxclip.clipBar.rewriting")
    let finding = ClipBarStatusView(text: "Finding clips…", identifier: "voxclip.clipBar.finding")
    /// "8 cuts · Undo" in Tighten's place after it ran (impl-plan item 1).
    let toast = ClipBarToast()
    let suggestionLabel = ClipBarLabel(symbol: "rectangle.dashed", text: "Suggested clip", identifier: "voxclip.clipBar.suggestion")
    let keep = ClipBarButton(style: .bordered, symbol: "checkmark", label: "Keep", hint: "⇧⌘↩", identifier: "voxclip.clipBar.keep")
    let dismiss = ClipBarButton(style: .ghost, symbol: nil, label: "Dismiss", identifier: "voxclip.clipBar.dismiss")
    private(set) var variant = ClipBarVariant.hidden
    /// The Ask field (or its button) shows: a Rewrite can open or one runs.
    private(set) var asks = false
    /// The last Tighten's cuts, until the project changes again.
    private(set) var tightened: (cuts: Int, revision: Int, undoName: String)?
    private var toastEnd: Task<Void, Never>?
    private(set) var askPopover: NSPopover?

    init(model: EditorModel, shell: WorkspaceShell) {
        self.model = model
        self.shell = shell
        picker = HarnessPicker(app: shell.app)
        super.init(frame: NSRect(x: 0, y: 0, width: 652, height: ShellMetrics.clipBar))
        identifier = NSUserInterfaceItemIdentifier("voxclip.shell.clipBar")
        setAccessibilityRole(.group)
        for view in [rewrite, rewriting, tighten, toast, hook, finding, askButton, ask, picker, suggestionLabel, keep, dismiss] as [NSView] { addSubview(view) }
        rewrite.onPress = { [weak self] in self?.runRewrite() }
        tighten.onPress = { [weak self] in self?.runTighten() }
        hook.onPress = { [weak self] in self?.model.runHook() }
        askButton.onPress = { [weak self] in self?.showAskPopover() }
        keep.onPress = { [weak self] in self?.keepSuggestion() }
        dismiss.onPress = { [weak self] in self?.dismissSuggestion() }
        toast.undo.onPress = { [weak self] in self?.undoTighten() }
        hook.setAccessibilityLabel("Hook: find hook clips in this take")
        keep.toolTip = "Keep this clip (⇧⌘↩)"
        ask.delegate = self
        ask.onFocus = { [weak self] in self?.askTookFocus() }
        ask.setAccessibilityHelp("Return opens Rewrite with what you type. Empty asks to fix mistakes.")
        render()
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    /// What Rewrite and Ask act on now, named for the verb's VoiceOver name and tooltip and the field's placeholder:
    /// "Rewrite selection" and "Ask about these words…", "Rewrite clip 1" and "Ask about Clip 1…", or "Rewrite full
    /// take" and "Ask about Full Take…" (V13's `rewriteScopeNow`; design.md §1 item 1).
    var rewriteNames: (verb: String, ask: String) {
        switch model.rewriteScopeNow {
        case .selection: ("Rewrite selection", "Ask about these words…")
        case .clip(let id): ("Rewrite clip \(model.clipNumber(id) ?? 1)", "Ask about \(model.scopeName(id))…")
        case .fullTake, nil: ("Rewrite full take", "Ask about Full Take…")
        }
    }

    func tearDown() {
        toastEnd?.cancel()
        askPopover?.close()
    }

    // MARK: State

    /// What the bar holds now: the verbs dimmed while the video is missing or a relink waits; nothing without an editable
    /// scope; Keep and Dismiss on a suggestion's tab; else the verbs.
    var currentVariant: ClipBarVariant {
        let tab = shell.tabs.active
        if model.transcribed, model.capabilities.writable, model.mediaReadOnlyNote != nil { return .readOnly(tab.clipID) }
        guard model.transcribed, model.capabilities.edit else { return .hidden }
        if case .suggestion(let id) = tab, model.isSuggestion(id) { return .suggestion(id) }
        return .scope(tab.clipID)
    }
    /// Rewrite can run on the scope now (V13): AI editing is available and there are words. Text Rewrite needs no
    /// selection and no Voice Lab.
    var rewriteAvailable: Bool { RewriteEntryPolicy.canRun(editable: model.capabilities.ai, scope: model.rewriteScopeNow) }
    var rewriteRunning: Bool { model.rewrite?.task.state == .running && !model.sendConfirmation.isPresented }
    /// The Tighten toast shows until the project changes again or the tab moves.
    var toastShown: Bool {
        guard let tightened, case .scope = variant else { return false }
        return tightened.revision == model.projectRevision
    }

    /// Follows the model, the tab and the chosen AI; the editor's observation calls it.
    func render() {
        _ = model.projectRevision
        variant = currentVariant
        let scoped: Bool, suggested: Bool, readOnly: Bool
        switch variant {
        case .hidden:
            scoped = false; suggested = false; readOnly = false
            setAccessibilityElement(false)
        case .scope(let clipID):
            scoped = true; suggested = false; readOnly = false
            setAccessibilityElement(true)
            setAccessibilityLabel("\(model.scopeName(clipID)) tools")
        case .readOnly(let clipID):
            scoped = false; suggested = false; readOnly = true
            setAccessibilityElement(true)
            setAccessibilityLabel("\(model.scopeName(clipID)) tools")
        case .suggestion(let id):
            scoped = false; suggested = true; readOnly = false
            setAccessibilityElement(true)
            setAccessibilityLabel("\(model.scopeName(id)) tools")
            keep.setAccessibilityLabel(EditorIconAction.suggestion(keep: true, number: model.clipNumber(id) ?? 0))
            dismiss.setAccessibilityLabel(EditorIconAction.suggestion(keep: false, number: model.clipNumber(id) ?? 0))
        }
        if !toastShown, tightened != nil { tightened = nil; toastEnd?.cancel() }
        let running = scoped && rewriteRunning
        let canRewrite = scoped && rewriteAvailable
        // Read-only: the verbs and the Ask field stay in place, dimmed, and say why (v5 f24).
        let note = readOnly ? model.mediaReadOnlyNote : nil
        for control in [rewrite, tighten, hook, askButton] as [NSControl] where control.isEnabled == readOnly { control.isEnabled = !readOnly }
        if ask.isEnabled == readOnly { ask.isEnabled = !readOnly }
        rewrite.isHidden = !readOnly && (!canRewrite || running)
        rewrite.isOn = model.rewrite != nil
        // The chosen AI asks before each send (C8): "Rewrite…", as Edit › Rewrite's title (design.md §3.1).
        rewrite.label = model.rewriteAsksFirst ? "Rewrite…" : "Rewrite"
        let names = rewriteNames
        rewrite.setAccessibilityLabel(names.verb)
        rewrite.toolTip = note ?? "\(names.verb) (⇧⌘R)"
        let askName = names.ask.replacingOccurrences(of: "…", with: "")
        if ask.placeholder != names.ask { ask.placeholder = names.ask }
        ask.setAccessibilityLabel(askName)
        askButton.setAccessibilityLabel(askName)
        rewriting.isHidden = !running
        let toasting = scoped && toastShown
        toast.isHidden = !toasting
        if let tightened, toasting { toast.show(cuts: tightened.cuts, undoName: tightened.undoName) }
        tighten.isHidden = !readOnly && (!scoped || toasting || !model.canTighten)
        switch variant {
        case .scope(let clipID), .readOnly(let clipID):
            let name = model.scopeName(clipID)
            tighten.setAccessibilityLabel("Tighten \(name)")
            tighten.toolTip = note ?? "Cut fillers and tighten pauses in \(name)"
        case .hidden, .suggestion: break
        }
        hook.toolTip = note ?? "Find hook clips in this take. They land in Suggested."
        askButton.toolTip = note ?? askName
        ask.toolTip = note
        finding.isHidden = !(scoped && model.finding)
        hook.isHidden = !readOnly && (!scoped || model.finding || !model.capabilities.ai)
        asks = readOnly || canRewrite || running
        ask.isEditable = !running
        if ask.currentEditor() == nil, ask.stringValue != model.rewriteInstruction { ask.stringValue = model.rewriteInstruction }
        picker.isHidden = !scoped && !readOnly
        picker.render()
        for view in [suggestionLabel, keep, dismiss] as [NSView] { view.isHidden = !suggested }
        linkKeyViews()
        needsLayout = true
        needsDisplay = true
    }
    /// Tab moves through the bar in reading order, from the active tab (F6's stop, V3a). The window may recalculate
    /// its key-view loop as views come and go, so every render links the bar again.
    private func linkKeyViews() {
        let order: [NSView] = [self, rewrite, tighten, toast.undo, hook, askButton, ask, picker, keep, dismiss]
        for (view, next) in zip(order, order.dropFirst()) where view.nextKeyView !== next { view.nextKeyView = next }
    }

    // MARK: Layout

    /// The views in reading order that lay out from the bar's start.
    private var leadingViews: [NSView] {
        switch variant {
        case .hidden: []
        case .scope, .readOnly: [rewrite, rewriting, tighten, toast, hook, finding, askButton]
        case .suggestion: [suggestionLabel, keep, dismiss]
        }
    }
    override func layout() {
        super.layout()
        let width = bounds.width
        let iconsOnly = width < ClipBarMetrics.iconsBelow
        let collapsed = width < ClipBarMetrics.askButtonBelow
        // "Ask…" keeps its word: its icon would read as Rewrite's.
        for verb in [rewrite, tighten, hook] where verb.iconOnly != iconsOnly { verb.iconOnly = iconsOnly }
        askButton.isHidden = !(asks && collapsed)
        ask.isHidden = !(asks && !collapsed)
        if collapsed, ask.currentEditor() != nil { window?.makeFirstResponder(nil) }
        if !collapsed { askPopover?.close() }
        // The content sits on the 33 pt above the hairline (border-box), centred at 16.5.
        let middle = (bounds.height - 1) / 2
        func place(_ view: NSView, x: CGFloat, width: CGFloat, height: CGFloat) {
            view.frame = backingAlignedRect(NSRect(x: x, y: middle - height / 2, width: width, height: height), options: .alignAllEdgesNearest)
        }
        var x = ClipBarMetrics.leading
        for view in leadingViews where !view.isHidden {
            if view === keep { x += ClipBarMetrics.keepMargin }
            let size = view.intrinsicContentSize
            place(view, x: x, width: size.width, height: size.height)
            x += size.width + ClipBarMetrics.gap
        }
        switch variant {
        case .scope, .readOnly: break
        case .hidden, .suggestion: return
        }
        let end = width - ClipBarMetrics.trailing
        let fieldStart = x + ClipBarMetrics.askMargin
        picker.compact = false
        if !ask.isHidden {
            // The picker sits inside the field's end; it keeps its dot and first word when the text runs short.
            let textStart = fieldStart + ClipBarMetrics.askLeading + ClipBarMetrics.askIcon + ClipBarMetrics.askIconGap
            picker.compact = end - ClipBarMetrics.askTrailing - picker.fullWidth - textStart < ClipBarMetrics.askTextMinimum
            let pickerWidth = picker.intrinsicContentSize.width
            place(ask, x: fieldStart, width: max(0, end - fieldStart), height: ClipBarMetrics.control)
            (ask.cell as? ClipBarAskCell)?.trailingInset = ClipBarMetrics.askTrailing + pickerWidth + ClipBarMetrics.askIconGap
            place(picker, x: end - ClipBarMetrics.askTrailing - pickerWidth, width: pickerWidth, height: HarnessPicker.height)
        } else {
            picker.compact = end - ClipBarMetrics.askTrailing - picker.fullWidth < x
            let pickerWidth = picker.intrinsicContentSize.width
            place(picker, x: end - ClipBarMetrics.askTrailing - pickerWidth, width: pickerWidth, height: HarnessPicker.height)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        DesignValues.nsColor("bg.surface").setFill()
        dirtyRect.fill()
        DesignValues.nsColor("line.default").setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    /// Where the Find Clips popover opens (impl-plan item 17): at Hook, else at the bar.
    var findClipsAnchorView: NSView { hook.isHidden || hook.window == nil ? self : hook }

    // MARK: Actions

    /// Rewrite and Return in the Ask field: Rewrite on the scope now with the field's text as its instruction, as Edit ›
    /// Rewrite and ⇧⌘R run it (V13's `runRewrite`); on the open session's own scope it sends again.
    func runRewrite() {
        commitAsk()
        model.sendConfirmation.onFinish = { [weak self] approved in
            guard !approved, let self else { return }
            _ = window?.makeFirstResponder(rewrite)
        }
        model.runRewrite()
    }
    /// Tighten on the bar's scope, one undo step, then "8 cuts · Undo" in its place.
    func runTighten() {
        guard case .scope(let clipID) = variant, let cuts = model.tighten(scope: clipID) else { return }
        tightened = (cuts, model.projectRevision, model.tightenStepName(clipID))
        toastEnd?.cancel()
        toastEnd = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard let self, !Task.isCancelled else { return }
            tightened = nil
            render()
        }
        render()
    }
    /// The toast's Undo: undoes that Tighten while it is still the last step.
    func undoTighten() {
        defer { tightened = nil; toastEnd?.cancel(); render() }
        guard let tightened, tightened.revision == model.projectRevision, let undo = model.undoManager,
              undo.canUndo, undo.undoActionName == tightened.undoName else { return }
        undo.undo()
    }
    func keepSuggestion() {
        guard case .suggestion(let id) = variant else { return }
        model.keep(id)
    }
    func dismissSuggestion() {
        guard case .suggestion(let id) = variant else { return }
        model.dismiss(id)
    }

    // MARK: The Ask field

    /// Typing in the field is the tab and clip-bar pane's (F6's stop), so the Explorer's bare Return and Delete
    /// (Clip › Keep, Dismiss, Rename, Remove) never take the field's keys, and the next F6 goes on to the transcript.
    private func askTookFocus() { model.focusedPane = .tabs }
    private func commitAsk() {
        if ask.currentEditor() != nil || ask.stringValue != model.rewriteInstruction { model.rewriteInstruction = Self.limited(ask.stringValue) }
    }
    /// At most `instructionBytes` of UTF-8, cut at a character.
    static func limited(_ text: String) -> String {
        guard text.utf8.count > ClipBarMetrics.instructionBytes else { return text }
        var result = ""
        for character in text {
            guard result.utf8.count + String(character).utf8.count <= ClipBarMetrics.instructionBytes else { break }
            result.append(character)
        }
        return result
    }
    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        let text = Self.limited(field.stringValue)
        if text != field.stringValue { field.stringValue = text }
        model.rewriteInstruction = text
    }
    /// Return runs Rewrite; Escape leaves the field for the transcript.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if control === ask || askPopover?.isShown == true {
                askPopover?.close()
                if model.sendConfirmation.isPresented, let event = NSApp.currentEvent {
                    _ = model.sendConfirmation.pressReturn(timestamp: event.timestamp, now: ProcessInfo.processInfo.systemUptime,
                        isRepeat: event.isARepeat, command: event.modifierFlags.contains(.command))
                } else if rewriteAvailable {
                    commitAsk()
                    model.sendConfirmation.onFinish = { [weak self] approved in
                        guard !approved, let self else { return }
                        _ = window?.makeFirstResponder(ask)
                    }
                    model.runRewrite(verb: "Ask")
                }
                return true
            }
            return false
        case #selector(NSResponder.cancelOperation(_:)):
            if askPopover?.isShown == true { askPopover?.close(); return true }
            _ = focusTranscript(in: window)
            return true
        default: return false
        }
    }

    /// Under 440: the field in a popover under "Ask…".
    func showAskPopover() {
        guard askPopover?.isShown != true else { return }
        let field = ClipBarAskField()
        field.placeholder = rewriteNames.ask
        field.setAccessibilityLabel(ask.accessibilityLabel())
        field.stringValue = model.rewriteInstruction
        field.delegate = self
        field.onFocus = { [weak self] in self?.askTookFocus() }
        (field.cell as? ClipBarAskCell)?.trailingInset = ClipBarMetrics.askLeading
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 48))
        field.frame = NSRect(x: 12, y: 12, width: 276, height: ClipBarMetrics.control)
        container.addSubview(field)
        let controller = NSViewController()
        controller.view = container
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        popover.contentSize = container.frame.size
        popover.delegate = self
        askPopover = popover
        popover.show(relativeTo: askButton.bounds, of: askButton, preferredEdge: .maxY)
        popover.contentViewController?.view.window?.makeFirstResponder(field)
    }
    func popoverDidClose(_ notification: Notification) {
        guard (notification.object as? NSPopover) === askPopover else { return }
        askPopover = nil
    }
}

// MARK: - Controls

/// A clip-bar button. `verb` (notes.md `.verb`): a 14 pt icon in text.tertiary and a 13 pt label in text.secondary,
/// 24 high, 8 pt padding, 6 between, radius 5, the selected-row fill when on, pressed or under the pointer; icon-only
/// it is 24 × 24 with its name as the tooltip. `bordered` (`.btn`, a 22 high chip): bg.muted with a line.edge outline,
/// a 13 pt medium text.primary label, radius 6, and an SF Mono 10 key hint. `ghost`: the same without fill or outline,
/// in text.secondary. Every style's target is 24 high (impl-plan §3.7); the 22 pt chip is centred in it.
@MainActor final class ClipBarButton: NSButton {
    enum Style { case verb, bordered, ghost }
    let style: Style
    private let symbol: String?
    let hint: String?
    var label: String { didSet { if label != oldValue { invalidateIntrinsicContentSize(); needsDisplay = true; updateTip() } } }
    var iconOnly = false { didSet { if iconOnly != oldValue { invalidateIntrinsicContentSize(); needsDisplay = true; updateTip() } } }
    var isOn = false { didSet { if isOn != oldValue { needsDisplay = true } } }
    override var isEnabled: Bool { didSet { if isEnabled != oldValue { needsDisplay = true } } }
    var onPress: () -> Void = {}
    private var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }
    private var baseTip: String?

    init(style: Style, symbol: String?, label: String, hint: String? = nil, identifier: String) {
        self.style = style; self.symbol = symbol; self.label = label; self.hint = hint
        super.init(frame: NSRect(x: 0, y: 0, width: 80, height: ClipBarMetrics.control))
        self.identifier = NSUserInterfaceItemIdentifier(identifier)
        isBordered = false
        setButtonType(.momentaryPushIn)
        title = ""
        target = self
        action = #selector(press)
        setAccessibilityLabel(label)
    }
    required init?(coder: NSCoder) { nil }
    @objc private func press() { onPress() }
    override var toolTip: String? {
        get { super.toolTip }
        set { baseTip = newValue; super.toolTip = newValue }
    }
    /// Icon-only verbs carry their name in the tooltip (impl-plan §3.5).
    private func updateTip() { super.toolTip = iconOnly && baseTip == nil ? label : baseTip }

    /// The drawn chip: the whole target for a verb, 22 high and centred for `.btn` and ghost.
    var chip: NSRect {
        let height = style == .verb ? ClipBarMetrics.control : ClipBarMetrics.suggestionButton
        return NSRect(x: bounds.minX, y: bounds.minY + ((bounds.height - height) / 2).rounded(), width: bounds.width, height: min(height, bounds.height))
    }
    private var padding: CGFloat { style == .verb ? 8 : 10 }
    private var iconSize: CGFloat { style == .verb ? 14 : 12 }
    private var labelFont: NSFont { style == .verb ? VCType.body.nsFont() : VCType.body.nsFont(.medium) }
    /// The pointer or a press lights the button only while it can act.
    private var lit: Bool { isEnabled && (isOn || hovering || isHighlighted) }
    private var labelColor: NSColor {
        guard isEnabled else { return DesignValues.nsColor("text.disabled") }
        return switch style {
        case .verb: DesignValues.nsColor(lit ? "text.primary" : "text.secondary")
        case .bordered: DesignValues.nsColor("text.primary")
        case .ghost: DesignValues.nsColor(hovering || isHighlighted ? "text.primary" : "text.secondary")
        }
    }
    private var iconColor: NSColor { style == .verb && isEnabled ? DesignValues.nsColor(lit ? "text.secondary" : "text.tertiary") : labelColor }
    private var hintAttributes: [NSAttributedString.Key: Any] { [.font: VCType.label.nsMono(), .foregroundColor: DesignValues.nsColor("text.tertiary")] }
    override var intrinsicContentSize: NSSize {
        if iconOnly { return NSSize(width: ClipBarMetrics.control, height: ClipBarMetrics.control) }
        var width = padding * 2 + ceil((label as NSString).size(withAttributes: [.font: labelFont]).width)
        if symbol != nil { width += iconSize + 6 }
        if let hint { width += 4 + ceil((hint as NSString).size(withAttributes: hintAttributes).width) }
        return NSSize(width: width.rounded(.up), height: ClipBarMetrics.control)
    }
    private var shape: NSBezierPath {
        let radius: CGFloat = style == .verb ? 5 : 6
        return NSBezierPath(roundedRect: style == .bordered ? chip.insetBy(dx: 0.5, dy: 0.5) : chip, xRadius: radius, yRadius: radius)
    }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        switch style {
        case .verb, .ghost:
            if lit {
                DesignValues.nsColor("bg.selectedRow").setFill()
                shape.fill()
            }
        case .bordered:
            DesignValues.nsColor(isHighlighted ? "bg.selectedRow" : "bg.muted").setFill()
            shape.fill()
            DesignValues.nsColor("line.edge").setStroke()
            shape.lineWidth = 1
            shape.stroke()
        }
        var x = iconOnly ? (bounds.width - iconSize) / 2 : padding
        if let symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: iconSize - 1, weight: .regular)) {
            let tinted = Self.tinted(image, iconColor)
            let size = tinted.size
            tinted.draw(in: NSRect(x: (x + (iconSize - size.width) / 2).rounded(), y: ((bounds.height - size.height) / 2).rounded(), width: size.width, height: size.height))
            x += iconSize + 6
        }
        guard !iconOnly else { return }
        let text = NSAttributedString(string: label, attributes: [.font: labelFont, .foregroundColor: labelColor])
        let size = text.size()
        text.draw(at: NSPoint(x: x, y: ((bounds.height - size.height) / 2).rounded()))
        if let hint {
            let hintText = NSAttributedString(string: hint, attributes: hintAttributes)
            hintText.draw(at: NSPoint(x: x + ceil(size.width) + 4, y: ((bounds.height - hintText.size().height) / 2).rounded()))
        }
    }
    override func drawFocusRingMask() { shape.fill() }
    override var focusRingMaskBounds: NSRect { bounds }
    override var mouseDownCanMoveWindow: Bool { false }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    /// `image` in `color`, as a template symbol tinted for drawing.
    static func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
        NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }
}

/// A label with an icon in the bar's text.tertiary (the suggestion's "Suggested clip"): 4 pt in, then the verb's metrics.
@MainActor final class ClipBarLabel: NSView {
    private let symbol: String
    let text: String
    init(symbol: String, text: String, identifier: String) {
        self.symbol = symbol; self.text = text
        super.init(frame: NSRect(x: 0, y: 0, width: 120, height: ClipBarMetrics.control))
        self.identifier = NSUserInterfaceItemIdentifier(identifier)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(text)
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    private var attributes: [NSAttributedString.Key: Any] { [.font: VCType.body.nsFont(), .foregroundColor: DesignValues.nsColor("text.tertiary")] }
    override var intrinsicContentSize: NSSize {
        NSSize(width: (4 + 14 + 6 + ceil((text as NSString).size(withAttributes: attributes).width) + 8).rounded(.up), height: ClipBarMetrics.control)
    }
    override func draw(_ dirtyRect: NSRect) {
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 13, weight: .regular)) {
            let tinted = ClipBarButton.tinted(image, DesignValues.nsColor("text.tertiary"))
            tinted.draw(in: NSRect(x: (4 + (14 - tinted.size.width) / 2).rounded(), y: ((bounds.height - tinted.size.height) / 2).rounded(), width: tinted.size.width, height: tinted.size.height))
        }
        let string = NSAttributedString(string: text, attributes: attributes)
        string.draw(at: NSPoint(x: 24, y: ((bounds.height - string.size().height) / 2).rounded()))
    }
}

/// A status in a verb's place (design.md §3.1): a 12 pt spinner and the text in 12 pt text.secondary; under Reduce
/// Motion the text alone. It is status, not a button.
@MainActor final class ClipBarStatusView: NSView {
    let spinner = NSProgressIndicator()
    let label: NSTextField
    init(text: String, identifier: String) {
        label = NSTextField(labelWithString: text)
        super.init(frame: NSRect(x: 0, y: 0, width: 120, height: ClipBarMetrics.control))
        self.identifier = NSUserInterfaceItemIdentifier(identifier)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.isDisplayedWhenStopped = false
        spinner.setAccessibilityElement(false)
        label.font = VCType.callout.nsFont()
        label.textColor = DesignValues.nsColor("text.secondary")
        addSubview(spinner)
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(text)
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    private var motion: Bool { !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    override var isHidden: Bool {
        didSet { if !isHidden && motion { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) } }
    }
    override var intrinsicContentSize: NSSize {
        NSSize(width: (8 + (motion ? 12 + 6 : 0) + ceil(label.intrinsicContentSize.width) - 4 + 8).rounded(.up), height: ClipBarMetrics.control)
    }
    override func layout() {
        super.layout()
        var x: CGFloat = 8
        if motion {
            spinner.frame = NSRect(x: x, y: ((bounds.height - 12) / 2).rounded(), width: 12, height: 12)
            x += 12 + 6
        }
        let height = label.intrinsicContentSize.height
        // A label field draws its text 2 pt in from its frame.
        label.frame = NSRect(x: x - 2, y: ((bounds.height - height) / 2).rounded(), width: max(0, bounds.width - x - 4), height: height)
    }
}

/// Tighten's toast in its place (impl-plan item 1): "8 cuts" in 12 pt text.secondary and a borderless Undo, on the
/// selected-row fill, radius 5, 24 high.
@MainActor final class ClipBarToast: NSView {
    let label = NSTextField(labelWithString: "")
    let undo = ClipBarButton(style: .ghost, symbol: nil, label: "Undo", identifier: "voxclip.clipBar.toastUndo")
    private(set) var cuts = 0
    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 120, height: ClipBarMetrics.control))
        identifier = NSUserInterfaceItemIdentifier("voxclip.clipBar.toast")
        label.font = VCType.callout.nsFont()
        label.textColor = DesignValues.nsColor("text.secondary")
        addSubview(label)
        addSubview(undo)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    /// "8 cuts · Undo"; Undo's name says what it undoes.
    func show(cuts: Int, undoName: String) {
        self.cuts = cuts
        let text = (cuts == 1 ? "1 cut" : "\(cuts) cuts") + " ·"
        if label.stringValue != text { label.stringValue = text; invalidateIntrinsicContentSize(); needsLayout = true }
        setAccessibilityLabel(cuts == 1 ? "1 cut" : "\(cuts) cuts")
        undo.setAccessibilityLabel(undoName.isEmpty ? "Undo" : "Undo \(undoName)")
    }
    /// 8 in, the count and its dot, 5, then Undo's word (its button is 10 wider each side), 8 to the end.
    override var intrinsicContentSize: NSSize {
        NSSize(width: (8 + labelWidth + 5 + undo.intrinsicContentSize.width - 20 + 8).rounded(.up), height: ClipBarMetrics.control)
    }
    private var labelWidth: CGFloat { ceil((label.stringValue as NSString).size(withAttributes: [.font: label.font ?? VCType.callout.nsFont()]).width) }
    override func layout() {
        super.layout()
        let height = label.intrinsicContentSize.height
        // A label field draws its text 2 pt in from its frame.
        label.frame = NSRect(x: 8 - 2, y: ((bounds.height - height) / 2).rounded(), width: labelWidth + 4, height: height)
        let undoSize = undo.intrinsicContentSize
        undo.frame = NSRect(x: 8 + labelWidth + 5 - 10, y: ((bounds.height - undoSize.height) / 2).rounded(), width: undoSize.width, height: undoSize.height)
    }
    override func draw(_ dirtyRect: NSRect) {
        DesignValues.nsColor("bg.selectedRow").setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
    }
}

/// The Ask field (notes.md `.ask`): 24 high, radius 6, the chrome fill with a 1 pt line.edge outline, a 13 pt sparkles
/// in text.disabled, then the 13 pt text and its placeholder in text.tertiary. The picker sits over its end; the cell
/// keeps its text clear of it. Its focus ring follows the rounded box.
@MainActor final class ClipBarAskField: NSTextField {
    override class var cellClass: AnyClass? { get { ClipBarAskCell.self } set {} }
    /// Called when the field takes keyboard focus, by a click, Tab or a popover opening.
    var onFocus: () -> Void = {}
    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: ClipBarMetrics.control))
        identifier = NSUserInterfaceItemIdentifier("voxclip.clipBar.ask")
        isBezeled = false
        isBordered = false
        drawsBackground = false
        font = VCType.body.nsFont()
        textColor = DesignValues.nsColor("text.primary")
        usesSingleLineMode = true
        lineBreakMode = .byTruncatingTail
        cell?.isScrollable = true
        cell?.wraps = false
        focusRingType = .default
    }
    required init?(coder: NSCoder) { nil }
    /// The placeholder in 13 pt text.tertiary.
    var placeholder: String {
        get { placeholderAttributedString?.string ?? "" }
        set { placeholderAttributedString = NSAttributedString(string: newValue, attributes: [.font: VCType.body.nsFont(), .foregroundColor: DesignValues.nsColor("text.tertiary")]) }
    }
    override var mouseDownCanMoveWindow: Bool { false }
    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        onFocus()
        return true
    }
}

@MainActor final class ClipBarAskCell: NSTextFieldCell {
    /// Room kept for the picker at the field's end.
    var trailingInset: CGFloat = 0
    static var leadingInset: CGFloat { ClipBarMetrics.askLeading + ClipBarMetrics.askIcon + ClipBarMetrics.askIconGap }
    /// The text's rect in the box: past the icon, short of the picker, one line centred.
    func textRect(_ bounds: NSRect) -> NSRect {
        let font = self.font ?? VCType.body.nsFont()
        let line = ceil(font.ascender - font.descender + font.leading)
        let height = min(bounds.height, line)
        return NSRect(x: bounds.minX + Self.leadingInset, y: bounds.minY + ((bounds.height - height) / 2).rounded(),
                      width: max(0, bounds.width - Self.leadingInset - trailingInset), height: height)
    }
    private func box(_ frame: NSRect) -> NSBezierPath { NSBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6) }
    override func drawingRect(forBounds rect: NSRect) -> NSRect { textRect(rect) }
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        let path = box(cellFrame)
        DesignValues.nsColor("bg.window").setFill()
        path.fill()
        DesignValues.nsColor("line.edge").setStroke()
        path.lineWidth = 1
        path.stroke()
        if let image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 11, weight: .regular)) {
            let tinted = ClipBarButton.tinted(image, DesignValues.nsColor("text.disabled"))
            let size = tinted.size
            tinted.draw(in: NSRect(x: cellFrame.minX + ClipBarMetrics.askLeading + (ClipBarMetrics.askIcon - size.width) / 2,
                                   y: cellFrame.minY + ((cellFrame.height - size.height) / 2).rounded(), width: size.width, height: size.height),
                        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        drawInterior(withFrame: cellFrame, in: controlView)
    }
    override func drawFocusRingMask(withFrame cellFrame: NSRect, in controlView: NSView) { box(cellFrame).fill() }
    override func focusRingMaskBounds(forFrame cellFrame: NSRect, in controlView: NSView) -> NSRect { cellFrame }
}
