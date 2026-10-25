import Foundation

/// Atomic document I/O and source relinking; editing §10 and architecture §2.5, §7.1.
public protocol ProjectStore: Sendable {
    func load(from url: URL) async throws -> Project
    func save(_ project: Project, to url: URL) async throws
    func resolveSource(for project: Project, projectURL: URL) async throws -> URL
}

/// mac-editing owns actual atomic disk operations. Skeleton never overwrites a document.
public actor JSONProjectStore: ProjectStore {
    public init() {}
    public func load(from url: URL) async throws -> Project { throw VoxClipError.notImplemented("mac-editing") }
    public func save(_ project: Project, to url: URL) async throws { throw VoxClipError.notImplemented("mac-editing") }
    public func resolveSource(for project: Project, projectURL: URL) async throws -> URL { throw VoxClipError.notImplemented("mac-editing") }
}
