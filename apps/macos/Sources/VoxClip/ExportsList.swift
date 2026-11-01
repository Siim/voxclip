import Foundation
import VoxClipCore

/// A projection of one project's latest export per target/aspect. No view, workspace,
/// file-opening or selection state: the Explorer and timeline EXPORTS tab share it.
@MainActor struct ExportsListModel {
    enum Status: String, Equatable {
        case exported = "Exported", edited = "Edited since export", failed = "Export failed"
        var warning: Bool { self != .exported }
    }
    struct Row: Identifiable, Equatable {
        let record: ExportRecord
        let targetName: String
        let status: Status
        let targetExists: Bool
        var id: String { record.targetID + "|" + record.aspect.rawValue }
        var target: ExportTarget { record.targetID == "full" ? .fullEdit : .clip(record.targetID) }
        var aspect: AspectRatio { record.aspect }
        var outputURL: URL? { record.outputPath.isEmpty ? nil : URL(fileURLWithPath: record.outputPath) }
        var retryFolder: URL? { record.retryFolder.map { URL(fileURLWithPath: $0) } }
        var title: String { "\(targetName) · \(aspect.rawValue)" }
        var duration: String { record.durationSeconds.map { durationLabel($0) } ?? "—" }
        var resolution: String {
            guard let width = record.width, let height = record.height else { return "—" }
            return "\(min(width, height))p"
        }
        var size: String { record.byteSize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—" }
        var time: String { record.exportedAt.formatted(date: .omitted, time: .shortened) }
        var metadata: String { [duration, resolution, size, time].joined(separator: " · ") }
        var accessibilityLabel: String { "\(title), \(metadata), \(status.rawValue)" }
    }
    let rows: [Row]
    init(project: Project, records: [ExportRecord], labelPosition: VoiceLabLabelPosition = .topRight) {
        let words = project.transcript?.words ?? []
        let positions = Dictionary(uniqueKeysWithValues: words.enumerated().map { ($0.element.id, $0.offset) })
        let clips = project.edits.clips.enumerated().filter { $0.element.origin == .manual || $0.element.selected }.sorted {
            let first = positions[$0.element.startWordId] ?? 0, second = positions[$1.element.startWordId] ?? 0
            return first == second ? $0.offset < $1.offset : first < second
        }.map(\.element)
        rows = records.filter { $0.projectID == project.id }.sorted {
            if $0.exportedAt != $1.exportedAt { return $0.exportedAt > $1.exportedAt }
            return ($0.targetID, $0.aspect.rawValue) < ($1.targetID, $1.aspect.rawValue)
        }.map { record in
            let index = clips.firstIndex { $0.id == record.targetID }
            let target: ExportTarget = record.targetID == "full" ? .fullEdit : .clip(record.targetID)
            let name = record.targetID == "full" ? "Full Take" : (index.map { "Clip \($0 + 1)" } ?? record.targetName ?? "Removed clip")
            var snapshot = project
            snapshot.export.aspect = record.aspect
            let fingerprint = try? ExportFingerprint.value(snapshot, target: target, labelPosition: labelPosition)
            let status: Status = record.failed == true ? .failed : (record.planFingerprint == fingerprint ? .exported : .edited)
            return Row(record: record, targetName: name, status: status, targetExists: record.targetID == "full" || index != nil)
        }
    }
}

extension EditorModel {
    var exportsList: ExportsListModel {
        _ = projectRevision
        return ExportsListModel(project: project, records: app.exportLedger.records, labelPosition: app.voiceLabLabelPosition)
    }
    /// Explicit row actions retain that row's aspect and target, even on another tab.
    /// A running job keeps its snapshot; no render starts until the Export button.
    func presentExport(_ row: ExportsListModel.Row, retry: Bool = false) {
        guard !exporting, row.targetExists, row.record.projectID == project.id, capabilities.writable, mediaExportable else { return }
        let ids: [String] = row.record.targetID == "full" ? [] : [row.record.targetID]
        guard ids.isEmpty || keptClips.contains(where: { $0.id == row.record.targetID }) else { return }
        presentExport(clipIDs: ids, folder: retry ? row.retryFolder : row.outputURL?.deletingLastPathComponent())
        if exportJob.isOpen, project.export.aspect != row.aspect {
            setAspect(row.aspect)
        }
    }
}
