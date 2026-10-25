import Foundation

/// Cache metadata with no source contents; architecture §8.
public struct CacheEntry: Codable, Sendable, Equatable {
    public var schema: String = "voxclip-cache/1"
    public var contentKey: String
    public var createdAt: Date
    public var lastAccessAt: Date
    public var bytes: Int64
    public var envelope: CacheEnvelope? = nil
    public init(contentKey: String, createdAt: Date, lastAccessAt: Date, bytes: Int64) { self.contentKey = contentKey; self.createdAt = createdAt; self.lastAccessAt = lastAccessAt; self.bytes = bytes }
}

public struct CacheEnvelope: Codable, Sendable, Equatable {
    public var sampleRate: Double
    public var frameSeconds: Double
    public var count: Int
    public init(sampleRate: Double, frameSeconds: Double = 0.01, count: Int) { self.sampleRate = sampleRate; self.frameSeconds = frameSeconds; self.count = count }
}
/// Serialized cache index and eviction; architecture §7.1 and §8. Never removes installed models or in-use entries.
public actor CacheStore {
    private let root: URL
    public init(locations: DataLocations) { root = locations.cache }

    public func entry(contentKey: String) async throws -> CacheEntry? {
        guard ProjectValidation.matches(contentKey, ProjectValidation.hashPattern) else { return nil }
        let directory = root.appendingPathComponent(contentKey, isDirectory: true)
        guard isDirectory(directory), var entry = readEntry(directory), entry.contentKey == contentKey else { return nil }
        entry.lastAccessAt = Date()
        try? AtomicJSON.write(AtomicJSON.encoded(entry), to: directory.appendingPathComponent("meta.json"))
        return entry
    }

    public func record(_ entry: CacheEntry) async throws {
        try ProjectValidation.require(ProjectValidation.matches(entry.contentKey, ProjectValidation.hashPattern) && entry.schema == "voxclip-cache/1" && entry.bytes >= 0, "Invalid cache metadata")
        let directory = root.appendingPathComponent(entry.contentKey, isDirectory: true)
        if FileManager.default.fileExists(atPath: directory.path), !isDirectory(directory) { return }
        try AtomicJSON.write(AtomicJSON.encoded(entry), to: directory.appendingPathComponent("meta.json"))
    }

    func readEntry(_ directory: URL) -> CacheEntry? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("meta.json")),
              let entry = try? ProjectJSON.decoder().decode(CacheEntry.self, from: data), entry.schema == "voxclip-cache/1", entry.bytes >= 0 else { return nil }
        return entry
    }

    func isDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    public func evict(limitBytes: Int64, protectedKeys: Set<String>) async throws {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return }
        let entries = urls.filter { ProjectValidation.matches($0.lastPathComponent, ProjectValidation.hashPattern) && isDirectory($0) }.map { url in
            (url: url, entry: readEntry(url))
        }.sorted {
            let left = $0.entry?.lastAccessAt ?? .distantPast, right = $1.entry?.lastAccessAt ?? .distantPast
            return left == right ? $0.url.lastPathComponent < $1.url.lastPathComponent : left < right
        }
        let sizes = entries.map { item -> Int64 in
            guard let files = FileManager.default.enumerator(at: item.url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]) else { return item.entry?.bytes ?? 0 }
            var total: Int64 = 0
            for case let file as URL in files {
                if let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]), values.isRegularFile == true, values.isSymbolicLink != true { total += Int64(values.fileSize ?? 0) }
            }
            return max(total, item.entry?.bytes ?? 0)
        }
        var bytes = sizes.reduce(0, +)
        for (index, item) in entries.enumerated() where bytes > max(0, limitBytes) && !protectedKeys.contains(item.url.lastPathComponent) {
            do { try FileManager.default.removeItem(at: item.url); bytes -= sizes[index] } catch { continue }
        }
    }
}
