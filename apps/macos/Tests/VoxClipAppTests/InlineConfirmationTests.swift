#if DEBUG
import Foundation
import Testing
@testable import VoxClip
@testable import VoxClipCore

@Suite("Inline connector confirmations", .serialized, .enabled(if: ProcessInfo.processInfo.environment["VOXCLIP_DATA_DIR"] != nil))
@MainActor struct InlineConfirmationTests {
    private func waitForRow(_ confirmation: ConnectorConfirmation) async throws {
        for _ in 0..<10_000 where !confirmation.isPresented { await Task.yield() }
        #expect(confirmation.isPresented)
        _ = try #require(confirmation.prompt)
    }
    private func app(_ id: String = "openai", auth: String? = nil) -> (AppModel, ConsentFixtureConnector, ProviderChoice) {
        let app = AppModel(settingsStore: RegressionSettingsStore())
        app.set("llm.connector", .string(id))
        let connector = ConsentFixtureConnector(id: ConnectorID(rawValue: id)!, authMethod: auth)
        app.connectorOverride = { _ in connector }
        return (app, connector, app.providers.first { $0.id == id }!)
    }
    @Test func f22FirstUseCombinesConsentAndBillingAndLaterSendsStillAsk() async throws {
        let (app, connector, provider) = app()
        let row = ConnectorConfirmation()
        for run in 0..<2 {
            let task = Task { try await app.authorizeConnectorRequest(provider, connector: connector, action: .rewrite,
                wordCount: 86, rewrite: DirectorScope(kind: .clip(number: 1), wordCount: 86), confirmation: row) }
            try await waitForRow(row)
            let prompt = try #require(row.prompt)
            #expect(prompt.message == "Rewrite sends the 86 words of clip 1 to OpenAI with your key.")
            #expect(prompt.confirm == (run == 0 ? "Allow and Send" : "Send"))
            #expect(prompt.firstUse == (run == 0) && prompt.billed)
            #expect(prompt.details.first?.contains("Asks before each send.") == true)
            #expect(prompt.note == "VoxClip can't tell what this costs. Check OpenAI's pricing.")
            #expect(!prompt.confirm.contains("$") && prompt.pricingURL != nil)
            row.approve()
            #expect(try await task.value)
            #expect(app.bool("llm.cloudConsent.openai"))
        }
        #expect(await connector.sends == 0) // Authorizing never invokes a connector.
    }
    @Test func f22bPlanFirstUseIsNeutralAndRememberedOncePerConnector() async throws {
        let (app, connector, provider) = app("claude-code", auth: "claude.ai")
        let row = ConnectorConfirmation()
        let task = Task { try await app.authorizeConnectorRequest(provider, connector: connector, action: .rewrite,
            wordCount: 86, rewrite: DirectorScope(kind: .clip(number: 1), wordCount: 86), confirmation: row) }
        try await waitForRow(row)
        let prompt = try #require(row.prompt)
        #expect(prompt.confirm == "Allow and Rewrite" && !prompt.billed)
        #expect(prompt.message == "VoxClip will run your installed Claude Code with your own sign-in.")
        #expect(prompt.details == ["The 86 words of clip 1 are sent to Anthropic and count toward your Claude plan's usage. No audio or video."])
        row.approve(); #expect(try await task.value)
        #expect(try await app.authorizeConnectorRequest(provider, connector: connector, action: .findClips, confirmation: row))
        #expect(!row.isPresented && !app.bool("llm.cloudConsent.codex"))
    }
    @Test func cancelStoresNoConsentAndLeavesTheAskTextAndProjectAlone() async throws {
        let (app, connector, provider) = app()
        let row = ConnectorConfirmation()
        let task = Task { try await app.authorizeConnectorRequest(provider, connector: connector, action: .rewrite,
            wordCount: 14, confirmation: row, verb: "Ask") }
        try await waitForRow(row)
        #expect(row.prompt?.message == "Ask sends your question and these 14 words to OpenAI with your key.")
        row.cancel(); #expect(try await task.value == false)
        #expect(!app.bool("llm.cloudConsent.openai") && !row.isPresented)
        #expect(await connector.sends == 0)
    }
    @Test func doubleReturnAndKeyRepeatNeverApproveButCommandReturnWorks() async throws {
        let row = ConnectorConfirmation()
        let prompt = ConnectorSendPrompt(reason: .cost, title: "Confirm send", message: "Text only", confirm: "Send")
        let task = Task { await row.present(prompt, isCurrent: { true }, saveKey: { _ in }) }
        try await waitForRow(row)
        let opened = row.keyGuard.appearedAt
        for time in [0.0, 0.08, 0.49] {
            #expect(row.pressReturn(timestamp: opened + time, now: opened + time, isRepeat: false, command: false))
            #expect(row.isPresented)
        }
        _ = row.pressReturn(timestamp: opened + 1, now: opened + 1, isRepeat: true, command: false)
        _ = row.pressReturn(timestamp: opened + 1, now: opened + 1, isRepeat: true, command: true)
        #expect(row.isPresented)
        _ = row.pressReturn(timestamp: opened - 0.1, now: opened + 1, isRepeat: false, command: false)
        #expect(row.isPresented)
        _ = row.pressReturn(timestamp: opened + 0.1, now: opened + 0.6, isRepeat: false, command: false)
        #expect(row.isPresented)
        _ = row.pressReturn(timestamp: opened + 0.1, now: opened + 0.1, isRepeat: false, command: true)
        #expect(await task.value && !row.isPresented)
        let fresh = PaidSendKeyGuard(now: 20)
        #expect(!fresh.accepts(timestamp: 20.49, now: 21, isRepeat: false, command: false))
        #expect(fresh.accepts(timestamp: 20.5, now: 20.6, isRepeat: false, command: false))
        #expect(fresh.accepts(timestamp: 20.6, now: 20.6, isRepeat: false, command: false))
        let next = Task { await row.present(prompt, isCurrent: { true }, saveKey: { _ in }) }
        try await waitForRow(row)
        let nextOpened = row.keyGuard.appearedAt
        _ = row.pressReturn(timestamp: nextOpened + 0.6, now: nextOpened + 0.6, isRepeat: false, command: false)
        #expect(await next.value && !row.isPresented)
    }
    @Test(arguments: ["approve", "cancel", "close"])
    func finishingTheRequestReleasesItsCapturedEditorAndSession(action: String) async throws {
        let (app, _, _) = app()
        let shared = try SharedResources.locate()
        let fixture = try DemoEditing.loadFixture(shared.root.appendingPathComponent("fixtures/projects/interview-take.voxclip"))
        var editor: EditorModel? = DebugConnectorRequests.makeEditor(fixture: fixture, app: app)
        var session: RewriteSession? = RewriteSession(editor: editor!, scope: .fullTake, envelope: nil, connector: nil)
        editor?.openRewrite = session
        weak var weakEditor = editor
        weak var weakSession = session
        let row = editor!.sendConfirmation
        let prompt = ConnectorSendPrompt(reason: .cost, title: "Confirm send", message: "Text only", confirm: "Send")
        var pending: Task<Bool, Never>? = Task { [owner = editor!, review = session!] in
            await row.present(prompt, isCurrent: { owner.openRewrite === review }, saveKey: { _ in })
        }
        try await waitForRow(row)
        if action == "approve" { row.approve() }
        else if action == "cancel" { row.cancel() }
        else { editor?.close() }
        #expect(await pending?.value == (action == "approve"))
        pending = nil
        editor?.close()
        await editor?.waveformTask?.value
        await editor?.waitForPendingPreviewForAudit()
        await editor?.rewriteOpenTask?.value
        await session?.waitForSend()
        await session?.actionTask?.value
        await session?.takesTask?.value
        session = nil; editor = nil
        #expect(!row.isPresented && row.requestID == nil)
        #expect(weakEditor == nil && weakSession == nil)
    }
    @Test func missingKeySaveRevealsSendAndRestartsItsGuardWithoutSending() async throws {
        let row = ConnectorConfirmation()
        var prompt = ConnectorSendPrompt(reason: .cost, title: "Confirm send", message: "Text only", confirm: "Allow and Send")
        prompt.needsKey = true
        var saves = 0
        let task = Task { await row.present(prompt, isCurrent: { true }, saveKey: { _ in saves += 1 }) }
        try await waitForRow(row)
        row.approve(); #expect(row.isPresented && saves == 0)
        row.key = "fixture-only"
        await row.saveKey()
        #expect(row.prompt?.needsKey == false && row.key.isEmpty && saves == 1 && row.isPresented)
        _ = row.pressReturn(timestamp: 0, now: row.keyGuard.appearedAt, isRepeat: false, command: false)
        #expect(row.isPresented)
        row.approve(); #expect(await task.value)
    }
    @Test func taskCancellationAndReplacementCannotApproveOrCloseAnotherRequest() async throws {
        let row = ConnectorConfirmation()
        let prompt = ConnectorSendPrompt(reason: .cost, title: "Confirm send", message: "Text only", confirm: "Send")
        let old = Task { await row.present(prompt, isCurrent: { true }, saveKey: { _ in }) }
        try await waitForRow(row)
        let oldID = row.requestID
        let next = Task { await row.present(prompt, isCurrent: { true }, saveKey: { _ in }) }
        for _ in 0..<10_000 where row.requestID == oldID { await Task.yield() }
        old.cancel(); #expect(await old.value == false)
        #expect(row.isPresented && row.requestID != oldID)
        row.cancel(); #expect(await next.value == false)
    }
    @Test func changingTheWordsReplacesThePendingRowAndOnlySendsItsNewScope() async throws {
        let (app, connector, _) = app()
        app.set("llm.model.openai", .string("fixture-local"))
        let shared = try SharedResources.locate()
        let fixture = try DemoEditing.loadFixture(shared.root.appendingPathComponent("fixtures/projects/interview-take.voxclip"))
        let editor = DebugConnectorRequests.makeEditor(fixture: fixture, app: app)
        defer { editor.close() }
        editor.runRewrite(verb: "Ask")
        await editor.rewriteOpenTask?.value
        try await waitForRow(editor.sendConfirmation)
        let first = editor.sendConfirmation.requestID
        #expect(editor.panelTask == nil)
        editor.selectedWordIDs = Set(editor.words.prefix(14).map(\.id))
        await editor.rewriteOpenTask?.value
        try await waitForRow(editor.sendConfirmation)
        #expect(editor.sendConfirmation.requestID != first)
        #expect(editor.sendConfirmation.prompt?.message == "Ask sends your question and these 14 words to OpenAI with your key.")
        #expect(await connector.sends == 0)
        let session = try #require(editor.openRewrite)
        editor.sendConfirmation.approve()
        await session.waitForSend()
        let sends = await connector.sends
        #expect(sends == 1, "state=\(session.task.state) problem=\(session.problem) open=\(session.isOpen) current=\(session.current)")
    }
    @Test func editorConnectorApprovalContainsNoSheetPresentation() throws {
        let shared = try SharedResources.locate()
        let source = try String(contentsOf: shared.root.deletingLastPathComponent().appendingPathComponent("apps/macos/Sources/VoxClip/ConnectorRequestConsent.swift"), encoding: .utf8)
        #expect(!source.contains("RewriteApprovalSheet("))
        #expect(!source.contains("beginSheetModal") && !source.contains("NSAlert("))
    }
}
#endif
