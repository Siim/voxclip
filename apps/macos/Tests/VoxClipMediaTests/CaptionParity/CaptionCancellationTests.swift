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

private final class CaptionShadowCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var armedIndex: Int?
    private var count = 0

    func arm(at index: Int) { lock.withLock { armedIndex = index } }
    var cancellations: Int { lock.withLock { count } }

    func check(_ index: Int) {
        let cancel = lock.withLock {
            guard armedIndex == index else { return false }
            armedIndex = nil
            count += 1
            return true
        }
        // The existing hook runs on the rendering task after a shadow-mask
        // mutation. Its next production cancellation check must throw.
        if cancel { withUnsafeCurrentTask { $0?.cancel() } }
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
        var cancellations = 0
        var attempts = 0
        for name in ["neon", "editorial"] {
            let track = try await layout(name, shared: shared)
            let before = 0.4, after = 0.62, interrupted = name == "neon" ? 4.0 : 5.2
            let first = CaptionTimeline.evaluate(track, time: before), next = CaptionTimeline.evaluate(track, time: after)
            #expect(first.page == next.page && first.activeWord != next.activeWord)
            #expect(first.page != CaptionTimeline.evaluate(track, time: interrupted).page)
            let expected = try CaptionRenderPool(shared: shared, cacheLimit: 0)
                .band(track, time: after, width: 1080, reduceMotion: false).raster()
            try #require(!track.style.shadows.isEmpty)
            for limit in [0, 64 * 1024 * 1024] {
                for width in [720, 1080, 1440] {
                    for shadow in Set([0, track.style.shadows.count - 1]).sorted() {
                        attempts += 1
                        let cancellation = CaptionShadowCancellation()
                        let pool = CaptionRenderPool(shared: shared, cacheLimit: limit, shadowPassHook: cancellation.check)
                        _ = try pool.band(track, time: before, width: 1080, reduceMotion: false)
                        cancellation.arm(at: shadow)
                        let task = Task.detached {
                            try pool.band(track, time: interrupted, width: width, reduceMotion: false)
                        }
                        do {
                            _ = try await task.value
                            Issue.record("The shadow-pass cancellation must reach the renderer's cancellation check")
                        } catch is CancellationError { cancellations += 1 }
                        #expect(cancellation.cancellations == 1)
                        let actual = try pool.band(track, time: after, width: 1080, reduceMotion: false).raster()
                        compare(actual, expected, context: "\(name), limit=\(limit), width=\(width), shadow=\(shadow)")
                        #expect(pool.statistics.renderedBands == 2, "A cancelled band must not be published")
                    }
                }
            }
        }
        #expect(attempts == 18)
        #expect(cancellations == attempts)
        print("CAPTION_CANCELLATION cancellations=\(cancellations) pixel_comparisons=\(attempts)")
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
