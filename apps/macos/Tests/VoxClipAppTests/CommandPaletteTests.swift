#if DEBUG
import AppKit
import Testing
@testable import VoxClipCore
@testable import VoxClip

@MainActor private final class PaletteTarget: NSObject, NSMenuItemValidation {
    var allowed = true
    var validations = 0
    var runs = 0
    @objc func execute(_ sender: Any?) { runs += 1 }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { validations += 1; return allowed }
}

@MainActor private final class LazyPaletteMenu: NSObject, NSMenuDelegate {
    let item: NSMenuItem
    var updates = 0
    init(item: NSMenuItem) { self.item = item }
    func menuNeedsUpdate(_ menu: NSMenu) { updates += 1; item.isHidden = false }
}

@Suite("Command field", .serialized)
@MainActor struct CommandPaletteTests {
    init() { _ = NSApplication.shared }
    private func menu(_ target: PaletteTarget) -> NSMenu {
        let root = NSMenu(), parent = NSMenuItem(title: "Clip", action: nil, keyEquivalent: "")
        let commands = NSMenu(title: "Clip"); parent.submenu = commands; root.addItem(parent)
        let item = NSMenuItem(title: "Make Clip from Selection", action: #selector(PaletteTarget.execute(_:)), keyEquivalent: "k")
        item.keyEquivalentModifierMask = [.command, .option]; item.target = target; commands.addItem(item)
        let hidden = NSMenuItem(title: "Hidden voice command", action: item.action, keyEquivalent: "")
        hidden.target = target; hidden.isHidden = true; commands.addItem(hidden)
        commands.addItem(.separator())
        return root
    }
    @Test func indexValidatesOnlyAndDispatchRevalidates() throws {
        let target = PaletteTarget(), menu = menu(target)
        let commands = MenuCommandIndex.items(in: menu)
        #expect(commands.count == 1 && target.validations == 1 && target.runs == 0)
        let item = try #require(commands.first)
        #expect(item.shortcut == "⌥⌘K" && item.path == "Clip")
        #expect(MenuCommandIndex.matching("clip selection", in: commands).count == 1)
        #expect(MenuCommandIndex.matching("voice", in: commands).isEmpty)
        target.allowed = false
        #expect(MenuCommandIndex.items(in: menu).isEmpty && target.runs == 0)
        #expect(!MenuCommandIndex.run(item) && target.runs == 0)
        target.allowed = true
        #expect(MenuCommandIndex.run(item) && target.runs == 1)
    }
    @Test func indexRefreshesLazyMenusWithoutExecuting() throws {
        let target = PaletteTarget(), menu = menu(target)
        let submenu = try #require(menu.items.first?.submenu)
        let item = try #require(submenu.items.first)
        item.isHidden = true
        let delegate = LazyPaletteMenu(item: item); submenu.delegate = delegate
        let commands = MenuCommandIndex.items(in: menu)
        #expect(delegate.updates == 1 && commands.count == 1 && target.runs == 0)
    }
    @Test func comboBoxReportsResultsAndReturnAndEscapeWork() {
        let target = PaletteTarget(), old = NSApp.mainMenu
        NSApp.mainMenu = menu(target); defer { NSApp.mainMenu = old }
        let view = CommandPaletteView(); var closes = 0
        view.onClose = { closes += 1 }; view.open()
        #expect(view.field.accessibilityRole() == .comboBox && view.field.isAccessibilityExpanded() == true)
        #expect(view.count.stringValue == "1 result" && view.field.accessibilityHelp()?.contains("1 result") == true)
        view.field.stringValue = "unmatched"; view.filter()
        #expect(view.results.isEmpty && view.count.stringValue == "0 results")
        view.field.stringValue = "make clip"; view.filter()
        #expect(view.control(view.field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(target.runs == 1 && closes == 1)
        #expect(view.control(view.field, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(closes == 2 && target.runs == 1)
    }
    @Test func remappedNativeCommandsAndDeletedSheetStayConsistent() throws {
        let old = NSApp.mainMenu; defer { NSApp.mainMenu = old }
        let delegate = AppDelegate(); delegate.installMenus()
        func all(_ menu: NSMenu) -> [NSMenuItem] { menu.items.flatMap { [$0] + ($0.submenu.map(all) ?? []) } }
        let main = try #require(NSApp.mainMenu)
        let items = all(main)
        for result in DebugMenus.shortcutChecks(in: main) { #expect(result.passed, "\(result.name)") }
        #expect(items.first { $0.tag == 61 }?.keyEquivalent == "k")
        #expect(items.first { $0.tag == 61 }?.keyEquivalentModifierMask == .command)
        #expect(items.first { $0.tag == 29 }?.keyEquivalentModifierMask == [.command, .option])
        let app = AppModel.sharedModel
        let prior = app.settings.values["voiceLab.enabled"]
        defer { app.settings.values["voiceLab.enabled"] = prior }
        app.settings.values["voiceLab.enabled"] = .bool(false)
        #expect(!MenuCommandIndex.items().contains { $0.menuItem.tag == 38 || $0.title.contains("Voice Lab") })
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let editor = try String(contentsOf: root.appendingPathComponent("Sources/VoxClip/EditorView.swift"), encoding: .utf8)
        let home = try String(contentsOf: root.appendingPathComponent("Sources/VoxClip/HomeView.swift"), encoding: .utf8)
        #expect(!editor.contains("showShortcuts") && !home.contains("ShortcutsView") && !home.contains("NSAlert"))
    }
    @Test func transcriptSeparatesCommandFieldMakeClipAndFindClips() throws {
        let resources = try SharedResources.locate()
        let project = try JSONProjectStore.decode(Data(contentsOf: resources.root.appendingPathComponent("fixtures/projects/interview-take.voxclip")))
        let app = AppModel(settingsStore: RegressionSettingsStore())
        let editor = EditorModel(document: VoxClipDocument(project: project, demo: true), app: app, preview: DemoPreviewEngine())
        defer { editor.close() }
        editor.mediaResolved = true
        editor.selectedWordIDs = Set(editor.words.prefix(3).map(\.id))
        let text = TranscriptNSTextView(usingTextLayoutManager: true); text.model = editor
        func key(_ flags: NSEvent.ModifierFlags) throws {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, characters: "k", charactersIgnoringModifiers: "k", isARepeat: false, keyCode: 40))
            text.keyDown(with: event)
        }
        let clips = editor.keptClips.count
        try key(.command)
        #expect(app.shell.showCommandPalette && editor.keptClips.count == clips && !editor.showFindClips)
        app.shell.showCommandPalette = false
        try key([.command, .option])
        #expect(!app.shell.showCommandPalette && editor.keptClips.count == clips + 1)
        try key([.command, .shift])
        #expect(editor.showFindClips && editor.keptClips.count == clips + 1)
    }

    @Test func productionOverlayFitsTheShellAndRestoresFocusOnTableReturn() async throws {
        let old = NSApp.mainMenu; defer { NSApp.mainMenu = old }
        let target = PaletteTarget(); NSApp.mainMenu = menu(target)
        let shell = WorkspaceShell(app: AppModel(settingsStore: RegressionSettingsStore()))
        let controller = EditorShellController(shell: shell)
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 640, height: 480), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false; window.contentView = controller.view
        controller.view.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        controller.apply(EditorShellState(shell: shell))
        defer { controller.tearDown(); window.close() }
        let original = controller.homeSearch
        window.makeFirstResponder(original)
        shell.showCommandPalette = true
        // Observation schedules shell updates on the next actor turn, without showing a window.
        for _ in 0..<20 where controller.commandPalette == nil { await Task.yield() }
        let palette = try #require(controller.commandPalette)
        controller.view.layoutSubtreeIfNeeded()
        #expect(controller.view.bounds.contains(palette.frame) && palette.frame.minY == ShellMetrics.titleRow)
        #expect(palette.field.currentEditor() != nil)
        #expect(!window.isVisible && target.runs == 0)
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        palette.table.keyDown(with: event)
        #expect(target.runs == 1 && !shell.showCommandPalette)
        #expect(window.firstResponder === original || window.firstResponder === original.currentEditor())
    }

    @Test func commandFieldBelongsToTheKeyVersionsWindow() throws {
        let resources = try SharedResources.locate()
        let project = try JSONProjectStore.decode(Data(contentsOf: resources.root.appendingPathComponent("fixtures/projects/interview-take.voxclip")))
        let document = VoxClipDocument(project: project, demo: true); document.versionForTesting = true
        let app = AppModel(settingsStore: RegressionSettingsStore())
        let controller = VersionWindowController(version: document, app: app)
        defer { controller.window?.close(); document.close() }
        let delegate = AppDelegate(); delegate.commandWindowForTesting = controller.window
        defer { delegate.commandWindowForTesting = nil }
        let item = NSMenuItem(title: "Search or Run a Command…", action: NSSelectorFromString("performEditorCommand:"), keyEquivalent: "k"); item.tag = 61
        _ = delegate.perform(NSSelectorFromString("performEditorCommand:"), with: item)
        #expect(controller.shell.showCommandPalette && !app.shell.showCommandPalette)
        controller.shell.showCommandPalette = false
        let text = TranscriptNSTextView(usingTextLayoutManager: true)
        let editor = try #require(controller.shell.editor)
        text.model = editor
        controller.window?.contentView?.addSubview(text)
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil, characters: "k", charactersIgnoringModifiers: "k", isARepeat: false, keyCode: 40))
        text.keyDown(with: event)
        #expect(controller.shell.showCommandPalette && !app.shell.showCommandPalette)
        #expect(controller.window?.isVisible == false && !document.isDocumentEdited)
    }

}
#endif
