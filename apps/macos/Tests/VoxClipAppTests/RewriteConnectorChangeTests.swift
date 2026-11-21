#if DEBUG
import AppKit
import Foundation
import Testing
@testable import VoxClip
@testable import VoxClipCore
@testable import VoxClipMedia

private struct ConnectorChangeKeys: KeyProvider {
    func key(for provider: String) async throws -> String? { Issue.record("AI change tests must not ask for credentials"); return nil }
}

/// A change of AI in Settings (the connector, its model, server or CLI path) closes a Rewrite whose proposal came from the
/// old AI, but never one that holds paid work: its takes stay valid (the AI only matters for asking again) and the status
/// bar says so. It used to close it, and the paid takes went with it.
@MainActor @Suite(.serialized, .offlineFixtures) struct RewriteConnectorChangeTests {
    private func open(paid: Bool) async throws -> (AppModel, EditorModel, RewriteSession, URL) {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-connector-change-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let app = AppModel(settingsStore: RegressionSettingsStore(), locations: DataLocations(environment: ["VOXCLIP_DATA_DIR": root.path]))
        app.loadCatalogue()
        app.settings.values["llm.connector"] = .string("claude-code")
        app.settings.values["llm.model.claude-code"] = .string("opus")
        let shared = try SharedResources.locate()
        var project = try JSONProjectStore.decode(Data(contentsOf: shared.root.appendingPathComponent("fixtures/projects/interview-take.voxclip")))
        project.id = UUID().uuidString.lowercased()
        await app.shell.attachForTesting(VoxClipDocument(project: project, demo: true), selection: .fullTake)
        let editor = try #require(app.shell.editor)
        let signature = editor.rewriteConnectorSignature
        let session = RewriteSession(editor: editor, scope: .fullTake, envelope: nil, connector: nil,
                                     connectorIsCurrent: { [weak editor] in editor?.rewriteConnectorSignature == signature })
        editor.openRewrite = session
        if paid {
            session.configureGeneration(client: ElevenLabsVoiceLab(keys: ConnectorChangeKeys(), region: .default),
                store: VoiceConsentStore(locations: app.locations), speaker: .unavailable)
            let generation = try #require(session.generation)
            let rate = project.media.source.audio?.sampleRate ?? 48_000
            let start = Int64(2 * rate), end = Int64(3 * rate)
            let window = VoiceLabWindow(firstWordId: editor.words[1].id, lastWordId: editor.words[1].id, leftBridgeWordIds: [], rightBridgeWordIds: [],
                start: 2, end: 3, startSample: start, endSample: end, leftSeam: .init(kind: .gap, time: 2, sample: start, fadeSamples: 0),
                rightSeam: .init(kind: .gap, time: 3, sample: end, fadeSamples: 0))
            let plan = VoiceLabFitPlan(edits: [], incoming: .init(padFrames: 0, borrowedSamples: 0), outgoing: .init(padFrames: 0, borrowedSamples: 0),
                trimStartFrame: 0, trimEndFrame: 24_000, windowStart: 2, windowEnd: 3, windowStartSample: start, windowEndSample: end,
                outputFrames: 24_000, words: [VoiceLabWord(text: "Hello", start: 0.1, end: 0.9, synthetic: true)])
            let audio = VoiceLabTakeAudio(sampleRate: 24_000, trimmed: [0.1], mixed: [0.1], patchRange: 0..<1, seams: [], gainDb: 0, roomTone: nil, fit: .exact(plan))
            let qa = VoiceLabTakeQAResult(values: VoiceLabQA(transcriptMatch: 1, lufsJumpLu: 0, peakDbfs: -20, speakerScore: 0.8), failures: [])
            let input = VoiceLabTakeInput(text: "Hello", modelID: "fixture-model", recordID: "fixture-record", language: "en", seed: 7,
                contentKey: project.media.source.contentKey, source: [], sourceSampleRate: rate, items: editor.words,
                window: window, incomingSilence: nil, outgoingSilence: nil, providerConsent: true)
            generation.review(VoiceLabTakeRunResult(rows: [VoiceLabTakeRow(id: UUID(), index: 0, seed: 7, audio: audio, qa: qa, score: 1)], end: .completed),
                              input: input)
        }
        return (app, editor, session, root)
    }

    @Test(arguments: ["llm.model.claude-code", "llm.connector", "llm.cliPath.claude-code"])
    func anAIChangeKeepsARewriteHoldingPaidTakesOpen(_ key: String) async throws {
        let (app, editor, session, root) = try await open(paid: true)
        defer { editor.close(); try? FileManager.default.removeItem(at: root) }
        #expect(session.hasPaidWork)
        #expect(app.set(key, .string(key == "llm.connector" ? "codex" : "/fixture/other")))
        #expect(editor.openRewrite === session && session.isOpen && session.hasPaidWork)
        #expect(!session.current && session.voiceSpendCurrent)
        #expect(editor.rewriteNotice == EditorModel.rewriteConnectorKeptNotice(session.paidWorkKept.kept))
        #expect(editor.rewriteNotice?.hasPrefix("The AI changed. Your paid take") == true && session.task.confirm == nil, "\(editor.rewriteNotice ?? "")")
    }

    /// The whole clip's variant: its paid voice is kept through an AI change, as paid takes are. What the voice and lip sync
    /// are made from has no AI in it (`wholeClipInputsCurrency`), so Try Again after a failed lip sync reaches Review over
    /// the paid voice and Use puts it in; only a new wording, which asks the AI, waits for Rewrite Again.
    @Test func anAIChangeKeepsAPaidWholeClipUsable() async throws {
        let (app, editor, _, root) = try await open(paid: false)
        defer { editor.close(); try? FileManager.default.removeItem(at: root) }
        var project = editor.project
        project.edits.clips = [ClipRange(id: "clip-a", startWordId: editor.words[0].id, endWordId: editor.words[editor.words.count - 1].id)]
        project.edits.activeClipId = "clip-a"
        editor.replace(project, name: "Keep clip")
        editor.discardRewrite(returnFocus: false)
        let signature = editor.rewriteConnectorSignature
        let session = RewriteSession(editor: editor, scope: .clip("clip-a"), envelope: nil, connector: nil,
                                     connectorIsCurrent: { [weak editor] in editor?.rewriteConnectorSignature == signature })
        editor.openRewrite = session
        let stubs = WholeClipRevoiceSessionTests.Stubs()
        stubs.isCurrent = session.wholeClipInputsCurrency()
        stubs.lipsyncError = WholeClipRevoiceSession.LipsyncFailed(error: LipsyncError.http(503), local: false)
        let whole = WholeClipRevoiceSession()
        whole.backend = WholeClipRevoiceSessionTests.backend(stubs)
        stubs.session = whole
        session.wholeClip = whole
        await whole.refreshQuote()
        whole.start(); await whole.waitForRun()
        try #require(whole.failure?.step == .lipsync && whole.spent > 0 && session.hasUnusedPaidWork)
        #expect(app.set("llm.model.claude-code", .string("sonnet")))
        #expect(editor.openRewrite === session && session.isOpen && session.task.confirm == nil, "kept open, never asked")
        #expect(editor.rewriteNotice == EditorModel.rewriteConnectorKeptNotice("Your paid whole-clip voice is kept"))
        #expect(!session.current && session.voiceSpendCurrent && stubs.isCurrent?() == true, "the AI is no part of what the voice is made from")
        #expect(session.wholeClipStoppedActions().first?.id == "wholeClipRetry")
        stubs.lipsyncError = nil
        whole.start(); await whole.waitForRun()
        #expect(whole.phase == .review && stubs.voices.count == 1 && stubs.lipsyncs.count == 2, "\(whole.phase)")
        await whole.use()
        #expect(whole.phase == .used && stubs.used == 1)
    }

    @Test func anAIChangeStillClosesARewriteWithNothingPaid() async throws {
        let (app, editor, session, root) = try await open(paid: false)
        defer { editor.close(); try? FileManager.default.removeItem(at: root) }
        #expect(!session.hasPaidWork)
        #expect(app.set("llm.model.claude-code", .string("sonnet")))
        #expect(editor.openRewrite == nil && !session.isOpen && editor.rewriteNotice == nil)
    }
}
#endif
