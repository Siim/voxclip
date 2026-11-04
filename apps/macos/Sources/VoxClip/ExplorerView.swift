import SwiftUI
import VoxClipCore

/// The v2 Explorer: a native plain List on the shell's flat chrome (impl-plan V2).
@MainActor struct ExplorerView: View {
    @Bindable var shell: WorkspaceShell
    var body: some View {
        ExplorerList(shell: shell)
            .modifier(EditorPaneFocus(model: shell.editor, pane: .sidebar))
    }
}

/// Below 1,128 the Explorer over the editor on request (impl-plan §3.5): flat, the
/// Explorer's width on the chrome, with a 1 pt `line.strong` edge, the boundary a pane over
/// content needs (3:1), and no shadow. Escape or a click on a row hides it again.
@MainActor struct SidebarOverlay: View {
    @Bindable var shell: WorkspaceShell
    var body: some View {
        ExplorerList(shell: shell, overlay: true)
            .modifier(EditorPaneFocus(model: shell.editor, pane: .sidebar))
            .frame(width: shell.layout.explorerWidth)
            .frame(maxHeight: .infinity)
            .background(DesignValues.color("bg.window"))
            .overlay(alignment: .trailing) { Rectangle().fill(DesignValues.color("line.strong")).frame(width: 1) }
            .onExitCommand { shell.sidebarOverlay = false }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Explorer")
            .accessibilityIdentifier("voxclip.sidebar.overlay")
    }
}

/// Home, the open project's Full Take, kept clips, the Suggested group and the
/// actions, and on Home the recent projects. Selecting a row scopes the editor; Return
/// keeps a suggestion, renames a kept clip or opens a Recent row, and Delete dismisses
/// a suggestion or removes a kept clip. The selected row scrolls into view when the
/// editor moves it, for example after ⌥⌘K. After Find Clips the first new suggestion is
/// focused, not selected: Return keeps it, ⌫ dismisses it, and an arrow key selects it.
@MainActor private struct ExplorerList: View {
    @Bindable var shell: WorkspaceShell
    var overlay = false
    @FocusState private var listFocused: Bool

    var body: some View {
        ScrollViewReader { rows in
            content
                // A rename ends, and keeps its text, when the selection changes.
                .onChange(of: shell.selection) { _, row in
                    shell.endRename()
                    rows.scrollTo(row)
                }
                .onChange(of: shell.editor?.focusedSuggestion) { _, id in
                    guard let id, overlay || shell.layout.explorerVisible else { return }
                    rows.scrollTo(SidebarItem.clip(id))
                    listFocused = true
                }
                .accessibilityLabel("Explorer")
        }
    }
    private var content: some View {
        VStack(spacing: 0) {
            keys(list)
            if !shell.showsHome, let editor = shell.editor {
                ExplorerLibrarySections(shell: shell, editor: editor)
            }
        }
    }
    private var list: some View {
        List(selection: Binding(get: { shell.selection }, set: { if let row = $0 { shell.choose(row) } })) {
            if shell.showsHome {
                Label("Home", systemImage: "house").frame(height: ExplorerMetrics.rowHeight)
                    .modifier(ExplorerRowForeground(emphasized: shell.selection == .home && listFocused)).tag(SidebarItem.home)
                    .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12)).listRowSeparator(.hidden)
            }
            if !shell.showsHome, let document = shell.document, let editor = shell.editor {
                ProjectSection(shell: shell, document: document, editor: editor, listFocused: listFocused)
            }
            if shell.showsHome { RecentSection(shell: shell, listFocused: listFocused) }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(DesignValues.color("bg.window"))
        .environment(\.defaultMinListRowHeight, ExplorerMetrics.outlineHeight)
        .contextMenu(forSelectionType: SidebarItem.self) { rows in
            if rows.count == 1, case .clip(let id) = rows.first, let editor = shell.editor {
                if let clip = editor.project.edits.clips.first(where: { $0.id == id }) {
                    ExplorerClipMenu(shell: shell, editor: editor, clip: clip, suggested: editor.isSuggestion(id))
                }
                Divider()
                Button("Keep Tab Open") { shell.pinExplorerRows(rows) }
            }
        } primaryAction: { rows in shell.pinExplorerRows(rows) }
        .focused($listFocused)
        .onChange(of: listFocused) { _, focused in if focused { shell.editor?.focusedPane = .sidebar } }
    }
    /// Return, Escape, the arrow keys and Delete (design §6.2 and §3.7).
    private func keys(_ list: some View) -> some View {
        list
            .onKeyPress(.return) {
                guard shell.renaming == nil else { return .ignored }
                if shell.editor?.actOnFocusedSuggestion(keep: true) == true { return .handled }
                if case .recent(let url) = shell.selection { Task { await shell.openRecent(url) }; return .handled }
                guard case .clip(let id) = shell.selection, let editor = shell.editor else { return .ignored }
                if editor.isSuggestion(id) { editor.keep(id) } else { shell.beginRename(id) }
                return .handled
            }
            .onKeyPress(.escape) {
                guard shell.renaming == nil else { return .ignored }
                if let editor = shell.editor, editor.finding { editor.findTask?.cancel(); return .handled }
                guard overlay else { return .ignored }
                shell.sidebarOverlay = false
                return .handled
            }
            .onKeyPress(keys: [.upArrow, .downArrow]) { _ in
                guard shell.renaming == nil, let id = shell.editor?.focusedSuggestion, shell.editor?.isSuggestion(id) == true else { return .ignored }
                shell.selection = .clip(id)
                return .handled
            }
            .onDeleteCommand {
                guard shell.renaming == nil, let editor = shell.editor, !editor.actOnFocusedSuggestion(keep: false), case .clip(let id) = shell.selection else { return }
                if editor.isSuggestion(id) { editor.dismiss(id) } else { editor.removeClip(id) }
            }
    }
}

@MainActor private struct ProjectSection: View {
    @Bindable var shell: WorkspaceShell
    @ObservedObject var document: VoxClipDocument
    let editor: EditorModel
    let listFocused: Bool

    var body: some View {
        Group {
            Section {
                if shell.explorerExpanded(.take) {
                    FullTakeRow(editor: editor, selectedFocused: shell.selection == .fullTake && listFocused)
                        .tag(SidebarItem.fullTake).id(SidebarItem.fullTake)
                }
            } header: { ExplorerHeader(shell: shell, section: .take, count: 1) }
            .accessibilityElement(children: .contain).accessibilityLabel(ExplorerSection.take.accessibilityLabel(count: 1, title: shell.projectTitle))
            Section {
                if shell.explorerExpanded(.clips) {
                    if editor.keptClips.isEmpty && !editor.words.isEmpty {
                        Text("No clips yet. Select words and press ⌥⌘K.")
                            .font(.system(size: 11)).foregroundStyle(DesignValues.color("text.tertiary")).selectionDisabled()
                    }
                    ForEach(editor.keptClips, id: \.id) { clip in
                        ClipRow(shell: shell, editor: editor, clip: clip, suggested: false, selectedFocused: shell.selection == .clip(clip.id) && listFocused)
                            .tag(SidebarItem.clip(clip.id)).id(SidebarItem.clip(clip.id))
                    }
                }
            } header: { ExplorerHeader(shell: shell, section: .clips, count: editor.keptClips.count) }
            .accessibilityElement(children: .contain).accessibilityLabel(ExplorerSection.clips.accessibilityLabel(count: editor.keptClips.count))
            let outline = shell.outlineEntries
            Section {
                if shell.explorerExpanded(.outline) {
                    ForEach(outline) { entry in
                        ExplorerOutlineRow(entry: entry, selectedFocused: shell.selection == .outline(entry.id) && listFocused)
                            .tag(SidebarItem.outline(entry.id)).id(SidebarItem.outline(entry.id))
                    }
                }
            } header: { ExplorerHeader(shell: shell, section: .outline, count: outline.count) }
            .accessibilityElement(children: .contain).accessibilityLabel(ExplorerSection.outline.accessibilityLabel(count: outline.count))
            let suggestions = editor.suggestedClips
            Section {
                if shell.explorerExpanded(.suggested) {
                    if let note = editor.fallbackNote, !suggestions.isEmpty { FallbackNote(note: note).selectionDisabled() }
                    if editor.finding { FindingRow(editor: editor).selectionDisabled() }
                    if editor.clipError == EditorModel.noClipsMatched { NoMatchRow(editor: editor).selectionDisabled() }
                    ForEach(suggestions, id: \.id) { clip in
                        ClipRow(shell: shell, editor: editor, clip: clip, suggested: true, focused: listFocused && editor.focusedSuggestion == clip.id,
                                selectedFocused: shell.selection == .clip(clip.id) && listFocused)
                            .tag(SidebarItem.clip(clip.id)).id(SidebarItem.clip(clip.id))
                    }
                }
            } header: { SuggestedHeader(shell: shell, editor: editor, keepAll: !suggestions.isEmpty) }
            .accessibilityElement(children: .contain).accessibilityLabel(ExplorerSection.suggested.accessibilityLabel(count: suggestions.count))
            if !shell.showsHome { SidebarActions(editor: editor).selectionDisabled() }
        }
        .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
        .listRowSeparator(.hidden)
    }
}

/// A disclosure is a 24 pt target, with the same count in its visible and spoken names.
@MainActor struct ExplorerHeader: View {
    @Bindable var shell: WorkspaceShell
    let section: ExplorerSection
    let count: Int
    private var title: String { section == .take ? shell.projectTitle : section.title }
    var accessibilityName: String { section.accessibilityLabel(count: count, title: title) }
    var body: some View {
        Button { shell.setExplorerExpanded(section, !shell.explorerExpanded(section)) } label: {
            HStack(spacing: 6) {
                Image(systemName: shell.explorerExpanded(section) ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold)).frame(width: 10)
                Text(title.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.55)
                    .lineLimit(1).truncationMode(.tail).layoutPriority(1)
                    .columnLayoutEvidence("explorer.header.title.\(section.rawValue)", text: title.uppercased())
                Spacer(minLength: 0)
                if section == .outline, let editor = shell.editor {
                    ViewThatFits(in: .horizontal) {
                        Text(editor.scopeName(shell.tabs.active.clipID)).font(.system(size: 11)).fixedSize()
                            .columnLayoutEvidence("explorer.header.trailing.outline", text: editor.scopeName(shell.tabs.active.clipID))
                        Color.clear.frame(width: 0, height: 0)
                    }
                } else if section != .take {
                    Text("\(count)").font(.system(size: 11))
                        .columnLayoutEvidence("explorer.header.trailing.\(section.rawValue)", text: "\(count)")
                }
            }
            .foregroundStyle(DesignValues.color("text.tertiary"))
            .frame(height: ExplorerMetrics.rowHeight).contentShape(Rectangle())
        }
        .buttonStyle(.plain).selectionDisabled()
        .help(section == .take ? shell.projectTitle : "")
        .accessibilityLabel(accessibilityName)
        .accessibilityValue(shell.explorerExpanded(section) ? "Expanded" : "Collapsed")
        .accessibilityIdentifier("voxclip.explorer.\(section.rawValue)")
        .columnLayoutEvidence("explorer.header.\(section.rawValue)", text: accessibilityName)
    }
}

@MainActor struct ExplorerOutlineRow: View {
    let entry: ExplorerOutlineEntry
    var selectedFocused = false
    @Environment(\.controlActiveState) private var activeState
    var body: some View {
        let emphasized = selectedFocused && activeState == .key
        HStack(spacing: 8) {
            Text(entry.time).font(DesignValues.mono(11)).foregroundStyle(SidebarStyle.meta(emphasized)).fixedSize()
            Text(entry.title).font(.system(size: 13)).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
            if entry.pendingHunk { Circle().fill(DesignValues.color("change.add")).frame(width: 5, height: 5).accessibilityHidden(true) }
            if entry.aiVoice { Circle().fill(DesignValues.color("ai.tint")).frame(width: 5, height: 5).accessibilityHidden(true) }
        }
        .frame(height: ExplorerMetrics.outlineHeight).contentShape(Rectangle())
        .modifier(ExplorerRowForeground(emphasized: emphasized))
        .accessibilityElement(children: .ignore).accessibilityLabel(entry.accessibilityLabel)
    }
}

/// Full Take's 28 pt row: 36×20 frame, title and edited length, or progress and Cancel.
@MainActor struct FullTakeRow: View {
    let editor: EditorModel
    var selectedFocused = false
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        let emphasized = selectedFocused && activeState == .key
        HStack(spacing: 8) {
            ExplorerThumbnail(editor: editor, clip: nil, emphasized: emphasized)
            Text("Full Take").font(.system(size: 13)).lineLimit(1)
            Spacer(minLength: 0)
            if editor.progress != nil {
                Text(editor.progressFraction.map { "\(Int($0 * 100))%" } ?? "Transcribing")
                    .font(DesignValues.mono(11)).foregroundStyle(SidebarStyle.meta(emphasized))
                Button { editor.workTask?.cancel(); editor.progress = nil } label: { Text("Cancel").modifier(SidebarActionTarget()) }
                    .buttonStyle(.borderless).font(.system(size: 11))
            } else {
                if editor.containsAISpeech() { ExplorerVoiceGlyph() }
                Text(SidebarStyle.fullTakeMeta(editor)).font(editor.transcribed ? DesignValues.mono(11) : .system(size: 11))
                    .foregroundStyle(SidebarStyle.meta(emphasized)).lineLimit(1)
            }
        }
        .frame(height: ExplorerMetrics.rowHeight).contentShape(Rectangle())
        .modifier(ExplorerRowForeground(emphasized: emphasized))
        .help(exportStatus.label)
        .contextMenu {
            if exportStatus == .failed { Button("Retry export") { editor.retryExport(target: .fullEdit) }.disabled(!editor.canExport) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel((!editor.transcribed && editor.progress == nil ? "Full take, not transcribed" : "Full take, \(SidebarStyle.spokenDuration(editor.editedDuration(nil))) after cuts") + (exportStatus == .none ? "" : ", \(exportStatus.label)") + (editor.containsAISpeech() ? ", AI modified" : ""))
    }
    private var exportStatus: ClipExportStatus { editor.exportRowStatus(target: .fullEdit) }
}

/// A kept clip or suggestion: number, 36×20 frame, title and mono duration in 28 pt.
/// The selected row, kept or suggested, always shows ✦ Rewrite and ⋯ More in the duration's
/// place, and hover or keyboard focus shows them on any row; the title truncates first. A
/// suggestion's Rewrite and Export keep it first (one undo step). Keep/Dismiss also live in
/// the clip bar. A focused suggestion draws the keyboard focus ring without becoming selected.
@MainActor struct ClipRow: View {
    @Bindable var shell: WorkspaceShell
    let editor: EditorModel
    let clip: ClipRange
    let suggested: Bool
    var focused = false
    var selectedFocused = false
    @State var hovering = false
    @FocusState private var editing: Bool
    @Environment(\.controlActiveState) private var activeState

    private var title: String { clip.title ?? "Untitled clip" }

    var body: some View {
        let number = editor.clipNumber(clip.id) ?? 0
        let emphasized = selectedFocused && activeState == .key
        let duration = editor.editedDuration(clip)
        let exportStatus: ClipExportStatus = suggested ? .none : editor.exportRowStatus(clip.id)
        HStack(spacing: 8) {
            Text("\(number)").font(DesignValues.mono(10)).foregroundStyle(SidebarStyle.meta(emphasized)).fixedSize().frame(minWidth: 13).accessibilityHidden(true)
                .columnLayoutEvidence("explorer.clipNumber", text: "\(number)")
            ExplorerThumbnail(editor: editor, clip: clip, emphasized: emphasized)
            if shell.renaming == clip.id {
                TextField("Clip title", text: $shell.renameDraft)
                    .textFieldStyle(.plain).font(.system(size: 13)).focused($editing)
                    .onAppear { editing = true }.onSubmit { shell.endRename() }.onExitCommand { shell.endRename(keep: false) }
            } else {
                Text(title).font(.system(size: 13)).lineLimit(1).truncationMode(.tail)
                    .columnLayoutEvidence("explorer.clipTitle", text: title)
            }
            Spacer(minLength: 0)
            if editor.containsAISpeech(clipID: clip.id) { ExplorerVoiceGlyph() }
            if showsActions {
                HStack(spacing: 2) {
                    if shell.canRewriteExplorerClip(clip.id) {
                        Button { shell.rewriteExplorerClip(clip.id) } label: {
                            Text("✦").font(.system(size: 12)).frame(width: 22, height: 20).contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless).focusable(false)
                        .help("Rewrite Clip \(number) (⇧⌘R)")
                        .accessibilityLabel("Rewrite Clip \(number)")
                        .columnLayoutEvidence("explorer.clipRewrite", text: "Rewrite Clip \(number)")
                    }
                    Menu {
                        ExplorerClipMenu(shell: shell, editor: editor, clip: clip, suggested: suggested)
                    } label: {
                        Image(systemName: "ellipsis").font(.system(size: 12)).frame(width: 22, height: 20).contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().frame(width: 22, height: 20)
                    .focusable(false).help("More").accessibilityLabel("More")
                    .columnLayoutEvidence("explorer.clipMore", text: "More")
                }
                .fixedSize().foregroundStyle(SidebarStyle.meta(emphasized))
                .columnLayoutEvidence("explorer.clipActions")
            } else {
                Text(durationLabel(duration)).font(DesignValues.mono(11)).foregroundStyle(SidebarStyle.meta(emphasized)).fixedSize()
                    .columnLayoutEvidence("explorer.clipDuration", text: durationLabel(duration))
            }
        }
        .frame(height: ExplorerMetrics.rowHeight).contentShape(Rectangle())
        .overlay(alignment: .leading) {
            if suggested {
                Path { path in path.move(to: CGPoint(x: -5, y: 4)); path.addLine(to: CGPoint(x: -5, y: 24)) }
                    .stroke(DesignValues.color("clip.label"), style: StrokeStyle(lineWidth: 2, dash: [3, 2])).accessibilityHidden(true)
            }
        }
        .modifier(ExplorerRowForeground(emphasized: emphasized))
        .overlay {
            if focused { RoundedRectangle(cornerRadius: 3).strokeBorder(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: 2).padding(-2) }
        }
        .onChange(of: editing) { _, editing in if !editing, shell.renaming == clip.id { shell.endRename() } }
        .onHover { hovering = $0 }
        .help(suggested ? reason : exportStatus.label)
        .contextMenu { ExplorerClipMenu(shell: shell, editor: editor, clip: clip, suggested: suggested) }
        .accessibilityElement(children: shell.renaming == clip.id ? .contain : .combine)
        .accessibilityLabel((suggested ? "Suggested clip \(number), \(title), \(SidebarStyle.spokenDuration(duration))" : "Clip \(number), \(title), \(SidebarStyle.spokenDuration(duration))") + (editor.containsAISpeech(clipID: clip.id) ? ", AI modified" : ""))
        .accessibilityHint((suggested ? reason : exportStatus.label) + (editor.containsAISpeech(clipID: clip.id) ? ", AI modified" : ""))
        .accessibilityActions {
            if shell.canRewriteExplorerClip(clip.id) {
                Button("Rewrite Clip \(number)") { shell.rewriteExplorerClip(clip.id) }
            }
            Button("Captions") { shell.captionExplorerClip(clip.id) }
            Button("Find More Clips") { shell.findMoreClips() }.disabled(!shell.canFindMoreClips)
            Button("Export Clip") { shell.exportExplorerClip(clip.id) }.disabled(!shell.canExportExplorerClip(clip.id))
            if suggested {
                Button("Keep") { editor.keep(clip.id) }.disabled(!editor.capabilities.edit)
                Button("Dismiss") { editor.dismiss(clip.id) }.disabled(!editor.capabilities.edit)
            } else {
                Button("Rename") { shell.beginRename(clip.id) }.disabled(!editor.capabilities.edit)
                Button("Remove") { editor.removeClip(clip.id) }.disabled(!editor.capabilities.edit)
                if exportStatus == .failed {
                    Button("Retry export") { editor.retryExport(clip.id) }.disabled(!editor.canExport || !editor.mediaExportable)
                }
            }
        }
    }

    var showsActions: Bool { shell.selection == .clip(clip.id) || hovering || focused || selectedFocused }

    /// A suggestion's reason and score, "8/10 · Strong hook, one idea".
    private var reason: String {
        guard let resultID = clip.aiResultId, let index = clip.aiClipIndex,
              let result = editor.project.ai.results.first(where: { $0.id == resultID }), index < result.clips.count else { return "" }
        let found = result.clips[index]
        return "\(found.score)/10 · \(found.reason)"
    }

}

/// One menu definition for the native List and the standalone DEBUG rows.
@MainActor private struct ExplorerClipMenu: View {
    let shell: WorkspaceShell
    let editor: EditorModel
    let clip: ClipRange
    let suggested: Bool
    var body: some View {
        if shell.canRewriteExplorerClip(clip.id) {
            Button("Rewrite Clip \(editor.clipNumber(clip.id) ?? 0)") { shell.rewriteExplorerClip(clip.id) }
        }
        Button("Captions") { shell.captionExplorerClip(clip.id) }
        Button("Find More Clips") { shell.findMoreClips() }.disabled(!shell.canFindMoreClips)
        Button("Export Clip…") { shell.exportExplorerClip(clip.id) }.disabled(!shell.canExportExplorerClip(clip.id))
        Divider()
        if suggested {
            Button("Keep Clip") { editor.keep(clip.id) }.disabled(!editor.capabilities.edit)
            Button("Dismiss") { editor.dismiss(clip.id) }.disabled(!editor.capabilities.edit)
        } else {
            if editor.exportRowStatus(clip.id) == .failed {
                Button("Retry export") { editor.retryExport(clip.id) }.disabled(!editor.canExport || !editor.mediaExportable)
            }
            Button("Rename…") { shell.beginRename(clip.id) }.disabled(!editor.capabilities.edit)
            Button("Copy Text") { copyText(clipText) }
            Divider()
            Button("Remove Clip") { editor.removeClip(clip.id) }.disabled(!editor.capabilities.edit)
        }
    }
    private var clipText: String {
        guard let lower = editor.index(clip.startWordId), let upper = editor.index(clip.endWordId), lower <= upper else { return "" }
        return editor.words[lower...upper].filter { !editor.cutWordIDs.contains($0.id) }.map { editor.text($0) }.joined(separator: " ")
    }
}

/// AI voice has one meaning and retains a spoken label on the enclosing row.
private struct ExplorerVoiceGlyph: View {
    var body: some View {
        Image(systemName: "waveform").font(.system(size: 11)).foregroundStyle(DesignValues.color("ai.tint")).accessibilityHidden(true)
    }
}

/// The non-selectable "Suggested" sub-header with Keep All.
@MainActor private struct SuggestedHeader: View {
    @Bindable var shell: WorkspaceShell
    let editor: EditorModel
    var keepAll = true
    var body: some View {
        HStack(spacing: 5) {
            ExplorerHeader(shell: shell, section: .suggested, count: editor.suggestedClips.count)
            if keepAll {
                Button { editor.keepAll() } label: { Text("Keep All").modifier(SidebarActionTarget()) }
                    .buttonStyle(.borderless).font(.system(size: 11, weight: .medium)).fixedSize()
                    .disabled(!editor.capabilities.edit)
            }
        }.selectionDisabled()
    }
}

/// "Answered by {fallback} because {model} was busy." under Suggested after a run the
/// fallback model answered (ai.md §4.3).
@MainActor private struct FallbackNote: View {
    let note: String
    var body: some View {
        Text(note).font(.system(size: 11)).foregroundStyle(DesignValues.color("text.secondary"))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, 2)
    }
}

/// "Finding clips…" under Suggested while a connector runs, with Cancel and the
/// connector line (design §6.2 and §13).
@MainActor private struct FindingRow: View {
    let editor: EditorModel
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Finding clips…").font(.system(size: 13))
                Spacer(minLength: 4)
                Button { editor.findTask?.cancel() } label: { Text("Cancel").modifier(SidebarActionTarget()) }.buttonStyle(.borderless).font(.system(size: 13))
            }
            Text("\(editor.findConnector?.label ?? "AI") · reading \(durationLabel(editor.editedDuration(nil))) of transcript")
                .font(.system(size: 11)).foregroundStyle(DesignValues.color("text.secondary")).lineLimit(1)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }
}

/// The connector's "nothing matched" message under Suggested, with Find Clips….
@MainActor private struct NoMatchRow: View {
    let editor: EditorModel
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(EditorModel.noClipsMatched).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
            Button { editor.requestFindClips(from: .sidebar) } label: { Text("Find Clips…").modifier(SidebarActionTarget()) }.controlSize(.small)
        }
        .padding(.vertical, 4)
    }
}

/// The section footer's actions: borderless buttons, never rows or arrow-key stops.
/// Under them, the setup callout when no connector is chosen, or a failure with Retry.
@MainActor private struct SidebarActions: View {
    @Bindable var editor: EditorModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            let untranscribed = SidebarStyle.untranscribedReason(editor)
            SidebarAction(title: "New Clip from Selection", symbol: "plus", hint: "⌥⌘K", enabled: !editor.selectedIDs.isEmpty, reason: untranscribed) { editor.makeClip() }
            SidebarAction(title: "Find Clips with AI", symbol: "sparkles", hint: "⇧⌘K", enabled: !editor.words.isEmpty && !editor.finding, reason: untranscribed) { editor.requestFindClips(from: .sidebar) }
                .popover(isPresented: Binding(get: { editor.showFindClips && editor.findClipsAnchor == .sidebar }, set: { if !$0 { editor.showFindClips = false } }), arrowEdge: .trailing) {
                    FindClipsPopover(model: editor)
                }
            if editor.showAISetup {
                SidebarCallout {
                    Text("Choose how VoxClip finds clips: your API key, a model on this computer, or an installed CLI.")
                    Button { openVoxClipSettings(pane: "ai") } label: { Text("Set Up AI…").modifier(SidebarActionTarget()) }.controlSize(.small)
                    Text("You can also select words and press ⌥⌘K to make a clip yourself.").font(.system(size: 11)).foregroundStyle(DesignValues.color("text.secondary"))
                }
            } else if let error = editor.clipError, error != EditorModel.noClipsMatched, !editor.finding {
                SidebarCallout {
                    Text(error)
                    Button { editor.retryFindClips() } label: { Text("Retry").modifier(SidebarActionTarget()) }.controlSize(.small)
                }
            }
        }
        .padding(.top, VCTokens.spacing3)
    }
}

@MainActor private struct SidebarCallout<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .font(.system(size: 13))
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) { Rectangle().fill(DesignValues.color("line.default")).frame(width: 1) }
            .padding(.top, VCTokens.spacing3)
            .accessibilityElement(children: .contain)
    }
}

@MainActor private struct SidebarAction: View {
    let title: String
    let symbol: String
    let hint: String
    let enabled: Bool
    /// Why the action is unavailable, as its tooltip.
    var reason: String?
    let perform: () -> Void

    var body: some View {
        Button(action: perform) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 12)).frame(width: 16)
                    .foregroundStyle(DesignValues.color(enabled ? "text.secondary" : "text.tertiary").opacity(enabled ? 1 : 0.55))
                Text(title).font(.system(size: 13))
                    .foregroundStyle(enabled ? DesignValues.color("text.primary") : DesignValues.color("text.tertiary").opacity(0.55))
                Spacer(minLength: 4)
                Text(hint).font(DesignValues.mono(11)).foregroundStyle(DesignValues.color("text.secondary").opacity(enabled ? 1 : 0.55))
            }
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(reason ?? "")
        .accessibilityLabel(title)
        .accessibilityHint(reason ?? "")
    }
}

/// On Home: up to 12 recent projects other than the open one. A click, or Return on the
/// selected row, opens the project in place; a missing video reads "Not found" and opens
/// Locate….
@MainActor private struct RecentSection: View {
    let shell: WorkspaceShell
    let listFocused: Bool
    var body: some View {
        let app = shell.app, recents = app.recentProjects
        let open = shell.document?.fileURL?.standardizedFileURL
        let urls = Array(app.recent.filter { $0.standardizedFileURL != open }.prefix(12))
        if !urls.isEmpty {
            Section {
                if shell.explorerExpanded(.recent) {
                    ForEach(urls, id: \.self) { url in
                        RecentRow(url: url, item: recents.items[url], sources: recents.sources(url, row: true), status: recents.status(url), shell: shell, emphasized: shell.selection == .recent(url) && listFocused)
                            .tag(SidebarItem.recent(url))
                            .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12)).listRowSeparator(.hidden)
                    }
                }
            } header: { ExplorerHeader(shell: shell, section: .recent, count: urls.count) }
            .accessibilityElement(children: .contain).accessibilityLabel(ExplorerSection.recent.accessibilityLabel(count: urls.count))
        }
    }
}

@MainActor private struct RecentRow: View {
    let url: URL
    let item: RecentProject?
    let sources: StandInSources
    let status: MediaStatus
    let shell: WorkspaceShell
    let emphasized: Bool

    private var title: String { item?.title ?? url.deletingPathExtension().lastPathComponent }

    var body: some View {
        Button {
            Task { await shell.openRecent(url) }
        } label: {
            HStack(spacing: 8) {
                MediaThumbnail(status: status, sources: sources, surface: .row, unread: item == nil, cornerRadius: 3).frame(width: 36, height: 20)
                Text(title).font(.system(size: 13)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                if status == .missing || status == .unreadable {
                    Label(status == .missing ? "Not found" : "Can't read video", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11)).foregroundStyle(DesignValues.color("status.warning")).lineLimit(1)
                }
            }
            .frame(height: ExplorerMetrics.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(ExplorerRowForeground(emphasized: emphasized))
        .accessibilityLabel(status.spokenState.map { "\(title), \($0)" } ?? title)
    }
}

/// A row's thumbnail (design §3.4 and §5.4): the scope's first kept frame and its
/// caption card at sidebar size (no plates), between which VoxClipCore's precedence
/// picks. It regenerates when the scope's card, the caption style or the media changes.
@MainActor private struct ExplorerThumbnail: View {
    let editor: EditorModel
    let clip: ClipRange?
    let emphasized: Bool
    @State private var frame: CGImage?
    @State private var card: CGImage?
    @State private var drawn = CaptionCardText.none

    private struct Key: Equatable {
        let text: CaptionCardText
        let styleId: String
        let overrides: String
        let frameTime: Double?
        let source: String
        let ready: Bool
    }

    var body: some View {
        let app = editor.app
        let size = ExplorerMetrics.thumbnailSize
        let scope: CaptionCardScope = clip.map { .clip($0.id) } ?? .fullTake
        let project = editor.project
        let key = Key(text: editor.cardText(scope, wordsVisible: app.bool("general.showPlaceholderWords", fallback: true)), styleId: app.cardStyle(for: project)?.id ?? "",
                      overrides: (try? String(decoding: JSONEncoder().encode(project.captions.overrides), as: UTF8.self)) ?? "",
                      frameTime: editor.firstKeptTime(clip), source: editor.sourceURL.path,
                      ready: editor.mediaResolved && !editor.mediaUnreadable && !editor.document.demo && project.media.source.video != nil)
        MediaThumbnail(status: status, sources: StandInSources(frame: frame, card: drawn, styleId: key.styleId, cardImage: card), surface: .row, cornerRadius: 3)
            .frame(width: size.width, height: size.height)
            .columnLayoutEvidence("explorer.thumbnail")
            .overlay {
                if emphasized { RoundedRectangle(cornerRadius: 3).strokeBorder(Color(nsColor: .alternateSelectedControlTextColor).opacity(0.55), lineWidth: 1) }
            }
            .task(id: key) { await load(key, size: size) }
    }

    /// Clip rows have no transcribing state: clips need words (§5.4.4 d).
    private var status: MediaStatus {
        if clip != nil, case .transcribing = editor.mediaStatus { return .none }
        return editor.mediaStatus
    }

    private func load(_ key: Key, size: CGSize) async {
        let app = editor.app, project = editor.project
        var image: CGImage?
        if let style = app.styles.first(where: { $0.id == key.styleId }) {
            image = await app.captions.card(CaptionCardInput(text: key.text, style: style, previewBackground: app.previewBackgrounds[style.id], overrides: project.captions.overrides,
                                                             language: project.transcript?.language, fit: .row()))
        }
        guard !Task.isCancelled else { return }
        card = image
        drawn = key.text
        guard key.ready else { frame = nil; return }
        let lower = clip.flatMap { range in editor.words.first { $0.id == range.startWordId }?.start } ?? 0
        let upper = clip.flatMap { range in editor.words.first { $0.id == range.endWordId }?.end } ?? project.media.source.durationSeconds
        let result = await ThumbnailCache.shared.frame(of: editor.sourceURL, contentKey: project.media.source.contentKey, at: key.frameTime ?? 0,
                                                       scope: lower...max(lower, upper), filling: size, cache: app.locations.cache)
        switch result {
        case .frame(let image)?: frame = image
        case .black?, .unreadable?: frame = nil
        case nil: break
        }
    }
}

@MainActor private struct ExplorerRowForeground: ViewModifier {
    let emphasized: Bool
    @Environment(\.controlActiveState) private var activeState

    func body(content: Content) -> some View {
        content.foregroundStyle(emphasized && activeState == .key ? Color(nsColor: .alternateSelectedControlTextColor) : DesignValues.color("text.primary"))
    }
}

@MainActor enum SidebarStyle {
    /// Meta text: text.tertiary, or the selected-text colour in a focused selected row.
    /// It is full strength, not the delta's 88%, so 11 pt meta reads at 4.5:1 on the
    /// dark accent selection.
    static func meta(_ emphasized: Bool) -> Color {
        emphasized ? Color(nsColor: .alternateSelectedControlTextColor) : DesignValues.color("text.tertiary")
    }
    /// Full Take's meta: its edited length, or "Not transcribed" (design C7).
    static func fullTakeMeta(_ editor: EditorModel) -> String {
        editor.transcribed ? durationLabel(editor.editedDuration(nil)) : "Not transcribed"
    }
    /// Why the clip actions are unavailable before transcription (design C7).
    static func untranscribedReason(_ editor: EditorModel) -> String? {
        editor.transcribed ? nil : "Transcribe the video to select words."
    }
    /// "2 minutes 10 seconds", "20 seconds".
    static func spokenDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded()), minutes = total / 60, rest = total % 60
        let parts = [minutes > 0 ? "\(minutes) \(minutes == 1 ? "minute" : "minutes")" : nil, rest > 0 || minutes == 0 ? "\(rest) \(rest == 1 ? "second" : "seconds")" : nil]
        return parts.compactMap { $0 }.joined(separator: " ")
    }
}

#if DEBUG
/// Production Explorer rows without a native List for the existing DEBUG row captures.
/// Captures obey the same unlocked, idle console gate as the window scenes.
@MainActor struct ExplorerRowsPreview: View {
    let shell: WorkspaceShell
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let document = shell.document, let editor = shell.editor {
                ProjectSection(shell: shell, document: document, editor: editor, listFocused: false).padding(.horizontal, 12)
            }
            Spacer(minLength: 0)
            if let editor = shell.editor { ExplorerLibrarySections(shell: shell, editor: editor) }
        }
        .frame(width: shell.layout.explorerWidth, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(DesignValues.color("bg.window"))
    }
}
#endif
