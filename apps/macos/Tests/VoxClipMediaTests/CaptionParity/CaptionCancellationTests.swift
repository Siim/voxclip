import Foundation
import Testing
import VoxClipCore
@testable import VoxClipMedia

private final class CaptionShadowFault: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false
    func arm() { lock.withLock { armed = true } }
    func check(_ index: Int) throws {
        let fail = lock.withLock {
            guard armed, index == 0 else { return false }
            armed = false
            return true
        }
        if fail { throw CaptionFailure.invalid("Injected shadow-pass failure") }
    }
}

@Suite(.serialized)
struct CaptionCancellationTests {
    private func compare(_ actual: CaptionRaster, _ expected: CaptionRaster, context: String) {
        var artifacts: URL?
        if actual.rgba != expected.rgba {
            let changes = zip(actual.rgba, expected.rgba).enumerated().filter { $0.element.0 != $0.element.1 }
            let maximum = changes.map { abs(Int($0.element.0) - Int($0.element.1)) }.max() ?? 0
            print("CANCELLATION_DIFF \(context): bytes=\(changes.count), max=\(maximum), first=\(changes.first?.offset ?? -1)")
            artifacts = CaptionFailureArtifacts.write(actual, expected, context: context)
        }
        #expect(actual.rgba == expected.rgba, "\(context); mismatch images: \(artifacts?.path ?? "none")")
    }

    @Test("Fresh and reused renderers remain byte-identical before any cancellation")
    func coldRendererRepeatability() async throws {
        let shared = try CaptionMediaFixtures.shared()
        for name in ["neon", "editorial"] {
            let track = try await layout(name, shared: shared)
            let expected = try CaptionRenderPool(shared: shared, cacheLimit: 0)
                .band(track, time: 0.62, width: 1080, reduceMotion: false).raster()
            let independent = try CaptionRenderPool(shared: shared, cacheLimit: 0)
                .band(track, time: 0.62, width: 1080, reduceMotion: false).raster()
            compare(expected, independent, context: "\(name) first expected vs independent cold reference")
            for iteration in 0..<24 {
                let actual = try await Task.detached {
                    let pool = CaptionRenderPool(shared: shared, cacheLimit: 0)
                    if iteration % 2 == 0 { _ = try pool.band(track, time: 0.4, width: 1080, reduceMotion: false) }
                    return try pool.band(track, time: 0.62, width: 1080, reduceMotion: false).raster()
                }.value
                compare(actual, expected, context: "\(name) uncancelled cold/reused control \(iteration)")
            }
        }
    }

    private func layout(_ name: String, shared: SharedResources) async throws -> CaptionLayoutResult {
        struct Fixture: Decodable { var input: CaptionLayoutInput }
        let url = shared.root.appendingPathComponent("fixtures/captions/layout/\(name)-portrait-en.json")
        let input = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url)).input
        return try await CaptionRenderHarness(shared: shared).layout(input)
    }

    @Test("Cancelled different-page frames cannot poison the next active word")
    func cancelledRenderRecovery() async throws {
        let shared = try CaptionMediaFixtures.shared()
        for name in ["neon", "editorial"] {
            let track = try await layout(name, shared: shared)
            let before = 0.4, after = 0.62, interrupted = name == "neon" ? 4.0 : 5.2
            let first = CaptionTimeline.evaluate(track, time: before), next = CaptionTimeline.evaluate(track, time: after)
            #expect(first.page == next.page && first.activeWord != next.activeWord)
            #expect(first.page != CaptionTimeline.evaluate(track, time: interrupted).page)
            let expected = try CaptionRenderPool(shared: shared, cacheLimit: 0)
                .band(track, time: after, width: 1080, reduceMotion: false).raster()
            var cancellations = 0
            for limit in [0, 64 * 1024 * 1024] {
                for delay in [0, 250, 1_000, 3_000, 8_000, 12_000] {
                    let pool = CaptionRenderPool(shared: shared, cacheLimit: limit)
                    _ = try pool.band(track, time: before, width: 1080, reduceMotion: false)
                    let (started, continuation) = AsyncStream<Void>.makeStream()
                    let task = Task.detached {
                        continuation.yield(()); continuation.finish()
                        return try pool.band(track, time: interrupted, width: 1080, reduceMotion: false)
                    }
                    for await _ in started { break }
                    if delay > 0 { try await Task.sleep(for: .microseconds(delay)) }
                    task.cancel()
                    do { _ = try await task.value }
                    catch is CancellationError { cancellations += 1 }
                    let actual = try pool.band(track, time: after, width: 1080, reduceMotion: false).raster()
                    compare(actual, expected, context: "\(name), limit=\(limit), cancel delay=\(delay)µs")
                }
            }
            #expect(cancellations > 0, "\(name) must exercise cancellation")
        }
    }

    @Test("A deterministic throw during shadow mutation invalidates renderer caches")
    func shadowFailureRecovery() async throws {
        let shared = try CaptionMediaFixtures.shared()
        for name in ["neon", "editorial"] {
            let track = try await layout(name, shared: shared)
            let interrupted = name == "neon" ? 4.0 : 5.2
            let expected = try CaptionRenderPool(shared: shared, cacheLimit: 0)
                .band(track, time: 0.62, width: 1080, reduceMotion: false).raster()
            let fault = CaptionShadowFault()
            let renderer = CaptionRenderer(shared: shared, shadowPassHook: fault.check)
            _ = try renderer.renderBand(track, state: CaptionTimeline.evaluate(track, time: 0.4), outputWidth: 1080, layoutID: 1)
            fault.arm()
            #expect(throws: CaptionFailure.self) {
                try renderer.renderBand(track, state: CaptionTimeline.evaluate(track, time: interrupted), outputWidth: 720, layoutID: 1)
            }
            let recovered = try renderer.renderBand(track, state: CaptionTimeline.evaluate(track, time: 0.62), outputWidth: 1080, layoutID: 1).raster()
            compare(recovered, expected, context: "Direct renderer recovery: \(name)")
            for limit in [0, 64 * 1024 * 1024] {
                let pool = CaptionRenderPool(shared: shared, cacheLimit: limit, shadowPassHook: fault.check)
                _ = try pool.band(track, time: 0.4, width: 1080, reduceMotion: false)
                fault.arm()
                #expect(throws: VoxClipError.self) {
                    try pool.band(track, time: interrupted, width: 720, reduceMotion: false)
                }
                let actual = try pool.band(track, time: 0.62, width: 1080, reduceMotion: false).raster()
                compare(actual, expected, context: "Pool recovery: \(name), limit=\(limit)")
                #expect(pool.statistics.renderedBands == 2)
            }
        }
    }
}
