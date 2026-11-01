#if DEBUG
import AppKit
import SwiftUI
import VoxClipCore

/// The editor's tabs (impl-plan V3a) on the "Five questions" fixture, in an offscreen
/// `MainWindow` at 1280 × 800: open, pin and close; the preview tab and its replacement;
/// a double-click keeping it open; × and a middle click; ⌘W, ⌃Tab and the Window menu;
/// tab switches that add no undo step and leave the document clean; Undo that keeps the
/// tab; the open clip's removal falling back to Full Take; a Rewrite session surviving a
/// tab switch and edits outside its clip, and closing with its tab; a Versions window;
/// the tab metrics against f1, the shrink to 96 and the overflow chevron, with the drag
/// gap after them; the active tab covering the row's hairline; and VoiceOver's tab group.
/// Captures `v2-tabs-*` offscreen; `sceneCaptures` takes the real-window `v2-tabs-1280.png`.
@MainActor enum DebugTabs {
    struct Frame: Codable { let tab: String; let frame: CGRect }
    /// The harness windows' controllers, which their windows do not retain, until `run` ends.
    private static var windowControllers: [NSWindowController] = []

    static func run(app: AppModel, fixture: Project, directory: URL) async throws -> [DebugUISuite.Result] {
        var results: [DebugUISuite.Result] = []
        func check(_ name: String, _ passed: Bool) { results.append(.init(name: name, passed: passed)) }
        defer { windowControllers = [] }
        // Fresh layout defaults, and Voice Lab on so a Rewrite session can be current; in memory only.
        let previousSettings = app.settings
        defer { app.settings = previousSettings }
        for key in [WorkspaceLayout.explorerWidthKey, WorkspaceLayout.rightWidthKey, WorkspaceLayout.timelineHeightKey] { app.settings.values[key] = nil }
        app.settings.values["voiceLab.enabled"] = .bool(true)
        app.settings.values["voiceLab.betaNoticeAccepted"] = .bool(true)

        let shell = WorkspaceShell(app: app)
        let document = VoxClipDocument(project: try DebugExplorer.fiveQuestions(from: fixture), demo: true)
        await shell.attachForTesting(document, selection: .fullTake)
        guard let editor = shell.editor else { throw CocoaError(.coderInvalidValue) }
        defer { editor.close() }
        editor.mediaResolved = true; editor.refresh()
        // One explicit undo group per user action, so "no undo step" means none.
        let undo = UndoManager()
        undo.groupsByEvent = false
        editor.undoManager = undo
        func step(_ action: () -> Void) { undo.beginUndoGrouping(); action(); undo.endUndoGrouping() }
        let kept = editor.keptClips.map(\.id), suggested = editor.suggestedClips.map(\.id)
        guard kept.count == 4, suggested.count == 1 else { throw CocoaError(.coderInvalidValue) }

        let window = makeWindow(app: app, shell: shell)
        guard let root = window.contentView else { throw CocoaError(.coderInvalidValue) }
        root.layoutSubtreeIfNeeded()
        guard let bar = DebugShell.firstView(EditorTabBarView.self, in: root) else {
            window.close()
            check("the tab row holds the editor's tab bar", false)
            return results
        }
        func settle() {
            bar.render()
            root.layoutSubtreeIfNeeded()
        }
        func frame(_ tab: EditorTab) -> CGRect? {
            guard let item = bar.items[tab] else { return nil }
            let rect = item.convert(item.bounds, to: nil)
            return CGRect(x: rect.minX, y: root.bounds.height - rect.maxY, width: rect.width, height: rect.height)
        }

        // Open and pin: Full Take alone, pinned; clip tabs open before it (f1).
        settle()
        check("a project opens with Full Take as its one tab, active and pinned with no ×",
              shell.tabs.open == [.fullTake] && shell.tabs.active == .fullTake && bar.items[.fullTake]?.showsClose == false && bar.items[.fullTake]?.closeButton.isHidden == true)
        let steps = editor.undoSteps
        shell.selection = .clip(kept[0])
        shell.selection = .clip(kept[1])
        settle()
        check("Explorer rows open Clip 1 and Clip 2 before Full Take, Clip 2 active (\(shell.tabs.open))",
              shell.tabs.open == [.clip(kept[0]), .clip(kept[1]), .fullTake] && shell.tabs.active == .clip(kept[1]) && editor.project.edits.activeClipId == kept[1])
        check("the tabs read Clip 1, Clip 2 and Full Take", bar.order.map(bar.name(for:)) == ["Clip 1", "Clip 2", "Full Take"])
        check("tab switches add no undo step and leave the document neither edited nor with unautosaved changes",
              editor.undoSteps == steps && !undo.canUndo && !document.isDocumentEdited && !document.hasUnautosavedChanges)
        // f1: "Clip 1" 100 wide from the tab row's start, "Full Take" about 120; text.tertiary names, the active one text.primary.
        let frames = bar.order.compactMap { tab in frame(tab).map { Frame(tab: bar.name(for: tab), frame: $0) } }
        try JSONEncoder().encode(frames).write(to: directory.appendingPathComponent("v2-tabs-1280-frames.json"), options: .atomic)
        if let first = frame(.clip(kept[0])), let full = frame(.fullTake) {
            check("Clip 1's tab starts at the tab row's start, 38 high and about 100 wide as in f1 (\(first))",
                  abs(first.minX - 224) <= 1 && first.minY == 0 && first.height == ShellMetrics.titleRow && abs(first.width - 100) <= 4)
            check("Full Take's tab is about 120 wide as in f1 (\(full))", abs(full.width - 120) <= 5)
        } else { check("the open tabs have frames", false) }
        check("the active tab shows × and the inactive ones show none", bar.items[.clip(kept[1])]?.showsClose == true && bar.items[.clip(kept[0])]?.showsClose == false)
        results += hairlineChecks(bar: bar, active: .clip(kept[1]), inactive: .clip(kept[0]))

        // The preview tab: a suggestion opens after Full Take in italics, and the next preview replaces it.
        shell.selection = .clip(suggested[0])
        settle()
        let previewItem = bar.items[.suggestion(suggested[0])]
        check("a suggestion opens as the preview tab after Full Take (\(shell.tabs.open))",
              shell.tabs.open.last == .suggestion(suggested[0]) && shell.tabs.preview == .suggestion(suggested[0]) && shell.tabs.active == .suggestion(suggested[0]))
        check("the preview tab's name is italic and reads Suggested clip 5",
              previewItem?.label.font.map { NSFontManager.shared.traits(of: $0).contains(.italicFontMask) } == true && previewItem?.name == "Suggested clip 5")
        var second = editor.project
        if var extra = second.edits.clips.first(where: { $0.id == suggested[0] }) {
            extra.id = "tabs-suggestion"
            extra.startWordId = second.edits.clips[0].startWordId
            extra.endWordId = second.edits.clips[0].endWordId
            second.edits.clips.append(extra)
        }
        step { editor.replace(second, name: "Add suggestion fixture") }
        // The fixture edit is set-up, not under test: the document starts clean again, so
        // the close checks below see only what closing tabs does to it.
        document.updateChangeCount(.changeCleared)
        shell.selection = .clip("tabs-suggestion")
        settle()
        check("the next preview replaces the first (\(shell.tabs.open))",
              shell.tabs.preview == .suggestion("tabs-suggestion") && !shell.tabs.open.contains(.suggestion(suggested[0])) && shell.tabs.open.count == 4)
        if let item = bar.items[.suggestion("tabs-suggestion")], let event = mouse(.leftMouseDown, clicks: 2, in: window) {
            item.mouseDown(with: event)
        }
        settle()
        check("a double-click keeps the preview open as a clip tab before Full Take (\(shell.tabs.open))",
              shell.tabs.preview == nil && shell.tabs.open == [.clip(kept[0]), .clip(kept[1]), .suggestion("tabs-suggestion"), .fullTake])
        // Close: a middle click on an inactive tab, × on the active one, which hands the scope to its neighbour.
        if let item = bar.items[.clip(kept[0])], let event = CGEvent(mouseEventSource: nil, mouseType: .otherMouseUp, mouseCursorPosition: .zero, mouseButton: .center).flatMap(NSEvent.init(cgEvent:)) {
            item.otherMouseUp(with: event)
        }
        settle()
        check("a middle click closes an inactive tab and leaves the scope (\(shell.tabs.open))",
              !shell.tabs.open.contains(.clip(kept[0])) && shell.tabs.active == .suggestion("tabs-suggestion"))
        bar.items[.suggestion("tabs-suggestion")]?.closeButton.performClick(nil)
        settle()
        check("× on the active tab closes it and selects the tab before it (\(shell.tabs.active))",
              !shell.tabs.open.contains(.suggestion("tabs-suggestion")) && shell.tabs.active == .clip(kept[1]) && shell.selection == .clip(kept[1]) && editor.project.edits.activeClipId == kept[1])
        check("closing tabs adds no undo step and leaves the document clean",
              editor.undoSteps == steps + 1 && !document.isDocumentEdited && !document.hasUnautosavedChanges)

        // ⌘W (impl-plan item 5), the Window menu and ⌃Tab, in this window.
        results += try commandChecks(window: window, shell: shell, kept: kept)

        // Undo keeps the tab; Undo that removes the open clip falls back to Full Take.
        shell.selectTab(.clip(kept[1]))
        let clip2 = editor.project.edits.clips.first { $0.id == kept[1] }
        if let clip2, let first = editor.index(clip2.startWordId) {
            step { editor.apply(.cutSelection(ids: [editor.words[first].id]), name: "Cut selection") }
            shell.selectTab(.fullTake)
            undo.undo()
            check("Undo after a tab switch undoes the edit and keeps the tab", !editor.cutWordIDs.contains(editor.words[first].id) && shell.tabs.active == .fullTake && editor.project.edits.activeClipId == nil)
            undo.redo()
            check("Redo keeps the tab too", editor.cutWordIDs.contains(editor.words[first].id) && shell.tabs.active == .fullTake)
            undo.undo()
        } else { check("Clip 2 is in the fixture", false) }
        let words = editor.words
        if let start = words.firstIndex(where: { $0.text == "One" }), start + 3 < words.count {
            editor.select(words[start].id); editor.select(words[start + 3].id, extend: true)
            step { editor.makeClip() }
            let made = editor.project.edits.activeClipId
            check("Make Clip opens the new clip's tab", made.map { shell.tabs.active == .clip($0) } == true)
            undo.undo()
            check("Undo of Make Clip closes its tab and falls back to Full Take", shell.tabs.active == .fullTake && shell.tabs.open.allSatisfy { $0.clipID != made } && editor.project.edits.activeClipId == nil)
        } else { check("the fixture has the words for a new clip", false) }
        // The last Explorer row is the suggestion at the take's end: dismissing it while it is open leaves no row after it.
        shell.selection = .clip(suggested[0])
        step { editor.dismiss(suggested[0]) }
        check("Dismiss on the last row closes its tab and falls back to Full Take", shell.tabs.active == .fullTake && !shell.tabs.open.contains(.suggestion(suggested[0])))
        undo.undo()

        results += rewriteChecks(window: window, bar: bar, editor: editor, shell: shell, kept: kept, undo: undo)
        results += try await narrowChecks(window: window, shell: shell, bar: bar, kept: kept, suggested: suggested)

        // VoiceOver: a tab group of tab buttons, the active one selected; a dirty tab says so.
        shell.selectTab(.clip(kept[1]))
        shell.tabs.dirty = [.clip(kept[1])]
        settle()
        let active = bar.items[.clip(kept[1])]
        check("VoiceOver reads the tabs as a tab group of tab buttons, the active one selected",
              bar.accessibilityRole() == .tabGroup && bar.order.allSatisfy { bar.items[$0]?.accessibilityRole() == .radioButton && bar.items[$0]?.accessibilitySubrole() == .tabButtonSubrole }
              && (active?.accessibilityValue() as? NSNumber)?.intValue == 1 && (bar.accessibilityTabs()?.count ?? 0) == bar.order.count)
        check("a tab with unreviewed changes shows the dot in place of × and tells VoiceOver",
              active?.showsDot == true && active?.showsClose == false && active?.accessibilityHelp() == "Has unreviewed changes")
        window.close()
        try await DebugUISuite.snapshot(WorkspaceView(shell: shell).environment(app), name: "v2-tabs-dirty-dark", size: NSSize(width: 1280, height: 800), appearance: .darkAqua, directory: directory, active: true, mainWindow: true)
        shell.tabs.dirty = []
        shell.selection = .clip(suggested[0])
        try await DebugUISuite.snapshot(WorkspaceView(shell: shell).environment(app), name: "v2-tabs-preview-dark", size: NSSize(width: 1280, height: 800), appearance: .darkAqua, directory: directory, active: true, mainWindow: true)
        results += try await versionChecks(fixture: fixture)
        return results
    }

    /// An offscreen window like the main window, showing `shell`, whose controller is the
    /// shell's so ⌃Tab, F6 and Escape take the window's own path.
    private static func makeWindow(app: AppModel, shell: WorkspaceShell) -> MainWindow {
        let size = NSSize(width: 1280, height: 800)
        let window = MainWindow(contentRect: NSRect(origin: NSPoint(x: -10000, y: -10000), size: size), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        windowControllers.append(DebugShellWindowController(window: window, shell: shell))
        window.appearance = NSAppearance(named: .darkAqua)
        EditorShellController.prepare(window)
        let host = NSHostingController(rootView: WorkspaceView(shell: shell).environment(app).sceneAccent())
        host.sizingOptions = []
        host.sceneBridgingOptions = []
        window.contentViewController = host
        window.setContentSize(size)
        shell.windowWidth = size.width
        window.orderBack(nil)
        return window
    }

    private static func mouse(_ type: NSEvent.EventType, clicks: Int, in window: NSWindow) -> NSEvent? {
        NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)
    }

    /// The active tab is the editor surface down to the row's last line, covering its
    /// hairline; an inactive tab leaves the chrome and the hairline (f1).
    private static func hairlineChecks(bar: EditorTabBarView, active: EditorTab, inactive: EditorTab) -> [DebugUISuite.Result] {
        guard let row = bar.superview, let window = bar.window, let on = bar.items[active], let off = bar.items[inactive],
              let rep = row.bitmapImageRepForCachingDisplay(in: row.bounds) else { return [.init(name: "the tab row draws", passed: false)] }
        row.cacheDisplay(in: row.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / max(1, row.bounds.width)
        // 4 pt into the tab: clear of its icon, name and hairline.
        func sample(_ item: NSView, y: CGFloat) -> NSColor? {
            let point = item.convert(NSPoint(x: item.bounds.minX + 4, y: 0), to: row)
            return rep.colorAt(x: Int(point.x * scale), y: Int(y * scale))?.usingColorSpace(.sRGB)
        }
        func token(_ name: String) -> NSColor? {
            var color: NSColor?
            window.effectiveAppearance.performAsCurrentDrawingAppearance { color = DesignValues.nsColor(name).usingColorSpace(.sRGB) }
            return color
        }
        func same(_ a: NSColor?, _ b: NSColor?) -> Bool {
            guard let a, let b else { return false }
            return abs(a.redComponent - b.redComponent) < 0.02 && abs(a.greenComponent - b.greenComponent) < 0.02 && abs(a.blueComponent - b.blueComponent) < 0.02
        }
        let last = ShellMetrics.titleRow - 0.5
        return [
            .init(name: "the active tab runs into the clip bar: its last line is bg.surface", passed: same(sample(on, y: last), token("bg.surface"))),
            .init(name: "the active tab has a text.tertiary line on top", passed: same(sample(on, y: 0.5), token("text.tertiary"))),
            .init(name: "an inactive tab shows the row's line.default hairline under it", passed: same(sample(off, y: last), token("line.default"))),
            .init(name: "an inactive tab shows the chrome", passed: same(sample(off, y: 19), token("bg.window")))
        ]
    }

    /// ⌘W closes a clip tab and is Close Project's place on Full Take; Show Next Tab and
    /// Show Previous Tab in the Window menu, and ⌃Tab and ⌃⇧Tab sent to the window.
    private static func commandChecks(window: MainWindow, shell: WorkspaceShell, kept: [String]) throws -> [DebugUISuite.Result] {
        var results: [DebugUISuite.Result] = []
        func check(_ name: String, _ passed: Bool) { results.append(.init(name: name, passed: passed)) }
        guard let delegate = NSApp.delegate as? AppDelegate else { return [.init(name: "the app delegate runs the menus", passed: false)] }
        delegate.commandWindowForTesting = window
        defer { delegate.commandWindowForTesting = nil }
        let file = NSApp.mainMenu?.item(withTitle: "File")?.submenu
        let windowMenu = NSApp.mainMenu?.item(withTitle: "Window")?.submenu
        guard let close = file?.items.first(where: { $0.keyEquivalent == "w" && $0.keyEquivalentModifierMask == .command }),
              let next = windowMenu?.items.first(where: { $0.title == "Show Next Tab" && !$0.isHidden }),
              let previous = windowMenu?.items.first(where: { $0.title == "Show Previous Tab" && !$0.isHidden }) else {
            return [.init(name: "the File menu has ⌘W and the Window menu Show Next Tab and Show Previous Tab", passed: false)]
        }
        check("Show Next Tab is ⌃⇥ and Show Previous Tab ⌃⇧⇥, with ⇧⌘] and ⇧⌘[ as hidden alternates",
              next.keyEquivalent == "\t" && next.keyEquivalentModifierMask == .control && previous.keyEquivalent == "\t" && previous.keyEquivalentModifierMask == [.control, .shift]
              && windowMenu?.items.contains { $0.isHidden && $0.keyEquivalent == "]" && $0.keyEquivalentModifierMask == [.command, .shift] && $0.allowsKeyEquivalentWhenHidden && $0.tag == next.tag } == true
              && windowMenu?.items.contains { $0.isHidden && $0.keyEquivalent == "[" && $0.keyEquivalentModifierMask == [.command, .shift] && $0.allowsKeyEquivalentWhenHidden && $0.tag == previous.tag } == true)
        shell.selection = .clip(kept[0])
        shell.selection = .clip(kept[1])
        _ = delegate.validateMenuItem(close)
        check("on a clip tab ⌘W reads Close Tab (\(close.title))", close.title == "Close Tab")
        if let action = close.action { _ = delegate.perform(action, with: close) }
        check("⌘W closes the clip tab and keeps the project open", !shell.tabs.open.contains(.clip(kept[1])) && shell.tabs.active == .clip(kept[0]) && shell.editor != nil)
        shell.selectTab(.fullTake)
        _ = delegate.validateMenuItem(close)
        check("on Full Take ⌘W is not Close Tab, so it stays Close Project in the main window (\(close.title))", close.title != "Close Tab" && !shell.closesTab)
        shell.selection = .clip(kept[1])
        // [Clip 1, Clip 2, Full Take], Clip 2 active.
        check("Show Next Tab is on with more than one tab", delegate.validateMenuItem(next))
        if let action = next.action { _ = delegate.perform(action, with: next) }
        check("Show Next Tab selects the next tab", shell.tabs.active == .fullTake)
        if let action = next.action { _ = delegate.perform(action, with: next) }
        check("Show Next Tab wraps to the first tab", shell.tabs.active == .clip(kept[0]))
        if let action = previous.action { _ = delegate.perform(action, with: previous) }
        check("Show Previous Tab wraps back to the last tab", shell.tabs.active == .fullTake)
        func controlTab(shift: Bool) {
            let tab = "\t"
            if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: shift ? [.control, .shift] : [.control], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, characters: tab, charactersIgnoringModifiers: tab, isARepeat: false, keyCode: 48) {
                window.sendEvent(event)
            }
        }
        controlTab(shift: true)
        check("⌃⇧Tab in the window selects the previous tab", shell.tabs.active == .clip(kept[1]))
        controlTab(shift: false)
        check("⌃Tab in the window selects the next tab", shell.tabs.active == .fullTake)
        return results
    }

    /// A Rewrite session belongs to its tab (impl-plan §3.3): it survives a tab switch and
    /// edits outside its clip and stays current; on another tab the right column, the
    /// transcript's mark and Escape leave it alone, and its tab shows the dirty dot while its
    /// new words differ. Back on its tab it shows again; an edit inside its clip closes it.
    private static func rewriteChecks(window: NSWindow, bar: EditorTabBarView, editor: EditorModel, shell: WorkspaceShell, kept: [String], undo: UndoManager) -> [DebugUISuite.Result] {
        var results: [DebugUISuite.Result] = []
        func check(_ name: String, _ passed: Bool) { results.append(.init(name: name, passed: passed)) }
        func step(_ action: () -> Void) { undo.beginUndoGrouping(); action(); undo.endUndoGrouping() }
        let clips = editor.project.edits.clips
        guard let one = clips.first(where: { $0.id == kept[0] }), let two = clips.first(where: { $0.id == kept[1] }),
              let lower = editor.index(one.startWordId), let other = editor.index(two.startWordId) else { return [.init(name: "Clips 1 and 2 are in the fixture", passed: false)] }
        shell.selection = .clip(kept[0])
        let session = RewriteSession(editor: editor, range: lower...(lower + 2), envelope: nil, connector: nil)
        editor.rewrite = session
        editor.rewriteRange = lower...(lower + 2)
        session.edit("A different opening")
        bar.render()
        check("the session's tab shows the dirty dot while its new words differ", shell.dirtyTabs == [.clip(kept[0])] && bar.items[.clip(kept[0])]?.showsDot == true)
        shell.selectTab(.clip(kept[1]))
        bar.render()
        check("a Rewrite session survives a tab switch, hidden on the other tab with its words unmarked",
              session.isOpen && editor.openRewrite === session && editor.rewrite == nil && editor.rewriteRange == nil)
        check("on another tab the session stays current and its tab keeps the dot", session.current && bar.items[.clip(kept[0])]?.showsDot == true)
        // With no words selected the transcript's Escape leaves the clip (no selection bar to dismiss first).
        editor.selectedWordIDs = []
        editor.selectedPauseIDs = []
        let escape = String(UnicodeScalar(UInt8(27)))
        if focusTranscript(in: window), let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                                 context: nil, characters: escape, charactersIgnoringModifiers: escape, isARepeat: false, keyCode: 53) {
            window.sendEvent(key)
        }
        check("Escape in the transcript on another tab leaves its clip and the session open", session.isOpen && editor.openRewrite === session && shell.tabs.active == .fullTake)
        shell.selectTab(.clip(kept[1]))
        let outside = editor.words[other].id
        step { editor.apply(.cutSelection(ids: [outside]), name: "Cut selection") }
        check("an edit outside the session's clip leaves it open", session.isOpen && editor.openRewrite === session)
        shell.selectTab(.clip(kept[0]))
        check("back on its tab the session shows again, on the current project and still current",
              editor.rewrite === session && editor.rewriteRange == lower...(lower + 2) && session.project == editor.project && session.current)
        step { editor.apply(.cutSelection(ids: [editor.words[lower + 1].id]), name: "Cut selection") }
        bar.render()
        check("an edit inside the session's clip closes it (design.md R3) and the dot goes",
              !session.isOpen && editor.openRewrite == nil && editor.rewrite == nil && shell.dirtyTabs.isEmpty && bar.items[.clip(kept[0])]?.showsDot == false)
        undo.undo()
        undo.undo()
        // Closing the session's tab closes the session, as Escape does.
        shell.selection = .clip(kept[0])
        let closing = RewriteSession(editor: editor, range: lower...(lower + 2), envelope: nil, connector: nil)
        editor.rewrite = closing
        closing.edit("Another opening")
        shell.closeTab(.clip(kept[0]))
        shell.selection = .clip(kept[0])
        bar.render()
        check("closing the session's tab closes the session, and its clip opens again without it",
              !closing.isOpen && editor.openRewrite == nil && editor.rewrite == nil && shell.dirtyTabs.isEmpty && bar.items[.clip(kept[0])]?.showsDot == false)
        return results
    }

    /// At 1280 the tabs get what Show cuts and ⋯ leave of the 652 pt tab row, less the drag
    /// gap: 460, room for four at 96. Four shrink together, never under 96, with no chevron,
    /// and a fifth scrolls behind it. At 960 six overflow: each at most 96, the row scrolls
    /// to the active tab, and the chevron lists them all (impl-plan §3.5).
    private static func narrowChecks(window: NSWindow, shell: WorkspaceShell, bar: EditorTabBarView, kept: [String], suggested: [String]) async throws -> [DebugUISuite.Result] {
        var results: [DebugUISuite.Result] = []
        func check(_ name: String, _ passed: Bool) { results.append(.init(name: name, passed: passed)) }
        guard let root = window.contentView else { return results }
        guard let showCuts = DebugShell.firstView(ShowCutsToggle.self, in: root) else { return [.init(name: "the tab row holds Show cuts", passed: false)] }
        func settle() {
            bar.render()
            root.layoutSubtreeIfNeeded()
        }
        func ends() -> [CGFloat] { bar.overflowing ? [bar.overflowButton.frame.maxX] : bar.order.compactMap { bar.items[$0]?.frame.maxX } }
        // Clip 1, Clip 2, Full Take and the suggestion's preview tab ("Suggested clip 5").
        for tab in shell.tabs.open where tab != .fullTake { shell.closeTab(tab) }
        for id in [kept[0], kept[1], suggested[0]] { shell.selection = .clip(id) }
        settle()
        check("at 1280 Show cuts, with its label, and ⋯ end the tab row after the tab bar (bar \(Int(bar.frame.width)), Show cuts \(Int(showCuts.frame.minX))+\(Int(showCuts.frame.width)))",
              !showCuts.isHidden && !showCuts.compact && showCuts.superview === bar.superview && bar.frame.maxX <= showCuts.frame.minX)
        let naturals = bar.order.compactMap { bar.items[$0]?.naturalWidth }
        let widths = bar.order.compactMap { bar.items[$0]?.frame.width }
        check("at 1280 four tabs shrink to fit beside Show cuts, none under 96, with no chevron (\(naturals.map { Int($0) }) to \(widths.map { Int($0) }) in \(Int(bar.tabRoom)))",
              widths.count == 4 && naturals.reduce(0, +) > bar.tabRoom + 0.5 && widths.allSatisfy { $0 >= EditorTabMetrics.minimumWidth } && widths.reduce(0, +) <= bar.tabRoom + 0.5
              && !bar.overflowing && bar.overflowButton.isHidden && ends().allSatisfy { $0 <= bar.tabRoom + 0.5 })
        check("at 1280 the shrunk tabs leave the row's end to the title row, which moves the window (\(dragGapHit(bar, in: root).map { String(describing: type(of: $0)) } ?? "nothing"))",
              (dragGapHit(bar, in: root) as? ShellBand)?.movesWindow == true)
        shell.selection = .clip(kept[2])
        settle()
        check("at 1280 a fifth tab scrolls behind the chevron: the row has room for four at 96 (\(Int(bar.tabRoom)))",
              bar.order.count == 5 && Int(bar.tabRoom / EditorTabMetrics.minimumWidth) == 4 && bar.overflowing && !bar.overflowButton.isHidden && ends().allSatisfy { $0 <= bar.tabRoom + 0.5 })
        check("at 1280 the chevron leaves the row's end to the title row (\(dragGapHit(bar, in: root).map { String(describing: type(of: $0)) } ?? "nothing"))",
              (dragGapHit(bar, in: root) as? ShellBand)?.movesWindow == true)
        // Six tabs, the preview active, for the window minimum.
        for id in [kept[3], suggested[0]] { shell.selection = .clip(id) }
        window.setContentSize(NSSize(width: 960, height: 600))
        shell.windowWidth = 960
        // SwiftUI applies the narrow layout (the Explorer folds away) a pass or two later.
        for _ in 0..<40 {
            root.layoutSubtreeIfNeeded()
            if bar.overflowing && !shell.layout.explorerVisible && bar.window != nil { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        root.layoutSubtreeIfNeeded()
        let narrow = bar.order.compactMap { bar.items[$0]?.frame }
        let activeFrame = bar.items[shell.tabs.active]?.frame ?? .null
        check("at 960 the tabs overflow: each at most 96 and the chevron shows (\(narrow.map { Int($0.width) }), bar \(Int(bar.bounds.width)))",
              bar.overflowing && !bar.overflowButton.isHidden && narrow.allSatisfy { $0.width <= EditorTabMetrics.minimumWidth })
        check("the row scrolls to keep the active tab in view (\(activeFrame), strip \(Int(bar.overflowButton.frame.minX)))",
              activeFrame.minX >= -0.5 && activeFrame.maxX <= bar.overflowButton.frame.minX + 0.5)
        check("the chevron's menu lists every tab, the active one checked",
              bar.overflowMenu().items.map(\.title) == bar.order.map(bar.name(for:)) && bar.overflowMenu().items.filter { $0.state == .on }.map(\.title) == [bar.name(for: shell.tabs.active)])
        check("at 960 the row's end after the chevron still moves the window (\(dragGapHit(bar, in: root).map { String(describing: type(of: $0)) } ?? "nothing"))",
              (dragGapHit(bar, in: root) as? ShellBand)?.movesWindow == true && bar.overflowButton.frame.maxX <= bar.tabRoom + 0.5)
        window.setContentSize(NSSize(width: 1280, height: 800))
        shell.windowWidth = 1280
        for _ in 0..<40 where !shell.layout.explorerVisible || bar.overflowing {
            root.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(25))
        }
        return results
    }

    /// What a click 16 pt from the tab bar's end, the middle of its 32 pt drag gap,
    /// reaches, hit-tested from the window's content as AppKit does.
    private static func dragGapHit(_ bar: EditorTabBarView, in root: NSView) -> NSView? {
        guard let container = root.superview else { return nil }
        let point = bar.convert(NSPoint(x: bar.bounds.maxX - 16, y: bar.bounds.midY), to: nil)
        return root.hitTest(container.convert(point, from: nil))
    }

    /// A Versions window switches tabs and never writes them.
    private static func versionChecks(fixture: Project) async throws -> [DebugUISuite.Result] {
        let version = VoxClipDocument(project: try DebugExplorer.fiveQuestions(from: fixture), demo: true)
        version.versionForTesting = true
        version.makeWindowControllers()
        defer { version.close() }
        guard let controller = version.windowControllers.first as? VersionWindowController, let editor = controller.shell.editor,
              let clip = editor.keptClips.first else { return [.init(name: "a version opens in its own shell window", passed: false)] }
        controller.window?.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        let shell = controller.shell
        shell.selection = .clip(clip.id)
        shell.selectTab(.fullTake)
        shell.selectTab(.clip(clip.id))
        return [.init(name: "a Versions window switches tabs, read only, and never marks the version edited",
                      passed: shell.tabs.active == .clip(clip.id) && editor.project.edits.activeClipId == clip.id && !editor.capabilities.writable && !version.isDocumentEdited && !version.hasUnautosavedChanges)]
    }

    /// The real-window capture for side-by-side comparison with f1 (sceneAudit): Clip 1,
    /// Clip 2 and Full Take, Clip 1 active.
    static func sceneCaptures(app: AppModel, fixture: Project, directory: URL) async throws -> [DebugUISuite.Result] {
        guard !DebugUISuite.sessionLocked else { throw CocoaError(.userCancelled) }
        let shell = WorkspaceShell(app: app)
        await shell.attachForTesting(VoxClipDocument(project: try DebugExplorer.fiveQuestions(from: fixture), demo: true), selection: .fullTake)
        guard let editor = shell.editor else { throw CocoaError(.coderInvalidValue) }
        defer { editor.close() }
        editor.mediaResolved = true; editor.refresh()
        let kept = editor.keptClips.map(\.id)
        shell.windowWidth = 1280
        shell.selection = .clip(kept[1])
        shell.selection = .clip(kept[0])
        var frames: [Frame] = []
        try await DebugUISuite.snapshot(WorkspaceView(shell: shell).environment(app), name: "v2-tabs-1280", size: NSSize(width: 1280, height: 800), appearance: .darkAqua,
            directory: directory, active: true, mainWindow: true, native: true, beforeCapture: { window in
                guard let root = window.contentView else { return nil }
                root.layoutSubtreeIfNeeded()
                if let bar = DebugShell.firstView(EditorTabBarView.self, in: root) {
                    bar.render()
                    root.layoutSubtreeIfNeeded()
                    frames = bar.order.compactMap { tab in
                        bar.items[tab].map { item in
                            let rect = item.convert(item.bounds, to: nil)
                            return Frame(tab: bar.name(for: tab), frame: CGRect(x: rect.minX, y: root.bounds.height - rect.maxY, width: rect.width, height: rect.height))
                        }
                    }
                }
                return nil
            })
        try JSONEncoder().encode(frames).write(to: directory.appendingPathComponent("v2-tabs-1280-native-frames.json"), options: .atomic)
        return [.init(name: "native tabs: Clip 1, Clip 2 and Full Take from the tab row's start (\(frames.map { "\($0.tab) \(Int($0.frame.minX))+\(Int($0.frame.width))" }))",
                      passed: frames.map(\.tab) == ["Clip 1", "Clip 2", "Full Take"] && frames.first.map { abs($0.frame.minX - 224) <= 1 && abs($0.frame.width - 100) <= 4 } == true)]
    }
}
#endif
