#if DEBUG
import AppKit
import SwiftUI
import VoxClipCore
import VoxClipMedia

@MainActor enum DebugAccessibility {
    static func run(app: AppModel, fixture: Project, directory: URL) async throws -> [DebugUISuite.Result] {
        var results: [DebugUISuite.Result] = []
        func check(_ name: String, _ passed: Bool) { results.append(.init(name: name, passed: passed)) }
        let names = EditorIconAction.allCases.map(\.name)
        let expected = ["Back 3 seconds", "Play", "Pause", "Forward 3 seconds", "Close Rewrite", "Hide Viewer", "Show Viewer", "Previous match", "Next match", "Close find",
                        "Hide Sidebar", "Show Sidebar", "Hide Timeline", "Show Timeline", "More Commands"]
        check("all shipped editor icon actions have explicit C15 names", names == expected && Set(names).count == names.count)
        for number in [1, 5, 12] {
            check("suggestion \(number) has explicit Keep and Dismiss names", EditorIconAction.suggestion(keep: true, number: number) == "Keep suggested clip \(number)" && EditorIconAction.suggestion(keep: false, number: number) == "Dismiss suggested clip \(number)")
        }
        check("F6 and Control-F6 use the same pane route", EditorPane.isCycleKey(code: 97, modifiers: []) && EditorPane.isCycleKey(code: 97, modifiers: .control) && EditorPane.isCycleKey(code: 97, modifiers: [.control, .shift]))
        check("pane route does not steal unrelated shortcuts", !EditorPane.isCycleKey(code: 48, modifiers: []) && !EditorPane.isCycleKey(code: 97, modifiers: .command) && !EditorPane.isCycleKey(code: 97, modifiers: .option))
        check("only forward Tab enters selection bar without trapping Shift-Tab", EditorPane.entersSelectionBar(code: 48, modifiers: []) && !EditorPane.entersSelectionBar(code: 48, modifiers: .shift) && !EditorPane.entersSelectionBar(code: 48, modifiers: .control) && !EditorPane.entersSelectionBar(code: 97, modifiers: .control))
        let visible: [EditorPane] = [.sidebar, .transcript, .viewer, .panel, .timeline]
        let hidden: [EditorPane] = [.sidebar, .transcript, .timeline]
        check("visible pane order matches design C15", EditorPane.order(viewerVisible: true, timelineVisible: true) == visible)
        check("collapsed viewer removes both right-column panes", EditorPane.order(viewerVisible: false, timelineVisible: true) == hidden)
        check("a hidden timeline panel is no F6 stop", EditorPane.order(viewerVisible: true, timelineVisible: false) == [.sidebar, .transcript, .viewer, .panel])
        for motion in [false, true] {
            for transparency in [false, true] {
                for contrast in [false, true] {
                    let policy = EditorAccessibilityPolicy(reduceMotion: motion, reduceTransparency: transparency, increaseContrast: contrast)
                    check("opaque selection bar transparency=\(transparency) contrast=\(contrast) motion=\(motion)", policy.opaqueSelectionBar == (transparency || contrast))
                    check("motion policy scroll/zoom/crossfade motion=\(motion) transparency=\(transparency) contrast=\(contrast)", motion ? policy.transcriptScrollDuration == 0 && policy.timelineZoomDuration == 0 && policy.crossfadeDuration == 0 : policy.crossfadeDuration <= 0.15)
                }
            }
        }
        check("caption gallery always uses resting raster frames", EditorAccessibilityPolicy.staticCaptionTiles)
        let target = ImageRenderer(content: Text("Retry").font(.system(size: 11)).modifier(SidebarActionTarget()))
        target.scale = 1
        check("sidebar label target renders at least 24 points in both axes", target.cgImage.map { $0.width >= 24 && $0.height >= 24 } == true)

        let project = try DebugSidebar.fiveQuestions(from: fixture)
        let editor = EditorModel(document: VoxClipDocument(project: project), app: app, preview: DemoPreviewEngine())
        defer { editor.close() }
        editor.mediaResolved = true; editor.refresh()
        let previousViewer = app.shell.layout.rightVisible
        defer { app.shell.layout.rightVisible = previousViewer }
        for expanded in [false, true] {
            app.shell.layout.rightVisible = expanded
            let order = expanded ? visible : hidden
            editor.focusedPane = .sidebar
            var visited: [EditorPane] = []
            for _ in order { visited.append(editor.focusedPane); editor.movePaneFocus(backward: false) }
            check("F6 model completes forward loop expanded=\(expanded)", visited == order && editor.focusedPane == .sidebar)
            var reversed: [EditorPane] = []
            for _ in order { editor.movePaneFocus(backward: true); reversed.append(editor.focusedPane) }
            check("Shift-F6 model completes backward loop expanded=\(expanded)", reversed == Array(order.reversed()) && editor.focusedPane == .sidebar)
        }
        let words = editor.words
        editor.selectedWordIDs = Set(words[3...9].map(\.id))
        let before = editor.announcements.count
        let scrollBeforeMake = editor.scopeScrollRevision
        editor.makeClip()
        check("Make Clip announces made once and preserves transcript scroll", editor.announcements.count == before + 1 && editor.lastAnnouncement?.hasSuffix(" made.") == true && editor.scopeScrollRevision == scrollBeforeMake)
        if let clip = editor.activeClip { editor.removeClip(clip.id) }
        check("Remove announces removed", editor.lastAnnouncement?.hasSuffix(" removed.") == true)
        if let suggested = editor.suggestedClips.first { editor.keep(suggested.id) }
        check("Keep announces kept", editor.lastAnnouncement?.hasSuffix(" kept.") == true)
        var extra = editor.project
        extra.edits.clips.append(ClipRange(id: "a11y-suggestion", startWordId: words[20].id, endWordId: words[70].id, origin: .ai, selected: false))
        editor.replace(extra, name: "Add suggestion fixture")
        editor.dismiss("a11y-suggestion")
        check("Dismiss announces dismissed", editor.lastAnnouncement == "Suggestion dismissed.")
        let beforeScope = editor.scopeScrollRevision
        if let clip = editor.keptClips.first(where: { $0.id != editor.activeClip?.id }) { editor.activate(clip) }
        check("sidebar scope change requests transcript jump without changing selected words", editor.scopeScrollRevision == beforeScope + 1 && editor.selectedWordIDs == Set(words[3...9].map(\.id)))

        let savedConnector = app.settings.values["llm.connector"]
        let savedModel = app.settings.values["llm.model.ollama"]
        let savedSnap = app.settings.values["llm.clips.snapToLines"]
        let savedOverride = app.connectorOverride
        defer {
            app.settings.values["llm.connector"] = savedConnector; app.settings.values["llm.model.ollama"] = savedModel
            app.settings.values["llm.clips.snapToLines"] = savedSnap; app.connectorOverride = savedOverride
        }
        app.settings.values["llm.connector"] = .string("ollama")
        app.settings.values["llm.model.ollama"] = .string("fixture-local")
        app.settings.values["llm.clips.snapToLines"] = .bool(false)
        app.connectorOverride = { _ in FixtureClipConnector(spans: [(20, 70), (95, 145), (170, 220)]) }
        editor.findClips(); await editor.findTask?.value
        check("Find Clips announces found exactly once through the real action", editor.announcements.filter { $0.hasPrefix("Found ") }.count == 1 && editor.lastAnnouncement == "Found 3 clips.")
        for contrast in [false, true] {
            let policy = EditorAccessibilityPolicy(reduceMotion: true, reduceTransparency: !contrast, increaseContrast: contrast)
            let first = barBitmap(editor, policy: policy, backdrop: .red)
            let second = barBitmap(editor, policy: policy, backdrop: .blue)
            let color = first.flatMap { $0.colorAt(x: $0.pixelsWide / 2, y: 3) }
            let other = second.flatMap { $0.colorAt(x: $0.pixelsWide / 2, y: 3) }
            check("selection bar is opaque over different backdrops contrast=\(contrast)", color != nil && color == other && color?.alphaComponent == 1)
            check("selection bar controls retain 24pt targets contrast=\(contrast)", first.map { $0.pixelsHigh >= 24 && $0.pixelsWide >= 3 * 24 } == true)
        }
        try await captures(app: app, editor: editor, directory: directory)
        return results
    }

    private static func barBitmap(_ editor: EditorModel, policy: EditorAccessibilityPolicy, backdrop: Color) -> NSBitmapImageRep? {
        let renderer = ImageRenderer(content: SelectionBar(model: editor, policyOverride: policy, dismiss: {}).background(backdrop).sceneAccent())
        renderer.scale = 1
        return renderer.cgImage.map(NSBitmapImageRep.init(cgImage:))
    }

    private static func captures(app: AppModel, editor: EditorModel, directory: URL) async throws {
        let shell = WorkspaceShell(app: app)
        let savedVoiceLab = app.settings.values["voiceLab.enabled"]
        let savedConnector = app.settings.values["llm.connector"]
        let savedConsent = app.settings.values["llm.cloudConsent.codex"]
        defer {
            app.settings.values["voiceLab.enabled"] = savedVoiceLab
            app.settings.values["llm.connector"] = savedConnector
            app.settings.values["llm.cloudConsent.codex"] = savedConsent
        }
        app.settings.values["voiceLab.enabled"] = .bool(true)
        let fake = RewriteFixtureConnector()
        let connector = RewriteConnector(connector: fake, model: "fixture-local", name: "Fixture", group: "local", plan: "")
        let envelope = AudioEnvelope(sampleRate: 48_000, levels: Array(repeating: 0.01, count: 100_000))
        var captureProject = editor.project
        captureProject.edits = ProjectEdits()
        let captureEditor = EditorModel(document: VoxClipDocument(project: captureProject), app: app, preview: DemoPreviewEngine())
        captureEditor.mediaResolved = true; captureEditor.refresh()
        let session = RewriteSession(editor: captureEditor, range: 3...9, envelope: envelope, connector: connector)
        defer { session.close(); captureEditor.close() }
        session.setInstruction("Make this clearer")
        session.edit("Here is my new draft")
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while session.quote == nil && clock.now < deadline { await Task.yield() }
        if let quote = session.quote { session.markEstimateShown(quote.id) }
        guard session.canPropose else { throw CocoaError(.coderInvalidValue) }
        for (name, scheme) in [("light", ColorScheme.light), ("dark", .dark)] {
            let panel = RewritePanel(session: session)
            let panelContents = VStack(spacing: 0) { panel.contents; Divider(); panel.footer }
            try DebugRound4.bitmap(panelContents, name: "rewrite-partial-native-fields-unsupported-\(name)", width: 360, height: 680, scheme: scheme, directory: directory)
            let controls = RewriteProposalControls(session: session, propose: {}).padding(16)
            try DebugRound4.bitmap(controls, name: "rewrite-refreshed-estimate-controls-\(name)", width: 360, height: 150, scheme: scheme, directory: directory)
            app.settings.values["llm.connector"] = .string("codex")
            app.settings.values["llm.cloudConsent.codex"] = .bool(false)
            try DebugRound4.bitmap(FindClipsPopover(model: editor), name: "find-clips-unprobed-component-\(name)", width: 380, height: 330, scheme: scheme, directory: directory)
            for provider in app.providers.filter({ ["anthropic", "claude-code", "codex"].contains($0.id) }) {
                for action in [ConnectorConsentAction.findClips, .rewrite] {
                    for method in provider.group == "cli" ? ["plan", "api_key"] : ["api_key"] {
                        let text = Text(provider.consentCopy(action: action, wordCount: 7, authMethod: method)).font(.system(size: 13)).padding(16)
                        try DebugRound4.bitmap(text, name: "consent-copy-only-\(provider.id)-\(action)-\(method)-\(name)", width: 420, height: 130, scheme: scheme, directory: directory)
                    }
                }
            }
            for contrast in [false, true] {
                let policy = EditorAccessibilityPolicy(reduceMotion: true, reduceTransparency: !contrast, increaseContrast: contrast)
                let bar = SelectionBar(model: editor, policyOverride: policy, dismiss: {})
                try DebugRound4.bitmap(bar, name: "selection-bar-\(contrast ? "increase-contrast" : "reduce-transparency")-\(name)", width: 560, height: 48, scheme: scheme, directory: directory)
            }
            if let clip = editor.suggestedClips.first {
                try DebugRound4.bitmap(ClipRow(shell: shell, editor: editor, clip: clip, suggested: true), name: "sidebar-24pt-suggestion-\(name)", width: 300, height: 50, scheme: scheme, directory: directory)
            }
            editor.failedExports[ExportLedger.key(.fullEdit, aspect: editor.project.export.aspect)] = directory
            try DebugRound4.bitmap(FullTakeRow(editor: editor), name: "sidebar-24pt-retry-\(name)", width: 300, height: 70, scheme: scheme, directory: directory)
            editor.failedExports = [:]
            for isStart in [false, true] {
                let notice = InlineNotice(text: RewriteSession.refusal(VoiceLabGeometryError.seamFadeOutsideTake(isStart: isStart))).padding(16)
                try DebugRound4.bitmap(notice, name: "take-\(isStart ? "start" : "end")-refusal-component-\(name)", width: 360, height: 110, scheme: scheme, directory: directory)
            }
        }
    }
}
#endif
