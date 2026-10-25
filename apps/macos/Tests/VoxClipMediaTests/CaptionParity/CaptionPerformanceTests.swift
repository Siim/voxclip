import Foundation
import Darwin
import XCTest
import VoxClipCore
@testable import VoxClipMedia

@MainActor
final class CaptionPerformanceTests: XCTestCase {
    func testFrameBudget() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VOXCLIP_PERF_TESTS"] == "1",
            "Run VOXCLIP_PERF_TESTS=1 swift test -c release for the caption frame budget")
        #if DEBUG
        XCTFail("Run VOXCLIP_PERF_TESTS=1 swift test -c release for the caption frame budget")
        #else
        struct Fixture: Decodable { var input: CaptionLayoutInput }
        let shared = try CaptionMediaFixtures.shared()
        let harness = try CaptionRenderHarness(shared: shared)
        let urls = try CaptionMediaFixtures.urls().filter { $0.lastPathComponent.hasSuffix("-portrait-en.json") }
        XCTAssertEqual(urls.count, 19)
        let clock = ContinuousClock()
        for url in urls {
            let input = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url)).input
            let layout = try await harness.layout(input)
            let frame = try CaptionTestFrames.make(.init(width: 1080, height: 1920))
            let times = (0..<Int(ceil(input.duration * 30))).map { Double($0) / 30 }.filter { layout.page(at: $0) != nil }
            var pages = Set<Int>()
            let firstFrames = times.filter { time in
                let state = CaptionTimeline.evaluate(layout, time: time)
                guard let page = state.page, state.motion.alpha > 0, state.motion.scale > 0,
                      state.words.contains(where: { $0.visible && $0.opacity > 0 }) else { return false }
                return pages.insert(page).inserted
            }
            XCTAssertEqual(firstFrames.count, layout.pages.count)
            XCTAssertGreaterThan(firstFrames.count, 1)
            let warmTime = try XCTUnwrap(firstFrames.first)
            let pageFirstTimes = Set(firstFrames)
            for mode in ["band-uncached", "playback", "page-first"] {
                let budget = mode == "page-first" ? 7.5 : 3.0
                var percentiles: [Double] = []
                for pass in 1...3 {
                    let pool = CaptionRenderPool(shared: shared, cacheLimit: mode == "band-uncached" ? 0 : 64 * 1024 * 1024)
                    let renderer = mode == "page-first" ? CaptionRenderer(shared: shared) : nil
                    if let renderer {
                        try renderer.renderBand(layout, state: CaptionTimeline.evaluate(layout, time: warmTime), outputWidth: 1080, layoutID: 1).composite(into: frame)
                    } else {
                        try pool.band(layout, time: warmTime, width: 1080, reduceMotion: false).composite(into: frame)
                    }
                    var milliseconds: [Double] = []
                    var load = [Double](repeating: 0, count: 3)
                    let loadCount = getloadavg(&load, 3)
                    try XCTSkipUnless(loadCount == 3 && load[0] < 2,
                        "Caption performance requires one-minute load below 2; observed \(load[0])")
                    for time in mode == "page-first" ? Array(firstFrames.dropFirst()) : times {
                        if renderer == nil, pageFirstTimes.contains(time) {
                            try pool.band(layout, time: time, width: 1080, reduceMotion: false).composite(into: frame)
                            continue
                        }
                        let start = clock.now
                        if let renderer {
                            let state = CaptionTimeline.evaluate(layout, time: time)
                            try renderer.renderBand(layout, state: state, outputWidth: 1080, layoutID: 1).composite(into: frame)
                        } else {
                            try pool.band(layout, time: time, width: 1080, reduceMotion: false).composite(into: frame)
                        }
                        let elapsed = start.duration(to: clock.now).components
                        milliseconds.append(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
                    }
                    milliseconds.sort()
                    let median = milliseconds[milliseconds.count / 2]
                    let percentile95 = milliseconds[min(milliseconds.count - 1, milliseconds.count * 95 / 100)]
                    percentiles.append(percentile95)
                    print(String(format: "CAPTION_PERF %@ %@ pass=%d median=%.3fms p95=%.3fms frames=%d load=%.2f/%.2f/%.2f",
                        mode, layout.style.id, pass, median, percentile95, milliseconds.count, load[0], load[1], load[2]))
                    XCTAssertEqual(pool.statistics.fullFrameRasters, 0)
                }
                let best = try XCTUnwrap(percentiles.min())
                print(String(format: "CAPTION_PERF_BEST %@ %@ p95=%.3fms margin=%.3fms", mode, layout.style.id, best, budget - best))
                XCTAssertLessThanOrEqual(best, budget, "\(layout.style.id) \(mode): best-of-three p95 \(best) ms exceeds the M3 Max \(budget) ms gate for captions §13.9")
            }
        }
        #endif
    }
}
