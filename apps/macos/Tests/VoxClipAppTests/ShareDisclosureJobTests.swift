#if DEBUG
import Foundation
import Testing
@testable import VoxClipCore
@testable import VoxClip

/// The Export job's optional share text for videos with accepted AI audio (voice-lab.md §11.3–11.4).
@Suite("Headless share disclosure", .serialized, .enabled(if: ProcessInfo.processInfo.environment["VOXCLIP_DATA_DIR"] != nil, "Use an isolated VOXCLIP_DATA_DIR for app-model tests; nothing is shared or opened."))
@MainActor struct ShareDisclosureJobTests {
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

    @Test func optingInKeepsTheLineWhenShareTextRulesAreUnavailable() throws {
        let model = try editor(); defer { model.close() }; exported(model, [.fullEdit])
        var draft = ShareCaptionDraft(); draft.load(target: "full", model: model)
        let original = draft.captionDraft
        draft.setDisclosure(true, format: { _, _ in throw VoxClipError.sharedResourcesMissing })
        #expect(draft.addDisclosure && draft.captionDraft == original + "\n\n" + line)
        draft.setDisclosure(true, format: { _, _ in throw VoxClipError.sharedResourcesMissing })
        #expect(draft.captionDraft == original + "\n\n" + line)
        draft.setDisclosure(false, format: { _, _ in throw VoxClipError.sharedResourcesMissing })
        #expect(!draft.addDisclosure && draft.captionDraft == original)
    }

    @Test func postDisclosureAlwaysDefaultsOffIncludingAIVoice() throws {
        let model = try editor(); defer { model.close() }
        exported(model, [.fullEdit, .clip("clip-main")])
        var draft = ShareCaptionDraft()
        for target in ["full", "clip-main"] {
            draft.load(target: target, model: model)
            #expect(!draft.addDisclosure && draft.disclosureLine == line)
            #expect(!draft.captionDraft.contains(line))
        }
        #expect(!model.app.bool("ui.export.shareExpanded"))
    }
    @Test func toggleAddsTheExactLineAndTurningItOffNeedsNoInterstitial() throws {
        let model = try editor(); defer { model.close() }; exported(model, [.fullEdit])
        var draft = ShareCaptionDraft(); draft.load(target: "full", model: model)
        let original = draft.captionDraft
        draft.setDisclosure(true)
        #expect(draft.addDisclosure && draft.captionDraft == original + "\n\n" + line)
        draft.setDisclosure(true)
        #expect(draft.captionDraft == original + "\n\n" + line)
        draft.setDisclosure(false)
        #expect(!draft.addDisclosure && draft.captionDraft == original)
        // Each destination receives the caption directly, with no held action or warning.
        for destination in ["x", "linkedin"] {
            let url = try #require(try ShareText.url(destination, caption: draft.captionDraft, disclosureLine: nil))
            let text = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "text" }?.value
            #expect(text == original)
        }
    }
    @Test func savedDisclosureDoesNotChangeTheOffDefaultAndDraftIsCapped() throws {
        let model = try editor { $0.share.captions["full"] = "Saved caption\n\n" + line }
        defer { model.close() }; exported(model, [.fullEdit])
        var draft = ShareCaptionDraft(); draft.load(target: "full", model: model)
        #expect(!draft.addDisclosure && draft.captionDraft == "Saved caption" && !draft.edited)
        draft.edit(String(repeating: "a", count: 3100)); draft.setDisclosure(true)
        #expect(draft.captionDraft.unicodeScalars.count <= 3000 && draft.captionDraft.hasSuffix(line))
    }
    @Test func targetsWithoutAIVoiceHaveNoVideoHintOrAutomaticPostLine() throws {
        let model = try editor { $0.edits.clips.append(ClipRange(id: "after-ai", startWordId: "w8", endWordId: "w9", title: "After")) }
        defer { model.close() }; exported(model, [.clip("after-ai")])
        var draft = ShareCaptionDraft(); draft.load(target: "after-ai", model: model)
        #expect(draft.disclosureLine == nil && !draft.addDisclosure)
        let original = draft.captionDraft; draft.setDisclosure(true)
        #expect(draft.captionDraft == original && !draft.addDisclosure)
    }
    @Test func theOptionalLineComesFromTheRenderedExportNotTheLiveProject() throws {
        let model = try editor(); defer { model.close() }; exported(model, [.fullEdit])
        var project = model.project
        project.voiceLab.segments = project.voiceLab.segments.map { var segment = $0; segment.enabled = false; return segment }
        model.replace(project, name: "Turn off AI segment")
        var draft = ShareCaptionDraft(); draft.load(target: "full", model: model)
        #expect(draft.disclosureLine == line && !draft.addDisclosure)
        draft.setDisclosure(true); #expect(draft.captionDraft.hasSuffix(line))
        #expect(model.shareDisclosureLine("clip-main") == nil)
    }
    @Test func draftsAndOptInSurviveSwitchingTargets() throws {
        let model = try editor(); defer { model.close() }; exported(model, [.fullEdit, .clip("clip-main")])
        let job = model.exportJob
        job.selectShareTarget("full", model: model); job.draft.edit("My caption"); job.draft.setDisclosure(true)
        job.selectShareTarget("clip-main", model: model)
        #expect(!job.draft.addDisclosure)
        job.selectShareTarget("full", model: model)
        #expect(job.draft.addDisclosure && job.draft.captionDraft == "My caption\n\n" + line)
    }
    @Test func openXKeepsAnOptedInLineWholeAndLastWhenTheCaptionIsCut() throws {
        let caption = String(repeating: "word ", count: 80) + "\n\n" + line
        let url = try #require(try ShareText.url("x", caption: caption, disclosureLine: line))
        let text = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "text" }?.value)
        #expect(text.hasSuffix("…\n\n" + line))
        #expect((ShareText.weight(text) ?? .max) <= 280)
        let linkedIn = try #require(try ShareText.url("linkedin", caption: caption, disclosureLine: line))
        #expect(URLComponents(url: linkedIn, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "text" }?.value == caption)
        #expect(ShareDisclosure.xMadeWithAITip == "Turn on 'Made with AI' in the post's content disclosure before posting.")
    }
    @Test func openXTipFollowsRenderedAIVoiceEvenWithOptionalPostLineOff() throws {
        let model = try editor { $0.edits.clips.append(ClipRange(id: "after-ai", startWordId: "w8", endWordId: "w9", title: "After")) }
        defer { model.close() }; exported(model, [.fullEdit, .clip("after-ai")])
        let job = model.exportJob
        job.selectShareTarget("after-ai", model: model)
        #expect(!job.openedX() && !job.showsXTip)
        job.selectShareTarget("full", model: model)
        #expect(!job.draft.addDisclosure && job.openedX() && job.showsXTip)
        job.selectShareTarget("after-ai", model: model)
        #expect(!job.showsXTip)
    }

}
#endif
