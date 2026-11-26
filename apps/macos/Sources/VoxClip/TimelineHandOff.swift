import Foundation
import VoxClipCore
import VoxClipMedia

struct TimelineHandOffSelection: Equatable {
    let project: Project
    let targets: [ExportTarget]
    let folder: URL
    let pattern: String
    let canExport: Bool
}

struct TimelineHandOffPreparation {
    let selection: TimelineHandOffSelection
    let documents: [FCPXMLExporter.Prepared]
    let unavailable: String?
}

extension EditorModel {
    func timelineHandOffSelection(_ targets: [ExportTarget], folder: URL) -> TimelineHandOffSelection {
        let pattern = exportJob.fileNamePattern.isEmpty ? app.string("export.fileNamePattern", fallback: "{project}-{clip}-{aspect}") : exportJob.fileNamePattern
        return TimelineHandOffSelection(project: project, targets: targets, folder: folder, pattern: pattern, canExport: canExport)
    }

    func timelineExportUnavailable(_ selection: TimelineHandOffSelection) -> String? {
        guard selection.canExport, !selection.targets.isEmpty else { return "Keep part of the edit before saving a timeline." }
        for target in selection.targets {
            let id = ExportLedger.clipID(target)
            if let reason = FCPXML.unsupportedReason(effects: ClipEffects.rendered(in: selection.project, clipID: id)) { return reason }
        }
        guard let preparation = exportJob.timelinePreparation, preparation.selection == selection else {
            return "Checking the editable timeline…"
        }
        return preparation.unavailable
    }

    func prepareTimelineExport(_ selection: TimelineHandOffSelection) async {
        guard !exporting, selection == timelineHandOffSelection(selection.targets, folder: selection.folder),
              exportJob.timelinePreparation?.selection != selection else { return }
        exportJob.timelinePreparation = nil
        guard selection.canExport, !selection.targets.isEmpty,
              selection.targets.allSatisfy({ FCPXML.unsupportedReason(effects: ClipEffects.rendered(
                in: selection.project, clipID: ExportLedger.clipID($0))) == nil }) else { return }
        let snapshot = renderSnapshot()
        let project = selection.project
        var documents: [FCPXMLExporter.Prepared] = []
        var reserved: Set<String> = []
        let unavailable: String?
        do {
            for target in selection.targets {
                try Task.checkCancellation()
                let id = ExportLedger.clipID(target)
                let name = project.edits.clips.first { $0.id == id }?.title ?? (id == nil ? "full" : "clip")
                let aspect = project.export.aspect.rawValue.replacingOccurrences(of: ":", with: "x")
                let expanded = selection.pattern.replacingOccurrences(of: "{project}", with: project.title ?? "Untitled")
                    .replacingOccurrences(of: "{clip}", with: name).replacingOccurrences(of: "{aspect}", with: aspect)
                    .replacingOccurrences(of: ".mp4", with: "").replacingOccurrences(of: ".fcpxml", with: "")
                let url = ExportSelection.destination(base: ExportSelection.baseName(expanded), folder: selection.folder,
                    writeSRT: false, fileExtension: "fcpxml", reserved: reserved)
                reserved.insert(url.lastPathComponent.lowercased())
                let render = try await renderRequest(target: target, snapshot: snapshot)
                let ready = try await FCPXMLExporter.prepare(name: id == nil ? project.title ?? "Full edit" : name,
                    render: render, to: url, replacing: false,
                    cleanupRegistry: app.locations.root.appendingPathComponent("Scratch", isDirectory: true))
                documents.append(ready)
            }
            unavailable = nil
        } catch where Self.isExportCancellation(error) {
            return
        } catch {
            documents = []
            unavailable = await app.safeError(error, context: .export, messageContext: "export")
        }
        guard !Task.isCancelled, selection == timelineHandOffSelection(selection.targets, folder: selection.folder) else { return }
        exportJob.timelinePreparation = TimelineHandOffPreparation(selection: selection, documents: documents, unavailable: unavailable)
    }

    func beginTimelineExport(_ selection: TimelineHandOffSelection) {
        guard !exporting, selection == timelineHandOffSelection(selection.targets, folder: selection.folder),
              timelineExportUnavailable(selection) == nil, let prepared = exportJob.timelinePreparation else { return }
        let job = exportJob
        job.timelineRunning = true
        job.timelineFiles = []
        exportError = nil
        exporting = true
        exportTask = Task { [weak self] in
            guard let self else { return }
            defer { job.timelineRunning = false; exporting = false; exportTask = nil }
            do {
                job.timelineFiles = try await FCPXMLExporter.publish(prepared.documents)
                job.timelinePreparation = nil
                announce("Editable timelines saved")
            } catch where Self.isExportCancellation(error) {
            } catch {
                exportError = await app.safeError(error, context: .export, messageContext: "export")
                if let exportError { announce(exportError) }
            }
        }
    }
}
