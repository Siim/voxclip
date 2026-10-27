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
    /// Files earlier builds left at the cache root instead of a source's entry, removed on sight (architecture §8.2):
    /// the extraction products, Apple speech's CAF copies and the temporaries of interrupted writes on either platform.
    static let legacyRootNames: Set<String> = ["audio-16k.wav", "envelope-10ms.f32", "meta.json"]
    static let legacyRootShapes: [(prefix: String, suffix: String)] = [("apple-", ".caf"), ("audio-16k-", ".partial"),
        ("audio-16k.wav.", ".partial"), ("envelope-", ".partial"), ("meta.json.", ".partial")]
    static let envelopeFile = "envelope-10ms.f32"
    /// What the first eviction pass keeps: the envelope and the raw transcripts, which may be paid results, with meta.json.
    static let keptByStripping: Set<String> = [envelopeFile, "transcripts", "meta.json"]

    private let root: URL
    public init(locations: DataLocations) { root = locations.cache }

    /// The source's own entry, `<cache>/<contentKey>/`; only a lowercase SHA-256 key names one (architecture §8.2).
    public nonisolated func entryDirectory(contentKey: String) throws -> URL {
        try ProjectValidation.require(ProjectValidation.matches(contentKey, ProjectValidation.hashPattern), "Invalid cache key")
        return root.appendingPathComponent(contentKey, isDirectory: true)
    }

    /// Extracts transcription audio into the source's own entry and records it in meta.json, so no two sources share
    /// audio-16k.wav or envelope-10ms.f32 (architecture §8.2). Removes the files earlier builds left at the cache root.
    public func extractAudio(sourceURL: URL, contentKey: String, durationSeconds: Double, audioTrackIndex: Int = 0, using extractor: any AudioExtractor,
                             progress: @escaping @Sendable (Double) -> Void) async throws -> AudioExtractionResult {
        let directory = try entryDirectory(contentKey: contentKey)
        // An entry is a real folder or nothing yet: never extract through a link (architecture §8.2).
        if let type = (try? FileManager.default.attributesOfItem(atPath: directory.path))?[.type] as? FileAttributeType, type != .typeDirectory {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "Cache entries cannot be symbolic links."])
        }
        removeLegacyRootFiles()
        let result = try await extractor.extract(AudioExtractionRequest(sourceURL: sourceURL, contentKey: contentKey, durationSeconds: durationSeconds,
                                                                        audioTrackIndex: audioTrackIndex, cacheDirectory: directory), progress: progress)
        let now = Date()
        var entry = readEntry(directory).flatMap { $0.contentKey == contentKey ? $0 : nil } ?? CacheEntry(contentKey: contentKey, createdAt: now, lastAccessAt: now, bytes: 0)
        entry.lastAccessAt = now
        entry.bytes = size(directory, skipping: "meta.json")
        entry.envelope = CacheEnvelope(sampleRate: result.envelope.sampleRate, count: result.envelope.levels.count)
        try? await record(entry)  // a missing or stale meta.json is a cache miss, never an error
        return result
    }

    /// Deletes the regular files at the cache root that match a legacy name or shape; never links, folders or anything
    /// inside an entry.
    public func removeLegacyRootFiles() {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return }
        for name in names where Self.isLegacyRootFile(name) {
            let url = root.appendingPathComponent(name)
            guard (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeRegular else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    static func isLegacyRootFile(_ name: String) -> Bool {
        legacyRootNames.contains(name) || legacyRootShapes.contains {
            name.count > $0.prefix.count + $0.suffix.count && name.hasPrefix($0.prefix) && name.hasSuffix($0.suffix)
        }
    }

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
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .utcTimestamp(allowingOffset: true)  // any RFC 3339 offset (architecture §8.2)
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("meta.json")),
              let entry = try? decoder.decode(CacheEntry.self, from: data), entry.schema == "voxclip-cache/1", entry.bytes >= 0 else { return nil }
        return entry
    }

    func isDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    /// Removes unused cache, least recently used entries first, until the cache holds at most `limitBytes`
    /// (architecture §8.2). Entries first lose what can be made again (audio-16k.wav, thumbnails, faces) and keep their
    /// waveform envelope, raw transcripts and meta.json; an entry left with neither an envelope nor transcripts goes
    /// whole. Only if that is not enough do whole entries go. `keepingEnvelopes` stops before that second pass: "Clear
    /// cache" keeps envelopes and transcripts, "Clear everything" does not.
    public func evict(limitBytes: Int64, protectedKeys: Set<String>, keepingEnvelopes: Bool = false) async throws {
        removeLegacyRootFiles()
        guard let urls = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return }
        let entries = urls.filter { ProjectValidation.matches($0.lastPathComponent, ProjectValidation.hashPattern) && isDirectory($0) }.map { url in
            (url: url, entry: readEntry(url))
        }.sorted {
            let left = $0.entry?.lastAccessAt ?? .distantPast, right = $1.entry?.lastAccessAt ?? .distantPast
            return left == right ? $0.url.lastPathComponent < $1.url.lastPathComponent : left < right
        }
        var sizes = entries.map { max(size($0.url), $0.entry?.bytes ?? 0) }
        var bytes = sizes.reduce(0, +), removed = Set<Int>()
        let limit = max(0, limitBytes)
        for (index, item) in entries.enumerated() where bytes > limit && !protectedKeys.contains(item.url.lastPathComponent) {
            let files = (try? FileManager.default.contentsOfDirectory(at: item.url, includingPropertiesForKeys: nil)) ?? []
            for file in files where !Self.keptByStripping.contains(file.lastPathComponent) { try? FileManager.default.removeItem(at: file) }
            guard holdsKeptData(item.url) else {
                if (try? FileManager.default.removeItem(at: item.url)) != nil { bytes -= sizes[index]; removed.insert(index) }
                continue
            }
            if var entry = item.entry {
                entry.bytes = size(item.url, skipping: "meta.json")
                try? AtomicJSON.write(AtomicJSON.encoded(entry), to: item.url.appendingPathComponent("meta.json"))
            }
            let left = size(item.url)
            bytes -= sizes[index] - left; sizes[index] = left
        }
        guard !keepingEnvelopes else { return }
        for (index, item) in entries.enumerated() where bytes > limit && !removed.contains(index) && !protectedKeys.contains(item.url.lastPathComponent) {
            do { try FileManager.default.removeItem(at: item.url); bytes -= sizes[index] } catch { continue }
        }
    }

    /// Whether a stripped entry still holds its envelope or any raw transcript.
    func holdsKeptData(_ entry: URL) -> Bool {
        FileManager.default.fileExists(atPath: entry.appendingPathComponent(Self.envelopeFile).path)
            || !((try? FileManager.default.contentsOfDirectory(atPath: entry.appendingPathComponent("transcripts").path)) ?? []).isEmpty
    }

    /// Bytes of the regular files under a directory, not following links.
    func size(_ directory: URL, skipping skipped: String? = nil) -> Int64 {
        guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in files where file.lastPathComponent != skipped {
            if let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]), values.isRegularFile == true, values.isSymbolicLink != true { total += Int64(values.fileSize ?? 0) }
        }
        return total
    }
}
