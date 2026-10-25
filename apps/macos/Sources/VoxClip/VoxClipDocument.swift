import Foundation
import SwiftUI
import UniformTypeIdentifiers
import Synchronization
import VoxClipCore

extension UTType {
    /// Portable project type; architecture §3 and editing §10.1.
    public static let voxclipProject = UTType(exportedAs: "com.voxconvo.voxclip.project", conformingTo: .json)
}

/// System document lifecycle; architecture §3, §7.1. Snapshots are protected for background document writes.
public final class VoxClipDocument: ReferenceFileDocument {
    public typealias Snapshot = Project
    public static var readableContentTypes: [UTType] { [.voxclipProject] }
    private let storage: Mutex<Project>
    private let location = Mutex<URL?>(nil)
    private let warnings = Mutex<[String]>([])
    private let resolvedMedia = Mutex(false)
    let demo: Bool
    public var project: Project { storage.withLock { $0 } }

    public init() {
        demo = false
        let now = Date()
        let source = MediaReference(absolutePath: "/", sizeBytes: 0, durationSeconds: 0, contentKey: String(repeating: "0", count: 64))
        storage = Mutex(Project(id: UUID().uuidString.lowercased(), createdAt: now, modifiedAt: now, media: ProjectMedia(source: source)))
    }

    public convenience init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw VoxClipError.projectUnreadable("No JSON document") }
        try self.init(data: data)
    }

    init(data: Data) throws {
        demo = false
        let (project, messages) = try JSONProjectStore.decodeReportingWarnings(data)
        storage = Mutex(project)
        warnings.withLock { $0 = messages }
    }

    public init(project: Project, demo: Bool = false) { storage = Mutex(project); self.demo = demo }

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

    @MainActor func adoptOpenedLocation(_ url: URL?) { location.withLock { $0 = url } }
    func setMediaResolved(_ resolved: Bool) { resolvedMedia.withLock { $0 = resolved } }

    @MainActor func updateLocation(_ url: URL?) {
        let changed = location.withLock { stored in let changed = stored != url; stored = url; return changed }
        if changed, resolvedMedia.withLock({ $0 }), let url, JSONProjectStore.relativePath(source: URL(fileURLWithPath: project.media.source.absolutePath), projectURL: url) != project.media.source.relativePath {
            objectWillChange.send()
            markEdited()
        }
    }
    @MainActor func markEdited() {
        if let url = fileURL { NSDocumentController.shared.document(for: url)?.updateChangeCount(.changeDone) }
    }
    var fileURL: URL? { location.withLock { $0 } }

    func reportWarnings(to logger: any Logger) async {
        let messages = warnings.withLock { messages in let pending = messages; messages.removeAll(); return pending }
        for message in messages { await logger.write(LogEntry(level: .warn, category: "import", message: message)) }
    }

    @MainActor public func replaceProject(_ project: Project) {
        guard project != self.project else { return }
        objectWillChange.send()
        storage.withLock { $0 = project }
    }

    public func snapshot(contentType: UTType) throws -> Project {
        var snapshot = project
        snapshot.savedBy = ProjectWriter(version: AppModel.version)
        snapshot.modifiedAt = Date()
        if resolvedMedia.withLock({ $0 }), let url = location.withLock({ $0 }) {
            snapshot.media.source.relativePath = JSONProjectStore.relativePath(source: URL(fileURLWithPath: snapshot.media.source.absolutePath), projectURL: url)
        }
        return snapshot
    }
    public func fileWrapper(snapshot: Project, configuration: WriteConfiguration) throws -> FileWrapper {
        let data = try JSONProjectStore.encode(snapshot)
        storage.withLock { current in
            if current.media.source.absolutePath == snapshot.media.source.absolutePath {
                current.media.source.relativePath = snapshot.media.source.relativePath
                current.savedBy = snapshot.savedBy
            }
        }
        return FileWrapper(regularFileWithContents: data)
    }
}
