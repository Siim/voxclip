#if DEBUG
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import VoxClipCore
@testable import VoxClipMedia
@testable import VoxClip

/// Closing Rewrite with paid work (design.md R2 "Closing Rewrite"): Close Rewrite, Esc in the panel and the transcript, a
/// Rewrite of another scope, Close Project, Quit and a switch of the video's voice never drop unused paid takes or a
/// whole clip's paid voice unasked. Each asks inline in the Rewrite job, Keep Working the default; Discard goes on. The take
/// and whole-clip fixtures are DEBUG stand-ins: nothing is sent, paid or read from the keychain, and no window is shown.
@Suite("Rewrite paid-work guard", .serialized, .offlineFixtures)
@MainActor struct RewritePaidWorkGuardTests {
    enum Paid { case takes, wholeClip }
    @MainActor private struct Fixture {
        let root: URL
        let app: AppModel
        let shell: WorkspaceShell
        let editor: EditorModel
        let session: RewriteSession
        func close() { editor.close(); try? FileManager.default.removeItem(at: root) }
    }

    /// The five-questions project open in the app's shell, Rewrite of words 12…25 with a reply in, and `paid` work in it:
    /// the take fixture's paid takes, or a whole clip's paid voice and lip sync in Review (≈ $1.61).
    private func fixture(_ paid: Paid = .wholeClip) async throws -> Fixture {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-paid-guard-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let app = AppModel(settingsStore: RegressionSettingsStore(), locations: DataLocations(environment: ["VOXCLIP_DATA_DIR": root.path]))
        app.settings.values["voiceLab.enabled"] = .bool(true)
        app.settings.values["voiceLab.betaNoticeAccepted"] = .bool(true)
        app.settings.values["voiceLab.providerConsent.elevenlabs"] = .bool(true)
        let shared = try SharedResources.locate()
        let project = try DemoEditing.loadFixture(shared.root.appendingPathComponent("fixtures/projects/five-questions.voxclip"))
        let shell = app.shell
        await shell.attachForTesting(VoxClipDocument(project: project, demo: true), selection: .fullTake)
        let editor = try #require(shell.editor)
        editor.mediaResolved = true
        editor.refresh()
        let connector = RewriteConnector(connector: RewriteFixtureConnector(), model: "fixture-local", name: "Fixture", group: "local", plan: "")
        let session = RewriteSession(editor: editor, scope: .selection(12...25),
            envelope: AudioEnvelope(sampleRate: 48_000, levels: Array(repeating: 0.01, count: 10_000)), connector: connector)
        editor.rewrite = session
        try session.receivePassage("A clearer way to explain what happened in this passage.")
        session.finishRun(seconds: 1)
        switch paid {
        case .takes:
            try DebugRewriteGeneration.install("ready", in: session)
            try #require(session.hasPaidTakes && session.paidTakeCount > 0)
        case .wholeClip:
            let whole = WholeClipRevoiceSession()
            whole.backend = WholeClipRevoiceSessionTests.backend(WholeClipRevoiceSessionTests.Stubs())
            whole.start(); await whole.waitForRun()
            try #require(whole.phase == .review && whole.spent > 0)
            session.wholeClip = whole
            try #require(!session.hasPaidTakes, "a paid whole clip alone is no patch take")
        }
        session.showProposal()
        try #require(session.hasUnusedPaidWork && session.task.confirm == nil)
        return Fixture(root: root, app: app, shell: shell, editor: editor, session: session)
    }

    private func asks(_ fixture: Fixture, _ prefix: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let confirm = fixture.session.task.confirm
        #expect(confirm?.confirm.id == "discardPaidWork" && confirm?.question.hasPrefix(prefix) == true && confirm?.cancel.title == "Keep Working",
                "\(String(describing: confirm?.question))", sourceLocation: sourceLocation)
        #expect(fixture.session.isOpen && fixture.editor.openRewrite === fixture.session, "Rewrite stays open", sourceLocation: sourceLocation)
    }

    // MARK: Close Rewrite and Esc

    /// The panel's X (the task's close action, Close Rewrite): asks, and Keep Working changes nothing; Discard and Close
    /// closes. It used to close at once and drop the takes.
    @Test(arguments: [Paid.takes, .wholeClip]) func closeRewriteAsksAndOnlyDiscardCloses(paid: Paid) async throws {
        let fixture = try await fixture(paid)
        defer { fixture.close() }
        let session = fixture.session
        session.task.close.perform()
        asks(fixture, "Close Rewrite and discard ")
        let question = try #require(session.task.confirm?.question)
        #expect(paid == .takes ? question.contains("paid take") : question.contains("the paid whole-clip voice and lip sync (≈ $"), "\(question)")
        #expect(fixture.editor.lastAnnouncement == question)
        session.task.confirm?.cancel.perform()
        #expect(session.task.confirm == nil && session.isOpen && session.hasUnusedPaidWork, "Keep Working keeps the work")
        // Return chooses Keep Working, as Esc does.
        session.task.close.perform()
        #expect(session.task.pressReturn(command: false) && session.task.confirm == nil && session.isOpen)
        #expect(fixture.editor.closeRewrite(returnFocus: false) == false)
        session.task.confirm?.confirm.perform()
        #expect(!session.isOpen && fixture.editor.openRewrite == nil)
    }

    /// Esc in the transcript (keyCode 53) asks as Close Rewrite does.
    @Test func escInTheTranscriptAsks() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        let coordinator = TranscriptTextView.Coordinator(model: fixture.editor)
        let scroll = TranscriptTextView.makeScrollView(model: fixture.editor, coordinator: coordinator, width: 652, height: 488)
        let text = try #require(scroll.documentView as? TranscriptNSTextView)
        let escape = String(UnicodeScalar(UInt8(27)))
        let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                                characters: escape, charactersIgnoringModifiers: escape, isARepeat: false, keyCode: 53))
        try #require(fixture.editor.rewrite === fixture.session)
        text.keyDown(with: key)
        asks(fixture, "Close Rewrite and discard ")
    }

    /// Esc in the Rewrite panel (its exit command): the first asks; the second is Keep Working, the question's safe answer.
    @Test func escInThePanelAsksThenKeepsWorking() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        let window = NSWindow(contentRect: CGRect(x: -10_000, y: -10_000, width: 404, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: AnyView(PanelHost(model: fixture.editor, shell: fixture.shell, width: 404, height: 600).environment(fixture.app)))
        host.frame = CGRect(x: 0, y: 0, width: 404, height: 600)
        window.contentView = host
        func settle(_ done: () -> Bool) async {
            for _ in 0..<2_000 {
                host.layoutSubtreeIfNeeded()
                pumpRunLoop()
                if done() { return }
                await Task.yield()
            }
        }
        var paneHasKeyboard: Bool {
            !(window.firstResponder is NSTextView) && (window.firstResponder as? NSView).map { $0.isDescendant(of: host) } == true
        }
        var showsTaskPanel: Bool { DebugRightColumn.markers(in: host)["director.panel"] != nil }
        await settle { showsTaskPanel }
        try #require(showsTaskPanel, "the Rewrite job shows")
        fixture.editor.focusedPane = .panel
        fixture.editor.paneFocusRequest += 1
        await settle { paneHasKeyboard }
        try #require(paneHasKeyboard, "the panel has the keyboard: \(String(describing: window.firstResponder))")
        window.firstResponder?.tryToPerform(#selector(NSResponder.cancelOperation(_:)), with: nil)
        asks(fixture, "Close Rewrite and discard ")
        // Esc again, while the question waits: its safe answer, Keep Working.
        window.firstResponder?.tryToPerform(#selector(NSResponder.cancelOperation(_:)), with: nil)
        #expect(fixture.session.task.confirm == nil && fixture.session.isOpen, "Esc answers Keep Working")
    }

    // MARK: Another Rewrite, the AI, the project and Quit

    /// Rewrite on another scope (⇧⌘R, the clip bar, another clip) asks first, and nothing is opened until Discard.
    @Test func aRewriteOfAnotherScopeAsksFirst() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        fixture.editor.runRewrite(scope: .fullTake)
        _ = await fixture.editor.rewriteOpenTask?.value
        asks(fixture, "Start a new Rewrite and discard ")
        #expect(fixture.session.task.confirm?.confirm.title == "Discard and Rewrite")
        fixture.session.task.confirm?.cancel.perform()
        #expect(fixture.session.isOpen && fixture.session.hasUnusedPaidWork && fixture.editor.openRewrite === fixture.session)
    }

    /// Rewrite Again on the same scope with no change edited still asks over a paid whole clip, naming it; it used to send
    /// again and drop the whole clip unasked.
    @Test func rewriteAgainOverAPaidWholeClipAsks() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        fixture.editor.sendRewriteAgain(fixture.session)
        _ = await fixture.editor.rewriteOpenTask?.value
        let confirm = try #require(fixture.session.task.confirm)
        #expect(["discardPaidWork", "discardChanges"].contains(confirm.confirm.id) && fixture.session.isOpen, "\(confirm.question)")
        #expect(fixture.session.wholeClip?.phase == .review, "nothing was sent again")
    }

    /// Close Project (⌘W, the window's close, opening another project) asks inline before anything freezes or saves; a
    /// refused or cancelled close no longer destroys anything. Discard and Close goes on with the same close.
    @Test func closingTheProjectAsksFirstAndACancelledCloseKeepsTheWork() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        let shell = fixture.shell
        // Nothing to save, so the document's own close review never shows a prompt here.
        try #require(!fixture.editor.document.isDocumentEdited)
        // The leave's own save prompt is refused (an untitled project's Cancel, a failed save).
        shell.injectSaveFailure = true
        #expect(await shell.closeProject() == false)
        asks(fixture, "Close the project and discard ")
        #expect(!fixture.editor.isLeaving && shell.document != nil)
        fixture.session.task.confirm?.cancel.perform()
        #expect(fixture.session.isOpen && fixture.session.hasUnusedPaidWork, "Keep Working keeps the work")
        // Discard and Close runs the close again, which no longer asks; this time the save is refused, so the project stays.
        #expect(await shell.closeProject() == false)
        fixture.session.task.confirm?.confirm.perform()
        #expect(await TestDeadline.until { !fixture.session.isOpen && !shell.injectSaveFailure && !fixture.editor.isLeaving })
        #expect(fixture.editor.openRewrite == nil && shell.document != nil)
    }

    /// Quit with paid work in an open Rewrite: the quit is cancelled and the question asks in that Rewrite; Discard and Quit
    /// quits again.
    @Test func quitAsksInTheRewriteAndDiscardQuitsAgain() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        let delegate = AppDelegate(model: fixture.app)
        var quits = 0
        delegate.requestTermination = { quits += 1 }
        #expect(delegate.rewriteHoldingPaidWork === fixture.session)
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
        asks(fixture, "Quit VoxClip and discard ")
        #expect(fixture.session.task.confirm?.confirm.title == "Discard and Quit" && quits == 0)
        fixture.session.task.confirm?.confirm.perform()
        #expect(quits == 1)
    }

    // MARK: The video's voice

    private static let anchorID = "11111111-1111-4111-8111-111111111111"
    private static let ownID = "33333333-3333-4333-8333-333333333333"
    private static func voiceRecord(_ id: String) throws -> VoiceConsentRecord {
        let json = try Data(contentsOf: SharedResources.locate().root.appendingPathComponent("fixtures/voice-lab/consent-record-project.json"))
        var object = try #require(JSONSerialization.jsonObject(with: json) as? [String: Any]); object["recordId"] = id
        return try JSONDecoder().decode(VoiceConsentRecord.self, from: JSONSerialization.data(withJSONObject: object))
    }

    /// "Match this video" with a paid whole-clip voice keeps the voice it was made with: a switch would make the paid voice
    /// stale. It used to switch, because the guard read only the patch's takes.
    @Test func matchingThisVideoKeepsTheVoiceOfAPaidWholeClip() async throws {
        _ = NSApplication.shared
        let shared = try SharedResources.locate()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-paid-voice-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var project = try JSONProjectStore.decode(Data(contentsOf: shared.root.appendingPathComponent("fixtures/voice-lab/passage-render-v3.voxclip")))
        project.id = UUID().uuidString.lowercased()
        project.voiceLab.segments = []; project.voiceLab.assets = []; project.edits = ProjectEdits()
        project.media.source.contentKey = "this-video"
        let app = AppModel(settingsStore: RegressionSettingsStore(), locations: DataLocations(environment: ["VOXCLIP_DATA_DIR": root.path]))
        app.settings.values["voiceLab.enabled"] = .bool(true)
        app.settings.values["voiceLab.betaNoticeAccepted"] = .bool(true)
        app.settings.values["voiceLab.providerConsent.elevenlabs"] = .bool(true)
        let editor = EditorModel(document: VoxClipDocument(project: project, demo: true), app: app, preview: DemoPreviewEngine())
        defer { editor.close() }
        editor.mediaResolved = true
        editor.refresh()
        let session = RewriteSession(editor: editor, scope: .fullTake, envelope: nil, connector: nil)
        editor.rewrite = session
        let word = try #require(project.transcript?.words.first)
        session.receive([RewriteChange(hunk: VoiceLabDiffHunk(kind: .voice, sourceWordIds: [word.id], newTokens: ["Hello"], correctedTexts: [],
            absorbedItemIds: [], bridgeWordIds: [], sourceStartIndex: 0, sourceEndIndex: 1, anchorSeconds: nil))])
        session.finishRun(seconds: 1); session.showProposal()
        let anchor = try Self.voiceRecord(Self.anchorID), own = try Self.voiceRecord(Self.ownID)
        let voiceLab = app.voiceLabSession
        voiceLab.records = [anchor, own]
        var book = VoicePerVideoBook()
        book.videos = [.init(contentKey: "this-video", recordId: own.id, anchorId: anchor.id, anchorReferenceSha256: String(repeating: "a", count: 64),
            title: "DJI_0011", createdAt: "2026-11-19T16:39:19Z", videoSeconds: 40, removesBackgroundNoise: false)]
        voiceLab.perVideoBook = book
        session.configureGeneration(client: ElevenLabsVoiceLab(keys: PaidGuardTestKeys(), region: .default),
            store: VoiceConsentStore(locations: app.locations), speaker: .unavailable)
        let generation = try #require(session.generation)
        generation.prepareQuote = nil
        let model = VoiceLabModel(id: VoiceLabWordingFit.modelID, name: "Eleven v4", languages: ["en"], canSpeak: true, canConvert: false,
            maximumTextLength: 5_000, characterCostMultiplier: 1)
        generation.discoverForTests = { _ in ([model], [anchor, own]) }
        await generation.discover(language: "en")
        try #require(generation.selectedVoiceID == anchor.id && voiceLab.offersVideoVoice(session.project) && session.current,
                     "the anchor, and the video's own voice is ready")
        // The whole clip's voice and lip sync are paid in the anchor's voice, then its lip sync failed: Stopped, voice kept.
        let stubs = WholeClipRevoiceSessionTests.Stubs()
        stubs.failLipsync = true
        let whole = WholeClipRevoiceSession()
        whole.backend = WholeClipRevoiceSessionTests.backend(stubs)
        whole.start(); await whole.waitForRun()
        try #require(whole.isStopped && whole.spent > 0 && whole.voice != nil)
        session.wholeClip = whole
        #expect(session.holdsPaidVoice && !session.hasPaidTakes)
        session.matchThisVideo()
        _ = await session.takesTask?.value
        #expect(generation.selectedVoiceID == anchor.id, "the paid whole clip keeps its voice")
    }

    /// A whole clip still running with nothing paid holds no voice: its own run chooses the video's voice before it pays.
    @Test func aWholeClipWithNothingPaidYetHoldsNoVoice() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        let stubs = WholeClipRevoiceSessionTests.Stubs()
        stubs.voiceError = WholeClipRevoiceSession.Unsent(error: WholeClipRevoiceSessionTests.refusal)
        let whole = WholeClipRevoiceSession()
        whole.backend = WholeClipRevoiceSessionTests.backend(stubs)
        whole.start(); await whole.waitForRun()
        fixture.session.wholeClip = whole
        #expect(whole.isStopped && whole.spent == 0 && !fixture.session.holdsPaidVoice && !fixture.session.hasUnusedPaidWork)
        // Nothing paid: Close Rewrite closes at once.
        #expect(fixture.editor.closeRewrite(returnFocus: false) && !fixture.session.isOpen)
    }
}

/// Drains ready AppKit and SwiftUI work without ordering a window on screen.
@MainActor private func pumpRunLoop() {
    _ = RunLoop.current.run(mode: .default, before: Date())
}

private struct PaidGuardTestKeys: KeyProvider {
    func key(for provider: String) async throws -> String? { Issue.record("Guard tests must not ask for credentials"); return nil }
}
#endif
