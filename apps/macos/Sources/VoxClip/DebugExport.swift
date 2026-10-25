#if DEBUG
import SwiftUI
import VoxClipCore

actor RegressionExporter: Exporter {
    let failure: VoxClipError?
    init(failure: VoxClipError? = nil) { self.failure = failure }
    func export(_ job: ExportJob, progress: @escaping @Sendable (ExportProgress) -> Void) async throws -> ExportResult {
        if let failure { throw failure }
        return ExportResult(outputURL: job.outputURL, srtURL: job.srtURL, durationSeconds: job.render.plan.duration, width: job.render.output.size.width, height: job.render.output.size.height, fps: job.render.output.fps, frames: 1, audioSampleRate: 48_000, audioSamples: 1, videoCodec: "h264", encoder: "fixture", elapsedSeconds: 0)
    }
}

@MainActor enum DebugExport {
    static func run(app: AppModel, fixture: Project, directory: URL) async throws -> [DebugUISuite.Result] {
        var project = fixture
        project.captions.styleId = "off"
        project.share.captions["full"] = "Keep this full-edit caption."
        guard let words = project.transcript?.words, words.count >= 4 else { throw CocoaError(.coderInvalidValue) }
        project.edits.clips = [ClipRange(id: "export-range", startWordId: words[0].id, endWordId: words[3].id, title: "Export fixture")]
        let model = EditorModel(document: VoxClipDocument(project: project), app: app, preview: DemoPreviewEngine(), exporter: RegressionExporter())
        defer { model.close() }
        model.mediaResolved = true; model.refresh()
        let undo = UndoManager(); undo.groupsByEvent = false; model.undoManager = undo
        guard let clip = project.edits.clips.first else { throw CocoaError(.coderInvalidValue) }
        model.beginExport(targets: [.clip(clip.id)], folder: directory)
        await model.exportTask?.value
        var draft = ShareCaptionDraft()
        draft.load(target: clip.id, model: model)
        draft.commit(model: model)
        try await DebugUISuite.snapshot(ExportSheet(model: model).environment(app), name: "export-clip-result", size: NSSize(width: 668, height: 650), appearance: .aqua, directory: directory)
        let unchanged = model.project.share.captions == project.share.captions && !undo.canUndo && model.exports.count == 1
        draft.edit("Edited clip caption")
        undo.beginUndoGrouping(); draft.commit(model: model); undo.endUndoGrouping()
        let scoped = model.project.share.captions[clip.id] == "Edited clip caption" && model.project.share.captions["full"] == project.share.captions["full"] && undo.canUndo
        undo.undo()
        var results: [DebugUISuite.Result] = [
            .init(name: "clip export leaves full caption and undo unchanged", passed: unchanged),
            .init(name: "caption edits commit only to their draft target", passed: scoped && model.project.share.captions == project.share.captions)
        ]
        let sidecar = directory.appendingPathComponent("occupied.srt")
        try Data("Existing subtitles".utf8).write(to: sidecar)
        defer { try? FileManager.default.removeItem(at: sidecar) }
        let paired = ExportSelection.destination(base: "occupied", folder: directory, writeSRT: true)
        let videoOnly = ExportSelection.destination(base: "occupied", folder: directory, writeSRT: false)
        let subtitles = try Data(contentsOf: sidecar)
        results.append(.init(name: "export de-duplicates video and subtitle paths together", passed: paired.lastPathComponent == "occupied 2.mp4" && videoOnly.lastPathComponent == "occupied.mp4" && subtitles == Data("Existing subtitles".utf8)))
        for failure in [VoxClipError.cancelled, .exportFailed("fixture failure")] {
            let failed = EditorModel(document: VoxClipDocument(project: project), app: app, preview: DemoPreviewEngine(), exporter: RegressionExporter(failure: failure))
            failed.mediaResolved = true; failed.refresh()
            failed.beginExport(targets: [.clip(clip.id)], folder: directory)
            await failed.exportTask?.value
            results.append(.init(name: failure == .cancelled ? "VoxClip export cancellation is silent" : "real export failures retain an inline error", passed: failure == .cancelled ? failed.exportError == nil : failed.exportError?.isEmpty == false))
            failed.close()
        }
        return results
    }
}
#endif
