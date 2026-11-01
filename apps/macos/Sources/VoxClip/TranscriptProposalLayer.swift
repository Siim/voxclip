import AppKit

/// The focused change's Keep ⌘↩ and Undo ⌘⌫ (ux/v2 notes.md §5, mockup `.hkact`): real 20 pt
/// buttons over the blank the renderer reserves after the change's last word (impl-plan item
/// 23), 10 pt after it and 4 pt apart. The text view places them again after every viewport
/// layout. VoiceOver reaches Keep and Undo through the transcript's custom actions and the
/// Proposed changes rotor (impl-plan §3.7), so the buttons are not accessibility elements.
@MainActor final class TranscriptProposalLayer: NSView {
    /// New words' `change.add` tint (notes.md §3: 19 %).
    static let addTint: CGFloat = 0.19
    static let height: CGFloat = 20
    /// From the change's last word to Keep, and between the buttons.
    static let margin: CGFloat = 10
    static let gap: CGFloat = 4
    /// After Undo, before the next word: a word space.
    static let trailing: CGFloat = 4

    /// A button's width: 7 pt, its 11 pt title, 5 pt, its 10 pt mono key, 7 pt.
    static func buttonWidth(_ action: TranscriptChangeAction) -> CGFloat {
        let title = (TranscriptChangeButton.title(action) as NSString).size(withAttributes: [.font: TranscriptChangeButton.titleFont(action)]).width
        let key = (TranscriptChangeButton.key(action) as NSString).size(withAttributes: [.font: TranscriptChangeButton.keyFont]).width
        return (7 + title + 5 + key + 7).rounded(.up)
    }
    /// The blank the text keeps for these buttons after the change's last word.
    static func reservedWidth(_ actions: [TranscriptChangeAction]) -> CGFloat {
        guard !actions.isEmpty else { return 0 }
        return margin + actions.map(buttonWidth).reduce(0, +) + gap * CGFloat(actions.count - 1) + trailing
    }

    private(set) var buttons: [TranscriptChangeButton] = []
    var perform: ((TranscriptChangeAction) -> Void)?
    override var isFlipped: Bool { true }
    override func isAccessibilityElement() -> Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        let local = convert(point, from: superview)
        return buttons.first { !$0.isHidden && $0.frame.contains(local) }
    }

    /// Shows `actions` from `origin`, the blank's leading edge, centred on the line `box`.
    func show(_ actions: [TranscriptChangeAction], blank origin: CGFloat, line box: CGRect) {
        if buttons.map(\.kind) != actions {
            buttons.forEach { $0.removeFromSuperview() }
            buttons = actions.map { action in
                let button = TranscriptChangeButton(kind: action)
                button.target = self; button.action = #selector(press(_:))
                addSubview(button)
                return button
            }
        }
        var x: CGFloat = 0
        for button in buttons {
            let width = Self.buttonWidth(button.kind)
            let frame = CGRect(x: x, y: 0, width: width, height: Self.height)
            if button.frame != frame { button.frame = frame }
            x += width + Self.gap
        }
        let frame = CGRect(x: origin + Self.margin, y: (box.midY - Self.height / 2).rounded(), width: max(0, x - Self.gap), height: Self.height)
        if self.frame != frame { self.frame = frame }
        if isHidden { isHidden = false }
    }
    func hide() { if !isHidden { isHidden = true } }
    @objc private func press(_ sender: TranscriptChangeButton) { perform?(sender.kind) }
}

/// One of the focused change's buttons (mockup `.hkact > span`): 20 pt, radius 5, an 11 pt
/// title in text.primary and the shortcut in 10 pt mono text.tertiary. Undo fills
/// bg.selectedRow inside a line.edge hairline; Keep, the default, a step lighter with a
/// semibold title.
@MainActor final class TranscriptChangeButton: NSButton {
    let kind: TranscriptChangeAction
    static func title(_ action: TranscriptChangeAction) -> String { action == .keep ? "Keep" : "Undo" }
    static func key(_ action: TranscriptChangeAction) -> String { action == .keep ? "⌘↩" : "⌘⌫" }
    static func titleFont(_ action: TranscriptChangeAction) -> NSFont { VCType.small.nsFont(action == .keep ? .semibold : .regular) }
    static let keyFont = VCType.label.nsMono()

    init(kind: TranscriptChangeAction) {
        self.kind = kind
        super.init(frame: .zero)
        isBordered = false; title = ""; setButtonType(.momentaryPushIn)
        refusesFirstResponder = true
        toolTip = kind == .keep ? "Keep this change (⌘↩)" : "Undo this change (⌘⌫)"
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let keep = kind == .keep
        let fill = DesignValues.nsColor(keep ? "line.edge" : "bg.selectedRow")
        let edge = keep ? DesignValues.nsColor("text.primary").withAlphaComponent(0.1) : DesignValues.nsColor("line.edge")
        let body = CGPath(roundedRect: bounds, cornerWidth: 5, cornerHeight: 5, transform: nil)
        context.setFillColor((isHighlighted ? fill.blended(withFraction: 0.25, of: .black) ?? fill : fill).cgColor)
        context.addPath(body); context.fillPath()
        context.setStrokeColor(edge.cgColor); context.setLineWidth(1)
        context.addPath(CGPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 4.5, cornerHeight: 4.5, transform: nil)); context.strokePath()
        let title = NSAttributedString(string: Self.title(kind), attributes: [.font: Self.titleFont(kind), .foregroundColor: DesignValues.nsColor("text.primary")])
        let key = NSAttributedString(string: Self.key(kind), attributes: [.font: Self.keyFont, .foregroundColor: DesignValues.nsColor("text.tertiary")])
        let titleSize = title.size(), keySize = key.size()
        title.draw(at: CGPoint(x: 7, y: ((bounds.height - titleSize.height) / 2).rounded()))
        key.draw(at: CGPoint(x: 7 + titleSize.width + 5, y: ((bounds.height - keySize.height) / 2).rounded()))
    }
}
