#if DEBUG
import AppKit
import SwiftUI
import VoxClipCore

@MainActor enum DebugMenus {
    static func run(app: AppModel, fixture: Project, directory: URL) async throws -> [DebugUISuite.Result] {
        var results: [DebugUISuite.Result] = []
        func check(_ name: String, _ passed: Bool) { results.append(.init(name: name, passed: passed)) }
        func item(_ menu: String, _ title: String) -> NSMenuItem? { NSApp.mainMenu?.item(withTitle: menu)?.submenu?.item(withTitle: title) }
        guard let delegate = NSApp.delegate as? AppDelegate else { throw CocoaError(.coderInvalidValue) }
        let bindings: [(String, String, String, NSEvent.ModifierFlags)] = [
            ("File", "New Project from Video…", "n", .command), ("File", "Close Project", "w", .command),
            ("View", "Home", "1", .command), ("View", "Full Take", "2", .command),
            ("Clip", "Find Clips…", "k", [.command, .shift]), ("Edit", "Rewrite…", "r", [.command, .shift]),
            ("View", "Hide Viewer", "i", [.command, .option]), ("View", "Hide Sidebar", "s", [.command, .control]),
            ("Clip", "Set Start", "i", []), ("Clip", "Set End", "o", []),
            ("Clip", "Previous Clip", "[", []), ("Clip", "Next Clip", "]", []),
            ("Playback", "Play/Pause", " ", []), ("Playback", "Play from Selection", " ", .shift),
            ("Playback", "Preview Cut", "p", []), ("Playback", "Shuttle Back", "j", []),
            ("Playback", "Stop", "k", []), ("Playback", "Shuttle Forward", "l", []),
            ("Playback", "Back 3 Seconds", "j", []),
            ("Playback", "Go to Start", String(UnicodeScalar(NSUpArrowFunctionKey)!), .command),
            ("Playback", "Go to End", String(UnicodeScalar(NSDownArrowFunctionKey)!), .command),
            ("Edit", "Cut Selection", String(UnicodeScalar(NSDeleteCharacter)!), []),
            ("Edit", "Restore Selection", String(UnicodeScalar(NSDeleteCharacter)!), .shift), ("Edit", "Correct Word", "c", [])
        ]
        for (menu, title, key, modifiers) in bindings {
            check("native menu shortcut: \(title)", item(menu, title).map { $0.keyEquivalent == key && $0.keyEquivalentModifierMask == modifiers } == true)
        }
        for title in ["Keep Suggestion", "Dismiss Suggestion", "Keep All Suggestions", "Rename Clip…", "Remove Clip", "Export Clip…"] {
            check("native Clip menu includes \(title)", item("Clip", title) != nil)
        }
        check("menus retain document Duplicate and Insert Words", item("File", "Duplicate") != nil && item("Edit", "Insert Words…") != nil)
        check("menus expose three-second playback actions", item("Playback", "Back 3 Seconds")?.keyEquivalent == "j" && item("Playback", "Forward 3 Seconds") != nil)
        check("Help uses Welcome Tour and removes obsolete workspaces", item("Help", "Welcome Tour") != nil && item("Help", "Workspace Tour") == nil && item("View", "Transcript") == nil && item("View", "Clips") == nil && item("View", "Show Caption Inspector") == nil)
        let previousDocument = app.shell.document
        let previousSelection = app.shell.selection
        let previousVoiceLab = app.bool("voiceLab.enabled")
        let commandWindow = app.shell.windowController?.window
        let previousContent = commandWindow?.contentViewController
        commandWindow?.contentViewController = NSViewController()
        defer { commandWindow?.contentViewController = previousContent }
        let project = try DebugSidebar.fiveQuestions(from: fixture)
        let document = VoxClipDocument(project: project, demo: true)
        await app.shell.attachForTesting(document, selection: .fullTake)
        guard let editor = app.shell.editor, let window = app.shell.windowController?.window else { throw CocoaError(.coderInvalidValue) }
        delegate.commandWindowForTesting = window
        defer { delegate.commandWindowForTesting = nil }
        window.makeKey()
        func invoke(_ menu: String, _ title: String) {
            guard let entry = item(menu, title), let action = entry.action else { return }
            _ = delegate.perform(action, with: entry)
        }
        invoke("View", "Home")
        check("Command-1 native action shows Home", app.shell.showsHome)
        let clipMenu = NSApp.mainMenu?.item(withTitle: "Clip")?.submenu
        check("every Clip command is disabled on Home", clipMenu?.items.filter { !$0.isSeparatorItem }.allSatisfy { !delegate.validateMenuItem($0) } == true)
        invoke("View", "Full Take")
        check("Command-2 native action shows Full Take", app.shell.selection == .fullTake && !app.shell.showsHome)
        try await Task.sleep(for: .milliseconds(100))
        window.makeKey()
        if let viewer = item("View", "Hide Viewer"), let sidebar = item("View", "Hide Sidebar") {
            _ = delegate.validateMenuItem(viewer); _ = delegate.validateMenuItem(sidebar)
            let before = viewer.title
            invoke("View", before)
            _ = delegate.validateMenuItem(viewer)
            check("Viewer menu title tracks the next action", before != viewer.title)
            invoke("View", viewer.title)
            let sidebarBefore = sidebar.title
            invoke("View", sidebarBefore)
            _ = delegate.validateMenuItem(sidebar)
            check("Sidebar menu title tracks the next action", sidebarBefore != sidebar.title)
            invoke("View", sidebar.title)
        }
        guard let first = editor.words.first, let kept = editor.keptClips.first, let suggestion = editor.suggestedClips.first else { throw CocoaError(.coderInvalidValue) }
        editor.selectedWordIDs = [first.id]
        invoke("Clip", "Find Clips…")
        check("Shift-Command-K routes to the existing Find Clips popover", editor.showFindClips)
        editor.showFindClips = false
        app.set("voiceLab.enabled", .bool(false))
        invoke("Edit", "Rewrite…")
        check("Rewrite menu uses the off-by-default Voice Lab opt-in", editor.showVoiceLabOptIn && editor.rewrite == nil)
        editor.showVoiceLabOptIn = false
        app.set("voiceLab.enabled", .bool(true))
        invoke("Edit", "Rewrite…")
        check("Shift-Command-R records the selection without starting a panel or provider", editor.rewrite == 0...0)
        invoke("Edit", "Insert Words…")
        check("Insert Words records its caret anchor without synthesising audio", editor.rewriteInsertionAfterID == first.id && editor.rewrite == nil)
        app.shell.selection = .clip(suggestion.id)
        check("suggestion menu validation enables Keep and disables Rename", item("Clip", "Keep Suggestion").map(delegate.validateMenuItem) == true && item("Clip", "Rename Clip…").map(delegate.validateMenuItem) == false)
        app.shell.selection = .clip(kept.id)
        check("kept clip menu validation enables Rename and disables Keep", item("Clip", "Rename Clip…").map(delegate.validateMenuItem) == true && item("Clip", "Keep Suggestion").map(delegate.validateMenuItem) == false)
        invoke("Clip", "Rename Clip…")
        check("Rename Clip uses the sidebar's native inline rename", app.shell.renaming == kept.id)
        app.shell.endRename(keep: false)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            try await DebugUISuite.snapshot(ShortcutsView(), name: "keyboard-shortcuts-\(name)", size: NSSize(width: 628, height: 760), appearance: appearance, directory: directory)
            try await DebugUISuite.snapshot(VoiceLabOptInView(editor: editor), name: "voice-lab-opt-in-\(name)", size: NSSize(width: 460, height: 270), appearance: appearance, directory: directory)
        }
        let menus: [[String: Any]] = NSApp.mainMenu?.items.compactMap { parent in
            guard let submenu = parent.submenu else { return nil }
            return ["menu": parent.title, "items": submenu.items.map { ["title": $0.title, "key": $0.keyEquivalent, "modifiers": $0.keyEquivalentModifierMask.rawValue] }]
        } ?? []
        try JSONSerialization.data(withJSONObject: menus, options: [.sortedKeys, .prettyPrinted]).write(to: directory.appendingPathComponent("native-menus.json"))
        app.set("voiceLab.enabled", .bool(previousVoiceLab))
        document.updateChangeCount(.changeCleared)
        if let previousDocument { await app.shell.attachForTesting(previousDocument, selection: previousSelection) }
        else { _ = await app.shell.closeProject() }
        document.updateChangeCount(.changeCleared); document.close()
        try JSONEncoder().encode(results).write(to: directory.appendingPathComponent("menu-results.json"), options: .atomic)
        return results
    }
}
#endif
