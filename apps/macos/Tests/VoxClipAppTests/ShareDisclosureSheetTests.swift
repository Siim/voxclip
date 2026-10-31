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
    /// What `beginExport` records for each target it rendered: the disclosure plan of that render.
    private func exported(_ model: EditorModel, _ targets: [ExportTarget]) {
        for target in targets {
            let scope: VoiceLabOutputScope
            switch target { case .fullEdit: scope = .full; case .clip(let id): scope = .clip(id) }
            let prepared = try? VoiceLabRenderContract.prepare(model.project, scope: scope, labelPosition: model.app.voiceLabLabelPosition)
            model.recordShareDisclosure(target, disclosure: prepared?.disclosure)
        }
    }

    @Test func captionFieldOpensWithTheDisclosureLineForAIModifiedSpeech() throws {
        let model = try editor(); defer { model.close() }
        exported(model, [.fullEdit, .clip("clip-main")])
        var draft = ShareCaptionDraft()
        draft.load(target: "full", model: model)
        #expect(draft.captionDraft == "Today we shipped the clipper. Thanks\n\n" + line)
        draft.load(target: "clip-main", model: model)
        #expect(draft.captionDraft.hasSuffix("\n\n" + line))
        #expect(draft.disclosureLine == line && !draft.lineRemoved)
    }

    @Test func removingTheLineWarnsAndRestoreLinePutsItBack() throws {
        let model = try editor(); defer { model.close() }
        exported(model, [.fullEdit])
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
        exported(model, [.clip("after-ai")])
        var draft = ShareCaptionDraft()
        draft.load(target: "after-ai", model: model)
        #expect(draft.disclosureLine == nil && !draft.lineRemoved)
        #expect(draft.captionDraft == model.shareCaption("after-ai"))
        let off = try editor { project in project.voiceLab.segments = project.voiceLab.segments.map { var segment = $0; segment.enabled = false; return segment } }
        defer { off.close() }
        exported(off, [.fullEdit])
        draft.load(target: "full", model: off)
        #expect(draft.disclosureLine == nil && draft.captionDraft == "Today we shipped the clipper. Thanks")
    }

    /// The line comes from the render the export made, as Windows reads it from the job snapshot, not from the live
    /// project: an edit made while the export ran or after it, here turning the AI segment off, leaves the shared file's
    /// AI speech and label in place, so it must not drop the line from that file's share text.
    @Test func theLineComesFromTheRenderedExportNotTheLiveProject() throws {
        let model = try editor(); defer { model.close() }
        exported(model, [.fullEdit])
        var project = model.project
        project.voiceLab.segments = project.voiceLab.segments.map { var segment = $0; segment.enabled = false; return segment }
        model.replace(project, name: "Turn off the AI segment")
        try #require(model.project.voiceLab.segments.allSatisfy { !$0.enabled })
        var draft = ShareCaptionDraft()
        draft.load(target: "full", model: model)
        #expect(draft.disclosureLine == line && draft.captionDraft.hasSuffix("\n\n" + line))
        // A target the export didn't render has no line.
        #expect(model.shareDisclosureLine("clip-main") == nil)
    }

    @Test func aRemovedLineHoldsEachShareUntilShareAnywayOrRestoreLine() throws {
        let model = try editor(); defer { model.close() }
        exported(model, [.fullEdit])
        var draft = ShareCaptionDraft()
        draft.load(target: "full", model: model)
        var flow = ShareDisclosureFlow()
        let actions: [ShareAction] = [.copy, .x, .linkedIn]
        // While the caption keeps the line, every action goes ahead at once.
        for action in actions {
            let now = flow.request(action, draft: draft)
            #expect(now == action && flow.pending == nil)
        }
        draft.edit("Today we shipped the clipper. Thanks")
        for action in actions {
            let now = flow.request(action, draft: draft)
            #expect(now == nil && flow.pending == action)
        }
        // Share anyway releases the held action with the caption as it is.
        let anyway = flow.shareAnyway(), nothing = flow.shareAnyway()
        #expect(anyway == .linkedIn && nothing == nil && flow.pending == nil && draft.lineRemoved)
        // Restore line puts the line back, then releases the held action.
        let held = flow.request(.copy, draft: draft)
        let result = flow.restoreLine(draft)
        let restored = try #require(result)
        #expect(held == nil && restored.action == .copy && flow.pending == nil)
        draft = restored.draft
        #expect(draft.captionDraft == "Today we shipped the clipper. Thanks\n\n" + line && !draft.lineRemoved)
        let again = flow.restoreLine(draft)
        #expect(again?.action == nil)
        // Editing the caption or choosing another target withdraws the warning.
        draft.edit("Today we shipped the clipper.")
        _ = flow.request(.x, draft: draft)
        #expect(flow.pending == .x)
        flow.edited()
        #expect(flow.pending == nil)
        _ = flow.request(.linkedIn, draft: draft)
        flow.select()
        #expect(flow.pending == nil)
    }

    @Test func openXShowsTheMadeWithAITipOnlyForATargetWithALine() throws {
        let model = try editor { project in
            project.edits.clips.append(ClipRange(id: "after-ai", startWordId: "w8", endWordId: "w9", title: "After"))
        }
        defer { model.close() }
        exported(model, [.fullEdit, .clip("after-ai")])
        var draft = ShareCaptionDraft()
        var flow = ShareDisclosureFlow()
        draft.load(target: "after-ai", model: model)
        let plain = flow.openedX(draft: draft)
        #expect(!plain && !flow.showsXTip)
        draft.load(target: "full", model: model)
        let disclosed = flow.openedX(draft: draft)
        #expect(disclosed && flow.showsXTip)
        flow.select()
        #expect(!flow.showsXTip)
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
