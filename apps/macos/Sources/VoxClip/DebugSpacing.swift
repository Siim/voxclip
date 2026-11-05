#if DEBUG
import AppKit
import SwiftUI
import VoxClipCore
import VoxClipMedia

/// Spacing captures (doc/design.md §16.3): every main surface at the default window and at the
/// window minimum, drawn with cacheDisplay in a window parked off every screen. Nothing is shown,
/// nothing reads the screen, no provider is called. `-layoutAudit <dir> -spacingCaptures` writes
/// one PNG per surface and `spacing-captures.json`, the names in order.
@MainActor enum DebugSpacing {
    static let rewriteVariants = ["rewrite", "rewrite-budget", "rewrite-takes-ready", "rewrite-takes-none-passed", "rewrite-takes-length-changed",
                                  "rewrite-takes-fixing", "rewrite-takes-lipsync-idle", "rewrite-own-words", "rewrite-say-it-myself"]

    static func run(app: AppModel, directory: URL) async throws -> [DebugUISuite.Result] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let root = app.shared?.root else { throw VoxClipError.sharedResourcesMissing }
        let url = root.appendingPathComponent("fixtures/projects/five-questions.voxclip")
        let project = try DemoEditing.loadFixture(url)
        let saved = app.settings
        defer { app.settings = saved }
        app.settings.values["voiceLab.enabled"] = .bool(true)
        app.settings.values["voiceLab.betaNoticeAccepted"] = .bool(true)
        app.settings.values["voiceLab.providerConsent.elevenlabs"] = .bool(true)
        for key in [WorkspaceLayout.explorerWidthKey, WorkspaceLayout.rightWidthKey, WorkspaceLayout.timelineHeightKey] { app.settings.values.removeValue(forKey: key) }
        var results: [DebugUISuite.Result] = []
        var names: [String] = []
        func capture(_ name: String, size: NSSize, dark: Bool = true, mainWindow: Bool = false, _ content: some View) async {
            do {
                try await draw(content.environment(app), name: name, size: size, dark: dark, mainWindow: mainWindow, directory: directory)
                names.append(name); results.append(.init(name: "spacing capture \(name)", passed: true))
            } catch { results.append(.init(name: "spacing capture \(name): \(error)", passed: false)) }
        }

        let shell = WorkspaceShell(app: app)
        app.recent = [url]; app.recentProjects.refresh([url])
        shell.windowWidth = 1280
        await capture("home-1280", size: NSSize(width: 1280, height: 800), mainWindow: true, WorkspaceView(shell: shell))
        shell.windowWidth = 960
        await capture("home-960", size: NSSize(width: 960, height: 600), mainWindow: true, WorkspaceView(shell: shell))
        await shell.attachForTesting(VoxClipDocument(project: project, demo: true))
        guard let editor = shell.editor else { throw CocoaError(.coderInvalidValue) }
        defer { editor.close() }
        editor.mediaResolved = true; editor.refresh()
        editor.waveform = WaveformData(fine: Array(repeating: 0.01, count: 300_000))
        for (width, height) in [(1280, 800), (960, 600)] {
            shell.windowWidth = CGFloat(width)
            await capture("editor-\(width)", size: NSSize(width: width, height: height), mainWindow: true, WorkspaceView(shell: shell))
        }
        shell.windowWidth = 1280
        await capture("editor-1280-light", size: NSSize(width: 1280, height: 800), dark: false, mainWindow: true, WorkspaceView(shell: shell))
        for width in [224, 220] {
            await capture("explorer-\(width)", size: NSSize(width: width, height: 720), ExplorerView(shell: shell))
        }
        await capture("timeline-1280", size: NSSize(width: 1280, height: 180), TimelinePanel(model: editor, shell: shell))
        await capture("timeline-960", size: NSSize(width: 960, height: 180), TimelinePanel(model: editor, shell: shell))
        for width in [404, 300] {
            let model = EditorModel(document: VoxClipDocument(project: project, demo: true), app: app, preview: DemoPreviewEngine())
            let panelShell = WorkspaceShell(app: app)
            await capture("panel-captions-\(width)", size: NSSize(width: width, height: 900),
                          PanelHost(model: model, shell: panelShell, width: CGFloat(width), height: 900))
            model.close()
        }
        for variant in rewriteVariants {
            for width in [404, 300] {
                let model = EditorModel(document: VoxClipDocument(project: project, demo: true), app: app, preview: DemoPreviewEngine())
                defer { model.close() }
                do {
                    try open(variant, in: model)
                } catch { results.append(.init(name: "spacing state \(variant): \(error)", passed: false)); continue }
                let panelShell = WorkspaceShell(app: app)
                await capture("panel-\(variant)-\(width)", size: NSSize(width: width, height: 1100),
                              PanelHost(model: model, shell: panelShell, width: CGFloat(width), height: 1100))
            }
        }
        for pane in ["general", "transcription", "ai", "export", "voiceLab", "about"] {
            app.settingsPane = pane
            await capture("settings-\(pane)", size: NSSize(width: 600, height: 560), SettingsView())
        }
        app.settingsPane = "general"
        try JSONEncoder().encode(names).write(to: directory.appendingPathComponent("spacing-captures.json"), options: .atomic)
        return results
    }

    private static func open(_ variant: String, in model: EditorModel) throws {
        switch variant {
        case "rewrite-own-words", "rewrite-say-it-myself":
            try DebugRightColumn.openRewrite("rewrite-takes-ready", in: model)
            guard let session = model.rewrite else { throw CocoaError(.coderInvalidValue) }
            session.chooseWording(variant == "rewrite-own-words" ? .ownWords : .microphone, phrase: 0)
        default: try DebugRightColumn.openRewrite(variant, in: model)
        }
    }

    /// One capture: an offscreen window off every screen, laid out at `size`, drawn with cacheDisplay.
    static func draw<Content: View>(_ content: Content, name: String, size: NSSize, dark: Bool, mainWindow: Bool, directory: URL) async throws {
        let root = content.background(DesignValues.color("bg.window")).sceneAccent()
            .preferredColorScheme(dark ? .dark : .light).environment(\.controlActiveState, .key)
        let controller = NSHostingController(rootView: root)
        controller.sizingOptions = []
        // A borderless window is never constrained to a screen, so a column taller than the display keeps its height.
        let styleMask: NSWindow.StyleMask = mainWindow ? [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView] : [.borderless]
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10000, y: -10000), size: size), styleMask: styleMask, backing: .buffered, defer: false)
        if mainWindow { EditorShellController.prepare(window); controller.sceneBridgingOptions = [] }
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentViewController = controller
        defer { window.close() }
        window.setContentSize(size)
        let hosting = controller.view
        hosting.frame = NSRect(origin: .zero, size: size)
        window.orderBack(nil)
        for _ in 0..<12 {
            try await Task.sleep(for: .milliseconds(50))
            window.setContentSize(size)
            hosting.frame = NSRect(origin: .zero, size: size)
            hosting.layoutSubtreeIfNeeded()
        }
        func prepare(_ view: NSView) {
            if let text = view as? NSTextView {
                if let manager = text.textLayoutManager, let range = manager.textContentManager?.documentRange { manager.ensureLayout(for: range); manager.textViewportLayoutController.layoutViewport() }
                text.displayIfNeeded()
            }
            view.subviews.forEach(prepare)
        }
        prepare(hosting)
        let surface = mainWindow ? hosting.superview ?? hosting : hosting
        guard let bitmap = surface.bitmapImageRepForCachingDisplay(in: surface.bounds) else { throw CocoaError(.fileWriteUnknown) }
        surface.cacheDisplay(in: surface.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: directory.appendingPathComponent(name).appendingPathExtension("png"), options: .atomic)
    }
}
#endif
