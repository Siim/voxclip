import Foundation
import Testing
import VoxClipCore
@testable import VoxClipMedia

@Suite(.serialized)
struct CaptionOptimizationTests {
    @Test("Word fades preserve per-operation alpha while reusing pre-page-alpha bands")
    func wordFadeBands() async throws {
        let shared = try CaptionMediaFixtures.shared(), pipeline = try CaptionPipeline(shared: shared)
        let frame = PixelSize(width: 320, height: 568)
        for identifier in ["vox-bold", "neon", "karaoke"] {
            let original = try CaptionMediaFixtures.style(identifier, shared: shared)
            let style = try original.resolved(overrides: ["animation": .object(["wordIn": .object(["type": .string("fade"), "durationSec": .number(0.2)])])], frame: frame)
            let layout = try await pipeline.layout(words: [.init(id: "first", text: "Hello", start: 0, end: 0.5),
                .init(id: "second", text: "world", start: 0.5, end: 1)], language: "en", style: style, position: nil, frame: frame, duration: 1)
            let direct = CaptionRenderPool(shared: shared, cacheLimit: 0), cached = CaptionRenderPool(shared: shared)
            let times = [0.02, 0.04, 0.06, 0.1, 0.15, 0.25, 0.5, 0.52, 0.58, 0.7]
            for time in times + times.reversed() {
                let actual = try cached.band(layout, time: time, width: 320, reduceMotion: false).raster()
                let expected = try direct.band(layout, time: time, width: 320, reduceMotion: false).raster()
                #expect(actual.rgba == expected.rgba, "\(identifier) word fade at \(time)")
            }
            #expect(cached.statistics.cacheHits > 0)
        }
    }
    @Test("Per-frame alpha lookup preserves direct round-half-up for every byte")
    func fadeAlphaTable() {
        for opacity in [0.0, 0.00001, 0.01, 0.125, 0.3, 0.5, 0.999, 1.0] {
            let table = CaptionAlphaTable(opacity)
            for byte in 0...255 {
                #expect(table.bytes[byte] == UInt8(clamping: CaptionMath.roundHalfUp(Double(byte) * opacity)))
            }
        }
    }

    @Test("Cached pre-alpha fade bands and step-nine wipe bands match direct renders")
    func animatedBands() async throws {
        let shared = try CaptionMediaFixtures.shared(), harness = try CaptionRenderHarness(shared: shared)
        struct Fixture: Decodable { var input: CaptionLayoutInput }
        for style in ["neon", "editorial", "karaoke", "emoji-accent"] {
            let url = shared.root.appendingPathComponent("fixtures/captions/layout/\(style)-portrait-en.json")
            var input = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url)).input
            if style == "emoji-accent" { input.captions.overrides["reveal"] = .object(["unit": .string("wipe")]) }
            let layout = try await harness.layout(input)
            let cached = CaptionRenderPool(shared: shared), direct = CaptionRenderPool(shared: shared, cacheLimit: 0)
            let times = [0.0, 0.02, 0.04, 0.06, 0.1, 0.15, 0.25, 0.4, 0.6, 1, 1.1, 1.2, 2, 3, 4, 5, 6, 7]
            for time in times + times.reversed() {
                let actual = try cached.band(layout, time: time, width: 360, reduceMotion: false).raster()
                let expected = try direct.band(layout, time: time, width: 360, reduceMotion: false).raster()
                #expect(actual.rgba == expected.rgba, "\(style), t=\(time)")
            }
            #expect(cached.statistics.cacheHits > 0)
            #expect(cached.statistics.cacheBytes <= 64 * 1024 * 1024)
        }
    }

    @Test("Distinct uncached styles and animated frames draw concurrently bit-exactly")
    func distinctConcurrentFrames() async throws {
        struct Fixture: Decodable { var input: CaptionLayoutInput }
        let shared = try CaptionMediaFixtures.shared(), harness = try CaptionRenderHarness(shared: shared)
        var layouts: [CaptionLayoutResult] = []
        for style in ["neon", "karaoke", "vhs", "active-pop"] {
            let url = shared.root.appendingPathComponent("fixtures/captions/layout/\(style)-portrait-en.json")
            layouts.append(try await harness.layout(JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url)).input))
        }
        let jobs = (0..<24).map { (layouts[$0 % layouts.count], 0.2 + Double($0) * 0.061) }
        let sequential = CaptionRenderPool(shared: shared, cacheLimit: 0)
        let expected = try jobs.map { try sequential.band($0.0, time: $0.1, width: 360, reduceMotion: false).raster().rgba }
        let concurrent = CaptionRenderPool(shared: shared, cacheLimit: 0)
        try await withThrowingTaskGroup(of: (Int, Data).self) { group in
            for (index, job) in jobs.enumerated() {
                group.addTask {
                    let frame = try CaptionTestFrames.make(.init(width: 360, height: 640))
                    try concurrent.band(job.0, time: job.1, width: 360, reduceMotion: false).composite(into: frame)
                    return (index, try CaptionTestFrames.rgba(frame))
                }
            }
            for try await (index, actual) in group { #expect(actual == expected[index], "Concurrent frame \(index)") }
        }
        #expect(concurrent.statistics.renderedBands == jobs.count)
        #expect(concurrent.statistics.cacheHits == 0)
    }

    @Test("Shadow lookup tables preserve every source-over rounding result")
    func shadowTables() throws {
        let shared = try CaptionMediaFixtures.shared()
        let style = try CaptionMediaFixtures.style("neon", shared: shared)
        for token in ["#000000FF", "#FF4FD899", "#9D00FF99", "#FFFFFFCC"] {
            let color = try CaptionColor(token, style: style)
            let table = CaptionShadowBlendTable(color: color)
            var differences = 0
            table.bytes.withUnsafeBytes { raw in
                let bytes = raw.bindMemory(to: UInt8.self)
                for mask in 0...255 {
                    let alpha = Double(mask) * color.alpha / 255
                    let channels = [color.blue * alpha * 255, color.green * alpha * 255, color.red * alpha * 255, alpha * 255]
                    for value in 0...255 {
                        for channel in 0..<4 {
                            let expected = UInt8(clamping: CaptionMath.roundHalfUp(channels[channel] + Double(value) * (1 - alpha)))
                            if bytes[(mask * 256 + value) * 4 + channel] != expected { differences += 1 }
                        }
                    }
                }
            }
            #expect(differences == 0, "Source-over lookup mismatch for \(token)")
        }
    }

    @Test("Reused bounded blur matches independent full-surface row passes")
    func blurScratch() throws {
        let scratch = CaptionBlurScratch()
        for (width, height) in [(31, 19), (7, 5), (37, 23), (321, 241)] {
            for sigma in [0.0, 0.25, 1.5, 1.999, 2, 2.5, 5] {
                for pattern in 0..<5 {
                    var input = [UInt8](repeating: 0, count: width * height)
                    for row in 0..<height {
                        for column in 0..<width {
                            let visible = pattern == 4 || (pattern == 1 ? row < 3 && column < 3 :
                                pattern == 2 ? abs(row - height / 2) < 2 && abs(column - width / 2) < 3 :
                                pattern == 3 && row >= height - 3 && column >= width - 3)
                            if visible { input[row * width + column] = UInt8((row * 37 + column * 23) % 255 + 1) }
                        }
                    }
                    var expected = input
                    for row in 0..<height {
                        let start = row * width
                        let filtered = CaptionBlur.row(Array(input[start..<(start + width)]), sigma: sigma)
                        expected.replaceSubrange(start..<(start + width), with: filtered)
                    }
                    for column in 0..<width {
                        let filtered = CaptionBlur.row((0..<height).map { expected[$0 * width + column] }, sigma: sigma)
                        for row in 0..<height { expected[row * width + column] = filtered[row] }
                    }
                    var actual = input
                    try actual.withUnsafeMutableBufferPointer { mask in
                        _ = try scratch.apply(mask, width: width, height: height, sigma: sigma)
                    }
                    #expect(actual == expected, "Blur \(width)x\(height), sigma \(sigma), pattern \(pattern)")
                }
            }
        }
    }

    @Test("Clipped bands keep integral origins with fractional shadow margins")
    func clippedOrigin() async throws {
        let shared = try CaptionMediaFixtures.shared()
        let pipeline = try CaptionPipeline(shared: shared)
        var style = try CaptionMediaFixtures.style("outline", shared: shared)
        style.font.sizeScale = 1.45
        style.shadows = [.init(dxEm: 0, dyEm: 0.09, sigmaEm: 0, color: "#00000000")]
        let layout = try await pipeline.layout(words: [.init(id: "long", text: String(repeating: "W", count: 61), start: 0, end: 1)],
            language: "en", style: style, position: nil, frame: .init(width: 1080, height: 1920), duration: 1)
        #expect(layout.pages[0].page.visual.x < 0)
        var unchanged = layout
        unchanged.style.shadows[0].dyEm = 0
        let pool = CaptionRenderPool(shared: shared, cacheLimit: 0)
        let fractionalBand = try pool.band(layout, time: 0.5, width: 1080, reduceMotion: false)
        let integralBand = try pool.band(unchanged, time: 0.5, width: 1080, reduceMotion: false)
        let fractional = fractionalBand.raster(), integral = integralBand.raster()
        var differences = 0, maximum = 0
        fractional.rgba.withUnsafeBytes { firstRaw in
            integral.rgba.withUnsafeBytes { secondRaw in
                let first = firstRaw.bindMemory(to: UInt8.self), second = secondRaw.bindMemory(to: UInt8.self)
                for index in first.indices where first[index] != second[index] {
                    differences += 1; maximum = max(maximum, abs(Int(first[index]) - Int(second[index])))
                }
            }
        }
        #expect(maximum <= 1, "\(differences) channel differences; maximum \(maximum) exceeds edge quantization")
    }

    @Test("Word box borders scale identically on both opacity paths")
    func scaledWordBorder() async throws {
        let shared = try CaptionMediaFixtures.shared()
        let pipeline = try CaptionPipeline(shared: shared)
        var style = try CaptionMediaFixtures.style("vox-bold", shared: shared)
        style.fill = .solid(color: "#00000000")
        style.box = .init(scope: .word, color: "#00000000", borderWidthEm: 0.15, borderColor: "#FFFFFF")
        style.words = .init(active: .init(scale: 1.7))
        let layout = try await pipeline.layout(words: [.init(id: "word", text: "Hello", start: 0, end: 1)],
            language: "en", style: style, position: nil, frame: .init(width: 320, height: 568), duration: 1)
        var almostOpaque = layout
        almostOpaque.style.words?.active?.opacity = 1 - 1e-12
        let pool = CaptionRenderPool(shared: shared, cacheLimit: 0)
        let opaque = try pool.raster(layout, time: 0.5, width: 320, reduceMotion: false)
        let translucent = try pool.raster(almostOpaque, time: 0.5, width: 320, reduceMotion: false)
        #expect(opaque.rgba.contains { $0 != 0 })
        #expect(opaque == translucent)
    }

    @Test("Static overlay cache is pixel-identical, snapshot-aware and bounded")
    func pageCache() async throws {
        let shared = try CaptionMediaFixtures.shared()
        let pipeline = try CaptionPipeline(shared: shared)
        let layout = try await pipeline.layout(words: [.init(id: "word", text: "Hello", start: 0, end: 1)],
            language: "en", style: CaptionMediaFixtures.style("vox-bold", shared: shared), position: nil,
            frame: .init(width: 320, height: 568), duration: 1)
        let uncached = CaptionRenderPool(shared: shared, cacheLimit: 0)
        let expected = try uncached.band(layout, time: 0.5, width: 320, reduceMotion: false)
        let limit = expected.bgra.count * 2
        let cached = CaptionRenderPool(shared: shared, cacheLimit: limit)
        #expect(try cached.band(layout, time: 0.5, width: 320, reduceMotion: false).bgra == expected.bgra)
        #expect(try cached.band(layout, time: 0.6, width: 320, reduceMotion: false).bgra == expected.bgra)
        #expect(cached.statistics.cacheHits == 1)
        for color in ["#FF0000", "#00FF00", "#0000FF"] {
            var changed = layout
            changed.style.fill = .solid(color: color)
            let actual = try cached.band(changed, time: 0.5, width: 320, reduceMotion: false)
            let reference = try uncached.band(changed, time: 0.5, width: 320, reduceMotion: false)
            #expect(actual.bgra == reference.bgra)
            #expect(actual.bgra != expected.bgra)
            #expect(cached.statistics.cacheBytes <= limit)
        }
        let renders = cached.statistics.renderedBands
        _ = try cached.band(layout, time: 0.5, width: 320, reduceMotion: false)
        #expect(cached.statistics.renderedBands == renders + 1)
        #expect(cached.statistics.fullFrameRasters == 0)
    }

    @Test("Geometric motion, jitter and cursors bypass completed-band caching")
    func animatedCacheEligibility() async throws {
        let shared = try CaptionMediaFixtures.shared()
        let pipeline = try CaptionPipeline(shared: shared)
        for identifier in ["karaoke", "active-pop", "bounce", "lower-third", "vhs", "typewriter"] {
            let layout = try await pipeline.layout(words: [.init(id: "word", text: "Hello", start: 0, end: 1)],
                language: "en", style: CaptionMediaFixtures.style(identifier, shared: shared), position: nil,
                frame: .init(width: 320, height: 568), duration: 1)
            let pool = CaptionRenderPool(shared: shared)
            let first = try pool.band(layout, time: 0.03, width: 320, reduceMotion: false)
            let repeated = try pool.band(layout, time: 0.03, width: 320, reduceMotion: false)
            #expect(first.bgra == repeated.bgra, "\(identifier)")
            #expect(pool.statistics.cacheHits == (identifier == "karaoke" ? 1 : 0), "\(identifier)")
            #expect(pool.statistics.renderedBands == 2, "\(identifier)")
        }
    }

    @Test("Stable caption bands are byte-identical on opaque targets before and after caching")
    func pageCacheOnVideo() async throws {
        struct Fixture: Decodable { var input: CaptionLayoutInput }
        let shared = try CaptionMediaFixtures.shared(), harness = try CaptionRenderHarness(shared: shared)
        let urls = try CaptionMediaFixtures.urls().filter { $0.lastPathComponent.hasSuffix("-portrait-en.json") }
        var styles = 0
        for url in urls {
            let input = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url)).input
            let layout = try await harness.layout(input)
            guard layout.style.reveal?.cursor == nil else { continue }
            let page = try #require(layout.pages.first?.page)
            let time = (page.start + page.end) / 2
            let uncached = CaptionRenderPool(shared: shared, cacheLimit: 0), cached = CaptionRenderPool(shared: shared)
            let expectedFrame = try CaptionTestFrames.make(.init(width: 1080, height: 1920), opaque: true)
            try uncached.band(layout, time: time, width: 1080, reduceMotion: true).composite(into: expectedFrame)
            let expected = try CaptionTestFrames.rgba(expectedFrame)
            for pass in 0..<2 {
                let actualFrame = try CaptionTestFrames.make(.init(width: 1080, height: 1920), opaque: true)
                try cached.band(layout, time: time, width: 1080, reduceMotion: true).composite(into: actualFrame)
                #expect(try CaptionTestFrames.rgba(actualFrame) == expected, "\(layout.style.id), cache pass \(pass)")
            }
            #expect(cached.statistics.cacheHits == 1, "\(layout.style.id)")
            #expect(cached.statistics.fullFrameRasters == 0)
            styles += 1
        }
        #expect(styles == 18)
        print("Opaque caption cache parity: \(styles) styles, before and after cache hits at 1080×1920")
    }
}
