import Foundation
import CoreVideo
import Testing
import VoxClipCore
@testable import VoxClipMedia

@Suite(.serialized)
struct CaptionRenderingTests {
    @Test("Prepared page protocol preserves later-page palette and seek parity")
    func preparedPage() async throws {
        let shared = try CaptionMediaFixtures.shared()
        let harness = try CaptionRenderHarness(shared: shared)
        struct Fixture: Decodable { var input: CaptionLayoutInput }
        let url = shared.root.appendingPathComponent("fixtures/captions/layout/one-word-portrait-en.json")
        let input = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url)).input
        let track = try await harness.layout(input)
        let page = try #require(track.pages.last?.page)
        let time = (page.start + page.end) / 2
        let rasterizer = CoreTextCaptionRasterizer(shared: shared)
        let request = CaptionRasterRequest(page: page, style: track.style, time: time, width: input.frame.width, height: input.frame.height)
        await #expect(throws: CaptionFailure.self) { try await rasterizer.rasterize(request) }
        await rasterizer.prepare(track)
        let protocolRaster = try await rasterizer.rasterize(request)
        let direct = try await rasterizer.rasterize(track, time: time)
        #expect(protocolRaster == direct)
        _ = try await rasterizer.rasterize(track, time: track.pages[0].page.start + 0.1)
        let seeked = try await rasterizer.rasterize(track, time: time)
        #expect(seeked == direct)
        #expect(protocolRaster.rgba.contains { $0 != 0 })
        let preview = try await rasterizer.rasterize(track, time: time, previewWidth: 270)
        #expect(preview.width == 270 && preview.height == 480)
        let hidden = try await rasterizer.rasterize(track, time: input.duration)
        #expect(hidden.rgba.allSatisfy { $0 == 0 })
        let srt = CaptionSubtitles.srt(track)
        #expect(srt.contains("03:15"))
        #expect(srt.contains("Monday."))
        #expect(!srt.contains("\r"))
        #expect(srt.components(separatedBy: " --> ").count - 1 == track.pages.filter { $0.page.end > $0.page.start }.count)
    }

    @Test("Active word boxes are not clipped by glyph-only surface bounds")
    func wordBoxBounds() async throws {
        let shared = try CaptionMediaFixtures.shared()
        let resources = try CaptionResources.load(shared: shared)
        var style = try CaptionMediaFixtures.style("box-highlight", shared: shared)
        style.words?.active?.box?.paddingXEm = 1.5
        style.words?.active?.box?.paddingYEm = 1
        let input = CaptionLayoutInput(style: style.id, frame: .init(width: 320, height: 568), language: "en", duration: 1,
            words: [.init(id: "word", text: "Hi", start: 0, end: 1)])
        let track = try await CaptionLayoutEngine.build(input: input, style: style, resources: resources, shaper: CoreTextShaper(shared: shared))
        let raster = try await CoreTextCaptionRasterizer(shared: shared).rasterize(track, time: 0.5)
        let rectangle = track.pages[0].page.wordRects[0]
        let fontPx = track.pages[0].page.fontPx
        let column = Int(floor(rectangle.x - fontPx)), row = Int(floor(rectangle.y + rectangle.height / 2))
        #expect(raster.rgba[row * raster.bytesPerRow + column * 4 + 3] > 0)
    }

    @Test("Premultiplied gamma-encoded RGBA blends into BGRA with stride")
    func bgraChannels() throws {
        var optional: CVPixelBuffer?
        #expect(CVPixelBufferCreate(nil, 1, 2, kCVPixelFormatType_32BGRA, nil, &optional) == kCVReturnSuccess)
        let buffer = try #require(optional)
        CVPixelBufferLockBaseAddress(buffer, [])
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let storage = try #require(CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self))
        storage.initialize(repeating: 23, count: stride * 2)
        for row in 0..<2 {
            storage[row * stride] = 100; storage[row * stride + 1] = 80
            storage[row * stride + 2] = 60; storage[row * stride + 3] = 255
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let raster = CaptionRaster(width: 1, height: 2, bytesPerRow: 4, rgba: Data([128, 0, 0, 128, 0, 0, 0, 0]))
        try raster.composite(into: buffer)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        #expect(Array(UnsafeBufferPointer(start: storage, count: 4)) == [50, 40, 158, 255])
        #expect(Array(UnsafeBufferPointer(start: storage + stride, count: 4)) == [100, 80, 60, 255])
        if stride > 4 { #expect(storage[4] == 23) }
    }

    @Test("Emoji filtering is deterministic on premultiplied channels")
    func emojiResampling() throws {
        var source = [UInt8](repeating: 0, count: 128 * 128 * 4)
        for row in 0..<128 {
            for column in 0..<128 {
                let offset = (row * 128 + column) * 4
                source[offset] = column < 64 ? 128 : 0
                source[offset + 1] = row < 64 ? 128 : 0
                source[offset + 3] = 128
            }
        }
        #expect(try CaptionEmojiResampler.resize(source, size: 1) == [64, 64, 0, 128])
        #expect(try CaptionEmojiResampler.resize(source, size: 128) == source)
        let enlarged = try CaptionEmojiResampler.resize(source, size: 256)
        #expect(Array(enlarged.prefix(4)) == [128, 128, 0, 128])
        #expect(Array(enlarged.suffix(4)) == [0, 0, 0, 128])
        #expect(throws: CaptionFailure.self) { try CaptionEmojiResampler.resize(source, size: 0) }
    }

    @Test("Public parity harness ignores expected geometry and validates samples")
    func publicHarness() async throws {
        let shared = try CaptionMediaFixtures.shared()
        let harness = try CaptionRenderHarness(shared: shared)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-caption-harness-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = shared.root.appendingPathComponent("fixtures/captions/layout/vox-bold-portrait-en.json")
        var fixture = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: input)) as? [String: Any])
        let expected = try #require(fixture["expected"] as? [String: Any])
        fixture["expected"] = ["samples": expected["samples"]!, "pages": "not layout data", "words": false]
        let poisoned = root.appendingPathComponent("fixture.json")
        try JSONSerialization.data(withJSONObject: fixture).write(to: poisoned)
        let images = try await harness.renderCase(at: poisoned, sample: 0)
        #expect(images.count == 1)
        #expect(images[0].crop.w > 1)
        await #expect(throws: CaptionFailure.self) { try await harness.renderCase(at: poisoned, sample: -1) }
        #expect(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).map(\.lastPathComponent) == ["fixture.json"])
        let index = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(images[0])) as? [String: Any])
        #expect(index["style"] is NSNull)
    }
}
