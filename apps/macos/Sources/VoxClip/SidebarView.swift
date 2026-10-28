import SwiftUI
import VoxClipCore

/// The workspace sidebar column (design §3.4 and §6.2).
@MainActor struct WorkspaceSidebar: View {
    @Bindable var shell: WorkspaceShell
    var body: some View {
        // On the column's root view, or NavigationSplitView ignores it.
        SidebarList(shell: shell)
            .modifier(EditorPaneFocus(model: shell.editor, pane: .sidebar))
            .navigationSplitViewColumnWidth(min: VCTokens.sizeSidebarMin, ideal: VCTokens.sizeSidebarIdeal, max: VCTokens.sizeSidebarMax)
    }
}

/// Below 960 the sidebar over the editor (design §3.7). Escape or a click on a row
/// hides it again.
@MainActor struct SidebarOverlay: View {
    @Bindable var shell: WorkspaceShell
    var body: some View {
        SidebarList(shell: shell, overlay: true)
            .frame(width: Double(VCTokens.sizeSidebarIdeal))
            .frame(maxHeight: .infinity)
            .background(DesignValues.color("bg.sunken"))
            .overlay(alignment: .trailing) { Rectangle().fill(DesignValues.color("line.strong")).frame(width: 1) }
            .shadow(color: .black.opacity(0.25), radius: 12, x: 4)
            .onExitCommand { shell.sidebarOverlay = false }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("voxclip.sidebar.overlay")
    }
}

/// Home, the open project's Full Take, kept clips, the Suggested group and the
/// actions, and on Home the recent projects. Selecting a row scopes the editor; Return
/// keeps a suggestion, renames a kept clip or opens a Recent row, and Delete dismisses
/// a suggestion or removes a kept clip. The selected row scrolls into view when the
/// editor moves it, for example after ⌘K. After Find Clips the first new suggestion is
/// focused, not selected: Return keeps it, ⌫ dismisses it, and an arrow key selects it.
@MainActor private struct SidebarList: View {
    @Bindable var shell: WorkspaceShell
    var overlay = false
    @FocusState private var listFocused: Bool

    var body: some View {
        ScrollViewReader { rows in
            keys(list)
                // A rename ends, and keeps its text, when the selection changes.
                .onChange(of: shell.selection) { _, row in
                    shell.endRename()
                    rows.scrollTo(row)
                }
                .onChange(of: shell.editor?.focusedSuggestion) { _, id in
                    guard let id, overlay || shell.columnVisibility != .detailOnly else { return }
                    rows.scrollTo(SidebarItem.clip(id))
                    listFocused = true
                }
                .accessibilityLabel("Workspace navigation")
        }
    }
    private var list: some View {
        List(selection: Binding(get: { shell.selection }, set: { if let row = $0 { shell.choose(row) } })) {
            Label("Home", systemImage: "house").modifier(SidebarRowForeground(emphasized: shell.selection == .home && listFocused)).tag(SidebarItem.home)
            if let document = shell.document, let editor = shell.editor {
                ProjectSection(shell: shell, document: document, editor: editor, listFocused: listFocused)
            }
            if shell.showsHome { RecentSection(shell: shell, listFocused: listFocused) }
        }
        .listStyle(.sidebar)
        .focused($listFocused)
        .onGeometryChange(for: Double.self) { $0.size.width } action: { if !overlay { shell.sidebarWidth = $0 } }
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
            // Escape hides the overlay sidebar (design §3.7).
            .onKeyPress(.escape) {
                guard overlay, shell.renaming == nil else { return .ignored }
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
        Section {
            FullTakeRow(editor: editor, selectedFocused: shell.selection == .fullTake && listFocused).tag(SidebarItem.fullTake).id(SidebarItem.fullTake)
            if editor.sortedClips.isEmpty && !editor.finding && editor.clipError != EditorModel.noClipsMatched && !editor.words.isEmpty {
                Text("No clips yet. Select words and press ⌘K.").font(.system(size: 11)).foregroundStyle(DesignValues.color("text.secondary")).selectionDisabled()
            }
            ForEach(editor.keptClips, id: \.id) { clip in
                ClipRow(shell: shell, editor: editor, clip: clip, suggested: false, selectedFocused: shell.selection == .clip(clip.id) && listFocused).tag(SidebarItem.clip(clip.id)).id(SidebarItem.clip(clip.id))
            }
            let suggestions = editor.suggestedClips
            let noMatch = editor.clipError == EditorModel.noClipsMatched
            if !suggestions.isEmpty || editor.finding || noMatch {
                SuggestedHeader(editor: editor, keepAll: !suggestions.isEmpty).selectionDisabled()
                if let note = editor.fallbackNote, !suggestions.isEmpty { FallbackNote(note: note).selectionDisabled() }
                if editor.finding { FindingRow(editor: editor).selectionDisabled() }
                if noMatch { NoMatchRow(editor: editor).selectionDisabled() }
                ForEach(suggestions, id: \.id) { clip in
                    ClipRow(shell: shell, editor: editor, clip: clip, suggested: true, focused: listFocused && editor.focusedSuggestion == clip.id, selectedFocused: shell.selection == .clip(clip.id) && listFocused)
                        .tag(SidebarItem.clip(clip.id)).id(SidebarItem.clip(clip.id))
                }
            }
        } header: {
            Text(shell.projectTitle).lineLimit(1)
        } footer: {
            if !shell.showsHome { SidebarActions(editor: editor) }
        }
    }
}

/// Full Take: an empty badge column, the take's 36×20 thumbnail, "Full Take" and its
/// edited length, or the transcription status with Cancel.
@MainActor struct FullTakeRow: View {
    let editor: EditorModel
    var selectedFocused = false
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        let emphasized = selectedFocused && activeState == .key
        HStack(spacing: 8) {
            Color.clear.frame(width: 16, height: 16)
            SidebarThumbnail(editor: editor, clip: nil, emphasized: emphasized).frame(width: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text("Full Take").font(.system(size: 13, weight: .medium)).lineLimit(1)
                if editor.progress != nil {
                    HStack(spacing: 6) {
                        Text(editor.progressFraction.map { "Transcribing · \(Int($0 * 100))%" } ?? "Transcribing").monospacedDigit()
                        Spacer(minLength: 4)
                        Button("Cancel") { editor.workTask?.cancel(); editor.progress = nil }.buttonStyle(.borderless).font(.system(size: 11, weight: .medium))
                    }
                    .font(.system(size: 11)).foregroundStyle(SidebarStyle.meta(emphasized))
                } else {
                    HStack(spacing: 4) {
                        Text(SidebarStyle.fullTakeMeta(editor)).font(editor.transcribed ? DesignValues.mono(11) : .system(size: 11))
                        if !exportStatus.secondLine && exportStatus != .none { Text(exportStatus.label).font(.system(size: 11)) }
                    }.foregroundStyle(SidebarStyle.meta(emphasized))
                    if exportStatus.secondLine {
                        HStack(spacing: 4) {
                            Text(exportStatus.label).font(.system(size: 11))
                            if exportStatus == .failed {
                                Button("Retry") { editor.retryExport(target: .fullEdit) }.buttonStyle(.plain).font(.system(size: 11))
                                    .disabled(!editor.canExport)
                            }
                        }.foregroundStyle(DesignValues.color("status.warning"))
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(height: exportStatus.secondLine ? 66 : 50)
        .modifier(SidebarRowForeground(emphasized: emphasized))
        .accessibilityElement(children: .combine)
        .accessibilityLabel((!editor.transcribed && editor.progress == nil ? "Full take, not transcribed" : "Full take, \(SidebarStyle.spokenDuration(editor.editedDuration(nil))) after cuts") + (exportStatus == .none ? "" : ", \(exportStatus.label)"))
    }
    private var exportStatus: ClipExportStatus { editor.exportRowStatus(target: .fullEdit) }
}

/// A kept clip or a suggestion: badge, 26×46 thumbnail, title and meta. Suggestions
/// carry Keep and Dismiss on their second line; a focused suggestion draws the
/// keyboard focus ring without being selected.
@MainActor struct ClipRow: View {
    @Bindable var shell: WorkspaceShell
    let editor: EditorModel
    let clip: ClipRange
    let suggested: Bool
    var focused = false
    var selectedFocused = false
    @FocusState private var editing: Bool
    @Environment(\.controlActiveState) private var activeState

    private var title: String { clip.title ?? "Untitled clip" }

    var body: some View {
        let number = editor.clipNumber(clip.id) ?? 0
        let emphasized = selectedFocused && activeState == .key
        let duration = editor.editedDuration(clip)
        let exportStatus: ClipExportStatus = suggested ? .none : editor.exportRowStatus(clip.id)
        HStack(spacing: 8) {
            ClipBadge(number: number, kind: suggested ? .suggested : editor.project.edits.activeClipId == clip.id ? .selected : .neutral, emphasized: emphasized)
            SidebarThumbnail(editor: editor, clip: clip, emphasized: emphasized).frame(width: 36)
            VStack(alignment: .leading, spacing: 2) {
                if shell.renaming == clip.id {
                    // Return, a click elsewhere, a selection change, leaving the project or
                    // Quit keeps the new title; Escape keeps the old one.
                    TextField("Clip title", text: $shell.renameDraft)
                        .textFieldStyle(.roundedBorder).font(.system(size: 13)).focused($editing)
                        .onAppear { editing = true }
                        .onSubmit { shell.endRename() }
                        .onExitCommand { shell.endRename(keep: false) }
                } else {
                    Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.tail)
                }
                HStack(spacing: 4) {
                    Text(durationLabel(duration)).font(DesignValues.mono(11)).foregroundStyle(SidebarStyle.meta(emphasized))
                    if !exportStatus.secondLine, exportStatus != .none {
                        Text(exportStatus.label).font(.system(size: 11)).foregroundStyle(SidebarStyle.meta(emphasized)).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if suggested {
                        Button { editor.keep(clip.id) } label: { Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)) }
                            .buttonStyle(KeepButtonStyle(emphasized: emphasized)).help("Keep (Return)")
                            .disabled(!editor.capabilities.edit)
                            .accessibilityLabel("Keep suggested clip \(number)")
                        Button { editor.dismiss(clip.id) } label: { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).frame(width: 24, height: 24) }
                            .buttonStyle(.borderless).foregroundStyle(SidebarStyle.meta(emphasized)).help("Dismiss (⌫)")
                            .disabled(!editor.capabilities.edit)
                            .accessibilityLabel("Dismiss suggested clip \(number)")
                    }
                }
                if exportStatus.secondLine {
                    HStack(spacing: 4) {
                        Text(exportStatus.label).font(.system(size: 11)).foregroundStyle(emphasized ? Color(nsColor: .alternateSelectedControlTextColor) : DesignValues.color("status.warning")).lineLimit(1)
                        if exportStatus == .failed {
                            Button("Retry") { editor.retryExport(clip.id) }.font(.system(size: 11)).buttonStyle(.plain)
                                .foregroundStyle(emphasized ? Color(nsColor: .alternateSelectedControlTextColor) : DesignValues.accentText)
                                .disabled(!editor.canExport || !editor.mediaExportable)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(height: exportStatus.secondLine ? 66 : 50)
        .modifier(SidebarRowForeground(emphasized: emphasized))
        .overlay {
            if focused { RoundedRectangle(cornerRadius: VCTokens.radiusXs).strokeBorder(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: 2).padding(-2) }
        }
        .onChange(of: editing) { _, editing in if !editing, shell.renaming == clip.id { shell.endRename() } }
        .help(suggested ? reason : "")
        .contextMenu {
            if suggested {
                Button("Keep Clip") { editor.keep(clip.id) }.disabled(!editor.capabilities.edit)
                Button("Dismiss") { editor.dismiss(clip.id) }.disabled(!editor.capabilities.edit)
            } else {
                Button("Export Clip…") { editor.presentExport(clipIDs: [clip.id]) }.disabled(!editor.canExport || !editor.mediaExportable)
                Button("Rename…") { shell.beginRename(clip.id) }.disabled(!editor.capabilities.edit)
                Button("Copy Text") { copyText(clipText) }
                Divider()
                Button("Remove Clip") { editor.removeClip(clip.id) }.disabled(!editor.capabilities.edit)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(suggested ? "Suggested clip \(number), \(title), \(SidebarStyle.spokenDuration(duration))" : "Clip \(number), \(title), \(SidebarStyle.spokenDuration(duration))")
        .accessibilityHint(suggested ? reason : exportStatus.label)
        .accessibilityActions {
            if suggested {
                Button("Keep") { editor.keep(clip.id) }.disabled(!editor.capabilities.edit)
                Button("Dismiss") { editor.dismiss(clip.id) }.disabled(!editor.capabilities.edit)
            } else {
                Button("Rename") { shell.beginRename(clip.id) }.disabled(!editor.capabilities.edit)
                Button("Remove") { editor.removeClip(clip.id) }.disabled(!editor.capabilities.edit)
            }
        }
    }

    /// A suggestion's reason and score, "8/10 · Strong hook, one idea".
    private var reason: String {
        guard let resultID = clip.aiResultId, let index = clip.aiClipIndex,
              let result = editor.project.ai.results.first(where: { $0.id == resultID }), index < result.clips.count else { return "" }
        let found = result.clips[index]
        return "\(found.score)/10 · \(found.reason)"
    }

    private var clipText: String {
        guard let lower = editor.words.firstIndex(where: { $0.id == clip.startWordId }), let upper = editor.words.firstIndex(where: { $0.id == clip.endWordId }), lower <= upper else { return "" }
        let cut = Set(editor.project.edits.cutWordIds)
        return editor.words[lower...upper].filter { !cut.contains($0.id) }.map { editor.text($0) }.joined(separator: " ")
    }
}

/// A clip's number (design §3.4): neutral on clip.badgeBackground, the accent fill
/// when selected, a dashed outline for suggestions, and a white outline in a focused
/// selected row.
@MainActor private struct ClipBadge: View {
    enum Kind { case neutral, selected, suggested }
    let number: Int
    let kind: Kind
    let emphasized: Bool

    var body: some View {
        Text("\(number)")
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(emphasized ? Color(nsColor: .alternateSelectedControlTextColor) : kind == .selected ? DesignValues.color("accent.on") : DesignValues.color("text.secondary"))
            .frame(width: 16, height: 16)
            .background {
                if !emphasized, kind == .selected { RoundedRectangle(cornerRadius: 4).fill(.tint) }
                else if !emphasized, kind == .neutral { RoundedRectangle(cornerRadius: 4).fill(DesignValues.color("clip.badgeBackground")) }
            }
            .overlay {
                if emphasized { RoundedRectangle(cornerRadius: 4).strokeBorder(Color(nsColor: .alternateSelectedControlTextColor), lineWidth: 1) }
                else if kind == .suggested { RoundedRectangle(cornerRadius: 4).strokeBorder(DesignValues.color("line.strong"), style: StrokeStyle(lineWidth: 1, dash: [2, 2])) }
            }
            .accessibilityHidden(true)
    }
}

/// Keep on a suggestion row (design §3.4): a bordered 24×24 control beside the
/// borderless 24×24 Dismiss.
private struct KeepButtonStyle: ButtonStyle {
    let emphasized: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 24, height: 24)
            .background(RoundedRectangle(cornerRadius: VCTokens.radiusXs).fill(Color(nsColor: configuration.isPressed ? .selectedControlColor : .controlColor).opacity(emphasized ? 0.25 : 1)))
            .overlay(RoundedRectangle(cornerRadius: VCTokens.radiusXs).strokeBorder(emphasized ? Color(nsColor: .alternateSelectedControlTextColor).opacity(0.7) : DesignValues.color("line.strong"), lineWidth: 1))
            .contentShape(Rectangle())
    }
}

/// The non-selectable "Suggested" sub-header with Keep All.
@MainActor private struct SuggestedHeader: View {
    let editor: EditorModel
    var keepAll = true
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "sparkles").font(.system(size: 10))
            Text("Suggested").font(.system(size: 11, weight: .semibold))
            Spacer()
            if keepAll {
                Button("Keep All") { editor.keepAll() }.buttonStyle(.borderless).font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DesignValues.color("text.primary"))
            }
        }
        .foregroundStyle(DesignValues.color("text.secondary"))
        .padding(.top, VCTokens.spacing3)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Suggested clips")
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
                Button("Cancel") { editor.findTask?.cancel() }.buttonStyle(.borderless).font(.system(size: 13))
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
            Button("Find Clips…") { editor.requestFindClips(from: .sidebar) }.controlSize(.small)
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
            SidebarAction(title: "New Clip from Selection", symbol: "plus", hint: "⌘K", enabled: !editor.selectedIDs.isEmpty, reason: untranscribed) { editor.makeClip() }
            SidebarAction(title: "Find Clips with AI", symbol: "sparkles", hint: "⇧⌘K", enabled: !editor.words.isEmpty && !editor.finding, reason: untranscribed) { editor.requestFindClips(from: .sidebar) }
                .popover(isPresented: Binding(get: { editor.showFindClips && editor.findClipsAnchor == .sidebar }, set: { if !$0 { editor.showFindClips = false } }), arrowEdge: .trailing) {
                    FindClipsPopover(model: editor)
                }
            if editor.showAISetup {
                SidebarCallout {
                    Text("Choose how VoxClip finds clips: your API key, a model on this computer, or an installed CLI.")
                    Button("Set Up AI…") { openVoxClipSettings(pane: "ai") }.controlSize(.small)
                    Text("You can also select words and press ⌘K to make a clip yourself.").font(.system(size: 11)).foregroundStyle(DesignValues.color("text.secondary"))
                }
            } else if let error = editor.clipError, error != EditorModel.noClipsMatched, !editor.finding {
                SidebarCallout {
                    Text(error)
                    Button("Retry") { editor.findClips() }.controlSize(.small)
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
            .background(DesignValues.color("status.infoBackground"), in: .rect(cornerRadius: VCTokens.radiusPane))
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
            Section("Recent") {
                ForEach(urls, id: \.self) { url in
                    RecentRow(url: url, item: recents.items[url], sources: recents.sources(url, row: true), status: recents.status(url), shell: shell, emphasized: shell.selection == .recent(url) && listFocused)
                        .tag(SidebarItem.recent(url))
                }
            }
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
            .frame(height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(SidebarRowForeground(emphasized: emphasized))
        .accessibilityLabel(status.spokenState.map { "\(title), \($0)" } ?? title)
    }
}

/// A row's thumbnail (design §3.4 and §5.4): the scope's first kept frame and its
/// caption card at sidebar size (no plates), between which VoxClipCore's precedence
/// picks. It regenerates when the scope's card, the caption style or the media changes.
@MainActor private struct SidebarThumbnail: View {
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
        let size = clip == nil ? CGSize(width: 36, height: 20) : CGSize(width: 26, height: 46)
        let scope: CaptionCardScope = clip.map { .clip($0.id) } ?? .fullTake
        let project = editor.project
        let key = Key(text: editor.cardText(scope, wordsVisible: app.bool("general.showPlaceholderWords", fallback: true)), styleId: app.cardStyle(for: project)?.id ?? "",
                      overrides: (try? String(decoding: JSONEncoder().encode(project.captions.overrides), as: UTF8.self)) ?? "",
                      frameTime: editor.firstKeptTime(clip), source: editor.sourceURL.path,
                      ready: editor.mediaResolved && !editor.mediaUnreadable && !editor.document.demo && project.media.source.video != nil)
        MediaThumbnail(status: status, sources: StandInSources(frame: frame, card: drawn, styleId: key.styleId, cardImage: card), surface: .row, cornerRadius: VCTokens.radiusXs)
            .frame(width: size.width, height: size.height)
            .overlay {
                if emphasized { RoundedRectangle(cornerRadius: VCTokens.radiusXs).strokeBorder(Color(nsColor: .alternateSelectedControlTextColor).opacity(0.55), lineWidth: 1) }
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
            let captionY = style.aspects?.portrait?.y ?? style.position.y
            image = await app.captions.card(CaptionCardInput(text: key.text, style: style, previewBackground: app.previewBackgrounds[style.id], overrides: project.captions.overrides,
                                                             language: project.transcript?.language, fit: clip == nil ? .row() : .clip(captionY: captionY)))
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

@MainActor private struct SidebarRowForeground: ViewModifier {
    let emphasized: Bool
    @Environment(\.controlActiveState) private var activeState

    func body(content: Content) -> some View {
        content.foregroundStyle(emphasized && activeState == .key ? Color(nsColor: .alternateSelectedControlTextColor) : DesignValues.color("text.primary"))
    }
}

@MainActor enum SidebarStyle {
    /// Meta text: text.secondary, or the selected-text colour in a focused selected row.
    /// It is full strength, not the delta's 88%, so 11 pt meta reads at 4.5:1 on the
    /// dark accent selection.
    static func meta(_ emphasized: Bool) -> Color {
        emphasized ? Color(nsColor: .alternateSelectedControlTextColor) : DesignValues.color("text.secondary")
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
/// The sidebar's rows outside the native List, for captures while the window server
/// can't draw the List (a locked session): layout, badges, thumbnails and meta. The
/// first clip shows the focused selection: accent fill and increased prominence.
@MainActor struct SidebarRowsPreview: View {
    let shell: WorkspaceShell
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let editor = shell.editor {
                Text(shell.projectTitle).font(.system(size: 11, weight: .semibold)).foregroundStyle(DesignValues.color("text.secondary"))
                FullTakeRow(editor: editor)
                if editor.sortedClips.isEmpty && !editor.finding && editor.clipError != EditorModel.noClipsMatched && !editor.words.isEmpty {
                    Text("No clips yet. Select words and press ⌘K.").font(.system(size: 11)).foregroundStyle(DesignValues.color("text.secondary"))
                }
                ForEach(Array(editor.keptClips.enumerated()), id: \.element.id) { index, clip in
                    if index == 0 {
                        ClipRow(shell: shell, editor: editor, clip: clip, suggested: false)
                            .padding(.horizontal, 6).background(.tint, in: .rect(cornerRadius: 10))
                            .foregroundStyle(Color(nsColor: .alternateSelectedControlTextColor))
                            .environment(\.backgroundProminence, .increased)
                    } else {
                        ClipRow(shell: shell, editor: editor, clip: clip, suggested: false).padding(.horizontal, 6)
                    }
                }
                if !editor.suggestedClips.isEmpty || editor.finding || editor.clipError == EditorModel.noClipsMatched {
                    SuggestedHeader(editor: editor, keepAll: !editor.suggestedClips.isEmpty).padding(.horizontal, 6)
                    if let note = editor.fallbackNote, !editor.suggestedClips.isEmpty { FallbackNote(note: note).padding(.horizontal, 6) }
                    if editor.finding { FindingRow(editor: editor).padding(.horizontal, 6) }
                    if editor.clipError == EditorModel.noClipsMatched { NoMatchRow(editor: editor).padding(.horizontal, 6) }
                    ForEach(editor.suggestedClips, id: \.id) { clip in
                        ClipRow(shell: shell, editor: editor, clip: clip, suggested: true, focused: editor.focusedSuggestion == clip.id).padding(.horizontal, 6)
                    }
                }
                SidebarActions(editor: editor).padding(.horizontal, 6)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(width: 252, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(DesignValues.color("bg.sunken"))
    }
}
#endif
