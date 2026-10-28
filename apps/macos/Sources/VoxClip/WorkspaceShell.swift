import AppKit
import SwiftUI
import VoxClipCore

/// The sidebar's one selection (design §2). A Recent row is selectable for the arrow
/// keys and Return, and shows Home like the Home row.
enum SidebarItem: Hashable {
    case home, fullTake, clip(String), recent(URL)
    var showsHome: Bool {
        switch self {
        case .home, .recent: true
        case .fullTake, .clip: false
        }
    }
}

/// State of the one main window (ADR-R29): the open project, its editor, the sidebar
/// selection and the column visibility. It is the only owner of `EditorModel`
/// instances. Each project stays a `VoxClipDocument`, attached to the main window's
/// controller while it is open and detached before it closes.
@MainActor @Observable final class WorkspaceShell {
    let app: AppModel
    private(set) var document: VoxClipDocument?
    private(set) var editor: EditorModel?
    var selection: SidebarItem = .home { didSet { if selection != oldValue { followSelection() } } }
    var columnVisibility: NavigationSplitViewVisibility = .all {
        didSet {
            // Below 960 the column stays collapsed: the toolbar's sidebar button shows or
            // hides the overlay instead (design §3.7).
            guard !settingColumns, windowWidth < Self.sidebarCollapseWidth, columnVisibility != .detailOnly else { return }
            setColumns(.detailOnly)
            sidebarOverlay.toggle()
        }
    }
    /// Below 960 the sidebar shows over the editor on request (design §3.7): the
    /// toolbar's sidebar button, View > Show Sidebar and Find Clips. Escape or a click
    /// on a row hides it again.
    var sidebarOverlay = false
    /// The clip whose title is being typed in the sidebar, and the typed title. Leaving
    /// the project and Quit keep it before edits freeze (design §6.2).
    var renaming: String?
    var renameDraft = ""
    /// The right column (viewer and captions). Show Viewer / Hide Viewer, ⌥⌘I.
    var viewerVisible = true
    var notice: String?
    /// A file is being dragged over the window.
    var dropTargeted = false
    /// Home's project search, kept while the editor shows.
    var homeQuery = ""
    var windowWidth = 1280.0 { didSet { if abs(windowWidth - oldValue) > 0.5 { fitColumns() } } }
    /// The sidebar's measured width; the user can drag it between its minimum and maximum.
    @ObservationIgnored var sidebarWidth = Double(VCTokens.sizeSidebarIdeal)
    /// Help > Keyboard Shortcuts (⌘/), also on Home.
    var showShortcuts = false
    /// The viewer was collapsed by the window's width, not by the user.
    @ObservationIgnored private var viewerHiddenByWidth = false
    /// The sidebar was hidden to make room for a viewer shown at a narrow width.
    @ObservationIgnored private var sidebarHiddenForViewer = false
    /// The sidebar was hidden because the window is narrower than 960 (design §3.7).
    @ObservationIgnored private var sidebarHiddenByWidth = false
    /// Below this window width the sidebar collapses (design §3.7, full-screen Split View).
    static let sidebarCollapseWidth = 960.0
    /// The transcript pane's minimum width (design §3.7): a 480 measure, the 84 gutter
    /// and 32 of trailing padding. Below it the right column collapses first.
    static let minimumTranscriptPane = 596.0
    private(set) var importProgress: String?
    @ObservationIgnored private var importTask: Task<Void, Never>?
    @ObservationIgnored weak var windowController: NSWindowController?
    /// The attached editor's start: media resolution, probe and the first preview load.
    @ObservationIgnored private(set) var started: Task<Void, Never>?
    @ObservationIgnored private var closeReply: CloseReply?
    @ObservationIgnored private var leaving = false
    @ObservationIgnored private var settingColumns = false
    private(set) var pendingRecovery: VoxClipDocument?
    @ObservationIgnored private var additionalRecoveries: [VoxClipDocument] = []
    @ObservationIgnored private var retryingRecovery = false
    /// Bumped when the open project's title follows its file's new name.
    private var titleRevision = 0
    #if DEBUG
    /// Treats the next leave-boundary save as failed (DebugPersistence).
    @ObservationIgnored var injectSaveFailure = false
    #endif

    init(app: AppModel) { self.app = app }

    /// No project is open.
    var isHome: Bool { document == nil }
    /// The detail area shows Home: no project is open, or the Home row or a Recent row
    /// is selected.
    var showsHome: Bool { document == nil || selection.showsHome }
    var isImporting: Bool { importTask != nil }

    /// The open project's name (design §2): `Project.title`, else the file name, so an
    /// untitled import reads as its video and never "Untitled".
    var projectTitle: String {
        _ = titleRevision
        return document.map { Self.projectTitle($0.project, fileURL: $0.fileURL) } ?? "VoxClip"
    }
    /// The one title rule for the window, the sidebar and Home: `Project.title`, else the
    /// file name, else the video's name, else "VoxClip".
    nonisolated static func projectTitle(_ project: Project, fileURL: URL?) -> String {
        if let title = project.title, !title.isEmpty { return title }
        if let fileURL { return fileURL.deletingPathExtension().lastPathComponent }
        let path = project.media.source.absolutePath
        return path == "/" || path.isEmpty ? "VoxClip" : URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    }
    /// The window title: "VoxClip" while Home is selected (design §7).
    var title: String { showsHome ? "VoxClip" : projectTitle }
    /// Save As, Rename or Move gave the open project's title the file's new name.
    func documentTitleDidChange(_ changed: VoxClipDocument) {
        guard changed === document else { return }
        titleRevision += 1
        windowController?.window?.title = title
    }
    /// The open project was saved or autosaved: crash recovery records an untitled
    /// project's autosave and nothing for a saved one (design §2).
    func documentRestorationChanged(_ changed: VoxClipDocument) {
        guard changed === document else { return }
        (windowController as? MainWindowController)?.restorationDidChange()
    }
    /// Crash recovery (design §2): reopens a never-saved project's autosave in place of
    /// the open project.
    @discardableResult func reopenAutosave(_ url: URL) async -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        if showsRecovered(url) { return true }
        do {
            let (reopened, _) = try await NSDocumentController.shared.reopenDocument(for: nil, withContentsOf: url, display: false)
            guard let next = reopened as? VoxClipDocument else { return false }
            if next.autosavedContentsFileURL == nil { next.autosavedContentsFileURL = url }
            if closesRecoveredCopy(next) { return true }
            guard await replaceProject(with: next) else { retainRecovery(next); return false }
            // Like an import, the recovered project asks to be kept or deleted when it closes.
            if !next.isDocumentEdited { next.markEdited() }
            return true
        } catch {
            notice = await app.safeError(error)
            return false
        }
    }
    /// Crash recovery can reach one autosave twice: through AppKit's document recovery
    /// and through the main window's restorable state. The open project keeps it, and
    /// the second copy closes without touching the file.
    func closesRecoveredCopy(_ copy: VoxClipDocument) -> Bool {
        guard copy !== document, copy.fileURL == nil, let url = copy.autosavedContentsFileURL, showsRecovered(url) else { return false }
        copy.autosavedContentsFileURL = nil
        copy.updateChangeCount(.changeCleared)
        copy.close()
        return true
    }
    private func showsRecovered(_ url: URL) -> Bool {
        guard let document, document.fileURL == nil else { return false }
        return document.autosavedContentsFileURL?.standardizedFileURL == url.standardizedFileURL
    }

    func retainRecovery(_ recovered: VoxClipDocument) {
        guard recovered.fileURL == nil, recovered.autosavedContentsFileURL != nil else { recovered.close(); return }
        guard recovered !== pendingRecovery, !additionalRecoveries.contains(where: { $0 === recovered }) else { return }
        if pendingRecovery == nil { pendingRecovery = recovered }
        else { additionalRecoveries.append(recovered) }
    }

    func resumePendingRecovery() async {
        guard !isImporting, !leaving, !retryingRecovery, let recovered = pendingRecovery else { return }
        retryingRecovery = true
        defer { retryingRecovery = false }
        guard await replaceProject(with: recovered) else { return }
        if !recovered.isDocumentEdited { recovered.markEdited() }
        pendingRecovery = additionalRecoveries.isEmpty ? nil : additionalRecoveries.removeFirst()
    }

    // MARK: Renaming a clip

    func beginRename(_ id: String) {
        guard editor?.capabilities.edit == true else { return }
        let clips: [ClipRange] = editor?.project.edits.clips ?? []
        guard let clip = clips.first(where: { (candidate: ClipRange) -> Bool in candidate.id == id }) else { return }
        renameDraft = clip.title ?? ""
        renaming = id
    }
    /// Ends the inline rename. Return, a click elsewhere, a selection change, leaving the
    /// project and Quit keep the typed title; Escape keeps the old one.
    func endRename(keep: Bool = true) {
        guard let id = renaming else { return }
        renaming = nil
        if keep { editor?.renameClip(id, to: renameDraft) }
    }

    // MARK: Opening and leaving projects

    /// Imports a movie as a new untitled project and opens it in place of the open one.
    func importVideo(_ url: URL) async {
        guard importTask == nil else { notice = Self.busyCopy; return }
        // A file opened from Finder or the Dock shows its progress in the main window,
        // even if that window was closed or minimised.
        windowController?.window?.makeKeyAndOrderFront(nil)
        let task = Task { [weak self] in
            guard let self else { return }
            importProgress = "Importing video…"
            defer { importProgress = nil; importTask = nil }
            do {
                let imported = try await importedDocument(url, app: app)
                try Task.checkCancellation()
                NSDocumentController.shared.addDocument(imported)
                guard await replaceProject(with: imported, fromImport: true) else { imported.close(); return }
                // An untitled import is an edited document, so leaving it later
                // shows the system keep/delete prompt.
                imported.markEdited()
                await started?.value
            } catch is CancellationError {
            } catch { notice = await app.safeError(error) }
        }
        importTask = task
        await task.value
        await resumePendingRecovery()
    }
    func cancelImport() { importTask?.cancel() }

    /// Opens a project file without a window of its own and replaces the open project
    /// with it. Opening the project that is already open selects Full take.
    @discardableResult func openProject(at url: URL) async -> Bool {
        windowController?.window?.makeKeyAndOrderFront(nil)
        if let open = document?.fileURL, open.standardizedFileURL == url.standardizedFileURL {
            selection = .fullTake
            return true
        }
        // The import replaces the open project when it finishes (checklist step 3.1).
        guard !isImporting else { notice = Self.busyCopy; return false }
        do {
            let (opened, alreadyOpen) = try await NSDocumentController.shared.openDocument(withContentsOf: url, display: false)
            guard let next = opened as? VoxClipDocument else { return false }
            if await replaceProject(with: next) { app.noteRecent(url); return true }
            if !alreadyOpen { next.close() }
            return false
        } catch {
            notice = await app.safeError(error)
            return false
        }
    }

    /// A Recent row (design §3.4 and §7): opens the project, or Locate… when its video is
    /// missing or can't be read.
    func openRecent(_ url: URL) async {
        let status = app.recentProjects.status(url)
        if status == .missing || status == .unreadable { await locateMedia(for: url) } else { await openProject(at: url) }
    }

    /// Locate… on a recent project whose video is missing: opens it in place, then
    /// runs the relink flow. Cancelling leaves it open in its missing-media state.
    func locateMedia(for url: URL) async {
        guard await openProject(at: url) else { return }
        await started?.value
        editor?.locateMedia()
    }

    /// The leave boundary (design §2): the open project freezes, saves and closes, then
    /// `next` is attached. Opening the project that is already open selects Full take.
    /// Returns false, with an inline notice, when the open project stays. Only the
    /// running import may replace the project while it imports.
    @discardableResult func replaceProject(with next: VoxClipDocument, fromImport: Bool = false) async -> Bool {
        if next === document { selection = .fullTake; return true }
        guard !next.isVersion else { return false }
        guard await leave(fromImport: fromImport) else { return false }
        attach(next)
        return true
    }

    /// Close Project (⌘W): the same boundary, leaving the shell on Home.
    @discardableResult func closeProject() async -> Bool {
        guard document != nil else { return true }
        guard await leave() else { return false }
        selection = .home
        return true
    }

    /// A project closed outside the shell, for example by a test. Detaching first keeps
    /// the main window open on Home.
    func documentWillClose(_ closing: VoxClipDocument) {
        guard closing === document, let editor else { return }
        detach(closing, editor)
        selection = .home
    }

    static let busyCopy = "Finish the current task first."

    /// The right column's starting width for a window width (design §3.7).
    static func rightColumnWidth(windowWidth: Double) -> Double {
        (360 - (1440 - windowWidth) * 0.25).clamped(to: rightWidthRange)
    }
    /// The right column's width: where the user last dragged its divider, kept for every
    /// project in `ui.rightColumnWidth`, else the starting width for this window.
    var rightWidth: Double { app.number(Self.rightWidthKey, fallback: Self.rightColumnWidth(windowWidth: windowWidth)).clamped(to: Self.rightWidthRange) }
    func rememberRightWidth(_ width: Double) { app.set(Self.rightWidthKey, .number(width.rounded().clamped(to: Self.rightWidthRange))) }
    private static let rightWidthKey = "ui.rightColumnWidth"
    private static var rightWidthRange: ClosedRange<Double> { Double(VCTokens.sizeRightColumnMin)...Double(VCTokens.sizeRightColumnMax) }
    private func paneWidth(viewer: Bool, sidebar: Bool) -> Double {
        windowWidth - (sidebar ? sidebarWidth : 0) - (viewer ? rightWidth : 0)
    }
    /// Shows a hidden sidebar for its Find Clips callout and progress (design §6.2); the
    /// right column makes room first. Below 960 it shows as the overlay (design §3.7).
    func revealSidebar() {
        if windowWidth < Self.sidebarCollapseWidth { sidebarOverlay = true; return }
        guard columnVisibility == .detailOnly else { return }
        sidebarHiddenForViewer = false
        sidebarHiddenByWidth = false
        setColumns(.all)
        fitColumns()
    }
    /// View > Show Sidebar and Hide Sidebar (⌃⌘S); below 960 the overlay.
    func toggleSidebar() {
        if windowWidth < Self.sidebarCollapseWidth { sidebarOverlay.toggle(); return }
        setColumns(columnVisibility == .detailOnly ? .all : .detailOnly)
    }
    var sidebarShown: Bool { columnVisibility != .detailOnly || sidebarOverlay }
    /// A row the user chose in the sidebar list. A click on a row also hides the overlay
    /// sidebar (design §3.7); the arrow keys leave it open.
    func choose(_ row: SidebarItem, byClick: Bool = NSApp.currentEvent.map { $0.type == .leftMouseDown || $0.type == .leftMouseUp } ?? false) {
        selection = row
        if byClick { sidebarOverlay = false }
    }
    private func setColumns(_ visibility: NavigationSplitViewVisibility) {
        settingColumns = true
        columnVisibility = visibility
        settingColumns = false
    }
    /// Show Viewer / Hide Viewer. Showing it where the transcript pane would be too
    /// narrow hides the sidebar; hiding it again brings the sidebar back (design §3.7).
    func toggleViewer() {
        viewerHiddenByWidth = false
        if viewerVisible {
            viewerVisible = false
            if sidebarHiddenForViewer {
                sidebarHiddenForViewer = false
                if windowWidth < Self.sidebarCollapseWidth { sidebarHiddenByWidth = true }
                else { setColumns(.all) }
            }
        } else {
            viewerVisible = true
            if columnVisibility != .detailOnly, paneWidth(viewer: true, sidebar: true) < Self.minimumTranscriptPane {
                sidebarHiddenForViewer = true
                setColumns(.detailOnly)
            }
        }
    }
    /// The narrow-width rule (design §3.7): the right column collapses before the
    /// sidebar, and both come back as the window widens.
    private func fitColumns() {
        // Below 960 the sidebar collapses so the transcript's minimum fits (design §3.7).
        // An overlay shown on request stays until Escape or a row choice.
        if windowWidth < Self.sidebarCollapseWidth {
            if sidebarHiddenForViewer { sidebarHiddenByWidth = true }
            if columnVisibility != .detailOnly { setColumns(.detailOnly); sidebarHiddenByWidth = true }
        } else {
            sidebarOverlay = false
            if sidebarHiddenByWidth {
                sidebarHiddenByWidth = false
                if !sidebarHiddenForViewer { setColumns(.all) }
            }
        }
        if sidebarHiddenForViewer, paneWidth(viewer: true, sidebar: true) >= Self.minimumTranscriptPane {
            sidebarHiddenForViewer = false
            setColumns(.all)
        }
        let sidebar = columnVisibility != .detailOnly
        if viewerVisible, !sidebarHiddenForViewer, paneWidth(viewer: true, sidebar: sidebar) < Self.minimumTranscriptPane {
            viewerVisible = false
            viewerHiddenByWidth = true
        } else if viewerHiddenByWidth, paneWidth(viewer: true, sidebar: sidebar) >= Self.minimumTranscriptPane {
            viewerVisible = true
            viewerHiddenByWidth = false
        }
    }

    private func leave(fromImport: Bool = false) async -> Bool {
        // Opening, closing or locating another project waits for a running import, which
        // would replace it when it finishes (checklist step 3.1).
        if isImporting, !fromImport { notice = Self.busyCopy; return false }
        guard let document, let editor else { return true }
        if leaving || editor.exporting || editor.finding || editor.progress != nil { notice = Self.busyCopy; return false }
        // A clip title still being typed is kept before edits freeze.
        endRename()
        leaving = true
        defer {
            leaving = false
            if !retryingRecovery, pendingRecovery != nil { Task { await self.resumePendingRecovery() } }
        }
        editor.isLeaving = true
        editor.preview.pause(); editor.isPlaying = false
        await document.pendingTitleWrite?.value
        var closes = await canClose(document)
        #if DEBUG
        if injectSaveFailure { injectSaveFailure = false; closes = false }
        #endif
        guard closes, document === self.document else {
            editor.isLeaving = false
            // A named project that cannot close failed to save. Cancelling the untitled
            // keep/delete prompt is silent.
            if document.fileURL != nil { notice = "Couldn't save “\(projectTitle)”, so it stays open. Your video and edits are still here." }
            return false
        }
        detach(document, editor)
        document.close()
        return true
    }

    private func canClose(_ document: VoxClipDocument) async -> Bool {
        await withCheckedContinuation { continuation in
            let reply = CloseReply { [weak self] shouldClose in
                self?.closeReply = nil
                continuation.resume(returning: shouldClose)
            }
            closeReply = reply
            document.canClose(withDelegate: reply, shouldClose: #selector(CloseReply.document(_:shouldClose:contextInfo:)), contextInfo: nil)
        }
    }

    /// A Versions-browser version in its own read-only window (VersionWindowController).
    func attachVersion(_ version: VoxClipDocument) {
        setColumns(.detailOnly)
        attach(version, bringForward: false)
    }

    private func attach(_ next: VoxClipDocument, bringForward: Bool = true) {
        notice = nil
        var preview: (any PreviewEngine)?
        #if DEBUG
        if next.demo { preview = DemoPreviewEngine() }
        #endif
        let model = EditorModel(document: next, app: app, preview: preview)
        model.undoManager = next.undoManager
        model.window = windowController?.window
        model.onActiveClipChange = { [weak self] id in self?.followScope(id) }
        model.onNeedsSidebar = { [weak self] in self?.revealSidebar() }
        next.editorModel = model
        renaming = nil
        sidebarOverlay = false
        document = next
        editor = model
        selection = next.project.edits.activeClipId.map(SidebarItem.clip) ?? .fullTake
        if let windowController {
            // AppKit takes the title from windowTitle(forDocumentDisplayName:) here.
            next.addWindowController(windowController)
            windowController.window?.representedURL = next.fileURL
            windowController.window?.isDocumentEdited = next.isDocumentEdited
            // A project opened from Finder or Open Recent while the window is closed or
            // minimised brings it back.
            if bringForward { windowController.window?.makeKeyAndOrderFront(nil) }
            (windowController as? MainWindowController)?.restorationDidChange()
        }
        started = Task { await model.start() }
    }

    private func detach(_ closing: VoxClipDocument, _ model: EditorModel) {
        model.close()
        if closing.editorModel === model { closing.editorModel = nil }
        if let windowController, closing.windowControllers.contains(windowController) {
            closing.removeWindowController(windowController)
        }
        windowController?.window?.representedURL = nil
        windowController?.window?.isDocumentEdited = false
        renaming = nil
        document = nil
        editor = nil
        started = nil
        windowController?.window?.title = title
        (windowController as? MainWindowController)?.restorationDidChange()
    }

    #if DEBUG
    /// Holds the import slot as a running import does, until the returned closure runs.
    func holdImportForTesting() -> () -> Void {
        let task = Task<Void, Never> { while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(20)) } }
        importTask = task
        return { [weak self] in
            task.cancel()
            self?.importTask = nil
            Task { await self?.resumePendingRecovery() }
        }
    }
    /// Offscreen captures and harness checks: attaches a project to a shell that has
    /// no window and waits for its editor to start.
    func attachForTesting(_ next: VoxClipDocument, selection row: SidebarItem? = nil) async {
        attach(next)
        await started?.value
        if let row { selection = row }
    }
    #endif

    // MARK: Selection

    /// A row change applies the existing `setActiveClip` command; Home and Recent rows
    /// only pause. When the editor refuses the change, for example while its video is
    /// missing, the selection returns to the editor's scope.
    private func followSelection() {
        notice = nil
        windowController?.window?.title = title
        guard let editor else { return }
        editor.focusedSuggestion = nil
        switch selection {
        case .home, .recent: editor.preview.pause(); editor.isPlaying = false
        case .fullTake: if editor.project.edits.activeClipId != nil { editor.activate(nil) }
        case .clip(let id):
            guard editor.project.edits.activeClipId != id, let clip = editor.project.edits.clips.first(where: { $0.id == id }) else { break }
            editor.activate(clip)
        }
        guard !selection.showsHome else { return }
        let scope = editor.project.edits.activeClipId.map(SidebarItem.clip) ?? .fullTake
        if selection != scope { selection = scope }
    }

    /// Keeps the selected row in step when undo or Remove changes the active clip.
    private func followScope(_ activeClipID: String?) {
        guard !selection.showsHome else { return }
        let row = activeClipID.map(SidebarItem.clip) ?? .fullTake
        if selection != row { selection = row }
    }
}

/// Receives `canClose(withDelegate:shouldClose:contextInfo:)`'s answer.
@MainActor private final class CloseReply: NSObject {
    private let answer: (Bool) -> Void
    init(_ answer: @escaping (Bool) -> Void) { self.answer = answer }
    @objc func document(_ document: NSDocument, shouldClose: Bool, contextInfo: UnsafeMutableRawPointer?) { answer(shouldClose) }
}

/// The one app-owned main window (ADR-R29). It opens on Home, and each project's
/// document attaches to this controller while it is open.
@MainActor final class MainWindowController: NSWindowController, NSWindowDelegate, NSWindowRestoration {
    static let shared = MainWindowController(shell: AppModel.sharedModel.shell)
    let shell: WorkspaceShell
    private static let untitledAutosaveKey = "voxclip.untitledAutosave"

    init(shell: WorkspaceShell) {
        self.shell = shell
        let size = NSSize(width: VCTokens.sizeWindowDefaultWidth, height: VCTokens.sizeWindowDefaultHeight)
        let window = MainWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // Restorable only for crash recovery of a never-saved project (design §2); harness
        // runs never leave state behind.
        window.isRestorable = !AppModel.isTestSession
        #if DEBUG
        // DebugProbes: crash recovery with the window non-restorable, as before round 1e.
        if CommandLine.arguments.contains("-probeNonRestorable") { window.isRestorable = false }
        #endif
        window.restorationClass = MainWindowController.self
        window.identifier = NSUserInterfaceItemIdentifier("voxclip.main")
        window.tabbingMode = .disallowed
        window.toolbarStyle = .unified
        window.title = "VoxClip"
        window.setAccessibilityIdentifier("voxclip.main")
        super.init(window: window)
        let hosting = NSHostingController(rootView: WorkspaceView(shell: shell).environment(shell.app).sceneAccent())
        // The window, not the SwiftUI content, sets the minimum size; full screen and
        // Split View may go narrower (design §3.7).
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.minSize = NSSize(width: VCTokens.sizeWindowMinWidth, height: VCTokens.sizeWindowMinHeight)
        window.minFullScreenContentSize = NSSize(width: 640, height: 480)
        window.setContentSize(size)
        window.center()
        if !AppModel.isTestSession { window.setFrameAutosaveName("VoxClip.main") }
        window.delegate = self
        window.closeProject = { [weak shell] in await shell?.closeProject() ?? true }
        shell.windowController = self
    }
    required init?(coder: NSCoder) { nil }

    override func windowTitle(forDocumentDisplayName displayName: String) -> String { shell.title }
    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: Crash recovery (design §2)

    /// Attaching a document makes NSDocumentController the restoration class; the shell
    /// restores into this window instead.
    func restorationDidChange() {
        window?.restorationClass = MainWindowController.self
        window?.invalidateRestorableState()
    }
    func window(_ window: NSWindow, willEncodeRestorableState state: NSCoder) {
        Self.encodeRestorableState(document: shell.document, into: state)
        #if DEBUG
        DebugProbes.trace("encode: \(shell.document.map { $0.fileURL == nil ? "untitled, autosave \($0.autosavedContentsFileURL?.lastPathComponent ?? "none")" : "saved" } ?? "no project"), class \(window.restorationClass.map { String(describing: $0) } ?? "none")")
        #endif
    }
    /// Only a never-saved project's autosave is recorded. A saved project reopens from
    /// Recent, so a relaunch shows Home.
    static func encodeRestorableState(document: VoxClipDocument?, into state: NSCoder) {
        guard let document, document.fileURL == nil, !document.isVersion, let autosave = document.autosavedContentsFileURL else { return }
        state.encode(autosave as NSURL, forKey: untitledAutosaveKey)
    }
    static func restoredAutosave(from state: NSCoder) -> URL? {
        state.decodeObject(of: NSURL.self, forKey: untitledAutosaveKey) as URL?
    }
    static func restoreWindow(withIdentifier identifier: NSUserInterfaceItemIdentifier, state: NSCoder, completionHandler: @escaping (NSWindow?, (any Error)?) -> Void) {
        let controller = shared
        completionHandler(controller.window, nil)
        #if DEBUG
        DebugProbes.trace("restoreWindow: recorded autosave \(restoredAutosave(from: state)?.lastPathComponent ?? "none")")
        #endif
        guard let autosave = restoredAutosave(from: state) else { return }
        #if DEBUG
        DebugProbes.reopenedBy.append("the main window's restorable state (\(autosave.lastPathComponent))")
        #endif
        Task { await controller.shell.reopenAutosave(autosave) }
    }
}

/// A version in File > Revert To > Browse All Versions…: its own window and shell, with
/// the sidebar hidden. The editor refuses edits to it, and AppKit places and closes the
/// window with the browser.
@MainActor final class VersionWindowController: NSWindowController {
    let shell: WorkspaceShell
    init(version: VoxClipDocument, app: AppModel) {
        shell = WorkspaceShell(app: app)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.toolbarStyle = .unified
        super.init(window: window)
        window.contentViewController = NSHostingController(rootView: WorkspaceView(shell: shell).environment(app).sceneAccent())
        shell.windowController = self
        shell.attachVersion(version)
    }
    required init?(coder: NSCoder) { nil }
    override func windowTitle(forDocumentDisplayName displayName: String) -> String { shell.projectTitle }
}

/// The close button and Window > Close run the shell's leave boundary first, so
/// AppKit never closes the shared window together with a project.
@MainActor final class MainWindow: NSWindow {
    var closeProject: (() async -> Bool)?
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, EditorPane.isCycleKey(code: event.keyCode, modifiers: event.modifierFlags), attachedSheet == nil,
           let editor = AppModel.sharedModel.shell.editor, !AppModel.sharedModel.shell.showsHome {
            if let input = firstResponder as? any NSTextInputClient, input.hasMarkedText() { super.sendEvent(event); return }
            if !event.modifierFlags.contains(.shift), let text = firstResponder as? TranscriptNSTextView, text.selectionBarVisible {
                text.showSelectionBar(focus: true)
                return
            }
            editor.movePaneFocus(backward: event.modifierFlags.contains(.shift))
            return
        }
        super.sendEvent(event)
    }
    override func performClose(_ sender: Any?) {
        guard let closeProject, (windowController?.document as? VoxClipDocument) != nil else { super.performClose(sender); return }
        Task { @MainActor in if await closeProject() { closeNow() } }
    }
    private func closeNow() { super.performClose(nil) }
}
