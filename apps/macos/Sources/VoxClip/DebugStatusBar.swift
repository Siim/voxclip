#if DEBUG
import AppKit
import SwiftUI
import VoxClipCore

/// The status bar (impl-plan V11a) on the "Five questions" fixture, in an offscreen `MainWindow` at 1280 × 800: f1's
/// measurements (the AI's dot 15 in and its name at 27, the export state ending 15 from the right edge), the
/// `bg.statusBar` fill and its hairline, no billing phrase before this session's detection and C8's phrase after a
/// stubbed one, "Finding clips… 0:12" with its spinner, the Frame's View › Frame choices and its one undo step,
/// VoiceOver's group with values, and the narrow drop order at 960 and 800. Captures `v2-status-*` offscreen;
/// `sceneCaptures` takes the real-window `v2-status-1280-window.png`.
@MainActor enum DebugStatusBar {
    private static var windowControllers: [NSWindowController] = []

    static func run(app: AppModel, fixture: Project, directory: URL) async throws -> [DebugUISuite.Result] {
        var results: [DebugUISuite.Result] = []
        func check(_ name: String, _ passed: Bool) { results.append(.init(name: name, passed: passed)) }
        defer { windowControllers = [] }
        // Fresh layout and Claude Code on a plan through a fixture connector; settings and detection in memory, put back.
        let previousSettings = app.settings, previousOverride = app.connectorOverride
        let previousStatus = app.detectedConnectorStatus, previousMethods = app.knownCLIAuthMethods
        defer {
            app.settings = previousSettings; app.connectorOverride = previousOverride
            app.detectedConnectorStatus = previousStatus; app.knownCLIAuthMethods = previousMethods
        }
        for key in [WorkspaceLayout.explorerWidthKey, WorkspaceLayout.rightWidthKey, WorkspaceLayout.timelineHeightKey] { app.settings.values[key] = nil }
        app.settings.values["llm.connector"] = .string("claude-code")
        app.connectorOverride = { id in ConsentFixtureConnector(id: ConnectorID(rawValue: id) ?? .ollama, readiness: .ready, authMethod: "claude.ai") }
        app.detectedConnectorStatus["claude-code"] = nil

        let shell = WorkspaceShell(app: app)
        var project = try DebugSidebar.fiveQuestions(from: fixture)
        project.export.aspect = .landscape
        await shell.attachForTesting(VoxClipDocument(project: project, demo: true), selection: .fullTake)
        guard let editor = shell.editor else { throw CocoaError(.coderInvalidValue) }
        defer { editor.close() }
        editor.mediaResolved = true; editor.refresh()
        let undo = UndoManager()
        undo.groupsByEvent = false
        editor.undoManager = undo
        let window = makeWindow(app: app, shell: shell, size: NSSize(width: 1280, height: 800))
        defer { window.close() }
        guard let root = window.contentView else { throw CocoaError(.coderInvalidValue) }
        for _ in 0..<80 where DebugShell.firstView(StatusBarView.self, in: root)?.frame.width ?? 0 < 1280 {
            root.layoutSubtreeIfNeeded()
            await Task.yield()
        }
        guard let bar = DebugShell.firstView(StatusBarView.self, in: root) else {
            check("the window holds the status bar", false)
            return results
        }
        func settle() {
            bar.render()
            root.layoutSubtreeIfNeeded()
            bar.layoutSubtreeIfNeeded()
        }
        /// A view's frame in window points from the top-left, as notes.md §1 gives them.
        func frame(_ view: NSView) -> CGRect {
            let rect = view.convert(view.bounds, to: nil)
            return CGRect(x: rect.minX, y: root.bounds.height - rect.maxY, width: rect.width, height: rect.height)
        }
        func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) <= 1 }

        // Clip 1 open, nothing detected yet: the name and a ring, no billing phrase.
        shell.selection = .clip("five-1")
        settle()
        check("the status bar is notes.md's 0, 776, 1280 × 24 (\(frame(bar)))", frame(bar) == ShellRegion.statusBar.reference)
        check("before detection it shows the AI's name with a ring and no billing (\(bar.content[.harness]?.text ?? "none"))",
              bar.content[.harness]?.text == "Claude Code · Sonnet (latest)" && bar.content[.harness]?.lead == .dot(token: "text.tertiary", filled: false)
              && bar.content[.billing] == nil && !bar.shown.contains(.billing))
        try capture(bar, name: "v2-status-undetected", directory: directory)
        if let provider = app.providers.first(where: { $0.id == "claude-code" }) { _ = await app.connectorStatus(provider) }
        settle()
        check("after this session's detection it reads \"No extra cost on your plan\" after a filled dot (\(bar.content[.billing]?.text ?? "none"))",
              bar.content[.billing]?.text == "No extra cost on your plan" && bar.content[.harness]?.lead == .dot(token: "status.success", filled: true)
              && Array(bar.shown.prefix(2)) == [.harness, .billing])
        if let harness = bar.view(.harness), let export = bar.view(.export), let item = bar.content[.harness] {
            let text = frame(harness).minX + StatusBarMetrics.textX(item)
            check("f1: the AI's dot is 15 in and its name at 27 (\(frame(harness).minX + StatusBarMetrics.padding), \(text))",
                  near(frame(harness).minX + StatusBarMetrics.padding, 15) && near(text, 27))
            check("f1: the export state ends 8 from the right edge, its text 15 (\(frame(export).maxX))", near(frame(export).maxX, 1272))
        } else { check("f1's items show", false) }
        let summary = bar.content[.summary]
        check("the summary reads the tab, its edited length in SF Mono and its cuts (\(summary?.text ?? "none"))",
              summary?.text.hasPrefix("Clip 1 · ") == true && summary?.parts.filter(\.mono).count == 1 && summary?.help == editor.summaryDetail)
        check("the Frame reads \"16:9 · 1080p30\" and the export \"Not exported\"", bar.content[.frame]?.text == "16:9 · 1080p30" && bar.content[.export]?.text == "Not exported")
        results += pixelChecks(bar: bar)
        try capture(bar, name: "v2-status-1280", directory: directory)

        // Find Clips runs: "Finding clips… 0:12" with its spinner; VoiceOver reads the group with values.
        editor.finding = true
        if let since = editor.findingSince { bar.now = { since.addingTimeInterval(12) } }
        settle()
        let spinner = bar.itemView(.task)?.spinner
        check("a Find Clips run reads \"Finding clips… 0:12\" with a spinner (\(bar.content[.task]?.text ?? "none"))",
              bar.content[.task]?.text == "Finding clips… 0:12" && bar.shown.contains(.task)
              && (spinner.map { !$0.isHiddenOrHasHiddenAncestor } ?? false || !StatusBarMetrics.motion))
        let children = (bar.accessibilityChildren() as? [NSView]) ?? []
        check("VoiceOver reads the Status group's items with their values (\(children.map { "\($0.accessibilityLabel() ?? ""): \($0.accessibilityValue() as? String ?? "")" }))",
              bar.accessibilityRole() == .group && bar.accessibilityLabel() == "Status"
              && children.map { $0.accessibilityLabel() ?? "" } == ["AI", "In progress", "Edit summary", "Frame", "Export"]
              && children.first?.accessibilityValue() as? String == "Claude Code (installed CLI), Sonnet (latest), no extra cost on your plan"
              && children.dropFirst().first?.accessibilityValue() as? String == "Finding clips, 12 seconds")
        try capture(bar, name: "v2-status-finding", directory: directory)

        // The Frame: View › Frame's choices, one undo step.
        let menu = bar.frameButton.makeMenu()
        check("the Frame's menu is View › Frame's (\(menu.items.map(\.title)))", menu.items.map(\.title) == ["9:16", "1:1", "16:9", "Original"] && menu.items[2].state == .on
              && bar.frameButton.accessibilityRole() == .popUpButton)
        let steps = editor.undoSteps
        undo.beginUndoGrouping(); bar.frameButton.chooseAspect(menu.items[0]); undo.endUndoGrouping()
        settle()
        check("choosing 9:16 sets the aspect as one undo step (\(bar.content[.frame]?.text ?? "none"))",
              editor.project.export.aspect == .portrait && editor.undoSteps == steps + 1 && undo.undoActionName == "Change aspect" && bar.content[.frame]?.text == "9:16 · 1080p30")
        undo.undo()
        settle()

        // Narrow windows drop the billing first, then the Frame (impl-plan §3.5's spirit), and never overlap.
        for (width, name) in [(960.0, "v2-status-960"), (800.0, "v2-status-800")] {
            window.setContentSize(NSSize(width: width, height: 600))
            shell.windowWidth = width
            for _ in 0..<40 where abs(bar.frame.width - width) > 0.5 {
                root.layoutSubtreeIfNeeded()
                await Task.yield()
            }
            settle()
            let shown = bar.shown.compactMap { bar.view($0) }.map(frame)
            // What went is the start of the drop order: the billing, then the Frame, the export, the AI, the task.
            let present = StatusItem.Kind.dropOrder.filter { bar.content[$0] != nil }
            let dropped = present.filter { !bar.shown.contains($0) }
            check("at \(Int(width)) the bar shows \(bar.shown.map(\.rawValue)) without overlap, dropping in order, the summary kept",
                  bar.shown.contains(.summary) && zip(shown, shown.dropFirst()).allSatisfy { $0.maxX <= $1.minX } && shown.allSatisfy { $0.maxX <= width - 8 + 0.5 }
                  && dropped == Array(present.prefix(dropped.count)))
            try capture(bar, name: name, directory: directory)
        }
        editor.finding = false
        return results
    }

    /// The bar's fill is `bg.statusBar` and its first row the `line.default` hairline (the mockup's `.sbar`).
    private static func pixelChecks(bar: StatusBarView) -> [DebugUISuite.Result] {
        guard let bitmap = bar.bitmapImageRepForCachingDisplay(in: bar.bounds) else { return [.init(name: "the status bar draws", passed: false)] }
        bar.cacheDisplay(in: bar.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsHigh) / max(1, bar.bounds.height)
        func samples(_ x: CGFloat, _ y: CGFloat) -> [NSColor] {
            guard let raw = bitmap.colorAt(x: Int(x * scale), y: Int(y * scale)) else { return [] }
            return [raw.usingColorSpace(.sRGB), raw].compactMap { $0 }
        }
        func token(_ path: String) -> NSColor? {
            var color: NSColor?
            (bar.window?.effectiveAppearance ?? NSAppearance(named: .darkAqua)!).performAsCurrentDrawingAppearance { color = DesignValues.nsColor(path).usingColorSpace(.sRGB) }
            return color
        }
        func same(_ a: NSColor?, _ b: NSColor?) -> Bool {
            guard let a, let b else { return false }
            return abs(a.redComponent - b.redComponent) < 0.02 && abs(a.greenComponent - b.greenComponent) < 0.02 && abs(a.blueComponent - b.blueComponent) < 0.02
        }
        // Between the leading and trailing items, where nothing draws.
        let leadingEnd = bar.shown.filter(StatusItem.Kind.leading.contains).compactMap { bar.view($0)?.frame.maxX }.max() ?? 8
        let trailingStart = bar.shown.filter(StatusItem.Kind.trailing.contains).compactMap { bar.view($0)?.frame.minX }.min() ?? bar.bounds.width - 8
        let x = (leadingEnd + trailingStart) / 2
        let fill = samples(x, 12), line = samples(x, 0.5)
        return [
            .init(name: "the status bar's fill is bg.statusBar", passed: fill.contains { same($0, token("bg.statusBar")) }),
            .init(name: "its top row is the line.default hairline", passed: line.contains { same($0, token("line.default")) }),
        ]
    }

    private static func capture(_ view: NSView, name: String, directory: URL) throws {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let data = bitmap.representation(using: .png, properties: [:]) { try data.write(to: directory.appendingPathComponent("\(name).png")) }
    }

    private static func makeWindow(app: AppModel, shell: WorkspaceShell, size: NSSize) -> MainWindow {
        let window = MainWindow(contentRect: NSRect(origin: NSPoint(x: -10000, y: -10000), size: size), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        windowControllers.append(DebugShellWindowController(window: window, shell: shell))
        window.appearance = NSAppearance(named: .darkAqua)
        EditorShellController.prepare(window)
        let host = ShellHost.controller(WorkspaceView(shell: shell), app: app)
        window.contentViewController = host
        window.setContentSize(size)
        shell.windowWidth = size.width
        window.orderBack(nil)
        return window
    }

    /// The real-window capture: f1's frame at 1280 × 800 with Clip 1 open and Claude Code detected on a plan.
    static func sceneCaptures(app: AppModel, fixture: Project, directory: URL) async throws -> [DebugUISuite.Result] {
        guard !DebugUISuite.sessionLocked else { throw CocoaError(.userCancelled) }
        let previousSettings = app.settings, previousOverride = app.connectorOverride
        let previousStatus = app.detectedConnectorStatus, previousMethods = app.knownCLIAuthMethods
        defer {
            app.settings = previousSettings; app.connectorOverride = previousOverride
            app.detectedConnectorStatus = previousStatus; app.knownCLIAuthMethods = previousMethods
        }
        app.settings.values["llm.connector"] = .string("claude-code")
        app.connectorOverride = { id in ConsentFixtureConnector(id: ConnectorID(rawValue: id) ?? .ollama, readiness: .ready, authMethod: "claude.ai") }
        if let provider = app.providers.first(where: { $0.id == "claude-code" }) { _ = await app.connectorStatus(provider) }
        let shell = WorkspaceShell(app: app)
        var project = try DebugSidebar.fiveQuestions(from: fixture)
        project.export.aspect = .landscape
        await shell.attachForTesting(VoxClipDocument(project: project, demo: true), selection: .fullTake)
        guard let editor = shell.editor else { throw CocoaError(.coderInvalidValue) }
        defer { editor.close() }
        editor.mediaResolved = true; editor.refresh()
        shell.windowWidth = 1280
        shell.selection = .clip("five-1")
        var frames: [String: CGRect] = [:]
        try await DebugUISuite.snapshot(WorkspaceView(shell: shell).environment(app), name: "v2-status-1280-window", size: NSSize(width: 1280, height: 800), appearance: .darkAqua,
            directory: directory, active: true, mainWindow: true, native: true, beforeCapture: { window in
                guard let root = window.contentView, let bar = DebugShell.firstView(StatusBarView.self, in: root) else { return nil }
                bar.render()
                root.layoutSubtreeIfNeeded()
                frames["bar"] = { let rect = bar.convert(bar.bounds, to: nil); return CGRect(x: rect.minX, y: root.bounds.height - rect.maxY, width: rect.width, height: rect.height) }()
                for kind in bar.shown {
                    guard let view = bar.view(kind) else { continue }
                    let rect = view.convert(view.bounds, to: nil)
                    frames[kind.rawValue] = CGRect(x: rect.minX, y: root.bounds.height - rect.maxY, width: rect.width, height: rect.height)
                }
                return nil
            })
        try JSONEncoder().encode(frames).write(to: directory.appendingPathComponent("v2-status-1280-native-frames.json"), options: .atomic)
        return [.init(name: "native status bar at 0, 776, 1280 × 24 with the AI at 8 and the export state to 1272 (\(frames))",
                      passed: frames["bar"] == ShellRegion.statusBar.reference && frames["harness"].map { abs($0.minX - 8) <= 1 } == true
                      && frames["export"].map { abs($0.maxX - 1272) <= 1 } == true && frames["billing"] != nil)]
    }
}
#endif
