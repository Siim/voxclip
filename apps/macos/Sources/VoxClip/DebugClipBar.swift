#if DEBUG
import AppKit
import SwiftUI
import VoxClipCore

/// The clip bar (impl-plan V3b) on the "Five questions" fixture, in an offscreen `MainWindow`:
/// its frames against f1 at 1280 × 800 (Rewrite 12 in, the Ask field to 10 from the end, the
/// picker 3 inside it), its fill and hairline, the verbs and Ask with a selection and without
/// one, Tighten's step and toast, a suggestion's Keep and Dismiss with ⇧⌘↩, the Find Clips
/// popover at Hook, Tab from the active tab into the bar, the Ask field's and ⇧⌘↩'s keys against the
/// Clip menu, 24 pt targets, VoiceOver's group and the picker's
/// name, and the collapses: labels at 1128 (the editor keeps 602), icons under 600, "Ask…"
/// under 440. Captures `v2-clipbar-*`
/// offscreen; `sceneCaptures` takes the real-window `v2-clipbar-1280.png`.
@MainActor enum DebugClipBar {
    private static var windowControllers: [NSWindowController] = []

    static func run(app: AppModel, fixture: Project, directory: URL) async throws -> [DebugUISuite.Result] {
        var results: [DebugUISuite.Result] = []
        func check(_ name: String, _ passed: Bool) { results.append(.init(name: name, passed: passed)) }
        defer { windowControllers = [] }
        // Fresh layout, Voice Lab on so the selection Rewrite can open, and Apple on-device as the AI; in memory only.
        let previousSettings = app.settings
        defer { app.settings = previousSettings }
        for key in [WorkspaceLayout.explorerWidthKey, WorkspaceLayout.rightWidthKey, WorkspaceLayout.timelineHeightKey] { app.settings.values[key] = nil }
        app.settings.values["voiceLab.enabled"] = .bool(true)
        app.settings.values["voiceLab.betaNoticeAccepted"] = .bool(true)
        app.settings.values["llm.connector"] = .string("apple-foundation")

        let shell = WorkspaceShell(app: app)
        let document = VoxClipDocument(project: try DebugSidebar.fiveQuestions(from: fixture), demo: true)
        await shell.attachForTesting(document, selection: .fullTake)
        guard let editor = shell.editor else { throw CocoaError(.coderInvalidValue) }
        defer { editor.close() }
        editor.mediaResolved = true; editor.refresh()
        let undo = UndoManager()
        undo.groupsByEvent = false
        editor.undoManager = undo
        let window = makeWindow(app: app, shell: shell, size: NSSize(width: 1280, height: 800))
        defer { window.close() }
        guard let root = window.contentView else { throw CocoaError(.coderInvalidValue) }
        // SwiftUI builds the shell's tree in its next passes.
        for _ in 0..<80 where DebugShell.firstView(ClipBarView.self, in: root)?.frame.width ?? 0 < 600 {
            root.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(25))
        }
        guard let bar = DebugShell.firstView(ClipBarView.self, in: root),
              let work = sequence(first: bar as NSResponder, next: \.nextResponder).lazy.compactMap({ $0 as? EditorWorkController }).first else {
            check("the editor column holds the clip bar", false)
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

        // Full Take, no selection: Tighten and Hook, then the picker alone at the end.
        shell.selection = .fullTake
        editor.selectedWordIDs = []
        // DebugShell checks the bar's region, 224, 38, 652 × 34 (notes.md §1), at every size; here it is the bar's own layout.
        settle()
        let end = bar.bounds.width
        check("with no selection the bar shows Tighten and Hook, no Rewrite or Ask, and the picker 13 from its end",
              bar.rewrite.isHidden && bar.ask.isHidden && !bar.tighten.isHidden && !bar.hook.isHidden && !bar.picker.isHidden && near(bar.picker.frame.maxX, end - 13))
        check("VoiceOver reads the bar as the group \"Full Take tools\" with the picker \"AI: Apple on-device, On-device model\" (\(bar.picker.accessibilityLabel() ?? ""))",
              bar.accessibilityRole() == .group && bar.accessibilityLabel() == "Full Take tools" && bar.picker.accessibilityLabel() == "AI: Apple on-device, On-device model")
        results += try pixelChecks(bar: bar)
        try capture(bar, name: "v2-clipbar-fulltake", directory: directory)

        // Clip 1 with a selection (f1): Rewrite 12 in, Tighten, Hook, the Ask field to 866 with the picker 3 inside it.
        shell.selection = .clip("five-1")
        guard let clip = editor.activeClip, let first = editor.index(clip.startWordId) else { throw CocoaError(.coderInvalidValue) }
        let selection = Set(editor.words[(first + 6)...(first + 11)].map(\.id))
        editor.selectedWordIDs = selection
        settle()
        let rewrite = frame(bar.rewrite), ask = frame(bar.ask), picker = frame(bar.picker)
        check("Rewrite starts 12 in (f1: 236), 24 high, centred on the bar's 33 pt (\(rewrite))", near(bar.rewrite.frame.minX, 12) && rewrite.height == 24 && abs(bar.rewrite.frame.midY - 16.5) <= 0.5)
        check("the Ask field runs to 10 from the bar's end (f1: 866), 24 high (\(ask))", near(bar.ask.frame.maxX, bar.bounds.width - 10) && ask.height == 24)
        check("the picker sits 3 inside the field's end (\(picker))", near(bar.picker.frame.maxX, bar.ask.frame.maxX - 3) && bar.picker.frame.minX > bar.ask.frame.minX)
        let verbs = [bar.rewrite, bar.tighten, bar.hook].filter { !$0.isHidden }
        check("the verbs read Rewrite, Tighten (when it can act) and Hook in f1's order, left to right (\(verbs.map(\.label)))",
              !bar.rewrite.isHidden && !bar.hook.isHidden && zip(verbs, verbs.dropFirst()).allSatisfy { $0.frame.maxX < $1.frame.minX })
        check("VoiceOver reads \"Clip 1 tools\"", bar.accessibilityLabel() == "Clip 1 tools")
        // A click in the Ask field after the Explorer: the field's pane takes focus, and Return and Delete stay the field's.
        editor.focusedPane = .sidebar
        let askFocused = window.makeFirstResponder(bar.ask)
        check("a click in the Ask field after the Explorer puts focus in the tab and clip-bar pane",
              askFocused && editor.focusedPane == .tabs && window.firstResponder is NSText)
        if askFocused, let clipMenu = NSApp.mainMenu?.items.first(where: { $0.title == "Clip" })?.submenu {
            let delete = String(UnicodeScalar(NSDeleteCharacter)!)
            let keys = [(43, "\r", UInt16(36)), (44, delete, UInt16(51))].compactMap { tag, key, code -> (NSMenuItem, NSEvent)? in
                guard let item = clipMenu.items.first(where: { $0.tag == tag && $0.keyEquivalentModifierMask.isEmpty }),
                      let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                   characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: code) else { return nil }
                return (item, event)
            }
            // Checked against the stale Explorer focus too, which a mouse selection in the transcript leaves.
            check("Rename Clip… and Remove Clip leave the Ask field's Return and Delete alone",
                  keys.count == 2 && keys.allSatisfy { item, event in
                      [EditorPane.sidebar, editor.focusedPane].allSatisfy { !AppDelegate.clipRowKeyEnabled(item, event: event, pane: $0, renaming: shell.renaming != nil, responder: window.firstResponder) }
                  })
        }
        window.makeFirstResponder(nil)
        try JSONEncoder().encode(["rewrite": rewrite, "tighten": frame(bar.tighten), "hook": frame(bar.hook), "ask": ask, "picker": picker])
            .write(to: directory.appendingPathComponent("v2-clipbar-1280-frames.json"), options: .atomic)
        try capture(bar, name: "v2-clipbar-1280", directory: directory)

        // Tab from the active tab goes into the bar: its next key view is the bar's first that can take focus (the Ask
        // field; buttons too with Full Keyboard Access).
        work.tabBar.render()
        var chain: [NSView] = []
        var link = work.tabBar.activeItem?.nextKeyView
        while let view = link, chain.count < 16, !chain.contains(where: { $0 === view }) { chain.append(view); link = view.nextKeyView }
        check("Tab from the active tab runs into the clip bar: Rewrite, Tighten, Hook, the Ask field, the picker (\(chain.compactMap { $0.identifier?.rawValue }))",
              chain.first === bar && [bar.rewrite, bar.tighten, bar.hook, bar.ask, bar.picker].allSatisfy { control in chain.contains { $0 === control } })
        if window.isVisible, let next = work.tabBar.activeItem?.nextValidKeyView {
            check("the next key view the window finds after the tab is in the clip bar (\(String(describing: type(of: next))))", next.isDescendant(of: bar))
        }

        // Find Clips from the menus, ⇧⌘K and ⋯ opens its popover at Hook.
        editor.requestFindClips(from: .clipBar)
        for _ in 0..<40 where work.findClipsPopover?.isShown != true { try await Task.sleep(for: .milliseconds(25)) }
        check("Find Clips opens its popover at the clip bar's Hook", work.findClipsPopover?.isShown == true && bar.findClipsAnchorView === bar.hook)
        editor.showFindClips = false
        for _ in 0..<40 where work.findClipsPopover?.isShown == true { try await Task.sleep(for: .milliseconds(25)) }

        // Tighten: one step on the clip, then its toast. Clip 2 has two cut fillers; restore them first.
        shell.selection = .clip("five-2")
        editor.selectedWordIDs = []
        undo.beginUndoGrouping(); editor.apply(.restoreCuts, name: "Restore cuts"); undo.endUndoGrouping()
        settle()
        let before = editor.undoSteps, edits = editor.project.edits
        if !bar.tighten.isHidden {
            undo.beginUndoGrouping(); bar.tighten.performClick(nil); undo.endUndoGrouping()
            settle()
            check("Tighten on Clip 2 is one undo step, \"Tighten clip 2\"", editor.undoSteps == before + 1 && undo.undoActionName == "Tighten clip 2")
            check("its toast reads \"\(bar.toast.label.stringValue) Undo\" in Tighten's place", !bar.toast.isHidden && bar.tighten.isHidden && bar.toast.cuts > 0)
            try capture(bar, name: "v2-clipbar-tighten-toast", directory: directory)
            bar.toast.undo.performClick(nil)
            settle()
            check("the toast's Undo undoes the Tighten", editor.project.edits == edits && bar.toast.isHidden && !bar.tighten.isHidden)
        } else { check("Clip 2 has fillers to tighten after Restore cuts", false) }

        // A suggestion's tab: "Suggested clip", Keep ⇧⌘↩ and Dismiss (f5, impl-plan item 8).
        shell.selection = .clip("five-5")
        settle()
        check("a suggestion's bar shows Suggested clip, Keep and Dismiss, and no verbs",
              bar.variant == .suggestion("five-5") && !bar.keep.isHidden && !bar.dismiss.isHidden && bar.rewrite.isHidden && bar.hook.isHidden && bar.picker.isHidden)
        try capture(bar, name: "v2-clipbar-suggestion", directory: directory)
        check("Keep and Dismiss are 24 pt targets around their 22 pt chips (\(bar.keep.frame.height), \(bar.dismiss.frame.height))",
              bar.keep.frame.height == 24 && bar.dismiss.frame.height == 24 && bar.keep.chip.height == 22)
        if let main = NSApp.mainMenu, let clipMenu = main.items.first(where: { $0.title == "Clip" })?.submenu {
            let alternate = clipMenu.items.first { $0.tag == 40 && $0.keyEquivalentModifierMask == [.command, .shift] && $0.keyEquivalent == "\r" }
            let plainKeep = clipMenu.items.first { $0.tag == 40 && $0.keyEquivalentModifierMask.isEmpty }
            check("Clip › Keep Suggestion answers ⇧⌘↩ as a hidden alternate", alternate?.isHidden == true && alternate?.allowsKeyEquivalentWhenHidden == true)
            // ⇧⌘↩ from the transcript keeps the tab's suggestion; the bare Return stays the Explorer's.
            _ = focusTranscript(in: window)
            editor.focusedPane = .transcript
            let shiftCommandReturn = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                      characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)
            let plainReturn = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                               characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)
            check("⇧⌘↩ reaches Keep Suggestion from the transcript, the bare Return does not (\(String(describing: window.firstResponder.map { type(of: $0) })))",
                  window.firstResponder is TranscriptNSTextView
                  && alternate.map { AppDelegate.clipRowKeyEnabled($0, event: shiftCommandReturn, pane: editor.focusedPane, renaming: shell.renaming != nil, responder: window.firstResponder) } == true
                  && plainKeep.map { AppDelegate.clipRowKeyEnabled($0, event: plainReturn, pane: editor.focusedPane, renaming: shell.renaming != nil, responder: window.firstResponder) } == false)
        }
        let steps = editor.undoSteps
        undo.beginUndoGrouping(); bar.keep.performClick(nil); undo.endUndoGrouping()
        check("Keep keeps the suggestion in one step", editor.undoSteps == steps + 1 && editor.keptClips.contains { $0.id == "five-5" })
        undo.undo()

        // Hook's status while Find Clips runs.
        shell.selection = .fullTake
        editor.finding = true
        settle()
        check("while Find Clips runs, \"Finding clips…\" stands in Hook's place", !bar.finding.isHidden && bar.hook.isHidden)
        try capture(bar, name: "v2-clipbar-finding", directory: directory)
        editor.finding = false

        // Narrow (impl-plan §3.5). The editor keeps 604 pt with its hairlines, so at 1128 the bar is 602 and keeps its
        // labels; it is under 600 only in a narrower full screen or Split View, which the bar's own width stands in for.
        shell.selection = .clip("five-1")
        editor.selectedWordIDs = selection
        window.setContentSize(NSSize(width: 1128, height: 800))
        shell.windowWidth = 1128
        for _ in 0..<80 where abs(bar.frame.width - 602) > 0.5 { root.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(25)) }
        settle()
        check("at 1128 the bar is 602 and its verbs keep their labels (\(Int(bar.frame.width)))", abs(bar.frame.width - 602) <= 0.5 && !bar.rewrite.iconOnly)
        bar.frame.size.width = 560
        bar.needsLayout = true
        bar.layoutSubtreeIfNeeded()
        check("under 600 the verbs show icons with their names as tooltips", bar.rewrite.iconOnly && bar.hook.iconOnly && bar.rewrite.frame.width == 24 && bar.hook.toolTip != nil && !bar.ask.isHidden)
        try capture(bar, name: "v2-clipbar-560", directory: directory)
        // Under 440 the Ask field is "Ask…" with its popover; the picker keeps its dot and first word.
        bar.frame.size.width = 420
        bar.needsLayout = true
        bar.layoutSubtreeIfNeeded()
        check("under 440 Ask collapses into \"Ask…\" and the picker stays whole or at its first word",
              !bar.askButton.isHidden && bar.ask.isHidden && bar.picker.frame.width >= bar.picker.compactWidth && bar.picker.frame.maxX <= 420 - ClipBarMetrics.trailing)
        try capture(bar, name: "v2-clipbar-420", directory: directory)
        bar.askButton.performClick(nil)
        check("\"Ask…\" opens the field in a popover", bar.askPopover?.isShown == true)
        bar.askPopover?.close()
        window.setContentSize(NSSize(width: 1280, height: 800))
        shell.windowWidth = 1280
        root.layoutSubtreeIfNeeded()
        return results
    }

    /// The bar's fill is the editor surface and its last row the hairline (notes.md `.cbar`).
    private static func pixelChecks(bar: ClipBarView) throws -> [DebugUISuite.Result] {
        guard let bitmap = bar.bitmapImageRepForCachingDisplay(in: bar.bounds) else { return [.init(name: "the clip bar draws", passed: false)] }
        bar.cacheDisplay(in: bar.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsHigh) / max(1, bar.bounds.height)
        // The window's pixels in sRGB, as DebugTabs reads them; an offscreen backing store can hold the sRGB values
        // under the display's profile, so the raw components count too.
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
        let empty = CGPoint(x: bar.bounds.width * 0.6, y: 2)
        func describe(_ color: NSColor?) -> String {
            color.map { String(format: "#%02X%02X%02X", Int($0.redComponent * 255 + 0.5), Int($0.greenComponent * 255 + 0.5), Int($0.blueComponent * 255 + 0.5)) } ?? "none"
        }
        let fill = samples(empty.x, empty.y), line = samples(empty.x, bar.bounds.height - 0.5)
        return [
            .init(name: "the clip bar's fill is bg.surface (\(fill.map(describe)), \(describe(token("bg.surface"))))", passed: fill.contains { same($0, token("bg.surface")) }),
            .init(name: "its last row is the line.default hairline (\(line.map(describe)), \(describe(token("line.default"))))", passed: line.contains { same($0, token("line.default")) }),
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
        let host = NSHostingController(rootView: WorkspaceView(shell: shell).environment(app).sceneAccent())
        host.sizingOptions = []
        host.sceneBridgingOptions = []
        window.contentViewController = host
        window.setContentSize(size)
        shell.windowWidth = size.width
        window.orderBack(nil)
        return window
    }

    /// The real-window capture: f1's frame at 1280 × 800 with Clip 1 open and words selected.
    static func sceneCaptures(app: AppModel, fixture: Project, directory: URL) async throws -> [DebugUISuite.Result] {
        guard !DebugUISuite.sessionLocked else { throw CocoaError(.userCancelled) }
        let previousSettings = app.settings
        defer { app.settings = previousSettings }
        app.settings.values["voiceLab.enabled"] = .bool(true)
        app.settings.values["voiceLab.betaNoticeAccepted"] = .bool(true)
        app.settings.values["llm.connector"] = .string("claude-code")
        let shell = WorkspaceShell(app: app)
        await shell.attachForTesting(VoxClipDocument(project: try DebugSidebar.fiveQuestions(from: fixture), demo: true), selection: .fullTake)
        guard let editor = shell.editor else { throw CocoaError(.coderInvalidValue) }
        defer { editor.close() }
        editor.mediaResolved = true; editor.refresh()
        shell.windowWidth = 1280
        shell.selection = .clip("five-1")
        if let clip = editor.activeClip, let start = editor.index(clip.startWordId) {
            editor.selectedWordIDs = Set(editor.words[(start + 6)...(start + 11)].map(\.id))
        }
        var frames: [String: CGRect] = [:]
        try await DebugUISuite.snapshot(WorkspaceView(shell: shell).environment(app), name: "v2-clipbar-1280-window", size: NSSize(width: 1280, height: 800), appearance: .darkAqua,
            directory: directory, active: true, mainWindow: true, native: true, beforeCapture: { window in
                guard let root = window.contentView, let bar = DebugShell.firstView(ClipBarView.self, in: root) else { return nil }
                bar.render()
                root.layoutSubtreeIfNeeded()
                for (name, view) in [("bar", bar as NSView), ("rewrite", bar.rewrite), ("ask", bar.ask), ("picker", bar.picker)] {
                    let rect = view.convert(view.bounds, to: nil)
                    frames[name] = CGRect(x: rect.minX, y: root.bounds.height - rect.maxY, width: rect.width, height: rect.height)
                }
                return nil
            })
        try JSONEncoder().encode(frames).write(to: directory.appendingPathComponent("v2-clipbar-1280-native-frames.json"), options: .atomic)
        return [.init(name: "native clip bar at 224, 38 with Rewrite at 236 and the field to 866 (\(frames))",
                      passed: frames["bar"] == ShellRegion.clipBar.reference && frames["rewrite"].map { abs($0.minX - 236) <= 1 } == true && frames["ask"].map { abs($0.maxX - 866) <= 1 } == true)]
    }
}
#endif
