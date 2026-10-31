import SwiftUI
import VoxClipCore

@MainActor struct VoiceLabOptInView: View {
    @Bindable var editor: EditorModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Turn on Voice Lab").font(.title2)
            Text("Voice Lab can clone your own voice, change your voice and re-voice a few words. Everything it makes is labelled 'AI MODIFIED' in exports, as EU law requires. It uses your ElevenLabs key and, for lip sync, your fal.ai or sync.so key.")
            HStack {
                Button("Cancel") { editor.showVoiceLabOptIn = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Turn on") { editor.enableVoiceLab() }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 460)
    }
}

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
    /// Export, Transcribe Again, Keyboard Shortcuts and the tour.
    private func sheets(on content: some View) -> some View {
        content
            .sheet(isPresented: editorFlag(\.showExport)) { if let editor = shell.editor { ExportSheet(model: editor) } }
            .sheet(isPresented: editorFlag(\.showTranscribe)) { if let editor = shell.editor { TranscriptionSheet(model: editor) } }
            .sheet(isPresented: editorFlag(\.showVoiceLabOptIn)) {
                if let editor = shell.editor { VoiceLabOptInView(editor: editor) }
            }
            .sheet(isPresented: $shell.showShortcuts) { ShortcutsView(rewriteEnabled: shell.app.voiceLabRewriteEnabled) }
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
    /// A sheet or panel flag on the open editor; false while no project is open.
    private func editorFlag(_ flag: ReferenceWritableKeyPath<EditorModel, Bool>) -> Binding<Bool> {
        Binding(get: { shell.editor?[keyPath: flag] ?? false }, set: { shell.editor?[keyPath: flag] = $0 })
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

/// The right column (design §3.6): the viewer, a hairline, then Captions, which fills
/// the rest and scrolls. It sits on the window background with no card or inset.
@MainActor struct RightColumn: View {
    @Bindable var model: EditorModel
    var body: some View {
        GeometryReader { geometry in
            RightColumnContents(model: model, columnHeight: geometry.size.height, columnWidth: geometry.size.width)
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("voxclip.editor.right")
        }
    }
}

@MainActor struct RightColumnContents: View {
    @Bindable var model: EditorModel
    var columnHeight: CGFloat
    var columnWidth: CGFloat
    var fineTune = false
    var visibleRewrite: RewriteSession? { model.app.voiceLabRewriteEnabled ? model.rewrite : nil }
    var body: some View {
        VStack(spacing: 0) {
            ViewerSection(model: model, columnHeight: columnHeight, columnWidth: columnWidth)
                .modifier(EditorPaneFocus(model: model, pane: .viewer))
            Divider()
            Group {
                if let rewrite = visibleRewrite { RewritePanel(session: rewrite) }
                else { CaptionsSection(model: model, fineTune: fineTune).modifier(EditorPaneFocus(model: model, pane: .panel)) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .controlSize(.small)
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
            if let error = model.previewError, !error.isEmpty { InlineNotice(text: error) }
            if !model.document.demo, !model.mediaResolved {
                Button("Locate…") { model.locateMedia() }
            }
            if let progress = model.progress {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(0..<6) { line in RoundedRectangle(cornerRadius: 4).fill(DesignValues.color("bg.muted")).frame(width: line.isMultiple(of: 2) ? 300 : 240, height: 12) }
                    Text(progress)
                    Button("Cancel") { model.workTask?.cancel(); model.progress = nil }
                }.padding(40)
                Spacer()
            } else if !model.transcribed {
                ContentUnavailableView { Label("This video isn't transcribed yet.", systemImage: "text.alignleft") }
                    description: { Text("Your video is still here. Transcribe it to cut by words.") }
                    actions: { Button("Transcribe…") { model.showTranscribe = true }; Button("Models and keys…") { openVoxClipSettings() } }
            } else { TranscriptTextView(model: model).accessibilityLabel("Transcript, edit by words").focusSection() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(DesignValues.color("bg.surface"))
        .scrollEdgeEffectStyle(.automatic, for: .vertical)
    }
}
