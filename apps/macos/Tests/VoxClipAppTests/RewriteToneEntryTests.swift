#if DEBUG
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import VoxClipCore
@testable import VoxClip

/// "Rewrite as" everywhere words can be rewritten (design.md §6.3.1): the scope bar's strip, the selection bar's strip and
/// ⇧⌘R, ✦ Ask Claude's "Reword these words", a clip row's Rewrite as, and saved tones. Each place shows the same chips with
/// the default first, and a chip runs Rewrite at once with that tone's instruction on its own scope. The AI is a local
/// stub; nothing is sent or paid.
@Suite("Rewrite tones everywhere", .serialized, .offlineFixtures)
@MainActor struct RewriteToneEntryTests {
    init() { _ = NSApplication.shared }

    private func open(defaultTone: ClipTone? = nil) async throws -> (WorkspaceShell, EditorModel, AppModel) {
        let app = AppModel(settingsStore: RegressionSettingsStore())
        let fake = ConsentFixtureConnector(id: .ollama, readiness: .ready, authMethod: nil)
        app.connectorOverride = { _ in fake }
        app.set("llm.connector", .string("ollama"))
        app.set("voiceLab.enabled", .bool(false))
        let shared = try SharedResources.locate()
        let base = try JSONProjectStore.decode(Data(contentsOf: shared.root.appendingPathComponent("fixtures/projects/interview-take.voxclip")))
        var project = try DebugExplorer.fiveQuestions(from: base)
        if let defaultTone, let catalog = try? ClipStyleCatalog.load(shared: shared) {
            var style = catalog.preset(.auto).style
            style.tone = defaultTone
            project.clipStyle = style
        }
        let shell = WorkspaceShell(app: app)
        await shell.attachForTesting(VoxClipDocument(project: project, demo: true), selection: .fullTake)
        let editor = try #require(shell.editor)
        editor.mediaResolved = true
        editor.refresh()
        let undo = UndoManager()
        undo.groupsByEvent = false
        editor.undoManager = undo
        return (shell, editor, app)
    }

    private func viral(_ editor: EditorModel) throws -> RewriteStripItem {
        try #require(editor.rewriteStripItems.first { $0.id == "viral-youtuber" })
    }

    /// The session a chip opened: its scope and what it asks.
    private func opened(_ editor: EditorModel) async throws -> RewriteSession {
        await editor.rewriteOpenTask?.value
        let session = try #require(editor.rewrite)
        await session.actionTask?.value
        return session
    }

    @Test func theStripHasOneOrderAndTheDefaultComesFirst() async throws {
        let (_, editor, app) = try await open()
        defer { editor.close() }
        let items = editor.rewriteStripItems
        // No tone chosen: Fix mistakes is the default; then Shorter, the catalogue's eight tones in order.
        #expect(items.map(\.id) == ["fix-mistakes", "make-shorter", "viral-youtuber", "punchy-reel", "storyteller", "clear-explainer",
                                    "linkedin-pro", "funny", "hype-launch", "calm-sincere"])
        #expect(items.first?.isDefault == true && items.dropFirst().allSatisfy { !$0.isDefault })
        #expect(items[2].title == "✦ Viral YouTuber" && items[2].instruction == app.rewriteToneCatalog?.tones.first?.instruction)
        // The card's Tone sets the default; every strip re-marks it at once.
        editor.updateClipStyle { $0.tone = .tone("storyteller") }
        #expect(editor.project.clipStyle?.tone == .tone("storyteller"))
        #expect(editor.rewriteStripItems.first?.id == "storyteller" && editor.rewriteStripItems.first?.isDefault == true)
        #expect(editor.rewriteStripItems.count == items.count)
        #expect(editor.askClaudeQuickTones.map(\.id) == ["storyteller", "fix-mistakes", "make-shorter", "punchy-reel"])
        // Settings keep the tone with the default style, so a new project's strips start from it.
        #expect(app.settings.values["clipStyle.default"]?[ai: "tone"].aiString == "storyteller")
        // Auto and As I said it have no tone to rewrite in: Fix mistakes leads again.
        editor.updateClipStyle { $0.tone = .asSaid }
        #expect(editor.rewriteStripItems.first?.id == "fix-mistakes")
    }

    @Test func theScopeBarStripRewritesTheOpenClipAndMarksTheChip() async throws {
        let (shell, editor, _) = try await open(defaultTone: .tone("viral-youtuber"))
        defer { editor.closeRewrite(returnFocus: false); editor.close() }
        shell.selection = .clip("five-1")
        editor.selectedWordIDs = []
        #expect(editor.showsScopeToneStrip)
        #expect(editor.rewriteStripItems.first?.id == "viral-youtuber" && editor.rewriteStripItems.first?.isDefault == true)
        // The strip draws: chips wrap at a wide bar and collapse to a menu when narrow.
        let host = NSHostingView(rootView: ScopeToneStrip(model: editor).environment(editor.app))
        host.frame = NSRect(x: 0, y: 0, width: 652, height: 120)
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.height >= 24)
        let punchy = try #require(editor.rewriteStripItems.first { $0.id == "punchy-reel" })
        editor.rewriteAs(punchy)
        let session = try await opened(editor)
        #expect(session.rewriteScope == .clip("five-1") && session.instruction == punchy.instruction)
        // The field shows the tone's whole instruction, and that chip is the one marked.
        #expect(editor.rewriteInstruction == punchy.instruction && editor.rewriteStripMatch(editor.rewriteInstruction)?.id == "punchy-reel")
        // A tweak unmarks it and can be saved as the creator's own tone.
        editor.rewriteInstruction += " Even shorter."
        #expect(editor.rewriteStripMatch(editor.rewriteInstruction) == nil && editor.canSaveFieldAsTone)
        // The narrow strip collapses to "Tone: …", the same items as a menu.
        host.frame.size.width = 380
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.height >= 22)
    }

    @Test func theSelectionBarStripAndShiftCommandRRewriteTheSelectedWords() async throws {
        let (shell, editor, _) = try await open(defaultTone: .tone("viral-youtuber"))
        defer { editor.closeRewrite(returnFocus: false); editor.close() }
        shell.selection = .clip("five-1")
        let start = try #require(editor.activeClip.flatMap { editor.index($0.startWordId) })
        editor.selectedWordIDs = Set(editor.words[(start + 1)...(start + 3)].map(\.id))
        let range = (start + 1)...(start + 3)
        #expect(editor.selectionRewriteScope == .selection(range))
        // The strip under the bar draws its header, hint and chips, the default first.
        let strip = NSHostingView(rootView: SelectionRewriteStrip(model: editor, dismiss: {}).environment(editor.app))
        strip.layoutSubtreeIfNeeded()
        #expect(strip.fittingSize.width == SelectionRewriteStrip.width && strip.fittingSize.height > 60)
        #expect(SelectionRewriteStrip.hint == "runs at once · voice it after: one priced click")
        // ⇧⌘R asks the default tone directly on the selection.
        editor.rewriteShortcut()
        let first = try await opened(editor)
        let viralInstruction = try viral(editor).instruction
        #expect(first.rewriteScope == .selection(range) && first.instruction == viralInstruction)
        editor.closeRewrite(returnFocus: false)
        // A chip in the strip rewrites the same words in that tone.
        let clear = try #require(editor.rewriteStripItems.first { $0.id == "clear-explainer" })
        editor.rewriteAs(clear, scope: editor.selectionRewriteScope)
        let second = try await opened(editor)
        #expect(second.rewriteScope == .selection(range) && second.instruction == clear.instruction)
        // "Type your own…" sends the creator's words.
        editor.closeRewrite(returnFocus: false)
        editor.rewriteAs(text: "  Say it like a sports commentator  ", scope: .selection(range))
        let third = try await opened(editor)
        #expect(third.instruction == "Say it like a sports commentator")
        // The selection bar's first verb opens the strip; the old trailing Rewrite is gone.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let bar = try String(contentsOf: root.appendingPathComponent("Sources/VoxClip/SelectionBar.swift"), encoding: .utf8)
        #expect(bar.contains("voxclip.selectionBar.rewriteAs") && !bar.contains("model.runRewrite()"))
        #expect(bar.range(of: "voxclip.selectionBar.rewriteAs")!.lowerBound < bar.range(of: "voxclip.selectionBar.askClaude")!.lowerBound)
    }

    @Test func askClaudeRewordsTheAskedWordsAndKeepsEditsApart() async throws {
        let (shell, editor, _) = try await open(defaultTone: .tone("funny"))
        defer { editor.closeRewrite(returnFocus: false); editor.closeAskClaude(); editor.close() }
        shell.selection = .clip("five-2")
        let start = try #require(editor.activeClip.flatMap { editor.index($0.startWordId) })
        editor.selectedWordIDs = Set(editor.words[start...(start + 2)].map(\.id))
        editor.openAskClaudeOnSelection()
        #expect(editor.askClaude.selection != nil)
        #expect(AskClaudeState.placeholder == "Say what to change: reword it, bleep it, blur, add a title…")
        #expect(editor.askClaudeRewriteScope == .selection(start...(start + 2)))
        let quick = editor.askClaudeQuickTones
        #expect(quick.map(\.id) == ["funny", "fix-mistakes", "make-shorter", "punchy-reel"] && quick.first?.isDefault == true)
        // Tones never join the effect chips.
        let effects = Set(AskClaudeState.chips.map(\.label))
        #expect(editor.rewriteStripItems.allSatisfy { !effects.contains($0.title) })
        editor.rewriteAs(try #require(quick.first), scope: editor.askClaudeRewriteScope)
        let session = try await opened(editor)
        #expect(session.rewriteScope == .selection(start...(start + 2)) && session.instruction == quick.first?.instruction)
        // On a whole clip it rewords the clip.
        editor.closeRewrite(returnFocus: false)
        editor.openAskClaude(clip: "five-3")
        #expect(editor.askClaudeRewriteScope == .clip("five-3"))
    }

    @Test func aClipRowRewritesItsClipAndKeepsASuggestionFirst() async throws {
        let (shell, editor, _) = try await open()
        defer { editor.closeRewrite(returnFocus: false); editor.close() }
        let shorter = try #require(editor.rewriteStripItems.first { $0.id == "make-shorter" })
        #expect(shell.canRewriteExplorerClip("five-3"))
        shell.rewriteExplorerClip("five-3", as: shorter)
        let session = try await opened(editor)
        #expect(session.rewriteScope == .clip("five-3") && session.instruction == shorter.instruction)
        editor.closeRewrite(returnFocus: false)
        // A suggestion is kept first, then rewritten in the tone.
        let suggestion = try #require(editor.suggestedClips.first?.id)
        let viral = try viral(editor)
        shell.rewriteExplorerClip(suggestion, as: viral)
        let kept = try await opened(editor)
        #expect(!editor.isSuggestion(suggestion) && kept.rewriteScope == .clip(suggestion) && kept.instruction == viral.instruction)
    }

    @Test func savedTonesAreChipsAndSettingsRenameAndDeleteThem() async throws {
        let (shell, editor, app) = try await open()
        defer { editor.close() }
        shell.selection = .fullTake
        editor.rewriteInstruction = "Sound like my investor pitch: confident and specific."
        #expect(editor.canSaveFieldAsTone)
        let tone = try #require(editor.saveFieldAsTone("My pitch voice"))
        #expect(tone.id == "my-my-pitch-voice" && app.myRewriteTones == [tone])
        #expect(editor.rewriteStripItems.last?.id == tone.id && editor.rewriteStripItems.last?.kind == .saved)
        #expect(!editor.canSaveFieldAsTone, "the field is a chip now")
        // The card can choose it, and it becomes the default.
        editor.updateClipStyle { $0.tone = .tone(tone.id) }
        #expect(editor.rewriteStripItems.first?.id == tone.id)
        #expect(ClipStyleToneRow.label(.tone(tone.id), catalog: app.rewriteToneCatalog, saved: app.myRewriteTones) == "My pitch voice")
        // Settings › Clips renames it in place (the id stays) and deletes it; the card then reads Auto.
        #expect(app.renameRewriteTone(tone.id, to: "Pitch"))
        #expect(app.myRewriteTones.first?.title == "Pitch" && editor.rewriteStripItems.first?.title == "Pitch")
        let pane = NSHostingView(rootView: ClipsSettings(app: app))
        pane.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        pane.layoutSubtreeIfNeeded()
        app.deleteRewriteTone(tone.id)
        #expect(app.myRewriteTones.isEmpty && editor.rewriteStripItems.first?.id == "fix-mistakes")
        #expect(ClipStyleToneRow.label(.tone(tone.id), catalog: app.rewriteToneCatalog, saved: []) == "✦ Auto · Claude picks per clip")
        // A typed instruction is recorded as Recent; a tone's never is.
        app.noteRewriteInstruction(try viral(editor).instruction, for: editor.project.id)
        #expect(app.rewriteSuggestions(for: editor.project.id).allSatisfy { $0.asked != nil })
    }
}
#endif
