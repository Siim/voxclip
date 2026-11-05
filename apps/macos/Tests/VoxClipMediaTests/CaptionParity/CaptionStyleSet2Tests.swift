import Foundation
import Testing
import VoxClipCore
@testable import VoxClipMedia

/// Fixture set 2 (tools/captions/style-sets.json): the Roboto Black styles. Its vectors live in
/// shared/fixtures/captions/styles-2 so set 1's files and pinned counts stay unchanged.
@Suite(.serialized, .offlineFixtures)
struct CaptionStyleSet2Tests {
    static let styles = ["emoji-pop", "glow", "heavy-shadow", "marker", "minimal", "punch-in", "sing-along"]

    struct Index: Decodable {
        struct Entry: Decodable { var file: String; var style: String }
        var fixture: String; var set: Int; var styles: [String]; var layout: [Entry]; var files: [String]
    }

    static func root() throws -> URL { try CaptionMediaFixtures.shared().root.appendingPathComponent("fixtures/captions/styles-2", isDirectory: true) }

    static func index() throws -> Index {
        try JSONDecoder().decode(Index.self, from: Data(contentsOf: root().appendingPathComponent("index.json")))
    }

    @Test("Set 2 index names every Roboto Black style and the style x aspect matrix")
    func indexShape() throws {
        let index = try Self.index()
        #expect(index.fixture == "voxclip-caption-style-set/1" && index.set == 2 && index.files == ["preview-tiles.json"])
        #expect(index.styles == Self.styles)
        #expect(index.layout.count == 21)
        #expect(Set(index.layout.map(\.style)) == Set(Self.styles))
        let shared = try CaptionMediaFixtures.shared()
        for id in Self.styles {
            let style = try CaptionMediaFixtures.style(id, shared: shared)
            #expect(style.font.file == "Roboto-Black.ttf" && style.font.family == "Roboto" && style.font.weight == 900, "\(id) font")
        }
        #expect(try CaptionMediaFixtures.style("minimal", shared: shared).emoji?.enabled != true)
        #expect(try CaptionMediaFixtures.style("emoji-pop", shared: shared).emoji?.maxPerPage == 1)
    }

    @Test("Set 2 layout fixtures with bundled CoreText shaping")
    func layouts() async throws {
        struct Input: Decodable { var input: CaptionLayoutInput }
        let shared = try CaptionMediaFixtures.shared(), resources = try CaptionResources.load(shared: shared)
        let shaper = CoreTextShaper(shared: shared), root = try Self.root()
        var checked = 0
        for entry in try Self.index().layout {
            let data = try Data(contentsOf: root.appendingPathComponent(entry.file)), input = try JSONDecoder().decode(Input.self, from: data).input
            let fixture = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let expected = try #require(fixture["expected"] as? [String: Any]), samples = try #require(expected["samples"] as? [[String: Any]])
            let track = try await CaptionLayoutEngine.build(input: input, style: CaptionMediaFixtures.style(input.style, shared: shared), resources: resources, shaper: shaper)
            let differences = CaptionMediaFixtures.differences(try CaptionMediaFixtures.project(track, samples: samples), expected)
            #expect(differences.isEmpty, "\(entry.file): \(differences.prefix(12).joined(separator: "; "))")
            checked += 1
        }
        #expect(checked == 21)
    }

    @Test("Set 2 pixel goldens and gallery tiles")
    func goldens() async throws {
        let shared = try CaptionMediaFixtures.shared(), resources = try CaptionResources.load(shared: shared)
        let shaper = CoreTextShaper(shared: shared), harness = try CaptionRenderHarness(shared: shared)
        let pool = CaptionRenderPool(shared: shared), root = try Self.root()
        let entries = try Self.index().layout
        let stored = try CaptionStoredGoldens(root: root.appendingPathComponent("golden", isDirectory: true),
                                              cases: entries.map { URL(fileURLWithPath: $0.file).deletingPathExtension().lastPathComponent })
        var images = 0
        for entry in entries {
            struct Input: Decodable { var input: CaptionLayoutInput }
            let url = root.appendingPathComponent(entry.file), name = url.deletingPathExtension().lastPathComponent
            let input = try JSONDecoder().decode(Input.self, from: Data(contentsOf: url)).input
            let track = try await CaptionLayoutEngine.build(input: input, style: CaptionMediaFixtures.style(input.style, shared: shared), resources: resources, shaper: shaper)
            let rendered = try await harness.renderCase(at: url)
            let indexed = try stored.images(name, expected: rendered)
            for (position, image) in rendered.enumerated() {
                let raster = try pool.band(track, time: image.t, width: input.frame.width, reduceMotion: false).raster()
                try stored.compare(raster, image: indexed[position], folder: name)
                images += 1
            }
        }
        let tilesURL = root.appendingPathComponent("preview-tiles.json")
        let tiles = try await harness.renderTiles(at: tilesURL)
        let tileIndex = try stored.images("tiles", expected: tiles)
        struct Tiles: Decodable { struct Tile: Decodable { var style: String; var frame: CaptionLayoutInput.Frame; var t: Double }; var tiles: [Tile] }
        for (position, tile) in try JSONDecoder().decode(Tiles.self, from: Data(contentsOf: tilesURL)).tiles.enumerated() {
            let style = try CaptionMediaFixtures.style(tile.style, shared: shared), words = style.preview.text.split(separator: " ").map(String.init)
            let input = CaptionLayoutInput(style: tile.style, frame: tile.frame, language: "en", duration: 0.4 * Double(words.count) + 0.5,
                words: words.enumerated().map { .init(id: "tile-\($0.offset)", text: $0.element, start: 0.4 * Double($0.offset), end: 0.4 * Double($0.offset) + 0.35) })
            let track = try await CaptionLayoutEngine.build(input: input, style: style, resources: resources, shaper: shaper)
            let raster = try pool.band(track, time: tile.t, width: input.frame.width, reduceMotion: true).raster()
            try stored.compare(raster, image: tileIndex[position], folder: "tiles")
        }
        #expect(images == 68)
        #expect(tiles.count == 14)
    }
}
