import SwiftUI
import VoxClipCore

/// The library sections stay at the Explorer's bottom; long lists scroll within
/// their own bounded area so they cannot squeeze out project navigation.
@MainActor struct ExplorerLibrarySections: View {
    @Bindable var shell: WorkspaceShell
    let editor: EditorModel
    private func contentHeight(exports: Int, voices: Int) -> CGFloat {
        let headers = shell.explorerShowsVoices ? 2 : 1
        let voiceCount = shell.explorerShowsVoices && shell.explorerExpanded(.voices) ? voices : 0
        let exportCount = shell.explorerExpanded(.exports) ? exports : 0
        return CGFloat(headers + voiceCount + exportCount) * ExplorerMetrics.rowHeight + CGFloat(headers)
    }
    var body: some View {
        let exports = editor.exportsList.rows
        let voices = shell.explorerVoices
        ScrollView {
            VStack(spacing: 0) {
                if shell.explorerShowsVoices {
                    VStack(spacing: 0) {
                        libraryDivider
                        ExplorerHeader(shell: shell, section: .voices, count: voices.count)
                        if shell.explorerExpanded(.voices) {
                            ForEach(voices) { ExplorerVoiceRow(entry: $0) }
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(ExplorerSection.voices.accessibilityLabel(count: voices.count))
                }
                VStack(spacing: 0) {
                    libraryDivider
                    ExplorerHeader(shell: shell, section: .exports, count: exports.count)
                    if shell.explorerExpanded(.exports) {
                        ForEach(exports) { ExplorerExportRow(editor: editor, row: $0) }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(ExplorerSection.exports.accessibilityLabel(count: exports.count))
            }
            .padding(.horizontal, 12)
        }
        .frame(height: min(contentHeight(exports: exports.count, voices: voices.count), 260))
        .background(DesignValues.color("bg.window"))
        .columnLayoutEvidence("explorer.library")
    }
    private var libraryDivider: some View {
        Rectangle().fill(DesignValues.color("line.default")).frame(height: 1).accessibilityHidden(true)
    }
}

@MainActor struct ExplorerVoiceRow: View {
    let entry: ExplorerVoiceEntry
    var body: some View {
        Button { openVoxClipSettings(pane: "voiceLab") } label: { content }
            .buttonStyle(.plain)
            .help(entry.accessibilityLabel)
            .contextMenu { Button("Manage in Settings") { openVoxClipSettings(pane: "voiceLab") } }
            .accessibilityLabel(entry.accessibilityLabel).accessibilityHint("Manage in Settings")
            .accessibilityActions { Button("Manage in Settings") { openVoxClipSettings(pane: "voiceLab") } }
            .columnLayoutEvidence("explorer.voice", text: entry.accessibilityLabel)
    }
    private var content: some View {
        HStack(spacing: 8) {
            Image(systemName: "person").font(.system(size: 13)).frame(width: 20).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(entry.name).font(.system(size: 13)).frame(height: 15)
                Text(entry.made).font(.system(size: 11)).foregroundStyle(DesignValues.color("text.tertiary")).frame(height: 13)
            }.lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
            Text(entry.state).font(.system(size: 11)).fixedSize()
                .foregroundStyle(DesignValues.color(entry.needsAttention ? "status.warning" : "text.tertiary"))
                .columnLayoutEvidence("explorer.voice.state", text: entry.state)
        }
        .foregroundStyle(DesignValues.color("text.primary"))
        .frame(height: ExplorerMetrics.rowHeight).contentShape(Rectangle())
    }
}

@MainActor struct ExplorerExportRow: View {
    let editor: EditorModel
    let row: ExportsListModel.Row
    private var hasFile: Bool { row.outputURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }
    var body: some View {
        HStack(spacing: 8) {
            ExplorerExportThumbnail(editor: editor, row: row)
            VStack(alignment: .leading, spacing: 0) {
                Text(row.title).font(.system(size: 13)).frame(height: 15)
                HStack(spacing: 0) {
                    Text(row.duration).font(DesignValues.mono(11)).fixedSize()
                        .columnLayoutEvidence("explorer.export.duration", text: row.duration)
                    Text(" · " + [row.resolution, row.size, row.time].joined(separator: " · ")).font(.system(size: 11))
                        .columnLayoutEvidence("explorer.export.facts", text: [row.resolution, row.size, row.time].joined(separator: " · "))
                }.foregroundStyle(DesignValues.color("text.tertiary")).frame(height: 13)
            }.lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
            if row.status.warning {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 11))
                    .foregroundStyle(DesignValues.color("status.warning")).accessibilityHidden(true)
                    .columnLayoutEvidence("explorer.exportWarning", text: row.status.rawValue)
            }
            Menu { actions } label: {
                Image(systemName: row.status == .failed ? "arrow.clockwise" : "arrow.up.right.square")
                    .font(.system(size: 11)).frame(width: 24, height: 24)
            } primaryAction: {
                if row.status == .failed { editor.presentExport(row, retry: true) } else { reveal() }
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help(row.status == .failed ? "Retry; more export actions in the menu" : "Show in Finder; more export actions in the menu")
            .accessibilityLabel("Export actions for \(row.title)")
        }
        .foregroundStyle(DesignValues.color("text.primary"))
        .frame(height: ExplorerMetrics.rowHeight).contentShape(Rectangle())
        .help(row.accessibilityLabel).onTapGesture(count: 2, perform: open)
        .contextMenu { actions }
        .accessibilityElement(children: .combine).accessibilityLabel(row.accessibilityLabel)
        .accessibilityActions { actions }
        .columnLayoutEvidence("explorer.export", text: row.accessibilityLabel)
    }
    @ViewBuilder private var actions: some View {
        Button("Show in Finder", action: reveal).disabled(!hasFile)
        Button("Open", action: open).disabled(!hasFile)
        Button("Export again") { editor.presentExport(row) }.disabled(!editor.capabilities.writable || !editor.mediaExportable || editor.exporting || !row.targetExists)
        if row.status == .failed {
            Button("Retry") { editor.presentExport(row, retry: true) }
                .disabled(!editor.capabilities.writable || !editor.mediaExportable || editor.exporting || !row.targetExists || row.retryFolder == nil)
        }
    }
    private func reveal() { if hasFile, let url = row.outputURL { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
    private func open() { if hasFile, let url = row.outputURL { NSWorkspace.shared.open(url) } }
}

/// Decode the exported file itself: later edits must not change its thumbnail.
@MainActor private struct ExplorerExportThumbnail: View {
    let editor: EditorModel
    let row: ExportsListModel.Row
    @State private var frame: CGImage?
    var body: some View {
        MediaThumbnail(status: .none, sources: StandInSources(frame: frame), surface: .row, cornerRadius: 3)
            .frame(width: ExplorerMetrics.thumbnailSize.width, height: ExplorerMetrics.thumbnailSize.height)
            .accessibilityHidden(true)
            .task(id: row.record) {
                frame = nil
                guard let url = row.outputURL else { return }
                let result = await ThumbnailCache.shared.frame(of: url, contentKey: row.id + url.path + String(row.record.exportedAt.timeIntervalSinceReferenceDate),
                    at: 0, scope: 0...max(0, row.record.durationSeconds ?? 0), filling: ExplorerMetrics.thumbnailSize, cache: editor.app.locations.cache)
                guard !Task.isCancelled else { return }
                if case .frame(let image)? = result { frame = image }
            }
    }
}
