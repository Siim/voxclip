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

/// The v2 shell's AppKit tree without a visible window (impl-plan V1a). Nothing is shown,
/// and settings are never loaded, so nothing is written.
@Suite("v2 shell controllers", .serialized)
@MainActor struct EditorShellTests {
    private func editor(_ app: AppModel) throws -> EditorModel {
        let shared = try SharedResources.locate()
        let project = try JSONProjectStore.decode(Data(contentsOf: shared.root.appendingPathComponent("fixtures/voice-lab/passage-render-v3.voxclip")))
        return EditorModel(document: VoxClipDocument(project: project, demo: true), app: app, preview: DemoPreviewEngine())
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

    /// At 1024 a drag of the right column's divider is Show Viewer or Hide Viewer: the width
    /// rule's bookkeeping stays right, and nothing stores a width.
    @Test func draggingTheRightColumnOpenOrClosedIsItsToggle() throws {
        let app = AppModel()
        let shell = WorkspaceShell(app: app)
        let model = try editor(app)
        defer { model.close() }
        shell.windowWidth = 1024
        #expect(!shell.layout.rightVisible && shell.layout.explorerVisible)
        // Building the work area while the width rule hides the column keeps it hidden.
        let work = makeWork(model, shell)
        defer { work.tearDown() }
        #expect(!shell.layout.rightVisible && work.rightItem.isCollapsed)

        // Dragged open: the Explorer makes room, and a 1 pt resize keeps the column.
        drag(work.rightItem, collapsed: false, in: work.columns)
        #expect(shell.layout.rightVisible && !shell.layout.explorerVisible)
        work.apply(rightVisible: shell.layout.rightVisible, timelineVisible: shell.layout.timelineVisible)
        shell.windowWidth = 1025
        #expect(shell.layout.rightVisible && !shell.layout.explorerVisible)

        // Dragged closed: the Explorer hidden to make room comes back.
        drag(work.rightItem, collapsed: true, in: work.columns)
        #expect(!shell.layout.rightVisible && shell.layout.explorerVisible)
        #expect(app.settings.values[WorkspaceLayout.rightWidthKey] == nil)
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
        model.movePaneFocus(backward: false)
        #expect(model.focusedPane == .sidebar)
        model.movePaneFocus(backward: true)
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
}
#endif
