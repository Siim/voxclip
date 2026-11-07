import Foundation

/// The frame analyzer's cache, `Cache/<contentKey>/frames/` (architecture §8.2, ADR-R48): `analysis-v<version>.json`
/// holds one observation per source millisecond asked for, and `sheet-<ms>.jpg` the frame sheet's small JPEG of that
/// frame. Both can be made again, so the cache's first eviction pass removes the folder with the rest of what an entry
/// can rebuild, and clearing the cache drops the analysis. Folders are real folders, never links, made one level at a
/// time; an entry's key is leased while the file is written.
public struct FrameAnalysisCache: Sendable {
    public static let folder = "frames"
    public static var fileName: String { "analysis-v\(FrameAnalysis.version).json" }

    private let cacheStore: CacheStore

    public init(store: CacheStore) { self.cacheStore = store }

    public init(locations: DataLocations) { self.init(store: CacheStore(locations: locations)) }

    /// The cached observations of `contentKey` for one pass (a decode tolerance, such as `"0.250"`), keyed by the
    /// millisecond asked for; empty when there are none or the file is not this version's.
    public func observations(contentKey: String, pass: String) -> [Int: FrameObservation] {
        let prefix = pass + ":"
        var result: [Int: FrameObservation] = [:]
        for (key, value) in allFrames(contentKey: contentKey) where key.hasPrefix(prefix) {
            if let millisecond = Int(key.dropFirst(prefix.count)) { result[millisecond] = value }
        }
        return result
    }

    /// Adds observations to the cached ones of a pass, keyed by the millisecond each was asked for.
    public func store(_ observations: [(requested: Double, observation: FrameObservation)], contentKey: String, pass: String) async {
        guard !observations.isEmpty else { return }
        let lease = await cacheStore.keys.lease(contentKey)
        defer { lease.release() }
        guard let folder = folder(contentKey: contentKey, create: true) else { return }
        var merged = allFrames(contentKey: contentKey)
        for item in observations { merged["\(pass):\(Self.millisecond(item.requested))"] = item.observation }
        let file = CachedFrames(frames: merged)
        guard let data = try? AtomicJSON.encoded(file) else { return }
        try? AtomicJSON.write(data, to: folder.appendingPathComponent(Self.fileName))
    }

    private func allFrames(contentKey: String) -> [String: FrameObservation] {
        guard let folder = folder(contentKey: contentKey, create: false),
              let data = Self.readRegularFile(folder.appendingPathComponent(Self.fileName)),
              let file = try? JSONDecoder().decode(CachedFrames.self, from: data), file.schema == CachedFrames.schemaID else { return [:] }
        return file.frames
    }

    /// The pass name of a decode tolerance: its seconds with three decimals.
    public static func pass(tolerance: Double) -> String { String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), tolerance) }

    /// The cached sheet JPEG of the frame at `time`, if any.
    public func sheetImage(contentKey: String, time: Double) -> Data? {
        guard let folder = folder(contentKey: contentKey, create: false) else { return nil }
        return Self.readRegularFile(folder.appendingPathComponent("sheet-\(Self.millisecond(time)).jpg"))
    }

    public func storeSheetImage(_ data: Data, contentKey: String, time: Double) async {
        let lease = await cacheStore.keys.lease(contentKey)
        defer { lease.release() }
        guard let folder = folder(contentKey: contentKey, create: true) else { return }
        try? data.write(to: folder.appendingPathComponent("sheet-\(Self.millisecond(time)).jpg"), options: .atomic)
    }

    /// The key a time is cached under: its millisecond, rounded half away from zero.
    public static func millisecond(_ time: Double) -> Int { Int((time * 1000).rounded()) }

    /// `Cache/<contentKey>/frames/`, only for a well-formed key and only through real folders.
    func folder(contentKey: String, create: Bool) -> URL? {
        guard let entry = try? cacheStore.entryDirectory(contentKey: contentKey) else { return nil }
        let root = entry.deletingLastPathComponent()
        if !CacheStore.isRealDirectory(root) {
            guard create, (try? FileManager.default.attributesOfItem(atPath: root.path)) == nil,
                  (try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)) != nil else { return nil }
        }
        let frames = entry.appendingPathComponent(Self.folder, isDirectory: true)
        for folder in [entry, frames] where !CacheStore.isRealDirectory(folder) {
            guard create, (try? FileManager.default.attributesOfItem(atPath: folder.path)) == nil,
                  (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)) != nil,
                  CacheStore.isRealDirectory(folder) else { return nil }
        }
        return frames
    }

    /// A regular file's bytes, never through a link.
    static func readRegularFile(_ url: URL) -> Data? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
        return try? Data(contentsOf: url)
    }
}

private struct CachedFrames: Codable {
    static let schemaID = "voxclip-frames/\(FrameAnalysis.version)"
    var schema: String = CachedFrames.schemaID
    var frames: [String: FrameObservation]
}
