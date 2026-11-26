import Foundation
import Testing
import VoxClipCore

@Suite struct FCPXMLCLITests {
    @Test func exportsEditableCutPlanWithoutRenderingAnMP4() throws {
        let shared = try SharedResources.locate()
        let media = shared.root.appendingPathComponent("fixtures/media")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let output = dir.appendingPathComponent("Cut & keep.fcpxml")
        let result = try runCLI(["export", "--format", "fcpxml", "--open", media.appendingPathComponent("fillers-chirp.mp4").path,
            "--transcript", media.appendingPathComponent("fillers-chirp.transcript.json").path,
            "--cut-fillers", "--style", "vox-highlight", "--export", output.path, "--json"], directory: dir, timeout: 60, sharedRoot: shared.root)
        try #require(result.status == 0, "\(result.stderr) \(String(decoding: result.stdout, as: UTF8.self))")
        #expect(try result.json["format"] as? String == "fcpxml")
        let xml = try XMLDocument(contentsOf: output)
        #expect(try xml.nodes(forXPath: "//spine/asset-clip").count > 1)
        #expect(try !xml.nodes(forXPath: "//title[@role='titles.caption']/text/text-style").isEmpty)
        #expect(try !xml.nodes(forXPath: "//audio[@role='dialogue']").isEmpty)
        #expect(!FileManager.default.fileExists(atPath: output.deletingPathExtension().appendingPathExtension("mp4").path))
    }
}
