#if DEBUG
import AVFoundation
import SwiftUI
import VoxClipCore
import VoxClipMedia

private actor RegressionClipConnector: LLMConnector {
    nonisolated let id: ConnectorID = .ollama
    func status() -> ConnectorStatus { .ready }
    func models(refresh: Bool) -> [LLMModel] { [LLMModel(id: "fixture-local", name: "Fixture", contextTokens: 128000, source: .curated)] }
    func contextTokens(model: String) -> Int? { 128000 }
    func send(_ request: LLMRequest, model: String) -> RawCompletion {
        RawCompletion(text: "{\"clips\":[{\"title\":\"A clear point\",\"reason\":\"Self-contained fixture section\",\"score\":8,\"start_word\":10,\"end_word\":85}]}",
            model: model, stop: .complete)
    }
}

@MainActor enum DebugIntegratedFlow {
    static func run(app: AppModel, directory: URL) async throws -> [DebugUISuite.Result] {
        guard let root = app.shared?.root else { throw VoxClipError.sharedResourcesMissing }
        let media = root.appendingPathComponent("fixtures/media/joins-tone.mov")
        let transcriptURL = root.appendingPathComponent("fixtures/media/joins-tone.transcript.json")
        let transcript = try ProjectJSON.decoder().decode(Transcript.self, from: Data(contentsOf: transcriptURL))
        let probe = try await AVMediaProbe().probe(media)
        let document = try await VoxClipDocument(importing: media)
        var imported = document.project
        imported.media.source.durationSeconds = probe.durationSeconds
        imported.media.source.video = probe.video
        imported.media.source.audio = probe.audio
        imported.replaceTranscript(transcript)
        document.replaceProject(imported)
        let model = EditorModel(document: document, app: app, preview: DemoPreviewEngine())
        defer { model.close(); app.connectorOverride = nil }
        model.mediaResolved = true
        model.refresh()
        var results: [DebugUISuite.Result] = []
        func check(_ name: String, _ passed: Bool) { results.append(.init(name: name, passed: passed)) }
        check("synthetic video and transcript import", model.words.count == transcript.words.count && model.canExport)
        let first = model.words[0].id
        model.apply(.correct(id: first, text: "corrected"), name: "Correct word")
        model.apply(.cutSelection(ids: [model.words[2].id]), name: "Cut word")
        check("synthetic word correction and cut", model.project.edits.corrections[first] == "corrected" && model.project.edits.cutWordIds.contains(model.words[2].id))
        model.setStyle("vox-highlight")
        let render = try await model.renderRequest()
        check("caption preview uses prepared compositor layout", render.captionLayout != nil && render.captionLayout?.track.pages.isEmpty == false)
        let captionable = model.words.filter { $0.kind == .word }
        guard captionable.count >= 8 else { throw VoxClipError.projectUnreadable("Scope regression needs eight words") }
        let head = ClipRange(id: "scope-head", startWordId: captionable[0].id, endWordId: captionable[2].id)
        let tail = ClipRange(id: "scope-tail", startWordId: captionable[captionable.count - 3].id, endWordId: captionable[captionable.count - 1].id)
        model.apply(.addClip(head), name: "Head scope")
        model.apply(.addClip(tail), name: "Tail scope")
        model.apply(.setActiveClip(clipId: head.id), name: "Preview head")
        guard let state = model.editState() else { throw VoxClipError.projectUnreadable("Missing scope transcript") }
        func matches(_ request: RenderRequest, clip: ClipRange?) throws -> Bool {
            let segments = try buildSegments(state, activeClip: clip)
            let expectedPlan = try buildEditPlan(segments, duration: model.sourceDuration,
                sampleRate: Double(model.project.media.source.audio?.sampleRate ?? 48_000), pauseKeepSeconds: state.pauseKeepSeconds)
            let expected = captionCopy(segments, plan: expectedPlan)
            let actual = request.captionLayout?.input.words.map { CaptionWord(id: $0.id, text: $0.text, start: $0.start, end: $0.end) }
            return request.plan == expectedPlan && actual == expected
        }
        let fullScope = try await model.renderRequest(target: .fullEdit)
        let tailScope = try await model.renderRequest(target: .clip(tail.id))
        let headPreview = try await model.renderRequest()
        check("full export captions use full plan with head clip open", try matches(fullScope, clip: nil)
            && fullScope.captionLayout?.input.words.contains(where: { $0.id == tail.endWordId }) == true)
        check("other clip export captions use its own plan", try matches(tailScope, clip: tail)
            && tailScope.captionLayout?.input.words.first?.id == tail.startWordId
            && tailScope.captionLayout?.input.words.contains(where: { $0.id == head.startWordId }) == false)
        check("current clip preview captions keep active scope", try matches(headPreview, clip: head)
            && headPreview.captionLayout?.input.words.first?.id == head.startWordId
            && headPreview.captionLayout?.input.words.contains(where: { $0.id == tail.startWordId }) == false)
        do { _ = try await model.renderRequest(target: .clip("missing-scope")); check("missing export clip is rejected", false) }
        catch { check("missing export clip is rejected", error as? VoxClipError == .exportFailed("Clip no longer exists")) }
        if let layout = tailScope.captionLayout, let word = layout.input.words.first, let shared = app.shared {
            let frame = try await CoreTextCaptionRasterizer(shared: shared).rasterize(layout,
                time: (word.start + word.end) / 2, previewWidth: 320, reduceMotion: true)
            check("other clip words draw in a synthetic caption frame", frame.rgba.enumerated().contains { $0.offset % 4 == 3 && $0.element > 0 })
        } else { check("other clip words draw in a synthetic caption frame", false) }
        model.apply(.setActiveClip(clipId: nil), name: "Show full take")
        app.connectorOverride = { _ in RegressionClipConnector() }
        app.set("llm.connector", .string("ollama"))
        app.set("llm.model.ollama", .string("fixture-local"))
        app.set("llm.clips.snapToLines", .bool(false))
        model.preset = .quotes
        model.findClips()
        await model.findTask?.value
        check("fake local connector adds persistent AI clip", model.project.ai.results.count == 1 && model.project.edits.clips.contains { $0.origin == .ai } && model.clipError == nil)
        let outputDirectory = directory.appendingPathComponent("integrated-export")
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        model.beginExport(targets: [.fullEdit], folder: outputDirectory)
        await model.exportTask?.value
        let output = model.exports.first?.outputURL
        check("synthetic caption export writes playable media (\(model.exportError ?? "no error"))", output.map { FileManager.default.fileExists(atPath: $0.path) } == true && model.exportError == nil)
        let saved = directory.appendingPathComponent("integrated.voxclip")
        try JSONProjectStore.encode(document.snapshot(contentType: .voxclipProject)).write(to: saved)
        let reopened = try VoxClipDocument(data: Data(contentsOf: saved)).project
        check("synthetic project reopens with words", reopened.transcript == model.project.transcript)
        check("synthetic project reopens with edits", reopened.edits == model.project.edits)
        check("synthetic project reopens with captions", reopened.captions == model.project.captions)
        check("synthetic project reopens with clips", reopened.ai.results.count == 1
            && reopened.ai.results.first?.id == model.project.ai.results.first?.id
            && reopened.ai.results.first?.clips == model.project.ai.results.first?.clips
            && reopened.edits.clips.contains { $0.origin == .ai })
        var noTranscript = imported
        noTranscript.transcript = nil
        noTranscript.edits = ProjectEdits()
        let bare = EditorModel(document: VoxClipDocument(project: noTranscript), app: app, preview: DemoPreviewEngine())
        defer { bare.close() }
        bare.mediaResolved = true
        bare.refresh()
        let bareRender = try await bare.renderRequest(target: .fullEdit)
        check("transcript-free full export keeps video without captions", bareRender.plan.outputSamples > 0
            && bareRender.captionLayout == nil && bareRender.captions.words.isEmpty)
        return results
    }
}
#endif
