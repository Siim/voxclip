#if DEBUG
import Foundation
import Testing
@testable import VoxClipCore
@testable import VoxClip

/// The export sheet's share text for videos with accepted AI audio (voice-lab.md §11.3–11.4).
@Suite("Headless share disclosure", .serialized, .enabled(if: ProcessInfo.processInfo.environment["VOXCLIP_DATA_DIR"] != nil, "Use an isolated VOXCLIP_DATA_DIR for app-model tests; nothing is shared or opened."))
@MainActor struct ShareDisclosureSheetTests {
    private let line = "Some words in this video were re-voiced with an AI copy of my own voice."
    private func editor(_ change: (inout Project) -> Void = { _ in }) throws -> EditorModel {
        let shared = try SharedResources.locate()
        var project = try JSONProjectStore.decode(Data(contentsOf: shared.root.appendingPathComponent("fixtures/voice-lab/passage-render-v3.voxclip")))
        change(&project)
        return EditorModel(document: VoxClipDocument(project: project, demo: true), app: AppModel(), preview: DemoPreviewEngine())
    }

    @Test func captionFieldOpensWithTheDisclosureLineForAIModifiedSpeech() throws {
        let model = try editor(); defer { model.close() }
        var draft = ShareCaptionDraft()
        draft.load(target: "full", model: model)
        #expect(draft.captionDraft == "Today we shipped the clipper. Thanks\n\n" + line)
        draft.load(target: "clip-main", model: model)
        #expect(draft.captionDraft.hasSuffix("\n\n" + line))
        #expect(draft.disclosureLine == line && !draft.lineRemoved)
    }

    @Test func removingTheLineWarnsAndRestoreLinePutsItBack() throws {
        let model = try editor(); defer { model.close() }
        var draft = ShareCaptionDraft()
        draft.load(target: "full", model: model)
        draft.edit("Today we shipped the clipper. Thanks")
        #expect(draft.lineRemoved)
        // Any edit to the line counts as removing it; white space differences don't.
        draft.edit("Today we shipped the clipper.\n\nSome words in this video were re-voiced with AI.")
        #expect(draft.lineRemoved)
        draft.edit("Today we shipped the clipper.  " + line.replacingOccurrences(of: " ", with: "\n"))
        #expect(!draft.lineRemoved)
        draft.edit("Today we shipped the clipper. Thanks  ")
        draft.restoreLine()
        #expect(draft.captionDraft == "Today we shipped the clipper. Thanks\n\n" + line)
        #expect(!draft.lineRemoved && draft.edited)
        #expect([ShareDisclosure.removedWarning, ShareDisclosure.shareAnyway, ShareDisclosure.restoreLine]
            == ["Your post no longer says the video contains AI-modified parts.", "Share anyway", "Restore line"])
    }

    @Test func targetsWithoutAIModifiedSpeechCarryNoLine() throws {
        let model = try editor { project in
            project.edits.clips.append(ClipRange(id: "after-ai", startWordId: "w8", endWordId: "w9", title: "After"))
        }
        defer { model.close() }
        var draft = ShareCaptionDraft()
        draft.load(target: "after-ai", model: model)
        #expect(draft.disclosureLine == nil && !draft.lineRemoved)
        #expect(draft.captionDraft == model.shareCaption("after-ai"))
        let off = try editor { project in project.voiceLab.segments = project.voiceLab.segments.map { var segment = $0; segment.enabled = false; return segment } }
        defer { off.close() }
        draft.load(target: "full", model: off)
        #expect(draft.disclosureLine == nil && draft.captionDraft == "Today we shipped the clipper. Thanks")
    }

    @Test func openXKeepsTheLineWholeAndLastWhenTheCaptionIsCut() throws {
        let caption = String(repeating: "word ", count: 80) + "\n\n" + line
        let url = try #require(try ShareText.url("x", caption: caption, disclosureLine: line))
        #expect(url.host == "x.com")
        let text = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "text" }?.value)
        #expect(text.hasSuffix("…\n\n" + line))
        #expect((ShareText.weight(text) ?? .max) <= 280)
        let linkedIn = try #require(try ShareText.url("linkedin", caption: caption, disclosureLine: line))
        #expect(URLComponents(url: linkedIn, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "text" }?.value == caption)
        #expect(ShareDisclosure.xMadeWithAITip == "Turn on 'Made with AI' in the post's content disclosure before posting.")
    }
}
#endif
