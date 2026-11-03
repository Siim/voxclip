#if DEBUG
import AppKit
import Foundation
import Testing
@testable import VoxClipCore
@testable import VoxClip

private actor RewriteFailureRunner: ProcessRunner {
    let failure: String
    private var pending: TestContinuation<Void>?
    private var arrivals: [TestContinuation<Void>] = []
    private(set) var sends = 0

    init(failure: String) { self.failure = failure }

    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        if request.arguments == ["--version"] { return result("2.1.309 (Claude Code)") }
        if request.arguments == ["--help"] {
            return result("--print --output-format --json-schema --tools --system-prompt --model --no-session-persistence --safe-mode --strict-mcp-config --disable-slash-commands --effort --fallback-model")
        }
        if request.arguments == ["auth", "status", "--json"] {
            return result(#"{"loggedIn":true,"authMethod":"claude_ai"}"#)
        }
        sends += 1
        await withTestDeadline { pending = $0; arrivals.forEach { $0.resume() }; arrivals = [] }
        switch failure {
        case "timeout": throw CLIProcessTimeout(stdout: Data(), stderr: Data())
        case "cancelled": throw LLMError.cancelled
        case "cancellationError": throw CancellationError()
        case "cancelledTask":
            withUnsafeCurrentTask { $0?.cancel() }
            throw LLMError.cancelled
        case "malformed": return result("not a JSON reply")
        default: return ProcessResult(exitCode: 1, stdout: Data(), stderr: Data(failure.utf8))
        }
    }

    func untilWaiting() async { if pending == nil { await withTestDeadline { arrivals.append($0) } } }
    func release() { pending?.resume(); pending = nil }
    private func result(_ text: String) -> ProcessResult { ProcessResult(exitCode: 0, stdout: Data(text.utf8), stderr: Data()) }
}

@Suite("Rewrite failure stays visible", .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["VOXCLIP_DATA_DIR"] != nil, "Use isolated app data and stub CLI processes."), .offlineFixtures)
@MainActor struct RewriteFailureVisibilityTests {
    private func setup(_ failure: String, clip: Bool = false) async throws -> (AppModel, EditorModel, WorkspaceShell, RewriteFailureRunner) {
        _ = NSApplication.shared
        let app = AppModel(settingsStore: RegressionSettingsStore())
        let shared = try SharedResources.locate()
        let runner = RewriteFailureRunner(failure: failure)
        let connector = CLIConnector(id: .claudeCode, runner: runner, catalog: try LLMCatalog(shared: shared), log: app.log,
            executable: URL(fileURLWithPath: "/bin/sh"), environment: [:], loginShellPATH: "/test")
        app.connectorOverride = { _ in connector }
        app.providerKeyStoreOverride = DirectorFixtureKeys()
        app.connectorConsentOverride = { _, _, _ in true }
        app.settings.values["llm.connector"] = .string("claude-code")
        app.settings.values["llm.model.claude-code"] = .string("opus")
        app.settings.values["voiceLab.enabled"] = .bool(false)
        var fixture = try DemoEditing.loadFixture(shared.root.appendingPathComponent("fixtures/projects/interview-take.voxclip"))
        if clip {
            let words = try #require(fixture.transcript?.words)
            fixture.edits.clips = [ClipRange(id: "failure-clip", startWordId: words[0].id, endWordId: words[5].id)]
            fixture.edits.activeClipId = "failure-clip"
        }
        await app.shell.attachForTesting(VoxClipDocument(project: fixture, demo: true), selection: clip ? .clip("failure-clip") : .fullTake, preview: DemoPreviewEngine())
        let editor = try #require(app.shell.editor)
        editor.mediaResolved = true
        editor.refresh()
        editor.waveformTask?.cancel()
        editor.waveform = WaveformData(fine: Array(repeating: 0.01, count: 100_000))
        editor.selectedWordIDs = Set(editor.words[3...5].map(\.id))
        return (app, editor, app.shell, runner)
    }

    private func open(_ editor: EditorModel, runner: RewriteFailureRunner) async throws -> RewriteSession {
        editor.runRewrite()
        _ = try await TestDeadline.value(editor.rewriteOpenTask, "open failing Rewrite")
        let session = try #require(editor.openRewrite)
        await runner.untilWaiting()
        return session
    }

    @Test(arguments: ["API Error: Connection refused (ECONNREFUSED)", "unexpected CLI failure", "timeout", "Not logged in", "Usage limit reached", "overloaded", "malformed", "cancelled", "cancellationError", "cancelledTask"])
    func firstFailureKeepsJobClipBarAndStatus(_ failure: String) async throws {
        let (app, editor, shell, runner) = try await setup(failure)
        defer { editor.close() }
        let before = editor.project
        let session = try await open(editor, runner: runner)
        #expect(session.sendApproved && session.task.state == .running)
        shell.choosePanelJob(.captions, for: editor)
        #expect(shell.panelJob(for: editor) == .captions)
        await runner.release()
        _ = try await TestDeadline.value(session.actionTask, "finish failing Rewrite")
        #expect(editor.openRewrite === session && session.isOpen)
        #expect(PanelJob.available(in: editor).contains(.rewrite))
        #expect(shell.panelJob(for: editor) == .rewrite)
        if case .error = session.task.state {} else { Issue.record("Failure did not remain visible: \(session.task.state)") }
        if failure == "unexpected CLI failure" || failure == "timeout" {
            let expected: LLMError = failure == "timeout" ? .timeout : .cliFailed(failure)
            let copy = RewriteSession.proposalError(expected, provider: "Claude Code", model: "opus")
            #expect(session.task.state == .error(.message(copy)))
            #expect(session.task.cards.contains(.text(copy)))
        }
        let bar = ClipBarView(model: editor, shell: shell)
        bar.render()
        #expect(bar.rewrite.label == "Rewrite failed")
        #expect(bar.rewrite.symbol == "exclamationmark.triangle")
        #expect(!bar.rewrite.isHidden && bar.rewrite.isOn && bar.rewriting.isHidden)
        let status = try #require(StatusBarContent.make(app: app, editor: editor, now: Date()).items[.task])
        #expect(status.spoken.hasPrefix("Rewrite stopped: "))
        #expect(status.lead == .symbol("exclamationmark.triangle"))
        #expect(editor.project == before && !editor.llmRuns.isBusy)
        session.task.close.perform()
        #expect(editor.openRewrite == nil && !session.isOpen)
        #expect(!PanelJob.available(in: editor).contains(.rewrite))
        #expect(StatusBarContent.make(app: app, editor: editor, now: Date()).items[.task] == nil)
    }

    @Test(arguments: [false, true])
    func scopedFailureCanBeReopenedFromAnotherTab(_ clip: Bool) async throws {
        let (_, editor, shell, runner) = try await setup("unexpected CLI failure", clip: clip)
        defer { editor.close() }
        editor.selectedWordIDs = []
        let session = try await open(editor, runner: runner)
        #expect(session.rewriteScope == (clip ? .clip("failure-clip") : .fullTake))
        await runner.release()
        _ = try await TestDeadline.value(session.actionTask, "finish scoped failure")
        #expect(editor.openRewrite === session && session.isOpen)
        #expect(shell.panelJob(for: editor) == .rewrite)
        if clip {
            shell.choose(.fullTake, byClick: false)
            #expect(editor.rewrite == nil && editor.statusRewriteFailure != nil)
        }
        if shell.viewerShown { shell.toggleViewer() }
        shell.showRewriteFailure()
        #expect(shell.viewerShown && shell.panelJob(for: editor) == .rewrite)
        #expect(editor.rewrite === session && editor.focusedPane == .panel)
    }

    @Test(arguments: ["API Error: Connection refused (ECONNREFUSED)", "unexpected CLI failure", "timeout"])
    func failedSendWithStaleConnectorStillShowsTheActualError(_ failure: String) async throws {
        let (_, editor, shell, runner) = try await setup(failure)
        defer { editor.close() }
        let session = try await open(editor, runner: runner)
        editor.app.settings.values["llm.model.claude-code"] = .string("sonnet")
        #expect(!session.current)
        await runner.release()
        _ = try await TestDeadline.value(session.actionTask, "finish stale failing Rewrite")
        #expect(editor.openRewrite === session && session.isOpen)
        #expect(shell.panelJob(for: editor) == .rewrite)
        if case .error = session.task.state {} else { Issue.record("Stale failure closed or lost its error") }
    }

    @Test func networkRecoveryRetryReplacementAndStop() async throws {
        let (app, editor, shell, runner) = try await setup("API Error: Connection refused (ECONNREFUSED)")
        defer { editor.close() }
        let session = try await open(editor, runner: runner)
        await runner.release()
        _ = try await TestDeadline.value(session.actionTask, "show network recovery")
        #expect(session.task.state == .error(.cliNetworkUnreachable(cli: "Claude Code", detail: "API Error: Connection refused (ECONNREFUSED)")))
        let texts = session.task.cards.compactMap { if case .text(let text) = $0 { text } else { nil } }
        #expect(texts == ["Claude Code couldn't reach its server from VoxClip.", LLMError.cliNetworkRecovery])
        #expect(session.task.footer.link?.title == "Open Local Network Settings")
        #expect(session.task.footer.primary?.title == "Try Again")
        shell.choosePanelJob(.captions, for: editor)
        let statusBar = StatusBarView(shell: shell)
        statusBar.render()
        let item = try #require(statusBar.itemView(.task))
        #expect(item.accessibilityPerformPress())
        #expect(shell.panelJob(for: editor) == .rewrite)
        statusBar.tearDown()
        session.task.footer.primary?.perform()
        await runner.untilWaiting()
        #expect(editor.openRewrite === session && session.task.state == .running)
        #expect(!StatusBarContent.make(app: app, editor: editor, now: Date()).items[.task]!.spoken.hasPrefix("Rewrite stopped:"))
        await runner.release()
        _ = try await TestDeadline.value(session.actionTask, "finish retry")
        #expect(await runner.sends == 2)
        editor.selectedWordIDs = Set(editor.words[0...2].map(\.id))
        let replacement = try await open(editor, runner: runner)
        #expect(replacement !== session && !session.isOpen)
        replacement.task.headline.stop?.perform()
        await runner.release()
        _ = try await TestDeadline.value(replacement.actionTask, "stop Rewrite")
        #expect(editor.openRewrite == nil && !replacement.isOpen)
        #expect(StatusBarContent.make(app: app, editor: editor, now: Date()).items[.task] == nil)
    }
}
#endif
