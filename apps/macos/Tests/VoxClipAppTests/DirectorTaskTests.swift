#if DEBUG
import AppKit
import Foundation
import SwiftUI
import Synchronization
import Testing
@_spi(Testing) @testable import VoxClipCore
@testable import VoxClip

/// A stub connector whose readiness, sign-in and answer a test sets. With `hold` its send
/// waits for `release()`, and `untilWaiting()` returns once it does. Nothing leaves the Mac.
private actor StubConnector: LLMConnector {
    nonisolated let id: ConnectorID
    private var readiness: ConnectorStatus
    private let authMethod: String?
    private var failure: LLMError?
    private let hold: Bool
    private var waiting: CheckedContinuation<Void, Never>?
    private var arrivals: [CheckedContinuation<Void, Never>] = []
    private(set) var sends = 0
    init(id: ConnectorID, readiness: ConnectorStatus = .ready, authMethod: String? = "claude.ai", failure: LLMError? = nil, hold: Bool = false) {
        self.id = id; self.readiness = readiness; self.authMethod = authMethod; self.failure = failure; self.hold = hold
    }
    func status() -> ConnectorStatus { readiness }
    func knownCLIAuthMethod() -> String? { authMethod }
    func models(refresh: Bool) -> [LLMModel] { [LLMModel(id: "fixture-local", name: "Fixture", contextTokens: 128_000, source: .curated)] }
    func contextTokens(model: String) -> Int? { 128_000 }
    func send(_ request: LLMRequest, model: String) async throws -> RawCompletion {
        sends += 1
        if hold { await withCheckedContinuation { waiting = $0; arrivals.forEach { $0.resume() }; arrivals = [] } }
        if let failure { throw failure }
        return RawCompletion(text: "{\"rewrite\":\"A clearer passage\"}", model: model, stop: .complete)
    }
    /// Returns once a send waits for `release()`; a release before that would leave the send waiting for good.
    func untilWaiting() async { if waiting == nil { await withCheckedContinuation { arrivals.append($0) } } }
    func release() { waiting?.resume(); waiting = nil }
    func set(readiness: ConnectorStatus) { self.readiness = readiness }
    func set(failure: LLMError?) { self.failure = failure }
}

/// The quote clock of a session's `VoiceRewriteService`, moved by hand.
private final class QuoteClock: Sendable {
    private let time = Mutex<Duration>(.zero)
    func now() -> Duration { time.withLock { $0 } }
    func advance(seconds: Int) { time.withLock { $0 += .seconds(seconds) } }
}

/// A Keychain that refuses every key.
private actor RefusingKeys: ProviderKeyStore {
    func hasKey(for provider: String) -> Bool { false }
    func save(_ value: String, for provider: String) throws { throw SecretError.status(-25293) }
}

/// The consent and cost sheets of a send, held until the test answers each.
@MainActor private final class HeldSheets {
    private(set) var asked: [LLMSendSheet.Reason] = []
    private var answer: CheckedContinuation<Bool, Never>?
    private var arrivals: [CheckedContinuation<Void, Never>] = []
    func ask(_ sheet: LLMSendSheet) async -> Bool {
        asked.append(sheet.reason)
        return await withCheckedContinuation { answer = $0; arrivals.forEach { $0.resume() }; arrivals = [] }
    }
    /// Returns once a sheet asks; an answer before that would leave the sheet asking for good.
    func untilAsking() async { if answer == nil { await withCheckedContinuation { arrivals.append($0) } } }
    func answer(_ approved: Bool) { answer?.resume(returning: approved); answer = nil }
}

/// The right column in a window that is never shown, with an AppKit text view that stands in for the transcript, so a
/// test can move the keyboard out of the panel. SwiftUI focus runs in it as in the editor's window when the panel is the
/// window's content view (in a plain container view it does not take focus while the window is not key).
@MainActor private struct PanelWindow {
    let window: NSWindow
    let host: NSHostingView<AnyView>
    let elsewhere = NSTextView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
    init(editor: EditorModel) {
        _ = NSApplication.shared
        window = NSWindow(contentRect: CGRect(x: -10_000, y: -10_000, width: 404, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        host = NSHostingView(rootView: AnyView(PanelHost(model: editor, shell: WorkspaceShell(app: editor.app), width: 404, height: 600).environment(editor.app)))
        host.frame = CGRect(x: 0, y: 0, width: 404, height: 600)
        window.contentView = host
        host.addSubview(elsewhere)
    }
    /// Lays the panel out and lets SwiftUI run its updates and tasks, until `done` holds or for `turns` turns.
    func settle(turns: Int = 2_000, until done: () -> Bool = { false }) async {
        for _ in 0..<turns {
            host.layoutSubtreeIfNeeded()
            if done() { return }
            await Task.yield()
        }
    }
    /// The task's panel shows, not the passage panel.
    var showsTaskPanel: Bool { DebugRightColumn.markers(in: host)["director.panel"] != nil }
    /// A text field in the panel has the keyboard: the passage panel's instruction, or a key field.
    var fieldHasKeyboard: Bool { (window.firstResponder as? NSTextView).map { $0 !== elsewhere && $0.isDescendant(of: host) } ?? false }
    /// The task's panel itself has the keyboard (SwiftUI focus on a view that is not a text field).
    var paneHasKeyboard: Bool { window.firstResponder === host }
    /// Esc, and ⌘., which AppKit sends as the same action.
    func escape() { window.firstResponder?.tryToPerform(#selector(NSResponder.cancelOperation(_:)), with: nil) }
    func close() { window.close() }
}

/// The Rewrite job on the Director task (impl-plan V12m): R0 chooses the AI, R1 runs with
/// its steps and Stop, R1x shows each error with its fix, and the panel's job follows the
/// task. Stub connectors and in-memory keys only; the app model never starts, so it saves
/// no settings.
@Suite("Rewrite job on the Director task", .serialized, .enabled(if: ProcessInfo.processInfo.environment["VOXCLIP_DATA_DIR"] != nil, "Use an isolated VOXCLIP_DATA_DIR for app-model tests; only stub connectors are called."))
@MainActor struct DirectorTaskTests {
    private func app(_ connector: String?, connectors: [String: StubConnector] = [:], keys: [String: String] = [:]) -> (AppModel, DirectorFixtureKeys) {
        let app = AppModel(settingsStore: RegressionSettingsStore())
        app.connectorOverride = { id in connectors[id] ?? StubConnector(id: ConnectorID(rawValue: id) ?? .ollama, readiness: .cliMissing) }
        let store = DirectorFixtureKeys(keys)
        app.providerKeyStoreOverride = store
        app.connectorConsentOverride = { _, _, _ in true }
        app.set("voiceLab.enabled", .bool(true))
        if let connector {
            app.set("llm.connector", .string(connector))
            app.set("llm.model.\(connector)", .string("fixture-local"))
        }
        return (app, store)
    }
    private func editor(_ app: AppModel) throws -> EditorModel {
        let shared = try SharedResources.locate()
        let fixture = try DemoEditing.loadFixture(shared.root.appendingPathComponent("fixtures/projects/interview-take.voxclip"))
        return DebugConnectorRequests.makeEditor(fixture: fixture, app: app)
    }
    /// Runs Rewrite on words 3–5 as ⇧⌘R does: it runs at once (R1), or detects the AIs (R0). With `waits`, until the run
    /// or the detection ends; a held stub's run waits for `release()`.
    private func open(_ editor: EditorModel, waits: Bool = true) async throws -> RewriteSession {
        editor.runRewrite()
        await editor.rewriteOpenTask?.value
        let session = try #require(editor.openRewrite)
        if waits { await session.actionTask?.value }
        return session
    }
    /// Runs Rewrite again on the session's words, as Rewrite in the passage panel does.
    private func send(_ session: RewriteSession) -> Task<Bool, Never> {
        Task { await session.run() }
    }
    private func texts(_ task: DirectorTask) -> [String] { task.cards.compactMap { if case .text(let text) = $0 { text } else { nil } } }

    // MARK: The model's words

    @Test func scopeWordsFollowTheScope() {
        let clip = DirectorScope(kind: .clip(number: 1), wordCount: 118)
        #expect([clip.title, clip.name, clip.words, clip.noun, clip.tooLong] == ["Rewrite clip 1", "clip 1", "the 118 words of clip 1", "clip", "Clip 1 is too long to rewrite at once"])
        let take = DirectorScope(kind: .fullTake, wordCount: 900)
        #expect([take.title, take.name, take.words, take.noun, take.tooLong] == ["Rewrite full take", "the full take", "the 900 words of this video", "video", "Full take is too long to rewrite at once"])
        let words = DirectorScope(kind: .selection(inClip: true), wordCount: 7)
        #expect([words.title, words.name, words.words, words.noun, words.tooLong] == ["Rewrite 7 words", "these words", "these 7 words", "clip", "These words are too long to rewrite at once"])
        let word = DirectorScope(kind: .selection(inClip: false), wordCount: 1)
        #expect([word.title, word.name, word.words, word.noun] == ["Rewrite 1 word", "this word", "this word", "video"])

        #expect(PanelError(ScopeRewritePlanError.tooManyEntries(count: 3_412)) == .tooManyEntries(count: 3_412))
        #expect(PanelError(ScopeRewritePlanError.tooMuchText(bytes: 20_001)) == .tooMuchText)
        #expect(PanelError(ScopeRewritePlanError.empty) == nil && PanelError(ScopeRewritePlanError.invalidInput) == nil)

        let find = PanelAction(id: "findClips", title: "Find Clips") {}
        let (headline, cards, footer) = RewriteSession.tooLarge(.tooManyEntries(count: 3_412), words: take, findClips: find)
        #expect(headline.text == "Full take is too long to rewrite at once" && footer.primary == find && footer.note == nil)
        #expect(cards == [.text("Rewrite works on up to 3,000 words at a time. This video has 3,412. Choose a clip or select a passage.")])
        let (clipHeadline, clipCards, clipFooter) = RewriteSession.tooLarge(.tooMuchText, words: clip, findClips: nil)
        #expect(clipHeadline.text == "Clip 1 is too long to rewrite at once" && clipFooter == PanelFooter())
        #expect(clipCards == [.text("This clip has more text than Rewrite can send at once. Choose a clip or select a passage.")])

        func items(_ kinds: [ProposalItem.Kind]) -> ChangeSet {
            ChangeSet(items: kinds.enumerated().map { ProposalItem(ordinal: $0.offset + 1, kind: $0.element, sourceWordIDs: [], newWords: []) })
        }
        #expect(items([.voice, .cut, .voice, .fix, .voice, .cut]).announcement == "6 changes proposed. 3 need your voice.")
        #expect(items([.voice]).announcement == "1 change proposed. 1 needs your voice.")
        #expect(items([.cut, .fix]).announcement == "2 changes proposed.")

        let done = ActivityStep(id: "read", title: "Read clip 1", detail: "118 words · 0:43", status: .done, spoken: "Read clip 1, 118 words")
        let running = ActivityStep(id: "wait", title: "Waiting for Claude Code…", detail: "", status: .running, spoken: "Waiting for Claude Code")
        #expect(done.accessibilityLabel == "Done: Read clip 1, 118 words" && running.accessibilityLabel == "In progress: Waiting for Claude Code")
        #expect(DirectorContext(name: "Claude Code", model: "Opus 5.5", state: .noExtraCost, readiness: .ready).text == "Claude Code · Opus 5.5 · no extra cost")
        #expect(DirectorContext(name: "Claude Code", model: "Opus 5.5", state: .answered(seconds: 14), readiness: .ready).text == "Claude Code · Opus 5.5 · answered in 14.0\u{00A0}s")
    }

    // MARK: R0

    @Test func withNoAIChosenTheJobListsTheDetectedAIsAndUseOpensWithOne() async throws {
        let connectors = ["claude-code": StubConnector(id: .claudeCode, authMethod: "claude.ai"), "codex": StubConnector(id: .codex, readiness: .cliMissing),
                          "ollama": StubConnector(id: .ollama, readiness: .notRunning(url: "http://127.0.0.1:11434")),
                          "apple-foundation": StubConnector(id: .appleFoundation, readiness: .unavailable(reason: "Off"))]
        let (app, _) = app(nil, connectors: connectors, keys: ["openai": "sk-openai"])
        let editor = try editor(app)
        defer { editor.close() }
        editor.rewriteInstruction = "Make it shorter"
        let session = try await open(editor)
        let task = session.task
        #expect(task.state == .choosingAI && session.connector == nil && session.sendLine.isEmpty && session.instruction == "Make it shorter")
        #expect(task.headline.text == "Who should rewrite these words?")
        #expect(task.cards == [.chooser([
            ConnectorChoice(id: "claude-code", name: "Claude Code (installed CLI)", shortName: "Claude Code", status: "Signed in · Claude plan · no extra cost", isReady: true, needsKey: false),
            ConnectorChoice(id: "openai", name: "OpenAI", shortName: "OpenAI", status: "your API key · asks before each send", isReady: true, needsKey: false),
            ConnectorChoice(id: "anthropic", name: "Anthropic", shortName: "Anthropic", status: "your API key · asks before each send", isReady: false, needsKey: true),
        ], saveKey: PanelAction(id: "saveKey", title: "Save Key") {})])
        #expect(task.choice == "claude-code")
        #expect(task.footer.note == "Change it any time from the menu above the transcript.")
        #expect(task.footer.link?.title == "Check Again" && task.footer.primary?.title == "Use Claude Code")
        // Picking another row retitles the primary; ↑↓ do the same through `choose`.
        task.choose("openai")
        #expect(task.footer.primary?.title == "Use OpenAI")

        // Use continues to R1 on the same words with the same instruction.
        task.footer.primary?.perform()
        #expect(app.string("llm.connector") == "openai")
        let reopened = try #require(editor.openRewrite)
        #expect(reopened !== session && !session.isOpen && reopened.rewriteScope == .selection(3...5))
        #expect(reopened.connector?.name == "OpenAI" && reopened.instruction == "Make it shorter" && reopened.task.state == .running && reopened.task.turn == 1)
        #expect(editor.announcements.isEmpty)
        await reopened.actionTask?.value
    }

    @Test func withNothingDetectedTheJobSendsToSettingsAndChecksAgain() async throws {
        let claude = StubConnector(id: .claudeCode, readiness: .cliMissing, authMethod: "claude.ai")
        let (app, _) = app(nil, connectors: ["claude-code": claude])
        let editor = try editor(app)
        defer { editor.close() }
        let session = try await open(editor)
        let task = session.task
        #expect(task.headline.text == "No AI is set up yet")
        #expect(texts(task) == ["Rewrite needs an AI: an installed Claude Code or Codex, a local model, Apple on-device, or an API key."])
        #expect(task.footer.link?.title == "AI Settings…" && task.footer.primary?.title == "Check Again" && task.footer.note == nil)
        await claude.set(readiness: .ready)
        task.footer.primary?.perform()
        await session.actionTask?.value
        #expect(task.headline.text == "Who should rewrite these words?" && task.choice == "claude-code")
        #expect(task.footer.primary?.title == "Use Claude Code")
    }

    @Test func aKeyPastedInTheChooserIsSavedAndOffered() async throws {
        let (app, keys) = app(nil, connectors: ["claude-code": StubConnector(id: .claudeCode, readiness: .cliSignedOut, authMethod: nil)])
        let editor = try editor(app)
        defer { editor.close() }
        let session = try await open(editor)
        let task = session.task
        guard case .chooser(let rows, let saveKey?) = task.cards.first else { Issue.record("no chooser with Save Key"); return }
        #expect(rows.map(\.status) == ["Not signed in. Run `claude` in Terminal and sign in.", "your API key · asks before each send"])
        // A signed-out CLI is still offered first: choosing it shows its fix when it sends (R1x).
        #expect(task.choice == "claude-code")
        // Save Key with an empty field saves nothing and asks for the key.
        let focus = task.focusRequest
        task.keyDraft = "  "
        saveKey.perform()
        await session.actionTask?.value
        #expect(await keys.saved.isEmpty && task.focusRequest == focus + 1)
        task.keyDraft = "sk-ant-fixture"
        saveKey.perform()
        await session.actionTask?.value
        #expect(await keys.saved == ["anthropic": "sk-ant-fixture"] && task.keyDraft.isEmpty)
        #expect(task.cards.first.map { if case .chooser(let rows, _) = $0 { rows.first { $0.id == "anthropic" }?.needsKey == false } else { false } } == true)
        #expect(task.choice == "anthropic" && task.footer.primary?.title == "Use Anthropic")
    }

    @Test func aKeyTheKeychainRefusesStaysInTheChooserWithItsReason() async throws {
        let (app, _) = app(nil, connectors: ["claude-code": StubConnector(id: .claudeCode, readiness: .cliSignedOut, authMethod: nil)])
        app.providerKeyStoreOverride = RefusingKeys()
        let editor = try editor(app)
        defer { editor.close() }
        let session = try await open(editor)
        let task = session.task
        guard case .chooser(let rows, let saveKey?) = task.cards.first else { Issue.record("no chooser with Save Key"); return }
        task.keyDraft = "sk-ant-fixture"
        saveKey.perform()
        await session.actionTask?.value
        let reason = "Couldn't save the key. " + UserMessages.message(SecretError.status(-25293))
        #expect(task.state == .choosingAI && task.headline.text == "Who should rewrite these words?")
        #expect(task.cards == [.chooser(rows, saveKey: saveKey), .text(reason)] && task.keyDraft == "sk-ant-fixture")
        #expect(task.footer.primary?.title == "Use Claude Code" && editor.announcements == [reason])
        // Try Again on a session with no AI goes back to the chooser, never to a passage panel that cannot send.
        await session.tryAgain()
        #expect(task.state == .choosingAI && session.connector == nil)
    }

    // MARK: R1

    @Test func aSendRunsWithItsStepsAndAnnouncesThenShowsTheProposal() async throws {
        let ollama = StubConnector(id: .ollama, hold: true)
        let (app, _) = app("ollama", connectors: ["ollama": ollama])
        let editor = try editor(app)
        defer { editor.close() }
        let session = try await open(editor, waits: false)
        let task = session.task
        #expect(task.state == .running && task.turn == 1 && task.context?.text == "Ollama · fixture-local · no extra cost" && task.context?.readiness == .ready)
        await ollama.untilWaiting()
        #expect(task.state == .running && task.turn == 1)
        #expect(task.headline.text == "Rewriting these words…" && task.headline.runningSince != nil && task.headline.stop?.title == "Stop")
        #expect(task.cards.first == .asked(preset: "Fix mistakes", text: "fix slips and repeats, keep my words, change as little as possible."))
        #expect(task.steps.map(\.title) == ["Read these words", "Running on this Mac", "Waiting for Ollama…", "Check that each change fits"])
        #expect(task.steps.map(\.detail) == ["3 words · 0:02", "Nothing leaves it.", "Changes appear in the transcript when it answers.", ""])
        #expect(task.steps.map(\.status) == [.done, .done, .running, .waiting])
        #expect(task.steps.map(\.accessibilityLabel) == ["Done: Read these words, 3 words", "Done: Running on this Mac", "In progress: Waiting for Ollama", "Next: Check that each change fits"])
        #expect(task.footer == PanelFooter(note: "Runs on this Mac. Nothing leaves it."))
        #expect(editor.announcements == ["Rewriting these words"])

        await ollama.release()
        #expect(await session.sending?.value == true)
        guard case .proposal(let changes) = task.state else { Issue.record("no proposal: \(task.state)"); return }
        #expect(!changes.items.isEmpty && changes.items.map(\.ordinal) == Array(1...changes.items.count))
        #expect(editor.announcements == ["Rewriting these words", changes.announcement])
        if case .answered = task.context?.state {} else { Issue.record("the context line does not say when it answered") }
        #expect(!editor.llmRuns.isBusy && task.turn == 1)
    }

    @Test func aTypedInstructionIsQuotedAndAnAPIKeySendSaysItIsBilled() async throws {
        let anthropic = StubConnector(id: .anthropic, hold: true)
        let (app, _) = app("anthropic", connectors: ["anthropic": anthropic])
        let editor = try editor(app)
        defer { editor.close() }
        editor.rewriteInstruction = "Tighten the intro"
        let session = try await open(editor, waits: false)
        #expect(session.task.context?.text == "Anthropic · fixture-local · billed to your key" && session.task.context?.readiness == .asksFirst)
        await anthropic.untilWaiting()
        #expect(session.task.cards.first == .asked(preset: nil, text: "“Tighten the intro”"))
        #expect(session.task.steps[1].title == "Sent to Anthropic" && session.task.steps[1].detail == "Text only. No audio or video.")
        #expect(session.task.footer.note == "Sends these 3 words to Anthropic with your key.")
        await anthropic.release()
        await session.actionTask?.value
        #expect(app.rewriteSuggestions(for: editor.project.id).last?.menuTitle == "Recent: “Tighten the intro”")
    }

    /// R1 shows as the user sends, but claims nothing sent and announces nothing while the privacy consent and the
    /// cost sheet ask; a declined sheet shows the proposal the run would have replaced again, silently (V15).
    @Test func whileTheSheetsAskNothingShowsAsSentOrIsAnnounced() async throws {
        let anthropic = StubConnector(id: .anthropic)
        let (app, _) = app("anthropic", connectors: ["anthropic": anthropic])
        let sheets = HeldSheets()
        app.connectorConsentOverride = { _, _, sheet in await sheets.ask(sheet) }
        let editor = try editor(app)
        defer { editor.close() }
        let session = try await open(editor, waits: false)
        let task = session.task
        await sheets.untilAsking()
        #expect(sheets.asked == [.privacy] && task.state == .running && task.turn == 1)
        #expect(task.steps.map(\.status) == [.done, .waiting, .waiting, .waiting] && editor.announcements.isEmpty)
        sheets.answer(true)
        await sheets.untilAsking()
        #expect(sheets.asked == [.privacy, .cost] && task.steps.map(\.status) == [.done, .waiting, .waiting, .waiting] && editor.announcements.isEmpty)
        sheets.answer(true)
        #expect(await session.sending?.value == true)
        guard case .proposal(let changes) = task.state else { Issue.record("no proposal: \(task.state)"); return }
        #expect(editor.announcements == ["Rewriting these words", changes.announcement])
        #expect(await anthropic.sends == 1)

        let declined = send(session)
        await sheets.untilAsking()
        #expect(sheets.asked == [.privacy, .cost, .cost] && editor.announcements.count == 2)
        sheets.answer(false)
        #expect(await declined.value == false)
        #expect(task.state == .proposal(changes) && editor.announcements.count == 2 && session.ownProposal != nil)
        #expect(await anthropic.sends == 1)
    }

    @Test func stopCancelsSilentlyAndChangesNothing() async throws {
        let ollama = StubConnector(id: .ollama, hold: true)
        let (app, _) = app("ollama", connectors: ["ollama": ollama])
        let editor = try editor(app)
        defer { editor.close() }
        let before = editor.project
        let session = try await open(editor, waits: false)
        await ollama.untilWaiting()
        session.task.headline.stop?.perform()
        #expect(!session.isOpen && editor.openRewrite == nil)
        await ollama.release()
        #expect(await session.sending?.value == false)
        #expect(editor.project == before && !editor.llmRuns.isBusy && editor.announcements == ["Rewriting these words"])
    }

    // MARK: R1x

    struct Failure: Sendable, CustomTestStringConvertible {
        let name: String
        let connector: String
        let readiness: ConnectorStatus
        let authMethod: String?
        let failure: LLMError?
        let error: PanelError
        let body: String?
        let primary: String
        let note: String?
        var testDescription: String { name }
    }
    nonisolated static let failures: [Failure] = [
        Failure(name: "Claude Code signed out", connector: "claude-code", readiness: .cliSignedOut, authMethod: nil, failure: nil,
                error: .signedOut(cli: "Claude Code", command: "claude"),
                body: "Claude Code isn't signed in. Run `claude` in Terminal and sign in, then choose Try Again.", primary: "Try Again",
                note: "Sends these 3 words to Claude Code with your sign-in."),
        Failure(name: "Codex signed out", connector: "codex", readiness: .cliSignedOut, authMethod: nil, failure: nil,
                error: .signedOut(cli: "Codex", command: "codex login"),
                body: "Codex isn't signed in. Run `codex login` in Terminal and sign in, then choose Try Again.", primary: "Try Again",
                note: "Sends these 3 words to Codex with your sign-in."),
        Failure(name: "Ollama not running", connector: "ollama", readiness: .notRunning(url: "http://127.0.0.1:11434"), authMethod: nil, failure: nil,
                error: .notRunning(server: "Ollama"), body: "Ollama isn't running. Start it, then choose Try Again.", primary: "Try Again",
                note: "Runs on this Mac. Nothing leaves it."),
        Failure(name: "LM Studio not running", connector: "lmstudio", readiness: .notRunning(url: "http://127.0.0.1:1234"), authMethod: nil, failure: nil,
                error: .notRunning(server: "LM Studio"), body: "LM Studio isn't running. Start it, then choose Try Again.", primary: "Try Again",
                note: "Runs on this Mac. Nothing leaves it."),
        Failure(name: "Anthropic without a key", connector: "anthropic", readiness: .needsKey, authMethod: nil, failure: nil,
                error: .noKey(provider: "anthropic", name: "Anthropic"), body: nil, primary: "Save Key and Try Again",
                note: "Sends these 3 words to Anthropic with your key."),
        Failure(name: "the model declines", connector: "ollama", readiness: .ready, authMethod: nil, failure: .refused(category: nil),
                error: .refused, body: "The model declined to rewrite this recording.", primary: "Ask for Something Else", note: nil),
        Failure(name: "a timeout on this Mac", connector: "ollama", readiness: .ready, authMethod: nil, failure: .timeout,
                error: .message("Ollama took too long to answer. Try again, or pick a faster model. Your edits are saved."),
                body: "Ollama took too long to answer. Try again, or pick a faster model. Your edits are saved.", primary: "Try Again",
                note: "Runs on this Mac. Nothing leaves it."),
        Failure(name: "a rejected API key", connector: "anthropic", readiness: .ready, authMethod: nil, failure: .unauthorized,
                error: .message("Anthropic rejected the API key. Check it in Settings › AI. Your edits are saved."),
                body: "Anthropic rejected the API key. Check it in Settings › AI. Your edits are saved.", primary: "Try Again…",
                note: "Sends these 3 words to Anthropic with your key."),
    ]

    @Test(arguments: failures)
    func eachErrorShowsItsFix(_ row: Failure) async throws {
        let stub = StubConnector(id: try #require(ConnectorID(rawValue: row.connector)), readiness: row.readiness, authMethod: row.authMethod, failure: row.failure)
        let (app, _) = app(row.connector, connectors: [row.connector: stub])
        let editor = try editor(app)
        defer { editor.close() }
        let before = editor.project
        let session = try await open(editor)
        #expect(await session.sending?.value == false)
        let task = session.task
        #expect(task.state == .error(row.error))
        #expect(task.headline.text == "Couldn't rewrite these words" && task.headline.stop == nil)
        if let body = row.body { #expect(texts(task) == [body]) }
        else { #expect(task.cards == [.keyField(provider: "anthropic", label: "Anthropic API key")] && task.focusRequest == 1) }
        #expect(task.footer.primary?.title == row.primary && task.footer.note == row.note && task.footer.link == nil)
        #expect(editor.announcements.last == "Couldn't rewrite these words.")
        #expect(editor.project == before && !editor.llmRuns.isBusy && session.isOpen)
    }

    @Test func tryAgainSendsAgainAndAskForSomethingElseAsksForTheField() async throws {
        let ollama = StubConnector(id: .ollama, failure: .timeout)
        let (app, _) = app("ollama", connectors: ["ollama": ollama])
        let editor = try editor(app)
        defer { editor.close() }
        let session = try await open(editor)
        #expect(session.task.footer.primary?.title == "Try Again" && session.task.turn == 1)
        await ollama.set(failure: nil)
        session.task.footer.primary?.perform()
        await session.actionTask?.value
        if case .proposal = session.task.state {} else { Issue.record("Try Again did not propose: \(session.task.state)") }
        #expect(await ollama.sends == 2 && session.task.turn == 2)

        await ollama.set(failure: .refused(category: nil))
        _ = await send(session).value
        #expect(session.task.state == .error(.refused))
        // The refusal shows the Ask field, and Ask for Something Else asks for the keyboard there.
        #expect(session.task.cards.contains(.ask(placeholder: "What should change in these words?")) && session.task.focusRequest == 0)
        session.task.footer.primary?.perform()
        #expect(session.task.state == .error(.refused) && session.task.focusRequest == 1 && session.isOpen)
    }

    /// R1x sends the user away (sign in, start the server, get a key); Try Again after the service's 300 s quote window
    /// still sends, with a quote made for it.
    @Test func tryAgainAfterTheQuoteWindowSendsWithAFreshQuote() async throws {
        let ollama = StubConnector(id: .ollama, failure: .timeout)
        let (app, _) = app("ollama", connectors: ["ollama": ollama])
        let editor = try editor(app)
        defer { editor.close() }
        let clock = QuoteClock()
        let session = try await open(editor, waits: false)
        await session.passageService?.useClock { clock.now() }
        await session.actionTask?.value
        guard case .error(.message) = session.task.state else { Issue.record("no R1x: \(session.task.state)"); return }
        clock.advance(seconds: 301)
        await ollama.set(failure: nil)
        session.task.footer.primary?.perform()
        await session.actionTask?.value
        if case .proposal = session.task.state {} else { Issue.record("Try Again after 301 s did not propose: \(session.task.state)") }
        #expect(await ollama.sends == 2)
    }

    /// While Find Clips (or another Rewrite) holds the project's AI lease, Try Again says so and stays.
    @Test func tryAgainWhileAnotherAIRequestRunsSaysSo() async throws {
        let ollama = StubConnector(id: .ollama, failure: .timeout)
        let (app, _) = app("ollama", connectors: ["ollama": ollama])
        let editor = try editor(app)
        defer { editor.close() }
        let session = try await open(editor)
        let task = session.task
        let body = "Ollama took too long to answer. Try again, or pick a faster model. Your edits are saved."
        #expect(task.state == .error(.message(body)))
        await ollama.set(failure: nil)
        let lease = try #require(editor.llmRuns.acquire())
        for (finding, line) in [(true, "Find Clips is still running. Choose Try Again when it finishes."),
                                (false, "Another AI request on this project is still running. Choose Try Again when it finishes.")] {
            editor.finding = finding
            task.footer.primary?.perform()
            await session.actionTask?.value
            #expect(task.state == .error(.message(body)) && texts(task) == [body, line])
            #expect(task.footer.primary?.title == "Try Again" && editor.announcements.last == line)
        }
        editor.finding = false
        editor.llmRuns.release(lease)
        #expect(await ollama.sends == 1)
        task.footer.primary?.perform()
        await session.actionTask?.value
        if case .proposal = task.state {} else { Issue.record("Try Again after the lease did not propose: \(task.state)") }
        #expect(await ollama.sends == 2)
    }

    @Test func aKeyTheKeychainRefusesInR1xKeepsTheKeyField() async throws {
        let anthropic = StubConnector(id: .anthropic, readiness: .needsKey)
        let (app, _) = app("anthropic", connectors: ["anthropic": anthropic])
        app.providerKeyStoreOverride = RefusingKeys()
        let editor = try editor(app)
        defer { editor.close() }
        let session = try await open(editor)
        let task = session.task
        let focus = task.focusRequest
        task.keyDraft = "sk-ant-fixture"
        task.footer.primary?.perform()
        await session.actionTask?.value
        let reason = "Couldn't save the key. " + UserMessages.message(SecretError.status(-25293))
        #expect(task.state == .error(.noKey(provider: "anthropic", name: "Anthropic")))
        #expect(task.cards == [.keyField(provider: "anthropic", label: "Anthropic API key"), .text(reason)])
        #expect(task.footer.primary?.title == "Save Key and Try Again" && task.keyDraft == "sk-ant-fixture" && task.focusRequest == focus + 1)
        #expect(editor.announcements.last == reason)
        #expect(await anthropic.sends == 0)
    }

    @Test func saveKeyAndTryAgainSavesTheKeyThenSends() async throws {
        let anthropic = StubConnector(id: .anthropic, readiness: .needsKey)
        let (app, keys) = app("anthropic", connectors: ["anthropic": anthropic])
        let editor = try editor(app)
        defer { editor.close() }
        let session = try await open(editor)
        let task = session.task
        #expect(task.state == .error(.noKey(provider: "anthropic", name: "Anthropic")))
        task.keyDraft = "sk-ant-fixture"
        await anthropic.set(readiness: .ready)
        task.footer.primary?.perform()
        await session.actionTask?.value
        #expect(await keys.saved == ["anthropic": "sk-ant-fixture"] && task.keyDraft.isEmpty)
        if case .proposal = task.state {} else { Issue.record("no proposal after the key: \(task.state)") }
        #expect(await anthropic.sends == 1)
    }

    // MARK: The panel

    /// The right column shows the job of the open task, and a new run of the task brings its
    /// job back after the user switched to Captions. Every state draws the task's panel; R2 adds
    /// the change list (V15).
    @Test func thePanelsJobFollowsTheTask() async throws {
        _ = NSApplication.shared
        let shell = WorkspaceShell(app: AppModel())
        let shared = try SharedResources.locate()
        let base = try JSONProjectStore.decode(Data(contentsOf: shared.root.appendingPathComponent("fixtures/projects/interview-take.voxclip")))
        await shell.attachForTesting(VoxClipDocument(project: try DebugSidebar.fiveQuestions(from: base), demo: true), selection: .clip("five-1"))
        let editor = try #require(shell.editor)
        defer { editor.close() }
        editor.mediaResolved = true
        editor.refresh()
        editor.app.settings.values["voiceLab.enabled"] = .bool(true)
        editor.app.settings.values["voiceLab.betaNoticeAccepted"] = .bool(true)
        let lower = try #require(editor.activeClip.flatMap { editor.index($0.startWordId) })
        let connector = RewriteConnector(connector: StubConnector(id: .ollama), model: "fixture-local", name: "Ollama", group: "local", plan: "")
        let session = RewriteSession(editor: editor, scope: .selection(lower...(lower + 2)), envelope: nil, connector: connector)
        editor.rewrite = session
        func panel() -> [String: CGRect] {
            let host = NSHostingView(rootView: PanelHost(model: editor, shell: shell, width: 404, height: 522).environment(editor.app))
            host.frame = CGRect(x: 0, y: 0, width: 404, height: 522)
            host.layoutSubtreeIfNeeded()
            return DebugRightColumn.markers(in: host)
        }
        // A session with an AI runs as it opens: it starts on its first turn.
        #expect(session.task.turn == 1 && shell.panelJob(for: editor) == .rewrite && panel()["director.panel"] != nil)
        shell.choosePanelJob(.captions, for: editor)
        #expect(shell.panelJob(for: editor) == .captions)
        // The same turn's reply keeps the user's pick; R2 adds the change list to the task's panel.
        try session.receivePassage("A clearer passage")
        session.finishRun(seconds: 1)
        #expect(shell.panelJob(for: editor) == .captions)
        shell.choosePanelJob(.rewrite, for: editor)
        #expect(panel()["director.panel"] != nil && panel()["director.changes"] != nil)
        shell.choosePanelJob(.captions, for: editor)
        // The next run brings the job back.
        session.beginRun()
        #expect(session.task.turn == 2 && shell.panelJob(for: editor) == .rewrite && panel()["director.panel"] != nil)
        shell.choosePanelJob(.captions, for: editor)
        // The same turn's error keeps the user's pick.
        session.fail(.refused)
        #expect(shell.panelJob(for: editor) == .captions)
        shell.choosePanelJob(.rewrite, for: editor)
        #expect(panel()["director.panel"] != nil)
    }

    /// A run keeps the keyboard where it was (design.md §10); moved into R1 (F6), Esc (and ⌘.) stop it there.
    @Test func aRunKeepsTheKeyboardWhereItWasAndEscInThePanelStopsIt() async throws {
        let ollama = StubConnector(id: .ollama, hold: true)
        let (app, _) = app("ollama", connectors: ["ollama": ollama])
        let editor = try editor(app)
        defer { editor.close() }
        let panel = PanelWindow(editor: editor)
        defer { panel.close() }
        panel.window.makeFirstResponder(panel.elsewhere)
        let session = try await open(editor, waits: false)
        await ollama.untilWaiting()
        await panel.settle { panel.showsTaskPanel }
        #expect(panel.showsTaskPanel && panel.window.firstResponder === panel.elsewhere && !session.task.keyboardInPanel)
        editor.focusedPane = .panel
        editor.paneFocusRequest += 1
        await panel.settle { panel.paneHasKeyboard }
        #expect(panel.paneHasKeyboard && session.task.keyboardInPanel)
        panel.escape()
        #expect(!session.isOpen && editor.openRewrite == nil)
        await ollama.release()
        #expect(await session.sending?.value == false)
    }

    /// The reply keeps the keyboard where it was: in the panel when it was there (R2 replaces R1 in the same panel), and
    /// elsewhere when the user works elsewhere.
    @Test(arguments: [true, false])
    func aReplyTakesTheKeyboardOnlyFromThePanel(stayed: Bool) async throws {
        let ollama = StubConnector(id: .ollama, hold: true)
        let (app, _) = app("ollama", connectors: ["ollama": ollama])
        let editor = try editor(app)
        defer { editor.close() }
        let panel = PanelWindow(editor: editor)
        defer { panel.close() }
        panel.window.makeFirstResponder(panel.elsewhere)
        let session = try await open(editor, waits: false)
        await ollama.untilWaiting()
        await panel.settle { panel.showsTaskPanel }
        if stayed {
            editor.focusedPane = .panel
            editor.paneFocusRequest += 1
            await panel.settle { panel.paneHasKeyboard }
            #expect(session.task.keyboardInPanel)
        }
        await ollama.release()
        #expect(await session.sending?.value == true)
        await panel.settle { if case .proposal = session.task.state { true } else { false } }
        #expect(panel.showsTaskPanel, "the proposal shows in the task's panel")
        if stayed {
            await panel.settle(turns: 500)
            #expect(panel.paneHasKeyboard && session.task.keyboardInPanel)
        } else {
            await panel.settle(turns: 500)
            #expect(panel.window.firstResponder === panel.elsewhere, "the reply moved focus to \(String(describing: panel.window.firstResponder))")
        }
    }

    /// Ask for Something Else focuses the field (design.md R1x), wherever the keyboard was.
    @Test func askForSomethingElseFocusesTheField() async throws {
        let ollama = StubConnector(id: .ollama, failure: .refused(category: nil))
        let (app, _) = app("ollama", connectors: ["ollama": ollama])
        let editor = try editor(app)
        defer { editor.close() }
        let panel = PanelWindow(editor: editor)
        defer { panel.close() }
        panel.window.makeFirstResponder(panel.elsewhere)
        let session = try await open(editor)
        #expect(session.task.state == .error(.refused))
        await panel.settle { panel.showsTaskPanel }
        #expect(panel.window.firstResponder === panel.elsewhere)
        session.task.footer.primary?.perform()
        await panel.settle { panel.fieldHasKeyboard }
        #expect(session.task.state == .error(.refused) && panel.fieldHasKeyboard)
    }

    /// The DEBUG scene runner's scenes (R0, R0 with nothing, R1 and each R1x) at 404 and 300:
    /// every action drawn and no disabled button. With VOXCLIP_DIRECTOR_SCENES set, each is
    /// also drawn to a PNG there.
    @Test func everySceneDrawsItsActionsAndNoDisabledButton() async throws {
        let app = AppModel(settingsStore: RegressionSettingsStore())
        let shared = try SharedResources.locate()
        let fixture = try DemoEditing.loadFixture(shared.root.appendingPathComponent("fixtures/projects/interview-take.voxclip"))
        let scenes = await DebugRewrite.directorScenes(app: app, fixture: fixture)
        defer { scenes.forEach { $0.editor?.close() } }
        #expect(scenes.map(\.name) == ["r0", "r0-none", "r1", "r1-clip", "r1x-message", "r1x-signed-out", "r1x-no-key", "r1x-not-running", "r1x-refused", "r1x-too-many-words", "r1x-too-much-text", "r3",
                                       "r2-free", "r2-voice-lab-off", "r2-make-takes", "r2-make-voice", "r2-use-take", "r2-several-voices", "r2-over-budget",
                                       "r2-nothing-included", "r2-no-changes"])
        let output = ProcessInfo.processInfo.environment["VOXCLIP_DIRECTOR_SCENES"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        for scene in scenes {
            for width in [404, 300] {
                let host = NSHostingView(rootView: DirectorPanel(task: scene.task).frame(width: CGFloat(width), height: 265).environment(app).environment(\.colorScheme, .dark))
                host.frame = CGRect(x: 0, y: 0, width: width, height: 265)
                let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: .darkAqua)
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                for result in DebugRewrite.directorSceneChecks(scene, host: host, width: width) { #expect(result.passed, "\(result.name)") }
                if let output, let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("v2-rewrite-\(scene.name)-\(width).png"))
                }
                window.close()
            }
        }
        let r0 = try #require(scenes.first { $0.name == "r0" })
        guard case .chooser(let rows, _) = r0.task.cards.first else { Issue.record("R0 has no chooser"); return }
        #expect(rows.map(\.id) == ["claude-code", "codex", "ollama", "anthropic"])
    }
}
#endif
