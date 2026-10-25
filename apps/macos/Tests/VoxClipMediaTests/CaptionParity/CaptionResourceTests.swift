import Foundation
import Testing
import VoxClipCore
@testable import VoxClipMedia

@Suite(.serialized)
struct CaptionResourceTests {
    @Test("Missing caption resources report the reinstall error")
    func missingResources() throws {
        let shared = try CaptionMediaFixtures.shared()
        let missing = SharedResources(root: shared.root.appendingPathComponent("missing-\(UUID().uuidString)"))
        #expect(throws: VoxClipError.sharedResourcesMissing) { try CaptionResources.load(shared: missing) }
        #expect(throws: VoxClipError.sharedResourcesMissing) { try CaptionPipeline(shared: missing) }
    }

    @Test("Missing, corrupt and unreadable styles report the reinstall error", arguments: ["missing", "corrupt", "unreadable"])
    func styleLibraryErrors(_ failure: String) throws {
        let source = try CaptionMediaFixtures.shared()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-caption-style-error-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["fonts/fonts.json", "caption-styles/casemap.json", "caption-styles/stopwords.json", "caption-styles/emoji-keywords.json"] {
            let destination = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source.root.appendingPathComponent(path), to: destination)
        }
        let styles = root.appendingPathComponent("caption-styles/styles")
        if failure != "missing" {
            try FileManager.default.createDirectory(at: styles, withIntermediateDirectories: true)
            let file = styles.appendingPathComponent("broken.json")
            if failure == "corrupt" { try Data("{broken".utf8).write(to: file) }
            else { try FileManager.default.createSymbolicLink(at: file, withDestinationURL: styles.appendingPathComponent("absent")) }
        }
        #expect(throws: VoxClipError.sharedResourcesMissing) { try CaptionStyleLibrary(shared: SharedResources(root: root)) }
    }

    @Test("Missing bundled styles do not leak Cocoa errors through the harness")
    func missingStyle() async throws {
        let harness = try CaptionRenderHarness(shared: CaptionMediaFixtures.shared())
        let input = CaptionLayoutInput(style: "missing-caption-style", frame: .init(width: 320, height: 568),
            language: "en", duration: 1, words: [])
        await #expect(throws: VoxClipError.sharedResourcesMissing) { try await harness.layout(input) }
    }

    @Test("Font integrity failures retain the shared-resource error code")
    func fontIntegrity() throws {
        let shared = try CaptionMediaFixtures.shared()
        func data(_ path: String) throws -> Data { try Data(contentsOf: shared.root.appendingPathComponent(path)) }
        var manifest = try #require(JSONSerialization.jsonObject(with: data("fonts/fonts.json")) as? [String: Any])
        var fonts = try #require(manifest["fonts"] as? [[String: Any]])
        let index = try #require(fonts.firstIndex { $0["file"] as? String == "DMSans-Black.ttf" })
        fonts[index]["sha256"] = String(repeating: "0", count: 64)
        manifest["fonts"] = fonts
        let resources = try CaptionResources(fontManifest: JSONSerialization.data(withJSONObject: manifest),
            caseMap: data("caption-styles/casemap.json"), stopwords: data("caption-styles/stopwords.json"),
            emojiKeywords: data("caption-styles/emoji-keywords.json"))
        let library = try CaptionFontLibrary(shared: shared, resources: resources)
        #expect(throws: VoxClipError.sharedResourcesMissing) { try library.font("DMSans-Black.ttf") }
    }
}
