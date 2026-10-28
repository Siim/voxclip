import AppKit
import SwiftUI
import VoxClipCore

@main @MainActor enum VoxClipMain {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        _ = NSDocumentController.shared
        application.run()
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSMenuDelegate {
    private let model = AppModel.sharedModel
    private var bufferedURLs: [URL] = []
    private var settingsWindow: NSWindow?
    private var terminating = false
    private var routingReady = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if AppModel.isTestSession && !CommandLine.arguments.contains("-sceneAudit") && !CommandLine.arguments.contains("-saveBoundaryAudit") && !CommandLine.arguments.contains("-settingsAudit") && !CommandLine.arguments.contains("-voiceRecipeAudit") { NSApp.setActivationPolicy(.prohibited) }
        #endif
        installMenus()
        model.fileRouter.installMovieOpener { [weak self] url in
            guard let self else { return }
            openMovie(url, app: self.model)
        }
        routingReady = true
        model.fileRouter.receive(bufferedURLs)
        bufferedURLs.removeAll()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if let index = CommandLine.arguments.firstIndex(where: { ["-round4SelfTest", "-round5SelfTest"].contains($0) }), index + 1 < CommandLine.arguments.count {
            let directory = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            Task { await model.start(); await DebugRound4.run(app: model, directory: directory) }
            return
        }
        #endif
        model.launch()
        // One app-owned main window, opening on Home (ADR-R29). Projects and movies
        // opened at launch attach to it through the file router.
        #if DEBUG
        if CommandLine.arguments.contains("-uiSelfTest") || CommandLine.arguments.contains("-timelineAudit") {
            MainWindowController.shared.window?.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        }
        #endif
        MainWindowController.shared.show()
        #if DEBUG
        // Crash recovery and accent checks from a bundle.sh build (DebugProbes).
        if !AppModel.isTestSession, DebugProbes.requested { Task { await DebugProbes.run(app: model) } }
        if !AppModel.isTestSession, let index = CommandLine.arguments.firstIndex(of: "-demoProject"), index + 1 < CommandLine.arguments.count {
            Task {
                do {
                    let document = VoxClipDocument(project: try DemoEditing.loadFixture(URL(fileURLWithPath: CommandLine.arguments[index + 1])), demo: true)
                    NSDocumentController.shared.addDocument(document)
                    if !(await model.shell.replaceProject(with: document)) { document.close() }
                } catch { model.shell.notice = await model.safeError(error) }
            }
        }
        if AppModel.isTestSession {
            Task {
                await model.start()
                if let position = CommandLine.arguments.firstIndex(of: "-voiceRecipeAudit"), position + 1 < CommandLine.arguments.count {
                    await DebugVoiceRecipe.run(app: model, destination: URL(fileURLWithPath: CommandLine.arguments[position + 1]))
                } else if CommandLine.arguments.contains("-uiSelfTest") { await DebugUISuite.run(app: model) }
                else if let position = CommandLine.arguments.firstIndex(of: "-timelineAudit"), position + 1 < CommandLine.arguments.count {
                    await DebugTimeline.audit(app: model, directory: URL(fileURLWithPath: CommandLine.arguments[position + 1]))
                }
                else if let position = CommandLine.arguments.firstIndex(of: "-sceneAudit"), position + 1 < CommandLine.arguments.count {
                    await DebugUISuite.sceneAudit(app: model, destination: URL(fileURLWithPath: CommandLine.arguments[position + 1]))
                } else if let position = CommandLine.arguments.firstIndex(of: "-saveBoundaryAudit"), position + 1 < CommandLine.arguments.count {
                    await DebugUISuite.saveBoundaryAudit(app: model, destination: URL(fileURLWithPath: CommandLine.arguments[position + 1]))
                } else if let position = CommandLine.arguments.firstIndex(of: "-settingsAudit"), position + 1 < CommandLine.arguments.count {
                    await DebugUISuite.settingsAudit(app: model, destination: URL(fileURLWithPath: CommandLine.arguments[position + 1]))
                } else if let position = CommandLine.arguments.firstIndex(of: "-uiPerformanceTest"), position + 1 < CommandLine.arguments.count {
                    DebugUISuite.performance(app: model, destination: URL(fileURLWithPath: CommandLine.arguments[position + 1]))
                } else if let position = CommandLine.arguments.firstIndex(of: "-demoCapture"), position + 1 < CommandLine.arguments.count {
                    await DebugUISuite.captureDemo(app: model, destination: URL(fileURLWithPath: CommandLine.arguments[position + 1]))
                }
            }
        }
        #endif
    }
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }
    /// The Dock icon brings the main window back, also while Settings is open.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        let window = MainWindowController.shared.window
        if window?.isVisible != true || window?.isMiniaturized == true { MainWindowController.shared.show() }
        return false
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        if routingReady { model.fileRouter.receive(urls) }
        else { bufferedURLs.append(contentsOf: urls) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    /// Crash recovery restores the main window from secure-coded state (design §2).
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        terminating = true
        // A clip title still being typed is kept before the documents are reviewed.
        model.shell.endRename()
        Task { @MainActor in
            let documents = NSDocumentController.shared.documents.compactMap { $0 as? VoxClipDocument }
            for document in documents { await document.pendingTitleWrite?.value }
            NSDocumentController.shared.reviewUnsavedDocuments(withAlertTitle: "Quit VoxClip?", cancellable: true, delegate: self, didReviewAllSelector: #selector(reviewedDocuments(_:didReviewAll:contextInfo:)), contextInfo: nil)
        }
        return .terminateLater
    }
    @objc private func reviewedDocuments(_ controller: NSDocumentController, didReviewAll: Bool, contextInfo: UnsafeMutableRawPointer?) {
        guard didReviewAll else { terminating = false; NSApp.reply(toApplicationShouldTerminate: false); return }
        Task { await model.flushSettings(); NSApp.reply(toApplicationShouldTerminate: true) }
    }
    func applicationWillTerminate(_ notification: Notification) { model.modelLibrary.task?.cancel() }

    #if DEBUG
    weak var commandWindowForTesting: NSWindow?
    #endif
    private var mainWindowIsKey: Bool {
        #if DEBUG
        if let commandWindowForTesting { return commandWindowForTesting === model.shell.windowController?.window }
        #endif
        return NSApp.keyWindow != nil && NSApp.keyWindow === model.shell.windowController?.window
    }
    /// The editor, while it is showing in the key main window.
    private var editor: EditorModel? {
        guard mainWindowIsKey, !model.shell.showsHome else { return nil }
        return model.shell.editor
    }
    @objc private func newProject(_ sender: Any?) { chooseFile(app: model, moviesOnly: true) }
    @objc private func openProject(_ sender: Any?) { chooseFile(app: model) }
    /// ⌘W closes the project and shows Home; on Home it closes the window (design §11).
    @objc private func closeProject(_ sender: Any?) {
        guard mainWindowIsKey else { NSApp.keyWindow?.performClose(sender); return }
        if model.shell.document != nil { Task { await model.shell.closeProject() } }
        else { model.shell.windowController?.window?.performClose(sender) }
    }
    @objc private func showMainWindow(_ sender: Any?) { MainWindowController.shared.show() }
    @objc private func openRecent(_ item: NSMenuItem) {
        if let url = item.representedObject as? URL { openFile(url, app: model) }
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        model.recentProjects.refresh(model.recent)
        for url in model.recent {
            let item = NSMenuItem(title: model.recentTitle(url), action: #selector(openRecent(_:)), keyEquivalent: "")
            item.representedObject = url
            item.target = self
            menu.addItem(item)
        }
        if menu.items.isEmpty {
            let empty = NSMenuItem(title: "No Recent Projects", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
    }
    @objc private func exportProject(_ sender: Any?) { editor?.presentExport() }
    @objc private func revealMedia(_ sender: Any?) { if let url = editor?.sourceURL { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
    @objc private func settings(_ sender: Any?) { openSettings() }
    func openSettings() {
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView().environment(model).sceneAccent())
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 620), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.title = "VoxClip Settings"
            window.setAccessibilityIdentifier("voxclip.settings")
            window.contentViewController = host
            window.toolbarStyle = .expanded
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    #if DEBUG
    var settingsWindowForTests: NSWindow? { settingsWindow }
    #endif
    @objc private func performEditorCommand(_ item: NSMenuItem) {
        let shell = model.shell
        switch item.tag {
        case 13: shell.selection = .home; return
        case 14: if shell.document != nil { shell.selection = .fullTake }; return
        case 16: shell.toggleSidebar(); return
        // Help works on Home and with no project open; both sheets belong to the main window.
        case 35: MainWindowController.shared.show(); shell.showShortcuts = true; return
        case 36: MainWindowController.shared.show(); model.showTour = true; return
        default: break
        }
        guard let editor, validateMenuItem(item) else { return }
        switch item.tag {
        case 1:
            if NSApp.currentEvent?.type == .keyDown { editor.toggleSelectionCut() }
            else { editor.cutSelection() }
        case 2: editor.cutSelection(restore: true)
        case 3: editor.beginCorrection()
        case 4: editor.findVisible = true
        case 5: editor.findNext()
        case 6: editor.findNext(backward: true)
        case 7: editor.apply(.cutFillers, name: "Cut fillers")
        case 8: editor.apply(.tightenPauses, name: "Tighten pauses")
        case 9: editor.apply(.restoreCuts, name: "Restore cuts")
        case 10: editor.showCuts.toggle()
        case 11: editor.showPauses.toggle()
        case 12: model.shell.toggleViewer()
        case 17: editor.editedTimeline.toggle()
        case 18: editor.zoom(1)
        case 19: editor.zoom(-1)
        case 20: editor.zoom(0)
        case 21: editor.transport(" ")
        case 22: editor.transport(" ", shift: true)
        case 23: editor.transport("p")
        case 24: editor.transport("j")
        case 25: editor.transport("k")
        case 26: editor.transport("l")
        case 27: editor.seek(source: 0)
        case 28: editor.seek(source: editor.sourceDuration)
        case 29: editor.makeClip()
        case 30: editor.setClipEdge(start: true)
        case 31: editor.setClipEdge(start: false)
        case 32: editor.moveClip(-1)
        case 33: editor.moveClip(1)
        case 34: editor.requestFindClips(from: .toolbar)
        case 37: confirmRetranscription()
        case 38: editor.beginRewrite(entry: .menu)
        case 39: editor.beginRewrite(inserting: true)
        case 40: if let id = selectedClipID { editor.keep(id) }
        case 41: if let id = selectedClipID { editor.dismiss(id) }
        case 42: editor.keepAll()
        case 43: if let id = selectedClipID { shell.beginRename(id) }
        case 44: if let id = selectedClipID { editor.removeClip(id) }
        case 45: if let id = selectedClipID { editor.presentExport(clipIDs: [id]) }
        case 46: editor.seek(source: max(0, editor.sourceTime - 3))
        case 47: editor.seek(source: min(editor.sourceDuration, editor.sourceTime + 3))
        case 48: editor.copySelection()
        default: break
        }
    }
    private var selectedClipID: String? {
        guard case .clip(let id) = model.shell.selection else { return nil }
        return id
    }
    @objc private func checkUpdates(_ sender: Any?) {
        if let url = model.update?.htmlURL, url.host == "github.com" { NSWorkspace.shared.open(url) }
        else { Task { await model.checkUpdates(manual: true) } }
    }
    @objc private func privacy(_ sender: Any?) {
        let alert = NSAlert(); alert.messageText = "What Leaves This Mac"; alert.informativeText = privacyCopy; alert.runModal()
    }
    @objc private func revealLogs(_ sender: Any?) { model.revealLogs() }
    @objc private func copyDiagnostics(_ sender: Any?) { Task { copyText(await model.diagnostics()) } }
    private func confirmRetranscription() {
        guard let editor else { return }
        let alert = NSAlert()
        alert.messageText = "Transcribe again?"
        alert.informativeText = Self.retranscriptionWarning(for: editor.project)
        alert.addButton(withTitle: "Transcribe Again")
        alert.addButton(withTitle: "Cancel")
        if let window = editor.window {
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn { editor.showTranscribe = true }
            }
        } else if alert.runModal() == .alertFirstButtonReturn {
            editor.showTranscribe = true
        }
    }
    static func retranscriptionWarning(for project: Project) -> String {
        let edits = project.edits
        return "This replaces the transcript and removes \(edits.cutWordIds.count + edits.cutPauseIds.count) cuts, \(edits.corrections.count) corrections, \(edits.clips.count) clips and the AI suggestions."
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(checkUpdates(_:)) {
            item.title = model.update.map { "VoxClip \($0.version) Available…" } ?? "Check for Updates…"
        }
        if item.action == #selector(closeProject(_:)) {
            item.title = mainWindowIsKey && model.shell.document != nil ? "Close Project" : "Close"
            return NSApp.keyWindow != nil
        }
        if item.action == #selector(performEditorCommand(_:)) {
            switch item.tag {
            case 13: return mainWindowIsKey
            case 14: return mainWindowIsKey && model.shell.document != nil
            case 16:
                item.title = model.shell.sidebarShown ? "Hide Sidebar" : "Show Sidebar"
                return mainWindowIsKey
            case 35, 36: return true
            default: break
            }
            guard let editor else { return false }
            if editor.mutationEnabled(item.tag) == false { return false }
            if NSApp.currentEvent?.type == .keyDown, [40, 41, 43, 44].contains(item.tag) {
                guard editor.focusedPane == .sidebar, model.shell.renaming == nil else { return false }
                if let input = NSApp.keyWindow?.firstResponder as? any NSTextInputClient, input.hasMarkedText() { return false }
            }
            if [1, 2, 3, 21, 22, 23, 24, 25, 26, 29, 30, 31, 32, 33, 38, 46].contains(item.tag) {
                guard editor.correctionID == nil else { return false }
                let responder = NSApp.keyWindow?.firstResponder
                if let input = responder as? any NSTextInputClient, input.hasMarkedText() { return false }
                if responder is NSTextView && !(responder is TranscriptNSTextView) { return false }
                if responder is NSTextField { return false }
                if responder is NSTableView && ![32, 33].contains(item.tag) { return false }
            }
            switch item.tag {
            case 1, 3, 29: return editor.capabilities.edit && !editor.selectedIDs.isEmpty
            case 38: return RewriteEntryPolicy.resolve(.menu, enabled: model.bool("voiceLab.enabled"), editable: editor.capabilities.ai, selection: !editor.selectedIDs.isEmpty) != .unavailable
            case 39: return false
            case 48: return !editor.selectedIDs.isEmpty
            case 2: return editor.capabilities.edit && (!editor.selectedWordIDs.isDisjoint(with: editor.cutWordIDs) || !editor.selectedPauseIDs.isDisjoint(with: editor.cutPauseIDs))
            case 40, 41: return editor.capabilities.edit && selectedClipID.map(editor.isSuggestion) == true
            case 42: return editor.capabilities.edit && !editor.suggestedClips.isEmpty
            case 43, 44: return selectedClipID.map { !editor.isSuggestion($0) } == true && editor.capabilities.edit
            case 45: return selectedClipID.map { !editor.isSuggestion($0) } == true && editor.canExport && editor.mediaExportable
            case 46: return editor.mediaResolved && NSApp.keyWindow?.firstResponder is TranscriptNSTextView
            case 47: return editor.mediaResolved
            case 7: return editor.capabilities.edit && editor.summary.canCutFillers
            case 8: return editor.capabilities.edit && editor.summary.canTighten
            case 9: return editor.capabilities.edit && editor.summary.hasEdits
            case 30, 31: return editor.capabilities.edit && editor.activeClip != nil
            case 34: return editor.capabilities.ai && !editor.words.isEmpty
            case 10: item.title = editor.showCuts ? "Hide Cut Words" : "Show Cut Words"
            case 11: item.title = editor.showPauses ? "Hide Pauses" : "Show Pauses"
            case 12: item.title = model.shell.viewerVisible ? "Hide Viewer" : "Show Viewer"
            default: return true
            }
        }
        if item.action == #selector(exportProject(_:)) { return editor.map { $0.canExport && $0.exportUnavailable == nil } ?? false }
        if item.action == #selector(revealMedia(_:)) { return editor != nil }
        return true
    }
    private func installMenus() {
        let main = NSMenu()
        NSApp.mainMenu = main
        func menu(_ title: String) -> NSMenu {
            let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let result = NSMenu(title: title)
            parent.submenu = result
            main.addItem(parent)
            return result
        }
        func add(_ menu: NSMenu, _ title: String, _ action: Selector?, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = [.command], tag: Int = 0, target: AnyObject? = nil) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.tag = tag
            item.target = target
            menu.addItem(item)
        }
        func command(_ menu: NSMenu, _ title: String, _ tag: Int, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = [.command]) {
            add(menu, title, #selector(performEditorCommand(_:)), key, modifiers, tag: tag, target: self)
        }
        let app = menu("VoxClip")
        add(app, "About VoxClip", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), target: NSApp)
        add(app, "Check for Updates…", #selector(checkUpdates(_:)), target: self)
        app.addItem(.separator())
        add(app, "Settings…", #selector(settings(_:)), ",", target: self)
        app.addItem(.separator())
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        services.submenu = NSMenu(title: "Services"); app.addItem(services); NSApp.servicesMenu = services.submenu
        app.addItem(.separator())
        add(app, "Hide VoxClip", #selector(NSApplication.hide(_:)), "h", target: NSApp)
        add(app, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option], target: NSApp)
        add(app, "Show All", #selector(NSApplication.unhideAllApplications(_:)), target: NSApp)
        app.addItem(.separator())
        add(app, "Quit VoxClip", #selector(NSApplication.terminate(_:)), "q", target: NSApp)
        let file = menu("File")
        add(file, "New Project from Video…", #selector(newProject(_:)), "n", target: self)
        add(file, "Open…", #selector(openProject(_:)), "o", target: self)
        let recent = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu(title: "Open Recent")
        recentMenu.delegate = self
        recent.submenu = recentMenu
        file.addItem(recent)
        file.addItem(.separator())
        add(file, "Close Project", #selector(closeProject(_:)), "w", target: self)
        add(file, "Save", #selector(NSDocument.save(_:)), "s")
        add(file, "Save As…", #selector(NSDocument.saveAs(_:)), "s", [.command, .shift])
        add(file, "Duplicate", #selector(NSDocument.duplicate(_:)))
        add(file, "Move To…", #selector(NSDocument.move(_:)))
        add(file, "Rename…", #selector(NSDocument.rename(_:)))
        add(file, "Revert to Saved…", #selector(NSDocument.revertToSaved(_:)))
        file.addItem(.separator())
        add(file, "Export…", #selector(exportProject(_:)), "e", target: self)
        add(file, "Reveal Media in Finder", #selector(revealMedia(_:)), target: self)
        let edit = menu("Edit")
        add(edit, "Undo", Selector(("undo:")), "z")
        add(edit, "Redo", Selector(("redo:")), "z", [.command, .shift])
        edit.addItem(.separator())
        add(edit, "Cut", #selector(NSText.cut(_:)), "x")
        add(edit, "Copy", #selector(NSText.copy(_:)), "c")
        add(edit, "Paste", #selector(NSText.paste(_:)), "v")
        add(edit, "Select All", #selector(NSText.selectAll(_:)), "a")
        edit.addItem(.separator())
        command(edit, "Cut Selection", 1, String(UnicodeScalar(NSDeleteCharacter)!), [])
        command(edit, "Restore Selection", 2, String(UnicodeScalar(NSDeleteCharacter)!), [.shift])
        command(edit, "Correct Word", 3, "c", [])
        if RewriteEntryPolicy.buildEnabled { command(edit, "Rewrite…", 38, "r", [.command, .shift]) }
        command(edit, "Copy Text", 48)
        command(edit, "Find…", 4, "f")
        command(edit, "Find Next", 5, "g")
        command(edit, "Find Previous", 6, "g", [.command, .shift])
        command(edit, "Cut Fillers", 7, "u", [.command, .option])
        command(edit, "Tighten Pauses", 8, "p", [.command, .option])
        command(edit, "Restore All Cuts", 9, "r", [.command, .option])
        command(edit, "Transcribe Again…", 37)
        let view = menu("View")
        command(view, "Show Cut Words", 10, "h", [.command, .shift])
        command(view, "Show Pauses", 11)
        command(view, "Hide Viewer", 12, "i", [.command, .option])
        command(view, "Home", 13, "1")
        command(view, "Full Take", 14, "2")
        command(view, "Hide Sidebar", 16, "s", [.command, .control])
        command(view, "Source / Edited Timeline", 17)
        command(view, "Bigger Text", 18, "+")
        command(view, "Smaller Text", 19, "-")
        command(view, "Actual Size", 20, "0")
        add(view, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])
        let playback = menu("Playback")
        command(playback, "Play/Pause", 21, " ", [])
        command(playback, "Play from Selection", 22, " ", [.shift])
        command(playback, "Preview Cut", 23, "p", [])
        command(playback, "Shuttle Back", 24, "j", [])
        command(playback, "Stop", 25, "k", [])
        command(playback, "Shuttle Forward", 26, "l", [])
        command(playback, "Go to Start", 27, String(UnicodeScalar(NSUpArrowFunctionKey)!), [.command])
        command(playback, "Go to End", 28, String(UnicodeScalar(NSDownArrowFunctionKey)!), [.command])
        command(playback, "Back 3 Seconds", 46, "j", [])
        command(playback, "Forward 3 Seconds", 47)
        let clip = menu("Clip")
        command(clip, "Make Clip from Selection", 29, "k")
        command(clip, "Find Clips…", 34, "k", [.command, .shift])
        command(clip, "Keep Suggestion", 40, String(UnicodeScalar(NSCarriageReturnCharacter)!), [])
        command(clip, "Dismiss Suggestion", 41, String(UnicodeScalar(NSDeleteCharacter)!), [])
        command(clip, "Keep All Suggestions", 42)
        command(clip, "Rename Clip…", 43, String(UnicodeScalar(NSCarriageReturnCharacter)!), [])
        command(clip, "Remove Clip", 44, String(UnicodeScalar(NSDeleteCharacter)!), [])
        command(clip, "Set Start", 30, "i", [])
        command(clip, "Set End", 31, "o", [])
        command(clip, "Previous Clip", 32, "[", [])
        command(clip, "Next Clip", 33, "]", [])
        command(clip, "Export Clip…", 45)
        let window = menu("Window")
        add(window, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        add(window, "Zoom", #selector(NSWindow.performZoom(_:)))
        add(window, "Toggle Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])
        window.addItem(.separator())
        add(window, "VoxClip", #selector(showMainWindow(_:)), target: self)
        window.addItem(.separator())
        NSApp.windowsMenu = window
        let help = menu("Help")
        command(help, "Keyboard Shortcuts", 35, "/")
        command(help, "Welcome Tour", 36)
        add(help, "What Leaves This Mac", #selector(privacy(_:)), target: self)
        add(help, "Reveal Logs", #selector(revealLogs(_:)), target: self)
        add(help, "Copy Diagnostics", #selector(copyDiagnostics(_:)), target: self)
    }
}

let privacyCopy = "On-device transcription, editing, captions and export stay on this Mac. Your chosen cloud transcription engine receives audio only. Your chosen AI connector receives transcript text only, no audio or video. Installed CLIs use your own sign-in. Model downloads and update checks contact their publishers. No telemetry. Posting is optional and never happens without your click."

@MainActor func openVoxClipSettings(pane: String? = nil) {
    if let pane { AppModel.sharedModel.settingsPane = pane }
    (NSApp.delegate as? AppDelegate)?.openSettings()
}

@MainActor func chooseFile(app: AppModel, projectsOnly: Bool = false, moviesOnly: Bool = false) {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = projectsOnly ? [.voxclipProject] : moviesOnly ? [.movie] : [.voxclipProject, .movie]
    panel.allowsMultipleSelection = false
    if panel.runModal() == .OK, let url = panel.url { openFile(url, app: app) }
}
@MainActor func openFile(_ url: URL, app: AppModel) { app.fileRouter.receive([url]) }
/// Imports a movie as a new project in the main window (ADR-R29).
@MainActor func openMovie(_ url: URL, app: AppModel) {
    Task { await app.shell.importVideo(url) }
}
@MainActor func importedDocument(_ url: URL, app: AppModel) async throws -> VoxClipDocument {
    await app.start()
    var project = try await VoxClipDocument(importing: url).project
    project.captions.styleId = app.string("captions.defaultStyleId", fallback: "vox-highlight")
    project.export = ProjectExport(aspect: AspectRatio(rawValue: app.string("export.defaultAspect", fallback: "source")) ?? .source, quality: ExportQuality(rawValue: app.string("export.quality", fallback: "standard")) ?? .standard, srt: app.bool("export.srt"), folder: nil)
    let breath = app.string("editing.pauseBreath", fallback: "natural")
    project.edits.pauseKeepSeconds = breath == "tight" ? 0.05 : breath == "relaxed" ? 0.3 : 0.15
    let document = VoxClipDocument(project: project)
    document.setMediaResolved(true)
    return document
}
@MainActor final class FileOpenRouter {
    private var bufferedMovies: [URL] = []
    private var movieOpener: ((URL) -> Void)?
    var projectOpener: (URL) -> Void = { url in
        Task { await AppModel.sharedModel.shell.openProject(at: url) }
    }
    func installMovieOpener(_ opener: @escaping (URL) -> Void) {
        movieOpener = opener
        let pending = bufferedMovies
        bufferedMovies.removeAll()
        pending.forEach(opener)
    }
    func receive(_ urls: [URL]) {
        for url in urls {
            if url.pathExtension.lowercased() == "voxclip" { projectOpener(url) }
            else if ["mov", "mp4", "m4v"].contains(url.pathExtension.lowercased()) {
                if let movieOpener { movieOpener(url) } else { bufferedMovies.append(url) }
            } else { AppModel.sharedModel.shell.notice = "VoxClip can't open \(url.pathExtension.uppercased()) files on Mac yet. Export the video as MP4 or MOV and try again." }
        }
    }
}
