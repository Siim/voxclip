import AppKit
import Observation
import VoxClipCore

// The editor's tabs (ux/v2 notes.md §1, impl-plan V3a): one tab per clip in the tab row,
// which doubles as the title bar. A tab is the editor's scope, `activeClipId`, written
// through `EditorModel.setScope`, so switching tabs is never an undo step and never makes
// the document edited (impl-plan item 16, §3.3).

// MARK: - Model

/// A tab in the editor's tab row: the full take, a kept clip, or a suggested clip.
enum EditorTab: Hashable, Sendable {
    case fullTake
    case clip(String)
    case suggestion(String)

    /// The clip the tab scopes the editor to; nil for Full Take.
    var clipID: String? {
        switch self {
        case .fullTake: nil
        case .clip(let id), .suggestion(let id): id
        }
    }
    /// Full Take is pinned: always open, never closed.
    var closable: Bool { self != .fullTake }
}

/// The open tabs of one window (impl-plan V3a, §3.4). Full Take is always open. Clip tabs
/// come before it in the order they opened, then the one preview tab after it: a
/// suggestion opened from the Explorer, set in italics and replaced by the next preview
/// (f1, f5). The active tab is the editor's scope. `dirty` marks tabs with unreviewed
/// changes, which show a dot (V14 sets it while hunks wait).
@MainActor @Observable final class EditorTabs {
    /// Kept clips, and suggestions kept open, before Full Take in the order they opened.
    private(set) var clipTabs: [EditorTab] = []
    /// The preview tab after Full Take.
    private(set) var preview: EditorTab?
    /// The tab the editor is scoped to.
    private(set) var active: EditorTab = .fullTake
    var dirty: Set<EditorTab> = []

    /// The row's tabs, leading to trailing.
    var open: [EditorTab] { clipTabs + [.fullTake] + (preview.map { [$0] } ?? []) }

    /// Only Full Take, active: a new project, or none.
    func reset() {
        update(clipTabs: [], preview: nil, active: .fullTake)
        if !dirty.isEmpty { dirty = [] }
    }

    /// Follows the project after any change to its clips or its scope. A tab whose clip
    /// is gone closes; a kept suggestion's tab becomes a clip tab (a kept preview joins
    /// the clip tabs) and a suggestion again after Undo; the scope's tab opens if it is
    /// not open, a suggestion as the preview. A scope whose clip is gone is Full Take.
    func sync(kept: [String], suggested: [String], active activeID: String?) {
        let keptIDs = Set(kept), suggestedIDs = Set(suggested)
        func current(_ tab: EditorTab) -> EditorTab? {
            guard let id = tab.clipID else { return .fullTake }
            return keptIDs.contains(id) ? .clip(id) : suggestedIDs.contains(id) ? .suggestion(id) : nil
        }
        var tabs: [EditorTab] = []
        for tab in clipTabs.compactMap(current) where !tabs.contains(tab) { tabs.append(tab) }
        var nextPreview = preview.flatMap(current)
        if let tab = nextPreview, case .clip = tab {
            if !tabs.contains(tab) { tabs.append(tab) }
            nextPreview = nil
        }
        if let tab = nextPreview, tabs.contains(tab) { nextPreview = nil }
        let target = activeID.flatMap { current(.clip($0)) } ?? .fullTake
        if target != .fullTake, !tabs.contains(target), target != nextPreview {
            if case .suggestion = target { nextPreview = target } else { tabs.append(target) }
        }
        update(clipTabs: tabs, preview: nextPreview, active: target)
        let marked = Set(dirty.compactMap(current)).intersection(open)
        if marked != dirty { dirty = marked }
    }

    /// The tab that a closing `tab` hands the scope to: the one before it, else the one after it.
    func neighbour(of tab: EditorTab) -> EditorTab {
        let tabs = open
        guard let index = tabs.firstIndex(of: tab) else { return active }
        if index > 0 { return tabs[index - 1] }
        return index + 1 < tabs.count ? tabs[index + 1] : .fullTake
    }
    /// The tab `offset` places from the active one, wrapping around (⌃Tab, ⌃⇧Tab).
    func adjacent(_ offset: Int) -> EditorTab {
        let tabs = open
        guard let index = tabs.firstIndex(of: active) else { return active }
        return tabs[((index + offset) % tabs.count + tabs.count) % tabs.count]
    }
    /// Takes `tab` out of the row without moving the scope; the shell moves it first when
    /// `tab` is active. Full Take stays.
    func remove(_ tab: EditorTab) {
        guard tab.closable else { return }
        if preview == tab { preview = nil }
        if clipTabs.contains(tab) { clipTabs.removeAll { $0 == tab } }
        if dirty.contains(tab) { dirty.remove(tab) }
    }
    /// A double-click keeps the preview tab open: it stops being the preview and joins
    /// the clip tabs, so the next preview opens beside it.
    func keepOpen(_ tab: EditorTab) {
        guard preview == tab else { return }
        preview = nil
        clipTabs.append(tab)
    }

    /// Assigns only what changed, so observers redraw only for a real change.
    private func update(clipTabs: [EditorTab], preview: EditorTab?, active: EditorTab) {
        if self.clipTabs != clipTabs { self.clipTabs = clipTabs }
        if self.preview != preview { self.preview = preview }
        if self.active != active { self.active = active }
    }
}

extension WorkspaceShell {
    /// The tabs follow the editor's clips and scope (`EditorModel.onClipsChange`, `onActiveClipChange`).
    func syncTabs() {
        guard let editor else { tabs.reset(); return }
        tabs.sync(kept: editor.keptClips.map(\.id), suggested: editor.suggestedClips.map(\.id), active: editor.project.edits.activeClipId)
        closeRewriteWithoutTab()
    }
    /// An open Rewrite session closes with its tab, as Escape closes it: ×, a middle click,
    /// ⌘W, Close Tab, or a preview tab that the next preview replaces. Left open, it would
    /// wait unseen with no dot and come back with its words when its clip opened again.
    private func closeRewriteWithoutTab() {
        guard let editor, let id = editor.openRewrite?.project.edits.activeClipId,
              !tabs.open.contains(where: { $0.clipID == id }) else { return }
        editor.closeRewrite(returnFocus: false)
    }
    /// The tab row shows: an editor shows, not Home.
    var tabsShown: Bool { editor != nil && !showsHome }
    /// The tabs that show the dirty dot: those whose hunks wait (`tabs.dirty`, set by V14),
    /// and the tab of an open Rewrite session whose new words differ from its words, on
    /// whichever tab is active (impl-plan §3.3).
    var dirtyTabs: Set<EditorTab> {
        var dirty = tabs.dirty
        if let session = editor?.openRewrite, session.isOpen, session.review?.diff.hunks.isEmpty == false,
           let tab = tabs.open.first(where: { $0.clipID == session.project.edits.activeClipId }) {
            dirty.insert(tab)
        }
        return dirty
    }
    /// ⌘W closes the active tab when it is a clip or a suggestion; on Full Take it stays
    /// Close Project (impl-plan item 5).
    var closesTab: Bool { tabsShown && tabs.active.closable }

    /// A click on a tab, ← and → on a focused tab, ⌃Tab and the tab overflow menu: scopes
    /// the editor to `tab` as an Explorer row does, with no undo step (`setScope`), and
    /// the Explorer's selection follows.
    func selectTab(_ tab: EditorTab) {
        guard let editor, tabsShown, tabs.open.contains(tab) else { return }
        if let id = tab.clipID {
            guard let clip = editor.project.edits.clips.first(where: { $0.id == id }) else { syncTabs(); return }
            editor.activate(clip)
        } else {
            editor.activate(nil)
        }
        syncTabs()
    }
    /// ×, a middle click and ⌘W. Closing the active tab scopes the editor to its neighbour.
    /// The tab's Rewrite session closes with it.
    func closeTab(_ tab: EditorTab) {
        guard tab.closable, tabsShown, tabs.open.contains(tab) else { return }
        guard tabs.active == tab else { tabs.remove(tab); closeRewriteWithoutTab(); return }
        let next = tabs.neighbour(of: tab)
        tabs.remove(tab)
        selectTab(next)
    }
    /// Show Next Tab and Show Previous Tab (⌃Tab, ⌃⇧Tab, ⇧⌘] and ⇧⌘[).
    func showAdjacentTab(_ offset: Int) {
        guard tabsShown, tabs.open.count > 1 else { return }
        selectTab(tabs.adjacent(offset))
    }
}

// MARK: - Views

/// A tab's sizes in points (notes.md `.tab`, measured on f1: "Clip 1" is 100 wide).
enum EditorTabMetrics {
    static let leading: CGFloat = 12
    static let icon: CGFloat = 14
    static let gap: CGFloat = 7
    static let slot: CGFloat = 16
    static let trailing: CGFloat = 10
    /// Everything but the name: 12 + 14 + 7 before it, 7 + 16 + 10 after it, and the 1 pt hairline.
    static let chrome: CGFloat = 67
    /// impl-plan §3.5: tabs shrink to 96 each, then the row scrolls.
    static let minimumWidth: CGFloat = 96
    static let overflowButton: CGFloat = 24
    /// The row's end the tabs never take, even shrunk or scrolling, so the title row can
    /// always move the window there (impl-plan V3a: drag area after the tabs).
    static let dragGap: CGFloat = 32
}

/// The tab row's tabs (impl-plan V3a): an AppKit tab group of tab buttons at their
/// natural widths, shrinking together toward 96 when the row is short and then scrolling,
/// with a chevron menu of every tab. Its empty space, and always the last 32 pt
/// (`EditorTabMetrics.dragGap`), falls through to the title row, which moves the window
/// and runs the double-click action.
@MainActor final class EditorTabBarView: NSView {
    private let shell: WorkspaceShell
    private let model: EditorModel
    private let strip = EditorTabStrip()
    /// Lists every tab while they overflow the row.
    let overflowButton = ShellIconButton(symbol: "chevron.down", size: 11, identifier: "voxclip.shell.tabOverflow")
    private(set) var items: [EditorTab: EditorTabItemView] = [:]
    /// The tabs as drawn, leading to trailing.
    private(set) var order: [EditorTab] = []
    /// The tabs are wider than the row, which scrolls.
    private(set) var overflowing = false
    /// How far the row is scrolled.
    private(set) var offset: CGFloat = 0
    private var renderedActive: EditorTab?
    private var revealsActive = true
    private var observation: ShellObservation?

    init(shell: WorkspaceShell, model: EditorModel) {
        self.shell = shell
        self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: ShellMetrics.titleRow))
        identifier = NSUserInterfaceItemIdentifier("voxclip.shell.tabs")
        strip.clipsToBounds = true
        addSubview(strip)
        overflowButton.describe("Show All Tabs")
        overflowButton.target = self
        overflowButton.action = #selector(showOverflowMenu(_:))
        overflowButton.isHidden = true
        addSubview(overflowButton)
        setAccessibilityElement(true)
        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel("Tabs")
        observation = ShellObservation { [weak self] in self?.render() }
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: ShellMetrics.titleRow) }
    func tearDown() { observation?.cancel() }
    /// A new width scrolls the active tab back into view.
    override func setFrameSize(_ newSize: NSSize) {
        if newSize.width != frame.width { revealsActive = true }
        super.setFrameSize(newSize)
    }

    /// The active tab's button.
    var activeItem: EditorTabItemView? { items[shell.tabs.active] }

    /// F6's stop for the tab and clip-bar rows: the active tab.
    @discardableResult func focusActiveTab() -> Bool {
        render()
        layoutSubtreeIfNeeded()
        return activeItem?.takeFocus() ?? false
    }

    /// The tab's name: "Full Take", "Clip {n}", or "Suggested clip {n}" (`scopeName`).
    func name(for tab: EditorTab) -> String { model.scopeName(tab.clipID) }

    /// Builds the buttons for the open tabs. Clip numbers follow the project, which only
    /// `projectRevision` makes observable.
    func render() {
        let tabs = shell.tabs
        _ = model.projectRevision
        let open = tabs.open, active = tabs.active, preview = tabs.preview, dirty = shell.dirtyTabs
        for (tab, item) in items where !open.contains(tab) {
            item.removeFromSuperview()
            items[tab] = nil
        }
        for tab in open {
            let item = items[tab] ?? makeItem(tab)
            item.configure(name: name(for: tab), active: tab == active, preview: tab == preview, dirty: dirty.contains(tab))
        }
        if renderedActive != active {
            renderedActive = active
            revealsActive = true
        }
        if order != open { order = open }
        setAccessibilityTabs(open.compactMap { items[$0] })
        needsLayout = true
    }

    private func makeItem(_ tab: EditorTab) -> EditorTabItemView {
        let item = EditorTabItemView(tab: tab)
        item.onSelect = { [weak self] tab in self?.shell.selectTab(tab) }
        item.onClose = { [weak self] tab in self?.shell.closeTab(tab) }
        item.onKeepOpen = { [weak self] tab in self?.shell.tabs.keepOpen(tab) }
        item.onStep = { [weak self] tab, step in self?.step(step, from: tab) }
        items[tab] = item
        strip.addSubview(item)
        return item
    }

    /// ← and → on a focused tab select the tab beside it, and focus moves with it.
    private func step(_ step: Int, from tab: EditorTab) {
        guard let index = order.firstIndex(of: tab), order.indices.contains(index + step) else { return }
        let target = order[index + step]
        shell.selectTab(target)
        render()
        layoutSubtreeIfNeeded()
        items[target]?.takeFocus()
    }

    /// Every tab at its natural width when they fit in `available`, the row less its drag
    /// gap (impl-plan §3.5). Otherwise the widest shrink together, never under 96; when
    /// even 96 each is too wide, each is at most 96 and the row scrolls.
    static func widths(_ naturals: [CGFloat], available: CGFloat) -> [CGFloat] {
        guard naturals.reduce(0, +) > available else { return naturals }
        let floor = EditorTabMetrics.minimumWidth
        let smallest = naturals.map { min($0, floor) }
        if smallest.reduce(0, +) >= available { return smallest }
        var rest = available, remaining = naturals.count
        for width in naturals.sorted() {
            guard width <= rest / CGFloat(remaining) else { break }
            rest -= width
            remaining -= 1
        }
        let cap = max(floor, (rest / CGFloat(max(remaining, 1))).rounded(.down))
        return naturals.map { min($0, cap) }
    }

    /// The room for the tabs and the chevron: all but the drag gap at the row's end.
    var tabRoom: CGFloat { max(0, bounds.width - EditorTabMetrics.dragGap) }

    override func layout() {
        super.layout()
        let room = tabRoom
        let widths = Self.widths(order.map { items[$0]?.naturalWidth ?? EditorTabMetrics.minimumWidth }, available: room)
        let content = widths.reduce(0, +)
        overflowing = content > room + 0.5
        let viewport = max(0, overflowing ? room - EditorTabMetrics.overflowButton - 4 : room)
        if revealsActive, let index = order.firstIndex(of: shell.tabs.active) {
            let start = widths[..<index].reduce(0, +), end = start + widths[index]
            if start < offset { offset = start } else if end > offset + viewport { offset = end - viewport }
            revealsActive = false
        }
        offset = min(max(0, offset), max(0, content - viewport))
        strip.frame = NSRect(x: 0, y: 0, width: viewport, height: bounds.height)
        var x = -offset
        for (tab, width) in zip(order, widths) {
            items[tab]?.frame = NSRect(x: x, y: 0, width: width, height: bounds.height)
            x += width
        }
        overflowButton.isHidden = !overflowing
        overflowButton.frame = NSRect(x: viewport + 2, y: ((bounds.height - EditorTabMetrics.overflowButton) / 2).rounded(), width: EditorTabMetrics.overflowButton, height: EditorTabMetrics.overflowButton)
    }

    /// The row scrolls sideways under a scroll gesture while its tabs overflow. No animation.
    override func scrollWheel(with event: NSEvent) {
        guard overflowing else { super.scrollWheel(with: event); return }
        let delta = abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
        offset -= delta * (event.hasPreciseScrollingDeltas ? 1 : 12)
        needsLayout = true
    }

    /// Space that is no tab or button belongs to the title row.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self || hit === strip ? nil : hit
    }

    /// The chevron's menu: every tab, the active one checked.
    func overflowMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (index, tab) in order.enumerated() {
            let item = NSMenuItem(title: name(for: tab), action: #selector(chooseFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = tab == shell.tabs.active ? .on : .off
            menu.addItem(item)
        }
        return menu
    }
    @objc private func showOverflowMenu(_ sender: NSButton) {
        overflowMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: sender.isFlipped ? sender.bounds.maxY + 4 : -4), in: sender)
    }
    @objc private func chooseFromMenu(_ item: NSMenuItem) {
        guard order.indices.contains(item.tag) else { return }
        shell.selectTab(order[item.tag])
    }
}

/// The scrolling strip that clips the tabs to the row.
@MainActor private final class EditorTabStrip: NSView {
    override var isFlipped: Bool { true }
}

/// One tab (notes.md `.tab`): the kind's icon, the name and a 16 pt slot, then a hairline.
/// The slot holds × on the active tab and on hover, else the dirty dot. The active tab is
/// the editor surface with a 1 pt text.tertiary line on top, and covers the row's bottom
/// hairline so it runs into the clip bar; the others show the chrome and the hairline.
/// A preview tab's name is italic. Clicks select it without moving the window, a
/// double-click keeps a preview open, and a middle click closes it. VoiceOver reads it as
/// a tab button in the tab group; F6 focuses it, and ← and → move to the next tab.
@MainActor final class EditorTabItemView: NSView {
    let tab: EditorTab
    private let icon = NSImageView()
    let label = NSTextField(labelWithString: "")
    let closeButton = EditorTabCloseButton()
    private(set) var name = ""
    private(set) var isActive = false
    private(set) var isPreview = false
    private(set) var isDirty = false
    private var configured = false
    private(set) var hovering = false { didSet { if hovering != oldValue { updateSlot() } } }
    var onSelect: (EditorTab) -> Void = { _ in }
    var onClose: (EditorTab) -> Void = { _ in }
    var onKeepOpen: (EditorTab) -> Void = { _ in }
    var onStep: (EditorTab, Int) -> Void = { _, _ in }

    init(tab: EditorTab) {
        self.tab = tab
        super.init(frame: NSRect(x: 0, y: 0, width: EditorTabMetrics.minimumWidth, height: ShellMetrics.titleRow))
        identifier = NSUserInterfaceItemIdentifier(Self.identifier(for: tab))
        icon.imageScaling = .scaleNone
        icon.image = NSImage(systemSymbolName: Self.symbol(for: tab), accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        icon.setAccessibilityElement(false)
        label.lineBreakMode = .byTruncatingTail
        label.setAccessibilityElement(false)
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        addSubview(icon)
        addSubview(label)
        addSubview(closeButton)
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        setAccessibilitySubrole(.tabButtonSubrole)
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }

    static func identifier(for tab: EditorTab) -> String {
        switch tab {
        case .fullTake: "voxclip.shell.tab.fullTake"
        case .clip(let id): "voxclip.shell.tab.clip.\(id)"
        case .suggestion(let id): "voxclip.shell.tab.suggestion.\(id)"
        }
    }
    /// f1's glyphs: a film strip for the take, a play rectangle for a clip, a dashed one for a suggestion.
    static func symbol(for tab: EditorTab) -> String {
        switch tab {
        case .fullTake: "film"
        case .clip: "play.rectangle"
        case .suggestion: "rectangle.dashed"
        }
    }

    func configure(name: String, active: Bool, preview: Bool, dirty: Bool) {
        guard !configured || name != self.name || active != isActive || preview != isPreview || dirty != isDirty else { return }
        configured = true
        self.name = name
        isActive = active
        isPreview = preview
        isDirty = dirty
        let body = VCType.body.nsFont()
        label.font = preview ? NSFontManager.shared.convert(body, toHaveTrait: .italicFontMask) : body
        label.stringValue = name
        label.textColor = DesignValues.nsColor(active ? "text.primary" : "text.tertiary")
        icon.contentTintColor = DesignValues.nsColor(active ? "text.secondary" : "text.disabled")
        setAccessibilityLabel(name)
        setAccessibilityValue(NSNumber(value: active ? 1 : 0))
        // VoiceOver reads "Clip 1, selected, tab, 1 of 3", then this.
        let notes = [preview ? "Preview" : nil, dirty ? "Has unreviewed changes" : nil].compactMap { $0 }
        setAccessibilityHelp(notes.isEmpty ? nil : notes.joined(separator: ", "))
        closeButton.setAccessibilityLabel("Close \(name)")
        closeButton.toolTip = "Close \(name)"
        setAccessibilityCustomActions(tab.closable ? [NSAccessibilityCustomAction(name: "Close Tab", target: self, selector: #selector(closeAction))] : nil)
        updateSlot()
        needsLayout = true
    }

    /// The name in full plus the tab's 67 pt of chrome.
    var naturalWidth: CGFloat {
        let font = label.font ?? VCType.body.nsFont()
        return (EditorTabMetrics.chrome + ceil((name as NSString).size(withAttributes: [.font: font]).width)).rounded(.up)
    }
    /// × shows on the active tab and on hover; the dirty dot holds the slot otherwise. Full
    /// Take has no ×.
    var showsClose: Bool { tab.closable && (hovering || (isActive && !isDirty)) }
    var showsDot: Bool { isDirty && !showsClose }
    private func updateSlot() {
        closeButton.isHidden = !showsClose
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let height = bounds.height
        icon.frame = NSRect(x: EditorTabMetrics.leading, y: ((height - EditorTabMetrics.icon) / 2).rounded(), width: EditorTabMetrics.icon, height: EditorTabMetrics.icon)
        let nameX = EditorTabMetrics.leading + EditorTabMetrics.icon + EditorTabMetrics.gap
        let slotX = max(nameX, bounds.width - 1 - EditorTabMetrics.trailing - EditorTabMetrics.slot)
        closeButton.frame = NSRect(x: slotX, y: ((height - EditorTabMetrics.slot) / 2).rounded(), width: EditorTabMetrics.slot, height: EditorTabMetrics.slot)
        // A label field draws its text 2 pt in from its frame.
        let text = label.intrinsicContentSize.height
        label.frame = NSRect(x: nameX - 2, y: ((height - text) / 2).rounded(), width: max(0, slotX - EditorTabMetrics.gap - nameX + 4), height: text)
    }

    override func draw(_ dirtyRect: NSRect) {
        if isActive {
            DesignValues.nsColor("bg.surface").setFill()
            bounds.fill()
            DesignValues.nsColor("text.tertiary").setFill()
            NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        }
        DesignValues.nsColor("line.default").setFill()
        NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height).fill()
        if showsDot {
            DesignValues.nsColor("text.secondary").setFill()
            let slot = closeButton.frame
            NSBezierPath(ovalIn: NSRect(x: slot.midX - 3.5, y: slot.midY - 3.5, width: 7, height: 7)).fill()
        }
    }

    // MARK: Mouse

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2, isPreview { onKeepOpen(tab); return }
        onSelect(tab)
    }
    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber != 2 { super.otherMouseDown(with: event) }
    }
    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else { super.otherMouseUp(with: event); return }
        if tab.closable { onClose(tab) }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    @objc private func closeClicked() { onClose(tab) }
    @objc private func closeAction() -> Bool {
        onClose(tab)
        return true
    }

    // MARK: Keyboard and VoiceOver

    /// Only F6 gives a tab keyboard focus (`takeFocus`); a click selects it and leaves focus where it was.
    @discardableResult func takeFocus() -> Bool {
        focusRequested = true
        defer { focusRequested = false }
        return window?.makeFirstResponder(self) ?? false
    }
    private var focusRequested = false
    override var acceptsFirstResponder: Bool { focusRequested || window?.firstResponder === self }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { bounds.insetBy(dx: 2, dy: 3).fill() }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: onStep(tab, -1)
        case 124: onStep(tab, 1)
        case 36, 49, 76: onSelect(tab)
        default: super.keyDown(with: event)
        }
    }
    override func accessibilityPerformPress() -> Bool {
        onSelect(tab)
        return true
    }
}

/// A tab's × (notes.md `.tab .x`): 16 × 16, an 11 pt box, text.tertiary, with the
/// selected-row fill and radius 4 under the pointer.
@MainActor final class EditorTabCloseButton: NSButton {
    private var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }
    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: EditorTabMetrics.slot, height: EditorTabMetrics.slot))
        isBordered = false
        setButtonType(.momentaryPushIn)
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        title = ""
        image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 9, weight: .medium))
        contentTintColor = DesignValues.nsColor("text.tertiary")
        refusesFirstResponder = true
    }
    required init?(coder: NSCoder) { nil }
    override var intrinsicContentSize: NSSize { NSSize(width: EditorTabMetrics.slot, height: EditorTabMetrics.slot) }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func draw(_ dirtyRect: NSRect) {
        if hovering || isHighlighted {
            DesignValues.nsColor("bg.selectedRow").setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        }
        super.draw(dirtyRect)
    }
}
