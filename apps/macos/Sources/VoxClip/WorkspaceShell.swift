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

/// The window's layout (impl-plan §3.4): which shell regions show and how big they are.
/// Per window. The sizes the user drags are kept for every project under `ui.layout.*`;
/// showing, hiding and window resizes never store one. None of it is an undo step or a
/// document change.
@MainActor @Observable final class WorkspaceLayout {
    @ObservationIgnored private let app: AppModel
    var explorerVisible = true
    var rightVisible = true
    var timelineVisible = true
    /// The timeline fills the work area (V7a's maximize button); no V1a control sets it.
    var timelineMaximized = false
    /// The window's content width, which the right column's starting width follows.
    var windowWidth = 1280.0
    /// The work area's height above the status bar, which the timeline's starting height follows.
    var workHeight = 776.0
    init(app: AppModel) { self.app = app }

    static let explorerWidthKey = "ui.layout.explorerWidth"
    static let rightWidthKey = "ui.layout.rightWidth"
    static let timelineHeightKey = "ui.layout.timelineHeight"
    /// The pre-v2 right-column width, which a saved settings file may still hold.
    static let retiredRightWidthKey = "ui.rightColumnWidth"
    /// Removes the pre-v2 right-column width from loaded settings (impl-plan item 18).
    /// True when there was one, so the settings are saved without it.
    static func retireLegacyKeys(_ values: inout [String: JSONValue]) -> Bool {
        values.removeValue(forKey: retiredRightWidthKey) != nil
    }
    static let explorerRange = Double(VCTokens.sizeSidebarMin)...Double(VCTokens.sizeSidebarMax)
    static let rightRange = Double(VCTokens.sizeRightColumnMin)...Double(VCTokens.sizeRightColumnMax)
    /// notes.md §6: the bottom panel defaults to 216; it never gets shorter than today's strip.
    static let timelineDefault = 216.0
    static let timelineRange = Double(ShellMetrics.timelineMinimum)...640.0
    /// impl-plan §3.5: the panel starts at 216 or 40% of the work area's height, whichever is less.
    static let timelineShare = 0.4

    /// The right column's width when the user never dragged it (impl-plan item 18):
    /// 404 + (W − 1280) × 0.25 within 300–560, so 404 at 1280 and 444 at 1440, narrowed
    /// toward 300 so the editor keeps its minimum beside an Explorer `explorer` wide (0
    /// while it is collapsed).
    static func rightColumnWidth(windowWidth: Double, explorer: Double = Double(VCTokens.sizeSidebarIdeal)) -> Double {
        fitted(Double(VCTokens.sizeRightColumnIdeal) + (windowWidth - 1280) * 0.25, windowWidth: windowWidth, explorer: explorer)
    }
    /// `width` within 300–560, narrowed so the editor keeps `minimumTranscriptPane` (604).
    private static func fitted(_ width: Double, windowWidth: Double, explorer: Double) -> Double {
        let room = windowWidth - explorer - WorkspaceShell.minimumTranscriptPane
        return min(width, max(room, rightRange.lowerBound)).clamped(to: rightRange)
    }
    /// The Explorer pane's width: where the user last dragged its divider, else 224.
    var explorerWidth: Double { app.number(Self.explorerWidthKey, fallback: Double(VCTokens.sizeSidebarIdeal)).clamped(to: Self.explorerRange) }
    /// The right column's width: where the user last dragged its divider, else its starting
    /// width for this window. Either is narrowed so the editor keeps its minimum beside the
    /// Explorer while it shows; a wider window gives a dragged width back.
    var rightWidth: Double {
        let explorer = explorerVisible ? explorerWidth : 0
        return Self.fitted(app.number(Self.rightWidthKey, fallback: Self.rightColumnWidth(windowWidth: windowWidth, explorer: explorer)), windowWidth: windowWidth, explorer: explorer)
    }
    /// The timeline panel's height below its top edge: where the user last dragged that
    /// edge, else 216 within 40% of the work area (impl-plan §3.5).
    var timelineHeight: Double {
        let start = min(Self.timelineDefault, (workHeight * Self.timelineShare).rounded(.down))
        return app.number(Self.timelineHeightKey, fallback: start).clamped(to: Self.timelineRange)
    }
    func rememberExplorerWidth(_ width: Double) { app.set(Self.explorerWidthKey, .number(width.rounded().clamped(to: Self.explorerRange))) }
    func rememberRightWidth(_ width: Double) { app.set(Self.rightWidthKey, .number(width.rounded().clamped(to: Self.rightRange))) }
    func rememberTimelineHeight(_ height: Double) { app.set(Self.timelineHeightKey, .number(height.rounded().clamped(to: Self.timelineRange))) }
}

/// State of the one main window (ADR-R29): the open project, its editor, the sidebar
/// selection and the window's layout. It is the only owner of `EditorModel`
/// instances. Each project stays a `VoxClipDocument`, attached to the main window's
/// controller while it is open and detached before it closes.
@MainActor @Observable final class WorkspaceShell {
    let app: AppModel
    private(set) var document: VoxClipDocument?
    private(set) var editor: EditorModel?
    var selection: SidebarItem = .home { didSet { if selection != oldValue { followSelection() } } }
    /// The shell's regions and sizes (impl-plan V1a).
    let layout: WorkspaceLayout
    /// Below `explorerCollapseWidth` (1,128) the Explorer shows over the editor on request
    /// (impl-plan §3.5): the Explorer toggle, View > Show Sidebar and Find Clips. Escape or
    /// a click on a row hides it again.
    var sidebarOverlay = false
    /// Below 904 the right column shows over the editor's trailing edge on request: Show
    /// Viewer (⌥⌘I) and the right-column toggle. Escape or Hide Viewer hides it again.
    var rightOverlay = false
    /// The clip whose title is being typed in the sidebar, and the typed title. Leaving
    /// the project and Quit keep it before edits freeze (design §6.2).
    var renaming: String?
    var renameDraft = ""
    var notice: String?
    /// A file is being dragged over the window.
    var dropTargeted = false
    /// Home's project search, kept while the editor shows.
    var homeQuery = ""
    /// The window's content width; the narrow-width rule runs when it changes.
    var windowWidth: Double {
        get { layout.windowWidth }
        set {
            let old = layout.windowWidth
            layout.windowWidth = newValue
            if abs(newValue - old) > 0.5 { fitColumns() }
        }
    }
    /// Help > Keyboard Shortcuts (⌘/), also on Home.
    var showShortcuts = false
    /// The right column was collapsed by the window's width, not by the user.
    @ObservationIgnored private var rightHiddenByWidth = false
    /// The Explorer was collapsed by the window's width, not by the user.
    @ObservationIgnored private var explorerHiddenByWidth = false
    /// The editor column's minimum width (impl-plan §3.5): the 80 gutter, a 480 measure and
    /// 44 of trailing padding. It counts the 1 pt dividers on either side, which belong to
    /// the editor's rows (ShellRegion).
    static let minimumTranscriptPane = 604.0
    /// Below this window width the right column collapses (impl-plan §3.5, full screen and
    /// Split View): the editor's minimum and the right column's, 904.
    static let rightCollapseWidth = minimumTranscriptPane + WorkspaceLayout.rightRange.lowerBound
    /// Below this window width the Explorer collapses to its overlay: the Explorer's width
    /// beside both minimums, 1,128 with a 224 Explorer.
    var explorerCollapseWidth: Double { layout.explorerWidth + Self.rightCollapseWidth }
    /// The widest the Explorer's divider can be dragged in this window: the room left beside
    /// the editor's and the right column's minimums (296 at 1200), within 220–320. So a drag
    /// never moves `explorerCollapseWidth` past the window's width, and the docked Explorer
    /// stays docked.
    var explorerMaximumWidth: Double { (windowWidth - Self.rightCollapseWidth).clamped(to: WorkspaceLayout.explorerRange) }
    /// The AppKit F6 stops of this window's shell (EditorShellController).
    @ObservationIgnored weak var chromeFocus: ShellChromeFocus?
    private(set) var importProgress: String?
    @ObservationIgnored private var importTask: Task<Void, Never>?
    @ObservationIgnored weak var windowController: NSWindowController?
    /// The attached editor's start: media resolution, probe and the first preview load.
    @ObservationIgnored private(set) var started: Task<Void, Never>?
    @ObservationIgnored private var closeReply: CloseReply?
    @ObservationIgnored private var leaving = false
    private(set) var pendingRecovery: VoxClipDocument?
    @ObservationIgnored private var additionalRecoveries: [VoxClipDocument] = []
    @ObservationIgnored private var retryingRecovery = false
    /// Bumped when the open project's title follows its file's new name.
    private var titleRevision = 0
    #if DEBUG
    /// Treats the next leave-boundary save as failed (DebugPersistence).
    @ObservationIgnored var injectSaveFailure = false
    #endif

    init(app: AppModel) {
        self.app = app
        layout = WorkspaceLayout(app: app)
    }

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
                // Keep the cache under its limit after each import, once the new project holds its lease (architecture §8.2).
                app.requestCacheEviction()
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

    /// The right column's width for this window: dragged, else its starting width.
    var rightWidth: Double { layout.rightWidth }
    /// Shows a hidden sidebar for its Find Clips callout and progress (design §6.2). Below
    /// 1,128 it shows as the overlay (impl-plan §3.5); a docked Explorer already shows.
    func revealSidebar() {
        guard !layout.explorerVisible else { return }
        if windowWidth < explorerCollapseWidth { sidebarOverlay = true; return }
        explorerHiddenByWidth = false
        layout.explorerVisible = true
    }
    /// View > Show Sidebar and Hide Sidebar (⌃⌘S) and the Explorer toggle. A docked Explorer
    /// hides at any width; a hidden one shows as the overlay below 1,128.
    func toggleSidebar() {
        if layout.explorerVisible { explorerHiddenByWidth = false; layout.explorerVisible = false; return }
        if windowWidth < explorerCollapseWidth { sidebarOverlay.toggle(); return }
        explorerHiddenByWidth = false
        layout.explorerVisible = true
    }
    var sidebarShown: Bool { layout.explorerVisible || sidebarOverlay }
    /// The right column shows, in its column or over the editor.
    var viewerShown: Bool { layout.rightVisible || rightOverlay }
    /// This window's F6 stops (impl-plan §3.2): a hidden Explorer, right column or timeline is none.
    var paneOrder: [EditorPane] { EditorPane.order(explorerVisible: sidebarShown, viewerVisible: viewerShown, timelineVisible: layout.timelineVisible) }
    /// A row the user chose in the sidebar list. A click on a row also hides the overlay
    /// sidebar (design §3.7); the arrow keys leave it open.
    func choose(_ row: SidebarItem, byClick: Bool = NSApp.currentEvent.map { $0.type == .leftMouseDown || $0.type == .leftMouseUp } ?? false) {
        selection = row
        if byClick { sidebarOverlay = false }
    }
    /// Show Viewer / Hide Viewer (⌥⌘I) and the right-column toggle. Below 904 the right
    /// column shows over the editor instead (impl-plan §3.5). From 1,128 up both columns fit
    /// beside the Explorer, because the right column narrows toward 300 first.
    func toggleViewer() {
        if windowWidth < Self.rightCollapseWidth { rightOverlay.toggle(); return }
        rightHiddenByWidth = false
        if layout.rightVisible { hideRightColumn() } else { layout.rightVisible = true }
    }
    /// The timeline toggle in the title row. ⌘J and the hover transport arrive with V7a and V4;
    /// until then the panel carries play and the timecode while the right column is hidden,
    /// so it does not hide then (notes.md §1: "play and timecode are never lost").
    func toggleTimeline() {
        guard layout.rightVisible || !layout.timelineVisible else { return }
        layout.timelineVisible.toggle()
    }
    /// Hides the right column, and shows the timeline panel, which carries the compact
    /// transport while it is hidden (until V4).
    private func hideRightColumn() {
        layout.rightVisible = false
        if !layout.timelineVisible { layout.timelineVisible = true }
    }
    /// The narrow-size rule (impl-plan §3.5): below 1,128 the Explorer collapses and shows
    /// over the editor on request; below 904 (full screen or Split View) the right column
    /// does the same. Each comes back as the window widens, unless the user hid it. An
    /// overlay shown on request stays until Escape, a row choice or a hide, and goes when
    /// its column fits again.
    private func fitColumns() {
        if windowWidth < explorerCollapseWidth {
            if layout.explorerVisible { layout.explorerVisible = false; explorerHiddenByWidth = true }
        } else {
            sidebarOverlay = false
            if explorerHiddenByWidth { explorerHiddenByWidth = false; layout.explorerVisible = true }
        }
        if windowWidth < Self.rightCollapseWidth {
            if layout.rightVisible { hideRightColumn(); rightHiddenByWidth = true }
        } else {
            rightOverlay = false
            if rightHiddenByWidth { rightHiddenByWidth = false; layout.rightVisible = true }
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

    /// A Versions-browser version in its own read-only window (VersionWindowController):
    /// the same shell with the Explorer collapsed, as if the user hid it.
    func attachVersion(_ version: VoxClipDocument) {
        explorerHiddenByWidth = false
        layout.explorerVisible = false
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
        rightOverlay = false
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

/// A window controller whose window hosts a v2 shell: the main window and each Versions
/// window. F6 in its window moves through that shell's panes.
@MainActor protocol ShellWindowController: NSWindowController {
    var shell: WorkspaceShell { get }
}

/// The one app-owned main window (ADR-R29). It opens on Home, and each project's
/// document attaches to this controller while it is open.
@MainActor final class MainWindowController: NSWindowController, NSWindowDelegate, NSWindowRestoration, ShellWindowController {
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
        EditorShellController.prepare(window)
        window.title = "VoxClip"
        window.setAccessibilityIdentifier("voxclip.main")
        super.init(window: window)
        let hosting = NSHostingController(rootView: WorkspaceView(shell: shell).environment(shell.app).sceneAccent())
        // The window, not the SwiftUI content, sets the minimum size; full screen and
        // Split View may go narrower (design §3.7). The shell sets the title itself and
        // has no toolbar, so SwiftUI manages neither.
        hosting.sizingOptions = []
        hosting.sceneBridgingOptions = []
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

/// A version in File > Revert To > Browse All Versions…: its own window and shell, the
/// same frame as the main window with the Explorer collapsed (impl-plan V1b). The editor
/// refuses edits to it, and AppKit places and closes the window with the browser.
@MainActor final class VersionWindowController: NSWindowController, ShellWindowController {
    let shell: WorkspaceShell
    init(version: VoxClipDocument, app: AppModel) {
        shell = WorkspaceShell(app: app)
        let window = MainWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.tabbingMode = .disallowed
        EditorShellController.prepare(window)
        super.init(window: window)
        let hosting = NSHostingController(rootView: WorkspaceView(shell: shell).environment(app).sceneAccent())
        hosting.sizingOptions = []
        hosting.sceneBridgingOptions = []
        window.contentViewController = hosting
        window.minSize = NSSize(width: VCTokens.sizeWindowMinWidth, height: VCTokens.sizeWindowMinHeight)
        window.minFullScreenContentSize = NSSize(width: 640, height: 480)
        window.setContentSize(NSSize(width: 1100, height: 720))
        shell.windowController = self
        shell.attachVersion(version)
    }
    required init?(coder: NSCoder) { nil }
    override func windowTitle(forDocumentDisplayName displayName: String) -> String { shell.projectTitle }
}

/// The window of a shell: the main window and each Versions window. F6 moves through its
/// own shell's panes. On the main window the close button and Window > Close run the
/// shell's leave boundary first, so AppKit never closes the shared window together with a
/// project; a Versions window has no `closeProject` and closes with its version.
@MainActor final class MainWindow: NSWindow {
    var closeProject: (() async -> Bool)?
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, EditorPane.isCycleKey(code: event.keyCode, modifiers: event.modifierFlags), attachedSheet == nil,
           let shell = (windowController as? ShellWindowController)?.shell, shell.editor != nil, !shell.showsHome {
            if let input = firstResponder as? any NSTextInputClient, input.hasMarkedText() { super.sendEvent(event); return }
            if !event.modifierFlags.contains(.shift), let text = firstResponder as? TranscriptNSTextView, text.selectionBarVisible {
                text.showSelectionBar(focus: true)
                return
            }
            shell.movePaneFocus(backward: event.modifierFlags.contains(.shift))
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
