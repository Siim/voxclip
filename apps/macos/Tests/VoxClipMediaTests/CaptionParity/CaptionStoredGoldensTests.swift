import Foundation
import Testing
import VoxClipCore
@testable import VoxClipMedia

struct CaptionStoredGoldensTests {
    @Test("Golden generation refuses configured shared resources and committed goldens")
    func generationOutput() throws {
        let shared = try CaptionMediaFixtures.shared()
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-golden-output-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let alias = scratch.appendingPathComponent("shared-link")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: shared.root)
        for path in [shared.root, shared.root.appendingPathComponent("fixtures/captions/golden"),
                     shared.root.appendingPathComponent("other/../output"), alias.appendingPathComponent("generated")] {
            #expect(throws: CaptionFailure.self) { try CaptionStoredGoldens.generationOutput(path.path, shared: shared) }
        }
        let committed = try FixtureLoader.sharedRoot(environment: [:]).appendingPathComponent("fixtures/captions/golden")
        #expect(throws: CaptionFailure.self) {
            try CaptionStoredGoldens.generationOutput(committed.appendingPathComponent("generated").path, shared: SharedResources(root: scratch))
        }
        #expect(try CaptionStoredGoldens.generationOutput(nil, shared: shared) == nil)
        #expect(try CaptionStoredGoldens.generationOutput(scratch.path, shared: shared) == scratch.resolvingSymlinksInPath())
        let sibling = shared.root.deletingLastPathComponent().appendingPathComponent(shared.root.lastPathComponent + "-output")
        #expect(try CaptionStoredGoldens.generationOutput(sibling.path, shared: shared)?.path == sibling.resolvingSymlinksInPath().path)
    }

    @Test("Mismatch images use fresh system temporary directories")
    func failureArtifacts() throws {
        let raster = CaptionRaster(width: 1, height: 1, bytesPerRow: 4, rgba: Data([0, 0, 0, 0]))
        let first = CaptionFailureArtifacts.write(raster, raster, context: "Artifact location check")
        let second = CaptionFailureArtifacts.write(raster, raster, context: "Fresh artifact directory check")
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        #expect(first != second)
        #expect(first.deletingLastPathComponent().resolvingSymlinksInPath() == FileManager.default.temporaryDirectory.resolvingSymlinksInPath())
        #expect(try Set(FileManager.default.contentsOfDirectory(atPath: first.path)) == ["actual.png", "expected.png", "difference-x4.png"])
    }

    @Test("Stored PNG crops restore straight alpha with exact half-up premultiplication")
    func croppedPNG() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-stored-golden-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var bytes = Data(count: 32 * 24 * 4)
        let offset = (12 * 32 + 16) * 4
        bytes.replaceSubrange(offset..<(offset + 4), with: [32, 64, 96, 128])
        let raster = CaptionRaster(width: 32, height: 24, bytesPerRow: 128, rgba: bytes)
        let image = try CaptionGoldenWriter.write(raster, to: root.appendingPathComponent("synthetic/s0.png"), sample: 0, style: nil, time: 0)
        try CaptionGoldenWriter.writeIndex([image], to: root.appendingPathComponent("synthetic.json"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("tiles"), withIntermediateDirectories: true)
        try CaptionGoldenWriter.writeIndex([], to: root.appendingPathComponent("tiles.json"))
        let stored = try CaptionStoredGoldens(root: root, cases: ["synthetic"])
        let indexed = try stored.images("synthetic", expected: [image])
        var withinTolerance = image
        withinTolerance.t += 0.5e-9
        #expect(try stored.images("synthetic", expected: [withinTolerance]).count == 1)
        let decoded = try stored.raster(#require(indexed.first), folder: "synthetic")
        #expect(image.crop.x == 8 && image.crop.y == 4 && image.crop.w == 17 && image.crop.h == 17)
        #expect(decoded.rgba == raster.rgba)
        try stored.compare(raster, image: image, folder: "synthetic")
    }
}
