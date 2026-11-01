import AVFoundation
import CoreGraphics
import Foundation
import VoxClipCore

struct FilmstripSource: Equatable, Sendable {
    let url: URL
    let contentKey: String
    let cache: URL?
}

/// The same nominal frame at two zoom levels can decode to different actual times.
/// Round tolerance down to the generator's timebase so a cache hit is never looser
/// than its caller requested. Legacy frame-only disk entries are deliberately ignored.
struct FilmstripFrameKey: Hashable, Sendable {
    let frame: Int64
    let toleranceTicks: Int64
    init(_ frame: Int64, tolerance: Double) {
        self.frame = frame
        let seconds = tolerance.isFinite ? max(1.0 / Double(TimelineFilmstrip.fps), tolerance) : 1.0 / Double(TimelineFilmstrip.fps)
        toleranceTicks = max(20, Int64(min(seconds * 600, Double(Int64.max / 2)).rounded(.down)))
    }
    var tolerance: Double { Double(toleranceTicks) / 600 }
    var filename: String { "film-\(frame)-t\(toleranceTicks)-136x76.jpg" }
}

struct FilmstripDecodeStatistics: Sendable {
    nonisolated static var offMainThread: Bool { !Thread.isMainThread }
    var assets = 0
    var decodes = 0
    var offMain = true
    var firstDecodeMS = 0.0
    var lastDecodeMS = 0.0
}

/// Off-main decoding and bounded scheduling. Cancelled requests keep their slot until
/// their decoder returns, so rapid scrolling never starts more than two decoders.
actor FilmstripCache {
    typealias Decode = @Sendable (FilmstripSource, Int64, Double) async -> CGImage?
    typealias Delivery = @MainActor @Sendable (Int64, CGImage) -> Void
    static let pixelSize = CGSize(width: 136, height: 76)
    static let concurrentLoads = 2
    static let memoryLimit = 320
    let source: FilmstripSource
    private let decode: Decode?
    private var nativeDecoder: FilmstripDecoder?
    private var images: [FilmstripFrameKey: (image: CGImage, used: Int)] = [:]
    private var clock = 0
    private var generation = -1
    private var stopped = false
    private var queue: [FilmstripFrameKey] = []
    private var wanted: Set<FilmstripFrameKey> = []
    private var loading: [FilmstripFrameKey: Task<Void, Never>] = [:]
    private var deliver: Delivery?
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var started = 0
    private(set) var cancelled = 0
    private(set) var mostInFlight = 0
    var inFlight: Set<Int64> { Set(loading.keys.map(\.frame)) }
    var queued: [Int64] { queue.map(\.frame) }

    init(source: FilmstripSource, decode: Decode? = nil) {
        self.source = source
        self.decode = decode
    }

    /// Generations also reject a stale main-actor update queued before a newer scroll.
    func want(_ frames: [Int64], tolerance: Double, generation: Int, deliver: @escaping Delivery) async {
        guard !stopped, generation > self.generation else { return }
        self.generation = generation
        self.deliver = deliver
        let keys = frames.map { FilmstripFrameKey($0, tolerance: tolerance) }
        wanted = Set(keys)
        for (key, task) in loading where !wanted.contains(key) && !task.isCancelled {
            task.cancel()
            cancelled += 1
        }
        var seen = Set<FilmstripFrameKey>()
        queue = keys.filter { images[$0] == nil && (loading[$0] == nil || loading[$0]!.isCancelled) && seen.insert($0).inserted }
        let cached = keys.compactMap { key -> (Int64, CGImage)? in
            guard let entry = images[key] else { return nil }
            clock += 1
            images[key] = (entry.image, clock)
            return (key.frame, entry.image)
        }
        pump()
        for (frame, image) in cached {
            guard generation == self.generation else { break }
            await deliver(frame, image)
        }
    }

    func cancelAll() {
        stopped = true
        wanted = []; queue = []; deliver = nil
        for task in loading.values where !task.isCancelled { task.cancel(); cancelled += 1 }
        resumeIdleWaiters()
    }

    /// A completion barrier for off-main work, including cancellation; it does not spin
    /// the main run loop or return before queued main-actor deliveries have completed.
    func waitUntilIdle() async {
        if loading.isEmpty && queue.isEmpty { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }
    func decodeStatistics() async -> FilmstripDecodeStatistics {
        await nativeDecoder?.statistics ?? FilmstripDecodeStatistics()
    }
    private func resumeIdleWaiters() {
        guard loading.isEmpty && queue.isEmpty else { return }
        let waiters = idleWaiters; idleWaiters = []
        waiters.forEach { $0.resume() }
    }
    private func pump() {
        while loading.count < Self.concurrentLoads {
            guard let index = queue.firstIndex(where: { loading[$0] == nil }) else { break }
            let key = queue.remove(at: index)
            started += 1
            if decode == nil && nativeDecoder == nil { nativeDecoder = FilmstripDecoder(source: source) }
            let source = source, decode = decode, native = nativeDecoder
            loading[key] = Task { [weak self] in
                let image: CGImage?
                if let decode { image = await decode(source, key.frame, key.tolerance) }
                else { image = await native?.image(key) }
                let accepted = Task.isCancelled ? nil : image
                await self?.finished(key, image: accepted)
            }
            mostInFlight = max(mostInFlight, loading.count)
        }
        resumeIdleWaiters()
    }
    private func finished(_ key: FilmstripFrameKey, image: CGImage?) async {
        // Keep the slot occupied through delivery, so waitUntilIdle includes that hop.
        if let image, wanted.contains(key) {
            clock += 1
            images[key] = (image, clock)
            queue.removeAll { $0 == key }
            if images.count > Self.memoryLimit {
                let stale = images.sorted { $0.value.used < $1.value.used }.prefix(images.count - Self.memoryLimit * 3 / 4).map(\.key)
                for key in stale { images[key] = nil }
            }
            if let deliver { await deliver(key.frame, image) }
        }
        loading[key] = nil
        pump()
    }

    #if DEBUG
    /// Test hook: one-shot disk-cache entry point. A lane's normal scheduler instead retains one
    /// FilmstripDecoder (and at most one asset) for its single source lifetime.
    nonisolated static func decodeFrame(_ source: FilmstripSource, _ frame: Int64, _ tolerance: Double) async -> CGImage? {
        await FilmstripDecoder(source: source).image(FilmstripFrameKey(frame, tolerance: tolerance))
    }
    #endif
}

/// One confined AVFoundation object graph per source: a single reused asset and no more
/// than the scheduler's two generators. Setup, file access and decode stay off main.
private actor FilmstripDecoder {
    let source: FilmstripSource
    private var asset: AVURLAsset?
    private var requests: [UUID: AVAssetImageGenerator] = [:]
    private(set) var statistics = FilmstripDecodeStatistics()
    init(source: FilmstripSource) { self.source = source }

    func image(_ key: FilmstripFrameKey) async -> CGImage? {
        var lease: CacheKeyLease?
        if let cache = source.cache { lease = await CacheKeyRegistry.shared(cache: cache).lease(source.contentKey) }
        defer { lease?.release() }
        if let folder = ThumbnailCache.posterFolder(in: source.cache, contentKey: source.contentKey, create: false),
           let image = ThumbnailCache.readPoster(folder.appendingPathComponent(key.filename), immediately: true) { return image }
        guard !Task.isCancelled else { return nil }
        let began = ContinuousClock.now
        statistics.offMain = statistics.offMain && FilmstripDecodeStatistics.offMainThread
        if asset == nil { asset = AVURLAsset(url: source.url); statistics.assets += 1 }
        guard let asset else { return nil }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = FilmstripCache.pixelSize
        let slack = CMTime(value: key.toleranceTicks, timescale: 600)
        generator.requestedTimeToleranceBefore = slack
        generator.requestedTimeToleranceAfter = slack
        let time = CMTime(value: key.frame, timescale: Int32(TimelineFilmstrip.fps))
        let id = UUID()
        requests[id] = generator
        defer {
            requests[id] = nil
            let elapsed = began.duration(to: .now)
            let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
            if statistics.decodes == 0 { statistics.firstDecodeMS = ms }
            statistics.decodes += 1; statistics.lastDecodeMS = ms
        }
        let image: CGImage? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, image, _, result, _ in
                    continuation.resume(returning: result == .succeeded ? image : nil)
                }
            }
        } onCancel: { Task { await self.cancel(id) } }
        guard let image, !Task.isCancelled else { return nil }
        if let folder = ThumbnailCache.posterFolder(in: source.cache, contentKey: source.contentKey, create: true) {
            ThumbnailCache.writePoster(image, to: folder.appendingPathComponent(key.filename))
        }
        return image
    }
    private func cancel(_ id: UUID) { requests[id]?.cancelAllCGImageGeneration() }
}
