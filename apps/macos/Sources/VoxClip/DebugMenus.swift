#if DEBUG
import AppKit
import SwiftUI
import VoxClipCore

@MainActor enum DebugMenus {
    static func focusedControlChecks() -> [DebugUISuite.Result] {
        let play = NSMenuItem(title: "Play/Pause", action: nil, keyEquivalent: " ")
        play.keyEquivalentModifierMask = []
        let cut = NSMenuItem(title: "Cut Selection", action: nil, keyEquivalent: String(UnicodeScalar(NSDeleteCharacter)!))
        cut.keyEquivalentModifierMask = []
        let findNext = NSMenuItem(title: "Find Next", action: nil, keyEquivalent: "g")
        findNext.keyEquivalentModifierMask = .command
        let controls: [NSResponder] = [NSButton(), NSSwitch(), NSSegmentedControl(), NSPopUpButton()]
        return [
            .init(name: "bare keys remain with focused controls", passed: controls.allSatisfy {
                AppDelegate.focusedControlKeepsKey(play, responder: $0) && AppDelegate.focusedControlKeepsKey(cut, responder: $0)
            }),
            .init(name: "transcript, sidebar and timeline retain transport keys", passed: [TranscriptNSTextView(), NSTableView(), NSSlider()].allSatisfy {
                !AppDelegate.focusedControlKeepsKey(play, responder: $0)
            }),
            .init(name: "Command shortcuts remain available over focused controls", passed: !AppDelegate.focusedControlKeepsKey(findNext, responder: NSButton()))
        ]
    }
    /// Headless coverage of impl-plan §3.2, including hidden tab/Keep alternates.
    static func shortcutChecks(in menu: NSMenu) -> [DebugUISuite.Result] {
        func walk(_ menu: NSMenu) -> [NSMenuItem] { menu.items.flatMap { [$0] + ($0.submenu.map(walk) ?? []) } }
        let items = walk(menu)
        let bindings: [(Int, String, NSEvent.ModifierFlags)] = [
            (18, "=", .command), (18, "+", .command), (19, "-", .command), (61, "k", .command), (29, "k", [.command, .option]), (34, "k", [.command, .shift]),
            (60, "c", [.command, .option]), (56, "j", .command), (16, "s", [.command, .control]),
            (12, "i", [.command, .option]), (50, "\t", [.control, .shift]), (51, "\t", .control),
            (50, "{", .command), (51, "}", .command),
            (40, "\r", [.command, .shift]), (38, "r", [.command, .shift]),
            (24, "j", []), (25, "k", []), (26, "l", []), (30, "i", []), (31, "o", []),
            (32, "[", []), (33, "]", []), (21, " ", []), (22, " ", .shift), (23, "p", []),
            (13, "1", .command), (14, "2", .command), (7, "u", [.command, .option]),
            (8, "p", [.command, .option]), (9, "r", [.command, .option])
        ]
        var checks = bindings.map { tag, key, flags in
            DebugUISuite.Result(name: "keyboard §3.2 tag \(tag) \(flags.rawValue) \(key.debugDescription)", passed: items.contains { $0.tag == tag && $0.keyEquivalent == key && $0.keyEquivalentModifierMask == flags })
        }
        checks.append(.init(name: "keyboard §3.2 Close tab is Command-W", passed: items.contains { ["Close Project", "Close Tab", "Close"].contains($0.title) && $0.keyEquivalent == "w" && $0.keyEquivalentModifierMask == .command }))
        let grouped = Dictionary(grouping: items.filter { !$0.keyEquivalent.isEmpty }) { "\($0.keyEquivalent.lowercased())|\($0.keyEquivalentModifierMask.rawValue)" }
        let allowed: [Set<String>] = [["Keep Suggestion", "Rename Clip…"], ["Cut Selection", "Dismiss Suggestion", "Remove Clip"], ["Shuttle Back", "Back 3 Seconds"], ["Enter Full Screen", "Toggle Full Screen"]]
        checks.append(.init(name: "no accidental duplicate menu shortcuts", passed: grouped.values.allSatisfy { $0.count == 1 || allowed.contains(Set($0.map(\.title))) }))
        let reserved: [(String, NSEvent.ModifierFlags)] = [("\r", .command), (String(UnicodeScalar(NSDeleteCharacter)!), .command), (String(UnicodeScalar(NSUpArrowFunctionKey)!), .option), (String(UnicodeScalar(NSDownArrowFunctionKey)!), .option)]
        checks.append(.init(name: "transcript hunk keys stay off the native menu", passed: reserved.allSatisfy { key, flags in !items.contains { $0.keyEquivalent == key && $0.keyEquivalentModifierMask == flags } }))
        return checks
    }
    static func run(app: AppModel, fixture: Project, directory: URL) async throws -> [DebugUISuite.Result] {
        var results = NSApp.mainMenu.map(shortcutChecks) ?? []
        func check(_ name: String, _ passed: Bool) { results.append(.init(name: name, passed: passed)) }
        func item(_ menu: String, _ title: String) -> NSMenuItem? {
            let items = NSApp.mainMenu?.item(withTitle: menu)?.submenu
            if menu == "View", let tag = ["Bigger Text": 18, "Smaller Text": 19][title] { return items?.item(withTag: tag) }
            return items?.item(withTitle: title)
                ?? (title == "Close Project" ? items?.item(withTitle: "Close Tab") ?? items?.item(withTitle: "Close") : nil)
                ?? (title.hasPrefix("Rewrite") ? items?.item(withTag: 38) : nil)
        }
        guard let delegate = NSApp.delegate as? AppDelegate else { throw CocoaError(.coderInvalidValue) }
        let bindings: [(String, String, String, NSEvent.ModifierFlags)] = [
            ("File", "New Project from Video…", "n", .command), ("File", "Close Project", "w", .command),
            ("File", "Open…", "o", .command), ("File", "Export…", "e", .command),
            ("View", "Home", "1", .command), ("View", "Full Take", "2", .command),
            ("Clip", "Find Clips…", "k", [.command, .shift]), ("Edit", "Rewrite Full Take", "r", [.command, .shift]),
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
            ("Edit", "Restore Selection", String(UnicodeScalar(NSDeleteCharacter)!), .shift), ("Edit", "Correct Word", "c", []),
            ("Edit", "Cut Fillers", "u", [.command, .option]), ("Edit", "Tighten Pauses", "p", [.command, .option]),
            ("Edit", "Restore All Cuts", "r", [.command, .option]), ("View", "Show Cuts", "c", [.command, .option]),
            ("Edit", "Find…", "f", .command), ("Edit", "Find Next", "g", .command), ("Edit", "Find Previous", "g", [.command, .shift]),
            ("Clip", "Make Clip from Selection", "k", [.command, .option]), ("View", "Search or Run a Command…", "k", .command), ("Clip", "Cancel Finding Clips", ".", .command),
            ("Clip", "Keep Suggestion", String(UnicodeScalar(NSCarriageReturnCharacter)!), []),
            ("Clip", "Dismiss Suggestion", String(UnicodeScalar(NSDeleteCharacter)!), []),
            ("Clip", "Rename Clip…", String(UnicodeScalar(NSCarriageReturnCharacter)!), []),
            ("Clip", "Remove Clip", String(UnicodeScalar(NSDeleteCharacter)!), []),
            ("View", "Hide Timeline", "j", .command), ("View", "Bigger Text", "=", .command), ("View", "Smaller Text", "-", .command), ("View", "Actual Size", "0", .command),
            ("VoxClip", "Settings…", ",", .command)
        ]
        for (menu, title, key, modifiers) in bindings {
            check("native menu shortcut: \(title)", item(menu, title).map { $0.keyEquivalent == key && $0.keyEquivalentModifierMask == modifiers } == true)
        }
        if let play = item("Playback", "Play/Pause"), let cut = item("Edit", "Cut Selection"), let findNext = item("Edit", "Find Next") {
            let controls: [NSResponder] = [NSButton(), NSSwitch(), NSSegmentedControl(), NSPopUpButton()]
            check("bare Space and Delete leave a focused button, switch, segmented control or pop-up to the control", controls.allSatisfy { AppDelegate.focusedControlKeepsKey(play, responder: $0) && AppDelegate.focusedControlKeepsKey(cut, responder: $0) })
            check("bare keys still reach the editor from the transcript and the sidebar list", [TranscriptNSTextView(), NSTableView()].allSatisfy { !AppDelegate.focusedControlKeepsKey(play, responder: $0) && !AppDelegate.focusedControlKeepsKey(cut, responder: $0) })
            check("Command shortcuts still work while a control has keyboard focus", !AppDelegate.focusedControlKeepsKey(findNext, responder: NSButton()))
        }
        let standard: [(Selector, String, NSEvent.ModifierFlags)] = [
            (Selector(("undo:")), "z", .command), (Selector(("redo:")), "z", [.command, .shift]),
            (#selector(NSText.copy(_:)), "c", .command), (#selector(NSText.selectAll(_:)), "a", .command)
        ]
        let menuItems: [NSMenuItem] = NSApp.mainMenu?.items.flatMap { (parent: NSMenuItem) -> [NSMenuItem] in parent.submenu?.items ?? [] } ?? []
        for (action, key, modifiers) in standard {
            check("native standard shortcut: \(action)", menuItems.contains { $0.action == action && $0.keyEquivalent == key && $0.keyEquivalentModifierMask == modifiers })
        }
        for title in ["Keep Suggestion", "Dismiss Suggestion", "Keep All Suggestions", "Rename Clip…", "Remove Clip", "Export Clip…"] {
            check("native Clip menu includes \(title)", item("Clip", title) != nil)
        }
        check("menus retain document Duplicate and hide unsupported insertion", item("File", "Duplicate") != nil && item("Edit", "Insert Words…") == nil)
        check("menus expose three-second playback actions", item("Playback", "Back 3 Seconds")?.keyEquivalent == "j" && item("Playback", "Forward 3 Seconds") != nil)
        check("Help keeps the tour and removes obsolete workspaces", item("Help", AppDelegate.tourTitle) != nil && item("Help", "Workspace Tour") == nil && item("View", "Transcript") == nil && item("View", "Clips") == nil && item("View", "Show Caption Inspector") == nil)
        let previousDocument = app.shell.document
        let previousSelection = app.shell.selection
        let previousVoiceLab = app.bool("voiceLab.enabled")
        let commandWindow = app.shell.windowController?.window
        let previousContent = commandWindow?.contentViewController
        commandWindow?.contentViewController = NSViewController()
        defer { commandWindow?.contentViewController = previousContent }
        let project = try DebugExplorer.fiveQuestions(from: fixture)
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
        // View › Frame (impl-plan V4): the Frame picker left the viewer.
        if let frameMenu = item("View", "Frame")?.submenu {
            check("View › Frame lists 9:16, 1:1, 16:9 and Original", frameMenu.items.map(\.title) == ["9:16", "1:1", "16:9", "Original"])
            let aspect = editor.project.export.aspect, steps = editor.undoSteps
            if let square = frameMenu.item(withTitle: "1:1"), let action = square.action { _ = delegate.perform(action, with: square) }
            let states = frameMenu.items.map { entry -> NSControl.StateValue in _ = delegate.validateMenuItem(entry); return entry.state }
            check("View › Frame › 1:1 sets the frame as one undo step and checks it (\(states))",
                  editor.project.export.aspect == .square && editor.undoSteps == steps + 1 && states == [.off, .on, .off, .off])
            editor.setAspect(aspect)
        } else { check("View › Frame exists", false) }
        // The viewer's Back 3 s button is gone (impl-plan V4): chosen from the menu, Back 3 Seconds
        // works outside the transcript, as Forward 3 Seconds does; the J key keeps its routing.
        if let back = item("Playback", "Back 3 Seconds"), let forward = item("Playback", "Forward 3 Seconds") {
            let resolved = editor.mediaResolved, responder = window.firstResponder
            editor.mediaResolved = true
            _ = window.makeFirstResponder(nil)
            check("Back 3 Seconds is on from the menu outside the transcript, as Forward 3 Seconds is",
                  delegate.validateMenuItem(back) && delegate.validateMenuItem(forward))
            editor.mediaResolved = resolved
            _ = window.makeFirstResponder(responder)
        } else { check("Playback has Back 3 Seconds and Forward 3 Seconds", false) }
        guard let first = editor.words.first, let kept = editor.keptClips.first, let suggestion = editor.suggestedClips.first else { throw CocoaError(.coderInvalidValue) }
        editor.selectedWordIDs = [first.id]
        invoke("Clip", "Find Clips…")
        check("Clip › Find Clips… (⇧⌘K, tag 34) opens Find Clips at the clip bar", editor.showFindClips && editor.findClipsAnchor == .clipBar)
        editor.showFindClips = false
        // Edit › Rewrite {scope} (impl-plan V13, design.md §8): no Voice Lab needed, titled for the scope, and it runs at
        // once. A stub on this Mac answers; the settings are put back.
        let rewriteKeys = ["llm.connector", "llm.model.ollama"]
        let savedRewrite = rewriteKeys.map { app.settings.values[$0] }, savedOverride = app.connectorOverride
        app.settings.values["llm.connector"] = .string("ollama")
        app.settings.values["llm.model.ollama"] = .string("fixture-local")
        let stub = ConsentFixtureConnector(id: .ollama)
        app.connectorOverride = { _ in stub }
        app.set("voiceLab.enabled", .bool(false))
        let rewriteItem = NSApp.mainMenu?.item(withTitle: "Edit")?.submenu?.item(withTag: 38)
        let validated = rewriteItem.map(delegate.validateMenuItem) == true
        results.append(.equal("Edit › Rewrite needs no Voice Lab and names the selection", expected: [
            "item exists": "true", "hidden": "false", "validated": "true", "title": "Rewrite Selection"
        ], actual: [
            "item exists": "\(rewriteItem != nil)", "hidden": "\(rewriteItem?.isHidden == true)", "validated": "\(validated)", "title": rewriteItem?.title ?? ""
        ]))
        if let rewriteItem, let action = rewriteItem.action { _ = delegate.perform(action, with: rewriteItem) }
        await editor.rewriteOpenTask?.value
        await editor.openRewrite?.actionTask?.value
        let proposed = if case .proposal = editor.openRewrite?.task.state { true } else { false }
        results.append(.equal("Shift-Command-R runs Rewrite on the selected words at once", expected: [
            "Rewrite opened": true, "selection scope": true, "proposed": true, "sends": true
        ], actual: [
            "Rewrite opened": editor.rewrite != nil, "selection scope": editor.rewriteScope == .selection(0...0), "proposed": proposed, "sends": await stub.sends == 1
        ]))
        editor.closeRewrite(returnFocus: false)
        editor.selectedWordIDs = []
        app.shell.selection = .clip(kept.id)
        let clipTitle = rewriteItem.map { _ = delegate.validateMenuItem($0); return $0.title }
        app.shell.selection = .fullTake
        let takeTitle = rewriteItem.map { _ = delegate.validateMenuItem($0); return $0.title }
        check("Edit › Rewrite follows the scope (\(clipTitle ?? ""), \(takeTitle ?? ""))", clipTitle == "Rewrite Clip 1" && takeTitle == "Rewrite Full Take")
        app.connectorOverride = savedOverride
        for (key, value) in zip(rewriteKeys, savedRewrite) { app.settings.values[key] = value }
        app.set("voiceLab.enabled", .bool(true))
        editor.selectedWordIDs = [first.id]
        check("Insert Words stays hidden until Core can place insertions", item("Edit", "Insert Words…") == nil)
        editor.closeRewrite(returnFocus: false)
        app.shell.selection = .clip(suggestion.id)
        check("suggestion menu validation enables Keep and disables Rename", item("Clip", "Keep Suggestion").map(delegate.validateMenuItem) == true && item("Clip", "Rename Clip…").map(delegate.validateMenuItem) == false)
        app.shell.selection = .clip(kept.id)
        check("kept clip menu validation enables Rename and disables Keep", item("Clip", "Rename Clip…").map(delegate.validateMenuItem) == true && item("Clip", "Keep Suggestion").map(delegate.validateMenuItem) == false)
        invoke("Clip", "Rename Clip…")
        check("Rename Clip uses the sidebar's native inline rename", app.shell.renaming == kept.id)
        app.shell.endRename(keep: false)
        check("Cancel Finding Clips is disabled while no clip search runs", item("Clip", "Cancel Finding Clips").map(delegate.validateMenuItem) == false)
        let search = Task<Void, Never> { while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) } }
        editor.finding = true; editor.findTask = search
        check("Cancel Finding Clips is enabled while a clip search runs", item("Clip", "Cancel Finding Clips").map(delegate.validateMenuItem) == true)
        invoke("Clip", "Cancel Finding Clips")
        check("Command-period cancels the running clip search", search.isCancelled)
        editor.finding = false; editor.findTask = nil
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            try await DebugUISuite.snapshot(DirectorVoiceSteps(session: app.voiceLabSession, model: editor), name: "voice-job-first-use-\(name)", size: NSSize(width: 404, height: 600), appearance: appearance, directory: directory)
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
