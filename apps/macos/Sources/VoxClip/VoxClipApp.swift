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
    /// The opt-in tour's Help item. DebugMenus checks it by this name, so the checklist's
    /// obsolete-workspace search finds only the item itself.
    nonisolated static let tourTitle = "Welcome Tour"
    private let model: AppModel
    init(model: AppModel = AppModel.sharedModel) { self.model = model; super.init() }
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
        if let index = CommandLine.arguments.firstIndex(of: "-transcriptionConsentAudit"), index + 1 < CommandLine.arguments.count {
            let directory = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            Task {
                do {
                    await model.start()
                    guard let shared = model.shared else { throw VoxClipError.sharedResourcesMissing }
                    let fixture = try DemoEditing.loadFixture(shared.root.appendingPathComponent("fixtures/projects/interview-take.voxclip"))
                    let results = try await DebugTranscriptionConsent.run(fixture: fixture)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try JSONEncoder().encode(results).write(to: directory.appendingPathComponent("results.json"), options: .atomic)
                    exit(results.allSatisfy(\.passed) ? 0 : 1)
                } catch { fputs("Transcription consent audit failed: \(error)\n", stderr); exit(1) }
            }
            return
        }
        if let index = CommandLine.arguments.firstIndex(where: { ["-layoutAudit", "-captionGalleryAudit"].contains($0) }), index + 1 < CommandLine.arguments.count {
            let directory = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            Task {
                await model.start()
                do {
                    let results: [DebugUISuite.Result]
                    if CommandLine.arguments.contains("-makeItCaptures") {
                        // Offscreen Make it postable states (DebugMakeIt.swift), on the -layoutAudit launch path.
                        results = try await DebugMakeIt.run(app: model, directory: directory)
                    } else if CommandLine.arguments.contains("-spacingCaptures") {
                        // Offscreen spacing captures (DebugSpacing.swift), on the -layoutAudit launch path.
                        results = try await DebugSpacing.run(app: model, directory: directory)
                    } else if CommandLine.arguments.contains("-timelinePerformanceAudit") {
                        // Headless counterpart of the timeline portion of -uiPerformanceTest.
                        // Keep -layoutAudit so AppModel uses the test-session launch path.
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        guard let shared = model.shared else { throw VoxClipError.sharedResourcesMissing }
                        let fixture = try DemoEditing.loadFixture(shared.root.appendingPathComponent("fixtures/projects/interview-take.voxclip"))
                        results = try await DebugTimeline.performance(app: model, fixture: fixture, directory: directory)
                    } else {
                        results = CommandLine.arguments[index] == "-captionGalleryAudit"
                            ? try await DebugCaptionGallery.run(app: model, directory: directory)
                            : try await DebugRightColumn.run(app: model, directory: directory)
                    }
                    try JSONEncoder().encode(results).write(to: directory.appendingPathComponent("results.json"), options: .atomic)
                    exit(results.allSatisfy(\.passed) ? 0 : 1)
                } catch { fputs("Layout audit failed: \(error)\n", stderr); exit(1) }
            }
            return
        }
        // The Rewrite smoke (doc/release.md): offscreen, scripted, run before every handed-over test build.
        if let index = CommandLine.arguments.firstIndex(of: "-rewriteSmoke"), index + 1 < CommandLine.arguments.count {
            let directory = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            Task {
                await model.start()
                exit(await DebugRewriteSmoke.run(app: model, directory: directory) ? 0 : 1)
            }
            return
        }
        if let index = CommandLine.arguments.firstIndex(where: { ["-round4SelfTest", "-round5SelfTest", "-round6SelfTest"].contains($0) }), index + 1 < CommandLine.arguments.count {
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
        if let index = CommandLine.arguments.firstIndex(of: "-voiceTakesDemo"), index + 1 < CommandLine.arguments.count {
            let state = CommandLine.arguments[index + 1]
            Task {
                await model.start()
                do { try await DebugRewriteGeneration.show(state, app: model) }
                catch { model.shell.notice = await model.safeError(error) }
            }
        }
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
                    await DebugUISuite.performance(app: model, destination: URL(fileURLWithPath: CommandLine.arguments[position + 1]))
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
    func applicationWillTerminate(_ notification: Notification) { model.stopVoiceRecovery(); model.modelLibrary.task?.cancel(); model.speakerModelLibrary.task?.cancel() }

    #if DEBUG
    weak var commandWindowForTesting: NSWindow?
    var commandEventForTesting: NSEvent?
    #endif
    private var commandEvent: NSEvent? {
        #if DEBUG
        if let commandEventForTesting { return commandEventForTesting }
        #endif
        return NSApp.currentEvent
    }
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
    /// The key window's shell: the main window's or a Versions window's. The tab commands act on it.
    private var keyShell: WorkspaceShell? {
        #if DEBUG
        if let commandWindowForTesting { return (commandWindowForTesting.windowController as? ShellWindowController)?.shell }
        #endif
        return (NSApp.keyWindow?.windowController as? ShellWindowController)?.shell
    }
    /// The editor showing in the key window, the main window's or a Versions window's.
    /// View settings that never write the project (Show Cuts) act on it.
    private var keyEditor: EditorModel? {
        guard let shell = keyShell, !shell.showsHome else { return nil }
        return shell.editor
    }
    @objc private func newProject(_ sender: Any?) { chooseFile(app: model, moviesOnly: true) }
    @objc private func openProject(_ sender: Any?) { chooseFile(app: model) }
    /// ⌘W closes a clip or suggestion tab (impl-plan item 5). On Full Take it closes the
    /// project and shows Home, and on Home it closes the window (design §11).
    @objc private func closeProject(_ sender: Any?) {
        if let shell = keyShell, shell.closesTab { shell.closeTab(shell.tabs.active); return }
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
        case 56: if validateMenuItem(item) { shell.toggleTimeline() }; return
        // Tabs work in the key window, a Versions window too (impl-plan V3a).
        case 50, 51: keyShell?.showAdjacentTab(item.tag == 50 ? -1 : 1); return
        // Show Cuts is a view setting, so it works in the key window, a Versions window too.
        case 60: if validateMenuItem(item) { keyEditor?.toggleShowsCuts() }; return
        case 20:
            if validateMenuItem(item) { keyEditor?.zoom(0) }
            return
        case 18, 19:
            guard validateMenuItem(item), let editor = keyEditor else { return }
            let direction = item.tag == 19 ? -1 : 1
            if editor.focusedPane == .timeline { editor.timelineZoomStep += direction }
            else { editor.zoom(Double(direction)) }
            return
        // Commands belong to the active window; Help also works with no project open.
        case 35, 61:
            if let keyShell { keyShell.openCommandPalette() }
            else { MainWindowController.shared.show(); shell.openCommandPalette() }
            return
        case 36: MainWindowController.shared.show(); model.showTour = true; return
        default: break
        }
        guard let editor, validateMenuItem(item) else { return }
        switch item.tag {
        case 1:
            if !MenuCommandIndex.isInvoking, commandEvent?.type == .keyDown { editor.toggleSelectionCut() }
            else { editor.cutSelection() }
        case 2: editor.cutSelection(restore: true)
        case 3: editor.beginCorrection()
        case 4: editor.findVisible = true
        case 5: editor.findNext()
        case 6: editor.findNext(backward: true)
        case 7: editor.apply(.cutFillers, name: "Cut fillers")
        case 8: editor.apply(.tightenPauses, name: "Tighten pauses")
        case 9: editor.apply(.restoreCuts, name: "Restore cuts")
        case 11: editor.showPauses.toggle()
        case 12: model.shell.toggleViewer()
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
        case 34: editor.requestFindClips(from: .clipBar)
        case 37: openRetranscription()
        case 38: editor.runRewrite()
        case 40: if let id = selectedClipID { editor.keep(id) }
        case 41: if let id = selectedClipID { editor.dismiss(id) }
        case 42: editor.keepAll()
        case 43: if let id = selectedClipID { shell.beginRename(id) }
        case 44: if let id = selectedClipID { editor.removeClip(id) }
        case 45: if let id = selectedClipID { editor.presentExport(clipIDs: [id]) }
        case 62: if let id = makeItClipID(editor) { editor.makeItPostable(id) }
        case 46: editor.seek(source: max(0, editor.sourceTime - 3))
        case 47: editor.seek(source: min(editor.sourceDuration, editor.sourceTime + 3))
        case 48: editor.copySelection()
        case 49: editor.findTask?.cancel()
        case 52, 53, 54, 55: editor.setAspect(Self.frameAspects[item.tag - 52])
        default: break
        }
    }
    /// View › Frame (impl-plan V4: the Frame picker left the viewer), in the design's order
    /// 9:16 · 1:1 · 16:9 · Original, tags 52–55.
    static let frameAspects: [AspectRatio] = [.portrait, .square, .landscape, .source]
    /// Clip › Make It Postable acts on the selected row's clip, else the open tab's clip.
    private func makeItClipID(_ editor: EditorModel) -> String? { selectedClipID ?? editor.activeClip?.id }
    private var selectedClipID: String? {
        switch model.shell.selection {
        case .clip(let id): return id
        case .outline: return model.shell.editor?.activeClip?.id
        default: return nil
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
    private func openRetranscription() {
        guard let editor else { return }
        Task { await editor.transcription.open(again: true) }
    }

    static func retranscriptionWarning(for project: Project) -> String {
        let edits = project.edits
        let counts = [(edits.cutWordIds.count + edits.cutPauseIds.count, "cut"), (edits.corrections.count, "correction"), (edits.clips.count, "clip")]
        let parts = counts.filter { $0.0 > 0 }.map { "\($0.0) \($0.1)\($0.0 == 1 ? "" : "s")" }
        let removed = parts.isEmpty ? "the AI suggestions" : parts.joined(separator: ", ") + " and the AI suggestions"
        return "This replaces the transcript and removes \(removed)."
    }

    static func focusedControlKeepsKey(_ item: NSMenuItem, responder: NSResponder?) -> Bool {
        guard !item.keyEquivalent.isEmpty, item.keyEquivalentModifierMask.isDisjoint(with: [.command, .control, .option]) else { return false }
        if responder is NSText || responder is NSTextField || responder is NSTableView || responder is NSSlider { return false }
        if responder is NSControl { return true }
        guard responder is NSView, NSApp.isFullKeyboardAccessEnabled || NSWorkspace.shared.isVoiceOverEnabled,
              let role = (NSApp.accessibilityFocusedUIElement as? any NSAccessibilityProtocol)?.accessibilityRole() else { return false }
        return [.button, .checkBox, .radioButton, .radioGroup, .popUpButton, .menuButton, .disclosureTriangle].contains(role)
    }
    /// Back 3 Seconds shares J with Shuttle Back. The J key reaches it only from the
    /// transcript; chosen from the menu it works wherever focus is, like Forward 3 Seconds,
    /// since the viewer has no Back 3 s button (impl-plan V4).
    static func backStepEnabled(_ item: NSMenuItem, event: NSEvent?, responder: NSResponder?) -> Bool {
        guard let event, event.type == .keyDown, !item.keyEquivalent.isEmpty,
              event.charactersIgnoringModifiers?.lowercased() == item.keyEquivalent.lowercased() else { return true }
        return responder is TranscriptNSTextView
    }
    /// Keep, Dismiss, Rename and Remove (tags 40, 41, 43, 44) by their bare Return and Delete act on the Explorer's
    /// row, so those keys reach them only from the Explorer's list: never while text is typed (the clip bar's Ask field,
    /// the transcript, another field), a clip is renamed or an input method composes. Keep Suggestion's hidden ⇧⌘↩, the
    /// clip bar's Keep (impl-plan §3.2, V3b), works from anywhere in the window on a suggestion's tab.
    static func clipRowKeyEnabled(_ item: NSMenuItem, event: NSEvent?, pane: EditorPane, renaming: Bool, responder: NSResponder?, row: SidebarItem? = nil) -> Bool {
        guard !MenuCommandIndex.isInvoking, event?.type == .keyDown, [40, 41, 43, 44].contains(item.tag) else { return true }
        if renaming { return false }
        if let input = responder as? any NSTextInputClient, input.hasMarkedText() { return false }
        guard item.keyEquivalentModifierMask.isDisjoint(with: [.command, .control, .option]) else { return true }
        if case .outline = row { return false }
        return pane == .sidebar && !(responder is NSText)
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(checkUpdates(_:)) {
            item.title = model.update.map { "VoxClip \($0.version) Available…" } ?? "Check for Updates…"
        }
        if item.action == #selector(closeProject(_:)) {
            item.title = keyShell?.closesTab == true ? "Close Tab" : mainWindowIsKey && model.shell.document != nil ? "Close Project" : "Close"
            return NSApp.keyWindow != nil
        }
        if item.action == #selector(performEditorCommand(_:)) {
            if item.tag == 38 { item.title = editor?.rewriteMenuTitle ?? "Rewrite Full Take" }
            switch item.tag {
            case 13: return mainWindowIsKey
            case 14: return mainWindowIsKey && model.shell.document != nil
            case 16:
                item.title = model.shell.sidebarShown ? "Hide Sidebar" : "Show Sidebar"
                return mainWindowIsKey
            case 56:
                // While the right column is hidden the timeline carries play and the timecode, so it stays (WorkspaceShell.toggleTimeline).
                let shell = model.shell
                item.title = shell.layout.timelineVisible ? "Hide Timeline" : "Show Timeline"
                return mainWindowIsKey && shell.editor != nil && !shell.showsHome && (shell.layout.rightVisible || !shell.layout.timelineVisible)
            case 35, 36, 61: return true
            case 50, 51: return keyShell.map { $0.tabsShown && $0.tabs.open.count > 1 } ?? false
            case 20: return keyEditor != nil
            case 18, 19:
                let timeline = keyEditor?.focusedPane == .timeline
                item.title = item.tag != 19 ? (timeline ? "Zoom Timeline In" : "Bigger Text") : (timeline ? "Zoom Timeline Out" : "Smaller Text")
                return keyEditor != nil
            case 60:
                guard let editor = keyEditor else { return false }
                item.state = editor.showsCuts ? .on : .off
                return true
            default: break
            }
            guard let editor else { return false }
            if editor.mutationEnabled(item.tag) == false { return false }
            if !MenuCommandIndex.isInvoking, commandEvent?.type == .keyDown, Self.focusedControlKeepsKey(item, responder: NSApp.keyWindow?.firstResponder) { return false }
            if !Self.clipRowKeyEnabled(item, event: commandEvent, pane: editor.focusedPane, renaming: model.shell.renaming != nil,
                                       responder: NSApp.keyWindow?.firstResponder, row: model.shell.selection) { return false }
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
            case 38: return RewriteEntryPolicy.canRun(editable: editor.capabilities.ai, scope: editor.rewriteScopeNow)
            case 48: return !editor.selectedIDs.isEmpty
            case 2: return editor.capabilities.edit && (!editor.selectedWordIDs.isDisjoint(with: editor.cutWordIDs) || !editor.selectedPauseIDs.isDisjoint(with: editor.cutPauseIDs))
            case 40, 41: return editor.capabilities.edit && selectedClipID.map(editor.isSuggestion) == true
            case 42: return editor.capabilities.edit && !editor.suggestedClips.isEmpty
            case 49: return editor.finding
            case 43, 44: return selectedClipID.map { !editor.isSuggestion($0) } == true && editor.capabilities.edit
            case 45: return selectedClipID.map { !editor.isSuggestion($0) } == true && editor.canExport && editor.mediaExportable
            case 62:
                guard let id = makeItClipID(editor) else { return false }
                item.title = editor.makeItTitle(clipID: id).replacingOccurrences(of: "✦ Make it postable", with: "Make It Postable")
                return editor.canMakeItPostable(id)
            case 46: return editor.mediaResolved && Self.backStepEnabled(item, event: commandEvent, responder: NSApp.keyWindow?.firstResponder)
            case 47: return editor.mediaResolved
            case 7: return editor.capabilities.edit && editor.summary.canCutFillers
            case 8: return editor.capabilities.edit && editor.summary.canTighten
            case 9: return editor.capabilities.edit && editor.summary.hasEdits
            case 30, 31: return editor.capabilities.edit && editor.activeClip != nil
            case 34: return editor.capabilities.ai && !editor.words.isEmpty
            case 11: item.title = editor.showPauses ? "Hide Pauses" : "Show Pauses"
            case 12: item.title = model.shell.viewerShown ? "Hide Viewer" : "Show Viewer"
            case 52, 53, 54, 55:
                item.state = editor.project.export.aspect == Self.frameAspects[item.tag - 52] ? .on : .off
                return editor.capabilities.writable && editor.capabilities.media
            default: return true
            }
        }
        if item.action == #selector(exportProject(_:)) { return editor.map { $0.canExport && $0.exportUnavailable == nil } ?? false }
        if item.action == #selector(revealMedia(_:)) { return editor != nil }
        return true
    }
    /// Shared by the installed View menu and the headless menu audit.
    func addZoomCommands(to menu: NSMenu) {
        for (title, tag, key) in [("Bigger Text", 18, "="), ("Bigger Text", 18, "+"), ("Smaller Text", 19, "-"), ("Actual Size", 20, "0")] {
            let item = NSMenuItem(title: title, action: #selector(performEditorCommand(_:)), keyEquivalent: key)
            item.tag = tag; item.target = self; item.keyEquivalentModifierMask = .command
            // Preserve the shifted plus spelling without a second visible action.
            item.isHidden = key == "+"
            item.allowsKeyEquivalentWhenHidden = key == "+"
            menu.addItem(item)
        }
    }
    /// Builds the main menu. Internal so a headless test can check its key equivalents and tags.
    func installMenus() {
        // The windows never tab (`tabbingMode = .disallowed`), so AppKit adds no tab items of
        // its own beside the editor's Show Next Tab and Show Previous Tab (⌃Tab, impl-plan V3a).
        NSWindow.allowsAutomaticWindowTabbing = false
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
        // Edit › Rewrite {scope} (design.md §8): `validateMenuItem` retitles it for the scope and the AI.
        command(edit, "Rewrite Full Take", 38, "r", [.command, .shift])
        command(edit, "Copy Text", 48)
        command(edit, "Find…", 4, "f")
        command(edit, "Find Next", 5, "g")
        command(edit, "Find Previous", 6, "g", [.command, .shift])
        command(edit, "Cut Fillers", 7, "u", [.command, .option])
        command(edit, "Tighten Pauses", 8, "p", [.command, .option])
        command(edit, "Restore All Cuts", 9, "r", [.command, .option])
        command(edit, "Transcribe Again…", 37)
        let view = menu("View")
        command(view, "Show Cuts", 60, "c", [.command, .option])
        command(view, "Show Pauses", 11)
        command(view, "Hide Viewer", 12, "i", [.command, .option])
        command(view, "Search or Run a Command…", 61, "k")
        command(view, "Home", 13, "1")
        command(view, "Full Take", 14, "2")
        command(view, "Hide Sidebar", 16, "s", [.command, .control])
        command(view, "Hide Timeline", 56, "j")
        let frame = NSMenuItem(title: "Frame", action: nil, keyEquivalent: "")
        let frameMenu = NSMenu(title: "Frame")
        for (offset, aspect) in Self.frameAspects.enumerated() { command(frameMenu, aspect.frameName, 52 + offset, "", []) }
        frame.submenu = frameMenu
        view.addItem(frame)
        addZoomCommands(to: view)
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
        command(clip, "Make Clip from Selection", 29, "k", [.command, .option])
        command(clip, "Find Clips…", 34, "k", [.command, .shift])
        command(clip, "Make It Postable", 62)
        command(clip, "Cancel Finding Clips", 49, ".")
        command(clip, "Keep Suggestion", 40, String(UnicodeScalar(NSCarriageReturnCharacter)!), [])
        // The clip bar's Keep ⇧⌘↩ on a suggestion's tab (impl-plan §3.2, V3b), a hidden alternate.
        command(clip, "Keep Suggestion", 40, String(UnicodeScalar(NSCarriageReturnCharacter)!), [.command, .shift])
        clip.items.last?.isHidden = true
        clip.items.last?.allowsKeyEquivalentWhenHidden = true
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
        // The editor's tabs (impl-plan §3.2): ⌃⇧Tab and ⌃Tab, with ⇧⌘[ and ⇧⌘] as hidden alternates.
        command(window, "Show Previous Tab", 50, "\t", [.control, .shift])
        command(window, "Show Next Tab", 51, "\t", [.control])
        for (tag, key) in [(50, "{"), (51, "}")] {
            command(window, tag == 50 ? "Show Previous Tab" : "Show Next Tab", tag, key, [.command])
            window.items.last?.isHidden = true
            window.items.last?.allowsKeyEquivalentWhenHidden = true
        }
        window.addItem(.separator())
        add(window, "VoxClip", #selector(showMainWindow(_:)), target: self)
        window.addItem(.separator())
        NSApp.windowsMenu = window
        let help = menu("Help")
        command(help, "Keyboard Shortcuts", 35, "/")
        command(help, Self.tourTitle, 36)
        add(help, "What Leaves This Mac", #selector(privacy(_:)), target: self)
        add(help, "Reveal Logs", #selector(revealLogs(_:)), target: self)
        add(help, "Copy Diagnostics", #selector(copyDiagnostics(_:)), target: self)
    }
}

let privacyCopy = """
On-device transcription, editing, captions and export stay on this Mac. Your chosen cloud transcription engine receives audio only. Your chosen AI connector receives transcript text only, no audio or video. Installed CLIs use your own sign-in. Model downloads and update checks contact their publishers. No telemetry. Posting is optional and never happens without your click.

Voice Lab (only when you turn it on; each provider action requires your approval):
• Source audio for Clean audio goes to ElevenLabs, only on your click. The input WAV is an evictable local cache; the result stays in this Mac's Voice Lab data folder.
• Consent statement audio goes to ElevenLabs Scribe for the check and IVC as one clone sample. It stays in this Mac's consent record folder until the voice is deleted.
• Training samples (project spans or a read-aloud) go to ElevenLabs IVC. They are temporary: deleted locally after upload or when the sheet closes; hashes are kept.
• Patch text and context text go to ElevenLabs TTS (previous_text / future_text, at most 100 or 300 characters). They stay in the project segment. Speech-check audio goes to ElevenLabs Scribe for QA.
• Lip-sync window video and audio go to fal.ai or sync.so. Remote files are deleted where the API allows; the result stays in this Mac's project Voice Lab folder.
• Speaker embeddings never leave this Mac. They stay in the local consent record.
"""

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
