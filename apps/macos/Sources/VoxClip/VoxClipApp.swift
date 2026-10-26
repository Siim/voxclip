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
    private var launchFinished = false
    private var openedExternalOnLaunch = false

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
        model.launch()
        launchFinished = true
        if !openedExternalOnLaunch && NSDocumentController.shared.documents.isEmpty { NSDocumentController.shared.newDocument(nil) }
        #if DEBUG
        if AppModel.isTestSession {
            Task {
                await model.start()
                if let position = CommandLine.arguments.firstIndex(of: "-voiceRecipeAudit"), position + 1 < CommandLine.arguments.count {
                    await DebugVoiceRecipe.run(app: model, destination: URL(fileURLWithPath: CommandLine.arguments[position + 1]))
                } else if CommandLine.arguments.contains("-uiSelfTest") { await DebugUISuite.run(app: model) }
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
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { NSDocumentController.shared.documents.isEmpty }
    func application(_ application: NSApplication, open urls: [URL]) {
        if !launchFinished { openedExternalOnLaunch = true }
        if routingReady { model.fileRouter.receive(urls) }
        else { bufferedURLs.append(contentsOf: urls) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        terminating = true
        NSDocumentController.shared.reviewUnsavedDocuments(withAlertTitle: "Quit VoxClip?", cancellable: true, delegate: self, didReviewAllSelector: #selector(reviewedDocuments(_:didReviewAll:contextInfo:)), contextInfo: nil)
        return .terminateLater
    }
    @objc private func reviewedDocuments(_ controller: NSDocumentController, didReviewAll: Bool, contextInfo: UnsafeMutableRawPointer?) {
        guard didReviewAll else { terminating = false; NSApp.reply(toApplicationShouldTerminate: false); return }
        Task { await model.flushSettings(); NSApp.reply(toApplicationShouldTerminate: true) }
    }
    func applicationWillTerminate(_ notification: Notification) { model.modelLibrary.task?.cancel() }

    private var editor: EditorModel? {
        guard let active = model.activeEditor, NSApp.keyWindow === active.window else { return nil }
        return active
    }
    @objc private func newProject(_ sender: Any?) { NSDocumentController.shared.newDocument(sender) }
    @objc private func openProject(_ sender: Any?) { chooseFile(app: model) }
    @objc private func openRecent(_ item: NSMenuItem) {
        if let url = item.representedObject as? URL { openFile(url, app: model) }
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for url in model.recent {
            let item = NSMenuItem(title: url.deletingPathExtension().lastPathComponent, action: #selector(openRecent(_:)), keyEquivalent: "")
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
        guard let editor else { return }
        switch item.tag {
        case 1: editor.cutSelection()
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
        case 12: editor.showInspector.toggle()
        case 13: editor.location = .home
        case 14: if !editor.isHome { editor.location = .transcript }
        case 15: if !editor.isHome { editor.location = .clips }
        case 16: editor.sidebarVisibility = editor.sidebarVisibility == .all ? .detailOnly : .all
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
        case 34: editor.location = .clips
        case 35: editor.showShortcuts = true
        case 36: model.showTour = true
        case 37: confirmRetranscription()
        default: break
        }
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
        if item.action == #selector(performEditorCommand(_:)) {
            guard let editor else { return false }
            switch item.tag {
            case 1, 2, 3, 29: return !editor.selectedIDs.isEmpty
            case 7: return editor.summary.canCutFillers
            case 8: return editor.summary.canTighten
            case 9: return editor.summary.hasEdits
            case 14, 15, 34: return !editor.isHome
            case 10: item.title = editor.showCuts ? "Hide Cut Words" : "Show Cut Words"
            case 11: item.title = editor.showPauses ? "Hide Pauses" : "Show Pauses"
            case 12: item.title = editor.showInspector ? "Hide Caption Inspector" : "Show Caption Inspector"
            case 16: item.title = editor.sidebarVisibility == .all ? "Hide Sidebar" : "Show Sidebar"
            default: return true
            }
        }
        if item.action == #selector(exportProject(_:)) { return editor?.canExport == true }
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
        add(file, "New Project", #selector(newProject(_:)), "n", target: self)
        add(file, "Open…", #selector(openProject(_:)), "o", target: self)
        let recent = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu(title: "Open Recent")
        recentMenu.delegate = self
        recent.submenu = recentMenu
        file.addItem(recent)
        file.addItem(.separator())
        add(file, "Close", #selector(NSWindow.performClose(_:)), "w")
        add(file, "Save", #selector(NSDocument.save(_:)), "s")
        add(file, "Save As…", #selector(NSDocument.saveAs(_:)), "s", [.command, .shift])
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
        command(edit, "Cut Selection", 1)
        command(edit, "Restore Selection", 2)
        command(edit, "Correct Word", 3)
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
        command(view, "Show Caption Inspector", 12, "i", [.command, .option])
        command(view, "Home", 13, "1")
        command(view, "Transcript", 14, "2")
        command(view, "Clips", 15, "3")
        command(view, "Toggle Sidebar", 16)
        command(view, "Source / Edited Timeline", 17)
        command(view, "Bigger Text", 18, "+")
        command(view, "Smaller Text", 19, "-")
        command(view, "Actual Size", 20, "0")
        let playback = menu("Playback")
        for (name, tag) in [("Play/Pause",21),("Play from Selection",22),("Preview Cut",23),("Shuttle Back",24),("Stop",25),("Shuttle Forward",26),("Go to Start",27),("Go to End",28)] { command(playback, name, tag) }
        let clip = menu("Clip")
        command(clip, "Make Clip from Selection", 29, "k")
        command(clip, "Set Start", 30)
        command(clip, "Set End", 31)
        command(clip, "Previous Clip", 32)
        command(clip, "Next Clip", 33)
        command(clip, "Find Clips…", 34)
        let window = menu("Window")
        add(window, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        add(window, "Zoom", #selector(NSWindow.performZoom(_:)))
        add(window, "Toggle Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])
        window.addItem(.separator())
        NSApp.windowsMenu = window
        let help = menu("Help")
        command(help, "Keyboard Shortcuts", 35, "/")
        command(help, "Workspace Tour", 36)
        add(help, "What Leaves This Mac", #selector(privacy(_:)), target: self)
        add(help, "Check for Updates…", #selector(checkUpdates(_:)), target: self)
        add(help, "Reveal Logs", #selector(revealLogs(_:)), target: self)
        add(help, "Copy Diagnostics", #selector(copyDiagnostics(_:)), target: self)
    }
}

let privacyCopy = "On-device transcription, editing, captions and export stay on this Mac. Your chosen cloud transcription engine receives audio only. Your chosen AI connector receives transcript text only, no audio or video. Installed CLIs use your own sign-in. Model downloads and update checks contact their publishers. No telemetry. Posting is optional and never happens without your click."

@MainActor func openVoxClipSettings() { (NSApp.delegate as? AppDelegate)?.openSettings() }

@MainActor func chooseFile(app: AppModel, projectsOnly: Bool = false) {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = projectsOnly ? [.voxclipProject] : [.voxclipProject, .movie]
    panel.allowsMultipleSelection = false
    if panel.runModal() == .OK, let url = panel.url { openFile(url, app: app) }
}
@MainActor func openFile(_ url: URL, app: AppModel) { app.fileRouter.receive([url]) }
@MainActor func openMovie(_ url: URL, app: AppModel) {
    if let home = app.activeHome, home.isHome {
        home.importTask = Task { await home.importVideo(url) }
        return
    }
    Task {
        do {
            let document = try await importedDocument(url, app: app)
            NSDocumentController.shared.addDocument(document)
            document.makeWindowControllers()
            document.showWindows()
        } catch {
            app.notice = await app.safeError(error)
            if NSDocumentController.shared.documents.isEmpty { NSDocumentController.shared.newDocument(nil) }
        }
    }
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
        let originatingHome = AppModel.sharedModel.activeHome
        let originatingWindow = originatingHome?.window
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { document, _, error in
            Task { @MainActor in
                if let error {
                    AppModel.sharedModel.notice = await AppModel.sharedModel.safeError(error)
                    if NSDocumentController.shared.documents.isEmpty { NSDocumentController.shared.newDocument(nil) }
                }
                else if document != nil { AppModel.sharedModel.noteRecent(url) }
                if document != nil, let originatingHome, let originatingWindow,
                        originatingHome.window === originatingWindow, originatingWindow.isVisible,
                        originatingHome.isHome, originatingHome.importProgress == nil {
                    originatingHome.closeEmptyWindow()
                }
            }
        }
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
            } else { AppModel.sharedModel.notice = "VoxClip can't open \(url.pathExtension.uppercased()) files on Mac yet. Export the video as MP4 or MOV and try again." }
        }
    }
}
