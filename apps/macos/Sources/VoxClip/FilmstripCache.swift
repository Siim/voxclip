import AVFoundation
import CoreGraphics
import Foundation
import VoxClipCore

struct FilmstripSource: Equatable, Sendable {
    let url: URL
    let contentKey: String
    let cache: URL?
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
    private let decode: Decode
    private var images: [Int64: (image: CGImage, used: Int)] = [:]
    private var clock = 0
    private var generation = -1
    private var stopped = false
    private var queue: [Int64] = []
    private var wanted: Set<Int64> = []
    private var tolerance = 0.5
    private var loading: [Int64: Task<Void, Never>] = [:]
    private var deliver: Delivery?
    private(set) var started = 0
    private(set) var cancelled = 0
    private(set) var mostInFlight = 0
    var inFlight: Set<Int64> { Set(loading.keys) }
    var queued: [Int64] { queue }

    init(source: FilmstripSource, decode: @escaping Decode = FilmstripCache.decodeFrame) {
        self.source = source
        self.decode = decode
    }

    /// Generations also reject a stale main-actor update queued before a newer scroll.
    func want(_ frames: [Int64], tolerance: Double, generation: Int, deliver: @escaping Delivery) async {
        guard !stopped, generation > self.generation else { return }
        self.generation = generation
        self.deliver = deliver
        self.tolerance = tolerance
        wanted = Set(frames)
        for (frame, task) in loading where !wanted.contains(frame) && !task.isCancelled {
            task.cancel()
            cancelled += 1
        }
        var seen = Set<Int64>()
        queue = frames.filter { images[$0] == nil && (loading[$0] == nil || loading[$0]!.isCancelled) && seen.insert($0).inserted }
        let cached = frames.compactMap { frame -> (Int64, CGImage)? in
            guard let entry = images[frame] else { return nil }
            clock += 1
            images[frame] = (entry.image, clock)
            return (frame, entry.image)
        }
        pump()
        for (frame, image) in cached { await deliver(frame, image) }
    }

    func cancelAll() {
        // This cache belongs to one lane/source lifetime. Reject an update that was queued
        // by the main actor before teardown but reaches us after this cancellation.
        stopped = true
        wanted = []; queue = []; deliver = nil
        for task in loading.values where !task.isCancelled { task.cancel(); cancelled += 1 }
    }

    private func pump() {
        while loading.count < Self.concurrentLoads {
            guard let index = queue.firstIndex(where: { loading[$0] == nil }) else { break }
            let frame = queue.remove(at: index)
            started += 1
            let source = source, decode = decode, tolerance = tolerance
            loading[frame] = Task { [weak self] in
                let image = await decode(source, frame, tolerance)
                let accepted = Task.isCancelled ? nil : image
                await self?.finished(frame, image: accepted)
            }
            mostInFlight = max(mostInFlight, loading.count)
        }
    }

    private func finished(_ frame: Int64, image: CGImage?) async {
        loading[frame] = nil
        if let image, wanted.contains(frame) {
            clock += 1
            images[frame] = (image, clock)
            queue.removeAll { $0 == frame }
            if images.count > Self.memoryLimit {
                let stale = images.sorted { $0.value.used < $1.value.used }.prefix(images.count - Self.memoryLimit * 3 / 4).map(\.key)
                for key in stale { images[key] = nil }
            }
            if let deliver { await deliver(frame, image) }
        }
        pump()
    }

    /// Reads the frame from the take's cache entry, or decodes it from the take and stores it
    /// there. The entry is leased while it is read or written (architecture §8.2).
    nonisolated static func decodeFrame(_ source: FilmstripSource, _ frame: Int64, _ tolerance: Double) async -> CGImage? {
        var lease: CacheKeyLease?
        if let cache = source.cache { lease = await CacheKeyRegistry.shared(cache: cache).lease(source.contentKey) }
        defer { lease?.release() }
        let name = "film-\(frame)-\(Int(pixelSize.width))x\(Int(pixelSize.height)).jpg"
        if let folder = ThumbnailCache.posterFolder(in: source.cache, contentKey: source.contentKey, create: false),
           let image = ThumbnailCache.readPoster(folder.appendingPathComponent(name)) { return image }
        guard !Task.isCancelled else { return nil }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: source.url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = pixelSize
        let slack = CMTime(seconds: max(1.0 / Double(TimelineFilmstrip.fps), tolerance), preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = slack
        generator.requestedTimeToleranceAfter = slack
        let request = FilmstripRequest(generator)
        let time = CMTime(seconds: Double(frame) / Double(TimelineFilmstrip.fps), preferredTimescale: 600)
        let image = await withTaskCancellationHandler {
            await request.image(at: time)
        } onCancel: {
            request.cancel()
        }
        guard let image, !Task.isCancelled else { return nil }
        if let folder = ThumbnailCache.posterFolder(in: source.cache, contentKey: source.contentKey, create: true) {
            ThumbnailCache.writePoster(image, to: folder.appendingPathComponent(name))
        }
        return image
    }
}

/// One frame decode. `cancelAllCGImageGeneration` is safe to call from the cancellation handler.
private final class FilmstripRequest: @unchecked Sendable {
    private let generator: AVAssetImageGenerator
    init(_ generator: AVAssetImageGenerator) { self.generator = generator }
    func image(at time: CMTime) async -> CGImage? { try? await generator.image(at: time).image }
    func cancel() { generator.cancelAllCGImageGeneration() }
}
