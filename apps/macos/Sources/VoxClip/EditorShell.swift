import AppKit
import Observation
import SwiftUI
import VoxClipCore

// The v2 editor frame (ux/v2 notes.md §1, impl-plan V1a): an AppKit split tree under
// WorkspaceView, which keeps the sheets and the drop target. The Explorer is a plain
// split pane, not the floating sidebar; the tab row doubles as the title bar; the
// timeline is a bottom panel under the editor and right columns; a status bar spans
// the window. There is no toolbar.

/// The shell's fixed sizes, in points (notes.md §1).
enum ShellMetrics {
    /// The editor tab row and the right column's title row. The tab row is the title bar.
    static let titleRow: CGFloat = 38
    static let clipBar: CGFloat = 34
    static let statusBar: CGFloat = 24
    /// The Explorer's top band: the window buttons and the Explorer toggle; the list starts below it.
    static let explorerHeader: CGFloat = 44
    /// Title-row controls are centred on the window buttons' line, 19 pt from the top.
    static let controlCenter: CGFloat = 19
    /// Room for the window buttons at the start of the work area while the Explorer is hidden.
    static let windowButtons: CGFloat = 78
    static let iconButton: CGFloat = 24
    /// The editor and right columns keep at least this height above the timeline.
    static let topMinimum: CGFloat = 240
    /// Today's timeline strip; the timeline panel is never shorter.
    static let timelineMinimum: CGFloat = VCTokens.sizeTimelineHeight
}

/// The shell's regions, for layout evidence (DebugShell). Rects are window points from the
/// top-left. The Explorer's divider and the right column's divider belong to the editor
/// column's rows; the timeline's top edge belongs to the rows above it.
enum ShellRegion: String, CaseIterable, Codable, Sendable {
    case explorer, tabBar, clipBar, transcript, rightTitle, rightBody, timeline, statusBar

    /// notes.md §1 at 1280 × 800 with fresh defaults. The right body holds the viewer and
    /// the panel together until V4 gives them their own rows.
    @MainActor var reference: CGRect { reference(in: CGSize(width: 1280, height: 800)) ?? .zero }

    /// The region in a window of `size` with fresh defaults, by the rules of notes.md §1 and
    /// impl-plan §3.5; nil where it is collapsed. At 1280 × 800 these are notes.md §1.
    @MainActor func reference(in size: CGSize) -> CGRect? {
        let width = Double(size.width), height = Double(size.height)
        let titleRow = Double(ShellMetrics.titleRow), clipBar = Double(ShellMetrics.clipBar), statusBar = Double(ShellMetrics.statusBar)
        let workHeight = height - statusBar
        let explorer = width >= Double(VCTokens.sizeSidebarIdeal) + WorkspaceShell.rightCollapseWidth ? Double(VCTokens.sizeSidebarIdeal) : 0
        let right = width >= WorkspaceShell.rightCollapseWidth ? WorkspaceLayout.rightColumnWidth(windowWidth: width, explorer: explorer) : 0
        let timeline = min(WorkspaceLayout.timelineDefault, (workHeight * WorkspaceLayout.timelineShare).rounded(.down))
        let top = workHeight - timeline
        let editor = width - explorer - right
        switch self {
        case .explorer: return explorer > 0 ? CGRect(x: 0, y: 0, width: explorer, height: workHeight) : nil
        case .tabBar: return CGRect(x: explorer, y: 0, width: editor, height: titleRow)
        case .clipBar: return CGRect(x: explorer, y: titleRow, width: editor, height: clipBar)
        case .transcript: return CGRect(x: explorer, y: titleRow + clipBar, width: editor, height: top - titleRow - clipBar)
        case .rightTitle: return right > 0 ? CGRect(x: width - right, y: 0, width: right, height: titleRow) : nil
        case .rightBody: return right > 0 ? CGRect(x: width - right, y: titleRow, width: right, height: top - titleRow) : nil
        case .timeline: return CGRect(x: explorer, y: top, width: width - explorer, height: timeline)
        case .statusBar: return CGRect(x: 0, y: workHeight, width: width, height: statusBar)
        }
    }
}

/// Hosts SwiftUI in the shell (impl-plan §4). Environment values do not cross hosting
/// boundaries, so every root gets the app and the scene accent here; the titlebar never
/// insets the content, and SwiftUI manages no toolbar or title from inside the shell.
@MainActor enum ShellHost {
    static func controller<Content: View>(_ content: Content, app: AppModel, sizing: NSHostingSizingOptions = []) -> NSViewController {
        let host = NSHostingController(rootView: content.environment(app).sceneAccent())
        host.safeAreaRegions = []
        host.sizingOptions = sizing
        host.sceneBridgingOptions = []
        return host
    }
}

/// Runs `render` now and again whenever an observable value it read changes, until cancelled.
@MainActor final class ShellObservation {
    private let render: () -> Void
    private var cancelled = false
    init(_ render: @escaping () -> Void) {
        self.render = render
        track()
    }
    func cancel() { cancelled = true }
    private func track() {
        guard !cancelled else { return }
        withObservationTracking { render() } onChange: { [weak self] in
            Task { @MainActor in self?.track() }
        }
    }
}

extension NSView {
    /// Makes this view a named VoiceOver group around its subviews (impl-plan V1b:
    /// "Explorer", "Editor", "Viewer and panel", "Timeline", "Status").
    func shellGroup(_ label: String) {
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(label)
    }
}

// MARK: - Views

/// Fixed-height rows at the top and bottom, and one view that fills the rest.
@MainActor final class ShellStackView: NSView {
    private var top: [(view: NSView, height: CGFloat)] = []
    private var bottom: [(view: NSView, height: CGFloat)] = []
    private var fillView: NSView?
    private let fill: String?
    init(fill: String? = nil) {
        self.fill = fill
        super.init(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    func set(top: [(view: NSView, height: CGFloat)], fill: NSView, bottom: [(view: NSView, height: CGFloat)] = []) {
        for view in [self.top.map(\.view), [fillView].compactMap { $0 }, self.bottom.map(\.view)].joined() where view.superview === self { view.removeFromSuperview() }
        self.top = top; self.bottom = bottom; fillView = fill
        for view in top.map(\.view) + [fill] + bottom.map(\.view) { addSubview(view) }
        needsLayout = true
    }
    override func layout() {
        super.layout()
        var y: CGFloat = 0
        for row in top {
            row.view.frame = NSRect(x: 0, y: y, width: bounds.width, height: row.height)
            y += row.height
        }
        var end = bounds.height
        for row in bottom.reversed() {
            end -= row.height
            row.view.frame = NSRect(x: 0, y: end, width: bounds.width, height: row.height)
        }
        fillView?.frame = NSRect(x: 0, y: y, width: bounds.width, height: max(0, end - y))
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let fill else { return }
        DesignValues.nsColor(fill).setFill()
        dirtyRect.fill()
    }
}

/// A row of the shell: its token fill, an optional bottom hairline, and controls at its
/// start and end, centred on the window buttons' line. A title row also moves the window
/// on a drag of its empty space and runs the system double-click action; its controls
/// get their own clicks.
@MainActor final class ShellBand: NSView {
    private let fill: String
    private let bottomLine: Bool
    let movesWindow: Bool
    var leadingInset: CGFloat = 0 { didSet { needsLayout = true } }
    var trailingInset: CGFloat = 8 { didSet { needsLayout = true } }
    var spacing: CGFloat = 4 { didSet { needsLayout = true } }
    private(set) var leading: [NSView] = []
    private(set) var trailing: [NSView] = []
    init(fill: String, bottomLine: Bool, movesWindow: Bool, region: String) {
        self.fill = fill; self.bottomLine = bottomLine; self.movesWindow = movesWindow
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: ShellMetrics.titleRow))
        identifier = NSUserInterfaceItemIdentifier("voxclip.shell.\(region)")
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { movesWindow }

    /// Places `leading` from the start and `trailing` at the end. A view placed in another
    /// band moves here.
    func set(leading: [NSView], trailing: [NSView]) {
        for view in self.leading + self.trailing where view.superview === self && !(leading + trailing).contains(view) { view.removeFromSuperview() }
        self.leading = leading; self.trailing = trailing
        for view in leading + trailing where view.superview !== self { addSubview(view) }
        needsLayout = true
    }
    override func layout() {
        super.layout()
        let center = min(ShellMetrics.controlCenter, bounds.height / 2)
        var x = leadingInset
        for view in leading where view.superview === self {
            let size = Self.size(of: view)
            view.frame = NSRect(x: x, y: (center - size.height / 2).rounded(), width: size.width, height: size.height)
            x += size.width + spacing
        }
        var end = bounds.width - trailingInset
        for view in trailing.reversed() where view.superview === self {
            let size = Self.size(of: view)
            end -= size.width
            view.frame = NSRect(x: end, y: (center - size.height / 2).rounded(), width: size.width, height: size.height)
            end -= spacing
        }
    }
    private static func size(of view: NSView) -> NSSize {
        let intrinsic = view.intrinsicContentSize
        let fitting = view.fittingSize
        return NSSize(width: intrinsic.width == NSView.noIntrinsicMetric ? fitting.width : intrinsic.width,
                      height: intrinsic.height == NSView.noIntrinsicMetric ? fitting.height : intrinsic.height)
    }
    override func draw(_ dirtyRect: NSRect) {
        DesignValues.nsColor(fill).setFill()
        dirtyRect.fill()
        guard bottomLine else { return }
        DesignValues.nsColor("line.default").setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }
    override func mouseDown(with event: NSEvent) {
        guard movesWindow, let window else { super.mouseDown(with: event); return }
        if event.clickCount == 2 { Self.titleBarDoubleClick(window) } else { window.performDrag(with: event) }
    }
    /// The system's title-bar double-click action (Desktop & Dock settings). Fill has no
    /// public API, so it zooms like Zoom.
    static func titleBarDoubleClick(_ window: NSWindow) {
        let defaults = UserDefaults.standard
        let action = defaults.string(forKey: "AppleActionOnDoubleClick") ?? (defaults.bool(forKey: "AppleMiniaturizeOnDoubleClick") ? "Minimize" : "Maximize")
        switch action {
        case "Minimize": window.performMiniaturize(nil)
        case "None": break
        default: window.performZoom(nil)
        }
    }
}

/// A borderless 24 × 24 symbol button in a title row (notes.md `.icb`): text.tertiary.
@MainActor final class ShellIconButton: NSButton {
    init(symbol: String, size: CGFloat = 15, identifier: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: ShellMetrics.iconButton, height: ShellMetrics.iconButton))
        self.identifier = NSUserInterfaceItemIdentifier(identifier)
        isBordered = false
        setButtonType(.momentaryPushIn)
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        contentTintColor = DesignValues.nsColor("text.tertiary")
        title = ""
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: size, weight: .regular))
    }
    required init?(coder: NSCoder) { nil }
    override var intrinsicContentSize: NSSize { NSSize(width: ShellMetrics.iconButton, height: ShellMetrics.iconButton) }
    /// The accessible name, and the tooltip with its shortcut.
    func describe(_ name: String, shortcut: String? = nil) {
        setAccessibilityLabel(name)
        toolTip = shortcut.map { "\(name) (\($0))" } ?? name
    }
}

/// Export in the right title row (notes.md `.btn`): a neutral bordered button, bg.muted
/// with a line.edge outline, 24 high, radius 6, a 13 pt medium label. Not the orange tint
/// and not the system accent (impl-plan item 10). It reads "Export"; its accessible name
/// and tooltip carry the scope's full title.
@MainActor final class ShellExportButton: NSButton {
    static func colors(for appearance: NSAppearance) -> (fill: NSColor, pressed: NSColor, outline: NSColor, label: NSColor) {
        var resolved = (fill: NSColor.clear, pressed: NSColor.clear, outline: NSColor.clear, label: NSColor.clear)
        appearance.performAsCurrentDrawingAppearance {
            resolved = (DesignValues.nsColor("bg.muted").usingColorSpace(.sRGB) ?? .clear,
                        DesignValues.nsColor("bg.selectedRow").usingColorSpace(.sRGB) ?? .clear,
                        DesignValues.nsColor("line.edge").usingColorSpace(.sRGB) ?? .clear,
                        DesignValues.nsColor("text.primary").usingColorSpace(.sRGB) ?? .clear)
        }
        return resolved
    }
    /// "Export Video…" or "Export Clip…" (design §3.5).
    var exportTitle = "Export Video…"
    var handler: () -> Void = {}
    override var isEnabled: Bool { didSet { updateLabel() } }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 86, height: 24))
        identifier = NSUserInterfaceItemIdentifier("voxclip.shell.export")
        isBordered = false
        setButtonType(.momentaryPushIn)
        imagePosition = .imageLeading
        imageHugsTitle = true
        image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        target = self
        action = #selector(invoke)
        updateLabel()
    }
    required init?(coder: NSCoder) { nil }
    @objc private func invoke() { handler() }
    private func updateLabel() {
        let color = DesignValues.nsColor(isEnabled ? "text.primary" : "text.disabled")
        contentTintColor = color
        attributedTitle = NSAttributedString(string: "Export", attributes: [.font: VCType.body.nsFont(.medium), .foregroundColor: color])
        needsDisplay = true
    }
    override var intrinsicContentSize: NSSize {
        let padded: CGFloat = super.intrinsicContentSize.width + 20
        return NSSize(width: padded.rounded(.up), height: 24)
    }
    private var outline: NSBezierPath { NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6) }
    override func draw(_ dirtyRect: NSRect) {
        let path = outline
        DesignValues.nsColor(isHighlighted ? "bg.selectedRow" : "bg.muted").setFill()
        path.fill()
        DesignValues.nsColor("line.edge").setStroke()
        path.lineWidth = 1
        path.stroke()
        super.draw(dirtyRect)
    }
    override func drawFocusRingMask() { outline.fill() }
    override var focusRingMaskBounds: NSRect { bounds }
}

/// The tab row's one tab until V3a (notes.md `.tab.on`): the scope's name on the editor
/// surface with a text.tertiary line on top and a hairline after it. Clicks fall
/// through to the title row, which moves the window.
@MainActor final class ShellScopeTab: NSView {
    private let icon = NSImageView()
    let label = NSTextField(labelWithString: "Full Take")
    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 140, height: ShellMetrics.titleRow))
        identifier = NSUserInterfaceItemIdentifier("voxclip.shell.scopeTab")
        icon.contentTintColor = DesignValues.nsColor("text.secondary")
        icon.setAccessibilityElement(false)
        label.font = VCType.body.nsFont()
        label.textColor = DesignValues.nsColor("text.primary")
        label.lineBreakMode = .byTruncatingTail
        label.setAccessibilityIdentifier("voxclip.shell.scopeTab.label")
        addSubview(icon); addSubview(label)
        show(name: "Full Take", clip: false)
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    func show(name: String, clip: Bool) {
        label.stringValue = name
        icon.image = NSImage(systemSymbolName: clip ? "rectangle.on.rectangle" : "film", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        invalidateIntrinsicContentSize()
        superview?.needsLayout = true
        needsLayout = true
    }
    /// Before the name: 12 + the 14 pt icon + 7. After it: 7 + the 16 pt close slot + 10 (notes.md `.tab`).
    private static let leadingRoom: CGFloat = 33
    private static let trailingRoom: CGFloat = 33
    override var intrinsicContentSize: NSSize {
        let name: CGFloat = label.intrinsicContentSize.width
        let width: CGFloat = Self.leadingRoom + name + Self.trailingRoom
        return NSSize(width: width.rounded(.up), height: ShellMetrics.titleRow)
    }
    override func layout() {
        super.layout()
        let iconSide: CGFloat = 14
        icon.frame = NSRect(x: 12, y: (bounds.height - iconSide) / 2, width: iconSide, height: iconSide)
        let text = label.intrinsicContentSize
        let top: CGFloat = ((bounds.height - text.height) / 2).rounded()
        let width: CGFloat = max(0, bounds.width - Self.leadingRoom - Self.trailingRoom)
        label.frame = NSRect(x: Self.leadingRoom, y: top, width: width, height: text.height)
    }
    override func draw(_ dirtyRect: NSRect) {
        DesignValues.nsColor("bg.surface").setFill()
        bounds.fill()
        DesignValues.nsColor("text.tertiary").setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        DesignValues.nsColor("line.default").setFill()
        NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height).fill()
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The Home title row's project search (it was the toolbar's search field).
@MainActor final class HomeSearchField: NSSearchField {
    override var intrinsicContentSize: NSSize { NSSize(width: 240, height: super.intrinsicContentSize.height) }
}

// MARK: - Splits

/// A split of the shell: 1 pt token hairlines, and a report when the user drags a
/// divider. NSSplitView gets mouseDown only on (or beside) a divider, because its panes
/// cover the rest, and `super.mouseDown` returns when the drag ends; window resizes,
/// toggles and collapses never come through here, so they never store a size.
@MainActor final class ShellSplitView: NSSplitView {
    var dividerToken = "line.default"
    var onDividerDrag: (() -> Void)?
    /// A divider is being dragged: the shell places no divider until the drag ends.
    private(set) var isDragging = false
    #if DEBUG
    var dividerMouseDowns = 0
    #endif
    override var dividerColor: NSColor { DesignValues.nsColor(dividerToken) }
    override func mouseDown(with event: NSEvent) {
        #if DEBUG
        dividerMouseDowns += 1
        #endif
        let before = arrangedSubviews.map(\.frame.size)
        isDragging = true
        super.mouseDown(with: event)
        isDragging = false
        guard arrangedSubviews.map(\.frame.size) != before else { return }
        onDividerDrag?()
    }
}

/// A split view controller around a ShellSplitView that reports every resize, so a
/// collapse by dragging reaches the layout.
@MainActor class ShellSplitController: NSSplitViewController {
    let divider = ShellSplitView()
    var onResize: (() -> Void)?
    init(vertical: Bool, identifier: String, dividerToken: String = "line.default") {
        super.init(nibName: nil, bundle: nil)
        divider.isVertical = vertical
        divider.dividerStyle = .thin
        divider.dividerToken = dividerToken
        divider.identifier = NSUserInterfaceItemIdentifier(identifier)
        splitView = divider
        NotificationCenter.default.addObserver(self, selector: #selector(splitDidResize(_:)), name: NSSplitView.didResizeSubviewsNotification, object: divider)
    }
    required init?(coder: NSCoder) { nil }
    @objc private func splitDidResize(_ notification: Notification) { onResize?() }

    /// A divider that cannot be dragged now: a pane collapsed because the window is too
    /// narrow for it shows over the editor on request instead (impl-plan §3.5).
    var dividerLocked: ((Int) -> Bool)?
    override func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect, forDrawnRect drawnRect: NSRect, ofDividerAt dividerIndex: Int) -> NSRect {
        if dividerLocked?(dividerIndex) == true { return .zero }
        return super.splitView(splitView, effectiveRect: proposedEffectiveRect, forDrawnRect: drawnRect, ofDividerAt: dividerIndex)
    }

    static func item(_ controller: NSViewController, thickness: ClosedRange<CGFloat>? = nil, holding: Float, collapses: Bool) -> NSSplitViewItem {
        let item = NSSplitViewItem(viewController: controller)
        if let thickness {
            item.minimumThickness = thickness.lowerBound
            item.maximumThickness = thickness.upperBound
        }
        item.holdingPriority = NSLayoutConstraint.Priority(holding)
        item.canCollapse = collapses
        return item
    }
    /// Collapses or expands without animation: the layout flag is the truth, and a toggle
    /// is one step, so an animation would only lag behind it.
    static func setCollapsed(_ item: NSSplitViewItem, _ collapsed: Bool) {
        if item.isCollapsed != collapsed { item.isCollapsed = collapsed }
    }
}

/// A view controller for an AppKit view built in code.
@MainActor final class ShellViewController: NSViewController {
    private let root: NSView
    init(_ root: NSView, children: [NSViewController] = []) {
        self.root = root
        super.init(nibName: nil, bundle: nil)
        for child in children { addChild(child) }
    }
    required init?(coder: NSCoder) { nil }
    override func loadView() { view = root }
}

/// The editor and right columns, and over them below 904 the right column on request
/// (impl-plan §3.5): under the tab row, at the trailing edge, `overlayWidth` wide.
@MainActor final class ShellOverlayView: NSView {
    private let base: NSView
    var overlay: NSView? {
        didSet {
            guard overlay !== oldValue else { return }
            oldValue?.removeFromSuperview()
            if let overlay { addSubview(overlay) }
            needsLayout = true
        }
    }
    var overlayWidth: CGFloat = CGFloat(VCTokens.sizeRightColumnMin) { didSet { needsLayout = true } }
    init(_ base: NSView) {
        self.base = base
        super.init(frame: base.frame)
        addSubview(base)
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        base.frame = bounds
        let width = min(overlayWidth, bounds.width)
        overlay?.frame = NSRect(x: bounds.width - width, y: ShellMetrics.titleRow, width: width, height: max(0, bounds.height - ShellMetrics.titleRow))
    }
}

/// The right column shown over the editor (impl-plan §3.5): flat, on the chrome, with a
/// 1 pt `line.strong` edge on top of its content at the leading side, the boundary a
/// pane over content needs (3:1). No shadow.
@MainActor final class ShellRightOverlay: NSView {
    private let edge = ShellRule(token: "line.strong")
    init(content: NSView) {
        super.init(frame: NSRect(x: 0, y: 0, width: CGFloat(VCTokens.sizeRightColumnMin), height: 400))
        identifier = NSUserInterfaceItemIdentifier("voxclip.shell.rightOverlay")
        shellGroup("Viewer and panel")
        addSubview(content)
        addSubview(edge)
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        for view in subviews where view !== edge { view.frame = bounds }
        edge.frame = NSRect(x: 0, y: 0, width: 1, height: bounds.height)
    }
    override func draw(_ dirtyRect: NSRect) {
        DesignValues.nsColor("bg.window").setFill()
        dirtyRect.fill()
    }
}

/// A token-coloured line, drawn above its siblings.
@MainActor final class ShellRule: NSView {
    private let token: String
    init(token: String) {
        self.token = token
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        DesignValues.nsColor(token).setFill()
        dirtyRect.fill()
    }
}

// MARK: - The shell

/// What the AppKit tree is built from. WorkspaceView reads it, so SwiftUI updates the
/// tree when it changes; the controls inside observe the editor themselves.
struct EditorShellState: Equatable {
    var editor: ObjectIdentifier?
    var showsHome: Bool
    var explorerVisible: Bool
    var rightVisible: Bool
    var rightOverlay: Bool
    var timelineVisible: Bool
    var homeQuery: String
    @MainActor init(shell: WorkspaceShell) {
        editor = shell.editor.map(ObjectIdentifier.init)
        showsHome = shell.showsHome
        explorerVisible = shell.layout.explorerVisible
        rightVisible = shell.layout.rightVisible
        rightOverlay = shell.rightOverlay
        timelineVisible = shell.layout.timelineVisible
        homeQuery = shell.homeQuery
    }
}

/// WorkspaceView's content: the shell controller.
@MainActor struct EditorShellView: NSViewControllerRepresentable {
    let shell: WorkspaceShell
    let state: EditorShellState
    func makeNSViewController(context: Context) -> EditorShellController { EditorShellController(shell: shell) }
    func updateNSViewController(_ controller: EditorShellController, context: Context) { controller.apply(state) }
    static func dismantleNSViewController(_ controller: EditorShellController, coordinator: ()) { controller.tearDown() }
    func sizeThatFits(_ proposal: ProposedViewSize, nsViewController: EditorShellController, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 1280, height: proposal.height ?? 800)
    }
}

/// The root of the shell (impl-plan V1a): a vertical stack of the content split and the
/// 24 pt status bar. The content split holds the Explorer and the work area: the editor
/// column and the right column over the timeline panel, or Home.
@MainActor final class EditorShellController: NSViewController, NSSearchFieldDelegate, ShellChromeFocus {
    let shell: WorkspaceShell
    private let content = ShellSplitController(vertical: true, identifier: "voxclip.shell.content")
    private let explorerHeader = ShellBand(fill: "bg.window", bottomLine: false, movesWindow: true, region: "explorerHeader")
    private var explorerItem: NSSplitViewItem?
    /// What `apply` last asked of the Explorer. Only a change from it is the user's: the
    /// layout can be ahead of the pane until SwiftUI applies it.
    private var explorerShown = true
    private let workArea = ShellStackView(fill: "bg.window")
    private var workHost: ShellViewController?
    private var workController: NSViewController?
    private(set) var statusBar: StatusBarView?
    private var applied: EditorShellState?
    private var sizedContent = false
    /// The editor's columns and timeline, while a project shows.
    private(set) var editorWork: EditorWorkController?
    /// Home's title row and Home, while Home shows.
    private(set) var homeBand: ShellBand?
    let homeSearch = HomeSearchField()
    /// Shows and hides the Explorer: in its header while it shows, else at the start of the work area's title row.
    let explorerToggle = ShellIconButton(symbol: "sidebar.left", identifier: "voxclip.shell.toggleExplorer")

    init(shell: WorkspaceShell) {
        self.shell = shell
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }

    /// The window frame of the shell: the system frame and corner radius, no toolbar, and
    /// the content under a transparent titlebar, whose title is hidden but still set for
    /// the Window menu and VoiceOver.
    static func prepare(_ window: NSWindow) {
        window.styleMask.insert(.fullSizeContentView)
        window.toolbar = nil
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
    }

    override func loadView() {
        let root = ShellStackView(fill: "bg.window")
        root.identifier = NSUserInterfaceItemIdentifier("voxclip.shell")
        view = root
        let list = ShellHost.controller(WorkspaceSidebar(shell: shell), app: shell.app)
        let explorerView = ShellStackView(fill: "bg.window")
        explorerView.identifier = NSUserInterfaceItemIdentifier("voxclip.shell.explorer")
        explorerView.shellGroup("Explorer")
        explorerView.set(top: [(explorerHeader, ShellMetrics.explorerHeader)], fill: list.view)
        let explorer = ShellViewController(explorerView, children: [list])
        explorerView.setFrameSize(NSSize(width: shell.layout.explorerWidth, height: 776))
        let explorerItem = ShellSplitController.item(explorer, thickness: CGFloat(WorkspaceLayout.explorerRange.lowerBound)...CGFloat(WorkspaceLayout.explorerRange.upperBound), holding: 260, collapses: true)
        self.explorerItem = explorerItem
        let work = ShellViewController(workArea)
        workHost = work
        workArea.setFrameSize(NSSize(width: shell.windowWidth - shell.layout.explorerWidth, height: 776))
        content.addSplitViewItem(explorerItem)
        content.addSplitViewItem(ShellSplitController.item(work, holding: 250, collapses: false))
        content.divider.onDividerDrag = { [weak self] in self?.explorerDragged() }
        content.onResize = { [weak self] in self?.syncCollapsed() }
        // Below 1,128 a collapsed Explorer opens as the overlay, never by a drag.
        content.dividerLocked = { [weak self] _ in
            guard let self, let explorerItem = self.explorerItem else { return false }
            return explorerItem.isCollapsed && self.shell.windowWidth < self.shell.explorerCollapseWidth
        }
        addChild(content)
        shell.chromeFocus = self
        let status = StatusBarView(shell: shell)
        status.shellGroup("Status")
        statusBar = status
        root.set(top: [], fill: content.view, bottom: [(status, ShellMetrics.statusBar)])
        explorerHeader.trailingInset = 8
        explorerToggle.target = self
        explorerToggle.action = #selector(toggleExplorer)
        homeSearch.placeholderString = "Search projects"
        homeSearch.controlSize = .small
        homeSearch.font = VCType.callout.nsFont()
        homeSearch.sendsSearchStringImmediately = true
        homeSearch.delegate = self
        homeSearch.target = self
        homeSearch.action = #selector(homeSearchChanged(_:))
        homeSearch.setAccessibilityIdentifier("voxclip.home.search")
        for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(windowFullScreenChanged(_:)), name: name, object: nil)
        }
    }

    /// Builds or updates the tree for `state`.
    func apply(_ state: EditorShellState) {
        loadViewIfNeeded()
        let rebuild = applied.map { $0.editor != state.editor || $0.showsHome != state.showsHome } ?? true
        applied = state
        if rebuild { buildWorkArea() }
        explorerShown = state.explorerVisible
        if let explorerItem { ShellSplitController.setCollapsed(explorerItem, !state.explorerVisible) }
        editorWork?.apply(rightVisible: state.rightVisible, timelineVisible: state.timelineVisible, rightOverlay: state.rightOverlay)
        if homeSearch.stringValue != state.homeQuery { homeSearch.stringValue = state.homeQuery }
        placeChrome()
    }

    func tearDown() {
        editorWork?.tearDown()
        statusBar?.tearDown()
    }

    private func buildWorkArea() {
        editorWork?.tearDown()
        workController?.removeFromParent()
        editorWork = nil
        homeBand = nil
        let next: NSViewController
        if !shell.showsHome, let editor = shell.editor {
            let work = EditorWorkController(model: editor, shell: shell)
            let width = workArea.bounds.width > 0 ? workArea.bounds.width : shell.windowWidth - shell.layout.explorerWidth
            work.view.setFrameSize(NSSize(width: width, height: max(ShellMetrics.topMinimum + 100, workArea.bounds.height)))
            editorWork = work
            next = work
        } else {
            let band = ShellBand(fill: "bg.window", bottomLine: true, movesWindow: true, region: "homeTitle")
            band.trailingInset = 8
            band.set(leading: [], trailing: [homeSearch])
            homeBand = band
            let home = ShellHost.controller(HomeView(shell: shell), app: shell.app)
            let stack = ShellStackView(fill: "bg.surface")
            stack.set(top: [(band, ShellMetrics.titleRow)], fill: home.view)
            next = ShellViewController(stack, children: [home])
        }
        workHost?.addChild(next)
        workController = next
        workArea.set(top: [], fill: next.view)
    }

    /// The Explorer toggle sits in the Explorer's header while it shows, else at the start
    /// of the work area's title row after the window buttons; the right column's controls
    /// move into the tab row while it is hidden.
    private func placeChrome() {
        let explorerShows = applied?.explorerVisible ?? true
        let titleRow = editorWork?.tabRow ?? homeBand
        let fullScreen = view.window?.styleMask.contains(.fullScreen) == true
        explorerToggle.describe((explorerShows ? EditorIconAction.hideSidebar : .showSidebar).name, shortcut: "⌃⌘S")
        if explorerShows {
            explorerHeader.set(leading: [], trailing: [explorerToggle])
            titleRow?.leadingInset = 0
            editorWork?.placeTabRow(explorerToggle: nil)
            if titleRow === homeBand { homeBand?.set(leading: [], trailing: [homeSearch]) }
        } else {
            explorerHeader.set(leading: [], trailing: [])
            titleRow?.leadingInset = fullScreen ? 8 : ShellMetrics.windowButtons
            editorWork?.placeTabRow(explorerToggle: explorerToggle)
            if titleRow === homeBand { homeBand?.set(leading: [explorerToggle], trailing: [homeSearch]) }
        }
    }

    @objc private func toggleExplorer() { shell.toggleSidebar() }

    /// The window buttons leave the title rows in full screen and come back after it, and
    /// neither runs `apply`.
    @objc private func windowFullScreenChanged(_ notification: Notification) {
        guard let window = view.window, (notification.object as? NSWindow) === window else { return }
        placeChrome()
    }

    /// A divider drag that collapses or opens the Explorer reaches the layout.
    private func syncCollapsed() {
        guard let explorerItem else { return }
        let shows = !explorerItem.isCollapsed
        guard shows != explorerShown else { return }
        explorerShown = shows
        if shell.layout.explorerVisible != shows { shell.layout.explorerVisible = shows }
    }
    private func explorerDragged() {
        guard let explorerItem, !explorerItem.isCollapsed else { return }
        shell.layout.rememberExplorerWidth(Double(explorerItem.viewController.view.frame.width))
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // The timeline's starting height follows the work area's (impl-plan §3.5).
        let workHeight = Double(content.view.frame.height)
        if workHeight > 0, abs(shell.layout.workHeight - workHeight) > 0.5 { shell.layout.workHeight = workHeight }
        // The first real size places the Explorer's divider at its width, after this layout pass.
        guard !sizedContent, content.divider.bounds.width > 400 else { return }
        sizedContent = true
        Task { @MainActor [weak self] in self?.placeDivider() }
    }
    private func placeDivider() {
        guard let explorerItem, !explorerItem.isCollapsed else { return }
        content.divider.setPosition(CGFloat(shell.layout.explorerWidth), ofDividerAt: 0)
    }

    /// Typing posts a text change at once and sends the action a moment later; the cancel
    /// button and Escape clear the field and send only the action.
    func controlTextDidChange(_ notification: Notification) {
        guard (notification.object as? NSSearchField) === homeSearch else { return }
        followHomeSearch()
    }
    @objc private func homeSearchChanged(_ sender: NSSearchField) { followHomeSearch() }
    private func followHomeSearch() {
        if shell.homeQuery != homeSearch.stringValue { shell.homeQuery = homeSearch.stringValue }
    }

    // MARK: F6 (ShellChromeFocus)

    func paneHoldingFocus() -> EditorPane? {
        guard let responder = view.window?.firstResponder as? NSView else { return nil }
        if responder is TranscriptNSTextView { return .transcript }
        if let statusBar, responder.isDescendant(of: statusBar) { return .status }
        if let work = editorWork, responder.isDescendant(of: work.tabRow) || responder.isDescendant(of: work.clipBar) { return .tabs }
        return nil
    }
    /// The tab and clip-bar rows take focus at ⋯ until V3a's tabs; the transcript is found
    /// in this window's tree; the status bar takes it itself.
    @discardableResult func focus(_ pane: EditorPane) -> Bool {
        guard let window = view.window else { return false }
        switch pane {
        case .tabs: return editorWork.map { window.makeFirstResponder($0.overflow) } ?? false
        case .transcript: return focusTranscript(in: window)
        case .status: return statusBar?.takeFocus() ?? false
        case .sidebar, .viewer, .panel, .timeline:
            // EditorPaneFocus focuses these a moment later; the stop lets go now.
            if paneHoldingFocus() != nil { window.makeFirstResponder(nil) }
            return false
        }
    }

}

/// The editor's part of the shell for one project: the editor column (tab row, clip-bar
/// row, transcript) beside the right column (title row, viewer and panel), over the
/// timeline panel, whose top edge (line.edge) is its resize handle. The editor column
/// hosts every editor state under the clip-bar row (`TranscriptColumn`). Below 904 the
/// right column shows over the editor on request.
@MainActor final class EditorWorkController: ShellSplitController, NSPopoverDelegate {
    let model: EditorModel
    let shell: WorkspaceShell
    /// The editor column beside the right column.
    let columns = ShellSplitController(vertical: true, identifier: "voxclip.editor.split")
    let tabRow = ShellBand(fill: "bg.window", bottomLine: true, movesWindow: true, region: "tabBar")
    let clipBar = ShellBand(fill: "bg.surface", bottomLine: true, movesWindow: false, region: "clipBar")
    private let rightTitle = ShellBand(fill: "bg.window", bottomLine: true, movesWindow: true, region: "rightTitle")
    private let scopeTab = ShellScopeTab()
    let overflow = ShellIconButton(symbol: "ellipsis", size: 14, identifier: "voxclip.shell.more")
    let export = ShellExportButton()
    let timelineToggle = ShellIconButton(symbol: "rectangle.bottomthird.inset.filled", identifier: "voxclip.shell.toggleTimeline")
    let rightToggle = ShellIconButton(symbol: "sidebar.right", identifier: "voxclip.shell.toggleRight")
    private(set) var transcriptView: NSView?
    private(set) var rightItem: NSSplitViewItem!
    private(set) var timelineItem: NSSplitViewItem!
    private var topItem: NSSplitViewItem!
    /// The columns, with the right column over them on request below 904.
    private var top: ShellOverlayView!
    private var topController: ShellViewController!
    /// The right column over the editor and its SwiftUI host, while it shows.
    private(set) var rightOverlay: (view: ShellRightOverlay, host: NSViewController)?
    /// What the dividers were last placed for, so a size the split cannot take is not retried.
    private var placedFor: [CGFloat] = []
    private var placing = false
    /// What `apply` last asked of the right column and the timeline. Only a change from it
    /// is the user's: the layout can be ahead of the panes until SwiftUI applies it.
    private var rightShown = true
    private var timelineShown = true
    private var observations: [ShellObservation] = []
    private(set) var findClipsPopover: NSPopover?
    private var explorerToggle: NSView?
    private var sized = false

    init(model: EditorModel, shell: WorkspaceShell) {
        self.model = model
        self.shell = shell
        super.init(vertical: false, identifier: "voxclip.shell.work", dividerToken: "line.edge")
        build()
    }
    required init?(coder: NSCoder) { nil }

    private func build() {
        let app = shell.app
        let transcript = ShellHost.controller(TranscriptColumn(model: model, shell: shell).background(TranscriptFocusOnShow(model: model)), app: app)
        transcriptView = transcript.view
        transcript.view.identifier = NSUserInterfaceItemIdentifier("voxclip.shell.transcript")
        let editorStack = ShellStackView(fill: "bg.surface")
        editorStack.identifier = NSUserInterfaceItemIdentifier("voxclip.shell.editor")
        editorStack.shellGroup("Editor")
        editorStack.set(top: [(tabRow, ShellMetrics.titleRow), (clipBar, ShellMetrics.clipBar)], fill: transcript.view)
        let editorColumn = ShellViewController(editorStack, children: [transcript])

        let right = ShellHost.controller(RightColumn(model: model), app: app)
        let rightStack = ShellStackView(fill: "bg.window")
        rightStack.identifier = NSUserInterfaceItemIdentifier("voxclip.shell.right")
        rightStack.shellGroup("Viewer and panel")
        rightStack.set(top: [(rightTitle, ShellMetrics.titleRow)], fill: right.view)
        let rightColumn = ShellViewController(rightStack, children: [right])

        let timeline = ShellHost.controller(TimelinePanel(model: model, shell: shell), app: app)
        let timelineStack = ShellStackView(fill: "bg.window")
        timelineStack.identifier = NSUserInterfaceItemIdentifier("voxclip.shell.timeline")
        timelineStack.shellGroup("Timeline")
        timelineStack.set(top: [], fill: timeline.view)
        let timelinePane = ShellViewController(timelineStack, children: [timeline])

        let layout = shell.layout
        let width = max(800, shell.windowWidth - (layout.explorerVisible ? layout.explorerWidth : 0))
        editorStack.setFrameSize(NSSize(width: width - layout.rightWidth, height: 560))
        rightStack.setFrameSize(NSSize(width: layout.rightWidth, height: 560))
        let editorItem = Self.item(editorColumn, holding: 250, collapses: false)
        // The editor's minimum less the two dividers its rows include (ShellRegion).
        editorItem.minimumThickness = CGFloat(WorkspaceShell.minimumTranscriptPane) - 2
        rightItem = Self.item(rightColumn, thickness: CGFloat(WorkspaceLayout.rightRange.lowerBound)...CGFloat(WorkspaceLayout.rightRange.upperBound), holding: 251, collapses: true)
        columns.addSplitViewItem(editorItem)
        columns.addSplitViewItem(rightItem)
        columns.divider.onDividerDrag = { [weak self] in self?.rightDragged() }
        columns.onResize = { [weak self] in self?.syncCollapsed() }
        // Below 904 a collapsed right column opens over the editor, never by a drag.
        columns.dividerLocked = { [weak self] _ in
            guard let self, let rightItem = self.rightItem else { return false }
            return rightItem.isCollapsed && self.shell.windowWidth < WorkspaceShell.rightCollapseWidth
        }

        columns.view.setFrameSize(NSSize(width: width, height: 560))
        timelineStack.setFrameSize(NSSize(width: width, height: layout.timelineHeight))
        top = ShellOverlayView(columns.view)
        top.identifier = NSUserInterfaceItemIdentifier("voxclip.shell.columns")
        topController = ShellViewController(top, children: [columns])
        topItem = Self.item(topController, holding: 250, collapses: false)
        topItem.minimumThickness = ShellMetrics.topMinimum
        timelineItem = Self.item(timelinePane, thickness: CGFloat(WorkspaceLayout.timelineRange.lowerBound)...CGFloat(WorkspaceLayout.timelineRange.upperBound), holding: 251, collapses: true)
        addSplitViewItem(topItem)
        addSplitViewItem(timelineItem)
        divider.onDividerDrag = { [weak self] in self?.timelineDragged() }
        onResize = { [weak self] in self?.syncCollapsed() }

        rightTitle.trailingInset = 8
        rightTitle.spacing = 6
        tabRow.trailingInset = 8
        overflow.describe(EditorIconAction.moreCommands.name)
        overflow.target = self
        overflow.action = #selector(showOverflow(_:))
        timelineToggle.target = self
        timelineToggle.action = #selector(toggleTimeline)
        rightToggle.target = self
        rightToggle.action = #selector(toggleRight)
        export.handler = { [weak self] in self?.model.presentExport() }
        placeTabRow(explorerToggle: nil)
        observations = [
            ShellObservation { [weak self] in self?.renderScope() },
            ShellObservation { [weak self] in self?.renderExport() },
            ShellObservation { [weak self] in self?.renderFindClips() },
            ShellObservation { [weak self] in self?.followSizes() }
        ]
    }

    func tearDown() {
        observations.forEach { $0.cancel() }
        observations = []
        findClipsPopover?.close()
        showRightOverlay(false)
    }

    /// Collapses or shows the right column and the timeline, shows the right column over the
    /// editor on request while it is collapsed below 904, and moves the right column's
    /// controls into the tab row while it is collapsed. Until V4's hover transport the
    /// timeline panel carries play and the timecode while the right column is collapsed, so
    /// neither its toggle nor a drag of its edge can hide it then (notes.md §1).
    func apply(rightVisible: Bool, timelineVisible: Bool, rightOverlay: Bool = false) {
        rightShown = rightVisible
        Self.setCollapsed(rightItem, !rightVisible)
        timelineShown = timelineVisible
        Self.setCollapsed(timelineItem, !timelineVisible)
        timelineItem.canCollapse = rightVisible
        timelineToggle.isEnabled = rightVisible || !timelineVisible
        showRightOverlay(rightOverlay && !rightVisible)
        rightToggle.describe((rightVisible || rightOverlay ? EditorIconAction.hideViewer : .showViewer).name, shortcut: "⌥⌘I")
        timelineToggle.describe((timelineVisible ? EditorIconAction.hideTimeline : .showTimeline).name)
        placeTabRow(explorerToggle: explorerToggle)
    }

    /// Builds the right column over the editor when it is asked for, and takes it down when
    /// it goes. It is its own `RightColumn`; Escape in it hides it.
    private func showRightOverlay(_ show: Bool) {
        if show, rightOverlay == nil {
            let host = ShellHost.controller(RightColumn(model: model).onExitCommand { [shell] in shell.rightOverlay = false }, app: shell.app)
            let panel = ShellRightOverlay(content: host.view)
            topController.addChild(host)
            top.overlayWidth = CGFloat(shell.layout.rightWidth)
            top.overlay = panel
            rightOverlay = (panel, host)
        } else if !show, let current = rightOverlay {
            top.overlay = nil
            current.host.removeFromParent()
            rightOverlay = nil
        }
    }

    /// The tab row: the Explorer toggle while the Explorer is hidden, the scope tab, then ⋯,
    /// and the right column's controls while it is hidden.
    func placeTabRow(explorerToggle: NSView?) {
        self.explorerToggle = explorerToggle
        let cluster: [NSView] = [export, timelineToggle, rightToggle]
        let rightShows = rightItem.map { !$0.isCollapsed } ?? true
        tabRow.set(leading: [explorerToggle, scopeTab].compactMap { $0 }, trailing: rightShows ? [overflow] : [overflow] + cluster)
        rightTitle.set(leading: [], trailing: rightShows ? cluster : [])
    }

    private func renderScope() {
        _ = model.projectRevision
        if let clip = model.activeClip, let number = model.clipNumber(clip.id) { scopeTab.show(name: "Clip \(number)", clip: true) }
        else { scopeTab.show(name: "Full Take", clip: false) }
        tabRow.needsLayout = true
    }

    private func renderExport() {
        // Its title and reasons come from the project, which only projectRevision makes observable.
        _ = model.projectRevision
        let title = model.exportTitle
        let reason = model.exportUnavailable
        export.exportTitle = title
        export.isEnabled = reason == nil && model.canExport
        export.setAccessibilityLabel(model.exportAccessibleName(title, targets: model.activeClip.map { [.clip($0.id)] } ?? [.fullEdit]))
        export.setAccessibilityHelp(reason)
        export.toolTip = reason ?? "\(title) (⌘E)"
    }

    // MARK: ⋯ and Find Clips

    @objc private func showOverflow(_ sender: NSButton) {
        overflowMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: sender.isFlipped ? sender.bounds.maxY + 4 : -4), in: sender)
    }
    /// Today's toolbar commands, which also stay in the menus (impl-plan V1a). Find
    /// Clips… opens its popover at ⋯.
    func overflowMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, _ action: Selector, key: String, _ modifiers: NSEvent.ModifierFlags, enabled: Bool) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = self
            item.isEnabled = enabled
            menu.addItem(item)
        }
        let edit = model.capabilities.edit, summary = model.summary
        add(summary.fillerCount > 0 ? "Cut Fillers (\(summary.fillerCount))" : "Cut Fillers", #selector(cutFillers), key: "u", [.command, .option], enabled: edit && summary.canCutFillers)
        add("Tighten Pauses", #selector(tightenPauses), key: "p", [.command, .option], enabled: edit && summary.canTighten)
        add("Restore Cuts", #selector(restoreCuts), key: "r", [.command, .option], enabled: edit && summary.hasEdits)
        menu.addItem(.separator())
        add("Find Clips…", #selector(findClips), key: "k", [.command, .shift], enabled: model.capabilities.ai && !model.words.isEmpty)
        return menu
    }
    @objc private func cutFillers() { model.apply(.cutFillers, name: "Cut fillers") }
    @objc private func tightenPauses() { model.apply(.tightenPauses, name: "Tighten pauses") }
    @objc private func restoreCuts() { model.apply(.restoreCuts, name: "Restore cuts") }
    @objc private func findClips() { model.requestFindClips(from: .overflow) }
    @objc private func toggleTimeline() { shell.toggleTimeline() }
    @objc private func toggleRight() { shell.toggleViewer() }

    /// The Find Clips popover from the menus, ⇧⌘K and ⋯ opens at ⋯ (impl-plan item 17).
    private func renderFindClips() {
        let wanted = model.showFindClips && model.findClipsAnchor == .overflow
        if wanted, findClipsPopover?.isShown != true, overflow.window != nil {
            let popover = NSPopover()
            popover.behavior = .transient
            popover.contentViewController = ShellHost.controller(FindClipsPopover(model: model), app: shell.app, sizing: [.preferredContentSize])
            popover.delegate = self
            findClipsPopover = popover
            popover.show(relativeTo: overflow.bounds, of: overflow, preferredEdge: .maxY)
        } else if !wanted, let popover = findClipsPopover, popover.isShown {
            popover.close()
        }
    }
    func popoverDidClose(_ notification: Notification) {
        findClipsPopover = nil
        if model.showFindClips && model.findClipsAnchor == .overflow { model.showFindClips = false }
    }

    // MARK: Sizes

    /// A divider drag that collapses or opens a pane reaches the layout. The right column
    /// goes through its toggle, which keeps the width rule's bookkeeping: the Explorer hidden
    /// to make room comes back, and showing it where the transcript would be too narrow hides
    /// the Explorer.
    private func syncCollapsed() {
        guard let rightItem, let timelineItem else { return }
        let right = !rightItem.isCollapsed, timeline = !timelineItem.isCollapsed
        if right != rightShown {
            rightShown = right
            if shell.layout.rightVisible != right { shell.toggleViewer() }
        }
        if timeline != timelineShown {
            timelineShown = timeline
            if shell.layout.timelineVisible != timeline { shell.layout.timelineVisible = timeline }
        }
    }
    private func rightDragged() {
        guard !rightItem.isCollapsed else { return }
        shell.layout.rememberRightWidth(Double(rightItem.viewController.view.frame.width))
    }
    private func timelineDragged() {
        guard !timelineItem.isCollapsed else { return }
        shell.layout.rememberTimelineHeight(Double(timelineItem.viewController.view.frame.height))
    }
    override func viewDidLayout() {
        super.viewDidLayout()
        // The first real size places the dividers, after this layout pass: the right column
        // at its width and the timeline at its height. Later sizes place them again when the
        // window's size moved what the layout asks for (impl-plan §3.5).
        if !sized {
            guard divider.bounds.height > 300, columns.divider.bounds.width > 400 else { return }
            sized = true
        }
        schedulePlacement()
    }
    /// The layout's sizes changed: the window resized, a column showed or hid, or a drag ended.
    private func followSizes() {
        let layout = shell.layout
        _ = (layout.rightWidth, layout.timelineHeight)
        top?.overlayWidth = CGFloat(layout.rightWidth)
        schedulePlacement()
    }
    /// What the dividers should be placed for now: the layout's sizes and the space they share.
    private var placement: [CGFloat] {
        [CGFloat(shell.layout.rightWidth), CGFloat(shell.layout.timelineHeight), columns.divider.bounds.width, divider.bounds.height,
         rightItem.isCollapsed ? 0 : 1, timelineItem.isCollapsed ? 0 : 1]
    }
    private func schedulePlacement() {
        guard sized, !placing, placement != placedFor else { return }
        placing = true
        Task { @MainActor [weak self] in self?.placeDividers() }
    }
    /// Places the right column at the layout's width and the timeline at its height. A drag
    /// in progress wins; it reports its size when it ends.
    private func placeDividers() {
        placing = false
        guard !divider.isDragging, !columns.divider.isDragging else { return }
        let layout = shell.layout
        if !rightItem.isCollapsed, abs(rightItem.viewController.view.frame.width - CGFloat(layout.rightWidth)) > 0.5 {
            columns.divider.setPosition(columns.divider.bounds.width - CGFloat(layout.rightWidth) - columns.divider.dividerThickness, ofDividerAt: 0)
        }
        if !timelineItem.isCollapsed, abs(timelineItem.viewController.view.frame.height - CGFloat(layout.timelineHeight)) > 0.5 {
            divider.setPosition(divider.bounds.height - CGFloat(layout.timelineHeight) - divider.dividerThickness, ofDividerAt: 0)
        }
        placedFor = placement
    }
}

/// The timeline panel's content until V7a: today's 72 pt strip at the top of the panel.
/// With the right column hidden it carries the compact transport.
@MainActor private struct TimelinePanel: View {
    let model: EditorModel
    let shell: WorkspaceShell
    var body: some View {
        TimelineStrip(model: model, compactTransport: !shell.layout.rightVisible)
            .frame(height: VCTokens.sizeTimelineHeight)
            .modifier(EditorPaneFocus(model: model, pane: .timeline))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(DesignValues.color("bg.window"))
    }
}
