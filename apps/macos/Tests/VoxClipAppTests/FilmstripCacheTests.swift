#if DEBUG
import AppKit
import Testing
@testable import VoxClip
import VoxClipCore

/// A decoder that stays in flight until cancelled. Continuations make cancellation and
/// the two-slot bound deterministic, with no sleeps or live media/provider requests.
private actor FilmstripDecoderProbe {
    private var pending: [Int64: TestContinuation<CGImage?>] = [:]
    private var starts = 0
    private var automaticImage: CGImage?
    private(set) var cancellations: Set<Int64> = []
    private(set) var offMain = true
    private var waiters: [(Int, TestContinuation<Void>)] = []
    func decode(_ frame: Int64) async -> CGImage? {
        starts += 1
        offMain = offMain && !Thread.isMainThread
        let ready = waiters.filter { starts >= $0.0 }; waiters.removeAll { starts >= $0.0 }
        ready.forEach { $0.1.resume() }
        if let automaticImage { return automaticImage }
        return await withTaskCancellationHandler {
            await withTestDeadline(returning: Optional<CGImage>.none) { continuation in
                if Task.isCancelled { continuation.resume(returning: nil) }
                else { pending[frame] = continuation }
            }
        } onCancel: { Task { await self.cancel(frame) } }
    }
    func completeAll(with image: CGImage) {
        automaticImage = image
        let continuations = Array(pending.values); pending = [:]
        continuations.forEach { $0.resume(returning: image) }
    }
    private func cancel(_ frame: Int64) { cancellations.insert(frame); pending.removeValue(forKey: frame)?.resume(returning: nil) }
    func waitForStarts(_ count: Int) async {
        if starts >= count { return }
        await withTestDeadline { waiters.append((count, $0)) }
    }
}

@Suite("V9 filmstrip", .serialized)
struct FilmstripCacheTests {
    @Test func scrollingCancelsOldFramesAndKeepsTwoDecoderSlots() async {
        let probe = FilmstripDecoderProbe()
        let cache = FilmstripCache(source: .init(url: URL(fileURLWithPath: "/unused"), contentKey: "test", cache: nil), decode: { _, frame, _ in await probe.decode(frame) })
        await cache.want([0, 30, 60, 90], tolerance: 0.5, generation: 1) { _, _ in Issue.record("Cancelled frames must not be delivered") }
        await probe.waitForStarts(2)
        #expect(await cache.inFlight == [0, 30])
        await cache.want([300, 330, 360], tolerance: 0.5, generation: 2) { _, _ in Issue.record("The test decoder never completes") }
        await probe.waitForStarts(4)
        #expect(await probe.cancellations == [0, 30])
        #expect(await cache.inFlight == [300, 330])
        #expect(await cache.queued == [360])
        #expect(await cache.mostInFlight == 2)
        #expect(await probe.offMain)
        // An older viewport arriving late cannot undo the newer scroll.
        await cache.want([0], tolerance: 0.5, generation: 1) { _, _ in Issue.record("Stale scroll delivered") }
        #expect(await cache.inFlight == [300, 330])
        await cache.cancelAll()
        let started = await cache.started
        await cache.want([900], tolerance: 0.5, generation: 3) { _, _ in Issue.record("Torn-down lane delivered") }
        #expect(await cache.started == started)
        #expect(await cache.queued.isEmpty)
    }

    @Test func realFrameDecodesIntoTheEvictableTakeCache() async throws {
        let shared = try SharedResources.locate()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-filmstrip-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = FilmstripSource(url: shared.root.appendingPathComponent("fixtures/media/bars-1080p.mp4"), contentKey: String(repeating: "a", count: 64), cache: root)
        let image = await FilmstripCache.decodeFrame(source, 0, 0.5)
        let decoded = try #require(image)
        #expect(decoded.width <= 136 && decoded.height <= 76)
        let folder = root.appendingPathComponent(source.contentKey).appendingPathComponent("thumbs")
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(files == ["film-0-t300-136x76.jpg"])
        // An unreadable original still returns the previously decoded, leased disk frame.
        let cached = await FilmstripCache.decodeFrame(.init(url: URL(fileURLWithPath: "/unused"), contentKey: source.contentKey, cache: root), 0, 0.5)
        #expect(cached != nil)
    }
    private func image(red: CGFloat, blue: CGFloat) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: red, green: 0, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        return try #require(context.makeImage())
    }

    @MainActor @Test func closeZoomNeverReceivesALooseMemoryFrame() async throws {
        let loose = try image(red: 1, blue: 0), fine = try image(red: 0, blue: 1)
        let cache = FilmstripCache(source: .init(url: URL(fileURLWithPath: "/unused"), contentKey: "tolerance", cache: nil),
            decode: { _, _, tolerance in tolerance > 1 ? loose : fine })
        var received: [CGImage] = []
        await cache.want([30], tolerance: 150, generation: 1) { _, image in received.append(image) }
        await cache.waitUntilIdle()
        #expect(received.count == 1)
        #expect(NSBitmapImageRep(cgImage: try #require(received.last)).colorAt(x: 0, y: 0)?.redComponent == 1)
        await cache.want([30], tolerance: 0.1, generation: 2) { _, image in received.append(image) }
        await cache.waitUntilIdle()
        #expect(await cache.started == 2, "The same frame number needs a new decode at a tighter tolerance")
        #expect(NSBitmapImageRep(cgImage: try #require(received.last)).colorAt(x: 0, y: 0)?.blueComponent == 1)
        await cache.want([30], tolerance: 0.1, generation: 3) { _, image in received.append(image) }
        #expect(await cache.started == 2 && received.count == 3, "The tight frame is reusable at the same tolerance")
        await cache.cancelAll()
    }

    @Test func closeZoomIgnoresLooseAndLegacyDiskFrames() async throws {
        let shared = try SharedResources.locate()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-filmstrip-tolerance-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = FilmstripSource(url: shared.root.appendingPathComponent("fixtures/media/bars-1080p.mp4"), contentKey: String(repeating: "b", count: 64), cache: root)
        let loose = try #require(await FilmstripCache.decodeFrame(source, 0, 150))
        let folder = root.appendingPathComponent(source.contentKey).appendingPathComponent("thumbs")
        ThumbnailCache.writePoster(loose, to: folder.appendingPathComponent("film-0-136x76.jpg"))
        let missing = FilmstripSource(url: URL(fileURLWithPath: "/unused"), contentKey: source.contentKey, cache: root)
        #expect(await FilmstripCache.decodeFrame(missing, 0, 0.1) == nil, "Neither a loose frame nor a legacy frame-only file is a tight cache hit")
        #expect(await FilmstripCache.decodeFrame(source, 0, 0.1) != nil)
        #expect(await FilmstripCache.decodeFrame(missing, 0, 0.1) != nil)
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(Set(files) == ["film-0-136x76.jpg", "film-0-t90000-136x76.jpg", "film-0-t60-136x76.jpg"])
    }

    @MainActor @Test func successiveNativeFramesReuseOneAsset() async throws {
        let shared = try SharedResources.locate()
        let cache = FilmstripCache(source: .init(url: shared.root.appendingPathComponent("fixtures/media/bars-1080p.mp4"), contentKey: "asset-reuse", cache: nil))
        var frames: [Int64] = []
        await cache.want([0, 30], tolerance: 0.1, generation: 1) { frame, _ in frames.append(frame) }
        await cache.waitUntilIdle()
        #expect(Set(frames) == [0, 30])
        let stats = await cache.decodeStatistics()
        #expect(stats.assets == 1 && stats.decodes == 2, "A source keeps one asset for all frame requests")
        #expect(stats.offMain)
        await cache.cancelAll()
    }

    @MainActor @Test func videoLaneRequestsCancelsReceivesAndRedraws() async throws {
        let probe = FilmstripDecoderProbe()
        let cache = FilmstripCache(source: .init(url: URL(fileURLWithPath: "/unused"), contentKey: "lane", cache: nil), decode: { _, frame, _ in await probe.decode(frame) })
        let lane = VideoLane(frame: NSRect(x: 0, y: 0, width: 500, height: 36), cacheFactory: { _ in cache })
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10_000, y: -10_000), size: lane.frame.size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = lane
        defer { lane.cancelLoads(); window.contentView = nil; window.close() }
        lane.state = .init(viewport: .init(axis: .source, ptPerSecond: 20, origin: 0, width: 388),
            pieces: TimelinePieces([TimelinePiece(source: 0..<120, edited: 0..<120)]), takeLength: 120)
        lane.setSource(.init(url: URL(fileURLWithPath: "/unused"), contentKey: "lane", cache: nil))
        lane.requestFrames()
        await probe.waitForStarts(2)
        let old = await cache.inFlight
        #expect(old.count == 2)
        lane.state.viewport.origin = 30
        lane.requestFrames()
        await probe.waitForStarts(4)
        #expect(await probe.cancellations == old, "Scrolling retires the old viewport's decodes")
        let invalidations = lane.invalidations
        await probe.completeAll(with: try image(red: 1, blue: 0))
        await cache.waitUntilIdle()
        #expect(lane.invalidations > invalidations, "A delivered image redraws V1")
        let bitmap = try DebugTimeline.sRGBBitmap(of: lane)
        #expect(lane.tiles > 0)
        let pixel = DebugTimeline.pixel(bitmap, x: Int((lane.headerWidth + 20) * CGFloat(bitmap.pixelsWide) / lane.bounds.width), y: Int(18 * CGFloat(bitmap.pixelsHigh) / lane.bounds.height))
        #expect(pixel[0] > pixel[1] + 0.5 && pixel[0] > pixel[2] + 0.5, "The decoder's red frame reaches the actual filmstrip pixels: \(pixel)")
        await lane.cancelLoads()?.value
        await cache.waitUntilIdle()
        let starts = await cache.started
        await cache.want([9000], tolerance: 0.1, generation: 999) { _, _ in Issue.record("A torn-down lane delivered") }
        #expect(await cache.started == starts)
    }

}
#endif
