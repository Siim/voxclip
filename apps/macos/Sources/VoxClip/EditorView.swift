import SwiftUI
import VoxClipCore

struct EditorFocusKey: FocusedValueKey { typealias Value = EditorModel }
extension FocusedValues { var editor: EditorModel? { get { self[EditorFocusKey.self] } set { self[EditorFocusKey.self] = newValue } } }

@MainActor public struct EditorView: View {
    @ObservedObject private var document: VoxClipDocument
    @State private var model: EditorModel
    @Environment(\.undoManager) private var undoManager
    @Environment(\.openDocument) private var openDocument
    @Environment(\.newDocument) private var newDocument

    init(document: VoxClipDocument, app: AppModel) {
        self.document = document
        var preview: (any PreviewEngine)?
        #if DEBUG
        if document.demo { preview = DemoPreviewEngine() }
        #endif
        _model = State(initialValue: EditorModel(document: document, app: app, preview: preview))
    }
    init(model: EditorModel) { document = model.document; _model = State(initialValue: model) }

    public var body: some View {
        NavigationSplitView(columnVisibility: $model.sidebarVisibility) {
            List(selection: $model.location) {
                Section("Library") {
                    Label("Home", systemImage: "house").tag(WorkspaceLocation.home)
                }
                if !model.isHome {
                    Section(model.project.title ?? "Project") {
                        Label("Transcript", systemImage: "text.alignleft").tag(WorkspaceLocation.transcript)
                        Label("Clips", systemImage: "film.stack").tag(WorkspaceLocation.clips)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 160, ideal: 190, max: 220)
            .accessibilityLabel("Workspace navigation")
        } detail: {
            if model.isHome || model.location == .home {
                HomeView(model: model)
            } else {
                GeometryReader { geometry in
                    VStack(spacing: 0) {
                        if geometry.size.width < 760 {
                            if model.location == .clips {
                                WorkspaceMainColumn(model: model)
                                Divider()
                                PreviewColumn(model: model, compact: true).frame(height: max(230, min(280, geometry.size.height * 0.4)))
                            } else {
                                PreviewColumn(model: model, compact: true).frame(height: min(220, geometry.size.height * 0.34))
                                Divider()
                                WorkspaceMainColumn(model: model)
                            }
                        } else {
                            EditorSplitView(model: model)
                        }
                        Divider()
                        TimelineStrip(model: model).frame(height: DesignValues.dimension("size.timelineHeight", fallback: 56))
                    }
                }
            }
        }
        .inspector(isPresented: $model.showInspector) {
            InspectorView(model: model).inspectorColumnWidth(min: 260, ideal: 300, max: 380)
        }
        .navigationTitle(model.isHome || model.location == .home ? "Home" : document.project.title ?? "Untitled")
        .navigationSubtitle(model.isHome || model.location == .home ? "" : model.subtitle)
        .toolbar { EditorToolbar(model: model, hasMedia: !model.isHome) }
        .focusedSceneValue(\.editor, model)
        .background(EditorWindowSetup(model: model))
        .preferredColorScheme(model.app.appearance)
        .sheet(isPresented: $model.showExport) { ExportSheet(model: model) }
        .sheet(isPresented: $model.showTranscribe) { TranscriptionSheet(model: model) }
        .sheet(isPresented: $model.showShortcuts) { ShortcutsView() }
        .sheet(isPresented: Binding(get: { model.app.showTour }, set: { model.app.showTour = $0 })) { OnboardingView() }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            openFile(url, app: model.app, open: openDocument, create: newDocument)
            return true
        }
        .task { model.undoManager = undoManager; await model.start() }
        .onDisappear { model.close() }
        .onChange(of: model.app.pauseBreathRevision) { _, _ in
            guard model.app.settingsLoaded else { return }
            let value = model.app.string("editing.pauseBreath", fallback: "natural")
            model.apply(.setPauseKeep(seconds: value == "tight" ? 0.05 : value == "relaxed" ? 0.3 : 0.15), name: "Change pause breath")
        }
        .frame(minWidth: 800, minHeight: 560)
    }
}

@MainActor private struct EditorToolbar: ToolbarContent {
    let model: EditorModel
    let hasMedia: Bool

    var body: some ToolbarContent {
        if hasMedia {
            ToolbarItemGroup(placement: .principal) {
                Button("Find Clips", systemImage: "film.stack") { model.location = .clips }
                    .labelStyle(.titleAndIcon)
                    .help("Find and manage clips · ⌘3")
            }
            EditorPlayToolbar(model: model)
            ToolbarSpacer(.flexible)
            EditorExportToolbar(model: model)
            ToolbarItem {
                Button("Captions", systemImage: "textformat") { model.showInspector.toggle() }
                    .help("Caption styles · ⌥⌘I")
            }
        }
    }
}

@MainActor private struct EditorPlayToolbar: ToolbarContent {
    let model: EditorModel

    var body: some ToolbarContent {
        #if compiler(>=6.4)
        if #available(macOS 26.1, *) {
            ToolbarItem { EditorPlayButton(model: model) }.visibilityPriority(.high)
        } else {
            ToolbarItem { EditorPlayButton(model: model) }
        }
        #else
        ToolbarItem { EditorPlayButton(model: model) }
        #endif
    }
}

@MainActor private struct EditorPlayButton: View {
    let model: EditorModel

    var body: some View {
        Button { model.transport(" ") } label: {
            Label(timecode(model.playhead), systemImage: model.isPlaying ? "pause.fill" : "play.fill")
                .labelStyle(.titleAndIcon)
                .font(DesignValues.mono())
        }
        .help("Play or pause · Space")
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

@MainActor private struct EditorExportButton: View {
    let model: EditorModel

    var body: some View {
        EditorExportControl(title: "Export…") { model.presentExport() }
            .disabled(!model.canExport)
            .help(model.canExport ? "Choose full video or clips to export · ⌘E" : "Keep at least one word before exporting.")
    }
}

@MainActor struct EditorExportControl: NSViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    let title: String
    let action: () -> Void
    init(title: String = "Export…", action: @escaping () -> Void) { self.title = title; self.action = action }
    func makeNSView(context: Context) -> ExportToolbarButton {
        let button = ExportToolbarButton(title: "Export…", target: nil, action: nil)
        button.setButtonType(.momentaryPushIn)
        button.bezelStyle = .glass
        button.tintProminence = .primary
        button.bezelColor = DesignValues.nsColor("accent.default")
        button.target = button
        button.action = #selector(ExportToolbarButton.invoke)
        return button
    }
    func updateNSView(_ button: ExportToolbarButton, context: Context) {
        button.isEnabled = isEnabled
        button.exportTitle = title
        button.handler = action
        button.needsDisplay = true
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ExportToolbarButton, context: Context) -> CGSize? {
        CGSize(width: max(86, nsView.intrinsicContentSize.width), height: nsView.intrinsicContentSize.height)
    }
}

@MainActor final class ExportToolbarButton: NSButton {
    #if DEBUG
    static var offscreenActive: Bool?
    #endif
    var handler: () -> Void = {}
    var exportTitle = "Export…"
    @objc func invoke() { handler() }
    override func draw(_ dirtyRect: NSRect) {
        var active = NSApp.isActive
        #if DEBUG
        if AppModel.isTestSession, let override = Self.offscreenActive { active = override }
        #endif
        let tinted = isEnabled && window?.isKeyWindow == true && active
        if tinted {
            DesignValues.nsColor("accent.default").setFill()
            NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        }
        let color = isEnabled ? DesignValues.nsColor(tinted ? "accent.on" : "text.primary") : NSColor.disabledControlTextColor
        let title = NSAttributedString(string: exportTitle, attributes: [.foregroundColor: color, .font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)])
        if !attributedTitle.isEqual(to: title) { attributedTitle = title }
        super.draw(dirtyRect)
    }
}

@MainActor private struct EditorSplitView: NSViewControllerRepresentable {
    let model: EditorModel
    func makeNSViewController(context: Context) -> NSSplitViewController {
        let controller = NSSplitViewController()
        controller.splitView.isVertical = true
        controller.splitView.dividerStyle = .thin
        controller.splitView.identifier = NSUserInterfaceItemIdentifier("voxclip.editor.split")
        if !AppModel.isTestSession { controller.splitView.autosaveName = "VoxClip.editor.\(model.project.id)" }
        let transcript = NSHostingController(rootView: WorkspaceMainColumn(model: model).frame(maxWidth: .infinity, maxHeight: .infinity))
        let preview = NSHostingController(rootView: PreviewColumn(model: model).frame(maxWidth: .infinity, maxHeight: .infinity))
        transcript.sizingOptions = []; preview.sizingOptions = []
        transcript.view.setFrameSize(NSSize(width: 580, height: 680))
        preview.view.setFrameSize(NSSize(width: 380, height: 680))
        let transcriptItem = NSSplitViewItem(viewController: transcript)
        transcriptItem.minimumThickness = 440
        transcriptItem.holdingPriority = .defaultLow
        let previewItem = NSSplitViewItem(viewController: preview)
        previewItem.minimumThickness = 300
        previewItem.maximumThickness = 560
        previewItem.holdingPriority = .defaultHigh
        controller.addSplitViewItem(transcriptItem)
        controller.addSplitViewItem(previewItem)
        return controller
    }
    func updateNSViewController(_ controller: NSSplitViewController, context: Context) {}
    func sizeThatFits(_ proposal: ProposedViewSize, nsViewController: NSSplitViewController, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 960, height: proposal.height ?? 680)
    }
}

@MainActor private struct EditorWindowSetup: NSViewRepresentable {
    let model: EditorModel
    func makeNSView(context: Context) -> SetupView { SetupView(model: model) }
    func updateNSView(_ view: SetupView, context: Context) {
        if let window = view.window, let native = window.windowController?.document { window.isDocumentEdited = native.isDocumentEdited }
    }
    final class SetupView: NSView {
        weak var model: EditorModel?
        var configured = false
        var editedStateTimer: Timer?
        init(model: EditorModel) { self.model = model; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil {
                editedStateTimer?.invalidate(); editedStateTimer = nil
                NotificationCenter.default.removeObserver(self)
                configured = false
            }
            super.viewWillMove(toWindow: newWindow)
        }
        override func viewDidMoveToWindow() {
            guard let window, !configured else { return }
            configured = true
            NotificationCenter.default.addObserver(self, selector: #selector(windowResized), name: NSWindow.didResizeNotification, object: window)
            // DocumentGroup's controller does not always mirror the edited bit after an asynchronous save.
            editedStateTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.syncEditedState() }
            }
            Task { @MainActor [weak self, weak window] in
                guard let self, let window, let model else { return }
                model.window = window
                model.windowWidth = window.frame.width
                if model.isHome { model.app.activeHome = model }
                @MainActor func focus(_ view: NSView) -> NSTextView? {
                    if let text = view as? TranscriptNSTextView { return text }
                    for child in view.subviews { if let text = focus(child) { return text } }
                    return nil
                }
                if model.location == .transcript, let root = window.contentView, let transcript = focus(root) { window.makeFirstResponder(transcript) }
            }
            NotificationCenter.default.addObserver(self, selector: #selector(windowBecameKey), name: NSWindow.didBecomeKeyNotification, object: window)
        }
        @objc private func windowBecameKey() {
            guard let model else { return }
            model.app.activeHome = model.isHome ? model : nil
            syncEditedState()
        }
        @objc private func syncEditedState() {
            guard let window, let native = window.windowController?.document else { return }
            if window.isDocumentEdited != native.isDocumentEdited { window.isDocumentEdited = native.isDocumentEdited }
        }
        @objc private func windowResized() {
            guard let width = window?.frame.width, let model, abs(width - model.windowWidth) > 1 else { return }
            model.windowWidth = width
        }
    }
}

@MainActor private struct WorkspaceMainColumn: View {
    let model: EditorModel
    var body: some View {
        if model.location == .clips { ClipsInspector(model: model) }
        else { TranscriptColumn(model: model) }
    }
}

@MainActor private struct TranscriptColumn: View {
    @Bindable var model: EditorModel
    @FocusState private var findFocused: Bool
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Transcript").font(.headline)
                Spacer()
                Button("Make Clip from Selection") { model.makeClip() }.disabled(model.selectedIDs.isEmpty)
                    .help("Select words, then make a clip · ⌘K")
                Menu("Edit Cuts", systemImage: "scissors") {
                    Button("Cut Fillers") { model.apply(.cutFillers, name: "Cut fillers") }.disabled(!model.summary.canCutFillers)
                    Button("Tighten Pauses") { model.apply(.tightenPauses, name: "Tighten pauses") }.disabled(!model.summary.canTighten)
                    Button("Restore All Cuts") { model.apply(.restoreCuts, name: "Restore cuts") }.disabled(!model.summary.hasEdits)
                }.menuStyle(.borderlessButton)
                Button("Find", systemImage: "magnifyingglass") { model.findVisible = true; findFocused = true }
                    .labelStyle(.iconOnly).help("Find in transcript · ⌘F")
            }.padding(20)
            if model.document.demo { Text("Demo fixture · synthetic preview · no media is exported").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.bottom, 12) }
            if model.findVisible {
                HStack {
                    TextField("Find in transcript", text: $model.query).focused($findFocused).onSubmit { model.findNext() }
                    Button("Previous", systemImage: "chevron.up") { model.findNext(backward: true) }.labelStyle(.iconOnly)
                    Button("Next", systemImage: "chevron.down") { model.findNext() }.labelStyle(.iconOnly)
                    Button("Cut all \(model.words.filter { model.text($0).localizedCaseInsensitiveContains(model.query) }.count)") { model.cutMatches() }.disabled(model.query.isEmpty)
                    Button("Close find", systemImage: "xmark") { model.findVisible = false }.labelStyle(.iconOnly)
                }.padding(.horizontal, 20).padding(.bottom, 12)
            }
            if let error = model.error, !error.isEmpty { InlineNotice(text: error) }
            if let progress = model.progress {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(0..<6) { line in RoundedRectangle(cornerRadius: 4).fill(DesignValues.color("bg.muted")).frame(width: line.isMultiple(of: 2) ? 300 : 240, height: 12) }
                    Text(progress)
                    Button("Cancel") { model.workTask?.cancel(); model.progress = nil }
                }.padding(40)
                Spacer()
            } else if model.project.transcript == nil {
                ContentUnavailableView { Label("This video isn't transcribed yet.", systemImage: "text.alignleft") }
                    description: { Text("Your video is still here. Transcribe it to cut by words.") }
                    actions: { Button("Transcribe…") { model.showTranscribe = true }; SettingsLink { Text("Models and keys…") } }
            } else { TranscriptTextView(model: model).accessibilityLabel("Transcript, edit by words") }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(DesignValues.color("bg.surface"))
        .scrollEdgeEffectStyle(.automatic, for: .vertical)
    }
}
