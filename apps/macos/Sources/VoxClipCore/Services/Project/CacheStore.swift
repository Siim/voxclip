import Foundation

/// Cache metadata with no source contents; architecture §8.
public struct CacheEntry: Codable, Sendable, Equatable {
    public var contentKey: String
    public var createdAt: Date
    public var lastAccessAt: Date
    public var bytes: Int64
    public init(contentKey: String, createdAt: Date, lastAccessAt: Date, bytes: Int64) { self.contentKey = contentKey; self.createdAt = createdAt; self.lastAccessAt = lastAccessAt; self.bytes = bytes }
}
/// Serialized cache index and eviction; architecture §7.1 and §8. Never removes installed models or in-use entries.
public actor CacheStore {
    public init(locations: DataLocations) {}
    public func entry(contentKey: String) async throws -> CacheEntry? { throw VoxClipError.notImplemented("mac-editing") }
    public func evict(limitBytes: Int64, protectedKeys: Set<String>) async throws { throw VoxClipError.notImplemented("mac-editing") }
}
