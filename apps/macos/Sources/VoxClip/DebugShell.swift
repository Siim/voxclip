#if DEBUG
import AppKit
import SwiftUI
import VoxClipCore

/// The v2 shell (impl-plan V1a): the regions at 1280 × 800 with fresh defaults against
/// notes.md §1, the window chrome, what the title rows' clicks reach, the Find Clips
/// anchor at ⋯, and a saved pre-v2 right-column width being ignored. Captures
/// `v2-shell-1280-*` offscreen; `sceneCaptures` takes the real-window `v2-shell-1280.png`.
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
        app.settings.values[WorkspaceLayout.retiredRightWidthKey] = .number(500)
        var retired: [String: JSONValue] = [WorkspaceLayout.retiredRightWidthKey: .number(500), "general.appearance": .string("dark")]
        check("loading settings retires ui.rightColumnWidth and keeps the rest", WorkspaceLayout.retireLegacyKeys(&retired) && retired == ["general.appearance": .string("dark")] && !WorkspaceLayout.retireLegacyKeys(&retired))

        let shell = WorkspaceShell(app: app)
        await shell.attachForTesting(VoxClipDocument(project: try DebugSidebar.fiveQuestions(from: fixture), demo: true), selection: .fullTake)
        guard let editor = shell.editor else { throw CocoaError(.coderInvalidValue) }
        defer { editor.close() }
        editor.mediaResolved = true; editor.refresh()
        check("a saved ui.rightColumnWidth is ignored: the right column starts at 404 at 1280", shell.rightWidth == 404 && WorkspaceShell(app: app).rightWidth == 404)
        results += try await windowChecks(app: app, shell: shell, editor: editor, directory: directory)
        // One window at a time on the editor: the offscreen capture comes after the checks' window closed.
        try await DebugUISuite.snapshot(WorkspaceView(shell: shell).environment(app), name: "v2-shell-1280-dark", size: NSSize(width: 1280, height: 800), appearance: .darkAqua, directory: directory, active: true, mainWindow: true)
        return results
    }

    private static func windowChecks(app: AppModel, shell: WorkspaceShell, editor: EditorModel, directory: URL) async throws -> [DebugUISuite.Result] {
        var results: [DebugUISuite.Result] = []
        func check(_ name: String, _ passed: Bool) { results.append(.init(name: name, passed: passed)) }
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 1280, height: 800), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        EditorShellController.prepare(window)
        window.title = shell.title
        let host = NSHostingController(rootView: WorkspaceView(shell: shell).environment(app).sceneAccent())
        host.sizingOptions = []
        host.sceneBridgingOptions = []
        window.contentViewController = host
        window.setContentSize(NSSize(width: 1280, height: 800))
        window.orderBack(nil)
        defer { window.close() }
        guard let root = window.contentView else { throw CocoaError(.coderInvalidValue) }
        var regions: [ShellRegion: CGRect] = [:]
        for _ in 0..<80 {
            root.layoutSubtreeIfNeeded()
            regions = Self.regions(in: window)
            if regions.count == ShellRegion.allCases.count, ShellRegion.allCases.allSatisfy({ Self.matches(regions[$0], $0.reference) }) { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let evidence = ShellRegion.allCases.map { Region(region: $0.rawValue, frame: regions[$0] ?? .zero, reference: $0.reference) }
        try JSONEncoder().encode(evidence).write(to: directory.appendingPathComponent("v2-shell-1280-regions.json"), options: .atomic)
        for region in ShellRegion.allCases {
            check("at 1280 × 800 the \(region.rawValue) region is \(describe(region.reference)) within 1 pt (\(regions[region].map(describe) ?? "missing"))", matches(regions[region], region.reference))
        }
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

        // Find Clips from the menus (tag 34 and ⇧⌘K call this), from ⋯, and the popover at ⋯.
        func popoverShown() -> Bool { NSApp.windows.contains { $0.isVisible && String(describing: type(of: $0)).contains("Popover") } }
        let work = view("voxclip.shell.work", in: root)?.nextResponder as? EditorWorkController
        check("the work area is the editor's split controller", work != nil)
        editor.requestFindClips(from: .overflow)
        for _ in 0..<40 where !popoverShown() { try await Task.sleep(for: .milliseconds(25)) }
        check("Find Clips from the menus opens its popover at ⋯", editor.showFindClips && editor.findClipsAnchor == .overflow && work?.findClipsPopover?.isShown == true && popoverShown())
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
        return ShellRegion.allCases.map { region in
            .init(name: "native v2 shell: the \(region.rawValue) region is \(describe(region.reference)) within 1 pt (\(regions[region].map(describe) ?? "missing"))", passed: matches(regions[region], region.reference))
        }
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

    /// The first view under `root` with `identifier`.
    static func view(_ identifier: String, in root: NSView) -> NSView? {
        if root.identifier?.rawValue == identifier { return root }
        return root.subviews.lazy.compactMap { view(identifier, in: $0) }.first
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
