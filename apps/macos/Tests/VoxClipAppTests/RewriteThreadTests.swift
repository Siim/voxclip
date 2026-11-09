#if DEBUG
import AppKit
import Foundation
import Testing
@testable import VoxClipCore
@testable import VoxClip

/// Talk back to Claude about a change (design.md §6.3, ADR-R50), headless: the thread under the focused change of a real
/// Rewrite reply (`DebugRewrite.proposalScenes`' f3 clip: two cuts and a phrase in your voice), with a stub that records
/// each request and answers as scripted. Nothing is sent anywhere, voiced or paid.
@Suite("Rewrite thread", .serialized, .enabled(if: ProcessInfo.processInfo.environment["VOXCLIP_DATA_DIR"] != nil, "Use an isolated VOXCLIP_DATA_DIR for app-model tests; no windows are shown."), .offlineFixtures)
@MainActor struct RewriteThreadTests {
    /// The requests a stub saw and what it answers next.
    @MainActor final class Script {
        var requests: [RewriteFollowupRequest] = []
        var replies: [Result<RewriteFollowupReply, any Error>] = []
        /// Holds the next answer until `release`.
        var hold = false
        private var waiting: CheckedContinuation<Void, Never>?
        func release() { waiting?.resume(); waiting = nil }
        var backend: RewriteThreadBackend {
            RewriteThreadBackend { [self] request in
                requests.append(request)
                if hold {
                    await withTaskCancellationHandler {
                        await withCheckedContinuation { waiting = $0 }
                    } onCancel: { Task { @MainActor in self.release() } }
                    try Task.checkCancellation()
                }
                guard !replies.isEmpty else { throw LLMError.invalidOutput(reason: "no scripted reply") }
                return try replies.removeFirst().get()
            }
        }
    }

    private func scene(_ name: String = "r2-make-takes") throws -> (EditorModel, RewriteSession, Script, [DirectorScene]) {
        let app = AppModel(settingsStore: RegressionSettingsStore())
        let shared = try SharedResources.locate()
        let fixture = try DemoEditing.loadFixture(shared.root.appendingPathComponent("fixtures/projects/interview-take.voxclip"))
        let all = DebugRewrite.proposalScenes(app: app, fixture: fixture)
        let scene = try #require(all.first { $0.name == name })
        let editor = try #require(scene.editor)
        let session = try #require(editor.openRewrite)
        let script = Script()
        editor.rewriteThreadBackend = script.backend
        editor.announcements = []
        return (editor, session, script, all)
    }
    private func voiceOrdinal(_ editor: EditorModel) throws -> Int {
        try #require(editor.proposal?.changes.first { $0.kind == .voice }?.ordinal)
    }
    private func reply(_ text: String, note: String = "Changed it.", steps: [String] = []) -> Result<RewriteFollowupReply, any Error> {
        .success(RewriteFollowupReply(texts: [text], note: note, nextSteps: steps))
    }
    private func send(_ editor: EditorModel, _ message: String, kind: RewriteFollowupRequest.Kind = .reply) async {
        editor.sendRewriteThread(message, kind: kind)
        await editor.rewriteThread.task?.value
    }

    @Test func aThreadShowsOnlyUnderTheFocusedChangeAndStartsWithTheBubblesAndTheInput() throws {
        let (editor, _, _, scenes) = try scene()
        defer { scenes.forEach { $0.editor?.close() } }
        let focused = try #require(editor.proposalDisplay?.focused)
        let display = try #require(editor.rewriteThreadDisplay)
        #expect(display.ordinal == focused && display.turns.isEmpty && display.versionLine == "1 of 1" && display.steps.isEmpty)
        #expect(display.keep == "\u{2713} That's it, keep it" && display.steady == ["Shorter", "Closer to my words", "3 more versions"])
        #expect(display.costLine == "Free on your Claude plan" && display.label == "Talk to Claude about change \(focused)")
        // It follows the focus: one thread, the focused change's.
        editor.focusNextChange(1)
        let next = try #require(editor.proposalDisplay?.focused)
        #expect(next != focused && editor.rewriteThreadDisplay?.ordinal == next && editor.rewriteThreadSlot(editor.proposalDisplay)?.ordinal == next)
    }

    @Test func theRequestCarriesTheRecordedWordsEveryVersionAndEveryMessageInOrder() async throws {
        let (editor, session, script, scenes) = try scene()
        defer { scenes.forEach { $0.editor?.close() } }
        let ordinal = try voiceOrdinal(editor)
        editor.focusChange(ordinal)
        let first = editor.changeText(ordinal)
        script.replies = [reply("brand new words", steps: ["More suspense"]), reply("newer words still")]
        await send(editor, "It reads like I was happy about the scammer.")
        await send(editor, "More suspense")
        #expect(script.requests.count == 2)
        let last = try #require(script.requests.last)
        #expect(last.recorded == editor.recordedText(ordinal) && last.recorded == "word30" && last.ordinal == ordinal)
        #expect(last.versions == [first, "brand new words"], "every version so far, oldest first")
        #expect(last.messages == ["It reads like I was happy about the scammer.", "More suspense"], "every message, the newest last")
        #expect(last.scope == "clip" && last.language == "en" && last.source == session.source.filter { $0.kind == .word }.map(\.text).joined(separator: " "))
        // The rendered request holds them in that order (the shared vector pins the rendering).
        let prompt = try #require(editor.rewriteFollowupPrompt)
        let instruction = prompt.instruction(last)
        let positions = (last.versions + last.messages).compactMap { instruction.range(of: $0)?.lowerBound }
        #expect(positions.count == 4 && positions == positions.sorted())
    }

    @Test func aReplyBecomesTheNextVersionThroughTheLocalEditAndSwitchingSendsNothing() async throws {
        let (editor, session, script, scenes) = try scene()
        defer { scenes.forEach { $0.editor?.close() } }
        let undo = UndoManager(); undo.groupsByEvent = false; editor.undoManager = undo
        defer { editor.undoManager = nil }
        let ordinal = try voiceOrdinal(editor)
        editor.focusChange(ordinal)
        let first = editor.changeText(ordinal), before = editor.project
        script.replies = [reply("much fresher words")]
        await send(editor, "Make it fresher")
        #expect(editor.changeText(ordinal) == "much fresher words", "the reply is in the change's place")
        #expect(editor.proposal?[ordinal]?.parts.flatMap(\.newTokens).contains("much") == true, "rediffed as an edit")
        #expect(editor.rewriteThreadDisplay?.versionLine == "2 of 2" && editor.rewriteThreadDisplay?.turns.map(\.speaker) == [.you, .claude])
        #expect(session.changes.isEmpty == false && editor.project == before && !undo.canUndo)
        // ‹ back to version 1 and › forward again: the text follows, nothing is sent and no undo step is added.
        #expect(editor.switchRewriteThreadVersion(by: -1))
        #expect(editor.changeText(ordinal) == first && editor.rewriteThreadDisplay?.versionLine == "1 of 2")
        #expect(editor.switchRewriteThreadVersion(by: 1) && editor.changeText(ordinal) == "much fresher words")
        #expect(!editor.switchRewriteThreadVersion(by: 1), "no version after the last")
        #expect(script.requests.count == 1 && !undo.canUndo && editor.project == before)
    }

    @Test func aReplyWithTheSameWordsAddsNoVersionAndSaysSo() async throws {
        let (editor, _, script, scenes) = try scene()
        defer { scenes.forEach { $0.editor?.close() } }
        let ordinal = try voiceOrdinal(editor)
        editor.focusChange(ordinal)
        script.replies = [reply(editor.changeText(ordinal), note: "It already says that.")]
        await send(editor, "Is the sale clear?")
        let display = try #require(editor.rewriteThreadDisplay)
        #expect(display.versionLine == "1 of 1" && display.turns.last?.text == "Kept the words as they are. It already says that.")
    }

    @Test func threeMoreVersionsBecomeTheNextVersionsAndTheFirstShows() async throws {
        let (editor, _, script, scenes) = try scene()
        defer { scenes.forEach { $0.editor?.close() } }
        let ordinal = try voiceOrdinal(editor)
        editor.focusChange(ordinal)
        script.replies = [.success(RewriteFollowupReply(texts: ["first other", "second other", "third other"], note: "Three ways.", nextSteps: []))]
        editor.pressRewriteThreadBubble("3 more versions")
        await editor.rewriteThread.task?.value
        #expect(script.requests.first?.kind == .versions && script.requests.first?.messages == ["3 more versions"])
        #expect(editor.rewriteThreadDisplay?.versionLine == "2 of 4" && editor.changeText(ordinal) == "first other")
    }

    @Test func thatsItKeepItIsExactlyKeepAndUndoReturnsTheRecordedWords() async throws {
        let (editor, _, script, scenes) = try scene()
        defer { scenes.forEach { $0.editor?.close() } }
        let ordinal = try voiceOrdinal(editor)
        editor.focusChange(ordinal)
        script.replies = [reply("much fresher words")]
        await send(editor, "Make it fresher")
        editor.pressRewriteThreadBubble("\u{2713} That's it, keep it")
        #expect(editor.proposal?[ordinal]?.state == .kept && editor.announcements.last == "Kept change \(ordinal)")
        #expect(editor.proposal?.threads[ordinal] == nil && editor.rewriteThreadDisplay?.ordinal != ordinal, "the thread goes with the kept change")
        #expect(script.requests.count == 1, "keeping sends nothing")
        // On another change: talk, then Undo (⌘⌫ from the input) returns it to the recorded words.
        let (other, _, otherScript, otherScenes) = try scene()
        defer { otherScenes.forEach { $0.editor?.close() } }
        let voice = try voiceOrdinal(other)
        other.focusChange(voice)
        otherScript.replies = [reply("much fresher words")]
        await send(other, "Make it fresher")
        let input = RewriteThreadInputTextView(frame: .zero)
        input.model = other
        input.keyDown(with: key(51, .command))
        #expect(other.proposal?[voice]?.state == .excluded && other.proposal?.threads[voice] == nil)
        let runs = (other.proposalDisplay?.before.values.flatMap { $0 } ?? []) + (other.proposalDisplay?.after.values.flatMap { $0 } ?? [])
        #expect(!runs.contains { $0.mark.ordinal == voice }, "the recorded words show, no new words")
    }

    @Test func escFoldsTheThreadAndFocusingTheChangeAgainOpensIt() throws {
        let (editor, _, _, scenes) = try scene()
        defer { scenes.forEach { $0.editor?.close() } }
        let ordinal = try #require(editor.proposalDisplay?.focused)
        let input = RewriteThreadInputTextView(frame: .zero)
        input.model = editor
        input.keyDown(with: key(53))
        #expect(editor.rewriteThreadDisplay == nil && editor.rewriteThreadSlot(editor.proposalDisplay) == nil, "Esc folds it")
        #expect(editor.proposal?[ordinal]?.state == .pending, "the version stays in the text")
        editor.focusChange(ordinal)
        #expect(editor.rewriteThreadDisplay?.ordinal == ordinal, "focusing the change opens it again")
    }

    @Test func claudesBubblesComeOnlyFromItsLastReplyAndTheSteadyOnesAlwaysShow() async throws {
        let (editor, _, script, scenes) = try scene()
        defer { scenes.forEach { $0.editor?.close() } }
        let ordinal = try voiceOrdinal(editor)
        editor.focusChange(ordinal)
        #expect(editor.rewriteThreadDisplay?.steps == [])
        script.replies = [reply("one", steps: ["More suspense", "End on the bill", "A third"]), reply("two", steps: [])]
        await send(editor, "first")
        #expect(editor.rewriteThreadDisplay?.steps == ["More suspense", "End on the bill"], "at most two, from the last reply")
        // A ✦ bubble sends its words as your message.
        editor.pressRewriteThreadBubble("More suspense")
        await editor.rewriteThread.task?.value
        #expect(script.requests.last?.messages.last == "More suspense" && script.requests.last?.kind == .reply)
        #expect(editor.rewriteThreadDisplay?.steps == [], "the last reply had none")
        #expect(editor.rewriteThreadDisplay?.steady == ["Shorter", "Closer to my words", "3 more versions"])
    }

    @Test func anErrorKeepsTheTypedTextAndStopCancelsWithNothingChanged() async throws {
        let (editor, _, script, scenes) = try scene()
        defer { scenes.forEach { $0.editor?.close() } }
        let ordinal = try voiceOrdinal(editor)
        editor.focusChange(ordinal)
        let before = editor.proposal, text = editor.changeText(ordinal)
        editor.rewriteThread.follow(try #require(editor.rewriteThreadDisplay?.key))
        editor.rewriteThread.text = "Say the sale first"
        script.replies = [.failure(LLMError.timeout)]
        editor.sendRewriteThread(editor.rewriteThread.text, fromInput: true)
        await editor.rewriteThread.task?.value
        let error = try #require(editor.rewriteThreadDisplay?.error)
        #expect(error.contains("took too long") && editor.rewriteThread.text == "Say the sale first" && editor.changeText(ordinal) == text)
        #expect(editor.proposal == before, "an error changes nothing")
        // Try Again sends the same message.
        script.replies = [reply("the sale came first")]
        editor.retryRewriteThread()
        await editor.rewriteThread.task?.value
        #expect(script.requests.count == 2 && script.requests.last?.messages.last == "Say the sale first" && editor.rewriteThread.text.isEmpty)
        // Stop while Claude works: cancelled, nothing changed, the input keeps its text.
        let stopped = editor.proposal
        editor.rewriteThread.text = "Shorter please"
        script.hold = true
        script.replies = [reply("never shown")]
        editor.sendRewriteThread("Shorter please", fromInput: true)
        for _ in 0..<50 where script.requests.count < 3 { await Task.yield() }
        #expect(editor.rewriteThreadDisplay?.sending == true)
        editor.stopRewriteThread()
        await editor.rewriteThread.task?.value
        for _ in 0..<20 { await Task.yield() }
        #expect(editor.rewriteThreadDisplay?.sending == false && editor.proposal == stopped && editor.rewriteThread.text == "Shorter please")
        #expect(editor.changeText(ordinal) == "the sale came first")
    }

    @Test func nothingInTheThreadPricesVoicesOrPays() async throws {
        let (editor, session, script, scenes) = try scene()
        defer { scenes.forEach { $0.editor?.close() } }
        let ordinal = try voiceOrdinal(editor)
        editor.focusChange(ordinal)
        let before = editor.project, takePlan = session.takePlan, quote = session.takeQuotePhrase
        script.replies = [reply("fresh new words"), .success(RewriteFollowupReply(texts: ["a", "b", "c"], note: "", nextSteps: []))]
        await send(editor, "fresher")
        await send(editor, "3 more versions", kind: .versions)
        editor.switchRewriteThreadVersion(by: -1)
        #expect(editor.project == before && editor.project.voiceLab == before.voiceLab, "the project, its takes and its voice are untouched")
        #expect(session.takePlan === takePlan && session.takeQuotePhrase == quote && !session.hasPaidTakes, "no takes, quote or payment")
        #expect(editor.rewriteThreadDisplay?.phrasesLine == "\u{00B7} 1 phrase to voice at Keep", "Keep is where voicing starts")
    }

    @Test func theInputsKeys() async throws {
        let (editor, _, script, scenes) = try scene()
        defer { scenes.forEach { $0.editor?.close() } }
        let ordinal = try voiceOrdinal(editor)
        editor.focusChange(ordinal)
        let input = RewriteThreadInputTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 30))
        input.model = editor
        // ⇧↵ adds a line, ↵ sends.
        input.string = "line one"
        input.setSelectedRange(NSRange(location: 8, length: 0))
        input.keyDown(with: key(36, .shift, "\r"))
        #expect(input.string == "line one\n" && script.requests.isEmpty)
        script.replies = [reply("brand new words")]
        input.string = "Shorter"
        input.keyDown(with: key(36, [], "\r"))
        await editor.rewriteThread.task?.value
        #expect(script.requests.count == 1 && script.requests.first?.messages == ["Shorter"])
        // ⌥← and ⌥→ switch versions while the input is empty, and only then.
        input.string = "typing"
        input.keyDown(with: key(123, .option))
        #expect(editor.rewriteThreadDisplay?.versionLine == "2 of 2")
        input.string = ""
        input.keyDown(with: key(123, .option))
        #expect(editor.rewriteThreadDisplay?.versionLine == "1 of 2")
        input.keyDown(with: key(124, .option))
        #expect(editor.rewriteThreadDisplay?.versionLine == "2 of 2")
        // ⌘↩ keeps the change.
        input.keyDown(with: key(36, .command, "\r"))
        #expect(editor.proposal?[ordinal]?.state == .kept)
    }

    private func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags = [], _ characters: String = "") -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, characters: characters,
                         charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }
}
#endif
