import SwiftUI
import VoxClipCore

/// Home in the main window (design §7): the drop bar, one callout when it gives a next
/// step, and every recent project as a card. On first run a hero replaces the bar.
@MainActor struct HomeView: View {
    let shell: WorkspaceShell
    @State private var sortByName = false
    @State private var readiness: ConnectorStatus?
    private var app: AppModel { shell.app }
    private static let types = "MOV, MP4, M4V"
    private static let dashedStroke = StrokeStyle(lineWidth: 1.5, dash: [6, 4])

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                notices
                if app.recent.isEmpty && shell.isHome {
                    hero
                } else {
                    dropBar
                    callouts
                    recentHeader.padding(.top, VCTokens.spacing7)
                    recentGrid.padding(.top, 10)
                }
            }
            .padding(.horizontal, VCTokens.spacing8)
            .padding(.top, VCTokens.spacing7)
            .padding(.bottom, VCTokens.spacing8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(DesignValues.color("bg.surface"))
        .searchable(text: Bindable(shell).homeQuery, placement: .toolbar, prompt: "Search projects")
        .task(id: app.recent) { app.recentProjects.refresh(app.recent) }
        .onChange(of: app.bool("general.showPlaceholderWords", fallback: true)) { app.recentProjects.refresh(app.recent) }
        .onChange(of: app.string("captions.defaultStyleId", fallback: "vox-highlight")) { app.recentProjects.refresh(app.recent) }
        .task(id: "\(app.string("llm.connector")):\(app.connectorReadinessRevision)") {
            readiness = nil
            let id = app.string("llm.connector")
            guard !id.isEmpty, !AppModel.isTestSession || app.connectorOverride != nil else { return }
            let status = await app.connector(id).status()
            guard !Task.isCancelled, id == app.string("llm.connector") else { return }
            readiness = status
        }
    }

    @ViewBuilder private var notices: some View {
        if let progress = shell.importProgress {
            HStack { ProgressView().controlSize(.small); Text(progress); Button("Cancel") { shell.cancelImport() } }.padding(.bottom, 12)
        }
        if let notice = shell.notice { InlineNotice(text: notice) }
        if let error = app.startupError { InlineNotice(text: UserMessages.message(error)) }
        if let notice = app.notice { InlineNotice(text: notice) }
    }

    private var importButtons: some View {
        HStack(spacing: VCTokens.spacing4) {
            Button("Import Video…") { chooseFile(app: app, moviesOnly: true) }
                .buttonStyle(.borderedProminent).help("Import Video (⌘O)")
            Button("Open Project…") { chooseFile(app: app, projectsOnly: true) }
                .buttonStyle(.bordered)
        }
        .controlSize(.large).buttonBorderShape(.capsule)
    }

    private var dropBar: some View {
        HStack(spacing: VCTokens.spacing4) {
            Image(systemName: "square.and.arrow.down").font(.system(size: 17)).foregroundStyle(DesignValues.color("text.secondary"))
            Text("Drop a talking-head video, or")
            importButtons
            Spacer(minLength: VCTokens.spacing4)
            Label("\(Self.types) · stays on this Mac", systemImage: "lock")
                .font(.system(size: 11)).foregroundStyle(DesignValues.color("text.secondary")).lineLimit(1)
        }
        .font(.system(size: 13))
        .padding(.leading, VCTokens.spacing6).padding(.trailing, 18)
        .frame(height: 64)
        .background(DesignValues.color("bg.sunken"), in: .rect(cornerRadius: VCTokens.radiusSheet))
        .overlay(RoundedRectangle(cornerRadius: VCTokens.radiusSheet).strokeBorder(DesignValues.color("line.strong"), style: Self.dashedStroke))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Import a video. You can also drop a video anywhere in this window.")
    }

    private var hero: some View {
        VStack(spacing: VCTokens.spacing3) {
            Image(systemName: "square.and.arrow.down").font(.system(size: 28)).foregroundStyle(DesignValues.color("text.secondary"))
            Text("Drop a talking-head video").font(.title)
            Text("VoxClip transcribes it so you can cut by words, make clips and add captions.")
                .foregroundStyle(DesignValues.color("text.secondary")).multilineTextAlignment(.center)
            importButtons.padding(.top, VCTokens.spacing3)
            Label("\(Self.types) · Media and edits stay on this Mac.", systemImage: "lock")
                .font(.system(size: 11)).foregroundStyle(DesignValues.color("text.secondary")).padding(.top, VCTokens.spacing2)
        }
        .padding(.horizontal, VCTokens.spacing7)
        .frame(maxWidth: .infinity).frame(height: 212)
        .background(DesignValues.color("bg.sunken"), in: .rect(cornerRadius: VCTokens.radiusSheet))
        .overlay(RoundedRectangle(cornerRadius: VCTokens.radiusSheet).strokeBorder(DesignValues.color("line.strong"), style: Self.dashedStroke))
    }

    @ViewBuilder private var callouts: some View {
        if let update = app.update {
            HomeCallout(text: "VoxClip \(update.version) is available.", action: "Download") { NSWorkspace.shared.open(update.htmlURL) }
                .padding(.top, VCTokens.spacing5)
        }
        if let callout = aiCallout {
            HomeCallout(text: callout.text, action: callout.action, perform: callout.perform).padding(.top, VCTokens.spacing5)
        }
    }

    /// The four readiness variants of design §7; hidden when the connector is ready.
    private var aiCallout: (text: String, action: String, perform: () -> Void)? {
        guard let provider = app.providers.first(where: { $0.id == app.string("llm.connector") }) else {
            return ("Find Clips with AI isn't set up yet. You can still make clips by hand.", "Set Up AI…", { openVoxClipSettings(pane: "ai") })
        }
        switch readiness {
        case .cliSignedOut:
            return ("\(provider.label) isn't signed in, so Find Clips with AI can't run. You can still make clips by hand.", "Sign-in Help", {
                let alert = NSAlert(); alert.messageText = "Sign in to \(provider.label)"
                alert.informativeText = provider.cli?.signInHint ?? ""
                alert.runModal()
            })
        case .needsKey:
            return ("Add your \(provider.label) key to use Find Clips with AI. You can still make clips by hand.", "Set Up AI…", { openVoxClipSettings(pane: "ai") })
        case .notRunning:
            return ("\(provider.label) isn't running, so Find Clips with AI can't run.", "Check Again", { app.refreshConnectorReadiness() })
        default:
            return nil
        }
    }

    private var recentHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Recent projects").font(.system(size: 15, weight: .semibold))
            Spacer()
            Menu {
                Picker("Sort projects", selection: $sortByName) {
                    Text("Last Opened").tag(false)
                    Text("Name").tag(true)
                }.pickerStyle(.inline).labelsHidden()
            } label: { Text(sortByName ? "Name" : "Last Opened") }
                .menuStyle(.borderlessButton).fixedSize().font(.system(size: 12))
                .tint(DesignValues.color("text.secondary"))
                .accessibilityLabel("Sort recent projects")
        }
    }

    private var shown: [URL] {
        let recents = app.recentProjects
        let urls = app.recent.filter { recents.items[$0] != nil || FileManager.default.fileExists(atPath: $0.path) }
        let named = urls.map { ($0, recents.items[$0]?.title ?? $0.deletingPathExtension().lastPathComponent) }
        let query = shell.homeQuery
        let matches = query.isEmpty ? named : named.filter { $0.1.localizedCaseInsensitiveContains(query) }
        return (sortByName ? matches.sorted { $0.1.localizedStandardCompare($1.1) == .orderedAscending } : matches).map(\.0)
    }

    @ViewBuilder private var recentGrid: some View {
        let urls = shown, recents = app.recentProjects
        if urls.isEmpty && !shell.homeQuery.isEmpty {
            Text("No projects match “\(shell.homeQuery)”.").foregroundStyle(DesignValues.color("text.secondary")).padding(.top, VCTokens.spacing3)
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 280), spacing: VCTokens.spacing5)], alignment: .leading, spacing: 18) {
                ForEach(urls, id: \.self) { url in
                    RecentCard(url: url, item: recents.items[url], sources: recents.sources(url), status: recents.status(url),
                               isOpen: shell.document?.fileURL?.standardizedFileURL == url.standardizedFileURL, shell: shell)
                }
            }
        }
    }
}

/// One informational callout row on Home (design §7, macOS).
@MainActor private struct HomeCallout: View {
    let text: String
    let action: String
    let perform: () -> Void
    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "sparkles").foregroundStyle(DesignValues.color("text.secondary"))
            Text(text).foregroundStyle(DesignValues.color("text.primary"))
            Spacer(minLength: VCTokens.spacing4)
            Button(action, action: perform)
        }
        .font(.system(size: 13))
        .padding(.leading, VCTokens.spacing4).padding(.trailing, VCTokens.spacing3)
        .frame(minHeight: 40)
        .background(DesignValues.color("status.infoBackground"), in: .rect(cornerRadius: VCTokens.radiusPane))
        .accessibilityElement(children: .contain)
    }
}

/// A recent project's card (design §7 and §5.4): its stand-in with the status and
/// duration chips, the title and a meta line. The open project reads "Open now"; a
/// missing or unreadable video offers Locate…, and a transcription offers Cancel.
@MainActor private struct RecentCard: View {
    let url: URL
    let item: RecentProject?
    let sources: StandInSources
    let status: MediaStatus
    let isOpen: Bool
    let shell: WorkspaceShell
    private var title: String { item?.title ?? url.deletingPathExtension().lastPathComponent }
    private var transcription: EditorModel? {
        guard isOpen, let editor: EditorModel = shell.editor else { return nil }
        return editor.transcriptionStatus != nil ? editor : nil
    }
    private var shownStatus: MediaStatus { transcription?.transcriptionStatus ?? status }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { Task { await shell.openProject(at: url) } } label: {
                VStack(alignment: .leading, spacing: 0) {
                    MediaThumbnail(status: shownStatus, sources: sources, unread: item == nil, duration: item?.duration)
                        .aspectRatio(16 / 9, contentMode: .fit)
                    Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        .foregroundStyle(DesignValues.color("text.primary")).padding(.top, VCTokens.spacing3)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            meta.font(.system(size: 11)).padding(.top, VCTokens.spacing1)
        }
        .contextMenu {
            Button("Open") { Task { await shell.openProject(at: url) } }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Button("Remove from List") { removeFromList() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(shownStatus.spokenState.map { "\(title), \($0)" } ?? title)
        .accessibilityHint(item.map { "\(durationLabel($0.duration)), \($0.keptClips) clips, opened \(RecentProjects.relativeDay($0.modified))" } ?? "")
    }

    @ViewBuilder private var meta: some View {
        switch shownStatus {
        case .missing: warning("Video not found.")
        case .unreadable: warning("Can't read video.")
        case .transcribing:
            HStack(spacing: 6) {
                Text("Transcribing on this Mac").foregroundStyle(DesignValues.color("text.secondary"))
                Button("Cancel") { transcription?.workTask?.cancel(); transcription?.progress = nil }
                    .buttonStyle(.link).underline().foregroundStyle(DesignValues.color("text.primary"))
            }
        case .loading: Text("Loading…").foregroundStyle(DesignValues.color("text.secondary"))
        default:
            if let item {
                let clips = item.keptClips == 0 ? "No clips yet" : item.keptClips == 1 ? "1 clip" : "\(item.keptClips) clips"
                Text("\(clips) · \(isOpen ? "Open now" : RecentProjects.relativeDay(item.modified))")
                    .foregroundStyle(DesignValues.color("text.secondary")).monospacedDigit()
            }
        }
    }

    private func warning(_ text: String) -> some View {
        HStack(spacing: 6) {
            Label(text, systemImage: "exclamationmark.triangle").labelStyle(.titleAndIcon)
            Button("Locate…") { Task { await shell.locateMedia(for: url) } }
                .buttonStyle(.link).underline()
                .accessibilityLabel("Locate the video for \(title)")
        }
        .foregroundStyle(DesignValues.color("status.warning"))
    }

    private func removeFromList() {
        let app = shell.app
        app.recent.removeAll { $0 == url }
        NSDocumentController.shared.clearRecentDocuments(nil)
        for remaining in app.recent.reversed() { NSDocumentController.shared.noteNewRecentDocumentURL(remaining) }
    }
}

@MainActor struct ShortcutsView: View {
    /// The current bindings: "keys|what they do".
    static let lines = ["Space|Play / pause", "J / K / L|Back / stop / forward", "Delete / ⇧Delete|Cut / restore selection", "Return / C|Correct spelling", "⌘Z / ⇧⌘Z|Undo / redo", "← / →|Previous / next word", "⌥← / ⌥→|Previous / next sentence", "⇧← / ⇧→|Extend selection", "⌘K|Make clip from selection", "I / O|Set clip start / end", "[ / ]|Previous / next clip", "P|Preview this cut", "⌥⌘U / ⌥⌘P / ⌥⌘R|Cut fillers / tighten / restore", "⌘F / ⌘G / ⇧⌘G|Find / next / previous", "⌘1 / ⌘2|Home / Full Take", "⇧⌘K|Find clips", "⌥⌘I|Show / hide viewer", "⌃⌘S|Show / hide sidebar", "⌘+ / ⌘− / ⌘0|Text size", "⌘E / ⌘O / ⌘,|Export / open / settings"]
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Keyboard shortcuts").font(.title2)
            Text("Select words in the transcript. Single-letter keys work in the editor, never while typing a correction or in a text field.").foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 40, verticalSpacing: 8) {
                ForEach(Self.lines, id: \.self) { line in
                    let parts = line.split(separator: "|")
                    GridRow { Text(parts[0]).font(DesignValues.mono()); Text(parts[1]) }
                }
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 580)
    }
}
