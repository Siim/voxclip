#if DEBUG
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import VoxClipCore
@testable import VoxClip

/// Pictures of every place "Rewrite as" shows (design.md §6.3.1), drawn offscreen in dark mode for review: the scope bar
/// (wide and narrow), the selection bar's strip, ✦ Ask Claude's two groups, clip rows, the clip style card's Tone row, the
/// Make it postable review's tone row with Change open, and Settings › Clips. Runs only with VOXCLIP_TONE_CAPTURES=<dir>;
/// it never reads the screen.
@Suite("Rewrite tone captures", .serialized, .offlineFixtures)
@MainActor struct RewriteToneCaptureTests {
    nonisolated static let directory = ProcessInfo.processInfo.environment["VOXCLIP_TONE_CAPTURES"]

    private func write(_ view: NSView, _ name: String, in folder: URL) throws {
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: view.frame.width, height: view.frame.height), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        defer { window.contentView = nil; window.close() }
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent(name + ".png"))
    }

    private func hosting<V: View>(_ view: V, app: AppModel, width: CGFloat, height: CGFloat? = nil) -> NSView {
        let host = NSHostingView(rootView: view.environment(app).frame(width: width).background(DesignValues.color("bg.window")).preferredColorScheme(.dark))
        // Two passes: a view that reads its own width (the narrow scope bar's menu) settles after the first layout.
        host.frame = NSRect(x: 0, y: 0, width: width, height: height ?? host.fittingSize.height)
        host.layoutSubtreeIfNeeded()
        host.frame = NSRect(x: 0, y: 0, width: width, height: height ?? host.fittingSize.height)
        return host
    }

    @Test(.enabled(if: RewriteToneCaptureTests.directory != nil)) func captureEveryPlace() async throws {
        let folder = URL(fileURLWithPath: try #require(Self.directory), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let app = AppModel(settingsStore: RegressionSettingsStore())
        let fake = ConsentFixtureConnector(id: .ollama, readiness: .ready, authMethod: nil)
        app.connectorOverride = { _ in fake }
        app.set("llm.connector", .string("ollama"))
        app.set("general.appearance", .string("dark"))
        let shared = try SharedResources.locate()
        let base = try JSONProjectStore.decode(Data(contentsOf: shared.root.appendingPathComponent("fixtures/projects/interview-take.voxclip")))
        let shell = WorkspaceShell(app: app)
        await shell.attachForTesting(VoxClipDocument(project: try DebugExplorer.fiveQuestions(from: base), demo: true), selection: .fullTake)
        let editor = try #require(shell.editor)
        editor.mediaResolved = true
        editor.refresh()
        let undo = UndoManager(); undo.groupsByEvent = false; editor.undoManager = undo
        defer { editor.close() }
        undo.beginUndoGrouping(); editor.updateClipStyle { $0.tone = .tone("viral-youtuber") }; undo.endUndoGrouping()
        editor.rewriteInstruction = "Sound like my investor pitch: confident, specific, one number per line."
        _ = editor.saveFieldAsTone("My pitch voice")
        editor.rewriteInstruction = ""

        // 4 · The scope bar: the clip bar with the strip always under it, Full take; then narrow.
        for (width, name) in [(CGFloat(760), "4-scope-bar"), (CGFloat(400), "4-scope-bar-narrow")] {
            shell.selection = .fullTake
            let bar = ClipBarView(model: editor, shell: shell)
            bar.frame = NSRect(x: 0, y: 0, width: width, height: ShellMetrics.clipBar)
            bar.render()
            let strip = hosting(ScopeToneStrip(model: editor), app: app, width: width)
            let stack = NSView(frame: NSRect(x: 0, y: 0, width: width, height: ShellMetrics.clipBar + strip.frame.height))
            bar.frame.origin.y = strip.frame.height
            stack.addSubview(strip); stack.addSubview(bar)
            try write(stack, name, in: folder)
            bar.tearDown()
        }
        // The field after a chip: the tone's instruction, its chip marked.
        editor.rewriteInstruction = try #require(editor.rewriteStripItems.first { $0.id == "punchy-reel" }).instruction
        try write(hosting(ScopeToneStrip(model: editor), app: app, width: 760), "4-scope-bar-chip-marked", in: folder)
        editor.rewriteInstruction = ""

        // 1 · The selection bar, its first verb "✦ Rewrite as ▾", and the strip open under it.
        shell.selection = .clip("five-1")
        let start = try #require(editor.activeClip.flatMap { editor.index($0.startWordId) })
        editor.selectedWordIDs = Set(editor.words[(start + 1)...(start + 4)].map(\.id))
        let selection = VStack(alignment: .leading, spacing: 6) {
            SelectionBar(model: editor, forceOpaque: true, rewriteAs: {}, stripOpen: true, dismiss: {})
            SelectionRewriteStrip(model: editor, dismiss: {})
        }.padding(16)
        try write(hosting(selection, app: app, width: 520), "1-selection-strip", in: folder)

        // 2 · ✦ Ask Claude on the selection: "Reword these words" and "Edit the video here".
        editor.openAskClaudeOnSelection()
        try write(hosting(AskClaudePanel(model: editor), app: app, width: 340, height: 360), "2-ask-claude", in: folder)
        editor.closeAskClaude()
        editor.selectedWordIDs = []

        // 3 · Clip rows, kept and suggested, selected so ✦ and Rewrite as show; and the ⋯ menu's Rewrite As items.
        let kept = try #require(editor.keptClips.first), suggested = try #require(editor.suggestedClips.first)
        shell.selection = .clip(kept.id)
        let rows = VStack(alignment: .leading, spacing: 4) {
            ClipRow(shell: shell, editor: editor, clip: kept, suggested: false, selectedFocused: true)
            ClipRow(shell: shell, editor: editor, clip: suggested, suggested: true, hovering: true)
            Divider()
            Text("Rewrite as ▾ (menu)").font(.system(size: 11)).foregroundStyle(.secondary)
            ForEach(editor.rewriteStripItems) { item in
                Text(item.isDefault ? item.title + " · your default" : item.title).font(.system(size: 12)) + Text("  " + item.detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }.padding(12)
        try write(hosting(rows, app: app, width: 300), "3-clip-rows", in: folder)

        // The clip style card with its Tone row.
        editor.clipStyleState.reopened = true
        try write(hosting(ClipStyleCard(editor: editor).padding(12), app: app, width: 300), "card-tone-row", in: folder)

        // 5 · The Make it postable review: the tone row with Change open.
        let run = MakeItRun(clipID: kept.id, cap: nil)
        var plan = ClipAutopilotPlan(startWord: 0, endWord: 5, title: "Most founders price wrong", hook: "Most founders price wrong",
                                     captions: .init(styleId: "vox-bold", font: .init(family: "Roboto", weight: 900), textCase: .upper, wordsPerCaption: 3),
                                     postText: "Most founders price wrong.", score: 8, verdict: .post)
        plan.tone = .init(id: "viral-youtuber", title: "Viral YouTuber", summary: "Hook first, two lines tightened")
        run.plan = plan
        run.phase = .ready
        run.voiceSpent = Decimal(string: "0.18")!
        run.rows = [
            MakeItRow(id: "tone", kind: .choice, text: "✦ Claude wrote it as Viral YouTuber", detail: "Hook first, two lines tightened · voiced 2 phrases, $0.18",
                      play: 0, undoable: true, change: .tone),
            MakeItRow(id: "hook", kind: .choice, text: "Claude chose the hook “Most founders price wrong”", detail: EditorModel.makeItHookDetail,
                      play: 0, undoable: true, change: .hook),
            MakeItRow(id: "cut-0", text: "Cut “uh” ×4 · tightened 3 pauses", play: 0, undoable: true),
        ]
        run.openChoice = "tone"
        let review = VStack(alignment: .leading, spacing: 0) {
            ForEach(run.rows) { row in MakeItRowView(model: editor, run: run, row: row) }
        }.padding(12)
        try write(hosting(review, app: app, width: 380), "5-review-tone-row", in: folder)

        // Settings › Clips with the saved tone.
        try write(hosting(ClipsSettings(app: app), app: app, width: 600, height: 260), "settings-clips", in: folder)
    }
}
#endif
