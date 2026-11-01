#if DEBUG
import AppKit
import Testing
@testable import VoxClip
import VoxClipCore

/// A decoder that stays in flight until cancelled. Continuations make cancellation and
/// the two-slot bound deterministic, with no sleeps or live media/provider requests.
private actor FilmstripDecoderProbe {
    private var pending: [Int64: CheckedContinuation<CGImage?, Never>] = [:]
    private var starts = 0
    private(set) var cancellations: Set<Int64> = []
    private(set) var offMain = true
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    func decode(_ frame: Int64) async -> CGImage? {
        starts += 1
        offMain = offMain && !Thread.isMainThread
        let ready = waiters.filter { starts >= $0.0 }; waiters.removeAll { starts >= $0.0 }
        ready.forEach { $0.1.resume() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume(returning: nil) }
                else { pending[frame] = continuation }
            }
        } onCancel: { Task { await self.cancel(frame) } }
    }
    private func cancel(_ frame: Int64) { cancellations.insert(frame); pending.removeValue(forKey: frame)?.resume(returning: nil) }
    func waitForStarts(_ count: Int) async {
        if starts >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
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
        #expect(files == ["film-0-136x76.jpg"])
        // An unreadable original still returns the previously decoded, leased disk frame.
        let cached = await FilmstripCache.decodeFrame(.init(url: URL(fileURLWithPath: "/unused"), contentKey: source.contentKey, cache: root), 0, 0.5)
        #expect(cached != nil)
    }
}
#endif
