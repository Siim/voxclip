#if DEBUG
import AppKit
import Foundation
import Testing
@testable import VoxClipCore
@testable import VoxClip

/// A window that reports full screen without entering it: AppKit refuses the style mask
/// outside its own transition. It is never shown.
private final class FullScreenStandIn: NSWindow {
    var reportsFullScreen = false
    override var styleMask: NSWindow.StyleMask {
        get { reportsFullScreen ? super.styleMask.union(.fullScreen) : super.styleMask }
        set { super.styleMask = newValue }
    }
}

/// The v2 shell's AppKit tree without a visible window (impl-plan V1a and V1b). Nothing is
/// shown, and settings are never loaded, so nothing is written.
@Suite("v2 shell controllers", .serialized)
@MainActor struct EditorShellTests {
    private func project() throws -> Project {
        let shared = try SharedResources.locate()
        return try JSONProjectStore.decode(Data(contentsOf: shared.root.appendingPathComponent("fixtures/voice-lab/passage-render-v3.voxclip")))
    }
    private func editor(_ app: AppModel) throws -> EditorModel {
        EditorModel(document: VoxClipDocument(project: try project(), demo: true), app: app, preview: DemoPreviewEngine())
    }
    /// A shell with the fixture open and its controller built in a never-shown window `width` wide.
    private func openShell(width: Double = 1280) async throws -> (WorkspaceShell, EditorShellController, FullScreenStandIn) {
        _ = NSApplication.shared
        let shell = WorkspaceShell(app: AppModel())
        await shell.attachForTesting(VoxClipDocument(project: try project(), demo: true), selection: .fullTake)
        shell.windowWidth = width
        let controller = EditorShellController(shell: shell)
        let window = FullScreenStandIn(contentRect: NSRect(x: -10000, y: -10000, width: width, height: 800), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = controller.view
        controller.view.frame = NSRect(x: 0, y: 0, width: width, height: 800)
        controller.apply(EditorShellState(shell: shell))
        return (shell, controller, window)
    }
    /// The first view under `root` with `identifier`.
    private func view(_ identifier: String, in root: NSView) -> NSView? {
        if root.identifier?.rawValue == identifier { return root }
        return root.subviews.lazy.compactMap { view(identifier, in: $0) }.first
    }
    /// The editor's columns and timeline at the work area's size, with the layout applied as
    /// EditorShellController applies it.
    private func makeWork(_ model: EditorModel, _ shell: WorkspaceShell) -> EditorWorkController {
        let work = EditorWorkController(model: model, shell: shell)
        work.view.setFrameSize(NSSize(width: shell.windowWidth - shell.layout.explorerWidth, height: 776))
        work.apply(rightVisible: shell.layout.rightVisible, timelineVisible: shell.layout.timelineVisible)
        return work
    }
    /// What a divider drag leaves behind: the pane's new state and the split's resize report.
    private func drag(_ item: NSSplitViewItem, collapsed: Bool, in split: ShellSplitController) {
        item.isCollapsed = collapsed
        NotificationCenter.default.post(name: NSSplitView.didResizeSubviewsNotification, object: split.divider)
    }

    /// The cancel button clears the field and sends only its action, no text change.
    @Test func clearingHomeSearchWithItsCancelButtonClearsTheQuery() throws {
        _ = NSApplication.shared
        let shell = WorkspaceShell(app: AppModel())
        let controller = EditorShellController(shell: shell)
        defer { controller.tearDown() }
        shell.homeQuery = "podcst"
        controller.apply(EditorShellState(shell: shell))
        let field = controller.homeSearch
        #expect(field.stringValue == "podcst")
        let cancel = try #require((field.cell as? NSSearchFieldCell)?.cancelButtonCell)
        cancel.performClick(field)
        #expect(field.stringValue.isEmpty)
        #expect(shell.homeQuery.isEmpty)
        // The next update of the tree leaves the field empty.
        controller.apply(EditorShellState(shell: shell))
        #expect(field.stringValue.isEmpty)
    }

    /// With the Explorer hidden, the title row keeps room for the window buttons outside full
    /// screen only, through entry and exit, which run no `apply`.
    @Test func fullScreenEntryAndExitPlaceTheExplorerToggle() throws {
        let shell = WorkspaceShell(app: AppModel())
        shell.layout.explorerVisible = false
        let controller = EditorShellController(shell: shell)
        defer { controller.tearDown() }
        let window = FullScreenStandIn(contentRect: NSRect(x: -10000, y: -10000, width: 1280, height: 800), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = controller.view
        controller.apply(EditorShellState(shell: shell))
        let titleRow = try #require(controller.homeBand)
        #expect(titleRow.leadingInset == ShellMetrics.windowButtons && controller.explorerToggle.superview === titleRow)
        window.reportsFullScreen = true
        NotificationCenter.default.post(name: NSWindow.didEnterFullScreenNotification, object: window)
        #expect(titleRow.leadingInset == 8)
        window.reportsFullScreen = false
        NotificationCenter.default.post(name: NSWindow.didExitFullScreenNotification, object: window)
        #expect(titleRow.leadingInset == ShellMetrics.windowButtons)
        // Another window's full screen leaves this one alone.
        window.reportsFullScreen = true
        NotificationCenter.default.post(name: NSWindow.didEnterFullScreenNotification, object: NSWindow())
        #expect(titleRow.leadingInset == ShellMetrics.windowButtons)
    }

    /// At 1024 a drag of the right column's divider is Show Viewer or Hide Viewer, and
    /// nothing stores a width. Below 904 the collapsed column's divider cannot be dragged:
    /// Show Viewer shows the column over the editor instead (impl-plan §3.5).
    @Test func draggingTheRightColumnOpenOrClosedIsItsToggle() throws {
        let app = AppModel()
        let shell = WorkspaceShell(app: app)
        let model = try editor(app)
        defer { model.close() }
        shell.windowWidth = 1024
        #expect(shell.layout.rightVisible && !shell.layout.explorerVisible)
        let work = makeWork(model, shell)
        defer { work.tearDown() }
        let probe = NSRect(x: 0, y: 0, width: 5, height: 100)
        #expect(!work.rightItem.isCollapsed && work.columns.splitView(work.columns.divider, effectiveRect: probe, forDrawnRect: probe, ofDividerAt: 0) != .zero)

        // Dragged closed and open again: Hide Viewer and Show Viewer.
        drag(work.rightItem, collapsed: true, in: work.columns)
        #expect(!shell.layout.rightVisible && !shell.layout.explorerVisible)
        work.apply(rightVisible: shell.layout.rightVisible, timelineVisible: shell.layout.timelineVisible)
        drag(work.rightItem, collapsed: false, in: work.columns)
        #expect(shell.layout.rightVisible)
        work.apply(rightVisible: shell.layout.rightVisible, timelineVisible: shell.layout.timelineVisible)
        #expect(app.settings.values[WorkspaceLayout.rightWidthKey] == nil)

        // Below 904: collapsed by width, locked, and shown over the editor on request.
        shell.windowWidth = 880
        work.apply(rightVisible: shell.layout.rightVisible, timelineVisible: shell.layout.timelineVisible, rightOverlay: shell.rightOverlay)
        #expect(!shell.layout.rightVisible && work.rightItem.isCollapsed && work.rightOverlay == nil)
        #expect(work.columns.splitView(work.columns.divider, effectiveRect: probe, forDrawnRect: probe, ofDividerAt: 0) == .zero)
        shell.toggleViewer()
        work.apply(rightVisible: shell.layout.rightVisible, timelineVisible: shell.layout.timelineVisible, rightOverlay: shell.rightOverlay)
        let overlay = try #require(work.rightOverlay?.view)
        overlay.superview?.layoutSubtreeIfNeeded()
        #expect(work.rightItem.isCollapsed && overlay.frame.width == 300 && overlay.frame.minY == ShellMetrics.titleRow)
        #expect(overlay.frame.maxX == overlay.superview?.bounds.width)
        #expect(overlay.accessibilityRole() == .group && overlay.accessibilityLabel() == "Viewer and panel")
        #expect(work.rightToggle.accessibilityLabel() == EditorIconAction.hideViewer.name)
        shell.toggleViewer()
        work.apply(rightVisible: shell.layout.rightVisible, timelineVisible: shell.layout.timelineVisible, rightOverlay: shell.rightOverlay)
        #expect(work.rightOverlay == nil && overlay.superview == nil)
    }

    /// A drag of the Explorer's divider stops where the editor (604) and the right column
    /// (300) keep their minimums, so the dragged width never moves the Explorer's threshold
    /// past the window and the work area is never squeezed (impl-plan §3.5). Outside a drag
    /// the maximum is the Explorer's own, so a window resize never narrows it.
    @Test func anExplorerDragLeavesTheEditorAndTheRightColumnTheirMinimums() async throws {
        let (shell, controller, _) = try await openShell(width: 1200)
        defer { controller.tearDown(); shell.editor?.close() }
        let item = try #require(controller.explorerItem)
        #expect(!item.isCollapsed && item.minimumThickness == 220 && item.maximumThickness == 320)
        let drag = try #require(controller.content.divider.aroundDividerDrag)
        drag(true)
        #expect(item.maximumThickness == 296)
        drag(false)
        #expect(item.maximumThickness == 320)
        shell.windowWidth = 1440
        drag(true)
        #expect(item.maximumThickness == 320)
        drag(false)
    }

    /// While the Explorer shows over the editor, its toggle reads Hide Sidebar, as the menu does.
    @Test func theExplorerToggleNamesTheOverlay() async throws {
        let (shell, controller, _) = try await openShell(width: 960)
        defer { controller.tearDown(); shell.editor?.close() }
        #expect(!shell.layout.explorerVisible && controller.explorerToggle.accessibilityLabel() == EditorIconAction.showSidebar.name)
        shell.toggleSidebar()
        controller.apply(EditorShellState(shell: shell))
        #expect(shell.sidebarOverlay && controller.explorerToggle.accessibilityLabel() == EditorIconAction.hideSidebar.name)
        #expect(controller.explorerToggle.toolTip == "\(EditorIconAction.hideSidebar.name) (⌃⌘S)")
        shell.toggleSidebar()
        controller.apply(EditorShellState(shell: shell))
        #expect(!shell.sidebarOverlay && controller.explorerToggle.accessibilityLabel() == EditorIconAction.showSidebar.name)
    }

    /// A hidden timeline panel is no F6 stop. Until V4 the panel stays while the right column
    /// is hidden: its toggle is unavailable and its edge does not collapse it.
    @Test func aHiddenTimelineIsNoF6StopAndStaysWhileTheRightColumnIsHidden() throws {
        let app = AppModel()
        let shell = app.shell
        let model = try editor(app)
        defer { model.close() }
        shell.toggleTimeline()
        #expect(!shell.layout.timelineVisible)
        model.focusedPane = .panel
        model.movePaneFocus(backward: false, through: shell.paneOrder)
        #expect(model.focusedPane == .status)
        model.movePaneFocus(backward: true, through: shell.paneOrder)
        #expect(model.focusedPane == .panel)

        shell.toggleViewer()
        #expect(!shell.layout.rightVisible && shell.layout.timelineVisible)
        let work = makeWork(model, shell)
        defer { work.tearDown() }
        #expect(!work.timelineToggle.isEnabled && !work.timelineItem.canCollapse && !work.timelineItem.isCollapsed)
        shell.toggleViewer()
        work.apply(rightVisible: shell.layout.rightVisible, timelineVisible: shell.layout.timelineVisible)
        #expect(work.timelineToggle.isEnabled && work.timelineItem.canCollapse)
    }

    /// ⇧⌘K in the transcript and ⋯ › Find Clips… both ask for the popover at ⋯. The Clip
    /// menu's item (tag 34) is DebugMenus' check; the popover itself is DebugShell's.
    @Test func findClipsFromTheTranscriptAndFromOverflowAnchorsAtOverflow() throws {
        _ = NSApplication.shared
        let app = AppModel()
        let model = try editor(app)
        defer { model.close() }
        let text = TranscriptNSTextView(usingTextLayoutManager: true)
        text.model = model
        let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0, windowNumber: 0, context: nil,
                                                characters: "K", charactersIgnoringModifiers: "K", isARepeat: false, keyCode: 40))
        text.keyDown(with: key)
        #expect(model.showFindClips && model.findClipsAnchor == .overflow)
        model.showFindClips = false

        let work = EditorWorkController(model: model, shell: WorkspaceShell(app: app))
        defer { work.tearDown() }
        let menu = work.overflowMenu()
        let index = try #require(menu.items.firstIndex { $0.title == "Find Clips…" })
        #expect(menu.items[index].isEnabled)
        menu.performActionForItem(at: index)
        #expect(model.showFindClips && model.findClipsAnchor == .overflow)
        model.showFindClips = false
    }

    /// VoiceOver reads the shell as five groups, in this order (impl-plan V1b).
    @Test func theShellReadsAsFiveNamedGroups() async throws {
        let (shell, controller, _) = try await openShell()
        defer { controller.tearDown(); shell.editor?.close() }
        func groups(_ view: NSView) -> [String] {
            let label = view.accessibilityLabel() ?? ""
            let own = view.isAccessibilityElement() && view.accessibilityRole() == .group && !label.isEmpty ? [label] : []
            return own + view.subviews.flatMap(groups)
        }
        #expect(groups(controller.view) == ["Explorer", "Editor", "Viewer and panel", "Timeline", "Status"])
        let explorer = try #require(view("voxclip.shell.explorer", in: controller.view))
        #expect(!(explorer.accessibilityChildren() ?? []).isEmpty)
    }

    /// F6 reaches the AppKit stops: ⋯ for the tab and clip-bar rows, and the status bar,
    /// and starts again from the stop that holds focus (impl-plan §3.2).
    @Test func f6ReachesTheTabRowAndTheStatusBar() async throws {
        let (shell, controller, window) = try await openShell()
        defer { controller.tearDown(); shell.editor?.close() }
        let editor = try #require(shell.editor)
        let work = try #require(controller.editorWork)
        editor.focusedPane = .sidebar
        shell.movePaneFocus(backward: false)
        #expect(editor.focusedPane == .tabs && window.firstResponder === work.overflow)
        // F6 starts from the stop that holds focus; with none, from the editor's last pane.
        window.makeFirstResponder(nil)
        editor.focusedPane = .timeline
        shell.movePaneFocus(backward: false)
        #expect(editor.focusedPane == .status && window.firstResponder === controller.statusBar)
        // Only F6 focuses the status bar: once it lets go, a click cannot give it focus.
        window.makeFirstResponder(nil)
        #expect(controller.statusBar?.acceptsFirstResponder == false)
        controller.statusBar?.takeFocus()
        editor.focusedPane = .sidebar
        shell.movePaneFocus(backward: true)
        #expect(editor.focusedPane == .timeline)
        // Moving to a SwiftUI pane lets go of the AppKit stop, so the next F6 starts from that pane.
        #expect(window.firstResponder !== controller.statusBar && controller.paneHoldingFocus() == nil)
        shell.movePaneFocus(backward: false)
        #expect(editor.focusedPane == .status)
        window.makeFirstResponder(work.overflow)
        editor.focusedPane = .panel
        shell.movePaneFocus(backward: false)
        #expect(editor.focusedPane == .transcript)
    }

    /// A Versions window hosts the same shell in the shell's window class, with the
    /// Explorer collapsed and edits refused; F6 there moves through its own shell.
    @Test func aVersionsWindowHostsTheShellReadOnly() throws {
        _ = NSApplication.shared
        let app = AppModel()
        let version = VoxClipDocument(project: try project(), demo: true)
        version.versionForTesting = true
        let controller = VersionWindowController(version: version, app: app)
        defer { version.close() }
        let window = try #require(controller.window as? MainWindow)
        #expect(window.toolbar == nil && window.titleVisibility == .hidden && window.titlebarAppearsTransparent && window.closeProject == nil)
        #expect((window.windowController as? ShellWindowController)?.shell === controller.shell && controller.shell !== app.shell)
        #expect(!controller.shell.layout.explorerVisible && !controller.shell.paneOrder.contains(.sidebar))
        let editor = try #require(controller.shell.editor)
        #expect(!editor.capabilities.writable && !editor.capabilities.edit && !editor.capabilities.ai)
        // Wider than 1,128, the Explorer the version window hid stays hidden.
        controller.shell.windowWidth = 1400
        #expect(!controller.shell.layout.explorerVisible)
    }

    /// Full-screen entry at a Split View width collapses both columns and the window
    /// buttons' room goes; exit to 1280 brings both back and the overlay goes.
    @Test func fullScreenAtASplitViewWidthAndBack() async throws {
        let (shell, controller, window) = try await openShell()
        defer { controller.tearDown(); shell.editor?.close() }
        let work = try #require(controller.editorWork)
        window.reportsFullScreen = true
        NotificationCenter.default.post(name: NSWindow.didEnterFullScreenNotification, object: window)
        shell.windowWidth = 760
        controller.apply(EditorShellState(shell: shell))
        #expect(!shell.layout.explorerVisible && !shell.layout.rightVisible)
        #expect(work.tabRow.leadingInset == 8 && controller.explorerToggle.superview === work.tabRow)
        shell.toggleViewer()
        controller.apply(EditorShellState(shell: shell))
        #expect(work.rightOverlay != nil)
        window.reportsFullScreen = false
        NotificationCenter.default.post(name: NSWindow.didExitFullScreenNotification, object: window)
        shell.windowWidth = 1280
        controller.apply(EditorShellState(shell: shell))
        #expect(shell.layout.explorerVisible && shell.layout.rightVisible && !shell.rightOverlay && work.rightOverlay == nil)
        #expect(work.tabRow.leadingInset == 0 && controller.explorerToggle.superview !== work.tabRow)
    }
}
#endif
