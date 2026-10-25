import Foundation
import VoxClipCore

public actor CaptionRenderHarness {
    private struct Case: Decodable {
        struct Schedule: Decodable {
            struct Sample: Decodable { var t: Double; var golden: Bool? }
            var samples: [Sample]
        }
        var fixture: String
        var id: String
        var input: CaptionLayoutInput
        var expected: Schedule
    }

    private struct Tiles: Decodable {
        struct Tile: Decodable { var style: String; var frame: CaptionLayoutInput.Frame; var t: Double }
        var fixture: String
        var tiles: [Tile]
    }

    private let shared: SharedResources
    private let resources: CaptionResources
    private let shaper: CoreTextShaper
    private let rasterizer: CoreTextCaptionRasterizer

    public init(shared: SharedResources) throws {
        self.shared = shared
        resources = try CaptionResources.load(shared: shared)
        shaper = CoreTextShaper(shared: shared)
        rasterizer = CoreTextCaptionRasterizer(shared: shared)
    }

    public func layout(_ input: CaptionLayoutInput) async throws -> CaptionLayoutResult {
        try await CaptionLayoutEngine.build(input: input, style: style(input.style), resources: resources, shaper: shaper)
    }

    public func renderCase(at fixtureURL: URL, sample: Int? = nil, out output: URL? = nil) async throws -> [CaptionGoldenImage] {
        let fixture = try JSONDecoder().decode(Case.self, from: Data(contentsOf: fixtureURL))
        guard fixture.fixture == "voxclip-caption-layout/1",
              fixture.id.range(of: "^[a-zA-Z0-9][a-zA-Z0-9_-]{0,127}$", options: .regularExpression) != nil,
              fixture.expected.samples.allSatisfy({ $0.t.isFinite }) else { throw CaptionFailure.invalid("Caption layout fixture") }
        if let sample, !fixture.expected.samples.indices.contains(sample) { throw CaptionFailure.invalid("Caption sample index") }
        let track = try await layout(fixture.input)
        var images: [CaptionGoldenImage] = []
        for (index, moment) in fixture.expected.samples.enumerated() {
            guard sample.map({ $0 == index }) ?? (moment.golden == true) else { continue }
            try Task.checkCancellation()
            let raster = try await rasterizer.rasterize(track, time: moment.t)
            if let output {
                let destination = sample == nil ? output.appendingPathComponent("\(fixture.id)/s\(index).png") : output
                images.append(try CaptionGoldenWriter.write(raster, to: destination, sample: index, style: nil, time: moment.t))
            } else {
                images.append(try CaptionGoldenWriter.encode(raster, file: "s\(index).png", sample: index, style: nil, time: moment.t).image)
            }
        }
        if sample == nil, let output { try CaptionGoldenWriter.writeIndex(images, to: output.appendingPathComponent("\(fixture.id).json")) }
        return images
    }

    public func renderTiles(at fixtureURL: URL, out output: URL? = nil) async throws -> [CaptionGoldenImage] {
        let fixture = try JSONDecoder().decode(Tiles.self, from: Data(contentsOf: fixtureURL))
        guard fixture.fixture == "voxclip-caption-preview/1", fixture.tiles.allSatisfy({ $0.t.isFinite }) else {
            throw CaptionFailure.invalid("Caption tile fixture")
        }
        var images: [CaptionGoldenImage] = []
        for tile in fixture.tiles {
            try Task.checkCancellation()
            let style = try style(tile.style)
            let words = CaptionTextRules.raw(style.preview.text).split(separator: " ").map(String.init)
            let input = CaptionLayoutInput(style: tile.style, frame: tile.frame, language: "en", duration: 0.4 * Double(words.count) + 0.5,
                words: words.enumerated().map { .init(id: "tile-\($0.offset)", text: $0.element, start: 0.4 * Double($0.offset), end: 0.4 * Double($0.offset) + 0.35) })
            let track = try await CaptionLayoutEngine.build(input: input, style: style, resources: resources, shaper: shaper)
            let raster = try await rasterizer.rasterize(track, time: tile.t, reduceMotion: true)
            let file = "\(tile.style)-\(tile.frame.width)x\(tile.frame.height).png"
            if let output {
                images.append(try CaptionGoldenWriter.write(raster, to: output.appendingPathComponent("tiles/\(file)"), sample: nil, style: tile.style, time: tile.t))
            } else {
                images.append(try CaptionGoldenWriter.encode(raster, file: file, sample: nil, style: tile.style, time: tile.t).image)
            }
        }
        if let output { try CaptionGoldenWriter.writeIndex(images, to: output.appendingPathComponent("tiles.json")) }
        return images
    }

    private func style(_ id: String) throws -> CaptionStyle {
        guard id.range(of: "^[a-z0-9][a-z0-9-]{1,39}$", options: .regularExpression) != nil, id != "off" else { throw CaptionFailure.invalid("Caption style id") }
        let url = shared.root.appendingPathComponent("caption-styles/styles/\(id).json")
        do {
            let style = try JSONDecoder().decode(CaptionStyle.self, from: Data(contentsOf: url))
            guard style.id == id else { throw VoxClipError.sharedResourcesMissing }
            return style
        } catch { throw VoxClipError.sharedResourcesMissing }
    }
}
