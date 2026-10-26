import AppKit
import SwiftUI
import UniformTypeIdentifiers
import Synchronization
import VoxClipCore

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
    }
    private struct WriteSnapshot {
        let project: Project
        let revision: Int
        let destination: URL
        let source: MediaReference
    }
    private let state: Mutex<State>
    private let projectUndoManager = UndoManager()
    private let pendingWrite = Mutex<WriteSnapshot?>(nil)
    #if DEBUG
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
        state = Mutex(State(project: Project(id: UUID().uuidString.lowercased(), createdAt: now, modifiedAt: now, media: ProjectMedia(source: source))))
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
        let name = EditingPrimitives.jsTrim(url.deletingPathExtension().lastPathComponent)
        let title = name.isEmpty ? nil : String(String.UnicodeScalarView(name.unicodeScalars.prefix(200)))
        self.init(project: Project(id: UUID().uuidString.lowercased(), title: title, createdAt: now, modifiedAt: now, media: ProjectMedia(source: source)))
        setMediaResolved(true)
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
    override public func makeWindowControllers() {
        let app = AppModel.sharedModel
        let hosting = NSHostingController(rootView: EditorView(document: self, app: app).environment(app).sceneAccent())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.contentViewController = hosting
        window.minSize = NSSize(width: 800, height: 560)
        window.toolbarStyle = .unified
        window.center()
        addWindowController(NSWindowController(window: window))
    }
    override public func close() {
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
        let snapshot = state.withLock { current -> WriteSnapshot in
            var project = current.project
            project.savedBy = ProjectWriter(version: AppModel.version)
            project.modifiedAt = Date()
            if current.mediaResolved && project.media.source.absolutePath != "/" {
                project.media.source.relativePath = JSONProjectStore.relativePath(source: URL(fileURLWithPath: project.media.source.absolutePath), projectURL: url)
            }
            return WriteSnapshot(project: project, revision: current.revision, destination: url, source: current.project.media.source)
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
        super.save(to: url, ofType: typeName, for: saveOperation) { [weak self] error in
            guard let self else { completionHandler(error); return }
            let snapshot = self.pendingWrite.withLock { pending -> WriteSnapshot? in let result = pending; pending = nil; return result }
            if error == nil, let snapshot, snapshot.destination == url,
               saveOperation != .saveToOperation && saveOperation != .autosaveElsewhereOperation && saveOperation != .autosaveAsOperation {
                self.state.withLock { current in
                    guard current.project.media.source.contentKey == snapshot.source.contentKey,
                          current.project.media.source.absolutePath == snapshot.source.absolutePath else { return }
                    current.project.media.source.relativePath = snapshot.project.media.source.relativePath
                    if current.revision == snapshot.revision {
                        current.project.savedBy = snapshot.project.savedBy
                        current.project.modifiedAt = snapshot.project.modifiedAt
                    }
                }
            }
            if error == nil, saveOperation != .saveToOperation && saveOperation != .autosaveElsewhereOperation {
                AppModel.sharedModel.noteRecent(url)
            }
            self.syncWindowEditedState()
            completionHandler(error)
        }
    }
    override public func move(to url: URL, completionHandler: ((Error?) -> Void)?) {
        guard let original = fileURL else {
            super.move(to: url, completionHandler: completionHandler)
            return
        }
        // A rename within a folder does not change the media's relative path.
        if original.deletingLastPathComponent().standardizedFileURL == url.deletingLastPathComponent().standardizedFileURL {
            super.move(to: url) { error in
                if error == nil { AppModel.sharedModel.moveRecent(from: original, to: url) }
                completionHandler?(error)
            }
            return
        }
        let changeToken = changeCountToken(for: .saveAsOperation)
        let startRevision = state.withLock { $0.revision }
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
        // adopt it after coordinated removal of the original has succeeded.
        save(to: url, ofType: UTType.voxclipProject.identifier, for: .saveToOperation) { [weak self] error in
            guard let self else { completionHandler?(error); return }
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
            self.state.withLock { current in
                guard current.project.media.source.contentKey == saved.media.source.contentKey,
                      current.project.media.source.absolutePath == saved.media.source.absolutePath else { return }
                current.project.media.source.relativePath = saved.media.source.relativePath
                if current.revision == startRevision {
                    current.project.savedBy = saved.savedBy
                    current.project.modifiedAt = saved.modifiedAt
                }
            }
            self.fileURL = url
            self.updateChangeCount(withToken: changeToken, for: .saveAsOperation)
            // Token completion does not call updateChangeCount(_:). It may leave
            // a post-snapshot edit dirty, so mirror AppKit's resulting state.
            self.syncWindowEditedState()
            AppModel.sharedModel.moveRecent(from: original, to: url)
            completionHandler?(nil)
        }
    }

    #if DEBUG
    func snapshot(contentType: UTType) throws -> Project { snapshotForTests(destination: fileURL) }
    func snapshotForTests(destination: URL?) -> Project {
        var copy = project
        copy.savedBy = ProjectWriter(version: AppModel.version)
        copy.modifiedAt = Date()
        if state.withLock({ $0.mediaResolved }), let destination {
            copy.media.source.relativePath = JSONProjectStore.relativePath(source: URL(fileURLWithPath: copy.media.source.absolutePath), projectURL: destination)
        }
        return copy
    }
    @MainActor func updateLocation(_ url: URL?) { fileURL = url }
    @MainActor func adoptOpenedLocation(_ url: URL?) { fileURL = url }
    #endif
}
