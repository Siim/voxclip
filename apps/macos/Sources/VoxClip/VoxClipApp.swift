import SwiftUI
import VoxClipCore

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    private var bufferedURLs: [URL] = []
    private var terminating = false
    func applicationWillFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if AppModel.isTestSession { NSApp.setActivationPolicy(.prohibited) }
        #endif
        model = AppModel.sharedModel
        model?.fileRouter.receive(bufferedURLs)
        bufferedURLs.removeAll()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        model?.launch()
        #if DEBUG
        if AppModel.isTestSession, let model {
            Task {
                await model.start()
                if CommandLine.arguments.contains("-uiSelfTest") { await DebugUISuite.run(app: model) }
                else if let position = CommandLine.arguments.firstIndex(of: "-uiPerformanceTest"), position + 1 < CommandLine.arguments.count {
                    DebugUISuite.performance(app: model, destination: URL(fileURLWithPath: CommandLine.arguments[position + 1]))
                } else if let position = CommandLine.arguments.firstIndex(of: "-demoCapture"), position + 1 < CommandLine.arguments.count {
                    await DebugUISuite.captureDemo(app: model, destination: URL(fileURLWithPath: CommandLine.arguments[position + 1]))
                }
            }
        }
        #endif
    }
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }
    func application(_ application: NSApplication, open urls: [URL]) {
        if let model { model.fileRouter.receive(urls) } else { bufferedURLs.append(contentsOf: urls) }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating, let model else { return .terminateNow }
        terminating = true
        Task { await model.flushSettings(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) { model?.modelLibrary.task?.cancel() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main @MainActor struct VoxClipApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var appModel = AppModel.sharedModel
    var body: some Scene {
        DocumentGroup(newDocument: { VoxClipDocument() }) { configuration in
            EditorView(document: configuration.document, app: appModel)
                .environment(appModel)
                .background(FileRoutingBridge(app: appModel))
                .onAppear { configuration.document.adoptOpenedLocation(configuration.fileURL) }
                .onChange(of: configuration.fileURL) { _, url in configuration.document.updateLocation(url) }
        }
        .defaultSize(width: 1280, height: 800)
        .windowToolbarStyle(.unified)
        .commands { VoxClipCommands(app: appModel) }
        Window("Welcome to VoxClip", id: "welcome") {
            WelcomeView().environment(appModel).preferredColorScheme(appModel.appearance)
                .background(FileRoutingBridge(app: appModel))
        }
        .defaultSize(width: 720, height: 480)
        .defaultLaunchBehavior(AppModel.isTestSession ? .suppressed : .presented)
        Settings { SettingsView().environment(appModel).preferredColorScheme(appModel.appearance) }
            .windowToolbarStyle(.expanded)
    }
}

@MainActor struct VoxClipCommands: Commands {
    @Bindable var app: AppModel
    @FocusedValue(\.editor) private var editor
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openDocument) private var openDocument
    @Environment(\.newDocument) private var newDocument
    var body: some Commands {
        CommandGroup(replacing: .newItem) { Button("New Project") { openWindow(id: "welcome") }.keyboardShortcut("n") }
        CommandGroup(replacing: .importExport) {
            Button("Open…") { chooseFile(app: app, open: openDocument, create: newDocument) }.keyboardShortcut("o")
            Button("Export…") { editor?.presentExport() }.keyboardShortcut("e").disabled(editor?.canExport != true)
            Button("Reveal Media in Finder") { if let url = editor?.sourceURL { NSWorkspace.shared.activateFileViewerSelecting([url]) } }.disabled(editor == nil)
        }
        CommandGroup(after: .appInfo) {
            Button(app.update.map { "Update Available: VoxClip \($0.version)…" } ?? "Check for Updates…") {
                if let url = app.update?.htmlURL, url.host == "github.com" { NSWorkspace.shared.open(url) }
                else { Task { await app.checkUpdates(manual: true) } }
            }
        }
        CommandGroup(after: .pasteboard) {
            Button("Cut Selection") { editor?.cutSelection() }.disabled(editor?.selectedIDs.isEmpty != false)
            Button("Restore Selection") { editor?.cutSelection(restore: true) }.disabled(editor?.selectedIDs.isEmpty != false)
            Button("Correct Word") { editor?.beginCorrection() }.disabled(editor?.selectedIDs.isEmpty != false)
            Divider()
            Button("Find…") { editor?.findVisible = true }.keyboardShortcut("f")
            Button("Find Next") { editor?.findNext() }.keyboardShortcut("g")
            Button("Find Previous") { editor?.findNext(backward: true) }.keyboardShortcut("g", modifiers: [.command, .shift])
            Button("Cut Fillers") { editor?.apply(.cutFillers, name: "Cut fillers") }.keyboardShortcut("u", modifiers: [.command, .option]).disabled(editor?.summary.canCutFillers != true)
            Button("Tighten Pauses") { editor?.apply(.tightenPauses, name: "Tighten pauses") }.keyboardShortcut("p", modifiers: [.command, .option]).disabled(editor?.summary.canTighten != true)
            Button("Restore All Cuts") { editor?.apply(.restoreCuts, name: "Restore cuts") }.keyboardShortcut("r", modifiers: [.command, .option]).disabled(editor?.summary.hasEdits != true)
            Button("Transcribe Again…") { confirmRetranscription() }.disabled(editor == nil)
        }
        CommandGroup(before: .toolbar) {
            Button(editor?.showCuts == true ? "Hide Cut Words" : "Show Cut Words") { editor?.showCuts.toggle() }.keyboardShortcut("h", modifiers: [.command, .shift])
            Button(editor?.showPauses == true ? "Hide Pauses" : "Show Pauses") { editor?.showPauses.toggle() }
            Button("Show Inspector") { editor?.showInspector.toggle() }.keyboardShortcut("i", modifiers: [.command, .option])
            Button("Captions") { editor?.inspectorTab = .captions; editor?.showInspector = true }.keyboardShortcut("1")
            Button("Clips") { editor?.inspectorTab = .clips; editor?.showInspector = true }.keyboardShortcut("2")
            Button("Source / Edited Timeline") { editor?.editedTimeline.toggle() }
            Divider()
            Button("Bigger Text") { editor?.zoom(1) }.keyboardShortcut("+")
            Button("Smaller Text") { editor?.zoom(-1) }.keyboardShortcut("-")
            Button("Actual Size") { editor?.zoom(0) }.keyboardShortcut("0")
        }
        CommandMenu("Playback") {
            Button("Play/Pause") { editor?.transport(" ") }
            Button("Play from Selection") { editor?.transport(" ", shift: true) }
            Button("Preview Cut") { editor?.transport("p") }
            Button("Shuttle Back") { editor?.transport("j") }
            Button("Stop") { editor?.transport("k") }
            Button("Shuttle Forward") { editor?.transport("l") }
            Button("Go to Start") { editor?.seek(source: 0) }
            Button("Go to End") { if let editor { editor.seek(source: editor.sourceDuration) } }
        }
        CommandMenu("Clip") {
            Button("Make Clip from Selection") { editor?.makeClip() }.keyboardShortcut("k").disabled(editor?.selectedIDs.isEmpty != false)
            Button("Set Start") { editor?.setClipEdge(start: true) }
            Button("Set End") { editor?.setClipEdge(start: false) }
            Button("Previous Clip") { editor?.moveClip(-1) }
            Button("Next Clip") { editor?.moveClip(1) }
            Button("Find Clips…") { editor?.inspectorTab = .clips; editor?.showInspector = true }
        }
        CommandGroup(after: .windowArrangement) { Button("Welcome") { openWindow(id: "welcome") } }
        CommandGroup(replacing: .help) {
            Button("Keyboard Shortcuts") { editor?.showShortcuts = true }.keyboardShortcut("/")
            Button("Welcome Tour") { openWindow(id: "welcome"); app.showTour = true }
            Button("What Leaves This Mac") { app.notice = privacyCopy; openWindow(id: "welcome") }
            Button("Reveal Logs") { app.revealLogs() }
            Button("Copy Diagnostics") { Task { copyText(await app.diagnostics()) } }
        }
    }
    private func confirmRetranscription() {
        guard let editor else { return }
        let edits = editor.project.edits
        let alert = NSAlert(); alert.messageText = "Transcribe again?"
        alert.informativeText = "This replaces the transcript and removes \(edits.cutWordIds.count + edits.cutPauseIds.count) cuts, \(edits.corrections.count) corrections, \(edits.clips.count) clips and the AI suggestions."
        alert.addButton(withTitle: "Transcribe Again"); alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { editor.showTranscribe = true }
    }
}

let privacyCopy = "On-device transcription, editing, captions and export stay on this Mac. Your chosen cloud transcription engine receives audio only. Your chosen AI connector receives transcript text only, no audio or video. Installed CLIs use your own sign-in. Model downloads and update checks contact their publishers. No telemetry. Posting is optional and never happens without your click."

@MainActor func chooseFile(app: AppModel, open: OpenDocumentAction, create: NewDocumentAction, projectsOnly: Bool = false) {
    let panel = NSOpenPanel(); panel.allowedContentTypes = projectsOnly ? [.voxclipProject] : [.voxclipProject, .movie]; panel.allowsMultipleSelection = false
    if panel.runModal() == .OK, let url = panel.url { openFile(url, app: app, open: open, create: create) }
}

@MainActor func openFile(_ url: URL, app: AppModel, open: OpenDocumentAction, create: NewDocumentAction) {
    app.fileRouter.installMovieOpener { url in openMovie(url, app: app, create: create) }
    app.fileRouter.receive([url])
}

@MainActor func openMovie(_ url: URL, app: AppModel, create: NewDocumentAction) {
    Task {
        do {
            let document = try await importedDocument(url, app: app)
            create { document }
        } catch { app.notice = await app.safeError(error) }
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
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
            if let error { Task { @MainActor in AppModel.sharedModel.notice = await AppModel.sharedModel.safeError(error) } }
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

@MainActor private struct FileRoutingBridge: View {
    let app: AppModel
    @Environment(\.newDocument) private var create
    var body: some View {
        Color.clear.onAppear { app.fileRouter.installMovieOpener { url in openMovie(url, app: app, create: create) } }
    }
}
