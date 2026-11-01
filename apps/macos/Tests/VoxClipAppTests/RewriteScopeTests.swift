#if DEBUG
import AppKit
import Foundation
import Testing
@_spi(Testing) @testable import VoxClipCore
@testable import VoxClip

/// A stub connector for Rewrite: a selection's passage request gets "A clearer passage"; a clip's or Full take's
/// `patch_edits` request gets the edits `reply` builds from the request's own lines. It records each request and, with
/// `hold`, waits for `release()` before answering. Nothing leaves the Mac.
private actor ScopeStub: LLMConnector {
    typealias Edit = (line: String, text: String, reason: String)
    nonisolated let id: ConnectorID
    private let authMethod: String?
    private let hold: Bool
    private let reply: @Sendable ([RewriteFixtureReply.Line]) -> [Edit]
    private var waiting: CheckedContinuation<Void, Never>?
    private(set) var requests: [LLMRequest] = []
    init(id: ConnectorID = .ollama, authMethod: String? = nil, hold: Bool = false,
         reply: @escaping @Sendable ([RewriteFixtureReply.Line]) -> [Edit] = ScopeStub.cutFirstWord) {
        self.id = id; self.authMethod = authMethod; self.hold = hold; self.reply = reply
    }
    /// The fixture's default: cut the first word of the first line.
    static let cutFirstWord: @Sendable ([RewriteFixtureReply.Line]) -> [Edit] = { lines in
        lines.first.map { [($0.label, $0.words.dropFirst().joined(separator: " "), "Cut a slip")] } ?? []
    }
    func status() -> ConnectorStatus { .ready }
    func knownCLIAuthMethod() -> String? { authMethod }
    func models(refresh: Bool) -> [LLMModel] { [LLMModel(id: "fixture-local", name: "Fixture", contextTokens: 128_000, source: .curated)] }
    func contextTokens(model: String) -> Int? { 128_000 }
    func send(_ request: LLMRequest, model: String) async throws -> RawCompletion {
        requests.append(request)
        if hold { await withCheckedContinuation { waiting = $0 } }
        let text = request.tag == "patch-rewrite" ? RewriteFixtureReply.patch(reply(RewriteFixtureReply.lines(of: request))) : "{\"rewrite\":\"A clearer passage\"}"
        return RawCompletion(text: text, model: model, stop: .complete)
    }
    var isWaiting: Bool { waiting != nil }
    func release() { waiting?.resume(); waiting = nil }
}

/// The sheets a run's route showed, answered yes.
@MainActor private final class Sheets {
    var shown: [LLMSendSheet] = []
    func take() -> [LLMSendSheet.Reason] { defer { shown = [] }; return shown.map(\.reason) }
}

/// `RewriteSession` takes a scope (impl-plan V13, plan M7): a clip and Full take through C1's plan, `PatchRewriteService`
/// and C2's diff, a selection through `VoiceRewriteService`; the free changes as one undo step; R3 and the way back; the
/// send's confirmation on an API key only; Edit › Rewrite {scope}; the Ask suggestions; and no Voice Lab gate. Stub
/// connectors and in-memory settings only; the app model never starts.
@Suite("Rewrite takes a scope", .serialized, .enabled(if: ProcessInfo.processInfo.environment["VOXCLIP_DATA_DIR"] != nil, "Use an isolated VOXCLIP_DATA_DIR for app-model tests; only stub connectors are called."))
@MainActor struct RewriteScopeTests {
    /// An app whose AI is `connector` on the stub, with every sheet answered yes and logged.
    private func app(_ connector: String, stub: ScopeStub) -> (AppModel, Sheets) {
        let app = AppModel(settingsStore: RegressionSettingsStore())
        app.connectorOverride = { _ in stub }
        app.providerKeyStoreOverride = DirectorFixtureKeys()
        let sheets = Sheets()
        app.connectorConsentOverride = { _, _, sheet in sheets.shown.append(sheet); return true }
        app.settings.values["llm.connector"] = .string(connector)
        app.settings.values["llm.model.\(connector)"] = .string("fixture-local")
        app.settings.values["voiceLab.enabled"] = .bool(false)
        return (app, sheets)
    }
    /// A take of `count` words one second apart ("word{i}", a sentence ending at every 20th), with clip 1 over words
    /// 10–45 and clip 2 over 50–70, open on `tab`.
    private func editor(_ app: AppModel, words count: Int = 80, tab: String? = "c1", waveform: Bool = true, events: Set<Int> = []) throws -> (EditorModel, UndoManager) {
        let shared = try SharedResources.locate()
        var project = try DemoEditing.loadFixture(shared.root.appendingPathComponent("fixtures/projects/interview-take.voxclip"))
        project.id = UUID().uuidString.lowercased()
        project.edits = ProjectEdits()
        project.transcript?.words = (0..<count).map { index in
            TimedWord(id: "w\(index)", text: index % 20 == 19 ? "word\(index)." : "word\(index)", start: Double(index) + 1, end: Double(index) + 1.4)
        }
        for index in events { project.transcript?.words[index].kind = .event; project.transcript?.words[index].text = "[laughter]" }
        project.transcript?.durationSeconds = Double(count) + 2
        project.media.source.durationSeconds = Double(count) + 2
        if count > 70 {
            project.edits.clips = [ClipRange(id: "c1", startWordId: "w10", endWordId: "w45"), ClipRange(id: "c2", startWordId: "w50", endWordId: "w70")]
            project.edits.activeClipId = tab
        }
        let editor = EditorModel(document: VoxClipDocument(project: project), app: app, preview: DemoPreviewEngine())
        editor.mediaResolved = true; editor.refresh()
        if waveform { editor.waveform = WaveformData(fine: Array(repeating: 0.01, count: 20_000)) }
        let undo = UndoManager()
        undo.groupsByEvent = false
        editor.undoManager = undo
        return (editor, undo)
    }
    /// ⇧⌘R on the scope now, waiting for its run.
    private func rewrite(_ editor: EditorModel) async throws -> RewriteSession {
        editor.runRewrite()
        await editor.rewriteOpenTask?.value
        let session = try #require(editor.openRewrite)
        await session.actionTask?.value
        return session
    }
    private func step(_ undo: UndoManager, _ action: () -> Void) { undo.beginUndoGrouping(); action(); undo.endUndoGrouping() }
    private func proposal(_ session: RewriteSession) -> ChangeSet? { if case .proposal(let set) = session.task.state { set } else { nil } }
    private func texts(_ task: DirectorTask) -> [String] { task.cards.compactMap { if case .text(let text) = $0 { text } else { nil } } }

    // MARK: A clip, Full take and a selection

    /// A clip with no selection: the plan's lines are the clip's, the reply's cut, fix and phrase are the proposal in
    /// transcript order, and Apply applies the free two as one undo step named "Rewrite clip 1".
    @Test func aClipRewritesThroughThePlanAndAppliesItsFreeChangesAsOneStep() async throws {
        let stub = ScopeStub { lines in
            lines.compactMap { line -> ScopeStub.Edit? in
                switch line.label {
                case "[10-19]": (line.label, line.words.dropFirst().joined(separator: " "), "Cut a slip")
                case "[20-39]": (line.label, line.words.map { $0 == "word25" ? "Word25" : $0 == "word30" ? "thirty" : $0 }.joined(separator: " "), "Fix")
                default: nil
                }
            }
        }
        let (app, sheets) = app("ollama", stub: stub)
        let (editor, undo) = try editor(app)
        defer { editor.close() }
        let session = try await rewrite(editor)
        #expect(session.rewriteScope == .clip("c1") && session.task.words == DirectorScope(kind: .clip(number: 1), wordCount: 36))
        let request = try #require(await stub.requests.first)
        #expect(await stub.requests.count == 1 && request.tag == "patch-rewrite" && sheets.take().isEmpty)
        #expect(RewriteFixtureReply.lines(of: request).map(\.label) == ["[10-19]", "[20-39]", "[40-45]"])
        #expect(request.instruction.hasSuffix("Instruction: Fix slips and repeats. Keep my words and my voice; change as little as possible."))
        let set = try #require(proposal(session))
        #expect(set.items.map(\.kind) == [.cut, .fix, .voice] && set.items.map(\.ordinal) == [1, 2, 3])
        #expect(set.items.map(\.sourceWordIDs) == [["w10"], ["w25"], ["w30"]] && set.items.map(\.newWords) == [[], ["Word25"], ["thirty"]])
        #expect(session.task.headline == PanelHeadline(text: "3 changes", sub: "1 cut · 1 fix · 1 phrase in your voice"))
        #expect(editor.announcements == ["Rewriting clip 1", "3 changes proposed. 1 needs your voice."])
        #expect(session.applyTitle == "Apply 2 Free Changes")
        let before = editor.project
        step(undo) { #expect(session.applyFreeChanges()) }
        #expect(undo.undoActionName == "Rewrite clip 1" && editor.undoSteps == 1)
        #expect(editor.cutWordIDs.contains("w10") && editor.project.edits.corrections["w25"] == "Word25" && editor.project.edits.corrections["w30"] == nil)
        #expect(!session.isOpen && editor.openRewrite == nil && editor.announcements.last == "Applied 2 changes" && editor.selectedWordIDs == ["w10"])
        undo.undo()
        #expect(editor.project.edits == before.edits && !undo.canUndo)
    }

    /// Full take reads every kept word, and its Apply is named "Rewrite full take". Over 3,000 entries the plan refuses
    /// before anything is sent: R1x names the count and offers Find Clips.
    @Test func aFullTakeRewritesEveryKeptWordAndRefusesOverTheLimit() async throws {
        let stub = ScopeStub()
        let (app, _) = app("ollama", stub: stub)
        let (editor, undo) = try editor(app, tab: nil)
        defer { editor.close() }
        step(undo) { editor.apply(.cutSelection(ids: ["w3"]), name: "Cut selection") }
        let session = try await rewrite(editor)
        #expect(session.rewriteScope == .fullTake && session.task.words == DirectorScope(kind: .fullTake, wordCount: 79))
        let request = try #require(await stub.requests.first)
        // A cut word ends its line (C1): the take's first line stops before w3, and no line sends it.
        let lines = RewriteFixtureReply.lines(of: request)
        #expect(lines.first?.label == "[0-2]" && lines.first?.words == ["word0", "word1", "word2"])
        #expect(!lines.contains { $0.words.contains("word3") } && lines.last?.words.last == "word79.")
        let set = try #require(proposal(session))
        #expect(set.items.map(\.sourceWordIDs) == [["w0"]])
        step(undo) { #expect(session.applyFreeChanges()) }
        #expect(undo.undoActionName == "Rewrite full take" && editor.cutWordIDs.isSuperset(of: ["w0", "w3"]))

        let longStub = ScopeStub()
        let (longApp, _) = self.app("ollama", stub: longStub)
        let (long, _) = try self.editor(longApp, words: 3_100, tab: nil, waveform: false)
        defer { long.close() }
        let connector = RewriteConnector(connector: longStub, model: "fixture-local", name: "Ollama", group: "local", plan: "")
        let tooLong = RewriteSession(editor: long, scope: .fullTake, envelope: nil, connector: connector, consent: { true })
        long.rewrite = tooLong
        #expect(await tooLong.run() == false)
        #expect(tooLong.task.state == .error(.tooManyEntries(count: 3_100)) && tooLong.task.headline.text == "Full take is too long to rewrite at once")
        #expect(texts(tooLong.task) == ["Rewrite works on up to 3,000 words at a time. This video has 3,100. Choose a clip or select a passage."])
        #expect(tooLong.task.footer.primary?.title == "Find Clips" && !long.llmRuns.isBusy)
        #expect(await longStub.requests.isEmpty)
    }

    /// A selection goes through `VoiceRewriteService`, as before: "Rewrite 3 words", the passage reply diffed against its
    /// words.
    @Test func aSelectionRewritesThroughThePassageService() async throws {
        let stub = ScopeStub()
        let (app, _) = app("ollama", stub: stub)
        let (editor, _) = try editor(app)
        defer { editor.close() }
        editor.selectedWordIDs = ["w12", "w13", "w14"]
        let session = try await rewrite(editor)
        #expect(session.rewriteScope == .selection(12...14) && session.scope == .clip("c1"))
        #expect(session.task.words == DirectorScope(kind: .selection(inClip: true), wordCount: 3) && session.task.words.title == "Rewrite 3 words")
        #expect(await stub.requests.map(\.tag) == ["voice-rewrite"])
        let set = try #require(proposal(session))
        #expect(!set.items.isEmpty && set.items.allSatisfy { $0.sourceWordIDs.allSatisfy { ["w12", "w13", "w14"].contains($0) } })
    }

    /// A clip whose every word is cut has nothing to send: R1x says so, and nothing is sent.
    @Test func aClipWithEveryWordCutSaysSo() async throws {
        let stub = ScopeStub()
        let (app, _) = app("ollama", stub: stub)
        let (editor, undo) = try editor(app)
        defer { editor.close() }
        step(undo) { editor.apply(.cutSelection(ids: (10...45).map { "w\($0)" }), name: "Cut selection") }
        let session = try await rewrite(editor)
        #expect(session.task.state == .error(.message("Clip 1 has no words left to rewrite. Your edits are saved.")))
        #expect(await stub.requests.isEmpty)
    }

    /// A change reads its removed words in transcript order, with the event a phrase in your voice absorbs.
    @Test func aChangeListsTheEventsItAbsorbsAmongItsRemovedWords() async throws {
        let stub = ScopeStub()
        let (app, _) = app("ollama", stub: stub)
        let (editor, _) = try editor(app, events: [11])
        defer { editor.close() }
        editor.selectedWordIDs = ["w10", "w11", "w12", "w13"]
        let session = try await rewrite(editor)
        let set = try #require(proposal(session))
        #expect(set.items.map(\.oldWords) == [["word10", "[laughter]", "word12", "word13"]])
        #expect(set.items.first?.sourceWordIDs.contains("w11") == false)
    }

    // MARK: R3

    /// design.md R3: an edit outside the clip moves the proposal on; one inside shows "Clip 1 changed", announced, with
    /// Close and Rewrite Again; undoing back shows the proposal again with its inclusions; Rewrite Again runs again.
    @Test func anEditInTheScopeShowsR3AndUndoReturnsToTheProposal() async throws {
        let stub = ScopeStub()
        let (app, _) = app("ollama", stub: stub)
        let (editor, undo) = try editor(app)
        defer { editor.close() }
        let session = try await rewrite(editor)
        var set = try #require(proposal(session))
        set.items[0].included = false
        session.task.show(.proposal(set), headline: session.task.headline)
        step(undo) { editor.apply(.cutSelection(ids: ["w60"]), name: "Cut selection") }
        #expect(proposal(session) == set && session.current && session.project == editor.project)
        step(undo) { editor.apply(.cutSelection(ids: ["w20"]), name: "Cut selection") }
        let task = session.task
        #expect(session.isOpen && task.state == .changed && !session.current && session.applyTitle == nil)
        #expect(task.headline.text == "Clip 1 changed" && editor.announcements.contains("Clip 1 changed."))
        #expect(texts(task) == ["You edited clip 1, so these changes may no longer fit. Nothing was applied, and no takes were paid for."])
        #expect(task.footer.link?.title == "Close" && task.footer.primary?.title == "Rewrite Again" && task.footer.note == "Runs on this Mac. Nothing leaves it.")
        // Another edit inside it keeps R3; undoing both shows the proposal as it was, inclusions kept.
        step(undo) { editor.apply(.cutSelection(ids: ["w21"]), name: "Cut selection") }
        #expect(task.state == .changed)
        undo.undo()
        #expect(task.state == .changed)
        undo.undo()
        #expect(proposal(session) == set && session.current)
        step(undo) { editor.apply(.cutSelection(ids: ["w20"]), name: "Cut selection") }
        task.footer.primary?.perform()
        await session.actionTask?.value
        #expect(proposal(session) != nil && session.task.turn == 2 && session.project == editor.project)
        #expect(await stub.requests.count == 2)
    }

    /// An edit inside the scope while R1 runs stops it: nothing is applied and the late reply changes nothing.
    @Test func anEditInTheScopeWhileItRunsStopsTheRun() async throws {
        let stub = ScopeStub(hold: true)
        let (app, _) = app("ollama", stub: stub)
        let (editor, undo) = try editor(app)
        defer { editor.close() }
        editor.runRewrite()
        await editor.rewriteOpenTask?.value
        let session = try #require(editor.openRewrite)
        for _ in 0..<2_000 where !(await stub.isWaiting) { await Task.yield() }
        #expect(session.task.state == .running)
        step(undo) { editor.apply(.cutSelection(ids: ["w30"]), name: "Cut selection") }
        #expect(session.task.state == .changed && session.task.headline.text == "Clip 1 changed")
        await stub.release()
        #expect(await session.sending?.value == false)
        #expect(session.task.state == .changed && session.changes.isEmpty && !editor.llmRuns.isBusy)
        undo.undo()
        #expect(session.task.state == .changed, "no proposal to go back to")
    }

    // MARK: The send's confirmation

    struct Route: Sendable, CustomTestStringConvertible {
        let connector: String
        let authMethod: String?
        let first: [LLMSendSheet.Reason]
        let later: [LLMSendSheet.Reason]
        let title: String
        let note: String
        var testDescription: String { connector }
    }
    nonisolated static let routes: [Route] = [
        Route(connector: "anthropic", authMethod: nil, first: [.privacy, .cost], later: [.cost], title: "Rewrite Clip 1…",
              note: "Sends the 36 words of clip 1 to Anthropic with your key."),
        Route(connector: "claude-code", authMethod: "claude.ai", first: [.privacy], later: [], title: "Rewrite Clip 1",
              note: "Sends the 36 words of clip 1 to Claude Code with your sign-in. Counts toward your Claude plan."),
        Route(connector: "ollama", authMethod: nil, first: [], later: [], title: "Rewrite Clip 1", note: "Runs on this Mac. Nothing leaves it."),
    ]

    /// Only a send on an API key confirms, every time, and the sheet names the clip (design.md R0b); the menu reads
    /// "Rewrite Clip 1…" for it. A CLI on a plan asks only the one-time privacy consent; a local model nothing.
    @Test(arguments: routes)
    func onlyAnAPIKeySendConfirms(_ route: Route) async throws {
        let stub = ScopeStub(id: try #require(ConnectorID(rawValue: route.connector)), authMethod: route.authMethod)
        let (app, sheets) = app(route.connector, stub: stub)
        let (editor, _) = try editor(app)
        defer { editor.close() }
        let session = try await rewrite(editor)
        #expect(proposal(session) != nil)
        let cost = sheets.shown.first { $0.reason == .cost }
        #expect(sheets.take() == route.first)
        if route.first.contains(.cost) {
            #expect(cost == LLMSendSheet(reason: .cost, title: "Rewrite clip 1?",
                message: "Sends the 36 words of clip 1 to Anthropic with your key.\n\nVoxClip can't tell what this costs. Check Anthropic's pricing.", confirm: "Rewrite"))
        }
        #expect(session.sendLine == route.note && editor.rewriteMenuTitle == route.title)
        #expect(session.proposalButton == (route.first.contains(.cost) ? "Rewrite…" : "Rewrite"))
        _ = try await rewrite(editor)
        #expect(sheets.take() == route.later)
        #expect(await stub.requests.count == 2)
    }

    // MARK: Entry

    /// Edit › Rewrite {scope} (design.md §8) and the scope ⇧⌘R takes: the selection, else the tab's clip (a suggestion
    /// too), else Full take.
    @Test func theScopeAndTheMenuTitleFollowTheEditor() async throws {
        let (app, _) = app("ollama", stub: ScopeStub())
        let (editor, undo) = try editor(app)
        defer { editor.close() }
        #expect(editor.rewriteScopeNow == .clip("c1") && editor.rewriteMenuTitle == "Rewrite Clip 1")
        editor.selectedWordIDs = ["w30", "w31"]
        #expect(editor.rewriteScopeNow == .selection(30...31) && editor.rewriteMenuTitle == "Rewrite Selection")
        editor.selectedWordIDs = []
        #expect(editor.setScope("c2") && editor.rewriteScopeNow == .clip("c2") && editor.rewriteMenuTitle == "Rewrite Clip 2")
        var project = editor.project
        project.edits.clips[1].origin = .ai
        project.edits.clips[1].selected = false
        step(undo) { editor.replace(project, name: "Suggest") }
        #expect(editor.isSuggestion("c2") && editor.rewriteMenuTitle == "Rewrite Clip 2")
        #expect(editor.setScope(nil) && editor.rewriteScopeNow == .fullTake && editor.rewriteMenuTitle == "Rewrite Full Take")
        #expect(editor.mutationEnabled(38) == true)
        editor.mediaResolved = false
        #expect(editor.mutationEnabled(38) == false)
    }

    /// Text Rewrite needs no Voice Lab (design.md §8): with it off, the menu, ⇧⌘R and the panel all work.
    @Test func textRewriteNeedsNoVoiceLab() async throws {
        let stub = ScopeStub()
        let (app, _) = app("ollama", stub: stub)
        let (editor, _) = try editor(app)
        defer { editor.close() }
        #expect(!app.bool("voiceLab.enabled") && !app.voiceLabRewriteEnabled && editor.mutationEnabled(38) == true)
        let session = try await rewrite(editor)
        #expect(proposal(session) != nil && editor.panelRewrite === session && session.current)
        #expect(!session.generationIsCurrent(region: .default))
    }

    // MARK: Ask

    /// design.md §6.3.1's suggestions: the four presets, then the project's last three distinct typed instructions, most
    /// recent first. An empty field asks Fix mistakes; a preset's title sends its instruction and R1 quotes it.
    @Test func askSuggestionsAndWhatTheySend() async throws {
        #expect(RewriteSuggestions.list(recent: []).map(\.menuTitle) == ["Fix mistakes", "Make it clearer", "Make it shorter", "Fix grammar and punctuation only"])
        #expect(RewriteSuggestions.suggestion(for: "  ") == RewriteSuggestions.fixMistakes)
        #expect(RewriteSuggestions.suggestion(for: "make it SHORTER").instruction == "Make it shorter, mostly by cutting. Keep my words and my voice.")
        #expect(RewriteSuggestions.suggestion(for: "I said 2024; it's 2025") == RewriteSuggestion(title: "I said 2024; it's 2025", instruction: "I said 2024; it's 2025", asked: nil))
        var recent: [String] = []
        for text in ["one", "two", "Make it clearer", "", "three", "one", "four"] { recent = RewriteSuggestions.noting(text, in: recent) }
        #expect(recent == ["four", "one", "three"])
        #expect(RewriteSuggestions.list(recent: recent).suffix(3).map(\.menuTitle) == ["Recent: “four”", "Recent: “one”", "Recent: “three”"])

        let stub = ScopeStub(hold: true)
        let (app, _) = app("ollama", stub: stub)
        let (editor, _) = try editor(app)
        defer { editor.close() }
        editor.rewriteInstruction = "Make it clearer"
        editor.runRewrite()
        await editor.rewriteOpenTask?.value
        let session = try #require(editor.openRewrite)
        for _ in 0..<2_000 where !(await stub.isWaiting) { await Task.yield() }
        #expect(session.task.cards.first == .asked(preset: "Make it clearer", text: "keep my words where they work, change as little as possible."))
        let request = try #require(await stub.requests.first)
        #expect(request.instruction.hasSuffix("Instruction: Make it clearer. Keep my words where they work; change as little as possible."))
        await stub.release()
        await session.actionTask?.value
        // A preset is always offered, so it is not recorded; a typed instruction is.
        #expect(app.rewriteSuggestions(for: editor.project.id).count == 4)
        editor.rewriteInstruction = "Shorter intro"
        let again = Task { _ = try? await rewrite(editor) }
        for _ in 0..<2_000 where !(await stub.isWaiting) { await Task.yield() }
        await stub.release()
        await again.value
        #expect(app.rewriteSuggestions(for: editor.project.id).map(\.menuTitle).last == "Recent: “Shorter intro”")
        #expect(app.rewriteSuggestions(for: UUID().uuidString).count == 4, "recents belong to their project")
    }
}
#endif
