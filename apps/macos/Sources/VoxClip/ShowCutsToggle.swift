import AppKit

/// Show cuts at the end of the tab row (ux/v2 notes.md §1, the mockup's `.tog`): an eye,
/// "Show cuts" in 12 pt and its ⌥⌘C hint in SF Mono 10, 24 high, 8 pt of padding, radius 5.
/// Off it reads `text.tertiary` with the eye struck through; on, `text.primary` on
/// `bg.selectedRow` with the open eye. With less than 560 pt of editor it shows the eye alone
/// (impl-plan §3.5). It toggles `EditorModel.showsCuts`, as View › Show Cuts does.
@MainActor final class ShowCutsToggle: NSButton {
    private let model: EditorModel
    static let compactWidth: CGFloat = 560
    private static let padding: CGFloat = 8, gap: CGFloat = 6, iconSide: CGFloat = 14
    private static let label = "Show cuts", shortcut = "⌥⌘C"

    init(model: EditorModel) {
        self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: 120, height: ShellMetrics.iconButton))
        identifier = NSUserInterfaceItemIdentifier("voxclip.shell.showCuts")
        isBordered = false
        setButtonType(.pushOnPushOff)
        title = ""
        target = self
        action = #selector(toggle)
        setAccessibilityLabel("Show cuts")
        toolTip = "\(Self.label) (\(Self.shortcut))"
        render()
    }
    required init?(coder: NSCoder) { nil }

    /// Follows the model; the tab row's observation calls it.
    func render() {
        let on = model.showsCuts
        if (state == .on) != on { state = on ? .on : .off }
        needsDisplay = true
    }
    @objc private func toggle() {
        model.toggleShowsCuts()
        render()
    }

    var compact: Bool { (superview?.bounds.width ?? .greatestFiniteMagnitude) < Self.compactWidth }
    private var textAttributes: [NSAttributedString.Key: Any] { [.font: VCType.callout.nsFont(), .foregroundColor: DesignValues.nsColor(model.showsCuts ? "text.primary" : "text.tertiary")] }
    private var hintAttributes: [NSAttributedString.Key: Any] { [.font: VCType.label.nsMono(), .foregroundColor: DesignValues.nsColor("text.disabled")] }
    override var intrinsicContentSize: NSSize {
        guard !compact else { return NSSize(width: ShellMetrics.iconButton, height: ShellMetrics.iconButton) }
        let text = (Self.label as NSString).size(withAttributes: textAttributes).width
        let hint = (Self.shortcut as NSString).size(withAttributes: hintAttributes).width
        return NSSize(width: (Self.padding * 2 + Self.iconSide + Self.gap * 2 + text + hint).rounded(.up), height: ShellMetrics.iconButton)
    }
    override func draw(_ dirtyRect: NSRect) {
        let on = model.showsCuts
        if on {
            DesignValues.nsColor("bg.selectedRow").setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        }
        let tint = DesignValues.nsColor(on ? "text.primary" : "text.tertiary")
        let compact = self.compact
        var x = compact ? (bounds.width - Self.iconSide) / 2 : Self.padding
        if let symbol = NSImage(systemSymbolName: on ? "eye" : "eye.slash", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 12, weight: .regular)) {
            let size = symbol.size
            let image = NSImage(size: size, flipped: false) { rect in
                symbol.draw(in: rect)
                tint.set()
                rect.fill(using: .sourceAtop)
                return true
            }
            image.draw(in: NSRect(x: x + (Self.iconSide - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height))
        }
        guard !compact else { return }
        x += Self.iconSide + Self.gap
        let text = NSAttributedString(string: Self.label, attributes: textAttributes)
        let textSize = text.size()
        text.draw(at: NSPoint(x: x, y: ((bounds.height - textSize.height) / 2).rounded()))
        x += textSize.width + Self.gap
        let hint = NSAttributedString(string: Self.shortcut, attributes: hintAttributes)
        hint.draw(at: NSPoint(x: x, y: ((bounds.height - hint.size().height) / 2).rounded()))
    }
}
