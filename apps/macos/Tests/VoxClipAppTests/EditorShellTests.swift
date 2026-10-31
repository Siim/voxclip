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
}
#endif
