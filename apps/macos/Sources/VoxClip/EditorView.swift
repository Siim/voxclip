import SwiftUI
import VoxClipCore

/// The main window's content (ADR-R29): the v2 shell (impl-plan V1a), which shows the
/// Explorer and Home or the open project's editor, with the sheets and the whole-window
/// drop target. The shell owns the editor; this view only presents it.
@MainActor struct WorkspaceView: View {
    @Bindable var shell: WorkspaceShell

    var body: some View {
        sheets(on: content)
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first else { return false }
                openFile(url, app: shell.app)
                return true
            } isTargeted: { shell.dropTargeted = $0 }
            .overlay { if shell.dropTargeted { DropOverlay(savedFirst: shell.isHome ? nil : shell.projectTitle) } }
            .onChange(of: shell.app.pauseBreathRevision) { _, _ in applyPauseBreath() }
            .modifier(WorkspaceServiceUpdates(shell: shell))
            .frame(minWidth: 640, minHeight: 480)
            .onGeometryChange(for: Double.self) { $0.size.width } action: { shell.windowWidth = $0 }
    }
    /// The AppKit shell, and below 1,128 the Explorer over it on request (impl-plan §3.5),
    /// under the title row and above the status bar. The shell starts at the window's top
    /// edge, under the transparent titlebar: its title rows are the title bar.
    private var content: some View {
        EditorShellView(shell: shell, state: EditorShellState(shell: shell))
            .overlay(alignment: .leading) {
                if shell.sidebarOverlay {
                    SidebarOverlay(shell: shell).padding(.top, ShellMetrics.titleRow).padding(.bottom, ShellMetrics.statusBar)
                }
            }
            .ignoresSafeArea()
            .preferredColorScheme(shell.app.appearance)
    }
    private func sheets(on content: some View) -> some View {
        content
            .sheet(isPresented: Binding(get: { shell.app.showTour }, set: { shell.app.showTour = $0 })) { OnboardingView() }
    }
    /// A changed pause breath setting applies to the open project as one undo step.
    private func applyPauseBreath() {
        guard shell.app.settingsLoaded, let editor = shell.editor else { return }
        let seconds: Double
        switch shell.app.string("editing.pauseBreath", fallback: "natural") {
        case "tight": seconds = 0.05
        case "relaxed": seconds = 0.3
        default: seconds = 0.15
        }
        editor.apply(.setPauseKeep(seconds: seconds), name: "Change pause breath")
    }
}

/// Keep service observations outside the workspace's layout expression for Xcode 26.
@MainActor private struct WorkspaceServiceUpdates: ViewModifier {
    let shell: WorkspaceShell
    func body(content: Content) -> some View {
        content
            .onChange(of: shell.app.voiceLabSession.busy) { _, busy in
                if !busy { Task { await shell.app.refreshMonthlySpend() } }
            }
            .task(id: shell.app.bool("voiceLab.enabled")) { await shell.app.refreshMonthlySpend() }
            .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
                Task { await shell.app.refreshMonthlySpend() }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                Task { await shell.app.refreshMonthlySpend(); await shell.app.harnessSignIn.checkPending() }
            }
    }
}

/// The whole-window drop target (design §7): one video at a time, and the open project
/// is saved first.
@MainActor private struct DropOverlay: View {
    let savedFirst: String?
    var body: some View {
        RoundedRectangle(cornerRadius: VCTokens.radiusSheet)
            .fill(DesignValues.color("overlay.drop"))
            .overlay(RoundedRectangle(cornerRadius: VCTokens.radiusSheet).strokeBorder(DesignValues.accentText, style: StrokeStyle(lineWidth: VCTokens.strokeDropBorder, dash: [6, 4])))
            .overlay {
                VStack(spacing: VCTokens.spacing2) {
                    Image(systemName: "arrow.down.to.line").font(.system(size: 24)).foregroundStyle(DesignValues.accentText)
                    Text("Drop to transcribe").font(.system(size: 17, weight: .semibold)).foregroundStyle(DesignValues.color("text.primary"))
                    Text(savedFirst.map { "\($0) is saved first." } ?? "One video at a time · MOV, MP4, M4V")
                        .font(.system(size: 13)).foregroundStyle(DesignValues.color("text.secondary"))
                }
                .accessibilityElement(children: .combine)
            }
            .padding(VCTokens.spacing4)
            .allowsHitTesting(false)
    }
}

/// The transcript takes keyboard focus when the editor shows (design: "The transcript
/// … gets keyboard focus by default"): always when a project opens or imports, and when
/// the selection leaves Home unless the user is moving through the sidebar's rows. Its
/// view arrives in the window a pass or two after this one, or once transcription ends.
@MainActor struct TranscriptFocusOnShow: NSViewRepresentable {
    let model: EditorModel
    func makeNSView(context: Context) -> FocusView { FocusView(model: model) }
    func updateNSView(_ view: FocusView, context: Context) {}
    final class FocusView: NSView {
        private weak var model: EditorModel?
        init(model: EditorModel) { self.model = model; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, let model, model.wantsTranscriptFocus || !(window.firstResponder is NSTableView) else { return }
            // An untranscribed take keeps asking until its transcript arrives.
            model.wantsTranscriptFocus = true
            Task { @MainActor [weak self] in
                for _ in 0..<40 {
                    guard let window = self?.window, let model = self?.model, model.wantsTranscriptFocus else { return }
                    if focusTranscript(in: window) { model.wantsTranscriptFocus = false; return }
                    try? await Task.sleep(for: .milliseconds(25))
                }
            }
        }
    }
}

/// Puts keyboard focus in the transcript, as when a project opens. Returns false while
/// the transcript isn't in the window yet. It finds the text view anywhere in the
/// window's shell, under the clip-bar row (impl-plan V1b).
@MainActor @discardableResult func focusTranscript(in window: NSWindow?) -> Bool {
    @MainActor func find(_ view: NSView) -> NSTextView? {
        if let text = view as? TranscriptNSTextView, !text.isHiddenOrHasHiddenAncestor { return text }
        for child in view.subviews { if let text = find(child) { return text } }
        return nil
    }
    guard let window, let root = window.contentView, let transcript = find(root) else { return false }
    return window.firstResponder === transcript || window.makeFirstResponder(transcript)
}

@MainActor struct TranscriptColumn: View {
    @Bindable var model: EditorModel
    let shell: WorkspaceShell
    @FocusState private var findFocused: Bool
    var body: some View {
        VStack(spacing: 0) {
            // The scope bar's "Rewrite as" strip (design.md §6.3.1), always under the clip bar's field while Rewrite can run.
            if model.showsScopeToneStrip { ScopeToneStrip(model: model) }
            ConnectorConfirmationView(confirmation: model.sendConfirmation, model: model)
            if model.document.demo {
                Label { Text("Demo project with no video. ").fontWeight(.semibold) + Text("Changes aren't saved to the fixture.") } icon: { Image(systemName: "info.circle") }
                    .font(.system(size: 13)).foregroundStyle(DesignValues.color("text.primary"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).frame(minHeight: 40)
                    .background(DesignValues.color("status.infoBackground"), in: .rect(cornerRadius: VCTokens.radiusPane))
                    .padding(.horizontal, 20).padding(.top, 12)
            }
            if model.findVisible {
                HStack {
                    TextField("Find in transcript", text: $model.query).focused($findFocused).onSubmit { model.findNext() }
                    Button("Previous", systemImage: "chevron.up") { model.findNext(backward: true) }.labelStyle(.iconOnly).accessibilityLabel(EditorIconAction.previousMatch.name)
                    Button("Next", systemImage: "chevron.down") { model.findNext() }.labelStyle(.iconOnly).accessibilityLabel(EditorIconAction.nextMatch.name)
                    Button("Cut all \(model.words.filter { model.text($0).localizedCaseInsensitiveContains(model.query) }.count)") { model.cutMatches() }.disabled(model.query.isEmpty)
                    Button("Close find", systemImage: "xmark") { model.findVisible = false }.labelStyle(.iconOnly).accessibilityLabel(EditorIconAction.closeFind.name)
                }.padding(.horizontal, 20).padding(.vertical, 12)
                .onAppear { findFocused = true }
            }
            if let notice = shell.notice { InlineNotice(text: notice) }
            if let error = model.error, !error.isEmpty { InlineNotice(text: error) }
            // A preview failure over the player shows on the stage, with Reload Preview (design.md §5.4.4 g).
            if let error = model.previewError, !error.isEmpty, model.stagePreviewError == nil { InlineNotice(text: error) }
            VoiceRewriteToast(model: model)
            MediaRelinkBanner(model: model)
            if !model.document.demo, model.mediaMissing {
                Button("Locate…") { model.locateMedia() }
            }
            if model.transcription.isVisible {
                if model.transcribed { InlineTranscriptionView(transcription: model.transcription) }
                else { ScrollView { InlineTranscriptionView(transcription: model.transcription) } }
            }
            if let progress = model.progress, !model.transcription.isRunning {
                VStack(alignment: .leading, spacing: VCTokens.spacing5) {
                    ForEach(0..<6) { line in RoundedRectangle(cornerRadius: 4).fill(DesignValues.color("bg.muted")).frame(width: line.isMultiple(of: 2) ? 300 : 240, height: 12) }
                    Text(progress)
                    Button("Cancel") { model.workTask?.cancel(); model.progress = nil }
                }.padding(40)
                Spacer()
            } else if !model.transcribed {
                if !model.transcription.isVisible {
                    HStack { Text("This video isn't transcribed yet."); Button("Transcribe…") { Task { await model.transcription.open() } } }.padding(.leading, 80).padding(.top, 24)
                }
                Spacer(minLength: 0)
            } else { TranscriptTextView(model: model).accessibilityLabel("Transcript, edit by words").focusSection() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(DesignValues.color("bg.surface"))
        .scrollEdgeEffectStyle(.automatic, for: .vertical)

    }
}

/// Missing media is resolved in the work area; system file pickers are the only modal step.
@MainActor struct MediaRelinkBanner: View {
    @Bindable var model: EditorModel
    var body: some View {
        if let candidate = model.mediaRelinkCandidate {
            VStack(alignment: .leading, spacing: 6) {
                InlineNotice(text: "This file looks different. Use it anyway? \(candidate.url.lastPathComponent)")
                HStack {
                    Button("Use It") { Task { await model.confirmMediaRelink() } }.accessibilityIdentifier("voxclip.relink.use")
                    Button("Choose Another…") { model.locateMedia() }.accessibilityIdentifier("voxclip.relink.choose")
                    Button("Cancel") { model.cancelMediaRelink() }.accessibilityIdentifier("voxclip.relink.cancel")
                }.padding(.horizontal, 12)
            }.accessibilityElement(children: .contain).accessibilityLabel("Locate media confirmation")
        }
    }
}
