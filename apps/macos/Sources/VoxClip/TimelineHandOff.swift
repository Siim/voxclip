import Foundation
import VoxClipCore
import VoxClipMedia

extension EditorModel {
    func timelineExportUnavailable(_ targets: [ExportTarget]) -> String? {
        guard canExport, !targets.isEmpty else { return "Keep part of the edit before saving a timeline." }
        for target in targets {
            let id = ExportLedger.clipID(target)
            if let reason = FCPXML.unsupportedReason(
                changesTiming: (ClipControlsProject.controls(for: id, in: project)?.speed ?? 1) != 1,
                effects: ClipEffects.rendered(in: project, clipID: id)) { return reason }
        }
        return nil
    }

    func beginTimelineExport(targets: [ExportTarget], folder: URL) {
        guard !exporting, timelineExportUnavailable(targets) == nil else { return }
        let snapshot = renderSnapshot()
        let project = snapshot.project
        let pattern = exportJob.fileNamePattern.isEmpty ? app.string("export.fileNamePattern", fallback: "{project}-{clip}-{aspect}") : exportJob.fileNamePattern
        let job = exportJob
        job.timelineRunning = true
        job.timelineFiles = []
        exportError = nil
        exporting = true
        exportTask = Task { [weak self] in
            guard let self else { return }
            defer { job.timelineRunning = false; exporting = false; exportTask = nil }
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                for target in targets {
                    try Task.checkCancellation()
                    let id = ExportLedger.clipID(target)
                    let name = project.edits.clips.first { $0.id == id }?.title ?? (id == nil ? "full" : "clip")
                    let aspect = project.export.aspect.rawValue.replacingOccurrences(of: ":", with: "x")
                    let expanded = pattern.replacingOccurrences(of: "{project}", with: project.title ?? "Untitled")
                        .replacingOccurrences(of: "{clip}", with: name).replacingOccurrences(of: "{aspect}", with: aspect)
                        .replacingOccurrences(of: ".mp4", with: "").replacingOccurrences(of: ".fcpxml", with: "")
                    let url = ExportSelection.destination(base: ExportSelection.baseName(expanded), folder: folder,
                        writeSRT: false, fileExtension: "fcpxml")
                    let render = try await renderRequest(target: target, snapshot: snapshot)
                    let saved = try await FCPXMLExporter.write(name: id == nil ? project.title ?? "Full edit" : name,
                        render: render, to: url, replacing: false)
                    job.timelineFiles.append(saved)
                }
                announce("Editable timelines saved")
            } catch where Self.isExportCancellation(error) {
            } catch {
                exportError = await app.safeError(error, context: .export, messageContext: "export")
                if let exportError { announce(exportError) }
            }
        }
    }
}
