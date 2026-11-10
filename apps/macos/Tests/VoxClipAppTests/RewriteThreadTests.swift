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
        // As the scenes were made: Voice Lab on, so the phrase in your voice can be reviewed and voiced at Keep.
        app.settings.values["voiceLab.enabled"] = .bool(true)
        app.settings.values["voiceLab.betaNoticeAccepted"] = .bool(true)
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

    /// The thread is in the text's flow: the paragraph keeps its height free under the change, at the text column, also
    /// when it is the last paragraph (the document grows), and Esc gives the room back.
    @Test func theThreadTakesRoomInTheTranscriptsFlowAndFoldingGivesItBack() throws {
        let (editor, _, _, scenes) = try scene()
        defer { scenes.forEach { $0.editor?.close() } }
        let pane = try TranscriptPane(model: editor, size: NSSize(width: 652, height: 900))
        defer { pane.close() }
        func used() -> Double { Double(pane.text.textLayoutManager?.usageBoundsForTextContainer.height ?? 0) }
        // The transcript as it reads with the thread folded, then with it open.
        let ordinal = try #require(editor.proposalDisplay?.focused)
        editor.foldRewriteThread()
        pane.update()
        let bare = used()
        editor.focusChange(ordinal)
        pane.update()
        pane.text.layoutThreadNow()
        pane.layout()
        let thread = try #require(pane.text.threadAuditView)
        let anchor = try #require(pane.renderer.threadAnchor)
        let line = try #require(pane.text.lineBox(atCharacter: anchor))
        #expect(thread.frame.minY >= line.maxY && abs(thread.frame.minX - pane.text.textContainerOrigin.x) < 0.5 && thread.frame.height > 60)
        #expect(used() >= bare + Double(thread.frame.height) - 1 && Double(pane.text.textContainerOrigin.y) + used() >= Double(thread.frame.maxY) - 1,
                "the text grows by the thread's height (\(bare) -> \(used()), thread \(thread.frame))")
        editor.foldRewriteThread()
        pane.update()
        #expect(!pane.text.threadVisible && pane.renderer.threadAnchor == nil && abs(used() - bare) < 1, "Esc gives the room back (\(used()))")
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
        #expect(session.reviewedVoiceOrdinals.contains(ordinal) && !session.hasEditedChanges, "Claude's version is the reply's words: voiced at Keep, not a hand edit")
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
        // A kept phrase in your voice still shows, waiting for its takes, and has no thread when focused again.
        editor.focusChange(ordinal)
        #expect(editor.proposalDisplay?.focused == ordinal && editor.rewriteThreadDisplay == nil && editor.rewriteThreadSlot(editor.proposalDisplay) == nil)
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

    /// The open Rewrite's own AI answers (no stand-in): `stub` behind a session that owns the scene's proposal.
    private func live(_ editor: EditorModel, _ stub: FollowupStub) throws {
        let proposal = try #require(editor.proposal)
        let session = RewriteSession(editor: editor, scope: .clip("r2-clip"), envelope: nil,
                                     connector: RewriteConnector(connector: stub, model: "sonnet", name: "Claude Code", group: "cli", plan: "Claude plan"))
        editor.openRewrite = session
        session.adopt(proposal)
        editor.rewriteThreadBackend = nil
    }
    private func until(_ done: () -> Bool) async {
        for _ in 0..<2_000 where !done() { await Task.yield() }
    }

    @Test func theLiveSendAsksInPlaceOnceWithTheRewriteConsentThenSends() async throws {
        let (editor, _, _, scenes) = try scene()
        defer { scenes.forEach { $0.editor?.close() } }
        let stub = FollowupStub(reply: #"{"text":"much fresher words","note":"Fresher now.","nextSteps":["End on the bill"]}"#)
        try live(editor, stub)
        let ordinal = try voiceOrdinal(editor)
        editor.focusChange(ordinal)
        #expect(editor.app.bool("llm.cloudConsent.claude-code") == false)
        editor.sendRewriteThread("Make it fresher")
        await until { editor.rewriteThread.confirmation.isPresented }
        let prompt = try #require(editor.rewriteThread.confirmation.prompt, "the confirmation shows in the thread, not a sheet")
        #expect(prompt.message.contains("Claude Code") && editor.rewriteThreadDisplay?.sending == true && editor.sendConfirmation.prompt == nil)
        let early = await stub.sent
        #expect(early.isEmpty, "nothing is sent before the click")
        editor.rewriteThread.confirmation.approve()
        await editor.rewriteThread.task?.value
        let sent = await stub.sent
        #expect(sent.count == 1 && sent.first?.tag == "rewrite-followup" && sent.first?.instruction.contains("Make it fresher") == true)
        #expect(editor.changeText(ordinal) == "much fresher words" && editor.rewriteThreadDisplay?.steps == ["End on the bill"])
        #expect(editor.app.bool("llm.cloudConsent.claude-code"), "asked once")
    }

    @Test func aReadinessProblemShowsRewritesCopyInPlace() async throws {
        let (editor, _, _, scenes) = try scene()
        defer { scenes.forEach { $0.editor?.close() } }
        let stub = FollowupStub(reply: "{}", status: .cliSignedOut)
        try live(editor, stub)
        let ordinal = try voiceOrdinal(editor)
        editor.focusChange(ordinal)
        let text = editor.changeText(ordinal)
        editor.rewriteThread.follow(try #require(editor.rewriteThreadDisplay?.key))
        editor.rewriteThread.text = "Make it fresher"
        editor.sendRewriteThread("Make it fresher", fromInput: true)
        await editor.rewriteThread.task?.value
        let sent = await stub.sent
        #expect(editor.rewriteThreadDisplay?.error == "Claude Code isn't signed in. Run `claude` in Terminal and sign in, then choose Try Again.")
        #expect(editor.rewriteThread.text == "Make it fresher" && editor.changeText(ordinal) == text && sent.isEmpty)
    }

    // MARK: Your own words

    private func input(_ editor: EditorModel, _ text: String) -> RewriteThreadInputTextView {
        let input = RewriteThreadInputTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 30))
        input.model = editor
        input.string = text
        editor.rewriteThread.text = text
        return input
    }

    /// "✎ My own words" fills the input with the version in the text; ↵ puts your words in place as a version, "your words",
    /// with no request, and they are this Rewrite's words: reviewed, priced and voiced at Keep (not a hand edit).
    @Test func myOwnWordsFillTheShownVersionAndReturnAddsAYourWordsVersionWithNoRequest() async throws {
        let (editor, session, script, scenes) = try scene()
        defer { scenes.forEach { $0.editor?.close() } }
        let ordinal = try voiceOrdinal(editor)
        editor.focusChange(ordinal)
        script.replies = [reply("much fresher words", steps: ["More suspense"])]
        await send(editor, "Make it fresher")
        let display = try #require(editor.rewriteThreadDisplay)
        #expect(display.ownWords == false && display.inputCostLine == "Free on your Claude plan")
        editor.rewriteThread.text = "a draft for Claude"
        let focus = editor.rewriteThread.focusRequest
        editor.pressRewriteThreadBubble("\u{270E} My own words")
        let own = try #require(editor.rewriteThreadDisplay)
        #expect(editor.rewriteThread.text == "much fresher words" && editor.rewriteThread.focusRequest == focus + 1, "the shown version, the keys in the input")
        #expect(own.ownWords && own.inputCostLine == "Free \u{00B7} nothing is sent")
        #expect(RewriteThreadInputField.placeholder(ownWords: true) == "Your exact words \u{00B7} \u{21B5} applies \u{00B7} Esc cancels")
        input(editor, "my very own sentence").keyDown(with: key(36, [], "\r"))
        #expect(script.requests.count == 1, "nothing is sent")
        #expect(editor.changeText(ordinal) == "my very own sentence")
        let after = try #require(editor.rewriteThreadDisplay)
        #expect(after.versionLine == "3 of 3" && after.yoursLine == "\u{00B7} your words" && !after.ownWords && after.steps.isEmpty)
        #expect(after.turns.last == RewriteThread.Turn(speaker: .yours, text: "my very own sentence"))
        #expect(editor.rewriteThread.text == "a draft for Claude", "Claude's draft comes back")
        #expect(session.reviewedVoiceOrdinals.contains(ordinal) && !session.hasEditedChanges, "your words are voiced at Keep, not a hand edit")
        #expect(session.changes[ordinal - 1].hunk.newTokens == ["my", "very", "own", "sentence"], "the voice is made from your text")
        // The arrows still reach Claude's versions, and the next request carries your words as a version, not a message.
        #expect(editor.switchRewriteThreadVersion(by: -1) && editor.rewriteThreadDisplay?.yoursLine == nil)
        #expect(editor.switchRewriteThreadVersion(by: 1) && editor.changeText(ordinal) == "my very own sentence")
        script.replies = [reply("their words, tightened")]
        await send(editor, "Tighter")
        let last = try #require(script.requests.last)
        #expect(last.versions.last == "my very own sentence" && last.messages == ["Make it fresher", "Tighter"])
        // Keep includes it for takes: no "Takes are made from the AI's words" dead end.
        #expect(editor.switchRewriteThreadVersion(by: -1) && editor.keepChange(ordinal))
        session.showProposal()
        let footer = session.task.footer
        #expect(session.reviewedVoiceOrdinals.contains(ordinal) && !session.hasEditedChanges)
        #expect(footer.note?.contains("Takes are made from the AI's words") != true && footer.primary != nil,
                "a step forward: \(footer.primary?.title ?? "none"), \(footer.note ?? "no note")")
    }

    /// Esc, or the bubble again, goes back to Claude with nothing changed; a second Esc folds the thread as before.
    @Test func escLeavesYourOwnWordsWithNothingChanged() throws {
        let (editor, _, script, scenes) = try scene()
        defer { scenes.forEach { $0.editor?.close() } }
        let ordinal = try voiceOrdinal(editor)
        editor.focusChange(ordinal)
        let before = editor.proposal, text = editor.changeText(ordinal)
        #expect(editor.openRewriteThreadOwnWords() && editor.rewriteThread.text == text)
        let field = input(editor, "words I will not keep")
        field.keyDown(with: key(53))
        #expect(editor.rewriteThread.ownWords == nil && editor.rewriteThread.text.isEmpty && editor.proposal == before && editor.changeText(ordinal) == text)
        #expect(editor.rewriteThreadDisplay?.ordinal == ordinal, "Esc leaves your words, not the thread")
        editor.pressRewriteThreadBubble("\u{270E} My own words")
        editor.rewriteThread.text = "other words"
        editor.pressRewriteThreadBubble("\u{270E} My own words")
        #expect(editor.rewriteThread.ownWords == nil && editor.proposal == before, "the bubble again leaves them too")
        field.keyDown(with: key(53))
        #expect(editor.rewriteThreadDisplay == nil && script.requests.isEmpty, "then Esc folds the thread")
    }

    /// As the edit popover did: an empty text makes the change a cut, and the recorded words leave nothing to change.
    @Test func emptyOwnWordsCutAndTheRecordedWordsLeaveNothingToChange() throws {
        let (editor, session, script, scenes) = try scene()
        defer { scenes.forEach { $0.editor?.close() } }
        let ordinal = try voiceOrdinal(editor)
        editor.focusChange(ordinal)
        #expect(editor.openRewriteThreadOwnWords())
        #expect(editor.applyRewriteThreadOwnWords(""))
        let change = try #require(editor.proposal?[ordinal])
        #expect(change.state == .pending && change.parts.allSatisfy { $0.kind == .cut } && !change.parts.isEmpty, "a cut of its words")
        #expect(editor.rewriteThreadDisplay?.turns.last == RewriteThread.Turn(speaker: .yours, text: "") && editor.rewriteThreadDisplay?.yoursLine != nil)
        #expect(session.changes[ordinal - 1].hunk.kind == .cut && !session.hasEditedChanges)
        // The recorded words: the change is left out, its thread with it.
        #expect(editor.openRewriteThreadOwnWords())
        #expect(editor.applyRewriteThreadOwnWords(editor.recordedText(ordinal)))
        #expect(editor.proposal?[ordinal]?.state == .excluded && editor.proposal?.threads[ordinal] == nil && editor.rewriteThread.ownWords == nil)
        #expect(script.requests.isEmpty)
    }

    @Test func theWordsAlreadyInTheTextChangeNothing() throws {
        let (editor, _, _, scenes) = try scene()
        defer { scenes.forEach { $0.editor?.close() } }
        let ordinal = try voiceOrdinal(editor)
        editor.focusChange(ordinal)
        let before = editor.proposal
        #expect(editor.openRewriteThreadOwnWords() && editor.applyRewriteThreadOwnWords(editor.changeText(ordinal) + " "))
        #expect(editor.proposal == before && editor.rewriteThreadDisplay?.versionLine == "1 of 1" && editor.rewriteThread.ownWords == nil)
    }

    // MARK: Paid takes: a version waits for the discard

    /// Paid takes on the scene's phrases, as the take fixtures make them; the voice change still waits, with its thread.
    private func payTakes(_ editor: EditorModel, _ session: RewriteSession, focus ordinal: Int) throws {
        try DebugRewriteGeneration.install("ready", in: session)
        session.showProposal()
        editor.focusChange(ordinal)
        #expect(session.hasPaidTakes && session.paidTakeCount > 0 && session.task.confirm == nil)
        #expect(editor.rewriteThreadDisplay?.ordinal == ordinal && editor.rewriteThreadDisplay?.waiting == nil, "a waiting change keeps its thread")
    }
    private func waitingLine(_ session: RewriteSession) -> String { RewriteThreadDisplay.waitingLine(takes: session.paidTakeCount) }

    /// With paid takes, Claude's version waits for the Rewrite panel's discard question, and the thread says so. Keep
    /// Working changes nothing and the line goes; Discard Changes puts the version in as any reply: "2 of 2", its turns
    /// and next steps, reviewed and voiced at Keep. The arrows wait the same way.
    @Test func claudesVersionWaitsForTheDiscardThenLandsInTheThreadOrChangesNothing() async throws {
        let (editor, session, script, scenes) = try scene()
        defer { scenes.forEach { $0.editor?.close() } }
        let ordinal = try voiceOrdinal(editor)
        editor.focusChange(ordinal)
        let first = editor.changeText(ordinal)
        try payTakes(editor, session, focus: ordinal)
        let takes = try #require(session.takePlan)
        script.replies = [reply("much fresher words", steps: ["More suspense"])]
        await send(editor, "Make it fresher")
        let waiting = try #require(editor.rewriteThreadDisplay)
        #expect(waiting.waiting == waitingLine(session) && waiting.waiting?.hasPrefix("Waiting: this replaces ") == true)
        #expect(waiting.error == nil && waiting.versionLine == "1 of 1" && waiting.turns.isEmpty && waiting.steps.isEmpty, "nothing in the thread yet")
        #expect(editor.changeText(ordinal) == first && session.takePlan === takes && session.hasPaidTakes, "nothing in the text, takes kept")
        let question = try #require(session.task.confirm)
        #expect(question.owner == editor.rewriteThread.waiting?.token && question.owner != nil)
        #expect(editor.lastAnnouncement == waitingLine(session))
        // Keep Working: nothing changes, and the thread shows the version in the text.
        question.cancel.perform()
        let declined = try #require(editor.rewriteThreadDisplay)
        #expect(declined.waiting == nil && declined.versionLine == "1 of 1" && declined.turns.isEmpty && declined.error == nil)
        #expect(editor.changeText(ordinal) == first && session.takePlan === takes)
        // Again, and Discard Changes: the version lands as any reply does.
        script.replies = [reply("much fresher words", steps: ["More suspense"])]
        await send(editor, "Make it fresher")
        #expect(editor.rewriteThreadDisplay?.waiting == waitingLine(session))
        try #require(session.task.confirm).confirm.perform()
        let landed = try #require(editor.rewriteThreadDisplay)
        #expect(editor.changeText(ordinal) == "much fresher words" && !session.hasPaidTakes && session.task.confirm == nil)
        #expect(landed.waiting == nil && landed.versionLine == "2 of 2" && landed.turns.map(\.speaker) == [.you, .claude] && landed.steps == ["More suspense"])
        #expect(session.reviewedVoiceOrdinals.contains(ordinal) && !session.hasEditedChanges, "Claude's words, voiced at Keep")
        #expect(editor.rewriteThread.waiting == nil)
        // The arrows wait too: ‹ with paid takes again, declined, then confirmed.
        try payTakes(editor, session, focus: ordinal)
        #expect(editor.switchRewriteThreadVersion(by: -1) && editor.rewriteThreadDisplay?.waiting != nil && editor.changeText(ordinal) == "much fresher words")
        try #require(session.task.confirm).cancel.perform()
        #expect(editor.rewriteThreadDisplay?.versionLine == "2 of 2" && editor.rewriteThreadDisplay?.waiting == nil)
        #expect(editor.switchRewriteThreadVersion(by: -1))
        try #require(session.task.confirm).confirm.perform()
        #expect(editor.changeText(ordinal) == first && editor.rewriteThreadDisplay?.versionLine == "1 of 2" && editor.rewriteThreadDisplay?.turns.count == 2)
    }

    /// With paid takes, your own words wait for the discard: the input keeps them, still your own words. Keep Working
    /// changes nothing and they stay typed; Discard Changes puts them in: "3 of 3 · your words", the "your own words"
    /// turn, Claude's steps gone, back to Claude.
    @Test func yourOwnWordsWaitForTheDiscardAndKeepWhatYouTyped() async throws {
        let (editor, session, script, scenes) = try scene()
        defer { scenes.forEach { $0.editor?.close() } }
        let ordinal = try voiceOrdinal(editor)
        editor.focusChange(ordinal)
        script.replies = [reply("much fresher words", steps: ["More suspense"])]
        await send(editor, "Make it fresher")
        try payTakes(editor, session, focus: ordinal)
        editor.rewriteThread.text = "a draft for Claude"
        editor.pressRewriteThreadBubble("\u{270E} My own words")
        let field = input(editor, "my very own sentence")
        field.keyDown(with: key(36, [], "\r"))
        let waiting = try #require(editor.rewriteThreadDisplay)
        #expect(waiting.waiting == waitingLine(session) && waiting.ownWords && editor.rewriteThread.text == "my very own sentence")
        #expect(waiting.versionLine == "2 of 2" && waiting.yoursLine == nil && waiting.steps == ["More suspense"] && editor.changeText(ordinal) == "much fresher words")
        // Keep Working: nothing changes, and what you typed stays in the input.
        try #require(session.task.confirm).cancel.perform()
        let declined = try #require(editor.rewriteThreadDisplay)
        #expect(declined.waiting == nil && declined.ownWords && editor.rewriteThread.text == "my very own sentence")
        #expect(declined.versionLine == "2 of 2" && editor.changeText(ordinal) == "much fresher words" && session.hasPaidTakes)
        // ↵ again, and Discard Changes.
        field.keyDown(with: key(36, [], "\r"))
        try #require(session.task.confirm).confirm.perform()
        let landed = try #require(editor.rewriteThreadDisplay)
        #expect(editor.changeText(ordinal) == "my very own sentence" && !session.hasPaidTakes && landed.waiting == nil)
        #expect(landed.versionLine == "3 of 3" && landed.yoursLine == "\u{00B7} your words" && landed.steps.isEmpty && !landed.ownWords)
        #expect(landed.turns.last == RewriteThread.Turn(speaker: .yours, text: "my very own sentence"))
        #expect(editor.rewriteThread.text == "a draft for Claude", "Claude's draft comes back")
        #expect(session.reviewedVoiceOrdinals.contains(ordinal) && !session.hasEditedChanges && script.requests.count == 1)
    }

    /// Only one version waits: a later one, Claude's or your own words, replaces it in the thread and in the panel's
    /// question, and only the last one goes in.
    @Test func aSecondVersionReplacesTheWaitingOne() async throws {
        let (editor, session, script, scenes) = try scene()
        defer { scenes.forEach { $0.editor?.close() } }
        let ordinal = try voiceOrdinal(editor)
        editor.focusChange(ordinal)
        try payTakes(editor, session, focus: ordinal)
        // Claude's version waits; your own words replace it.
        script.replies = [reply("much fresher words")]
        await send(editor, "Make it fresher")
        let claude = try #require(editor.rewriteThread.waiting)
        #expect(editor.openRewriteThreadOwnWords() && editor.applyRewriteThreadOwnWords("my very own sentence"))
        let own = try #require(editor.rewriteThread.waiting)
        #expect(own.token != claude.token && session.task.confirm?.owner == own.token && editor.rewriteThreadDisplay?.waiting != nil)
        try #require(session.task.confirm).confirm.perform()
        #expect(editor.changeText(ordinal) == "my very own sentence" && editor.rewriteThreadDisplay?.versionLine == "2 of 2")
        #expect(editor.rewriteThreadDisplay?.turns.map(\.speaker) == [.yours], "Claude's waiting version never landed")
        // Your own words wait; Claude's version replaces them.
        try payTakes(editor, session, focus: ordinal)
        #expect(editor.openRewriteThreadOwnWords() && editor.applyRewriteThreadOwnWords("other words of mine"))
        let mine = try #require(editor.rewriteThread.waiting)
        script.replies = [reply("much fresher words")]
        await send(editor, "Make it fresher")
        #expect(editor.rewriteThread.waiting?.token != mine.token && session.task.confirm?.owner == editor.rewriteThread.waiting?.token)
        try #require(session.task.confirm).confirm.perform()
        let landed = try #require(editor.rewriteThreadDisplay)
        #expect(editor.changeText(ordinal) == "much fresher words" && landed.versionLine == "3 of 3" && landed.yoursLine == nil)
        #expect(landed.turns.map(\.speaker) == [.you, .claude] && landed.waiting == nil && !editor.rewriteThread.text.contains("other words"))
    }

    /// ⌥E in the transcript opens the thread for your own words (↵ and F2 still open it for Claude); VoiceOver reads the
    /// bubble, the field and the transcript's action.
    @Test func optionEOpensYourOwnWordsAndVoiceOverNamesThem() throws {
        let (editor, _, _, scenes) = try scene()
        defer { scenes.forEach { $0.editor?.close() } }
        let ordinal = try voiceOrdinal(editor)
        editor.focusChange(ordinal)
        let pane = try TranscriptPane(model: editor, size: NSSize(width: 652, height: 900))
        defer { pane.close() }
        pane.text.keyDown(with: key(120))
        #expect(editor.rewriteThread.ownWords == nil, "F2 opens it for Claude")
        pane.text.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .option, timestamp: 0, windowNumber: 0, context: nil,
                                                  characters: "\u{00B4}", charactersIgnoringModifiers: "e", isARepeat: false, keyCode: 14)!)
        #expect(editor.rewriteThread.ownWords?.ordinal == ordinal && editor.rewriteThread.text == editor.changeText(ordinal))
        pane.update()
        pane.text.layoutThreadNow()
        pane.layout()
        let thread = try #require(pane.text.threadAuditView)
        thread.layoutSubtreeIfNeeded()
        func field(_ view: NSView) -> RewriteThreadInputTextView? {
            if let found = view as? RewriteThreadInputTextView { return found }
            return view.subviews.lazy.compactMap(field).first
        }
        let input = try #require(field(thread))
        #expect(input.accessibilityLabel() == "Your own words for change \(ordinal)" && input.ownWords && input.string == editor.changeText(ordinal))
        let bubble = RewriteThreadBubble(title: RewriteThreadDisplay.ownWordsBubble, kind: .own, identifier: "", selected: true) {}
        #expect(bubble.spokenLabel == "My own words")
        pane.text.configureAccessibilityActions()
        let actions = pane.text.accessibilityCustomActions()?.map(\.name) ?? []
        #expect(actions.contains("Type your own words for change \(ordinal)") && actions.contains("Talk to Claude about change \(ordinal)"))
    }

    private func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags = [], _ characters: String = "") -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, characters: characters,
                         charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }
}

/// Claude Code on a plan, answering every thread request with `reply`, or not ready.
private actor FollowupStub: LLMConnector {
    nonisolated let id: ConnectorID = .claudeCode
    let reply: String
    let readiness: ConnectorStatus
    private(set) var sent: [LLMRequest] = []
    init(reply: String, status: ConnectorStatus = .ready) { self.reply = reply; readiness = status }
    func status() -> ConnectorStatus { readiness }
    func knownCLIAuthMethod() async -> String? { "claude.ai" }
    func models(refresh: Bool) -> [LLMModel] { [LLMModel(id: "sonnet", name: "Sonnet", contextTokens: 200_000, source: .curated)] }
    func contextTokens(model: String) -> Int? { 200_000 }
    func send(_ request: LLMRequest, model: String) -> RawCompletion {
        sent.append(request)
        return RawCompletion(text: reply, model: model, stop: .complete)
    }
}
#endif
