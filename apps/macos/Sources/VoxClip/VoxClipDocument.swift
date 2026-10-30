import AppKit
import SwiftUI
import UniformTypeIdentifiers
import Synchronization
import VoxClipCore
import VoxClipMedia

extension UTType {
    public static let voxclipProject = UTType(exportedAs: "com.voxconvo.voxclip.project", conformingTo: .json)
}

/// One AppKit document owns the native write and undo lifecycle.
@objc(VoxClipDocument) public final class VoxClipDocument: NSDocument, ObservableObject {
    private struct State {
        var project: Project
        var revision = 0
        var mediaResolved = false
        var warnings: [String] = []
        /// A duplicate's source file name, which its title may still be (design §2).
        var inheritedName: String?
    }
    private struct WriteSnapshot {
        let project: Project
        let revision: Int
        let destination: URL
        let source: MediaReference
        /// The title before a Save As or Move gave it the file's new name.
        let titleBefore: String?
    }
    /// A Save As or Move to a new file name, which the written title may follow.
    private struct NameChange {
        let previous: URL?
        let destination: URL
    }
    private let state: Mutex<State>
    @MainActor private var retainedVoiceLabFiles: Set<String> = []
    private let projectUndoManager = UndoManager()
    private let pendingWrite = Mutex<WriteSnapshot?>(nil)
    private let nameChange = Mutex<NameChange?>(nil)
    @MainActor private(set) var pendingTitleWrite: Task<Void, Never>?
    #if DEBUG
    @MainActor var injectTitleWriteFailure = false
    final class WriteBarrier: @unchecked Sendable {
        let arrived = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
    }
    private let writeBarrier = Mutex<WriteBarrier?>(nil)
    func installWriteBarrier(_ barrier: WriteBarrier?) { writeBarrier.withLock { $0 = barrier } }
    private let failNextMoveRemoval = Mutex(false)
    func injectMoveRemovalFailure() { failNextMoveRemoval.withLock { $0 = true } }
    struct BoundaryEvent: Codable {
        let phase: String
        let projectID: String
        let location: String?
        let relativePath: String?
        let styleID: String
    }
    private let boundaryEvents = Mutex<[BoundaryEvent]>([])
    func saveBoundaryEvents() -> [BoundaryEvent] { boundaryEvents.withLock { $0 } }
    nonisolated private func recordBoundary(_ phase: String, project: Project, destination: URL?) {
        guard CommandLine.arguments.contains("-saveBoundaryAudit") else { return }
        boundaryEvents.withLock { $0.append(BoundaryEvent(phase: phase, projectID: project.id, location: destination?.path, relativePath: project.media.source.relativePath, styleID: project.captions.styleId)) }
    }
    #endif
    let demo: Bool
    @MainActor weak var editorModel: EditorModel?
    public var project: Project { state.withLock { $0.project } }

    public override init() {
        demo = false
        let now = Date()
        let source = MediaReference(absolutePath: "/", sizeBytes: 0, durationSeconds: 0, contentKey: String(repeating: "0", count: 64))
        state = Mutex(State(project: Project(id: UUID().uuidString.lowercased(), createdAt: now, modifiedAt: now, savedBy: ProjectWriter(version: AppVersion.projectWriterVersion), media: ProjectMedia(source: source))))
        super.init()
    }
    init(data: Data) throws {
        demo = false
        let (project, warnings) = try JSONProjectStore.decodeReportingWarnings(data)
        state = Mutex(State(project: project, warnings: warnings))
        super.init()
    }
    public init(project: Project, demo: Bool = false) {
        self.demo = demo
        state = Mutex(State(project: project))
        super.init()
    }
    public convenience init(importing url: URL) async throws {
        let now = Date()
        let key = try await Task.detached(priority: .userInitiated) { try JSONProjectStore.contentKey(for: url) }.value
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let source = MediaReference(absolutePath: url.path, sizeBytes: Int64(size), durationSeconds: 0, contentKey: key)
        let title = Self.defaultTitle(url.deletingPathExtension().lastPathComponent)
        self.init(project: Project(id: UUID().uuidString.lowercased(), title: title, createdAt: now, modifiedAt: now, savedBy: ProjectWriter(version: AppVersion.projectWriterVersion), media: ProjectMedia(source: source)))
        setMediaResolved(true)
    }

    /// A file or video name as a title, as import sets it: trimmed, at most 200 scalars.
    nonisolated static func defaultTitle(_ name: String) -> String? {
        let trimmed = EditingPrimitives.jsTrim(name)
        return trimmed.isEmpty ? nil : String(String.UnicodeScalarView(trimmed.unicodeScalars.prefix(200)))
    }
    /// The title after Save As, Move or Rename gives the file a new name (design §2): the
    /// new name while the title is still a default (unset, the video's name as import set
    /// it, or a previous file name), else nil and the title stays.
    nonisolated static func followingTitle(_ project: Project, previousNames: [String], destination: URL) -> String? {
        guard let name = defaultTitle(destination.deletingPathExtension().lastPathComponent) else { return nil }
        let title = project.title.flatMap { $0.isEmpty ? nil : $0 }
        guard title != name else { return nil }
        let path = project.media.source.absolutePath
        let video = path == "/" || path.isEmpty ? nil : defaultTitle(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)
        guard title == nil || title == video || previousNames.compactMap(defaultTitle).contains(title ?? "") else { return nil }
        return name
    }
    nonisolated private func previousNames(_ previous: URL?) -> [String] {
        [previous?.deletingPathExtension().lastPathComponent, state.withLock { $0.inheritedName }].compactMap { $0 }
    }
    /// An untitled project's name, never "Untitled" (design §2): `Project.title`, else the
    /// video's name. The keep/delete prompt and the Save panel's name field read it.
    override public func defaultDraftName() -> String {
        if let title = project.title, !title.isEmpty { return title }
        let path = project.media.source.absolutePath
        guard path != "/", !path.isEmpty, let name = Self.defaultTitle(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent) else {
            return super.defaultDraftName()
        }
        return name
    }

    nonisolated override public class var autosavesInPlace: Bool { true }
    nonisolated override public class var preservesVersions: Bool { true }
    nonisolated override public class var writableTypes: [String] { [UTType.voxclipProject.identifier] }
    // EditorModel records each accepted edit and its inverse explicitly. Keep
    // AppKit from also counting undo-group notifications as a second edit.
    override public var hasUndoManager: Bool { get { false } set {} }
    override public var undoManager: UndoManager? { get { projectUndoManager } set {} }

    func setMediaResolved(_ resolved: Bool) { state.withLock { $0.mediaResolved = resolved } }
    @MainActor func markEdited() { updateChangeCount(.changeDone) }
    func reportWarnings(to logger: any Logger) async {
        let warnings = state.withLock { current in let result = current.warnings; current.warnings.removeAll(); return result }
        for warning in warnings { await logger.write(LogEntry(level: .warn, category: "import", message: warning)) }
    }
    @MainActor public func replaceProject(_ project: Project) {
        guard project != self.project else { return }
        retainedVoiceLabFiles.formUnion(VoiceLabAssetRetention.references(in: self.project))
        retainedVoiceLabFiles.formUnion(VoiceLabAssetRetention.references(in: project))
        objectWillChange.send()
        state.withLock { $0.project = project; $0.revision += 1 }
    }
    override public func read(from data: Data, ofType typeName: String) throws {
        let (project, warnings) = try JSONProjectStore.decodeReportingWarnings(data)
        let previousID = state.withLock { current -> String in
            let oldID = current.project.id
            current.project = project; current.revision += 1; current.warnings = warnings; current.mediaResolved = false
            return oldID
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.objectWillChange.send()
            self.editorModel?.reloadFromDocument(previousProjectID: previousID)
        }
    }
    override public func revert(toContentsOf url: URL, ofType typeName: String) throws {
        try super.revert(toContentsOf: url, ofType: typeName)
        projectUndoManager.removeAllActions()
    }
    /// Projects never own a window: the app-owned main window hosts whichever one is
    /// open (ADR-R29). AppKit asking for windows routes the document through the
    /// shell's leave boundary.
    override public func makeWindowControllers() {
        let shell = AppModel.sharedModel.shell
        // File > Revert To > Browse All Versions… shows each version read-only in its
        // own window; the main window's project stays attached.
        if isVersion { _ = VersionWindowController(version: self, app: AppModel.sharedModel); return }
        #if DEBUG
        DebugProbes.reopenedBy.append("AppKit asking the document for windows (\(fileURL == nil ? "untitled" : "saved"), autosave \(autosavedContentsFileURL?.lastPathComponent ?? "none"))")
        #endif
        if shell.document === self {
            if let controller = shell.windowController, !windowControllers.contains(controller) { addWindowController(controller) }
            return
        }
        if shell.closesRecoveredCopy(self) { return }
        Task { @MainActor in if !(await shell.replaceProject(with: self)) { shell.retainRecovery(self) } }
    }
    /// A version shown by the Versions browser. It is read-only and never replaces the
    /// open project.
    var isVersion: Bool {
        #if DEBUG
        if versionForTesting { return true }
        #endif
        return isInViewingMode
    }
    override public func rename(_ sender: Any?) {
        guard !isVersion, AppModel.sharedModel.shell.editor?.isLeaving != true else { return }
        super.rename(sender)
    }
    override public func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(NSDocument.rename(_:)) {
            return !isVersion && (AppModel.sharedModel.shell.document !== self || AppModel.sharedModel.shell.editor?.capabilities.rename == true)
        }
        return super.validateUserInterfaceItem(item)
    }
    #if DEBUG
    /// Treats this document as a Versions-browser version (harness checks).
    var versionForTesting = false
    #endif
    override public func close() {
        if let editorModel {
            let anotherOpen = NSDocumentController.shared.documents.contains(where: { document in
                guard let other = document as? VoxClipDocument else { return false }
                return other !== self && other.project.id == project.id
            })
            retainedVoiceLabFiles.formUnion(VoiceLabAssetRetention.references(in: project))
            do {
                try VoiceLabAssetRetention.closeProject(projectId: project.id,
                    paidRoot: editorModel.app.locations.root.appendingPathComponent("VoiceLab"), references: retainedVoiceLabFiles, allowDeletion: !anotherOpen)
            } catch {
                let logger = editorModel.app.log
                Task { await logger.write(LogEntry(level: .warn, category: "voice-lab", message: "Asset cleanup deferred; paid media is safe.")) }
            }
        }
        for case let version as VersionWindowController in windowControllers {
            version.shell.documentWillClose(self)
            version.close()
        }
        AppModel.sharedModel.shell.documentWillClose(self)
        editorModel = nil
        projectUndoManager.removeAllActions()
        super.close()
    }

    override public func updateChangeCount(_ change: NSDocument.ChangeType) {
        super.updateChangeCount(change)
        syncWindowEditedState()
    }
    private func syncWindowEditedState() {
        for controller in windowControllers { controller.window?.isDocumentEdited = isDocumentEdited }
    }

    override public func canAsynchronouslyWrite(to url: URL, ofType typeName: String, for saveOperation: SaveOperationType) -> Bool { true }

    /// The outer safe-write URL is final; the inner write URL may be temporary.
    override public func writeSafely(to url: URL, ofType typeName: String, for saveOperation: SaveOperationType) throws {
        let change = nameChange.withLock { $0 }.flatMap { $0.destination.standardizedFileURL == url.standardizedFileURL ? $0 : nil }
        let names = change.map { previousNames($0.previous) } ?? []
        let snapshot = state.withLock { current -> WriteSnapshot in
            var project = current.project
            project.savedBy = ProjectWriter(version: AppVersion.projectWriterVersion)
            project.modifiedAt = Date()
            if current.mediaResolved && project.media.source.absolutePath != "/" {
                project.media.source.relativePath = JSONProjectStore.relativePath(source: URL(fileURLWithPath: project.media.source.absolutePath), projectURL: url)
            }
            // Save As and Move write the file's new name as the title while it is a default.
            if change != nil, let title = Self.followingTitle(project, previousNames: names, destination: url) { project.title = title }
            return WriteSnapshot(project: project, revision: current.revision, destination: url, source: current.project.media.source, titleBefore: current.project.title)
        }
        pendingWrite.withLock { $0 = snapshot }
        #if DEBUG
        recordBoundary("snapshot", project: snapshot.project, destination: url)
        #endif
        unblockUserInteraction()
        #if DEBUG
        if let barrier = writeBarrier.withLock({ $0 }) {
            barrier.arrived.signal()
            barrier.release.wait()
        }
        #endif
        try super.writeSafely(to: url, ofType: typeName, for: saveOperation)
    }
    override public func write(to url: URL, ofType typeName: String, for saveOperation: SaveOperationType, originalContentsURL: URL?) throws {
        guard let snapshot = pendingWrite.withLock({ $0 }) else { throw CocoaError(.fileWriteUnknown) }
        let data = try JSONProjectStore.encode(snapshot.project)
        #if DEBUG
        recordBoundary("write", project: snapshot.project, destination: url)
        #endif
        try data.write(to: url)
    }
    override public func save(to url: URL, ofType typeName: String, for saveOperation: SaveOperationType, completionHandler: @escaping (Error?) -> Void) {
        if saveOperation == .saveAsOperation { nameChange.withLock { $0 = NameChange(previous: fileURL, destination: url) } }
        super.save(to: url, ofType: typeName, for: saveOperation) { [weak self] error in
            guard let self else { completionHandler(error); return }
            let snapshot = self.pendingWrite.withLock { pending -> WriteSnapshot? in let result = pending; pending = nil; return result }
            if saveOperation == .saveAsOperation { self.nameChange.withLock { $0 = nil } }
            var retitled = false
            if error == nil, let snapshot, snapshot.destination == url,
               saveOperation != .saveToOperation && saveOperation != .autosaveElsewhereOperation && saveOperation != .autosaveAsOperation {
                retitled = self.state.withLock { current -> Bool in
                    // The written title follows the new name; no undo step or edit of its own.
                    var retitled = false
                    if saveOperation == .saveAsOperation {
                        current.inheritedName = nil
                        if snapshot.project.title != snapshot.titleBefore, current.project.title == snapshot.titleBefore {
                            current.project.title = snapshot.project.title
                            retitled = true
                        }
                    }
                    guard current.project.media.source.contentKey == snapshot.source.contentKey,
                          current.project.media.source.absolutePath == snapshot.source.absolutePath else { return retitled }
                    current.project.media.source.relativePath = snapshot.project.media.source.relativePath
                    if current.revision == snapshot.revision {
                        current.project.savedBy = snapshot.project.savedBy
                        current.project.modifiedAt = snapshot.project.modifiedAt
                    }
                    return retitled
                }
            }
            if error == nil, saveOperation != .saveToOperation && saveOperation != .autosaveElsewhereOperation {
                AppModel.sharedModel.noteRecent(url)
            }
            self.syncWindowEditedState()
            if retitled { self.titleDidFollowName() }
            // An untitled project's autosave location is what crash recovery reopens.
            AppModel.sharedModel.shell.documentRestorationChanged(self)
            completionHandler(error)
        }
    }
    /// The title followed the file's new name: the window, the sidebar, Home and Open
    /// Recent show it.
    @MainActor private func titleDidFollowName() {
        for controller in windowControllers { controller.synchronizeWindowTitleWithDocumentName() }
        AppModel.sharedModel.shell.documentTitleDidChange(self)
        AppModel.sharedModel.recentProjects.refresh(AppModel.sharedModel.recent)
    }
    /// File > Duplicate: the copy's title still follows its first Save As while it is
    /// the original's file name.
    override public func duplicate() throws -> NSDocument {
        let copy = try super.duplicate()
        if let copy = copy as? VoxClipDocument, let name = fileURL?.deletingPathExtension().lastPathComponent {
            copy.state.withLock { $0.inheritedName = name }
        }
        return copy
    }
    override public func move(to url: URL, completionHandler: ((Error?) -> Void)?) {
        guard let original = fileURL else {
            super.move(to: url, completionHandler: completionHandler)
            return
        }
        // A rename within a folder does not change the media's relative path. A default
        // title follows the new name, written in place: no undo step and no edited dot.
        if original.deletingLastPathComponent().standardizedFileURL == url.deletingLastPathComponent().standardizedFileURL {
            let titleBefore = project.title
            super.move(to: url) { [weak self] error in
                guard let self, error == nil else { completionHandler?(error); return }
                AppModel.sharedModel.moveRecent(from: original, to: url)
                let names = self.previousNames(original)
                let retitled = self.state.withLock { current -> Bool in
                    guard current.project.title == titleBefore, let title = Self.followingTitle(current.project, previousNames: names, destination: url) else { return false }
                    current.project.title = title
                    current.revision += 1
                    return true
                }
                guard retitled else { completionHandler?(nil); return }
                // The move calls back while it still holds the document's file access, and
                // a save started inside it would keep writing after the access ends. The
                // in-place write starts once the move has let go, and takes its own.
                self.pendingTitleWrite = Task { @MainActor in
                    let error: Error?
                    #if DEBUG
                    if self.injectTitleWriteFailure {
                        self.injectTitleWriteFailure = false
                        error = CocoaError(.fileWriteUnknown)
                    } else {
                        error = await self.writeFollowedTitle(to: url)
                    }
                    #else
                    error = await self.writeFollowedTitle(to: url)
                    #endif
                    if error != nil { self.updateChangeCount(.changeDone) }
                    self.titleDidFollowName()
                    self.pendingTitleWrite = nil
                    completionHandler?(error)
                }
            }
            return
        }
        let changeToken = changeCountToken(for: .saveAsOperation)
        let startRevision = state.withLock { $0.revision }
        let titleBefore = project.title
        let destinationExisted = FileManager.default.fileExists(atPath: url.path)
        let priorDestination: Data?
        do { priorDestination = destinationExisted ? try Data(contentsOf: url) : nil }
        catch { completionHandler?(error); return }
        func restoreDestination() -> Error? {
            var coordinationError: NSError?
            var rollbackError: Error?
            NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: destinationExisted ? .forReplacing : .forDeleting, error: &coordinationError) { coordinatedURL in
                do {
                    if let priorDestination { try priorDestination.write(to: coordinatedURL, options: .atomic) }
                    else { try FileManager.default.removeItem(at: coordinatedURL) }
                } catch { rollbackError = error }
            }
            return rollbackError ?? coordinationError
        }
        // Write a copy without changing AppKit's location or change count. Only
        // adopt it after coordinated removal of the original has succeeded. Its title
        // follows the new name while it is a default.
        nameChange.withLock { $0 = NameChange(previous: original, destination: url) }
        save(to: url, ofType: UTType.voxclipProject.identifier, for: .saveToOperation) { [weak self] error in
            guard let self else { completionHandler?(error); return }
            self.nameChange.withLock { $0 = nil }
            if let error { completionHandler?(error); return }
            let saved: Project
            do { saved = try JSONProjectStore.decode(Data(contentsOf: url)) }
            catch { completionHandler?(restoreDestination() ?? error); return }
            var coordinationError: NSError?
            var removalError: Error?
            #if DEBUG
            let injectedFailure = self.failNextMoveRemoval.withLock { flag -> Bool in let result = flag; flag = false; return result }
            #else
            let injectedFailure = false
            #endif
            if injectedFailure {
                removalError = CocoaError(.fileWriteNoPermission)
            } else {
                NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: original, options: .forDeleting, error: &coordinationError) { coordinatedURL in
                    do { try FileManager.default.removeItem(at: coordinatedURL) }
                    catch { removalError = error }
                }
            }
            if let failure = removalError ?? coordinationError {
                completionHandler?(restoreDestination() ?? failure)
                return
            }
            let retitled = self.state.withLock { current -> Bool in
                let retitled = saved.title != titleBefore && current.project.title == titleBefore
                if retitled { current.project.title = saved.title }
                guard current.project.media.source.contentKey == saved.media.source.contentKey,
                      current.project.media.source.absolutePath == saved.media.source.absolutePath else { return retitled }
                current.project.media.source.relativePath = saved.media.source.relativePath
                if current.revision == startRevision {
                    current.project.savedBy = saved.savedBy
                    current.project.modifiedAt = saved.modifiedAt
                }
                return retitled
            }
            self.fileURL = url
            self.updateChangeCount(withToken: changeToken, for: .saveAsOperation)
            // Token completion does not call updateChangeCount(_:). It may leave
            // a post-snapshot edit dirty, so mirror AppKit's resulting state.
            self.syncWindowEditedState()
            AppModel.sharedModel.moveRecent(from: original, to: url)
            if retitled { self.titleDidFollowName() }
            completionHandler?(nil)
        }
    }

    @MainActor private func writeFollowedTitle(to url: URL) async -> Error? {
        await withCheckedContinuation { continuation in
            save(to: url, ofType: fileType ?? UTType.voxclipProject.identifier, for: .autosaveInPlaceOperation) { error in
                continuation.resume(returning: error)
            }
        }
    }

    #if DEBUG
    func snapshot(contentType: UTType) throws -> Project { snapshotForTests(destination: fileURL) }
    func snapshotForTests(destination: URL?) -> Project {
        var copy = project
        copy.savedBy = ProjectWriter(version: AppVersion.projectWriterVersion)
        copy.modifiedAt = Date()
        if state.withLock({ $0.mediaResolved }), let destination {
            copy.media.source.relativePath = JSONProjectStore.relativePath(source: URL(fileURLWithPath: copy.media.source.absolutePath), projectURL: destination)
        }
        return copy
    }
    @MainActor func updateLocation(_ url: URL?) { fileURL = url }
    @MainActor func adoptOpenedLocation(_ url: URL?) { fileURL = url }
    /// Harness sessions never autosave a never-saved project into the user's Autosave
    /// Information folder. One a check gave an autosave location still autosaves there.
    override public func autosave(withImplicitCancellability autosavingIsImplicitlyCancellable: Bool, completionHandler: @escaping (Error?) -> Void) {
        if AppModel.isTestSession, fileURL == nil, autosavedContentsFileURL == nil { completionHandler(nil); return }
        super.autosave(withImplicitCancellability: autosavingIsImplicitlyCancellable, completionHandler: completionHandler)
    }
    #endif
}
