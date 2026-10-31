#if DEBUG
import AppKit
import SwiftUI
import VoxClipCore

/// The v2 shell (impl-plan V1a and V1b): the regions at 1280 × 800 with fresh defaults
/// against notes.md §1 and at 1440 × 900, 1128 × 800, 960 × 600 and 800 × 600 by the
/// narrow-size rule (§3.5), the Explorer and right-column overlays, the window chrome, what
/// the title rows' clicks reach, F6 and the VoiceOver groups, the Find Clips anchor at ⋯,
/// every editor state under the clip-bar row, a Versions window, and a saved pre-v2
/// right-column width being ignored. Captures `v2-shell-*` and `v2-state-*` offscreen;
/// `sceneCaptures` takes the real-window `v2-shell-1280.png` and `v2-shell-fullscreen.png`.
@MainActor enum DebugShell {
    struct Region: Codable { let region: String; let frame: CGRect; let reference: CGRect }

    static func run(app: AppModel, fixture: Project, directory: URL) async throws -> [DebugUISuite.Result] {
        var results: [DebugUISuite.Result] = []
        func check(_ name: String, _ passed: Bool) { results.append(.init(name: name, passed: passed)) }
        let keys = [WorkspaceLayout.explorerWidthKey, WorkspaceLayout.rightWidthKey, WorkspaceLayout.timelineHeightKey, WorkspaceLayout.retiredRightWidthKey, "llm.connector"]
        let saved = keys.map { app.settings.values[$0] }
        defer { for (key, value) in zip(keys, saved) { app.settings.values[key] = value } }
        for key in keys { app.settings.values[key] = nil }
        // A width saved by the pre-v2 layout must not reach the new right column.
        // Launch retires it (WorkspaceLayoutTests); here it is still in memory.
        app.settings.values[WorkspaceLayout.retiredRightWidthKey] = .number(500)

        let shell = WorkspaceShell(app: app)
        await shell.attachForTesting(VoxClipDocument(project: try DebugSidebar.fiveQuestions(from: fixture), demo: true), selection: .fullTake)
        guard let editor = shell.editor else { throw CocoaError(.coderInvalidValue) }
        defer { editor.close() }
        editor.mediaResolved = true; editor.refresh()
        check("a saved ui.rightColumnWidth is ignored: the right column starts at 404 at 1280", shell.rightWidth == 404 && WorkspaceShell(app: app).rightWidth == 404)
        results += try await windowChecks(app: app, shell: shell, editor: editor, directory: directory)
        results += try await sizeChecks(app: app, shell: shell, directory: directory)
        // One window at a time on the editor: the offscreen captures come after the checks' windows closed.
        for size in sizes {
            try await DebugUISuite.snapshot(WorkspaceView(shell: shell).environment(app), name: "v2-shell-\(Int(size.width))-dark", size: size, appearance: .darkAqua, directory: directory, active: true, mainWindow: true)
        }
        results += try await stateChecks(app: app, fixture: fixture, directory: directory)
        results += try await versionChecks(app: app, fixture: fixture)
        return results
    }

    /// notes.md §1's size, then the sizes of impl-plan §3.5 (800 × 600 stands in for full screen or Split View).
    static let sizes = [NSSize(width: 1280, height: 800), NSSize(width: 1440, height: 900), NSSize(width: 1128, height: 800), NSSize(width: 960, height: 600), NSSize(width: 800, height: 600)]

    /// An offscreen window like the main window, showing `shell`.
    private static func makeWindow(app: AppModel, shell: WorkspaceShell, size: NSSize = NSSize(width: 1280, height: 800)) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10000, y: -10000), size: size), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        EditorShellController.prepare(window)
        window.title = shell.title
        let host = NSHostingController(rootView: WorkspaceView(shell: shell).environment(app).sceneAccent())
        host.sizingOptions = []
        host.sceneBridgingOptions = []
        window.contentViewController = host
        window.setContentSize(size)
        window.orderBack(nil)
        return window
    }

    /// Lays `window` out until its regions are the rules' for `size`, for at most two
    /// seconds, records them in `v2-shell-{width}-regions.json` and checks each.
    private static func settleRegions(_ window: NSWindow, size: NSSize, directory: URL) async throws -> [DebugUISuite.Result] {
        guard let root = window.contentView else { throw CocoaError(.coderInvalidValue) }
        func settled(_ regions: [ShellRegion: CGRect]) -> Bool {
            ShellRegion.allCases.allSatisfy { region in region.reference(in: size).map { matches(regions[region], $0) } ?? (regions[region] == nil) }
        }
        var regions: [ShellRegion: CGRect] = [:]
        for _ in 0..<80 {
            root.layoutSubtreeIfNeeded()
            regions = Self.regions(in: window)
            if settled(regions) { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let evidence = ShellRegion.allCases.map { Region(region: $0.rawValue, frame: regions[$0] ?? .zero, reference: $0.reference(in: size) ?? .zero) }
        try JSONEncoder().encode(evidence).write(to: directory.appendingPathComponent("v2-shell-\(Int(size.width))-regions.json"), options: .atomic)
        return ShellRegion.allCases.map { region in
            let expected = region.reference(in: size)
            return .init(name: "at \(Int(size.width)) × \(Int(size.height)) the \(region.rawValue) region is \(expected.map(describe) ?? "collapsed") within 1 pt (\(regions[region].map(describe) ?? "missing"))",
                         passed: expected.map { matches(regions[region], $0) } ?? (regions[region] == nil))
        }
    }

    private static func windowChecks(app: AppModel, shell: WorkspaceShell, editor: EditorModel, directory: URL) async throws -> [DebugUISuite.Result] {
        var results: [DebugUISuite.Result] = []
        func check(_ name: String, _ passed: Bool) { results.append(.init(name: name, passed: passed)) }
        let window = makeWindow(app: app, shell: shell)
        defer { window.close() }
        guard let root = window.contentView else { throw CocoaError(.coderInvalidValue) }
        results += try await settleRegions(window, size: NSSize(width: 1280, height: 800), directory: directory)
        check("the window has no toolbar, a hidden title that is still set, and a transparent titlebar",
              window.toolbar == nil && window.titleVisibility == .hidden && window.titlebarAppearsTransparent && window.title == shell.title && !window.title.isEmpty)
        let content = view("voxclip.shell.content", in: root) as? NSSplitView
        let explorerController = content?.arrangedSubviews.first?.nextResponder as? NSViewController
        let splitController = content?.delegate as? NSSplitViewController
        let explorerItem = explorerController.flatMap { splitController?.splitViewItem(for: $0) }
        check("the Explorer is a plain split pane, not the floating sidebar", explorerItem?.behavior == .default)

        // What clicks in the title rows reach: their buttons, else the row, which moves the window.
        // AppKit hit-testing inside the shell; the titlebar's own forwarding is the real-window gate's.
        let shellRoot = view("voxclip.shell", in: root)
        func hit(_ point: CGPoint) -> NSView? {
            guard let shellRoot, let container = shellRoot.superview else { return nil }
            return shellRoot.hitTest(container.convert(NSPoint(x: point.x, y: root.bounds.height - point.y), from: nil))
        }
        func center(_ identifier: String) -> CGPoint? {
            guard let view = view(identifier, in: root) else { return nil }
            let rect = view.convert(view.bounds, to: nil)
            return CGPoint(x: rect.midX, y: root.bounds.height - rect.midY)
        }
        let more = center("voxclip.shell.more"), export = center("voxclip.shell.export"), toggle = center("voxclip.shell.toggleExplorer")
        check("a click on ⋯ reaches the ⋯ button", more.flatMap(hit)?.identifier?.rawValue == "voxclip.shell.more")
        check("a click on Export reaches the Export button", (export.flatMap(hit) as? ShellExportButton) != nil)
        check("a click on the Explorer toggle reaches it", toggle.flatMap(hit)?.identifier?.rawValue == "voxclip.shell.toggleExplorer")
        for (name, point) in [("the tab row beside its tab", CGPoint(x: 600, y: 19)), ("the scope tab", CGPoint(x: 260, y: 19)),
                              ("the right title row", CGPoint(x: 950, y: 19)), ("the Explorer's header", CGPoint(x: 120, y: 30))] {
            let band = hit(point) as? ShellBand
            check("a click on \(name) reaches a title row that moves the window (\(band?.identifier?.rawValue ?? hit(point).map { String(describing: type(of: $0)) } ?? "nothing"))", band?.movesWindow == true)
        }
        check("a click in the clip-bar row does not move the window", (hit(CGPoint(x: 600, y: 55)) as? ShellBand)?.movesWindow == false)

        // Find Clips from ⇧⌘K in the transcript and from ⋯ opens its popover at ⋯. The Clip
        // menu's Find Clips… (tag 34) is DebugMenus' check.
        func popoverShown() -> Bool { NSApp.windows.contains { $0.isVisible && String(describing: type(of: $0)).contains("Popover") } }
        let work = view("voxclip.shell.work", in: root)?.nextResponder as? EditorWorkController
        check("the work area is the editor's split controller", work != nil)
        let transcript = firstView(TranscriptNSTextView.self, in: root)
        check("the transcript text view is in the editor column", transcript != nil)
        if let transcript, let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: ProcessInfo.processInfo.systemUptime,
                                                      windowNumber: window.windowNumber, context: nil, characters: "K", charactersIgnoringModifiers: "K", isARepeat: false, keyCode: 40) {
            transcript.keyDown(with: key)
        }
        for _ in 0..<40 where !popoverShown() { try await Task.sleep(for: .milliseconds(25)) }
        check("⇧⌘K in the transcript opens Find Clips in its popover at ⋯", editor.showFindClips && editor.findClipsAnchor == .overflow && work?.findClipsPopover?.isShown == true && popoverShown())
        editor.showFindClips = false
        for _ in 0..<40 where work?.findClipsPopover?.isShown == true { try await Task.sleep(for: .milliseconds(25)) }
        check("closing Find Clips closes the popover", work?.findClipsPopover?.isShown != true)
        if let menu = work?.overflowMenu(), let index = menu.items.firstIndex(where: { $0.title == "Find Clips…" }) {
            check("⋯ lists the toolbar's commands and Find Clips…", menu.items.map(\.title).filter { !$0.isEmpty }.map { $0.hasPrefix("Cut Fillers") ? "Cut Fillers" : $0 } == ["Cut Fillers", "Tighten Pauses", "Restore Cuts", "Find Clips…"])
            menu.performActionForItem(at: index)
            check("⋯ › Find Clips… opens the popover at ⋯", editor.showFindClips && editor.findClipsAnchor == .overflow)
            editor.showFindClips = false
        } else { check("⋯ › Find Clips… exists", false) }

        // The layout toggles: hide and show the right column and the timeline; the right
        // column's controls move into the tab row while it is hidden.
        shell.toggleViewer()
        for _ in 0..<40 where Self.regions(in: window)[.rightTitle] != nil { try await Task.sleep(for: .milliseconds(25)) }
        let tabRow = view("voxclip.shell.tabBar", in: root)
        check("Hide Viewer collapses the right column and moves Export into the tab row", Self.regions(in: window)[.rightTitle] == nil && view("voxclip.shell.export", in: root)?.superview === tabRow)
        shell.toggleViewer()
        shell.toggleTimeline()
        for _ in 0..<40 where Self.regions(in: window)[.timeline] != nil { try await Task.sleep(for: .milliseconds(25)) }
        check("the timeline toggle collapses the timeline panel", Self.regions(in: window)[.timeline] == nil && !shell.layout.timelineVisible)
        shell.toggleTimeline()
        check("toggles store no width", app.settings.values[WorkspaceLayout.rightWidthKey] == nil && app.settings.values[WorkspaceLayout.timelineHeightKey] == nil)
        for _ in 0..<40 where Self.regions(in: window)[.timeline] == nil || Self.regions(in: window)[.rightTitle] == nil { try await Task.sleep(for: .milliseconds(25)) }

        // VoiceOver reads the shell as five named groups, in order (impl-plan V1b).
        func groups(_ view: NSView) -> [String] {
            let label = view.accessibilityLabel() ?? ""
            let own = view.isAccessibilityElement() && view.accessibilityRole() == .group && !label.isEmpty && !view.isHiddenOrHasHiddenAncestor ? [label] : []
            return own + view.subviews.flatMap(groups)
        }
        let named = shellRoot.map(groups) ?? []
        check("VoiceOver reads the shell as Explorer, Editor, Viewer and panel, Timeline and Status (\(named.joined(separator: ", ")))", named == ["Explorer", "Editor", "Viewer and panel", "Timeline", "Status"])

        // F6 (impl-plan §3.2): the AppKit stops take focus, the transcript is found in the new tree.
        // TranscriptFocusOnShow gave the transcript focus when the window opened, and F6 starts
        // from the stop that holds focus, so focus starts in the Explorer's list here.
        let explorerList = view("voxclip.shell.explorer", in: root).flatMap { firstView(NSTableView.self, in: $0) }
        if !(explorerList.map { window.makeFirstResponder($0) } ?? false) { window.makeFirstResponder(nil) }
        editor.focusedPane = .sidebar
        shell.movePaneFocus(backward: false)
        check("F6 from the Explorer reaches the tab and clip-bar rows at ⋯", editor.focusedPane == .tabs && (window.firstResponder as? NSView)?.identifier?.rawValue == "voxclip.shell.more")
        shell.movePaneFocus(backward: false)
        check("F6 from the tab row puts focus in the transcript", editor.focusedPane == .transcript && window.firstResponder is TranscriptNSTextView)
        shell.movePaneFocus(backward: true)
        check("⇧F6 from the transcript, which holds focus, returns to the tab row", editor.focusedPane == .tabs && (window.firstResponder as? NSView)?.identifier?.rawValue == "voxclip.shell.more")
        window.makeFirstResponder(nil)
        editor.focusedPane = .timeline
        shell.movePaneFocus(backward: false)
        check("F6 from the timeline reaches the status bar", editor.focusedPane == .status && window.firstResponder is StatusBarView)
        shell.movePaneFocus(backward: false)
        check("F6 from the status bar returns to the Explorer", editor.focusedPane == .sidebar)
        shell.movePaneFocus(backward: true)
        check("⇧F6 from the Explorer returns to the status bar", editor.focusedPane == .status)
        _ = focusTranscript(in: window)
        return results
    }

    /// The other sizes of impl-plan §3.5 in one window resized from 1280, and the Explorer
    /// and right-column overlays below 1,128 and 904.
    private static func sizeChecks(app: AppModel, shell: WorkspaceShell, directory: URL) async throws -> [DebugUISuite.Result] {
        var results: [DebugUISuite.Result] = []
        func check(_ name: String, _ passed: Bool) { results.append(.init(name: name, passed: passed)) }
        let window = makeWindow(app: app, shell: shell)
        defer { window.close(); shell.sidebarOverlay = false; shell.rightOverlay = false }
        guard let root = window.contentView else { throw CocoaError(.coderInvalidValue) }
        for size in sizes.dropFirst() {
            window.setContentSize(size)
            results += try await settleRegions(window, size: size, directory: directory)
        }

        // At 960 the Explorer shows over the editor on request: flat, its width, under the tab row.
        window.setContentSize(NSSize(width: 960, height: 600))
        for _ in 0..<40 where abs(shell.windowWidth - 960) > 0.5 { try await Task.sleep(for: .milliseconds(25)) }
        shell.toggleSidebar()
        func tables(in view: NSView) -> [NSTableView] {
            if let table = view as? NSTableView { return view.isHiddenOrHasHiddenAncestor || view.visibleRect.isEmpty ? [] : [table] }
            return view.subviews.flatMap { tables(in: $0) }
        }
        var overlayList: CGRect?
        for _ in 0..<80 {
            root.layoutSubtreeIfNeeded()
            if let scroll = tables(in: root).first?.enclosingScrollView {
                let rect = scroll.convert(scroll.bounds, to: nil)
                overlayList = CGRect(x: rect.minX, y: root.bounds.height - rect.maxY, width: rect.width, height: rect.height)
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        let explorerOverlay = CGRect(x: 0, y: ShellMetrics.titleRow, width: CGFloat(VCTokens.sizeSidebarIdeal), height: 600 - ShellMetrics.titleRow - ShellMetrics.statusBar)
        check("at 960 the Explorer toggle shows the Explorer over the editor under the tab row, \(describe(explorerOverlay)) within 1 pt (\(overlayList.map(describe) ?? "missing")), while its pane stays collapsed",
              shell.sidebarOverlay && !shell.layout.explorerVisible && matches(overlayList, explorerOverlay) && shell.paneOrder.first == .sidebar)
        shell.toggleSidebar()

        // At 800 Show Viewer shows the right column over the editor, flat, under the tab row.
        window.setContentSize(NSSize(width: 800, height: 600))
        for _ in 0..<40 where abs(shell.windowWidth - 800) > 0.5 { try await Task.sleep(for: .milliseconds(25)) }
        shell.toggleViewer()
        var overlay: CGRect?
        for _ in 0..<80 {
            root.layoutSubtreeIfNeeded()
            if let view = view("voxclip.shell.rightOverlay", in: root), !view.isHiddenOrHasHiddenAncestor {
                let rect = view.convert(view.bounds, to: nil)
                overlay = CGRect(x: rect.minX, y: root.bounds.height - rect.maxY, width: rect.width, height: rect.height)
                if matches(overlay, CGRect(x: 500, y: 38, width: 300, height: 322)) { break }
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        check("at 800 Show Viewer shows the right column over the editor at 500,38 300×322 within 1 pt (\(overlay.map(describe) ?? "missing")), while its pane stays collapsed",
              shell.rightOverlay && !shell.layout.rightVisible && matches(overlay, CGRect(x: 500, y: 38, width: 300, height: 322)) && shell.paneOrder.contains(.viewer))
        do {
            try DebugColumnBounds.assertBounds(window: window, name: "v2-shell-800-overlay", directory: directory)
            check("the right column over the editor keeps its controls inside its bounds", true)
        } catch { check("the right column over the editor keeps its controls inside its bounds: \(DebugUISuite.describe(error))", false) }
        // The overlay borrows the collapsed column's own host: no hidden copy runs the viewer's,
        // the panel's or Rewrite's tasks and focus a second time.
        let work = view("voxclip.shell.work", in: root)?.nextResponder as? EditorWorkController
        let hosts = work.map { rightColumnHosts(in: $0) } ?? []
        check("at 800 one right column is mounted (\(hosts.count)), and it shows in the overlay",
              hosts.count == 1 && work.flatMap { work in work.rightOverlay.map { work.rightColumnHost.view.isDescendant(of: $0) } } == true)
        let editor = shell.editor
        window.makeFirstResponder(nil)
        editor?.focusedPane = .transcript
        shell.movePaneFocus(backward: false)
        check("at 800 F6 from the transcript reaches the viewer over the editor", editor?.focusedPane == .viewer && !(window.firstResponder is TranscriptNSTextView))
        shell.toggleViewer()
        for _ in 0..<40 where view("voxclip.shell.rightOverlay", in: root) != nil { try await Task.sleep(for: .milliseconds(25)) }
        check("Hide Viewer takes the overlay down", !shell.rightOverlay && view("voxclip.shell.rightOverlay", in: root) == nil)
        window.setContentSize(NSSize(width: 1280, height: 800))
        results += try await settleRegions(window, size: NSSize(width: 1280, height: 800), directory: directory)
        return results
    }

    /// Every editor state renders under the clip-bar row in the editor column (impl-plan
    /// V1b): the demo banner, the Find bar, an inline notice, transcription in progress,
    /// the untranscribed take and missing media with Locate…. Captures `v2-state-*-dark`.
    private static func stateChecks(app: AppModel, fixture: Project, directory: URL) async throws -> [DebugUISuite.Result] {
        var results: [DebugUISuite.Result] = []
        typealias Expectation = (name: String, matches: (DebugColumnBounds.Element) -> Bool)
        func state(_ name: String, _ shell: WorkspaceShell, _ expectations: [Expectation]) async throws {
            let window = makeWindow(app: app, shell: shell)
            var found: [String: DebugColumnBounds.Element] = [:]
            var region = CGRect.zero
            for _ in 0..<80 {
                window.contentView?.layoutSubtreeIfNeeded()
                if let root = window.contentView, let transcript = view("voxclip.shell.transcript", in: root) {
                    region = DebugColumnBounds.screenFrame(transcript, window: window)
                    let inside = DebugColumnBounds.elements(in: window).filter { region.insetBy(dx: -1, dy: -1).contains($0.frame) }
                    for expectation in expectations { found[expectation.name] = inside.first(where: expectation.matches) }
                    if found.count == expectations.count { break }
                }
                try await Task.sleep(for: .milliseconds(25))
            }
            window.close()
            for expectation in expectations {
                results.append(.init(name: "v2 state \(name): \(expectation.name) shows in the editor column under the clip-bar row (\(found[expectation.name].map { "\($0.role) \(describe($0.frame))" } ?? "missing"))",
                                     passed: found[expectation.name] != nil))
            }
            do {
                try await DebugUISuite.snapshot(WorkspaceView(shell: shell).environment(app), name: "v2-state-\(name)-dark", size: NSSize(width: 1280, height: 800), appearance: .darkAqua, directory: directory, active: true, mainWindow: true)
            } catch { results.append(.init(name: "capture v2-state-\(name)-dark: \(DebugUISuite.describe(error))", passed: false)) }
        }
        func label(_ text: String) -> Expectation { (text, { $0.label.contains(text) }) }
        func button(_ title: String) -> Expectation { ("the \(title) button", { $0.role == kAXButtonRole && $0.label == title }) }

        let five = try DebugSidebar.fiveQuestions(from: fixture)
        let shell = WorkspaceShell(app: app)
        await shell.attachForTesting(VoxClipDocument(project: five, demo: true), selection: .fullTake)
        guard let editor = shell.editor else { throw CocoaError(.coderInvalidValue) }
        defer { editor.close() }
        editor.mediaResolved = true; editor.refresh()
        try await state("demo", shell, [label("Demo project with no video")])
        editor.findVisible = true
        try await state("find", shell, [("the Find field", { $0.role == kAXTextFieldRole }), button("Close find")])
        editor.findVisible = false
        shell.notice = "Couldn't save “Five questions”, so it stays open. Your video and edits are still here."
        try await state("notice", shell, [label("so it stays open")])
        shell.notice = nil
        editor.progress = "Transcribing… 42%"
        try await state("transcribing", shell, [label("Transcribing… 42%"), button("Cancel")])
        editor.progress = nil

        var bare = five
        bare.transcript = nil
        bare.edits.clips = []; bare.edits.cutWordIds = []; bare.edits.cutPauseIds = []
        let untranscribed = WorkspaceShell(app: app)
        await untranscribed.attachForTesting(VoxClipDocument(project: bare, demo: true), selection: .fullTake)
        if let model = untranscribed.editor {
            try await state("untranscribed", untranscribed, [label("isn't transcribed yet"), button("Transcribe…")])
            model.close()
        } else { results.append(.init(name: "an untranscribed take opens", passed: false)) }

        var moved = five
        moved.media.source.absolutePath = directory.appendingPathComponent("v2-moved-away.mp4").path
        moved.media.source.relativePath = nil
        let missing = WorkspaceShell(app: app)
        await missing.attachForTesting(VoxClipDocument(project: moved, demo: false), selection: .fullTake)
        if let model = missing.editor {
            try await state("missing-media", missing, [button("Locate…")])
            model.close()
        } else { results.append(.init(name: "a take with missing media opens", passed: false)) }
        return results
    }

    /// A Versions-browser version opens in the shell's window, with the Explorer collapsed,
    /// read only, and F6 moving through its own shell.
    private static func versionChecks(app: AppModel, fixture: Project) async throws -> [DebugUISuite.Result] {
        var results: [DebugUISuite.Result] = []
        func check(_ name: String, _ passed: Bool) { results.append(.init(name: name, passed: passed)) }
        let version = VoxClipDocument(project: try DebugSidebar.fiveQuestions(from: fixture), demo: true)
        version.versionForTesting = true
        version.makeWindowControllers()
        defer { version.close() }
        guard let controller = version.windowControllers.first as? VersionWindowController, let window = controller.window as? MainWindow, let root = window.contentView else {
            check("a version opens in its own shell window", false)
            return results
        }
        let shell = controller.shell
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderBack(nil)
        let size = NSSize(width: 1100, height: 720)
        var regions: [ShellRegion: CGRect] = [:]
        for _ in 0..<80 {
            root.layoutSubtreeIfNeeded()
            regions = Self.regions(in: window)
            if ShellRegion.allCases.allSatisfy({ region in region.reference(in: size).map { matches(regions[region], $0) } ?? (regions[region] == nil) }) { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        check("a version window shows the shell with the Explorer collapsed: the tab row is \(ShellRegion.tabBar.reference(in: size).map(describe) ?? "?") within 1 pt (\(regions[.tabBar].map(describe) ?? "missing"))",
              regions[.explorer] == nil && matches(regions[.tabBar], ShellRegion.tabBar.reference(in: size) ?? .zero) && matches(regions[.rightTitle], ShellRegion.rightTitle.reference(in: size) ?? .zero))
        check("a version window has the shell's chrome: no toolbar, a hidden title, a transparent titlebar", window.toolbar == nil && window.titleVisibility == .hidden && window.titlebarAppearsTransparent)
        let work = view("voxclip.shell.work", in: root)?.nextResponder as? EditorWorkController
        let commands = work?.overflowMenu().items.filter { !$0.isSeparatorItem } ?? []
        check("a version is read only: every ⋯ command is off", shell.editor?.capabilities.writable == false && !commands.isEmpty && commands.allSatisfy { !$0.isEnabled })
        let mainPane = app.shell.editor?.focusedPane
        func f6(backward: Bool = false) {
            let key = String(UnicodeScalar(UInt32(NSF6FunctionKey)) ?? " ")
            if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: backward ? [.function, .shift] : [.function], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                            context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: 97) {
                window.sendEvent(event)
            }
        }
        shell.editor?.focusedPane = .transcript
        f6()
        check("F6 in a version window moves through its own shell, not the main window's", shell.editor?.focusedPane == .viewer && app.shell.editor?.focusedPane == mainPane)
        // The Explorer's stop would sit between the status bar and the tab row.
        window.makeFirstResponder(nil)
        shell.editor?.focusedPane = .status
        f6()
        let forward = shell.editor?.focusedPane
        window.makeFirstResponder(nil)
        f6(backward: true)
        check("a version window has no Explorer stop: F6 from the status bar reaches the tab row (\(forward.map { "\($0)" } ?? "none")), and ⇧F6 from it the status bar",
              forward == .tabs && shell.editor?.focusedPane == .status)
        return results
    }

    /// The real-window capture for side-by-side comparison with f1 (sceneAudit).
    static func sceneCaptures(app: AppModel, fixture: Project, directory: URL) async throws -> [DebugUISuite.Result] {
        guard !DebugUISuite.sessionLocked else { throw CocoaError(.userCancelled) }
        let shell = WorkspaceShell(app: app)
        await shell.attachForTesting(VoxClipDocument(project: try DebugSidebar.fiveQuestions(from: fixture), demo: true), selection: .fullTake)
        guard let editor = shell.editor else { throw CocoaError(.coderInvalidValue) }
        defer { editor.close() }
        editor.mediaResolved = true; editor.refresh()
        shell.windowWidth = 1280
        var regions: [ShellRegion: CGRect] = [:]
        try await DebugUISuite.snapshot(WorkspaceView(shell: shell).environment(app), name: "v2-shell-1280", size: NSSize(width: 1280, height: 800), appearance: .darkAqua,
            directory: directory, active: true, mainWindow: true, native: true, beforeCapture: { window in
                window.contentView?.layoutSubtreeIfNeeded()
                regions = Self.regions(in: window)
                return nil
            })
        let evidence = ShellRegion.allCases.map { Region(region: $0.rawValue, frame: regions[$0] ?? .zero, reference: $0.reference) }
        try JSONEncoder().encode(evidence).write(to: directory.appendingPathComponent("v2-shell-1280-native-regions.json"), options: .atomic)
        var results: [DebugUISuite.Result] = ShellRegion.allCases.map { region in
            .init(name: "native v2 shell: the \(region.rawValue) region is \(describe(region.reference)) within 1 pt (\(regions[region].map(describe) ?? "missing"))", passed: matches(regions[region], region.reference))
        }

        // Full screen: the shell fills the screen from its top edge, laid out by the same
        // rules at the screen's size; the window buttons' room goes (impl-plan V1b).
        var entered = false, size = CGSize.zero, inset: CGFloat?
        regions = [:]
        try await DebugUISuite.snapshot(WorkspaceView(shell: shell).environment(app), name: "v2-shell-fullscreen", size: NSSize(width: 1280, height: 800), appearance: .darkAqua,
            directory: directory, active: true, mainWindow: true, native: true, beforeCapture: { window in
                window.toggleFullScreen(nil)
                for _ in 0..<160 where !window.styleMask.contains(.fullScreen) { try await Task.sleep(for: .milliseconds(25)) }
                entered = window.styleMask.contains(.fullScreen)
                // The transition animates on after the style mask changes; wait for the layout to match the screen.
                for _ in 0..<80 {
                    window.contentView?.layoutSubtreeIfNeeded()
                    size = window.contentView?.bounds.size ?? .zero
                    regions = Self.regions(in: window)
                    if ShellRegion.allCases.allSatisfy({ region in region.reference(in: size).map { matches(regions[region], $0) } ?? (regions[region] == nil) }) { break }
                    try await Task.sleep(for: .milliseconds(25))
                }
                inset = (window.contentView.flatMap { view("voxclip.shell.tabBar", in: $0) } as? ShellBand)?.leadingInset
                return nil
            })
        results.append(.init(name: "native full screen: the window enters full screen (\(Int(size.width)) × \(Int(size.height)))", passed: entered))
        for region in ShellRegion.allCases {
            let expected = region.reference(in: size)
            results.append(.init(name: "native full screen: the \(region.rawValue) region is \(expected.map(describe) ?? "collapsed") within 1 pt (\(regions[region].map(describe) ?? "missing"))",
                                 passed: entered && (expected.map { matches(regions[region], $0) } ?? (regions[region] == nil))))
        }
        results.append(.init(name: "native full screen: the tab row keeps no room for window buttons (\(inset.map { "\($0)" } ?? "none"))", passed: inset == 0 || inset == 8))
        return results
    }

    /// The shell's regions in window points from the top-left. The Explorer's divider and
    /// the right column's divider belong to the editor column's rows; the timeline's top
    /// edge belongs to the rows above it. A collapsed region is missing.
    static func regions(in window: NSWindow) -> [ShellRegion: CGRect] {
        guard let root = window.contentView else { return [:] }
        let height = root.bounds.height
        func frame(_ identifier: String) -> CGRect? {
            guard let view = view(identifier, in: root), !view.isHiddenOrHasHiddenAncestor, view.bounds.width > 0, view.bounds.height > 0 else { return nil }
            let rect = view.convert(view.bounds, to: nil)
            return CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
        }
        var regions: [ShellRegion: CGRect] = [:]
        let explorer = frame("voxclip.shell.explorer")
        regions[.explorer] = explorer
        regions[.statusBar] = frame("voxclip.shell.statusBar")
        guard let work = frame("voxclip.shell.work") else { return regions }
        let start = explorer?.maxX ?? work.minX
        let right = frame("voxclip.shell.right")
        let end = right?.minX ?? work.maxX
        for (region, identifier) in [(ShellRegion.tabBar, "voxclip.shell.tabBar"), (.clipBar, "voxclip.shell.clipBar"), (.transcript, "voxclip.shell.transcript")] {
            if let rect = frame(identifier) { regions[region] = CGRect(x: start, y: rect.minY, width: end - start, height: rect.height) }
        }
        if let right {
            regions[.rightTitle] = CGRect(x: right.minX, y: right.minY, width: right.width, height: ShellMetrics.titleRow)
            regions[.rightBody] = CGRect(x: right.minX, y: right.minY + ShellMetrics.titleRow, width: right.width, height: right.height - ShellMetrics.titleRow)
        }
        if let timeline = frame("voxclip.shell.timeline") {
            regions[.timeline] = CGRect(x: start, y: timeline.minY, width: timeline.maxX - start, height: timeline.height)
        }
        return regions
    }

    /// The `RightColumn` hosts under `controller`: one, whether the column or the overlay shows it.
    static func rightColumnHosts(in controller: NSViewController) -> [NSViewController] {
        let own = String(describing: type(of: controller)).contains("RightColumn") ? [controller] : []
        return own + controller.children.flatMap { rightColumnHosts(in: $0) }
    }

    /// The first view under `root` with `identifier`.
    static func view(_ identifier: String, in root: NSView) -> NSView? {
        if root.identifier?.rawValue == identifier { return root }
        return root.subviews.lazy.compactMap { view(identifier, in: $0) }.first
    }
    /// The first view under `root` of `type`.
    static func firstView<T: NSView>(_ type: T.Type, in root: NSView) -> T? {
        if let match = root as? T { return match }
        return root.subviews.lazy.compactMap { firstView(type, in: $0) }.first
    }

    private static func matches(_ frame: CGRect?, _ reference: CGRect) -> Bool {
        guard let frame else { return false }
        return abs(frame.minX - reference.minX) <= 1 && abs(frame.minY - reference.minY) <= 1 && abs(frame.width - reference.width) <= 1 && abs(frame.height - reference.height) <= 1
    }
    private static func describe(_ rect: CGRect) -> String {
        "\(Int(rect.minX.rounded())),\(Int(rect.minY.rounded())) \(Int(rect.width.rounded()))×\(Int(rect.height.rounded()))"
    }
}
#endif
