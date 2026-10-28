#if DEBUG
import SwiftUI
import VoxClipCore
import VoxClipMedia

actor RegressionExporter: Exporter {
    let failure: VoxClipError?
    var hold = false
    var pauseFirst = false
    private var resumeFirst: CheckedContinuation<Void, Never>?
    private(set) var jobs: [ExportJob] = []
    init(failure: VoxClipError? = nil) { self.failure = failure }
    func setHold(_ value: Bool) { hold = value }
    func pauseFirstTarget() { pauseFirst = true }
    func releaseFirstTarget() { resumeFirst?.resume(); resumeFirst = nil }
    func export(_ job: ExportJob, progress: @escaping @Sendable (ExportProgress) -> Void) async throws -> ExportResult {
        jobs.append(job)
        progress(ExportProgress(phase: .encoding, fraction: 0.25))
        if pauseFirst && jobs.count == 1 { await withCheckedContinuation { resumeFirst = $0 } }
        if hold { try await Task.sleep(for: .seconds(60)) }
        if let failure { throw failure }
        return ExportResult(outputURL: job.outputURL, srtURL: job.srtURL, durationSeconds: job.render.plan.duration, width: job.render.output.size.width, height: job.render.output.size.height, fps: job.render.output.fps, frames: 1, audioSampleRate: 48_000, audioSamples: 1, videoCodec: "h264", encoder: "fixture", elapsedSeconds: 0)
    }
}

@MainActor enum DebugExport {
    static func run(app: AppModel, fixture: Project, directory: URL, captures: Bool = true) async throws -> [DebugUISuite.Result] {
        let appearances: [(String, NSAppearance.Name)] = captures ? [("light", .aqua), ("dark", .darkAqua)] : []
        var project = fixture
        project.captions.styleId = "vox-highlight"
        project.export.aspect = .landscape
        project.export.srt = true
        project.share.captions["full"] = "Keep this full-edit caption."
        guard let words = project.transcript?.words, words.count >= 4 else { throw CocoaError(.coderInvalidValue) }
        project.edits.clips = [ClipRange(id: "export-range", startWordId: words[0].id, endWordId: words[3].id, title: "Export fixture")]
        let exporter = RegressionExporter()
        let model = EditorModel(document: VoxClipDocument(project: project), app: app, preview: DemoPreviewEngine(), exporter: exporter)
        defer { model.close() }
        model.mediaResolved = true; model.refresh()
        let undo = UndoManager(); undo.groupsByEvent = false; model.undoManager = undo
        guard let clip = project.edits.clips.first else { throw CocoaError(.coderInvalidValue) }
        let expectedRequest = try await model.renderRequest(target: .clip(clip.id))
        model.beginExport(targets: [.clip(clip.id)], folder: directory)
        await model.exportTask?.value
        var draft = ShareCaptionDraft()
        draft.load(target: clip.id, model: model)
        draft.commit(model: model)
        if captures { try await DebugUISuite.snapshot(ExportSheet(model: model).environment(app), name: "export-clip-result", size: NSSize(width: 668, height: 650), appearance: .aqua, directory: directory) }
        let unchanged = model.project.share.captions == project.share.captions && !undo.canUndo && model.exports.count == 1
        draft.edit("Edited clip caption")
        undo.beginUndoGrouping(); draft.commit(model: model); undo.endUndoGrouping()
        let scoped = model.project.share.captions[clip.id] == "Edited clip caption" && model.project.share.captions["full"] == project.share.captions["full"] && undo.canUndo
        undo.undo()
        var results: [DebugUISuite.Result] = [
            .init(name: "clip export leaves full caption and undo unchanged", passed: unchanged),
            .init(name: "caption edits commit only to their draft target", passed: scoped && model.project.share.captions == project.share.captions)
        ]
        func check(_ name: String, _ passed: Bool) { results.append(.init(name: name, passed: passed)) }
        check("This clip scope carries number, title and duration", model.exportScopeLabel(.thisClip, requestedIDs: [clip.id]) == "This clip\nClip 1 · Export fixture · \(timecode(model.editedDuration(clip)))")
        check("All clips scope carries kept count", model.exportScopeLabel(.allClips) == "All 1 clips")
        check("Full video scope carries duration", model.exportScopeLabel(.fullVideo) == "Full video · \(timecode(model.editedDuration(nil)))")
        check("successful clip export records Exported", model.exportRowStatus(clip.id) == .exported)
        let reloaded = ExportLedger(file: app.exportLedger.file)
        check("successful export ledger survives reload with its output path", reloaded.entry(projectID: project.id, targetID: clip.id, aspect: project.export.aspect)?.outputPath == model.exports.first?.outputURL.path)
        let job = await exporter.jobs.first
        let expectedAspect = project.export.aspect.rawValue.replacingOccurrences(of: ":", with: "x")
        let pattern = app.string("export.fileNamePattern", fallback: "{project}-{clip}-{aspect}")
        let expectedBase = ExportSelection.baseName(pattern.replacingOccurrences(of: "{project}", with: project.title ?? "Untitled").replacingOccurrences(of: "{clip}", with: clip.title ?? "clip").replacingOccurrences(of: "{aspect}", with: expectedAspect).replacingOccurrences(of: ".mp4", with: ""))
        let expectedURL = ExportSelection.destination(base: expectedBase, folder: directory, writeSRT: true)
        check("ledger integration preserves RenderRequest and byte-identical video/SRT names", job?.render == expectedRequest && job?.outputURL == expectedURL && job?.srtURL == expectedURL.deletingPathExtension().appendingPathExtension("srt"))
        let expectedSRT = expectedRequest.captionLayout.map(CaptionSubtitles.srt)
        let actualSRT = job?.render.captionLayout.map(CaptionSubtitles.srt)
        check("ledger integration preserves the fixture SRT bytes", expectedSRT?.isEmpty == false && actualSRT == expectedSRT)
        results += try fingerprints(project: project, target: .clip(clip.id))
        model.beginExport(targets: [.fullEdit], folder: directory)
        await model.exportTask?.value
        check("Full Take records successful full-video exports", model.exportRowStatus(target: .fullEdit) == .exported)
        for (name, appearance) in appearances {
            try await DebugUISuite.snapshot(FullTakeRow(editor: model), name: "full-take-exported-\(name)", size: NSSize(width: 300, height: 70), appearance: appearance, directory: directory)
        }
        model.exporting = true
        model.activeExportKey = ExportLedger.key(.fullEdit, aspect: model.project.export.aspect)
        model.exportProgress = ExportProgress(phase: .encoding, fraction: 0.25)
        check("Full Take shows active full-video progress", model.exportRowStatus(target: .fullEdit) == .exporting(25))
        model.exporting = false
        model.failedExports[model.activeExportKey!] = directory
        check("Full Take shows failure with Retry", model.exportRowStatus(target: .fullEdit) == .failed)
        model.failedExports = [:]
        undo.beginUndoGrouping()
        model.apply(.cutSelection(ids: [words[1].id]), name: "Cut word")
        undo.endUndoGrouping()
        check("cutting a clip word marks Edited since export", model.exportRowStatus(clip.id) == .changed)
        check("cutting a word marks Full Take Edited since export", model.exportRowStatus(target: .fullEdit) == .changed)
        let shell = WorkspaceShell(app: app)
        for (name, appearance) in appearances {
            try await DebugUISuite.snapshot(ClipRow(shell: shell, editor: model, clip: clip, suggested: false).padding(.vertical, 4), name: "export-edited-row-\(name)", size: NSSize(width: 270, height: 74), appearance: appearance, directory: directory)
        }
        undo.undo()
        check("one undo returns the row to Exported", model.exportRowStatus(clip.id) == .exported)
        undo.beginUndoGrouping(); model.activate(clip); undo.endUndoGrouping()
        model.presentExport()
        check("This clip defaults from the kept sidebar selection", model.exportTargets(.thisClip, requestedIDs: model.exportClipIDs) == [.clip(clip.id)])
        var withSuggestion = model.project
        withSuggestion.edits.clips.append(ClipRange(id: "not-kept", startWordId: words[0].id, endWordId: words[1].id, origin: .ai, selected: false))
        undo.beginUndoGrouping(); model.replace(withSuggestion, name: "Suggestion fixture"); undo.endUndoGrouping()
        check("All clips includes manual kept clips but excludes suggestions", model.exportTargets(.allClips) == [.clip(clip.id)] && model.exportTargets(.fullVideo) == [.fullEdit])
        for (name, appearance) in appearances {
            try await DebugUISuite.snapshot(ExportSheet(model: model).environment(app), name: "export-scope-\(name)", size: NSSize(width: 668, height: 650), appearance: appearance, directory: directory)
        }
        await exporter.setHold(true)
        model.beginExport(targets: [.clip(clip.id)], folder: directory)
        while await exporter.jobs.count < 2 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(20))
        check("active export drives the row's percentage", model.exportRowStatus(clip.id) == .exporting(25))
        for (name, appearance) in appearances {
            try await DebugUISuite.snapshot(ClipRow(shell: shell, editor: model, clip: clip, suggested: false).padding(.vertical, 4), name: "export-progress-row-\(name)", size: NSSize(width: 270, height: 58), appearance: appearance, directory: directory)
        }
        model.exportTask?.cancel()
        await model.exportTask?.value
        check("cancelling a running export marks the row failed with Retry", model.exportRowStatus(clip.id) == .failed)
        for (name, appearance) in appearances {
            try await DebugUISuite.snapshot(ClipRow(shell: shell, editor: model, clip: clip, suggested: false).padding(.vertical, 4), name: "export-failed-row-\(name)", size: NSSize(width: 270, height: 74), appearance: appearance, directory: directory)
        }
        await exporter.setHold(false)
        let jobsBeforeRetry = await exporter.jobs.count
        model.retryExport(clip.id)
        await model.exportTask?.value
        let retryCount = await exporter.jobs.count
        check("Retry runs just the failed clip and restores Exported", retryCount == jobsBeforeRetry + 1 && model.exportRowStatus(clip.id) == .exported)
        for (name, appearance) in appearances {
            try await DebugUISuite.snapshot(ClipRow(shell: shell, editor: model, clip: clip, suggested: false).padding(.vertical, 4), name: "export-success-row-\(name)", size: NSSize(width: 270, height: 58), appearance: appearance, directory: directory)
        }
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
        results += try await batchSnapshot(app: app, project: project, directory: directory)
        return results
    }
    private static func batchSnapshot(app: AppModel, project: Project, directory: URL) async throws -> [DebugUISuite.Result] {
        var initial = project
        let words = initial.transcript!.words
        initial.edits.clips = [
            ClipRange(id: "batch-first", startWordId: words[0].id, endWordId: words[2].id, title: "First", origin: .manual),
            ClipRange(id: "batch-second", startWordId: words[1].id, endWordId: words[3].id, title: "Second", origin: .manual)
        ]
        let exporter = RegressionExporter()
        await exporter.pauseFirstTarget()
        let editor = EditorModel(document: VoxClipDocument(project: initial), app: app, preview: DemoPreviewEngine(), exporter: exporter)
        defer { editor.close() }
        editor.mediaResolved = true; editor.refresh()
        let targets = editor.exportTargets(.allClips)
        let snapshot = editor.renderSnapshot()
        var expected: [RenderRequest] = []
        for target in targets { expected.append(try await editor.renderRequest(target: target, snapshot: snapshot)) }
        editor.beginExport(targets: targets, folder: directory)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while await exporter.jobs.isEmpty && clock.now < deadline { await Task.yield() }
        var changed = editor.project
        changed.edits.corrections[words[1].id] = "Changed during export"
        changed.edits.cutWordIds.append(words[2].id)
        changed.edits.clips.removeLast()
        changed.export.aspect = .portrait; changed.export.quality = .high; changed.export.srt = false
        changed.captions.styleId = "off"
        editor.replace(changed, name: "Edit during batch")
        await exporter.releaseFirstTarget()
        await editor.exportTask?.value
        let jobs = await exporter.jobs
        var results: [DebugUISuite.Result] = [
            .init(name: "batch exports removed later target without error", passed: jobs.count == 2 && editor.exports.count == 2 && editor.exportError == nil)
        ]
        for (index, job) in jobs.enumerated() {
            let target = targets[index]
            let fingerprint = try ExportFingerprint.value(initial, target: target)
            let record = app.exportLedger.entry(projectID: initial.id, targetID: ExportLedger.targetID(target), aspect: initial.export.aspect)
            let output = editor.exports[index]
            results.append(.init(name: "batch target \(index) uses start render, settings, output and fingerprint", passed:
                job.render == expected[index] && job.aspect == initial.export.aspect && job.quality == initial.export.quality && job.writeSRT == initial.export.srt &&
                job.srtURL != nil && record?.planFingerprint == fingerprint && output.durationSeconds == expected[index].plan.duration &&
                output.width == expected[index].output.size.width && output.height == expected[index].output.size.height &&
                job.render.captionLayout.map(CaptionSubtitles.srt) == expected[index].captionLayout.map(CaptionSubtitles.srt)))
        }
        var refresh = editor.project
        refresh.export.aspect = initial.export.aspect
        editor.replace(refresh, name: "View original export aspect")
        results.append(.init(name: "batch ledger marks intervening edits on refresh", passed: editor.exportRowStatus("batch-first") == .changed))
        return results
    }
    private static func fingerprints(project: Project, target: ExportTarget) throws -> [DebugUISuite.Result] {
        let baseline = try ExportFingerprint.value(project, target: target)
        var results: [DebugUISuite.Result] = []
        results.append(.init(name: "required target uses exact export-sheet disclosure", passed: EditorModel.exportSheetDisclosure(required: true) == "This video contains AI-modified speech. It will show AI MODIFIED."))
        results.append(.init(name: "unmodified target omits export-sheet disclosure", passed: EditorModel.exportSheetDisclosure(required: false) == nil))
        func compare(_ name: String, changed: Bool, edit: (inout Project) -> Void) throws {
            var next = project
            edit(&next)
            let value = try ExportFingerprint.value(next, target: target)
            results.append(.init(name: name, passed: (value != baseline) == changed))
        }
        try compare("fingerprint excludes confidence, speaker and modified time", changed: false) {
            $0.transcript?.words[0].conf = 0.123; $0.transcript?.words[0].speaker = "Metadata only"; $0.modifiedAt = Date.distantFuture
        }
        try compare("fingerprint excludes clip title, active selection, output folder and share copy", changed: false) {
            $0.edits.clips[0].title = "Renamed"; $0.edits.activeClipId = nil; $0.export.folder = "/unrelated"; $0.share.captions["full"] = "Share metadata"
        }
        try compare("fingerprint includes effective quality and bitrate", changed: true) { $0.export.quality = project.export.quality == .high ? .standard : .high }
        try compare("fingerprint includes effective encoding frame rate", changed: true) { $0.media.source.video?.frameRate = 60 }
        try compare("fingerprint includes this aspect's caption position", changed: true) { $0.captions.positionByAspect["16:9"] = CaptionPosition(x: 0.5, y: 0.3) }
        try compare("fingerprint excludes another aspect's caption position", changed: false) { $0.captions.positionByAspect["9:16"] = CaptionPosition(x: 0.3, y: 0.2) }
        try compare("fingerprint excludes corrections outside the clip", changed: false) {
            if let last = $0.transcript?.words.last { $0.edits.corrections[last.id] = "Outside" }
        }
        try compare("fingerprint excludes SRT sidecar intent", changed: false) { $0.export.srt.toggle() }
        for enabled in [false, true] {
            var snapshot = project
            snapshot.captions.styleId = enabled ? "vox-highlight" : "off"
            let original = try ExportFingerprint.value(snapshot, target: target)
            let changes: [(String, (inout Project) -> Void)] = [
                ("position", { $0.captions.positionByAspect["16:9"] = CaptionPosition(x: 0.4, y: 0.3) }),
                ("override", { $0.captions.overrides = ["fontSize": .number(72)] }),
                ("correction", { $0.edits.corrections[$0.transcript!.words[0].id] = "Changed" }),
                ("text", { $0.transcript?.words[0].text = "Changed" }),
                ("language", { $0.transcript?.language = "et" })
            ]
            for (name, change) in changes {
                var edited = snapshot
                change(&edited)
                let changed = try ExportFingerprint.value(edited, target: target) != original
                results.append(.init(name: "captions \(enabled ? "On" : "Off") fingerprint \(name)", passed: changed == enabled))
            }
        }
        var otherAspect = project
        otherAspect.export.aspect = .portrait
        let ledger = ExportLedger(file: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("json"))
        defer { try? FileManager.default.removeItem(at: ledger.file) }
        for snapshot in [project, otherAspect] {
            try ledger.record(ExportRecord(projectID: snapshot.id, targetID: ExportLedger.targetID(target), exportedAt: Date(), planFingerprint: ExportFingerprint.value(snapshot, target: target), styleId: snapshot.captions.styleId, aspect: snapshot.export.aspect, outputPath: "/fixture.mp4"))
        }
        results.append(.init(name: "ledger retains independent entries per clip and aspect", passed: ledger.records.count == 2))
        return results
    }
}
#endif
