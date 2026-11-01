import AppKit

/// A validated menu command. The item stays the source of its title, action and shortcut.
@MainActor struct CommandPaletteItem: Identifiable {
    let menuItem: NSMenuItem
    let path: String
    nonisolated let id: ObjectIdentifier
    init(menuItem: NSMenuItem, path: String) {
        self.menuItem = menuItem; self.path = path; id = ObjectIdentifier(menuItem)
    }
    var title: String { menuItem.title }
    var shortcut: String { MenuCommandIndex.shortcut(menuItem) }
}

/// Reads the current menu and validates through the responder chain. Indexing never sends an action.
@MainActor enum MenuCommandIndex {
    private(set) static var isInvoking = false
    /// Palette validation and dispatch are explicit menu choices, even during a Return key event.
    static func invoking<T>(_ body: () -> T) -> T {
        let previous = isInvoking; isInvoking = true
        defer { isInvoking = previous }
        return body()
    }
    static func enabled(_ item: NSMenuItem) -> Bool {
        guard !item.isHidden, !item.isSeparatorItem, item.submenu == nil, let action = item.action,
              let target = NSApp.target(forAction: action, to: item.target, from: item) else { return false }
        if let validator = target as? any NSMenuItemValidation { return invoking { validator.validateMenuItem(item) } }
        if let validator = target as? any NSUserInterfaceValidations { return invoking { validator.validateUserInterfaceItem(item) } }
        return item.isEnabled
    }
    static func items(in menu: NSMenu? = NSApp.mainMenu) -> [CommandPaletteItem] {
        guard let menu else { return [] }
        var result: [CommandPaletteItem] = []
        func walk(_ menu: NSMenu, path: [String]) {
            // Native submenus are lazy (for example, Open Recent and Voice Lab visibility).
            // Refresh their contents without opening them or sending a command.
            menu.delegate?.menuNeedsUpdate?(menu)
            for item in menu.items where !item.isHidden {
                if let submenu = item.submenu { walk(submenu, path: path + [item.title]) }
                else if enabled(item) { result.append(CommandPaletteItem(menuItem: item, path: path.joined(separator: " › "))) }
            }
        }
        walk(menu, path: [])
        return result
    }
    static func matching(_ query: String, in items: [CommandPaletteItem]) -> [CommandPaletteItem] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return items.filter { item in words.allSatisfy { (item.path + " " + item.title + " " + item.shortcut).localizedStandardContains($0) } }
    }
    @discardableResult static func run(_ item: CommandPaletteItem) -> Bool {
        guard enabled(item.menuItem), let action = item.menuItem.action else { return false }
        return invoking { NSApp.sendAction(action, to: item.menuItem.target, from: item.menuItem) }
    }
    static func shortcut(_ item: NSMenuItem) -> String {
        guard !item.keyEquivalent.isEmpty else { return "" }
        let flags = item.keyEquivalentModifierMask
        let prefix = [(NSEvent.ModifierFlags.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
            .filter { flags.contains($0.0) }.map(\.1).joined()
        let names: [String: String] = ["\r": "↩", "\t": "Tab", " ": "Space", "\u{7f}": "⌫", "\u{1b}": "Esc",
                     String(UnicodeScalar(NSUpArrowFunctionKey)!): "↑", String(UnicodeScalar(NSDownArrowFunctionKey)!): "↓"]
        return prefix + (names[item.keyEquivalent] ?? item.keyEquivalent.uppercased())
    }
}

/// A title-row launcher; the editable combo box and results live inside the shell.
@MainActor final class CommandPaletteLauncher: NSButton {
    var preferredWidth: CGFloat = 220
    init(shell: WorkspaceShell) {
        super.init(frame: .zero)
        title = ""
        isBordered = false
        setButtonType(.momentaryPushIn)
        setAccessibilityLabel("Search or run a command")
        toolTip = "Search or run a command (⌘K)"
        identifier = .init("voxclip.commands.launcher")
        target = self; action = #selector(open)
        self.shell = shell
    }
    private weak var shell: WorkspaceShell?
    required init?(coder: NSCoder) { nil }
    override var intrinsicContentSize: NSSize { NSSize(width: preferredWidth, height: 24) }
    @objc private func open() { shell?.openCommandPalette() }
    override func draw(_ dirtyRect: NSRect) {
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        DesignValues.nsColor(isHighlighted ? "bg.selectedRow" : "bg.input").setFill(); outline.fill()
        DesignValues.nsColor("line.edge").setStroke(); outline.lineWidth = 1; outline.stroke()
        let image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
        image?.draw(in: NSRect(x: 8, y: 6, width: 12, height: 12))
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [.font: VCType.callout.nsFont(), .foregroundColor: DesignValues.nsColor("text.secondary"), .paragraphStyle: paragraph]
        ("Search or run a command" as NSString).draw(in: NSRect(x: 27, y: 4, width: max(0, bounds.width - 63), height: 17), withAttributes: attributes)
        if bounds.width >= 64 {
            ("⌘K" as NSString).draw(in: NSRect(x: bounds.width - 29, y: 5, width: 24, height: 15), withAttributes: [.font: VCType.label.nsMono(), .foregroundColor: DesignValues.nsColor("text.secondary")])
        }
    }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill() }
    override var focusRingMaskBounds: NSRect { bounds }

}

/// A dropdown in the document's view tree, with native text editing and table navigation.
@MainActor final class CommandPaletteView: NSView, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    let field = NSTextField()
    let count = NSTextField(labelWithString: "")
    let table = CommandResultsTable()
    private let scroll = NSScrollView()
    private var commands: [CommandPaletteItem] = []
    private(set) var results: [CommandPaletteItem] = []
    private weak var previousResponder: NSResponder?
    var onClose: (() -> Void)?
    private var outsideMonitor: Any?
    private var announcement: DispatchWorkItem?
    private var isOpen = false
    var announce: (String) -> Void = { message in
        NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested, userInfo: [
            .announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue
        ])
    }
    override var isFlipped: Bool { true }
    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 500, height: 350))
        wantsLayer = true
        updateAppearance()
        layer?.borderWidth = 1; layer?.cornerRadius = 6
        shellGroup("Commands")
        identifier = .init("voxclip.commands")
        field.placeholderString = "Search or run a command"
        field.font = VCType.callout.nsFont()
        field.delegate = self
        field.setAccessibilityRole(.comboBox)
        field.setAccessibilityLabel("Search or run a command")
        field.setAccessibilityExpanded(true)
        field.setAccessibilityIdentifier("voxclip.commands.field")
        count.font = VCType.small.nsFont(); count.textColor = DesignValues.nsColor("text.tertiary")
        count.setAccessibilityIdentifier("voxclip.commands.count")
        let column = NSTableColumn(identifier: .init("command")); table.addTableColumn(column)
        table.headerView = nil; table.rowHeight = 28; table.intercellSpacing = .zero
        table.dataSource = self; table.delegate = self
        table.target = self; table.doubleAction = #selector(runSelection)
        table.run = { [weak self] in self?.runSelection() }
        table.close = { [weak self] in self?.close() }
        table.move = { [weak self] amount in self?.move(amount) }
        table.setAccessibilityLabel("Command results")
        field.setAccessibilityLinkedUIElements([table])
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        for view in [field, count, scroll] { addSubview(view) }
    }
    required init?(coder: NSCoder) { nil }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateAppearance() }
    private func updateAppearance() {
        layer?.backgroundColor = DesignValues.nsColor("bg.surface").cgColor
        layer?.borderColor = DesignValues.nsColor("line.strong").cgColor
    }
    func open() {
        if isOpen { focus(); return }
        isOpen = true
        outsideMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.dismissForOutsideMouseDown(event) }
            return event
        }
        // AppKit reuses a field editor between text fields. Restore its owning control,
        // otherwise the captured editor now belongs to this command field.
        if let editor = window?.firstResponder as? NSTextView, editor.isFieldEditor,
           let owner = editor.delegate as? NSResponder { previousResponder = owner }
        else { previousResponder = window?.firstResponder }
        commands = MenuCommandIndex.items()
        field.stringValue = ""; filter()
        field.setAccessibilityExpanded(true)
        focus()
    }
    func focus() { window?.makeFirstResponder(field) }
    func dismissForOutsideMouseDown(_ event: NSEvent) {
        dismissForMouseDown(at: event.locationInWindow, in: event.window)
    }
    func dismissForMouseDown(at point: NSPoint, in eventWindow: NSWindow?) {
        guard isOpen else { return }
        // Clicking the launcher is another request to focus this field; keep its query.
        if eventWindow === window, let content = window?.contentView {
            func onLauncher(_ view: NSView) -> Bool {
                if view is CommandPaletteLauncher, !view.isHiddenOrHasHiddenAncestor,
                   view.bounds.contains(view.convert(point, from: nil)) { return true }
                return view.subviews.contains(where: onLauncher)
            }
            if onLauncher(content) { return }
        }
        if eventWindow !== window || !bounds.contains(convert(point, from: nil)) { close(restoringFocus: false) }
    }
    private var ownsFocus: Bool {
        if let responder = window?.firstResponder as? NSView { return responder === self || responder.isDescendant(of: self) || responder === field.currentEditor() }
        return false
    }
    func controlTextDidEndEditing(_ notification: Notification) {
        Task { @MainActor [weak self] in
            guard let self, self.isOpen, !self.ownsFocus else { return }
            self.close(restoringFocus: false)
        }
    }
    func close(restoringFocus: Bool = true) {
        guard isOpen else { return }
        isOpen = false
        announcement?.cancel(); announcement = nil
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }; outsideMonitor = nil
        field.setAccessibilityExpanded(false)
        if restoringFocus, let previousResponder { window?.makeFirstResponder(previousResponder) }
        onClose?()
    }
    func controlTextDidChange(_ notification: Notification) { filter() }
    func filter() {
        results = MenuCommandIndex.matching(field.stringValue, in: commands)
        table.reloadData()
        if !results.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        count.stringValue = results.count == 1 ? "1 result" : "\(results.count) results"
        field.setAccessibilityHelp(count.stringValue + ". Use arrow keys to choose, Return to run, Escape to close.")
        NSAccessibility.post(element: count, notification: .valueChanged)
        announcement?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.announceResults() } }
        announcement = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }
    func announceResults() {
        announcement?.cancel(); announcement = nil
        guard isOpen else { return }
        announce(count.stringValue)
    }
    @objc func runSelection() {
        guard results.indices.contains(table.selectedRow) else { return }
        let command = results[table.selectedRow]
        close() // Restore the command's original responder before revalidation and dispatch.
        MenuCommandIndex.run(command)
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): runSelection(); return true
        case #selector(NSResponder.cancelOperation(_:)): close(); return true
        case #selector(NSResponder.moveDown(_:)): move(1); return true
        case #selector(NSResponder.moveUp(_:)): move(-1); return true
        default: return false
        }
    }
    private func move(_ amount: Int) {
        guard !results.isEmpty else { return }
        let next = max(0, min(results.count - 1, table.selectedRow + amount))
        table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false); table.scrollRowToVisible(next)
        NSAccessibility.post(element: table, notification: .selectedRowsChanged)
        let item = results[next]
        announce("\(item.path) › \(item.title)" + (item.shortcut.isEmpty ? "" : ", " + item.shortcut))
    }
    func numberOfRows(in tableView: NSTableView) -> Int { results.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = results[row]
        return CommandResultRow(name: "\(item.path) › \(item.title)", shortcut: item.shortcut)
    }
    override func layout() {
        super.layout()
        field.frame = NSRect(x: 10, y: 10, width: max(0, bounds.width - 20), height: 26)
        count.frame = NSRect(x: 12, y: 42, width: max(0, bounds.width - 24), height: 16)
        scroll.frame = NSRect(x: 6, y: 64, width: max(0, bounds.width - 12), height: max(0, bounds.height - 70))
        table.tableColumns.first?.width = max(0, scroll.contentSize.width)
    }
}

@MainActor final class CommandResultsTable: NSTableView {
    var run: (() -> Void)?
    var close: (() -> Void)?
    var move: ((Int) -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { run?() }
        else if event.keyCode == 53 { close?() }
        else if event.keyCode == 125 || event.keyCode == 126 { move?(event.keyCode == 125 ? 1 : -1) }
        else { super.keyDown(with: event) }
    }
}

@MainActor private final class CommandResultRow: NSTableCellView {
    let name: NSTextField
    let shortcut: NSTextField
    init(name: String, shortcut: String) {
        self.name = NSTextField(labelWithString: name)
        self.shortcut = NSTextField(labelWithString: shortcut)
        super.init(frame: .zero)
        self.name.font = VCType.callout.nsFont(); self.name.lineBreakMode = .byTruncatingTail
        self.shortcut.font = VCType.label.nsMono()
        addSubview(self.name); addSubview(self.shortcut)
        setAccessibilityElement(true); setAccessibilityRole(.staticText)
        setAccessibilityLabel(name + (shortcut.isEmpty ? "" : ", " + shortcut))
    }
    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout()
        let keyWidth = min(bounds.width, shortcut.intrinsicContentSize.width)
        shortcut.frame = NSRect(x: bounds.width - keyWidth - 6, y: 5, width: keyWidth, height: 18)
        name.frame = NSRect(x: 6, y: 5, width: max(0, bounds.width - keyWidth - 20), height: 18)
    }
}
