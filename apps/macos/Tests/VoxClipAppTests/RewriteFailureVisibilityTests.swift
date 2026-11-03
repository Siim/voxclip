#if DEBUG
import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import VoxClipCore
@testable import VoxClipMedia
@testable import VoxClip

private actor RewriteFailureRunner: ProcessRunner {
    let failure: String
    private var pending: TestContinuation<Void>?
    private var arrivals: [TestContinuation<Void>] = []
    private(set) var sends = 0
    private(set) var models: [String] = []
    private var reply = #"{"edits":[]}"#

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
        if let modelIndex = request.arguments.firstIndex(of: "--model") { models.append(request.arguments[modelIndex + 1]) }
        await withTestDeadline { pending = $0; arrivals.forEach { $0.resume() }; arrivals = [] }
        switch failure {
        case "success": return result("{\"type\":\"result\",\"is_error\":false,\"structured_output\":\(reply),\"modelUsage\":{\"claude-opus-5-5\":{\"outputTokens\":787}}}")
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
    func respond(with reply: String) { self.reply = reply }
    private func result(_ text: String) -> ProcessResult { ProcessResult(exitCode: 0, stdout: Data(text.utf8), stderr: Data()) }
}

@MainActor private final class RewritePresentationGate {
    private var pending: TestContinuation<Void>?
    private var arrivals: [TestContinuation<Void>] = []
    func pause() async {
        await withTestDeadline { pending = $0; arrivals.forEach { $0.resume() }; arrivals = [] }
    }
    func untilPaused() async { if pending == nil { await withTestDeadline { arrivals.append($0) } } }
    func release() { pending?.resume(); pending = nil }
}

@Suite("Rewrite failure stays visible", .serialized, .offlineFixtures)
@MainActor struct RewriteFailureVisibilityTests {
    private func setup(_ failure: String, clip: Bool = false) async throws -> (AppModel, EditorModel, WorkspaceShell, RewriteFailureRunner) {
        _ = NSApplication.shared
        let dataDirectory = try #require(ProcessInfo.processInfo.environment["VOXCLIP_DATA_DIR"], "This suite requires isolated app data; the hosted App suite supplies VOXCLIP_DATA_DIR.")
        try #require(dataDirectory.hasPrefix("/"), "VOXCLIP_DATA_DIR must be absolute.")
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

    @Test(arguments: ["none", "save", "scope", "connector"])
    func firstSuccessfulReplyAfterNewClipAndAsk(_ change: String) async throws {
        let (_, editor, shell, runner) = try await setup("success")
        defer { editor.close() }
        var fresh = editor.project
        fresh.media.source.durationSeconds = 32
        fresh.transcript?.durationSeconds = 32
        fresh.transcript?.words = (0..<60).map { index in
            TimedWord(id: "fresh-\(index)", text: "word", start: Double(index) / 2, end: Double(index) / 2 + 0.4)
        }
        editor.document.replaceProject(fresh)
        editor.refresh()
        editor.selectedWordIDs = Set(editor.words.prefix(52).map(\.id))
        editor.makeClip()
        let clipID = try #require(editor.project.edits.activeClipId)
        shell.choose(.clip(clipID), byClick: false)
        editor.selectedWordIDs = []
        let bar = ClipBarView(model: editor, shell: shell)
        bar.render()
        bar.ask.stringValue = "Rephrase this more clearly; keep my casual tone."
        bar.runRewrite()
        _ = try await TestDeadline.value(editor.rewriteOpenTask, "open fresh clip Rewrite")
        let session = try #require(editor.openRewrite)
        await runner.untilWaiting()
        #expect(session.rewriteScope == .clip(clipID))
        #expect(session.source.count == 52)
        #expect(session.instruction == "Rephrase this more clearly; keep my casual tone.")
        let plan = try ScopeRewritePlan.make(project: session.project, scope: session.rewriteScope, instruction: session.instruction, language: "en", envelope: session.envelope)
        let line = try #require(plan.lines.first)
        let reply = try JSONSerialization.data(withJSONObject: ["edits": [["line": line.line, "text": "", "reason": "Remove this line"]]])
        await runner.respond(with: String(decoding: reply, as: UTF8.self))
        let before = editor.project
        if change == "save" {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-rewrite-save-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let saved = await withTestDeadline(returning: false) { continuation in
                editor.document.save(to: root.appendingPathComponent("fresh.voxclip"), ofType: UTType.voxclipProject.identifier, for: .saveOperation) { error in
                    continuation.resume(returning: error == nil)
                }
            }
            #expect(saved)
            #expect(editor.project.modifiedAt != before.modifiedAt)
            #expect(editor.project.edits == before.edits)
        } else if change == "scope" {
            var changed = editor.project
            changed.edits.corrections[editor.words[1].id] = "changed"
            editor.document.replaceProject(changed)
        } else if change == "connector" {
            editor.app.settings.values["llm.model.claude-code"] = .string("sonnet")
        }
        await runner.release()
        _ = try await TestDeadline.value(session.actionTask, "finish fresh successful Rewrite")
        #expect(editor.openRewrite === session && session.isOpen)
        if change == "scope" || change == "connector" {
            #expect(session.task.state == .changed)
            #expect(editor.proposal == nil)
        } else {
            #expect(session.current)
            if case .proposal = session.task.state {} else { Issue.record("Successful reply was not proposed: \(session.task.state)") }
            #expect(!session.changes.isEmpty && editor.proposal != nil)
        }
        #expect(await runner.sends == 1)
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

    @Test(arguments: [PanelJob.demo, .voice, .motion, .export])
    func failureDoesNotInterruptAnotherJob(_ job: PanelJob) async throws {
        let (app, editor, shell, runner) = try await setup("API Error: Connection refused (ECONNREFUSED)", clip: true)
        defer { editor.close() }
        let session = try await open(editor, runner: runner)
        let demoBackend = ContextDemoRecordingProbe()
        defer { demoBackend.releaseRecording() }
        demoBackend.holdRecording = true
        var voiceDiscards = 0
        switch job {
        case .demo:
            let demo = ContextDemoSession(model: editor, backend: demoBackend)
            demo.setURL("https://example.test/demo")
            editor.contextDemoSession = demo
            shell.choosePanelJob(.demo, for: editor)
            demo.review()
            try #require(await TestDeadline.until { demo.phase == .ready })
            demo.start()
            try #require(await TestDeadline.until { demoBackend.recordingRelease != nil })
            try #require(demo.phase == .recording)
        case .voice:
            app.settings.values["voiceLab.enabled"] = .bool(true)
            app.settings.values["voiceLab.betaNoticeAccepted"] = .bool(true)
            let voice = app.voiceLabSession
            voice.flow.owner = editor
            voice.flow.state = .statement
            voice.showEnrollment = true
            shell.choosePanelJob(.voice, for: editor)
            voice.recorder.simulateTake(samples: [Float](repeating: 0.1, count: 48_000), at: .now) { voiceDiscards += 1 }
        case .motion:
            editor.motionCueEditing = MotionCueEditing(draft: try #require(editor.motionCueDraft()), returnJob: .captions)
            editor.motionCueEditing?.draft.sourceEnd -= 0.1
            shell.choosePanelJob(.motion, for: editor)
        case .export:
            editor.exportJob.isOpen = true
            editor.exportJob.fileNamePattern = "keep-my-export"
            shell.choosePanelJob(.export, for: editor)
        default: Issue.record("Unexpected protected job")
        }
        let motion = editor.motionCueEditing
        let demoCancels = demoBackend.cancels
        #expect(shell.panelJob(for: editor) == job)
        await runner.release()
        _ = try await TestDeadline.value(session.actionTask, "failure alongside another job")
        #expect(shell.panelJob(for: editor) == job)
        #expect(voiceDiscards == 0 && demoBackend.cancels == demoCancels && demoBackend.discarded.isEmpty)
        if job == .demo { #expect(editor.contextDemoSession?.phase == .recording) }
        if job == .voice { #expect(app.voiceLabSession.recorder.recording) }
        if job == .motion { #expect(editor.motionCueEditing === motion) }
        if job == .export { #expect(editor.exportJob.isOpen && editor.exportJob.fileNamePattern == "keep-my-export") }
        #expect(editor.statusRewriteFailure != nil)
        let statusBar = StatusBarView(shell: shell)
        statusBar.render()
        defer { statusBar.tearDown() }
        let status = try #require(statusBar.itemView(.task))
        #expect(status.accessibilityPerformPress())
        #expect(shell.panelJob(for: editor) == .rewrite)
        if job == .voice { #expect(voiceDiscards == 1 && !app.voiceLabSession.recorder.recording) }
        if job == .motion { #expect(editor.motionCueEditing == nil) }
        if job == .demo {
            #expect(demoBackend.cancels == demoCancels + 1)
            demoBackend.releaseRecording()
            try #require(await TestDeadline.until { !demoBackend.discarded.isEmpty })
        }
    }

    @Test(arguments: [false, true])
    func retryUsesCurrentConnectorAndFreshConsent(_ clipBar: Bool) async throws {
        let (app, editor, shell, runner) = try await setup("API Error: Connection refused (ECONNREFUSED)")
        defer { editor.close() }
        let failed = try await open(editor, runner: runner)
        app.settings.values["llm.model.claude-code"] = .string("sonnet")
        await runner.release()
        _ = try await TestDeadline.value(failed.actionTask, "fail old model")
        let consent = RewritePresentationGate()
        defer { consent.release() }
        app.settings.values["llm.cloudConsent.claude-code"] = .bool(false)
        app.connectorConsentOverride = { _, _, _ in await consent.pause(); return true }
        if clipBar {
            let bar = ClipBarView(model: editor, shell: shell)
            bar.render()
            #expect(bar.rewrite.label == "Rewrite failed")
            bar.runRewrite()
            _ = try await TestDeadline.value(editor.rewriteOpenTask, "schedule clip-bar retry")
        } else {
            failed.task.footer.primary?.perform()
        }
        _ = try await TestDeadline.value(failed.actionTask, "replace stale connector")
        let retry = try #require(editor.openRewrite)
        try #require(retry !== failed)
        #expect(!failed.isOpen && retry.connector?.model == "sonnet")
        #expect(retry.rewriteScope == failed.rewriteScope && retry.instruction == failed.instruction)
        await consent.untilPaused()
        #expect(await runner.sends == 1)
        #expect(!retry.sendApproved && retry.task.state == .running)
        consent.release()
        await runner.untilWaiting()
        #expect(retry.sendApproved && retry.task.state == .running)
        #expect(await runner.models.last?.contains("sonnet") == true)
        await runner.release()
        _ = try await TestDeadline.value(retry.actionTask, "finish current-model retry")
        #expect(await runner.sends == 2)
        #expect(retry.failureStatus?.contains("couldn't reach") == true)
    }

    @Test func editDuringErrorPresentationKeepsChangedRow() async throws {
        let (_, editor, _, runner) = try await setup("API Error: Connection refused (ECONNREFUSED)")
        defer { editor.close() }
        let session = try await open(editor, runner: runner)
        let presentation = RewritePresentationGate()
        defer { presentation.release() }
        session.beforeFailurePresentation = { await presentation.pause() }
        await runner.release()
        await presentation.untilPaused()
        editor.apply(.cutSelection(ids: [editor.words[3].id]), name: "Cut selection")
        #expect(session.task.state == .changed)
        presentation.release()
        _ = try await TestDeadline.value(session.actionTask, "finish error presentation after edit")
        #expect(editor.openRewrite === session && session.task.state == .changed)
        #expect(session.failureStatus == nil && session.sendFailure == nil)
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
