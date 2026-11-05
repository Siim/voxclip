#if DEBUG
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import VoxClipCore
@testable import VoxClip

/// A Claude Code fake on a plan that answers Ask Claude with `reply`.
private actor AskFixtureConnector: LLMConnector {
    nonisolated let id: ConnectorID = .claudeCode
    let reply: String
    private(set) var requests: [LLMRequest] = []
    init(reply: String) { self.reply = reply }
    func status() -> ConnectorStatus { .ready }
    func knownCLIAuthMethod() async -> String? { "claude.ai" }
    func models(refresh: Bool) -> [LLMModel] { [LLMModel(id: "fixture-local", name: "Fixture", contextTokens: 128_000, source: .curated)] }
    func contextTokens(model: String) -> Int? { 128_000 }
    func send(_ request: LLMRequest, model: String) -> RawCompletion {
        requests.append(request)
        return RawCompletion(text: reply, model: model, stop: .complete)
    }
}

/// ✦ Ask Claude in the editor (design.md §6.8): the selection bar, a timeline range and the clip row open one inline
/// field; chips only fill it; the answer applies as one undo step; each row undoes alone and Undo all takes every row out.
/// Stub connectors only, settings in memory, nothing shown on screen.
@Suite("Ask Claude", .serialized, .offlineFixtures)
@MainActor struct AskClaudeAppTests {
    private static func op(_ kind: String, _ fields: [String: Any] = [:]) -> [String: Any] {
        var value: [String: Any] = ["kind": kind, "startWord": -1, "endWord": -1, "start": -1, "end": -1, "text": "", "target": "", "x": 0, "y": 0,
                                    "width": 0, "height": 0, "tracking": "", "position": "", "rate": 0, "scale": 0, "sound": "", "language": "",
                                    "choice": "", "reason": "\(kind) because it was asked"]
        for (key, field) in fields { value[key] = field }
        return value
    }
    private static func reply(_ ops: [[String: Any]]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: ["summary": "Done as asked.", "ops": ops]), as: UTF8.self)
    }

    private func open(reply: String = "{\"summary\":\"\",\"ops\":[]}") async throws -> (WorkspaceShell, EditorModel, AskFixtureConnector, UndoManager) {
        _ = NSApplication.shared
        let app = AppModel(settingsStore: RegressionSettingsStore())
        app.loadCatalogue()
        let fake = AskFixtureConnector(reply: reply)
        app.connectorOverride = { _ in fake }
        app.set("llm.connector", .string("claude-code"))
        app.connectorConsentOverride = { _, action, _ in #expect(action == .askClaude); return true }
        let shared = try SharedResources.locate()
        let base = try JSONProjectStore.decode(Data(contentsOf: shared.root.appendingPathComponent("fixtures/projects/interview-take.voxclip")))
        var project = try DebugExplorer.fiveQuestions(from: base)
        // A saved project's own id; effects promote it to v4, whose asset folders are named by it.
        project.id = "0d6f3a52-8a59-4c0e-9d1b-2f8e7c4a6b31"
        let shell = WorkspaceShell(app: app)
        await shell.attachForTesting(VoxClipDocument(project: project, demo: true), selection: .fullTake)
        let editor = try #require(shell.editor)
        editor.mediaResolved = true
        editor.refresh()
        let undo = UndoManager(); undo.groupsByEvent = false; editor.undoManager = undo
        return (shell, editor, fake, undo)
    }

    private func select(_ editor: EditorModel, _ range: ClosedRange<Int>) {
        editor.selectedWordIDs = Set(editor.words[range].map(\.id))
    }

    @Test func theSelectionBarOpensOneInlineFieldAndChipsOnlyFillIt() async throws {
        let (shell, editor, fake, _) = try await open()
        defer { editor.close() }
        select(editor, 2...5)
        #expect(editor.canAskClaude && editor.askClaudeWordSelection == AskClaudeSelection(scope: .words(2...5), clipID: nil))
        editor.openAskClaudeOnSelection()
        #expect(editor.askClaude.selection != nil && editor.askClaude.label.hasPrefix("\u{201C}"))
        #expect(PanelJob.available(in: editor).contains(.askClaude) && shell.panelJob(for: editor) == .askClaude)
        #expect(editor.askClaudeCostLine == "Free on your Claude plan")
        // Chips fill the field; nothing is sent until Return.
        editor.askClaude.text = AskClaudeState.chips[0].text
        #expect(editor.askClaude.text == "Bleep these words")
        #expect(await fake.requests.isEmpty)
        // An empty field sends nothing either.
        editor.askClaude.text = "   "
        editor.sendAskClaude()
        await editor.askClaude.task?.value
        #expect(await fake.requests.isEmpty)
        editor.closeAskClaude()
        #expect(!editor.askClaude.isOpen && !PanelJob.available(in: editor).contains(.askClaude))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VOXCLIP_DATA_DIR"] != nil, "Use an isolated VOXCLIP_DATA_DIR; only stub connectors are called."))
    func theAnswerAppliesAsOneUndoStepAndEachRowUndoesAlone() async throws {
        let ops = [Self.op("bleep", ["startWord": 3, "endWord": 4]), Self.op("title", ["text": "Day 1", "position": "top"]),
                   Self.op("sound", ["sound": "pop"]), Self.op("rewrite", ["startWord": 2, "endWord": 5, "text": "this is new"]),
                   Self.op("speed", ["rate": 1.5])]
        let (shell, editor, fake, undo) = try await open(reply: try Self.reply(ops))
        defer { editor.close() }
        select(editor, 2...5)
        editor.openAskClaudeOnSelection()
        editor.askClaude.text = "bleep the swear, add a title and a pop"
        let before = editor.project
        undo.beginUndoGrouping()
        editor.sendAskClaude()
        await editor.askClaude.task?.value
        undo.endUndoGrouping()
        let requests = await fake.requests
        #expect(requests.count == 1 && requests.first?.feature == .askClaude && requests.first?.effort == .xhigh)
        #expect(requests.first?.instruction.contains("Instruction: bleep the swear, add a title and a pop") == true)
        let run = try #require(editor.askClaude.run, "\(editor.askClaude.error ?? "no error")")
        #expect(editor.askClaude.error == nil && !editor.llmRuns.isBusy)
        #expect(run.rows.count == 5 && run.rows[0...2].allSatisfy { $0.status == .applied })
        #expect(priced(run.rows[3]).hasPrefix("Voice it \u{00B7} "), "\(run.rows[3].status)")
        #expect(run.rows[4].status == .later(EditorModel.laterReason(run.rows[4].operation)))
        #expect(editor.project.clipEffects.map(\.kind) == [.bleep, .title, .sound])
        #expect(run.appliedCount == 3 && shell.panelJob(for: editor) == .askClaude)
        // Paid rows wait for their click: nothing else was sent.
        #expect(await fake.requests.count == 1)

        // One undo step for the whole answer.
        undo.undo()
        #expect(editor.project.clipEffects.isEmpty && editor.project.edits == before.edits)
        undo.redo()
        #expect(editor.project.clipEffects.count == 3)

        // Undo one row: the others stay.
        undo.beginUndoGrouping()
        editor.undoAskClaudeRow(run.rows[1].id)
        undo.endUndoGrouping()
        #expect(editor.project.clipEffects.map(\.kind) == [.bleep, .sound] && run.rows[1].status == .undone)
        // Undo all: the rest, in one step.
        undo.beginUndoGrouping()
        editor.undoAllAskClaude()
        undo.endUndoGrouping()
        #expect(editor.project.clipEffects.isEmpty && run.appliedCount == 0)
        undo.undo()
        #expect(editor.project.clipEffects.map(\.kind) == [.bleep, .sound])
    }

    private func priced(_ row: AskClaudeRow) -> String { if case .paid(let price) = row.status { price } else { "" } }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VOXCLIP_DATA_DIR"] != nil, "Use an isolated VOXCLIP_DATA_DIR; only stub connectors are called."))
    func adjustNudgesTheRangeEditsTextAndMovesTheBoxAsUndoSteps() async throws {
        let ops = [Self.op("title", ["text": "Day 1", "position": "top"]), Self.op("blur", ["x": 0.1, "y": 0.1, "width": 0.2, "height": 0.2, "tracking": "none"])]
        let (_, editor, _, undo) = try await open(reply: try Self.reply(ops))
        defer { editor.close() }
        select(editor, 2...8)
        editor.openAskClaudeOnSelection()
        editor.askClaude.text = "title and blur"
        undo.beginUndoGrouping(); editor.sendAskClaude(); await editor.askClaude.task?.value; undo.endUndoGrouping()
        let run = try #require(editor.askClaude.run)
        let title = run.rows[0].id, blur = run.rows[1].id
        let start = try #require(editor.askClaudeEffect(title)?.start)
        undo.beginUndoGrouping(); editor.adjustAskClaudeEffect(title) { $0.start += 0.1 }; undo.endUndoGrouping()
        #expect(abs((editor.askClaudeEffect(title)?.start ?? 0) - (start + 0.1)) < 1e-9)
        undo.beginUndoGrouping(); editor.adjustAskClaudeEffect(title) { $0.text = "Day 2"; $0.position = .bottom }; undo.endUndoGrouping()
        #expect(editor.askClaudeEffect(title)?.text == "Day 2" && editor.askClaudeEffect(title)?.position == .bottom)
        editor.askClaude.adjusting = blur
        #expect(editor.askClaudeAdjustingRect?.id == blur)
        undo.beginUndoGrouping(); editor.adjustAskClaudeEffect(blur) { $0.rect?.x = 0.95 }; undo.endUndoGrouping()
        #expect(editor.askClaudeEffect(blur)?.rect == ClipEffect.Rect(x: 0.8, y: 0.1, width: 0.2, height: 0.2), "kept inside the frame")
        undo.undo()
        #expect(editor.askClaudeEffect(blur)?.rect?.x == 0.1)
        // The box on the viewer maps through the export crop.
        let frame = try #require(AskClaudeRectOverlay.frame(ClipEffect.Rect(x: 0.25, y: 0.25, width: 0.5, height: 0.5), project: editor.project, stage: CGSize(width: 320, height: 180)))
        #expect(abs(frame.midX - 160) < 0.5 && abs(frame.midY - 90) < 0.5)
        // The FX lane lists them with their names.
        #expect(editor.timelineEffects(on: .source).compactMap(\.label).sorted() == ["Blur", "Title"])
    }

    @Test func aTimelineRangeAndAClipRowOpenTheFieldToo() async throws {
        let (shell, editor, _, _) = try await open()
        defer { editor.close() }
        let words = editor.words
        editor.askClaude.timeRange = words[1].start...words[6].end
        editor.openAskClaudeOnTimeRange()
        guard case .time(let range)? = editor.askClaude.selection?.scope else { Issue.record("No time range"); return }
        #expect(range.lowerBound == words[1].start && editor.askClaude.label.contains("\u{2013}"))
        let clip = try #require(editor.project.edits.clips.first)
        shell.choose(.clip(clip.id), byClick: false)
        editor.openAskClaude(clip: clip.id)
        #expect(editor.askClaude.selection == AskClaudeSelection(scope: .clip(clip.id), clipID: clip.id))
        #expect(editor.askClaude.label == "Clip \(editor.clipNumber(clip.id) ?? 0)")
    }

    @Test func aReadOnlyOrAIlessEditorOffersNoAskClaude() async throws {
        let (_, editor, _, _) = try await open()
        defer { editor.close() }
        editor.app.set("llm.connector", .string(""))
        select(editor, 2...5)
        #expect(!editor.canAskClaude)
        editor.openAskClaudeOnSelection()
        #expect(editor.askClaude.selection == nil)
    }
}
#endif
