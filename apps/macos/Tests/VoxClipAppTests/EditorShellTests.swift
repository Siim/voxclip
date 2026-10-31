#if DEBUG
import AppKit
import Foundation
import Testing
@testable import VoxClipCore
@testable import VoxClip

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
}
#endif
