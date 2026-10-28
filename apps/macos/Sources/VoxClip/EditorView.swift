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

/// The main window's content (ADR-R29): the sidebar, then Home or the open
/// project's editor. The shell owns the editor; this view only presents it.
@MainActor struct WorkspaceView: View {
    @Bindable var shell: WorkspaceShell

    var body: some View {
        sheets(on: split)
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first else { return false }
                openFile(url, app: shell.app)
                return true
            } isTargeted: { shell.dropTargeted = $0 }
            .overlay { if shell.dropTargeted { DropOverlay(savedFirst: shell.isHome ? nil : shell.projectTitle) } }
            .onChange(of: shell.app.pauseBreathRevision) { _, _ in applyPauseBreath() }
            .frame(minWidth: 640, minHeight: 480)
            .onGeometryChange(for: Double.self) { $0.size.width } action: { shell.windowWidth = $0 }
            .onChange(of: subtitleDetail, initial: true) { _, detail in
                guard !detail.subtitle.isEmpty, let window = shell.windowController?.window else { return }
                // The titlebar draws the new subtitle a moment later.
                Task { @MainActor in
                    for _ in 0..<20 where !describeSubtitle(in: window, detail: detail) { try? await Task.sleep(for: .milliseconds(30)) }
                }
            }
    }
    /// The sidebar and the detail column, with the window's title, subtitle and toolbar.
    private var split: some View {
        NavigationSplitView(columnVisibility: $shell.columnVisibility) {
            WorkspaceSidebar(shell: shell)
        } detail: {
            detailColumn
        }
        .navigationTitle(shell.title)
        .navigationSubtitle(windowSubtitle)
        .toolbar { if !shell.showsHome, let editor = shell.editor { EditorToolbar(model: editor, shell: shell) } }
        .preferredColorScheme(shell.app.appearance)
    }
    private var windowSubtitle: String {
        guard !shell.showsHome, let editor = shell.editor else { return "" }
        return editor.subtitle
    }
    /// Export, Transcribe Again, Keyboard Shortcuts and the tour.
    private func sheets(on content: some View) -> some View {
        content
            .sheet(isPresented: editorFlag(\.showExport)) { if let editor = shell.editor { ExportSheet(model: editor) } }
            .sheet(isPresented: editorFlag(\.showTranscribe)) { if let editor = shell.editor { TranscriptionSheet(model: editor) } }
            .sheet(isPresented: editorFlag(\.showVoiceLabOptIn)) {
                if let editor = shell.editor { VoiceLabOptInView(editor: editor) }
            }
            .sheet(isPresented: $shell.showShortcuts) { ShortcutsView() }
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
    /// Home or the editor. Below 960 the sidebar shows over it on request (design §3.7).
    private var detailColumn: some View {
        Group {
            if shell.showsHome {
                HomeView(shell: shell)
            } else if let editor = shell.editor {
                // A new project gets new AppKit hosts bound to its own editor.
                EditorDetail(model: editor, shell: shell).id(ObjectIdentifier(editor))
            }
        }
        .overlay(alignment: .leading) { if shell.sidebarOverlay { SidebarOverlay(shell: shell) } }
    }
    /// The edit summary's detail for the subtitle's accessibility help, with the
    /// subtitle it belongs to (design §3.5, lead decision 3).
    private var subtitleDetail: SubtitleDetail {
        guard !shell.showsHome, let editor = shell.editor else { return SubtitleDetail(subtitle: "", detail: "") }
        return SubtitleDetail(subtitle: editor.subtitle, detail: editor.summaryDetail)
    }
    /// A sheet or panel flag on the open editor; false while no project is open.
    private func editorFlag(_ flag: ReferenceWritableKeyPath<EditorModel, Bool>) -> Binding<Bool> {
        Binding(get: { shell.editor?[keyPath: flag] ?? false }, set: { shell.editor?[keyPath: flag] = $0 })
    }
}

struct SubtitleDetail: Equatable {
    let subtitle: String
    let detail: String
}

/// Gives the window subtitle the edit summary's detail ("{source} source · {w} words cut
/// in {r} places · {p} pauses cut") for VoiceOver, which reads it after the subtitle.
/// There is no tooltip (lead decision 3). AppKit draws the subtitle in a titlebar text
/// field, found by its text; a text field always reports its text as its accessibility
/// value, so the detail is its accessibility help. Returns false when there is none.
@MainActor @discardableResult func describeSubtitle(in window: NSWindow?, detail: SubtitleDetail) -> Bool {
    guard let window, !detail.subtitle.isEmpty, window.subtitle == detail.subtitle, let frame = window.contentView?.superview else { return false }
    @MainActor func field(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.stringValue == detail.subtitle { return field }
        for child in view.subviews { if let found = field(in: child) { return found } }
        return nil
    }
    guard let subtitle = frame.subviews.lazy.filter({ $0 !== window.contentView }).compactMap(field(in:)).first else { return false }
    subtitle.setAccessibilityHelp(detail.detail)
    return true
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

/// The editor detail (design §3.2): the transcript and the right column, then the
/// 72-high timeline strip. With the viewer collapsed the strip carries the compact
/// transport (§5.3).
@MainActor private struct EditorDetail: View {
    let model: EditorModel
    let shell: WorkspaceShell
    var body: some View {
        VStack(spacing: 0) {
            EditorSplitView(model: model, shell: shell, viewerVisible: shell.viewerVisible)
            Divider()
            TimelineStrip(model: model, compactTransport: !shell.viewerVisible).frame(height: VCTokens.sizeTimelineHeight)
                .modifier(EditorPaneFocus(model: model, pane: .timeline))
        }
        .background(TranscriptFocusOnShow(model: model))
    }
}

/// The transcript takes keyboard focus when the editor shows (design: "The transcript
/// … gets keyboard focus by default"): always when a project opens or imports, and when
/// the selection leaves Home unless the user is moving through the sidebar's rows. Its
/// view arrives in the window a pass or two after this one, or once transcription ends.
@MainActor private struct TranscriptFocusOnShow: NSViewRepresentable {
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

/// The editor toolbar (design §3.5). The title and edit summary lead; the trailing
/// cluster is the edit commands in one capsule, Find Clips, Export and the viewer
/// toggle. There is no Play. Below a 1100 window width the capsule is icon-only.
@MainActor private struct EditorToolbar: ToolbarContent {
    @Bindable var model: EditorModel
    let shell: WorkspaceShell

    var body: some ToolbarContent {
        let compact = shell.windowWidth < 1100
        ToolbarItemGroup {
            EditCommandButton(title: "Cut Fillers", symbol: "scissors", shortcut: "⌥⌘U", count: model.summary.fillerCount, compact: compact) {
                model.apply(.cutFillers, name: "Cut fillers")
            }.disabled(!model.capabilities.edit || !model.summary.canCutFillers)
                .modifier(EditorPaneFocus(model: model, pane: .toolbar))
            EditCommandButton(title: "Tighten Pauses", symbol: "arrow.right.and.line.vertical.and.arrow.left", shortcut: "⌥⌘P", compact: compact) {
                model.apply(.tightenPauses, name: "Tighten pauses")
            }.disabled(!model.capabilities.edit || !model.summary.canTighten)
            EditCommandButton(title: "Restore Cuts", symbol: "arrow.uturn.backward", shortcut: "⌥⌘R", compact: compact) {
                model.apply(.restoreCuts, name: "Restore cuts")
            }.disabled(!model.capabilities.edit || !model.summary.hasEdits)
        }
        ToolbarSpacer(.fixed)
        ToolbarItem {
            Button("Find Clips", systemImage: "sparkles") { model.requestFindClips(from: .toolbar) }
                .labelStyle(.titleAndIcon)
                .help("Find Clips (⇧⌘K)")
                .disabled(model.words.isEmpty || !model.capabilities.ai)
                .popover(isPresented: Binding(get: { model.showFindClips && model.findClipsAnchor == .toolbar }, set: { if !$0 { model.showFindClips = false } }), arrowEdge: .bottom) {
                    FindClipsPopover(model: model)
                }
        }
        ToolbarSpacer(.fixed)
        EditorExportToolbar(model: model)
        ToolbarSpacer(.fixed)
        ToolbarItem {
            Button(shell.viewerVisible ? "Hide Viewer" : "Show Viewer", systemImage: "sidebar.trailing") { shell.toggleViewer() }
                .help(shell.viewerVisible ? "Hide Viewer (⌥⌘I)" : "Show Viewer (⌥⌘I)")
        }
    }
}

/// One command in the toolbar's edit capsule: its symbol and title, or the symbol alone
/// when compact. Cut Fillers adds the scope's filler count in text.secondary.
@MainActor private struct EditCommandButton: View {
    let title: String
    let symbol: String
    let shortcut: String
    var count: Int?
    let compact: Bool
    let action: () -> Void

    var body: some View {
        let count = self.count.flatMap { $0 > 0 ? $0 : nil }
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                if !compact { Text(title) }
                if let count { Text("\(count)").font(DesignValues.mono(11)).foregroundStyle(DesignValues.color("text.secondary")) }
            }
        }
        .help("\(title) (\(shortcut))")
        .accessibilityLabel(count.map { "\(title), \($0)" } ?? title)
    }
}

@MainActor private struct EditorExportToolbar: ToolbarContent {
    let model: EditorModel

    var body: some ToolbarContent {
        #if compiler(>=6.4)
        if #available(macOS 26.1, *) {
            ToolbarItem(placement: .primaryAction) { EditorExportButton(model: model) }.visibilityPriority(.high)
        } else {
            ToolbarItem(placement: .primaryAction) { EditorExportButton(model: model) }
        }
        #else
        ToolbarItem(placement: .primaryAction) { EditorExportButton(model: model) }
        #endif
    }
}

/// Export Video… or Export Clip… (⌘E). Unavailable for a demo, a missing or unreadable
/// video, a selected suggestion or a scope with every word cut; the reason is its
/// tooltip and accessible description (design §3.5 and §5.4.4).
@MainActor private struct EditorExportButton: View {
    let model: EditorModel

    var body: some View {
        // Its title and reasons come from the project, which views can't observe.
        let _ = model.projectRevision
        let reason = model.exportUnavailable
        EditorExportControl(title: model.exportTitle, help: reason ?? "\(model.exportTitle) (⌘E)", reason: reason) { model.presentExport() }
            .disabled(reason != nil || !model.canExport)
    }
}

/// Export stays a painted accent capsule (see CONTRACTS.md, step 8). Offscreen renders of
/// the standard .glassProminent and .borderedProminent toolbar styles never put the label
/// on the accent (no glass material, and the test app is never active), and their dark
/// labels measured 1.23:1 and 4.37:1; the on-screen check in key and inactive windows
/// could not run in round 1. The button is borderless on the toolbar's own glass platter,
/// so no glass bezel covers the painted fill, and there is no glass on glass. The fill
/// and label use the appearance-specific Ink pair (ADR-R31).
/// DebugToolbarPixels holds the label to 4.5:1 in key and inactive windows.
@MainActor struct EditorExportControl: NSViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    let title: String
    var help = ""
    var reason: String?
    let action: () -> Void
    init(title: String = "Export Video…", help: String = "", reason: String? = nil, action: @escaping () -> Void) {
        self.title = title; self.help = help; self.reason = reason; self.action = action
    }
    func makeNSView(context: Context) -> ExportToolbarButton {
        let button = ExportToolbarButton(title: title, target: nil, action: nil)
        button.setButtonType(.momentaryPushIn)
        button.isBordered = false
        button.target = button
        button.action = #selector(ExportToolbarButton.invoke)
        return button
    }
    func updateNSView(_ button: ExportToolbarButton, context: Context) {
        button.isEnabled = isEnabled
        // The title is also the button's accessible name, so it follows the scope.
        button.title = title
        button.setAccessibilityLabel(title)
        button.exportTitle = title
        button.handler = action
        button.toolTip = help.isEmpty ? nil : help
        button.setAccessibilityHelp(reason)
        button.needsDisplay = true
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ExportToolbarButton, context: Context) -> CGSize? {
        let glass = NSButton(title: title, target: nil, action: nil)
        glass.bezelStyle = .glass
        glass.controlSize = nsView.controlSize
        return CGSize(width: max(86, glass.intrinsicContentSize.width), height: glass.intrinsicContentSize.height)
    }
}

@MainActor final class ExportToolbarButton: NSButton {
    static func colors(for appearance: NSAppearance) -> (fill: NSColor, label: NSColor) {
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return (DesignValues.nsColor(dark ? "accent.text" : "accent.default"),
                DesignValues.nsColor(dark ? "word.playingForeground" : "accent.on"))
    }
    #if DEBUG
    static var offscreenActive: Bool?
    #endif
    var handler: () -> Void = {}
    var exportTitle = "Export Video…"
    @objc func invoke() { handler() }
    /// The fill follows the window's key state and the app's active state, which change
    /// without SwiftUI updating the button, so those changes redraw it.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        guard let window else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(redrawForState), name: name, object: window)
        }
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(redrawForState), name: name, object: NSApp)
        }
    }
    @objc private func redrawForState() { needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        var active = NSApp.isActive
        #if DEBUG
        if AppModel.isTestSession, let override = Self.offscreenActive { active = override }
        #endif
        let tinted = isEnabled && window?.isKeyWindow == true && active
        let palette = Self.colors(for: effectiveAppearance)
        if tinted {
            palette.fill.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        }
        let color = isEnabled ? (tinted ? palette.label : DesignValues.nsColor("text.primary")) : NSColor.disabledControlTextColor
        let title = NSAttributedString(string: exportTitle, attributes: [.foregroundColor: color, .font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)])
        if !attributedTitle.isEqual(to: title) { attributedTitle = title }
        super.draw(dirtyRect)
    }
}

/// The transcript and the right column (design §3.2 and §3.6). The column starts at
/// the shell's right width: where the user last dragged the divider, for every project,
/// else clamp(360 − (1440 − window width) × 0.25, 300, 560). It collapses with the
/// viewer toggle and the narrow-width rule.
@MainActor private struct EditorSplitView: NSViewControllerRepresentable {
    let model: EditorModel
    let shell: WorkspaceShell
    let viewerVisible: Bool

    func makeCoordinator() -> Coordinator { Coordinator(shell: shell) }

    func makeNSViewController(context: Context) -> NSSplitViewController {
        let controller = NSSplitViewController()
        controller.splitView = EditorSplit()
        controller.splitView.isVertical = true
        controller.splitView.dividerStyle = .thin
        controller.splitView.identifier = NSUserInterfaceItemIdentifier("voxclip.editor.split")
        let transcript = NSHostingController(rootView: TranscriptColumn(model: model, shell: shell).frame(maxWidth: .infinity, maxHeight: .infinity).sceneAccent())
        let right = NSHostingController(rootView: RightColumn(model: model).frame(maxWidth: .infinity, maxHeight: .infinity).sceneAccent())
        transcript.sizingOptions = []; right.sizingOptions = []
        let thickness = shell.rightWidth
        transcript.view.setFrameSize(NSSize(width: max(WorkspaceShell.minimumTranscriptPane, shell.windowWidth - Double(VCTokens.sizeSidebarIdeal) - thickness), height: 680))
        right.view.setFrameSize(NSSize(width: thickness, height: 680))
        let transcriptItem = NSSplitViewItem(viewController: transcript)
        transcriptItem.minimumThickness = VCTokens.sizeTranscriptMinWidth
        transcriptItem.holdingPriority = .defaultLow
        let rightItem = NSSplitViewItem(viewController: right)
        rightItem.minimumThickness = VCTokens.sizeRightColumnMin
        rightItem.maximumThickness = VCTokens.sizeRightColumnMax
        rightItem.holdingPriority = .defaultHigh
        rightItem.canCollapse = true
        rightItem.isCollapsed = !viewerVisible
        controller.addSplitViewItem(transcriptItem)
        controller.addSplitViewItem(rightItem)
        context.coordinator.observe(controller)
        return controller
    }

    func updateNSViewController(_ controller: NSSplitViewController, context: Context) {
        guard controller.splitViewItems.count == 2 else { return }
        let item = controller.splitViewItems[1]
        guard item.isCollapsed == viewerVisible else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || AppModel.isTestSession { item.isCollapsed = !viewerVisible }
        else { item.animator().isCollapsed = !viewerVisible }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsViewController: NSSplitViewController, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 960, height: proposal.height ?? 680)
    }

    /// Keeps the shell's viewer state in step when the user collapses the column by
    /// dragging its divider, and remembers the width the user drags it to.
    @MainActor final class Coordinator {
        let shell: WorkspaceShell
        private var observer: NSObjectProtocol?
        init(shell: WorkspaceShell) { self.shell = shell }
        func observe(_ controller: NSSplitViewController) {
            (controller.splitView as? EditorSplit)?.onDividerDrag = { [weak self] width in self?.shell.rememberRightWidth(width) }
            observer = NotificationCenter.default.addObserver(forName: NSSplitView.didResizeSubviewsNotification, object: controller.splitView, queue: .main) { [weak self, weak controller] _ in
                MainActor.assumeIsolated {
                    guard let self, let controller, controller.splitViewItems.count == 2 else { return }
                    if controller.splitViewItems[1].isCollapsed == self.shell.viewerVisible { self.shell.toggleViewer() }
                }
            }
        }
        isolated deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    }
}

/// The editor's split view. Only a drag of its own divider reports the right column's
/// width: NSSplitView receives mouseDown only on (or beside) a divider, because its two
/// panes cover the rest, and `super.mouseDown` returns when the drag ends. Toolbar
/// toggles, window resizes and the sidebar's divider resize the panes without a
/// mouseDown here, so they never store a width.
@MainActor final class EditorSplit: NSSplitView {
    var onDividerDrag: ((Double) -> Void)?
    override func mouseDown(with event: NSEvent) {
        let before = arrangedSubviews.last?.frame.width
        super.mouseDown(with: event)
        guard let right = arrangedSubviews.last, !isSubviewCollapsed(right), abs(right.frame.width - (before ?? 0)) > 0.5 else { return }
        onDividerDrag?(right.frame.width)
    }
}

/// The right column (design §3.6): the viewer, a hairline, then Captions, which fills
/// the rest and scrolls. It sits on the window background with no card or inset.
@MainActor private struct RightColumn: View {
    @Bindable var model: EditorModel
    var body: some View {
        GeometryReader { geometry in
          VStack(spacing: 0) {
            ViewerSection(model: model, columnHeight: geometry.size.height)
                .modifier(EditorPaneFocus(model: model, pane: .viewer))
            Divider()
            Group {
                if let rewrite = model.rewrite { RewritePanel(session: rewrite) }
                else { CaptionsSection(model: model).modifier(EditorPaneFocus(model: model, pane: .panel)) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .controlSize(.small)
          }
        }
    }
}

/// Puts keyboard focus in the transcript, as when a project opens. Returns false while
/// the transcript isn't in the window yet.
@MainActor @discardableResult func focusTranscript(in window: NSWindow?) -> Bool {
    @MainActor func find(_ view: NSView) -> NSTextView? {
        if let text = view as? TranscriptNSTextView { return text }
        for child in view.subviews { if let text = find(child) { return text } }
        return nil
    }
    guard let window, let root = window.contentView, let transcript = find(root) else { return false }
    return window.firstResponder === transcript || window.makeFirstResponder(transcript)
}

@MainActor private struct TranscriptColumn: View {
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
                    Button("Previous", systemImage: "chevron.up") { model.findNext(backward: true) }.labelStyle(.iconOnly)
                    Button("Next", systemImage: "chevron.down") { model.findNext() }.labelStyle(.iconOnly)
                    Button("Cut all \(model.words.filter { model.text($0).localizedCaseInsensitiveContains(model.query) }.count)") { model.cutMatches() }.disabled(model.query.isEmpty)
                    Button("Close find", systemImage: "xmark") { model.findVisible = false }.labelStyle(.iconOnly)
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
            } else { TranscriptTextView(model: model).accessibilityLabel("Transcript, edit by words") }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(DesignValues.color("bg.surface"))
        .scrollEdgeEffectStyle(.automatic, for: .vertical)
    }
}
