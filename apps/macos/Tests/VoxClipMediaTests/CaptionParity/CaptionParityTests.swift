import Foundation
import CoreGraphics
import CoreVideo
import Testing
import VoxClipCore
@testable import VoxClipMedia

@Suite(.serialized)
struct CaptionParityTests {
    @Test("Every caption layout fixture with bundled CoreText shaping")
    func layouts() async throws {
        struct Input: Decodable { var input: CaptionLayoutInput }
        let shared = try CaptionMediaFixtures.shared(), resources = try CaptionResources.load(shared: shared)
        let shaper = CoreTextShaper(shared: shared)
        let urls = try CaptionMediaFixtures.urls()
        #expect(urls.count >= 86)
        var failed = 0, pages = 0, samples = 0
        for url in urls {
            let data = try Data(contentsOf: url), input = try JSONDecoder().decode(Input.self, from: data).input
            let fixture = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let expected = try #require(fixture["expected"] as? [String: Any]), sampleInputs = try #require(expected["samples"] as? [[String: Any]])
            let style = try CaptionMediaFixtures.style(input.style, shared: shared)
            let track = try await CaptionLayoutEngine.build(input: input, style: style, resources: resources, shaper: shaper)
            let actual = try CaptionMediaFixtures.project(track, samples: sampleInputs)
            let differences = CaptionMediaFixtures.differences(actual, expected)
            if !differences.isEmpty {
                failed += 1
                Issue.record("\(url.lastPathComponent): \(differences.prefix(12).joined(separator: "; "))")
            }
            pages += track.pages.count; samples += sampleInputs.count
        }
        print("Caption fixtures: \(urls.count) cases, \(pages) pages, \(samples) samples; \(failed) failures")
    }

    @Test("Caption blur and explicit geometry math fixtures")
    func drawingMath() throws {
        let shared = try CaptionMediaFixtures.shared()
        let fixture = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: shared.root.appendingPathComponent("fixtures/captions/math.json"))) as? [String: Any])
        let blur = try #require(fixture["blur"] as? [String: Any])
        for kernel in try #require(blur["kernels"] as? [[String: Any]]) {
            let sigma = try #require(kernel["sigma"] as? Double), expected = try #require(kernel["weights"] as? [Double])
            let actual = CaptionBlur.gaussianKernel(sigma: sigma)
            #expect(actual.count == expected.count)
            for index in actual.indices { #expect(abs(actual[index] - expected[index]) < 1e-9) }
        }
        for box in try #require(blur["boxSizes"] as? [[String: Any]]) {
            let sigma = try #require(box["sigma"] as? Double), expected = try #require(box["passes"] as? [[Int]])
            #expect(CaptionBlur.boxWindows(sigma: sigma).map { [$0.0, $0.1] } == expected)
        }
        for row in try #require(blur["rows"] as? [[String: Any]]) {
            let sigma = try #require(row["sigma"] as? Double), input = try #require(row["input"] as? [UInt8]), expected = try #require(row["output"] as? [UInt8])
            #expect(CaptionBlur.row(input, sigma: sigma) == expected)
        }
        for rounded in try #require(fixture["roundedRects"] as? [[String: Any]]) {
            let rect = try #require(rounded["rect"] as? [Double]), radius = try #require(rounded["radius"] as? Double)
            let path = CaptionPaths.rounded(.init(x: rect[0], y: rect[1], width: rect[2], height: rect[3]), radius: radius)
            var commands: [[Any]] = []
            path.applyWithBlock { pointer in
                let element = pointer.pointee
                switch element.type {
                case .moveToPoint: commands.append(["M", element.points[0].x, element.points[0].y])
                case .addLineToPoint: commands.append(["L", element.points[0].x, element.points[0].y])
                case .addCurveToPoint: commands.append(["C", element.points[0].x, element.points[0].y, element.points[1].x, element.points[1].y, element.points[2].x, element.points[2].y])
                case .closeSubpath: commands.append(["Z"])
                default: Issue.record("Unexpected path command")
                }
            }
            let expected = try #require(rounded["path"] as? [[Any]])
            #expect(commands.count == expected.count)
            for index in commands.indices {
                #expect(commands[index][0] as? String == expected[index][0] as? String)
                for coordinate in commands[index].indices.dropFirst() {
                    #expect(abs(Double(commands[index][coordinate] as! CGFloat) - (expected[index][coordinate] as! NSNumber).doubleValue) < 1e-6)
                }
            }
        }
        for gradient in try #require(fixture["gradients"] as? [[String: Any]]) {
            let rect = try #require(gradient["rect"] as? [Double]), angle = try #require(gradient["angleDeg"] as? Double)
            let start = try #require(gradient["p0"] as? [Double]), end = try #require(gradient["p1"] as? [Double])
            let actual = CaptionPaths.gradientEndpoints(.init(x: rect[0], y: rect[1], width: rect[2], height: rect[3]), angle: angle)
            #expect(abs(actual.0.x - start[0]) < 1e-6 && abs(actual.0.y - start[1]) < 1e-6)
            #expect(abs(actual.1.x - end[0]) < 1e-6 && abs(actual.1.y - end[1]) < 1e-6)
        }
    }

    @Test("Render all caption goldens and gallery states")
    func goldenRenders() async throws {
        struct Input: Decodable { var input: CaptionLayoutInput }
        let shared = try CaptionMediaFixtures.shared(), resources = try CaptionResources.load(shared: shared)
        let shaper = CoreTextShaper(shared: shared), harness = try CaptionRenderHarness(shared: shared)
        let parity = CaptionRenderPool(shared: shared), direct = CaptionRenderPool(shared: shared, cacheLimit: 0)
        let output = try CaptionStoredGoldens.generationOutput(ProcessInfo.processInfo.environment["VOXCLIP_GOLDEN_OUT"], shared: shared)
        let goldenRoot = shared.root.appendingPathComponent("fixtures/captions/golden", isDirectory: true)
        let hasStoredGoldens = FileManager.default.fileExists(atPath: goldenRoot.path)
        let urls = try CaptionMediaFixtures.urls()
        let stored = try output == nil && hasStoredGoldens ? CaptionStoredGoldens(root: goldenRoot,
            cases: urls.map { $0.deletingPathExtension().lastPathComponent }) : nil
        var count = 0
        for url in urls {
            let data = try Data(contentsOf: url), input = try JSONDecoder().decode(Input.self, from: data).input
            let fixture = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any]), expected = try #require(fixture["expected"] as? [String: Any])
            let samples = try #require(expected["samples"] as? [[String: Any]])
            let track = try await CaptionLayoutEngine.build(input: input, style: CaptionMediaFixtures.style(input.style, shared: shared), resources: resources, shaper: shaper)
            let name = url.deletingPathExtension().lastPathComponent
            let images = try await harness.renderCase(at: url, out: output)
            #expect(images.count == samples.filter { $0["golden"] as? Bool == true }.count)
            let indexed = try stored?.images(name, expected: images)
            for (position, image) in images.enumerated() {
                let index = try #require(image.sample)
                #expect(image.t == samples[index]["t"] as? Double, "Unchanged fixture sample time: \(name) s\(index)")
                let actualRaster = try parity.band(track, time: image.t, width: input.frame.width, reduceMotion: false).raster()
                let directRaster = try direct.band(track, time: image.t, width: input.frame.width, reduceMotion: false).raster()
                var artifacts: URL?
                if actualRaster.rgba != directRaster.rgba {
                    artifacts = CaptionFailureArtifacts.write(actualRaster, directRaster, context: "\(name) s\(index)")
                }
                #expect(actualRaster.rgba == directRaster.rgba, "Byte-identical cache parity: \(name) s\(index); images: \(artifacts?.path ?? "none")")
                if let indexed { try stored?.compare(actualRaster, image: indexed[position], folder: name) }
                count += 1
                let state = CaptionTimeline.evaluate(track, time: image.t)
                if state.page != nil, state.motion.alpha > 0.01, !state.words.filter({ $0.visible && $0.opacity > 0.01 }).isEmpty {
                    #expect(image.crop.w > 1 && image.crop.h > 1, "Nonempty ink: \(name) s\(index)")
                }
            }
        }
        let tilesJSON = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: shared.root.appendingPathComponent("fixtures/captions/preview-tiles.json"))) as? [String: Any])
        let tiles = try #require(tilesJSON["tiles"] as? [[String: Any]])
        let tileImages = try await harness.renderTiles(at: shared.root.appendingPathComponent("fixtures/captions/preview-tiles.json"), out: output)
        let tileIndex = try stored?.images("tiles", expected: tileImages)
        for (position, tile) in tiles.enumerated() {
            let id = try #require(tile["style"] as? String), frame = try #require(tile["frame"] as? [String: Int]), time = try #require(tile["t"] as? Double)
            #expect(tileImages[position].t == time, "Unchanged fixture tile time: \(tileImages[position].file)")
            let style = try CaptionMediaFixtures.style(id, shared: shared), words = style.preview.text.split(separator: " ").map(String.init)
            let input = CaptionLayoutInput(style: id, frame: .init(width: frame["width"]!, height: frame["height"]!), language: "en", duration: 0.4 * Double(words.count) + 0.5,
                words: words.enumerated().map { .init(id: "tile-\($0.offset)", text: $0.element, start: 0.4 * Double($0.offset), end: 0.4 * Double($0.offset) + 0.35) })
            let track = try await CaptionLayoutEngine.build(input: input, style: style, resources: resources, shaper: shaper)
            let state = CaptionTimeline.evaluate(track, time: time, reduceMotion: true)
            if let page = state.page {
                let actual = CaptionMediaFixtures.page(track.pages[page], track: track)
                if let expected = tile["page"] {
                    let differences = CaptionMediaFixtures.differences(actual, expected)
                    #expect(differences.isEmpty, "Tile \(id): \(differences.prefix(5))")
                }
            }
            let expected = try #require(tile["sample"])
            let differences = CaptionMediaFixtures.differences(try CaptionMediaFixtures.sample(state, track: track), expected)
            #expect(differences.isEmpty, "Tile state \(id): \(differences.prefix(5))")
            let actual = try parity.band(track, time: time, width: input.frame.width, reduceMotion: true).raster()
            let uncached = try direct.band(track, time: time, width: input.frame.width, reduceMotion: true).raster()
            var artifacts: URL?
            if actual.rgba != uncached.rgba {
                artifacts = CaptionFailureArtifacts.write(actual, uncached, context: "Tile \(tileImages[position].file)")
            }
            #expect(actual.rgba == uncached.rgba, "Byte-identical tile cache parity: \(tileImages[position].file); images: \(artifacts?.path ?? "none")")
            if let tileIndex { try stored?.compare(actual, image: tileIndex[position], folder: "tiles") }
        }
        print("Caption cache parity: \(count) samples + \(tileImages.count) tiles; tile states checked")
        #expect(count == 292)
        #expect(tileImages.count == 38)
        if let output {
            print("Caption goldens generated at \(output.path); stored comparison skipped for generation (stored root: \(goldenRoot.path))")
        } else {
            try #require(hasStoredGoldens, "Missing stored caption goldens at \(goldenRoot.path); generate reviewed output outside shared/ first")
            print("Caption goldens: \(count) samples + \(tileImages.count) tiles compared at \(goldenRoot.path)")
        }
    }

    @Test("Bundled Estonian glyphs and numeric punctuation survive rendering")
    func estonianAndBGRA() async throws {
        let shared = try CaptionMediaFixtures.shared(), resources = try CaptionResources.load(shared: shared)
        let style = try CaptionMediaFixtures.style("vox-bold", shared: shared)
        let shaper = CoreTextShaper(shared: shared), rasterizer = CoreTextCaptionRasterizer(shared: shared)
        let input = CaptionLayoutInput(style: style.id, frame: .init(width: 1080, height: 1920), language: "et", duration: 2,
            words: [.init(id: "et", text: "õäöü šž 03:15.", start: 0, end: 1)])
        let track = try await CaptionLayoutEngine.build(input: input, style: style, resources: resources, shaper: shaper)
        #expect(track.words.first?.shaped.word.text == "ÕÄÖÜ ŠŽ 03:15")
        #expect(track.words.first?.shaped.droppedClusters.isEmpty == true)
        let raster = try await rasterizer.rasterize(track, time: 0.5)
        var buffer: CVPixelBuffer?
        #expect(CVPixelBufferCreate(nil, 1080, 1920, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess)
        try raster.composite(into: #require(buffer))
        let image = try CaptionGoldenWriter.encode(raster, file: "estonian.png", sample: nil, style: style.id, time: 0.5).image
        #expect(image.crop.w > 1 && image.crop.h > 1)
    }
}
