import CoreGraphics
import Foundation
import Testing
@testable import VoxClipCore
@testable import VoxClipMedia

/// The export check's captions rule (ADR-R49) on the renderer's own layout: the default caption style (Highlight) at its
/// default position and the hook title at its default place, in each export shape, against the safe-zone bands.
@Suite(.offlineFixtures) struct ExportCheckPlacementTests {
    static let shapes: [(aspect: String, size: PixelSize)] = [("9:16", PixelSize(width: 1080, height: 1920)),
                                                              ("1:1", PixelSize(width: 1080, height: 1080)),
                                                              ("16:9", PixelSize(width: 1920, height: 1080))]
    /// A spoken line long enough to fill a page in every style.
    static let words: [CaptionWord] = "so this is how we ship the clipper every single week".split(separator: " ").enumerated().map { index, text in
        CaptionWord(id: "w\(index)", text: String(text), start: Double(index) * 0.4, end: Double(index) * 0.4 + 0.35)
    }
    /// A hook of the planner's usual length, and the longest the title takes (three lines).
    static let hooks = ["We ship every week", "This is the one change that made our whole team ship a clipper every single week"]

    static func style(_ id: String) throws -> CaptionStyle {
        let url = try SharedResources.locate().root.appendingPathComponent("caption-styles/styles/\(id).json")
        return try JSONDecoder().decode(CaptionStyle.self, from: Data(contentsOf: url))
    }

    /// Each caption card of `style` at its default position on `size`, as the render lays it out.
    static func captionCheck(_ id: String, size: PixelSize) async throws -> ExportCheckResult {
        let pipeline = try CaptionPipeline(shared: SharedResources.locate())
        let resolution = await pipeline.resolve(try style(id), overrides: [:], frame: size)
        let layout = try await pipeline.layout(words: words, language: "en", style: resolution.style, position: nil, frame: size, duration: 6)
        var render = RenderRequest(sourceURL: URL(fileURLWithPath: "/dev/null"), plan: EditPlan(sampleRate: 48_000, totalSamples: 288_000),
                                   output: OutputSpec(size: size, fps: 30, videoBitrate: 4_000_000))
        render.captionLayout = layout
        let boxes = ExportCheckExpectation.captionBoxes(render: render)
        #expect(boxes.count == layout.pages.count && !boxes.isEmpty)
        return ExportCheck.captions(ExportCheckInput(expected: [], heard: nil, video: nil, audio: nil, frameSeconds: 1 / 30.0, loudness: nil,
                                                     boxes: boxes, frame: size))
    }

    /// The hook title at its default place (`ClipHookTitle.position`) on `size`, laid out by the compositor.
    static func titleCheck(_ hook: String, size: PixelSize) -> (result: ExportCheckResult, rect: CaptionRect?) {
        let title = ClipEffect(id: "fx-hook-1", clipId: "clip", kind: .title, start: 0, end: 2, text: hook, position: ClipHookTitle.position)
        var render = RenderRequest(sourceURL: URL(fileURLWithPath: "/dev/null"), plan: EditPlan(sampleRate: 48_000, totalSamples: 288_000,
                                   kept: [MediaInterval(startSample: 0, endSample: 288_000)]), output: OutputSpec(size: size, fps: 30, videoBitrate: 4_000_000))
        render.effects = ClipEffectsRenderInput(effects: [title], soundURLs: [:])
        let boxes = ExportChecker.titleBoxes(render: render)
        let result = ExportCheck.captions(ExportCheckInput(expected: [], heard: nil, video: nil, audio: nil, frameSeconds: 1 / 30.0,
                                                           loudness: nil, boxes: boxes, frame: size))
        return (result, boxes.first?.rect)
    }

    static func describe(_ rect: CaptionRect?) -> String {
        guard let rect else { return "none" }
        return String(format: "%.4f…%.4f of the height", rect.y, rect.y + rect.height)
    }

    /// 9:16 is owed: Highlight's default (y 0.8) reaches 0.043 of the height into the bottom 22% band. The brief says to
    /// report a failing default to the lead rather than move it (ADR-R49); the known issue fails once it is moved.
    @Test func theDefaultCaptionPositionClearsTheBandsInEveryShape() async throws {
        for shape in Self.shapes {
            let result = try await Self.captionCheck("vox-highlight", size: shape.size)
            if shape.aspect == "9:16" {
                withKnownIssue("Highlight's default 9:16 position sits in the bottom band (ADR-R49, the lead decides)") {
                    #expect(result.status == .ok, "vox-highlight on \(shape.aspect): \(result.items)")
                }
            } else {
                #expect(result.status == .ok, "vox-highlight on \(shape.aspect): \(result.items)")
            }
        }
    }

    /// 9:16 is owed: the title's top is at 0.102 (one line) and 0.106 (three lines) of the height, inside the top 12% band.
    @Test func theDefaultTitlePositionClearsTheBandsInEveryShape() {
        for shape in Self.shapes {
            for hook in Self.hooks {
                let (result, rect) = Self.titleCheck(hook, size: shape.size)
                print("export-check title \(shape.aspect) \(hook.count) chars: \(Self.describe(rect)) \(result.status.rawValue) \(result.items.map { String(format: "%@ %.4f", $0.band?.rawValue ?? "", $0.value ?? 0) })")
                if shape.aspect == "9:16" {
                    withKnownIssue("The hook title's 9:16 top sits in the top band (ADR-R49, the lead decides)") {
                        #expect(result.status == .ok, "the hook title on \(shape.aspect) at \(Self.describe(rect)): \(result.items)")
                    }
                } else {
                    #expect(result.status == .ok, "the hook title on \(shape.aspect) at \(Self.describe(rect)): \(result.items)")
                }
            }
        }
    }

    /// Every bundled style at its default position, reported (the lead's evidence for the band rule; not a gate).
    @Test func everyStyleAtItsDefaultPosition() async throws {
        let directory = try SharedResources.locate().root.appendingPathComponent("caption-styles/styles")
        let ids = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".json") }
            .map { String($0.dropLast(5)) }.sorted()
        for shape in Self.shapes {
            var clear: [String] = [], inBands: [String] = []
            for id in ids {
                let result = try await Self.captionCheck(id, size: shape.size)
                if result.status == .ok { clear.append(id) }
                else {
                    let deepest = result.items.map { $0.value ?? 0 }.max() ?? 0
                    inBands.append(String(format: "%@ (%@ %.3f)", id, result.items.first?.band?.rawValue ?? "", deepest))
                }
            }
            print("export-check styles \(shape.aspect): clear \(clear.count) [\(clear.joined(separator: ", "))]; in a band \(inBands.count) [\(inBands.joined(separator: ", "))]")
        }
    }
}
