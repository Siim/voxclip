import Foundation
import Testing
import VoxClipCore
@testable import VoxClipMedia

@Test("Legacy kern pairs retain HarfBuzz advances and offsets")
func legacyCaptionKerning() async throws {
    let shaper = CoreTextShaper(shared: try CaptionMediaFixtures.shared())
    let runs = try await shaper.shape(.init(text: "AT", fontFile: "Righteous-Regular.ttf", language: "en"))
    let run = try #require(runs.first)
    #expect(run.glyphs.map(\.advance) == [1358, 1163])
    #expect(run.glyphs.map(\.offsetX) == [0, -21])
    #expect(run.units == 2521)
    let unkerned = try await shaper.shape(.init(text: "AT", fontFile: "Righteous-Regular.ttf", language: "en", kern: false))
    #expect(unkerned.first?.glyphs.map(\.advance) == [1380, 1184])
    #expect(unkerned.first?.glyphs.map(\.offsetX) == [0, 0])
    let positive = try await shaper.shape(.init(text: "F*", fontFile: "Righteous-Regular.ttf", language: "en"))
    #expect(positive.first?.glyphs.map(\.advance) == [1172, 1230])
    #expect(positive.first?.glyphs.map(\.offsetX) == [0, 22])
}

@Test("Default ignorables match HarfBuzz glyphs without system fallback")
func captionDefaultIgnorables() async throws {
    let shaper = CoreTextShaper(shared: try CaptionMediaFixtures.shared())
    let cases: [(String, [UInt32], [Int], [Int])] = [
        ("©️", [401, 336], [783, 0], [0, 0]),
        ("™️", [403, 336], [856, 0], [0, 0]),
        ("a\u{200D}b", [126, 336, 138], [598, 0, 663], [0, 0, 1]),
        ("ok\u{200C}ay", [196, 181, 336, 126, 242], [615, 576, 0, 579, 619], [0, 1, 1, 2, 3]),
        ("1️⃣", [291, 336], [379, 0], [0, 0]),
        ("f\u{200C}i", [160, 336, 167], [380, 0, 284], [0, 0, 1]),
        ("of\u{200C}fice", [196, 160, 336, 285, 139, 148], [615, 380, 0, 624, 617, 612], [0, 1, 1, 2, 4, 5]),
        ("A\u{200C}V", [1, 336, 108], [638, 0, 717], [0, 0, 1])
    ]
    for (text, glyphs, advances, clusters) in cases {
        let request = GlyphShapeRequest(text: text, fontFile: "DMSans-Black.ttf", language: "en")
        let runs = try await shaper.shape(request)
        #expect(runs.count == 1)
        let run = try #require(runs.first)
        #expect(run.glyphs.map(\.id) == glyphs, "\(text)")
        #expect(run.glyphs.map(\.advance) == advances, "\(text)")
        #expect(run.glyphs.map(\.cluster) == clusters, "\(text)")
        #expect(run.glyphs.allSatisfy { $0.offsetX == 0 && $0.offsetY == 0 })
        #expect(try await shaper.shape(request) == runs)
    }
    #expect(await shaper.cacheHits == cases.count)
    let legacy = try await shaper.shape(.init(text: "A\u{200C}T", fontFile: "Righteous-Regular.ttf", language: "en"))
    let legacyRun = try #require(legacy.first)
    #expect(legacyRun.glyphs.map(\.advance) == [1358, 0, 1163])
    #expect(legacyRun.glyphs.map(\.offsetX) == [0, 0, -21])
    let covered = try await shaper.shape(.init(text: "A\u{200C}V", fontFile: "NotoSans-SemiBold.ttf", language: "en"))
    let coveredRun = try #require(covered.first)
    #expect(coveredRun.glyphs.map(\.id) == [36, 3, 57])
    #expect(coveredRun.glyphs.map(\.advance) == [632, 0, 631])
}

private actor UnshowableCaptionShaper: GlyphShaper {
    private let shaper: CoreTextShaper
    init(shared: SharedResources) { shaper = CoreTextShaper(shared: shared) }
    func shape(_ request: GlyphShapeRequest) async throws -> [ShapedRun] {
        if request.text == "broken" { throw CaptionFailure.noGlyphs }
        return try await shaper.shape(request)
    }
}

@Test("Unshowable and empty words are reported without losing the track")
func captionDroppedWords() async throws {
    let shared = try CaptionMediaFixtures.shared()
    var style = try CaptionMediaFixtures.style("clean-subtitle", shared: shared)
    style.text.transform = .none
    let input = CaptionLayoutInput(style: style.id, frame: .init(width: 320, height: 568), language: "en", duration: 4,
        words: ["Intro", " ", "broken", "outro"].enumerated().map { .init(id: "word-\($0.offset)", text: $0.element, start: Double($0.offset), end: Double($0.offset) + 0.5) })
    let layout = try await CaptionLayoutEngine.build(input: input, style: style,
        resources: CaptionResources.load(shared: shared), shaper: UnshowableCaptionShaper(shared: shared))
    #expect(layout.words.map(\.input.text) == ["Intro", "outro"])
    #expect(layout.dropped.map(\.sourceIndex) == [1, 2])
    #expect(layout.dropped.map(\.text) == [" ", "broken"])
    #expect(layout.dropped.map(\.reason) == ["empty", "no-glyphs"])
}
