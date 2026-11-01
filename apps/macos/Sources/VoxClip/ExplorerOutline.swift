import SwiftUI
import VoxClipCore

/// Explorer sections are view preferences, shared between windows; no project edit.
enum ExplorerSection: String, CaseIterable {
    case take, clips, outline, suggested, voices, exports, recent
    var key: String { "ui.explorer.\(rawValue)" }
    var title: String { rawValue.capitalized }
    func accessibilityLabel(count: Int, title: String? = nil) -> String { "\(title ?? self.title), \(count) \(count == 1 ? "item" : "items")" }
}

enum ExplorerMetrics {
    static let rowHeight: CGFloat = 28
    /// f14: library rows have a title and metadata, unlike the one-line navigation rows.
    static let libraryRowHeight: CGFloat = 40
    static let outlineHeight: CGFloat = 24
    static let thumbnailSize = CGSize(width: 36, height: 20)
}

/// Stable take paragraph ids and ranges, filtered to the open tab, never re-split per clip.
struct ExplorerOutlineEntry: Identifiable, Equatable {
    let id: Int
    let words: Range<Int>
    let time: String
    let title: String
    let pendingHunk: Bool
    let aiVoice: Bool
    var accessibilityLabel: String {
        "\(time), \(title)" + (pendingHunk ? ", pending change" : "") + (aiVoice ? ", AI voice" : "")
    }
}

extension WorkspaceShell {
    func explorerExpanded(_ section: ExplorerSection) -> Bool { app.bool(section.key, fallback: section != .voices && section != .exports) }
    func setExplorerExpanded(_ section: ExplorerSection, _ expanded: Bool) { app.set(section.key, .bool(expanded)) }

    var outlineEntries: [ExplorerOutlineEntry] {
        guard let editor, !showsHome else { return [] }
        let words = editor.words
        let scope = editor.scopeBounds.map { $0.lowerBound..<($0.upperBound + 1) } ?? 0..<words.count
        return TranscriptParagraphs.split(words: words).enumerated().compactMap { index, range in
            guard range.overlaps(scope) else { return nil }
            let start = words[range.lowerBound].start, end = words[range.upperBound - 1].end
            return ExplorerOutlineEntry(id: index, words: range, time: TranscriptGutter.timecode(start),
                title: words[range.prefix(6)].map { editor.text($0) }.joined(separator: " "),
                pendingHunk: outlineHasPendingHunk?(range) ?? false,
                aiVoice: editor.project.voiceLab.segments.contains { $0.enabled && $0.replace.start < end && $0.replace.end > start })
        }
    }

    func scrollToOutline(_ index: Int) {
        guard let editor, let entry = outlineEntries.first(where: { $0.id == index }) else { return }
        editor.outlineScrollWordID = editor.words[entry.words.lowerBound].id
        editor.scopeScrollRevision += 1
    }

    /// Native List primary action is double-click. Return keeps its existing Keep/Rename path.
    func pinExplorerRows(_ rows: Set<SidebarItem>) {
        guard rows.count == 1, let row = rows.first else { return }
        choose(row, byClick: true)
        if case .clip(let id) = row, let tab = tabs.open.first(where: { $0.clipID == id }) { tabs.keepOpen(tab) }
    }

    func canRewriteExplorerClip(_ id: String) -> Bool {
        guard let editor,
              RewriteEntryPolicy.resolve(.menu, enabled: app.bool("voiceLab.enabled"), noticeAccepted: app.bool("voiceLab.betaNoticeAccepted"),
                editable: editor.capabilities.ai, selection: true) != .unavailable,
              let clip = editor.project.edits.clips.first(where: { $0.id == id }),
              let lower = editor.index(clip.startWordId), let upper = editor.index(clip.endWordId), lower <= upper else { return false }
        return editor.words[lower...upper].contains { !editor.cutWordIDs.contains($0.id) }
    }

    /// V13 replaces this selection-backed entry with its scope-taking Rewrite command.
    func rewriteExplorerClip(_ id: String) {
        guard canRewriteExplorerClip(id), let editor,
              let clip = editor.project.edits.clips.first(where: { $0.id == id }),
              let lower = editor.index(clip.startWordId), let upper = editor.index(clip.endWordId), lower <= upper else { return }
        choose(.clip(id))
        tabs.keepOpen(tabs.active)
        editor.selectedWordIDs = Set(editor.words[lower...upper].filter { !editor.cutWordIDs.contains($0.id) }.map(\.id))
        editor.selectedPauseIDs = []
        // The row's scope seek can finish during startup; the selected words, project
        // and connector still have to match, while its playhead need not stay still.
        editor.beginRewrite(entry: .menu, selectionAnchored: true)
    }
}

/// Voice management remains in Settings. Only visible consent records are projected;
/// the enabled setting is required in every build, independently of Settings visibility.
struct ExplorerVoiceEntry: Identifiable, Equatable {
    let id: String
    let name: String
    let made: String
    let needsAttention: Bool
    var state: String { needsAttention ? "Needs attention" : "Ready" }
    var accessibilityLabel: String { "\(name), \(made), \(state)" }
    init(record: VoiceConsentRecord, needsAttention: Bool) {
        id = record.id; name = record.voiceName
        let date = UTCTimestamp.date(from: record.createdAt)
        let day = date?.formatted(date: .abbreviated, time: .omitted) ?? String(record.createdAt.prefix(10))
        let sources = Set(record.samples.map(\.source))
        let source = sources == ["project"] ? "video audio" : sources == ["readAloud"] ? "a read-aloud" : "recorded audio"
        made = "made \(day) from \(source)"
        self.needsAttention = needsAttention
    }
}

extension WorkspaceShell {
    var explorerShowsVoices: Bool { !showsHome && app.bool("voiceLab.enabled") }
    var explorerVoices: [ExplorerVoiceEntry] {
        guard explorerShowsVoices else { return [] }
        let session = app.voiceLabSession
        return session.visibleRecords.map { record in
            let attention = record.status != .active || session.deleting.contains(record.id)
                || session.operations.contains { $0.recordID == record.id && !$0.finished }
            return ExplorerVoiceEntry(record: record, needsAttention: attention)
        }
    }
}
