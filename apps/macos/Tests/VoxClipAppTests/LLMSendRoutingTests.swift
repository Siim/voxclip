#if DEBUG
import Foundation
import Testing
@testable import VoxClipCore
@testable import VoxClipMedia
@testable import VoxClip

/// The sheets one routed send showed, and the action each was for.
@MainActor private final class SheetLog {
    var sheets: [LLMSendSheet] = []
    var actions: [ConnectorConsentAction] = []
    /// Answers a sheet; true approves it.
    var answer: (LLMSendSheet) -> Bool = { _ in true }
    func take() -> [LLMSendSheet.Reason] { defer { sheets = []; actions = [] }; return sheets.map(\.reason) }
}

/// Voice Lab's ElevenLabs client in these tests never reaches for a key: no take is generated or priced.
private struct NoVoiceLabKeys: KeyProvider {
    func key(for provider: String) async throws -> String? { Issue.record("Routing tests must not ask for credentials"); return nil }
}

/// Every LLM send (Find clips, Rewrite and Settings → Test) asks C8's `kind(forLLMSendTo:signIn:providerName:)` after
/// the one-time privacy consent (impl-plan VS, lead decision on item 13). Stub connectors only: nothing leaves the Mac,
/// and the app model never starts, so it saves no settings and sweeps no folders.
@Suite("LLM send routing", .serialized, .enabled(if: ProcessInfo.processInfo.environment["VOXCLIP_DATA_DIR"] != nil, "Use an isolated VOXCLIP_DATA_DIR for app-model tests; only stub connectors are called."))
@MainActor struct LLMSendRoutingTests {
    struct Row: Sendable, CustomTestStringConvertible {
        let name: String
        let connector: String
        /// What the stub's sign-in check reports (ai.md §6.8, §6.9); only CLIs read it.
        let authMethod: String?
        let baseURL: String?
        /// The sheets of the first send, and of every later one.
        let first: [LLMSendSheet.Reason]
        let later: [LLMSendSheet.Reason]
        var testDescription: String { name }
    }

    /// The API-key connectors are not here: Find clips and Test read their key from the Keychain before sending. They
    /// take the same `.confirm` branch as a CLI signed in with an API key, and `apiKeyConnectorsConfirmEverySend` covers
    /// them.
    nonisolated static let rows: [Row] = [
        Row(name: "Claude Code on a plan", connector: "claude-code", authMethod: "claude.ai", baseURL: nil, first: [.privacy], later: []),
        Row(name: "Codex on a plan", connector: "codex", authMethod: "chatgpt", baseURL: nil, first: [.privacy], later: []),
        Row(name: "Claude Code on an API key", connector: "claude-code", authMethod: "api_key", baseURL: nil, first: [.privacy, .cost], later: [.cost]),
        Row(name: "Codex on an API key", connector: "codex", authMethod: "api_key", baseURL: nil, first: [.privacy, .cost], later: [.cost]),
        Row(name: "Ollama on this Mac", connector: "ollama", authMethod: nil, baseURL: "http://127.0.0.1:11434", first: [], later: []),
        Row(name: "LM Studio on this Mac", connector: "lmstudio", authMethod: nil, baseURL: nil, first: [], later: []),
        Row(name: "Ollama on another computer", connector: "ollama", authMethod: nil, baseURL: "http://192.168.1.20:11434", first: [.privacy], later: []),
        Row(name: "Apple on-device", connector: "apple-foundation", authMethod: nil, baseURL: nil, first: [], later: []),
    ]

    private func setUp(_ connector: String, authMethod: String?, baseURL: String? = nil,
                       readiness: ConnectorStatus = .ready) throws -> (AppModel, ConsentFixtureConnector, SheetLog) {
        let app = AppModel(settingsStore: RegressionSettingsStore())
        let fake = ConsentFixtureConnector(id: try #require(ConnectorID(rawValue: connector)), readiness: readiness, authMethod: authMethod)
        app.connectorOverride = { _ in fake }
        app.set("llm.connector", .string(connector))
        app.set("llm.model.\(connector)", .string("fixture-local"))
        app.set("voiceLab.enabled", .bool(true))
        if let baseURL { app.set("llm.baseUrl.\(connector)", .string(baseURL)) }
        let log = SheetLog()
        app.connectorConsentOverride = { _, action, sheet in
            log.sheets.append(sheet); log.actions.append(action)
            return log.answer(sheet)
        }
        return (app, fake, log)
    }

    private func editor(_ app: AppModel) throws -> EditorModel {
        let shared = try SharedResources.locate()
        let fixture = try DemoEditing.loadFixture(shared.root.appendingPathComponent("fixtures/projects/interview-take.voxclip"))
        return DebugConnectorRequests.makeEditor(fixture: fixture, app: app)
    }

    /// One send through the entry the user presses: the Find Clips button, Rewrite in the panel, or Settings → Test.
    private func send(_ action: ConnectorConsentAction, editor: EditorModel, app: AppModel) async throws {
        switch action {
        case .findClips:
            editor.findClips()
            await editor.findTask?.value
        case .rewrite:
            if editor.rewrite == nil {
                editor.beginRewrite()
                await editor.rewriteOpenTask?.value
                let session = try #require(editor.rewrite)
                await session.detectConnector(); await session.prepare()
            }
            let session = try #require(editor.rewrite)
            let quote = try #require(session.quote)
            session.markEstimateShown(quote.id)
            _ = await session.propose(quote)
        case .test:
            let provider = try #require(app.providers.first { $0.id == app.string("llm.connector") })
            _ = await testProvider(provider, app: app)
        }
    }

    @Test(arguments: rows, [ConnectorConsentAction.findClips, .rewrite, .test])
    func everyEntryAsksTheSendKindBeforeEachSend(row: Row, action: ConnectorConsentAction) async throws {
        let (app, fake, log) = try setUp(row.connector, authMethod: row.authMethod, baseURL: row.baseURL)
        let editor = try editor(app)
        defer { editor.close() }
        try await send(action, editor: editor, app: app)
        let firstActions = log.actions
        #expect(log.take() == row.first)
        #expect(firstActions.allSatisfy { $0 == action })
        #expect(await fake.sends == 1)
        for later in 2...3 {
            try await send(action, editor: editor, app: app)
            #expect(log.take() == row.later, "send \(later)")
            #expect(await fake.sends == later)
        }
        #expect(!editor.finding && !editor.llmRuns.isBusy && app.testingProviders.isEmpty)
    }

    /// The four API-key connectors: Rewrite through the panel, and Find clips and Test through the route their entries
    /// call (`EditorModel.findClips` and `testProvider` call nothing else before sending).
    @Test(arguments: ["anthropic", "openai", "xai", "gemini"])
    func apiKeyConnectorsConfirmEverySend(connector: String) async throws {
        let (app, fake, log) = try setUp(connector, authMethod: nil)
        let provider = try #require(app.providers.first { $0.id == connector })
        let editor = try editor(app)
        defer { editor.close() }
        try await send(.rewrite, editor: editor, app: app)
        #expect(log.take() == [.privacy, .cost])
        #expect(await fake.sends == 1)
        try await send(.rewrite, editor: editor, app: app)
        #expect(log.take() == [.cost])
        #expect(await fake.sends == 2)
        #expect(editor.rewrite?.proposalButton == "Rewrite…")
        #expect(editor.rewrite?.estimateCopy == "VoxClip can't tell what this costs. Check \(provider.label)'s pricing.")
        for action in [ConnectorConsentAction.findClips, .test] {
            for _ in 0..<2 {
                #expect(try await app.authorizeConnectorRequest(provider, connector: fake, action: action, wordCount: 80))
                #expect(log.actions == [action])
                #expect(log.take() == [.cost])
            }
        }
    }

    @Test(arguments: ["third_party", "none", nil] as [String?], [ConnectorConsentAction.findClips, .rewrite, .test])
    func aCLIWithAnUnknownSignInShowsNoSheetAndSendsNothing(method: String?, action: ConnectorConsentAction) async throws {
        let (app, fake, log) = try setUp("claude-code", authMethod: method)
        let editor = try editor(app)
        defer { editor.close() }
        switch action {
        case .rewrite:
            editor.beginRewrite()
            await editor.rewriteOpenTask?.value
            let session = try #require(editor.rewrite)
            await session.detectConnector(); await session.prepare()
            let quote = try #require(session.quote)
            session.markEstimateShown(quote.id)
            let sent = await session.propose(quote)
            #expect(!sent)
        default: try await send(action, editor: editor, app: app)
        }
        #expect(log.sheets.isEmpty)
        #expect(await fake.sends == 0)
    }

    @Test(arguments: [ConnectorConsentAction.findClips, .rewrite, .test])
    func decliningTheCostSendsNothingKeepsTheConsentAndAsksAgain(action: ConnectorConsentAction) async throws {
        let (app, fake, log) = try setUp("codex", authMethod: "api_key")
        let editor = try editor(app)
        defer { editor.close() }
        log.answer = { $0.reason == .privacy }
        try await send(action, editor: editor, app: app)
        #expect(log.take() == [.privacy, .cost])
        #expect(await fake.sends == 0)
        #expect(app.bool("llm.cloudConsent.codex"))
        log.answer = { _ in true }
        try await send(action, editor: editor, app: app)
        #expect(log.take() == [.cost])
        #expect(await fake.sends == 1)
    }

    /// Find clips and Rewrite pass `isCurrent`, which a model change ends while the cost sheet is up.
    @Test(arguments: [ConnectorConsentAction.findClips, .rewrite])
    func aModelChangeWhileTheCostSheetIsUpSendsNothing(action: ConnectorConsentAction) async throws {
        let (app, fake, log) = try setUp("claude-code", authMethod: "api_key")
        app.set("llm.cloudConsent.claude-code", .bool(true))
        let editor = try editor(app)
        defer { editor.close() }
        log.answer = { _ in app.set("llm.model.claude-code", .string("other")); return true }
        try await send(action, editor: editor, app: app)
        #expect(log.take() == [.cost])
        #expect(await fake.sends == 0)
    }

    @Test func costSheetsSayWhereTheWordsGoAndThatThePriceIsUnknown() async throws {
        let cases: [(String, String?, ConnectorConsentAction, Int, LLMSendSheet)] = [
            ("anthropic", nil, .findClips, 80, LLMSendSheet(reason: .cost, title: "Find clips?",
                message: "Sends this project's transcript (80 words, no audio or video) to Anthropic with your key.\n\nVoxClip can't tell what this costs. Check Anthropic's pricing.", confirm: "Find Clips")),
            ("gemini", nil, .rewrite, 3, LLMSendSheet(reason: .cost, title: "Rewrite 3 words?",
                message: "Sends these 3 words to Google Gemini with your key.\n\nVoxClip can't tell what this costs. Check Google Gemini's pricing.", confirm: "Rewrite")),
            ("openai", nil, .rewrite, 1, LLMSendSheet(reason: .cost, title: "Rewrite 1 word?",
                message: "Sends this word to OpenAI with your key.\n\nVoxClip can't tell what this costs. Check OpenAI's pricing.", confirm: "Rewrite")),
            ("claude-code", "api_key", .test, 0, LLMSendSheet(reason: .cost, title: "Send a test request?",
                message: "Sends a short test request to Claude Code, billed to the API key it is signed in with. Nothing from your projects is sent.\n\nVoxClip can't tell what this costs. Check Anthropic's pricing.", confirm: "Test")),
            ("codex", "api_key", .rewrite, 7, LLMSendSheet(reason: .cost, title: "Rewrite 7 words?",
                message: "Sends these 7 words to Codex, billed to the API key it is signed in with.\n\nVoxClip can't tell what this costs. Check OpenAI's pricing.", confirm: "Rewrite")),
        ]
        for (connector, method, action, words, expected) in cases {
            let (app, fake, log) = try setUp(connector, authMethod: method)
            app.set("llm.cloudConsent.\(connector)", .bool(true))
            let provider = try #require(app.providers.first { $0.id == connector })
            #expect(try await app.authorizeConnectorRequest(provider, connector: fake, action: action, wordCount: words))
            #expect(log.sheets == [expected])
        }
    }

    /// Only a send that asks first reads "Rewrite…" with C8's sentence (design §6.3.1). A CLI with no known sign-in (not
    /// detected yet, signed out, or a method VoxClip does not recognise) never asks: its send fails with the sign-in error.
    @Test(arguments: [("claude.ai", "Rewrite", "Sends these 3 words to Fixture with your sign-in. Counts toward your Claude plan.", ""),
                      ("api_key", "Rewrite…", "Sends these 3 words to Fixture, billed to the API key it is signed in with.",
                       "VoxClip can't tell what this costs. Check Anthropic's pricing."),
                      ("third_party", "Rewrite", "Sends these 3 words to Fixture with your sign-in.", ""),
                      ("none", "Rewrite", "Sends these 3 words to Fixture with your sign-in.", "")])
    func theRewriteButtonAndSendLineFollowTheDetectedSignIn(method: String, button: String, line: String, price: String) async throws {
        let (app, fake, _) = try setUp("claude-code", authMethod: method)
        let provider = try #require(app.providers.first { $0.id == "claude-code" })
        let editor = try editor(app)
        defer { editor.close() }
        let connector = RewriteConnector(connector: fake, model: "fixture-local", name: "Fixture", group: "cli", plan: "Claude plan")
        let session = RewriteSession(editor: editor, range: 3...5, envelope: AudioEnvelope(sampleRate: 48_000, levels: Array(repeating: 0.01, count: 10_000)),
                                     connector: connector)
        defer { session.close() }
        await session.prepare()
        #expect(session.sendLine == "Sends these 3 words to Fixture with your sign-in.")
        #expect(session.proposalButton == "Rewrite")
        #expect(session.estimateCopy == "")
        _ = await app.connectorStatus(provider, using: fake)
        await session.prepare()
        #expect(session.proposalButton == button)
        #expect(session.sendLine == line)
        #expect(session.estimateCopy == price)
    }

    /// A take that passes review, so Voice Lab's Accept is ready.
    private func readyTake() -> VoiceLabTakeRow {
        let plan = VoiceLabFitPlan(edits: [], incoming: .init(padFrames: 0, borrowedSamples: 0), outgoing: .init(padFrames: 0, borrowedSamples: 0),
            trimStartFrame: 0, trimEndFrame: 24_000, windowStart: 1, windowEnd: 2, windowStartSample: 24_000, windowEndSample: 48_000,
            outputFrames: 24_000, words: [VoiceLabWord(text: "Hello", start: 0.1, end: 0.9, synthetic: true)])
        let audio = VoiceLabTakeAudio(sampleRate: 24_000, trimmed: [0.1], mixed: [0.1], patchRange: 0..<1, seams: [], gainDb: 0, roomTone: nil, fit: .exact(plan))
        let qa = VoiceLabTakeQAResult(values: VoiceLabQA(transcriptMatch: 1, lufsJumpLu: 0, peakDbfs: -20, speakerScore: 0.8), failures: [])
        return VoiceLabTakeRow(id: UUID(), index: 0, seed: 0, audio: audio, qa: qa, score: 1, failure: nil)
    }

    /// Declining the cost sheet changes nothing: the route runs before `propose` touches the session, so no spinner shows
    /// behind the sheet, Voice Lab's reviewed take stays acceptable and unpriced again, and the same estimate can be sent.
    @Test func decliningTheRewriteCostSheetLeavesVoiceLabAndTheEstimateAsTheyWere() async throws {
        let (app, fake, log) = try setUp("codex", authMethod: "api_key")
        app.set("llm.cloudConsent.codex", .bool(true))
        app.set("voiceLab.providerConsent.elevenlabs", .bool(true))
        let editor = try editor(app)
        defer { editor.close() }
        editor.beginRewrite()
        await editor.rewriteOpenTask?.value
        let session = try #require(editor.rewrite)
        await session.detectConnector(); await session.prepare()
        session.configureGeneration(client: ElevenLabsVoiceLab(keys: NoVoiceLabKeys(), region: .default),
            store: VoiceConsentStore(locations: app.locations), speaker: .unavailable)
        let generation = try #require(session.generation)
        var quoteRequests = 0
        generation.prepareQuote = { quoteRequests += 1 }
        let take = readyTake()
        generation.review(.init(rows: [take], end: .completed))
        #expect(generation.readyToAccept)
        let quote = try #require(session.quote)
        session.markEstimateShown(quote.id)
        var proposingBehindSheet = false
        log.answer = { _ in proposingBehindSheet = session.isProposing; return false }
        let declined = await session.propose(quote)
        await generation.finishQuotePreparationForTests()
        #expect(!declined)
        #expect(log.take() == [.cost])
        #expect(await fake.sends == 0)
        #expect(!proposingBehindSheet)
        #expect(generation.readyToAccept && generation.selectedID == take.id && generation.rows == [take])
        #expect(quoteRequests == 0)
        #expect(session.quote == quote && session.canPropose && session.problem.isEmpty && !editor.llmRuns.isBusy)
        log.answer = { _ in true }
        let approved = await session.propose(quote)
        await generation.finishQuotePreparationForTests()
        #expect(approved)
        #expect(log.take() == [.cost])
        #expect(await fake.sends == 1)
        #expect(!generation.readyToAccept && quoteRequests > 0)
        session.close()
    }

    /// Find clips shows its progress only once the route says yes (design §6.2: the consent, then "while it runs").
    @Test func decliningTheFindClipsCostSheetShowsNoProgressAndKeepsTheLastResultLines() async throws {
        let (app, fake, log) = try setUp("codex", authMethod: "api_key")
        app.set("llm.cloudConsent.codex", .bool(true))
        let editor = try editor(app)
        defer { editor.close() }
        var sidebarReveals = 0
        editor.onNeedsSidebar = { sidebarReveals += 1 }
        editor.clipError = "Earlier error."
        editor.fallbackNote = "Answered by fixture-fallback because fixture-local was busy."
        var findingBehindSheet = false
        log.answer = { _ in findingBehindSheet = editor.finding; return false }
        editor.findClips()
        await editor.findTask?.value
        #expect(log.take() == [.cost])
        #expect(await fake.sends == 0)
        #expect(!findingBehindSheet && !editor.finding && !editor.llmRuns.isBusy)
        #expect(sidebarReveals == 0 && !editor.announcements.contains("Finding clips"))
        #expect(editor.clipError == "Earlier error." && editor.fallbackNote == "Answered by fixture-fallback because fixture-local was busy.")
        log.answer = { _ in true }
        editor.findClips()
        await editor.findTask?.value
        #expect(await fake.sends == 1)
        #expect(sidebarReveals == 1 && editor.announcements.contains("Finding clips"))
        #expect(editor.fallbackNote == nil && editor.clipError != "Earlier error.")
    }

    /// A connector that is not ready fails in the route, before any progress: the error still reaches the sidebar.
    @Test func aFindClipsReadinessErrorRevealsTheSidebarWithTheConnectorsMessage() async throws {
        let (app, fake, log) = try setUp("lmstudio", authMethod: nil, readiness: .noModels)
        let editor = try editor(app)
        defer { editor.close() }
        var sidebarReveals = 0
        editor.onNeedsSidebar = { sidebarReveals += 1 }
        editor.findClips()
        await editor.findTask?.value
        #expect(log.sheets.isEmpty)
        #expect(await fake.sends == 0)
        #expect(sidebarReveals == 1 && !editor.finding)
        #expect(editor.clipError == "Load or download a model in LM Studio, then refresh. Your edits are saved.")
    }

    @Test(arguments: [("lmstudio", "LM Studio", "http://localhost:1234"),
                      ("ollama", "Ollama", "http://127.0.0.1:11434")])
    func stoppedLocalServerKeepsItsURLAcrossSendSurfaces(connector: String, name: String, url: String) async throws {
        let (app, fake, log) = try setUp(connector, authMethod: nil, readiness: .notRunning(url: url))
        let editor = try editor(app)
        defer { editor.close() }
        editor.findClips()
        await editor.findTask?.value
        #expect(editor.clipError?.contains("\(name) isn't answering at \(url).") == true)
        #expect(app.harnessStatus.stateWords?.contains(url) == true)
        let rewriteEditor = try self.editor(app)
        defer { rewriteEditor.close() }
        try await send(.rewrite, editor: rewriteEditor, app: app)
        let session = try #require(rewriteEditor.rewrite)
        let messages = session.task.cards.compactMap { card -> String? in
            if case .text(let text) = card { return text }; return nil
        }
        #expect(messages.contains { $0.contains("\(name) isn't answering at \(url).") })
        #expect(await fake.sends == 0)
        #expect(log.sheets.isEmpty)
    }

    /// The Rewrite panel's readiness error names the chosen connector, as Find clips does: the route now runs for local
    /// connectors too, and LM Studio's server is off until the user starts it. The error is R1x on the session's task
    /// (V12m), with nothing sent, no sheet and the passage panel's problem line untouched.
    @Test(arguments: [
        ("lmstudio", ConnectorStatus.notRunning(url: "http://localhost:1234"), PanelError.notRunning(server: "LM Studio", url: "http://localhost:1234")),
        ("lmstudio", .noModels, .message("Load or download a model in LM Studio, then refresh. Your edits are saved.")),
        ("claude-code", .cliSignedOut, .signedOut(cli: "Claude Code", command: "claude")),
        ("openai", .needsKey, .noKey(provider: "openai", name: "OpenAI")),
    ])
    func aRewriteReadinessErrorNamesTheConnector(connector: String, readiness: ConnectorStatus, error: PanelError) async throws {
        let (app, fake, log) = try setUp(connector, authMethod: nil, readiness: readiness)
        let editor = try editor(app)
        defer { editor.close() }
        try await send(.rewrite, editor: editor, app: app)
        let session = try #require(editor.rewrite)
        #expect(log.sheets.isEmpty)
        #expect(await fake.sends == 0)
        #expect(session.task.state == .error(error), "\(session.task.state)")
        #expect(session.problem.isEmpty && !editor.llmRuns.isBusy)
    }
}
#endif
