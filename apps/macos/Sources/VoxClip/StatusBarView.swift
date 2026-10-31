import AppKit

/// The status bar (notes.md §1, impl-plan V1a stub; V11a fills it in): full width, 24 pt,
/// on the chrome with a hairline above. With the window title hidden it carries the
/// scope's edit summary that the window subtitle showed, at its trailing end in small
/// text.secondary, with the summary's detail for VoiceOver ("{source} source · {w} words
/// cut in {r} places · {p} pauses cut", design §3.5).
@MainActor final class StatusBarView: NSView {
    let summary = NSTextField(labelWithString: "")
    private let shell: WorkspaceShell
    private var observation: ShellObservation?

    init(shell: WorkspaceShell) {
        self.shell = shell
        super.init(frame: NSRect(x: 0, y: 0, width: 1280, height: ShellMetrics.statusBar))
        identifier = NSUserInterfaceItemIdentifier("voxclip.shell.statusBar")
        summary.font = VCType.small.nsFont()
        summary.textColor = DesignValues.nsColor("text.secondary")
        summary.lineBreakMode = .byTruncatingTail
        summary.alignment = .right
        summary.setAccessibilityIdentifier("voxclip.status.summary")
        addSubview(summary)
        observation = ShellObservation { [weak self] in self?.render() }
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }

    func tearDown() { observation?.cancel() }

    /// The status bar is F6's last stop (impl-plan §3.2): F6 gives it keyboard focus, with
    /// the focus ring inside its bounds; a click does not. VoiceOver reads it as the
    /// "Status" group (EditorShellController).
    @discardableResult func takeFocus() -> Bool {
        focusRequested = true
        defer { focusRequested = false }
        return window?.makeFirstResponder(self) ?? false
    }
    private var focusRequested = false
    override var acceptsFirstResponder: Bool { focusRequested || window?.firstResponder === self }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { bounds.insetBy(dx: 2, dy: 2).fill() }

    private func render() {
        let editor = shell.showsHome ? nil : shell.editor
        // The summary follows the project, which only projectRevision makes observable.
        _ = editor?.projectRevision
        summary.stringValue = editor?.subtitle ?? ""
        summary.setAccessibilityHelp(editor?.summaryDetail)
        needsLayout = true
    }

    /// Items sit 15 pt in from the edges: the bar's 8 pt padding plus an item's 7 (notes.md `.sbar`, `.si`).
    override func layout() {
        super.layout()
        let height = summary.intrinsicContentSize.height
        summary.frame = NSRect(x: 15, y: ((bounds.height - height) / 2).rounded(), width: max(0, bounds.width - 30), height: height)
    }

    override func draw(_ dirtyRect: NSRect) {
        DesignValues.nsColor("bg.window").setFill()
        dirtyRect.fill()
        DesignValues.nsColor("line.default").setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }
}
