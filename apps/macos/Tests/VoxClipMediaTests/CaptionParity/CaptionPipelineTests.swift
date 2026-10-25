import Foundation
import CoreVideo
import Testing
import VoxClipCore
@testable import VoxClipMedia

enum CaptionTestFrames {
    static func make(_ size: PixelSize, opaque: Bool = false) throws -> CVPixelBuffer {
        var optional: CVPixelBuffer?
        let status = CVPixelBufferCreate(nil, size.width, size.height, kCVPixelFormatType_32BGRA, nil, &optional)
        #expect(status == kCVReturnSuccess)
        let buffer = try #require(optional)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let storage = try #require(CVPixelBufferGetBaseAddress(buffer))
        let byteCount = CVPixelBufferGetBytesPerRow(buffer) * size.height
        storage.initializeMemory(as: UInt32.self, repeating: opaque ? 0xFF995B25 : 0, count: byteCount / 4)
        return buffer
    }

    static func rgba(_ buffer: CVPixelBuffer) throws -> Data {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let source = try #require(CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self))
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        var result = Data(count: width * height * 4)
        result.withUnsafeMutableBytes { raw in
            let destination = raw.bindMemory(to: UInt8.self)
            for row in 0..<height {
                for column in 0..<width {
                    let input = row * stride + column * 4, output = (row * width + column) * 4
                    destination[output] = source[input + 2]; destination[output + 1] = source[input + 1]
                    destination[output + 2] = source[input]; destination[output + 3] = source[input + 3]
                }
            }
        }
        return result
    }
}

@Suite(.serialized)
struct CaptionPipelineTests {
    @Test("M6 resolved styles and M7 layout match engine resolution for every fixture")
    func resolvedFixtures() async throws {
        struct Fixture: Decodable { var input: CaptionLayoutInput }
        let shared = try CaptionMediaFixtures.shared(), resources = try CaptionResources.load(shared: shared)
        let pipeline = try CaptionPipeline(shared: shared), shaper = CoreTextShaper(shared: shared)
        let library = try CaptionStyleLibrary(shared: shared)
        #expect(library.styles.count == 19)
        #expect(library.styles.map(\.order) == library.styles.map(\.order).sorted())
        #expect(library.style(id: "off") == nil)
        var mismatches = 0
        let urls = try CaptionMediaFixtures.urls()
        for url in urls {
            let input = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url)).input
            let original = try #require(library.style(id: input.style))
            let frame = PixelSize(width: input.frame.width, height: input.frame.height)
            let resolved = try original.resolved(overrides: input.captions.overrides, frame: frame)
            let resolution = await pipeline.resolve(original, overrides: input.captions.overrides, frame: frame)
            #expect(!resolution.rejectedOverrides)
            #expect(resolution.style == resolved)
            let preset = CaptionStyleResolver.preset(width: frame.width, height: frame.height)
            let position = preset.flatMap { input.captions.positionByAspect[$0] } ?? input.captions.position
            var resolvedInput = input
            resolvedInput.captions.position = position
            var actual = try await CaptionLayoutEngine.build(input: resolvedInput, style: resolved, resources: resources, shaper: shaper, resolvedStyle: true)
            let expected = try await CaptionLayoutEngine.build(input: input, style: original, resources: resources, shaper: shaper)
            actual.input = input
            if actual != expected { mismatches += 1; Issue.record("M6/M7 resolution mismatch: \(url.lastPathComponent)") }
            let words = input.words.map { CaptionWord(id: $0.id, text: $0.text, start: $0.start, end: $0.end) }
            var pipelineLayout = try await pipeline.layout(words: words, language: input.language, style: resolved,
                position: position, frame: frame, duration: input.duration)
            var projectInput = input
            projectInput.words = words.map { .init(id: $0.id, text: $0.text, start: $0.start, end: $0.end) }
            let projectLayout = try await CaptionLayoutEngine.build(input: projectInput, style: original, resources: resources, shaper: shaper)
            pipelineLayout.input = projectInput
            #expect(pipelineLayout == projectLayout, "M7 caption-copy layout: \(url.lastPathComponent)")
        }
        print("Caption M6/M7 fixtures: \(urls.count) cases; \(mismatches) mismatches")
    }

    @Test("Invalid typed, semantic and manifest project patches reject atomically")
    func rejectedResolution() async throws {
        let shared = try CaptionMediaFixtures.shared(), pipeline = try CaptionPipeline(shared: shared)
        let original = try CaptionMediaFixtures.style("vox-bold", shared: shared)
        let frame = PixelSize(width: 1080, height: 1920)
        let fallback = try original.resolved(overrides: [:], frame: frame)
        let invalid: [[String: JSONValue]] = [
            ["text": .null], ["id": .string("other")], ["font": .object(["sizeSh": .number(-1)])],
            ["font": .object(["file": .string("Missing.ttf")])],
            ["font": .object(["family": .string("Missing")])],
            ["font": .object(["fallbackFiles": .array([.string("Missing.ttf")])])],
            ["emphasis": .object(["fontFile": .string("Missing.ttf")])]
        ]
        for patch in invalid {
            let result = await pipeline.resolve(original, overrides: patch, frame: frame)
            #expect(result.rejectedOverrides)
            #expect(result.style == fallback)
        }
        for patch in invalid.prefix(3) {
            #expect(throws: (any Error).self) { try original.resolved(overrides: patch, frame: frame) }
        }
    }

    @Test("CaptionPipeline and RenderRequest drive the real BGRA draw path")
    func integration() async throws {
        let shared = try CaptionMediaFixtures.shared()
        let pipeline = try CaptionPipeline(shared: shared)
        let size = PixelSize(width: 320, height: 568)
        var style = try CaptionMediaFixtures.style("vox-bold", shared: shared)
        style.font.sizeSh = 0.075
        let words = [CaptionWord(id: "word", text: "Tere!", start: 0, end: 1)]
        let layout = try await pipeline.layout(words: words, language: "et", style: style,
            position: .init(x: 0.5, y: 0.5), frame: size, duration: 1)
        #expect(layout.style.font.sizeSh == style.font.sizeSh)
        #expect(layout.style.position.y == 0.5)
        #expect(layout.track.words.map(\.id) == ["word"])
        #expect(layout.page(at: 0) != nil)
        #expect(layout.page(at: 1) == nil)
        #expect(layout.page(at: .nan) == nil)
        let request = RenderRequest(sourceURL: URL(fileURLWithPath: "/unused.mov"),
            plan: .init(sampleRate: 48_000, totalSamples: 48_000, kept: [.init(startSample: 0, endSample: 48_000)]),
            output: .init(size: size, fps: 30, videoBitrate: 1_000_000), captionLayout: layout)
        let snapshot = try #require(request.captionLayout)
        let rasterizer = CoreTextCaptionRasterizer(shared: shared)
        let buffer = try CaptionTestFrames.make(size)
        try rasterizer.draw(snapshot, time: 0.5, into: buffer)
        let pixels = try CaptionTestFrames.rgba(buffer)
        let page = try #require(layout.page(at: 0.5))
        let band = page.visual
        var ink = 0
        pixels.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for row in 0..<size.height {
                for column in 0..<size.width where bytes[(row * size.width + column) * 4 + 3] > 0 {
                    ink += 1
                    #expect(Double(row) >= band.y - 12 && Double(row) <= band.y + band.height + 12)
                    #expect(Double(column) >= band.x - 12 && Double(column) <= band.x + band.width + 12)
                }
            }
        }
        #expect(ink > 0)
        await rasterizer.prepare(layout)
        let raster = try await rasterizer.rasterize(.init(page: page, style: layout.style, time: 0.5, width: size.width, height: size.height))
        #expect(raster.rgba == pixels)
        let previewSize = PixelSize(width: 160, height: 284)
        let preview = try CaptionTestFrames.make(previewSize)
        try rasterizer.draw(layout, time: 0.5, into: preview, previewWidth: previewSize.width, reduceMotion: true)
        #expect(try CaptionTestFrames.rgba(preview).contains { $0 != 0 })
    }

    @Test("Concurrent frames match uncached renders and reuse only caption bands")
    func concurrentFrames() async throws {
        let shared = try CaptionMediaFixtures.shared()
        let pipeline = try CaptionPipeline(shared: shared)
        let size = PixelSize(width: 1080, height: 1920)
        let layout = try await pipeline.layout(words: [.init(id: "word", text: "Hello", start: 0, end: 1)], language: "en",
            style: CaptionMediaFixtures.style("vox-bold", shared: shared), position: nil, frame: size, duration: 1)
        let rasterizer = CoreTextCaptionRasterizer(shared: shared)
        let baseline = try CaptionTestFrames.make(size)
        try rasterizer.draw(layout, time: 0.5, into: baseline)
        let expected = try CaptionTestFrames.rgba(baseline)
        try await withThrowingTaskGroup(of: Data.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    let frame = try CaptionTestFrames.make(size)
                    try rasterizer.draw(layout, time: 0.5, into: frame)
                    return try CaptionTestFrames.rgba(frame)
                }
            }
            for try await result in group { #expect(result == expected) }
        }
        let stats = rasterizer.statistics
        #expect(stats.renderedBands == 1)
        #expect(stats.cacheHits == 8)
        #expect(stats.fullFrameRasters == 0)
        #expect(stats.largestBandBytes > 0 && stats.largestBandBytes < size.width * size.height * 4 / 4)
        #expect(stats.cacheBytes <= 64 * 1024 * 1024)
    }
}
