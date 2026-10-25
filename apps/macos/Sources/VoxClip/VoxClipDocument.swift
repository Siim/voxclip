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
    public var project: Project { storage.withLock { $0 } }

    public init() {
        let now = Date()
        let source = MediaReference(absolutePath: "/", sizeBytes: 0, durationSeconds: 0, contentKey: String(repeating: "0", count: 64))
        storage = Mutex(Project(id: UUID().uuidString.lowercased(), createdAt: now, modifiedAt: now, media: ProjectMedia(source: source)))
    }

    public init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw VoxClipError.projectUnreadable("No JSON document") }
        storage = Mutex(try ProjectJSON.decode(data))
    }

    @MainActor public func replaceProject(_ project: Project) {
        objectWillChange.send()
        storage.withLock { $0 = project }
    }

    public func snapshot(contentType: UTType) throws -> Project { project }
    public func fileWrapper(snapshot: Project, configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try ProjectJSON.encode(snapshot))
    }
}
