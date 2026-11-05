#if DEBUG
import AppKit
import Foundation
import Testing
@testable import VoxClipCore
@testable import VoxClip

/// Ask Claude's bleeps on the Voice Lab path (ai.md §18.5): a clip with a voiced phrase renders its captions from the
/// Voice Lab plan (`prepared.outputPlan.captions`), and a bleeped word there shows × in the render request's caption
/// layout, as on the plain path.
@Suite("Voice Lab caption masking", .serialized, .offlineFixtures)
@MainActor struct VoiceLabCaptionMaskingTests {
    @Test func aBleepedWordShowsCrossesInTheVoiceLabCaptions() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-vl-mask-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(settingsStore: RegressionSettingsStore(), locations: DataLocations(environment: ["VOXCLIP_DATA_DIR": root.path]))
        let shared = try SharedResources.locate()
        var project = try JSONProjectStore.decode(Data(contentsOf: shared.root.appendingPathComponent("fixtures/voice-lab/passage-render-v3.voxclip")))
        // "clipper." (w8) is source speech after the voiced phrase "we ship" (w4–w5).
        let bleep = ClipEffect(id: "fx-bleep-1", clipId: nil, kind: .bleep, start: 3.65, end: 4.2, wordIds: ["w8"])
        project = try ClipEffects.adding([bleep], to: project)
        let editor = EditorModel(document: VoxClipDocument(project: project, demo: true), app: app, preview: DemoPreviewEngine())
        defer { editor.close() }
        editor.mediaResolved = true
        editor.refresh()
        let request = try await editor.renderRequest(target: .clip("clip-main"))
        let plan = try #require(request.voiceLab?.prepared.outputPlan, "the clip renders through the Voice Lab plan")
        #expect(plan.requiresSyntheticRendering)
        let words = try #require(request.captionLayout?.input.words)
        let masked = ClipEffects.masked("clipper.")
        #expect(words.contains { $0.id == "w8" && $0.text == masked }, "\(words.map(\.text))")
        #expect(!words.contains { $0.text.lowercased().contains("clipper") })
        #expect(words.contains { $0.id == "w3" && $0.text == "today" }, "other words stay")
    }
}
#endif
