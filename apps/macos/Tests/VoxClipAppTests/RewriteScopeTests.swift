#if DEBUG
import AppKit
import Foundation
import Synchronization
import Testing
@_spi(Testing) @testable import VoxClipCore
@testable import VoxClipMedia
@testable import VoxClip

/// A stub connector for Rewrite: a selection's passage request gets "A clearer passage"; a clip's or Full take's
/// `patch_edits` request gets the edits `reply` builds from the request's own lines. It records each request and, with
/// `hold`, waits for `release()` before answering; `untilWaiting()` returns once it waits. Nothing leaves the Mac.
private actor ScopeStub: LLMConnector {
    typealias Edit = (line: String, text: String, reason: String)
    nonisolated let id: ConnectorID
    private let authMethod: String?
    private let hold: Bool
    private let reply: @Sendable ([RewriteFixtureReply.Line]) -> [Edit]
    private var waiting: TestContinuation<Void>?
    private var arrivals: [TestContinuation<Void>] = []
    private var fitReplies: [String] = []
    private var fitHold = false
    private var fitCalls = 0
    var fitRequests: [LLMRequest] { requests.filter { $0.tag == "voice-rewrite-fit" } }
    func configureFit(_ replies: [String], hold: Bool = false) {
        fitReplies = replies; fitHold = hold; fitCalls = 0
    }
    /// The passage replies the next `voice-rewrite` sends get, in order; `hold` makes the next one wait for `release()`.
    private var rewriteReplies: [String] = []
    private var holdNextRewrite = false
    func configureRewrites(_ replies: [String], hold: Bool = false) { rewriteReplies = replies; holdNextRewrite = hold }
    var rewriteRequests: [LLMRequest] { requests.filter { $0.tag == "voice-rewrite" } }
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
        let holdsRewrite = holdNextRewrite && request.tag == "voice-rewrite"
        if holdsRewrite { holdNextRewrite = false }
        if hold || holdsRewrite || (fitHold && request.tag == "voice-rewrite-fit") { await withTestDeadline { waiting = $0; arrivals.forEach { $0.resume() }; arrivals = [] } }
        if request.tag == "voice-rewrite", !rewriteReplies.isEmpty {
            return RawCompletion(text: rewriteReplies.removeFirst(), model: model, stop: .complete)
        }
        if request.tag == "voice-rewrite-fit", !fitReplies.isEmpty {
            let text = fitReplies[min(fitCalls, fitReplies.count - 1)]
            fitCalls += 1
            return RawCompletion(text: text, model: model, stop: .complete)
        }
        let text = request.tag == "patch-rewrite" ? RewriteFixtureReply.patch(reply(RewriteFixtureReply.lines(of: request))) : "{\"rewrite\":\"A clearer passage\"}"
        return RawCompletion(text: text, model: model, stop: .complete)
    }
    /// Returns once a send waits for `release()`; a release before that would leave the send waiting for good.
    func untilWaiting() async { if waiting == nil { await withTestDeadline { arrivals.append($0) } } }
    func release() { waiting?.resume(); waiting = nil }
}

/// Takes never ask for an ElevenLabs key here: nothing is generated or sent.
private struct ScopeTakeKeys: KeyProvider {
    func key(for provider: String) async throws -> String? { Issue.record("Rewrite scope tests must not ask for credentials"); return nil }
}

/// Holds a take's publication until the test lets it go.
@MainActor private final class PublicationHold {
    private var reached = false
    private var arrival: TestContinuation<Void>?
    private var release: TestContinuation<Void>?
    func pause() async { await withTestDeadline { release = $0; reached = true; arrival?.resume(); arrival = nil } }
    func wait() async { if !reached { await withTestDeadline { arrival = $0 } } }
    func resume() { release?.resume(); release = nil }
}

/// Where Rewrite's Core work ran, as `EditorModel.rewriteWorkProbe` reports it: true on the main thread.
private final class WorkThreads: Sendable {
    let onMain = Mutex<[Bool]>([])
    var values: [Bool] { onMain.withLock { $0 } }
    func record(_ main: Bool) { onMain.withLock { $0.append(main) } }
}

/// The sheets a run's route showed, answered yes.
@MainActor private final class Sheets {
    var shown: [ConnectorSendPrompt] = []
    func take() -> [ConnectorSendPrompt.Reason] { defer { shown = [] }; return shown.map(\.reason) }
}

/// `RewriteSession` takes a scope (impl-plan V13, plan M7): a clip and Full take through C1's plan, `PatchRewriteService`
/// and C2's diff, a selection through `VoiceRewriteService`; the free changes as one undo step; R3 and the way back; the
/// send's confirmation on an API key only; Edit › Rewrite {scope}; the Ask suggestions; and no Voice Lab gate. Stub
/// connectors and in-memory settings only; the app model never starts.
@Suite("Rewrite takes a scope", .serialized, .enabled(if: ProcessInfo.processInfo.environment["VOXCLIP_DATA_DIR"] != nil, "Use an isolated VOXCLIP_DATA_DIR for app-model tests; only stub connectors are called."), .offlineFixtures)
@MainActor struct RewriteScopeTests {
    /// An app whose AI is `connector` on the stub, with every sheet answered yes and logged. `locations` gives it its own
    /// data folder, so its log is its own.
    private func app(_ connector: String, stub: ScopeStub, locations: DataLocations? = nil) -> (AppModel, Sheets) {
        let app = AppModel(settingsStore: RegressionSettingsStore(), locations: locations)
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
    /// 10–45 and clip 2 over 50–70, open on `tab`. Each word lasts 0.4 s, or the whole second when `contiguous`, as in
    /// speech with no pause between words.
    private func editor(_ app: AppModel, words count: Int = 80, tab: String? = "c1", waveform: Bool = true, events: Set<Int> = [],
                        contiguous: Bool = false, adjust: (inout [TimedWord]) -> Void = { _ in }) throws -> (EditorModel, UndoManager) {
        let shared = try SharedResources.locate()
        var project = try DemoEditing.loadFixture(shared.root.appendingPathComponent("fixtures/projects/interview-take.voxclip"))
        project.id = UUID().uuidString.lowercased()
        project.edits = ProjectEdits()
        project.transcript?.words = (0..<count).map { index in
            TimedWord(id: "w\(index)", text: index % 20 == 19 ? "word\(index)." : "word\(index)", start: Double(index) + 1, end: Double(index) + (contiguous ? 2 : 1.4))
        }
        for index in events { project.transcript?.words[index].kind = .event; project.transcript?.words[index].text = "[laughter]" }
        if var words = project.transcript?.words { adjust(&words); project.transcript?.words = words }
        project.transcript?.durationSeconds = Double(count) + 2
        project.media.source.durationSeconds = Double(count) + 2
        if count > 70 {
            project.edits.clips = [ClipRange(id: "c1", startWordId: "w10", endWordId: "w45"), ClipRange(id: "c2", startWordId: "w50", endWordId: "w70")]
            project.edits.activeClipId = tab
        }
        let editor = EditorModel(document: VoxClipDocument(project: project), app: app, preview: DemoPreviewEngine())
        editor.mediaResolved = true; editor.refresh()
        // Nothing loads media here, so the waveform load that resolving it starts would replace the test's with none.
        editor.waveformTask?.cancel()
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
    /// Turns Voice Lab's Rewrite on, with the ElevenLabs consent, so takes are current.
    private func enableVoiceLab(_ app: AppModel) {
        app.settings.values["voiceLab.enabled"] = .bool(true)
        app.settings.values["voiceLab.betaNoticeAccepted"] = .bool(true)
        app.settings.values["voiceLab.providerConsent.elevenlabs"] = .bool(true)
        app.settings.values["transcription.elevenlabs.region"] = .string("default")
    }

    @Test func shortPhraseRecoveryOffersLongerWording() {
        let row = PhraseTimingRecovery(tooLong: false, priceAnyway: true) { _ in }
        #expect(row.retryTitle == "Ask for longer")
    }

    @Test func automaticFitStartsBeforePricing() async throws {
        let stub = ScopeStub()
        let (app, _) = app("ollama", stub: stub)
        enableVoiceLab(app)
        let (editor, _) = try editor(app)
        defer { editor.close() }
        editor.selectedWordIDs = ["w20", "w21"]
        _ = try await rewrite(editor)
        #expect(await stub.requests.count > 1)
    }

    private func fitFixture(_ connectorID: ConnectorID = .ollama, selected: [String] = ["w20", "w21"]) async throws -> (RewriteSession, ScopeStub, EditorModel) {
        let stub = ScopeStub(id: connectorID)
        let (app, _) = app(connectorID.rawValue, stub: stub)
        let (editor, _) = try editor(app)
        editor.selectedWordIDs = Set(selected)
        let session = try await rewrite(editor)
        enableVoiceLab(app)
        try session.receivePassage(String(repeating: "collaboratively ", count: 8))
        session.finishRun(seconds: 0.1)
        return (session, stub, editor)
    }

    private func fittingText(_ session: RewriteSession, ordinal: Int = 1) throws -> String {
        for count in 1...20 {
            let text = Array(repeating: "better", count: count).joined(separator: " ")
            var hunks = session.changes.map(\.hunk)
            hunks[ordinal - 1] = VoiceLabWordingFit.reword(hunks[ordinal - 1], text: text, tags: [])
            let review = try RewriteReview.build(hunks, session.reviewInputs)
            let voiceOrdinals = session.changes.indices.filter { session.changes[$0].hunk.kind == .voice }.map { $0 + 1 }
            if review.voiceHunks[try #require(voiceOrdinals.firstIndex(of: ordinal))].timing?.fits == true { return text }
        }
        throw RewriteSessionError.noSourceAudio
    }

    private func fitReply(_ text: String, ordinal: Int = 1, keep: Bool = false) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: ["phrases": [["ordinal": ordinal, "action": keep ? "keepOriginal" : "reword", "text": text]]])
        return try #require(String(data: data, encoding: .utf8))
    }

    @Test(arguments: [1]) func automaticWordingFitsAndStopsEarly(round: Int) async throws {
        let (session, stub, editor) = try await fitFixture()
        defer { editor.close() }
        let fitted = try fittingText(session)
        var replies = try Array(repeating: fitReply(session.changes[0].hunk.newTokens.joined(separator: " ")), count: round - 1)
        replies.append(try fitReply(fitted))
        await stub.configureFit(replies)
        await session.beginAutomaticWordingFit()
        #expect(session.wordingFit.round == round)
        #expect(session.wordingFit.completed)
        #expect(session.blockedVoiceOrdinals.isEmpty)
        #expect(session.changes[0].hunk.newTokens.joined(separator: " ") == fitted)
        #expect(await stub.fitRequests.count == round)
        #expect(session.takePlan == nil)
    }

    /// A reply line over its budget gets one free repair round (ai.md §12.9); still long, it keeps the speaker's words,
    /// since no take of it could fit the running video, and the footer goes on (MVP32 Clip 7: "Changes 3, 5 and 6 need a
    /// shorter wording before takes" with no button that did it).
    @Test func anOverBudgetLineIsRepairedOnceThenKeptAsRecorded() async throws {
        let (session, stub, editor) = try await fitFixture()
        defer { editor.close() }
        #expect(session.blockedVoiceOrdinals == [1] && session.voiceReview(1)?.timing?.tooLong == true)
        await stub.configureFit([try fitReply(session.changes[0].hunk.newTokens.joined(separator: " "))])
        await session.beginAutomaticWordingFit()
        #expect(session.wordingFit.round == 1)
        #expect(await stub.fitRequests.count == 1)
        #expect(session.blockedVoiceOrdinals.isEmpty && !session.includedVoice.contains(1))
        #expect(session.ownProposal?[1]?.state == .excluded && session.wordingFit.kept == [1])
        #expect(session.autoFix.notes.contains { $0.hasPrefix("Change 1 keeps your original words") })
        #expect(session.task.footer.note != session.timingBlockedNote)
        #expect(session.task.footer.primary != nil, "\(session.task.footer)")
        #expect(!session.task.wordingLocked)
    }

    /// MVP25 (2026-11-05): a viral rewrite turned one short word into two sentences. Its slot was so short that the
    /// word target's minimum was 0, the fit request refused it, and the whole wording fit failed with invalidInput.
    /// A phrase no wording can fit is priced as written now, and the others still go to the fit.
    @Test func aPhraseNoWordingCanFitIsPricedAsWrittenNotSentToTheWordingFit() async throws {
        let (session, stub, editor) = try await fitFixture(selected: ["w20"])
        defer { editor.close() }
        try session.receivePassage("Stop scrolling right now. Here is the truth that nobody ever tells you about this.")
        session.finishRun(seconds: 0.1)
        let blocked = session.blockedVoiceOrdinals
        let phrases = try session.fitPhrases(ordinals: blocked)
        #expect(phrases.allSatisfy { $0.target.minimum > 0 && $0.target.maximum >= $0.target.minimum })
        await stub.configureFit([try fitReply("Stop scrolling.")])
        await session.beginAutomaticWordingFit()
        #expect(!session.wordingFit.problem.contains("ElevenLabs can't take"), "\(session.wordingFit.problem)")
        #expect(session.wordingFit.problem.isEmpty, "\(session.wordingFit.problem) blocked \(blocked)")
    }

    /// The user's log (2026-11-05): `stage=wordingFit type=VoiceLabError case=invalidInput` as the fit was prepared. A fit
    /// that can't start ends with the held change kept as recorded and a step forward, never a control that sends the
    /// same fit again.
    @Test func aWordingFitThatCannotStartKeepsTheWordsAndGoesOn() async throws {
        let (session, _, editor) = try await fitFixture()
        defer { editor.close() }
        let held = session.blockedVoiceOrdinals
        #expect(!held.isEmpty && held.allSatisfy { session.voiceReview($0)?.timing?.tooLong == true })
        session.wordingFitFailed(VoiceLabError.invalidInput)
        #expect(!session.wordingFit.problem.isEmpty && session.wordingFit.completed && !session.wordingIsLocked)
        #expect(held.allSatisfy(session.wordingFit.kept.contains) && session.blockedVoiceOrdinals.isEmpty)
        #expect(session.task.footer.primary != nil, "\(session.task.footer)")
        #expect(session.task.footer.primary?.id != "fitWording" && !session.task.cards.contains { card in
            if case .nextSteps(let steps) = card { return steps.chips.contains { $0.action.id.hasPrefix("fit") } } else { return false }
        })
    }

    @Test func automaticWordingKeepsTheRecordingOnlyForAStructuredDecision() async throws {
        let (session, stub, editor) = try await fitFixture()
        defer { editor.close() }
        await stub.configureFit([try fitReply("", keep: true)])
        await session.beginAutomaticWordingFit()
        #expect(await stub.fitRequests.count == 1)
        #expect(session.wordingFit.kept == [1])
        #expect(session.ownProposal?[1]?.state == .excluded)
        #expect(session.task.footer.note == "0 phrases fit · 1 kept as recorded")
        #expect(session.takePlan == nil)
    }

    @Test(arguments: [false, true]) func stoppingOrEditingCancelsWordingRounds(edit: Bool) async throws {
        let (session, stub, editor) = try await fitFixture()
        defer { editor.close() }
        let before = session.changes
        await stub.configureFit([try fitReply(fittingText(session))], hold: true)
        let work = Task { await session.beginAutomaticWordingFit() }
        await stub.untilWaiting()
        #expect(session.wordingFit.running)
        #expect(session.task.wordingLocked)
        #expect(session.task.footer.primary == nil)
        if edit { #expect(editor.editChange(1, text: "Edited by the user")) }
        else { session.stopWordingFit() }
        await stub.release()
        await work.value
        #expect(session.wordingFit.stopped)
        #expect(!session.wordingFit.running)
        #expect(await stub.fitRequests.count == 1)
        #expect(session.changes == before)
        if edit { #expect(editor.changeReadings.first?.text == "Edited by the user") }
        #expect(!editor.llmRuns.isBusy)
    }

    @Test(arguments: [false, true]) func APIWordingApprovalCoversThisReplyOnlyAndCanBeSkipped(approve: Bool) async throws {
        let (session, stub, editor) = try await fitFixture(.anthropic)
        defer { editor.close() }
        await stub.configureFit([try fitReply(session.changes[0].hunk.newTokens.joined(separator: " "))])
        await session.beginAutomaticWordingFit()
        #expect(session.wordingFit.awaitingApproval)
        #expect(await stub.fitRequests.isEmpty)
        if approve {
            await session.fitWording(approved: true)
            #expect(await stub.fitRequests.count == 1)
            #expect(!session.wordingFit.awaitingApproval)
            // The unfitted change now keeps its words, so another automatic fit has nothing to ask about and sends
            // nothing: the approval covered that reply only.
            await session.beginAutomaticWordingFit()
            #expect(!session.wordingFit.awaitingApproval && session.blockedVoiceOrdinals.isEmpty)
            #expect(await stub.fitRequests.count == 1)
        } else {
            session.stopWordingFit()
            #expect(await stub.fitRequests.isEmpty)
            #expect(session.ownProposal?[1]?.state == .pending)
        }
        #expect(session.takePlan == nil)
    }

    @Test func fittedPhrasesAreFrozenAndNeverResent() async throws {
        let (session, stub, editor) = try await fitFixture(selected: (20...31).map { "w\($0)" })
        defer { editor.close() }
        let first = RewriteChange(hunk: try #require(VoiceLabWordDiff.diff(source: Array(session.source.prefix(2)),
            newText: String(repeating: "collaboratively ", count: 8)).hunks.first))
        let second = RewriteChange(hunk: try #require(VoiceLabWordDiff.diff(source: Array(session.source.suffix(2)),
            newText: "Some completely different wording").hunks.first))
        session.receive([first, second]); session.finishRun(seconds: 0.1)
        let text = try fittingText(session, ordinal: 2)
        try session.applyWordingFit([.init(ordinal: 2, keepOriginal: false, text: text)])
        let frozen = session.changes[1]
        await stub.configureFit([try fitReply("", keep: true)])
        await session.beginAutomaticWordingFit()
        let requests = await stub.fitRequests
        #expect(requests.count == 1)
        #expect(requests.allSatisfy { $0.cachedBlock?.contains("Phrase 2\n") == false })
        #expect(session.changes[1] == frozen)
    }

    @Test func newRewriteUsesOnlyV4AndThePanelHasAFixedModelLabel() async throws {
        let (session, _, editor) = try await fitFixture()
        defer { editor.close() }
        #expect(session.synthesisModel == "eleven_v4")
        #expect(DirectorTakeRows.rewriteModelLabel == "Eleven v4 · audio tags")
    }

    @Test func longPhraseIsBlockedBeforePricing() async throws {
        let (app, _) = app("ollama", stub: ScopeStub())
        enableVoiceLab(app)
        let (editor, _) = try editor(app)
        defer { editor.close() }
        editor.selectedWordIDs = ["w20", "w21"]
        let session = try await rewrite(editor)
        try session.receivePassage(String(repeating: "collaboratively ", count: 8))
        session.finishRun(seconds: 0.1)
        #expect(session.includedVoice.isEmpty)
        #expect(session.task.footer.note == "Change \(try #require(session.blockedVoiceOrdinals.first)) needs a shorter wording before takes.")
        // Never a dead end (design.md R2): the held change can keep the speaker's words.
        #expect(session.task.footer.primary?.id == "keepMyWords")
    }

    @Test func priceOverrideAndOriginalWordsDoNotSendAnything() async throws {
        let stub = ScopeStub()
        let (app, _) = app("ollama", stub: stub)
        enableVoiceLab(app)
        let (editor, _) = try editor(app)
        defer { editor.close() }
        editor.selectedWordIDs = ["w20", "w21"]
        let session = try await rewrite(editor)
        try session.receivePassage(String(repeating: "collaboratively ", count: 8))
        session.finishRun(seconds: 0.1)
        let ordinal = try #require(session.blockedVoiceOrdinals.first)
        let item = try #require(session.task.changes?.items.first)
        let sendsBeforeRecovery = await stub.requests.count
        #expect(item.timing?.copy.hasPrefix("≈ ") == true && item.timing?.fits == false)
        #expect(session.includedVoice.isEmpty)
        session.phraseTimingAction(.priceAnyway, ordinal: ordinal)
        #expect(session.includedVoice == [ordinal])
        #expect(session.task.footer.primary?.title == "Get Price · 1 phrase")
        #expect(session.task.footer.note?.hasPrefix("Nothing paid yet.") == true)
        session.phraseTimingAction(.original, ordinal: ordinal)
        #expect(session.ownProposal?[ordinal]?.state == .excluded && session.includedVoice.isEmpty)
        #expect(await stub.requests.count == sendsBeforeRecovery)
        #expect(RewriteSession.firstTakeVerb(hasTakes: false) == "Make take")
        #expect(RewriteSession.firstTakeVerb(hasTakes: true) == "Try another")
    }

    @Test func shortPhraseDoesNotClaimItNeedsShortening() async throws {
        let (app, _) = app("ollama", stub: ScopeStub())
        enableVoiceLab(app)
        let (editor, _) = try editor(app, contiguous: true)
        defer { editor.close() }
        editor.selectedWordIDs = ["w20", "w21"]
        let session = try await rewrite(editor)
        try session.receivePassage("Hi.")
        session.finishRun(seconds: 0.1)
        let ordinal = try #require(session.blockedVoiceOrdinals.first)
        let timing = try #require(session.voiceReview(ordinal)?.timing)
        #expect(!timing.fits && !timing.tooLong)
        #expect(session.task.footer.note == "Change \(ordinal) needs wording that fits before takes.")
        #expect(session.task.footer.primary?.id == "keepMyWords")
        let recovery = PhraseTimingRecovery(tooLong: false, priceAnyway: true, action: { _ in })
        #expect(recovery.retryTitle == "Ask for longer")
        app.settings.values["voiceLab.providerConsent.elevenlabs"] = .bool(false)
        session.phraseTimingAction(.surrounding, ordinal: ordinal)
        #expect(session.surroundingSentenceOrdinal == ordinal)
        #expect(session.takeRowsShown)
        #expect(!session.includedVoice.contains(ordinal))
    }

    @Test(arguments: ["ollama", "anthropic"])
    func shorterWordingReplacesTheProposalWithFreshSendConsent(_ provider: String) async throws {
        let stub = ScopeStub(id: try #require(ConnectorID(rawValue: provider)))
        let (app, sheets) = app(provider, stub: stub)
        enableVoiceLab(app)
        let (editor, _) = try editor(app)
        defer { editor.close() }
        editor.selectedWordIDs = ["w20", "w21"]
        let session = try await rewrite(editor)
        _ = sheets.take()
        try session.receivePassage(String(repeating: "collaboratively ", count: 8))
        session.finishRun(seconds: 0.1)
        let ordinal = try #require(session.blockedVoiceOrdinals.first)
        let expected = try session.shorterFeedbackBlock(ordinals: [ordinal])
        #expect(expected.contains("Original words: word20 word21"))
        #expect(expected.contains("Proposed words: collaboratively"))
        #expect(expected.contains("Estimated:") && expected.contains("slot:"))
        session.pricedAnyway.insert(ordinal)
        session.phraseTimingAction(.shorter, ordinal: ordinal)
        await editor.rewriteOpenTask?.value
        await session.actionTask?.value
        let rewrites = await stub.requests.filter { $0.tag != "voice-rewrite-fit" }
        let request = try #require(rewrites.last)
        #expect(rewrites.count == 2)
        #expect(request.instruction.hasSuffix(expected))
        #expect(sheets.take() == (provider == "anthropic" ? [.cost] : []))
        #expect(session.pricedAnyway.isEmpty)
        #expect(session.task.changes?.items.first?.quote == "A clearer passage")
        #expect(session.rewriteScope == RewriteScope.selection(20...21))
    }
    /// Gives `session` one reviewed take, ready to use: no provider is called.
    private func giveTake(_ session: RewriteSession, editor: EditorModel) throws -> RewriteGenerationSession {
        let root = editor.app.locations.root
        session.configureGeneration(client: ElevenLabsVoiceLab(keys: ScopeTakeKeys(), region: .default),
                                    store: VoiceConsentStore(locations: DataLocations(environment: ["VOXCLIP_DATA_DIR": root.path])), speaker: .unavailable)
        let generation = try #require(session.generation)
        let sourceRate = editor.project.media.source.audio?.sampleRate ?? 48_000
        let fallbackStart = Int64(21 * sourceRate)
        let fallbackEnd = Int64(EditingPrimitives.jsRound(22.4 * Double(sourceRate)))
        let fade = Int64(EditingPrimitives.jsRound(0.020 * Double(sourceRate)))
        let fallback = VoiceLabWindow(firstWordId: "w20", lastWordId: "w21", leftBridgeWordIds: [], rightBridgeWordIds: [], start: 21, end: 22.4,
            startSample: fallbackStart, endSample: fallbackEnd, leftSeam: .init(kind: .gap, time: 21, sample: fallbackStart, fadeSamples: fade),
            rightSeam: .init(kind: .gap, time: 22.4, sample: fallbackEnd, fadeSamples: fade))
        let window = session.review?.voiceHunks.first?.window ?? fallback
        let frames = Int64(EditingPrimitives.jsRound((window.end - window.start) * 24_000))
        let plan = VoiceLabFitPlan(edits: [], incoming: .init(padFrames: 0, borrowedSamples: 0), outgoing: .init(padFrames: 0, borrowedSamples: 0),
            trimStartFrame: 0, trimEndFrame: frames, windowStart: window.start, windowEnd: window.end,
            windowStartSample: window.startSample, windowEndSample: window.endSample,
            outputFrames: frames, words: [VoiceLabWord(text: "Hello", start: 0.1, end: 0.9, synthetic: true)])
        let audio = VoiceLabTakeAudio(sampleRate: 24_000, trimmed: [0.1], mixed: [0.1], patchRange: 0..<1, seams: [], gainDb: 0, roomTone: nil, fit: .exact(plan))
        let qa = VoiceLabTakeQAResult(values: VoiceLabQA(transcriptMatch: 1, lufsJumpLu: 0, peakDbfs: -20, speakerScore: 0.8), failures: [])
        let row = VoiceLabTakeRow(id: UUID(), index: 0, seed: 0, audio: audio, qa: qa, score: 1, failure: nil)
        let input = VoiceLabTakeInput(text: "new words", modelID: "fixture-model", recordID: "fixture-record", language: "en", seed: 7,
            contentKey: editor.project.media.source.contentKey, source: [], sourceSampleRate: sourceRate, items: editor.words,
            window: window, incomingSilence: nil, outgoingSilence: nil, providerConsent: true)
        generation.review(VoiceLabTakeRunResult(rows: [row], end: .completed), input: input)
        #expect(generation.chooseVideo(.source))
        return generation
    }
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
    /// The failure goes to the app log by its code, never its words.
    @Test func aClipWithEveryWordCutSaysSo() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-rewrite-log-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let stub = ScopeStub()
        let (app, _) = app("ollama", stub: stub, locations: DataLocations(environment: ["VOXCLIP_DATA_DIR": root.path]))
        let (editor, undo) = try editor(app)
        defer { editor.close() }
        step(undo) { editor.apply(.cutSelection(ids: (10...45).map { "w\($0)" }), name: "Cut selection") }
        let session = try await rewrite(editor)
        #expect(session.task.state == .error(.message("Clip 1 has no words left to rewrite. Your edits are saved.")))
        #expect(await stub.requests.isEmpty)
        let log = (try? String(contentsOf: app.locations.logs.appendingPathComponent("voxclip.log"), encoding: .utf8)) ?? ""
        #expect(log.contains("[error] llm: code=operationFailed") && !log.contains("word10"))
    }

    /// With Voice Lab off, a selection beside a cut still rewrites (design.md §8). In speech with no pause between words
    /// its window starts at the cut (a seam at a cut, voice-lab §8.4 step 5, 2026-11-09; it was refused until then), and
    /// the request takes the selection's span as its length, as C1's lines do. With no waveform the same holds, and the
    /// phrase says what it needs.
    @Test func aSelectionNeedsNoVoicePlacement() async throws {
        let stub = ScopeStub()
        let (app, _) = app("ollama", stub: stub)
        let (editor, undo) = try editor(app, contiguous: true)
        defer { editor.close() }
        #expect(!app.voiceLabRewriteEnabled)
        step(undo) { editor.apply(.cutSelection(ids: ["w40"]), name: "Cut selection") }
        editor.selectedWordIDs = ["w41", "w42", "w43"]
        let session = try await rewrite(editor)
        #expect(proposal(session) != nil && session.problem.isEmpty)
        #expect(await stub.requests.map(\.tag) == ["voice-rewrite"])
        let placed = session.review?.voiceHunks.first
        #expect(placed?.refusal == nil && placed?.window?.leftSeam.kind == .hard && placed?.window?.start == 42, "\(String(describing: placed?.refusal))")

        editor.closeRewrite(returnFocus: false)
        editor.selectedWordIDs = ["w12", "w13", "w14"]
        let connector = RewriteConnector(connector: stub, model: "fixture-local", name: "Ollama", group: "local", plan: "")
        let silent = RewriteSession(editor: editor, scope: .selection(12...14), envelope: nil, connector: connector, consent: { true })
        editor.rewrite = silent
        #expect(await silent.run())
        #expect(proposal(silent) != nil)
        #expect(await stub.requests.count == 2)
        #expect(silent.review?.voiceHunks.map(\.refusal) == ["Find the original video before rewriting speech. Your edits are saved."])
    }

    /// Rewrite's Core work runs off the main actor (impl-plan §3.1): the selection's placement and the reply's review on a
    /// run, and the review again after an edit outside the scope, which returns before it is built. A far cut and one
    /// beside the passage both end in the review the edited take gives; cuts and fixes alone build nothing again.
    @Test func coreWorkRunsOffTheMainActor() async throws {
        let stub = ScopeStub()
        let (app, _) = app("ollama", stub: stub)
        let (editor, undo) = try editor(app, tab: nil)
        defer { editor.close() }
        let threads = WorkThreads()
        editor.rewriteWorkProbe = { threads.record($0) }
        editor.selectedWordIDs = ["w62", "w63", "w64"]
        let session = try await rewrite(editor)
        #expect(session.scope == .full && session.review?.voiceHunks.count == 1 && proposal(session) != nil)
        #expect(threads.values == [false, false])
        for cut in ["w20", "w61"] {
            step(undo) { editor.apply(.cutSelection(ids: [cut]), name: "Cut selection") }
            let reviewing = try #require(session.reviewing, "\(cut) is reviewed again after the edit returns")
            #expect(session.current && proposal(session) != nil)
            await reviewing.value
            let fresh = try RewriteReview.build(session.changes.map(\.hunk), session.reviewInputs)
            #expect(session.reviewing == nil && session.review.map { fresh.makesTheSameTakes(as: $0) } == true)
        }
        #expect(threads.values == [false, false, false, false])

        editor.selectedWordIDs = []
        #expect(editor.setScope("c1"))
        let clip = try await rewrite(editor)
        #expect(clip.review?.voiceHunks.isEmpty == true && threads.values.count == 6 && !threads.values.contains(true))
        step(undo) { editor.apply(.cutSelection(ids: ["w60"]), name: "Cut selection") }
        #expect(clip.reviewing == nil && clip.current && threads.values.count == 6)
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
        // The list's Undo leaves the change out (impl-plan item 7): no project change and no undo step.
        session.review(1, .undo)
        let set = try #require(proposal(session))
        #expect(set.items.map(\.state) == [.excluded] && !undo.canUndo)
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
        await editor.rewriteOpenTask?.value
        await session.actionTask?.value
        #expect(proposal(session) != nil && session.task.turn == 2 && session.project == editor.project)
        #expect(await stub.requests.count == 2)
    }

    /// The clip's title, and keeping a suggested clip, lie outside the scope: the proposal stays, and so does one on a
    /// selection inside the renamed clip (design.md R3 "Edits outside the scope don't affect the proposal").
    @Test func renamingOrKeepingTheClipKeepsTheProposal() async throws {
        let stub = ScopeStub()
        let (app, _) = app("ollama", stub: stub)
        let (editor, undo) = try editor(app)
        defer { editor.close() }
        let session = try await rewrite(editor)
        let set = try #require(proposal(session))
        step(undo) { editor.apply(.renameClip(id: "c1", title: "Intro"), name: "Rename clip") }
        #expect(proposal(session) == set && session.current && session.project == editor.project && session.applyTitle == "Apply 1 Change")

        editor.selectedWordIDs = ["w12", "w13", "w14"]
        let selection = try await rewrite(editor)
        #expect(selection !== session && selection.scope == .clip("c1") && proposal(selection) != nil)
        step(undo) { editor.apply(.renameClip(id: "c1", title: "Opening"), name: "Rename clip") }
        #expect(proposal(selection) != nil && selection.current)

        editor.selectedWordIDs = []
        var project = editor.project
        project.edits.clips[1].origin = .ai
        project.edits.clips[1].selected = false
        step(undo) { editor.replace(project, name: "Suggest") }
        #expect(editor.setScope("c2") && editor.isSuggestion("c2"))
        let suggestion = try await rewrite(editor)
        let suggested = try #require(proposal(suggestion))
        #expect(suggestion.rewriteScope == .clip("c2"))
        step(undo) { editor.keep("c2") }
        #expect(!editor.isSuggestion("c2") && proposal(suggestion) == suggested && suggestion.current && suggestion.isOpen)
        #expect(!editor.announcements.contains("Clip 2 changed."))
    }

    /// In R3, Rewrite Again and ⇧⌘R (the clip bar's Rewrite too) would drop the takes R3 says are kept: they ask
    /// "Discard this change?" for the proposal set aside first, inline in the Rewrite job's footer (impl-plan §13.1, no
    /// alert), and Keep Working, also Return's answer, sends nothing.
    @Test func rewriteAgainInR3AsksBeforeDiscardingTakes() async throws {
        let stub = ScopeStub()
        let (app, _) = app("ollama", stub: stub)
        enableVoiceLab(app)
        let (editor, undo) = try editor(app)
        defer { editor.close() }
        let session = try await rewrite(editor)
        let generation = try giveTake(session, editor: editor)
        #expect(!generation.rows.isEmpty && session.proposalCount == 1)
        step(undo) { editor.apply(.cutSelection(ids: ["w20"]), name: "Cut selection") }
        #expect(session.task.state == .changed && session.proposalCount == 1)
        #expect(texts(session.task).first?.hasSuffix("Your takes are kept until you close this.") == true)
        let footer = session.task.footer
        session.task.footer.primary?.perform()
        let asked = try #require(session.task.confirm)
        #expect(asked.question == "Discard this change?" && asked.cancel.title == "Keep Working" && asked.confirm.title == "Discard Changes")
        #expect(editor.announcements.last == "Discard this change?" && session.task.footer == footer)
        asked.cancel.perform()
        #expect(session.task.confirm == nil)
        editor.runRewrite()
        #expect(session.task.confirm?.question == "Discard this change?")
        #expect(session.task.pressReturn(command: true) && session.task.confirm == nil)
        await editor.rewriteOpenTask?.value
        #expect(session.generation === generation && session.task.state == .changed)
        #expect(await stub.requests.count == 1)
        session.task.footer.primary?.perform()
        try #require(session.task.confirm).confirm.perform()
        #expect(session.task.confirm == nil)
        await editor.rewriteOpenTask?.value
        await session.actionTask?.value
        #expect(session.generation == nil && proposal(session) != nil && session.task.confirm == nil)
        #expect(await stub.requests.count == 2)
    }

    /// While a take publishes for Use Takes, the user's edits are still followed: one outside the clip moves the session
    /// on, one inside it shows R3, and the refused acceptance leaves it there. The take is the reply's one phrase's.
    @Test func editsWhileATakePublishesAreFollowed() async throws {
        let stub = ScopeStub { lines in
            lines.compactMap { line -> ScopeStub.Edit? in
                guard line.words.contains("word20") else { return nil }
                return (line.label, line.words.map { $0 == "word20" ? "new" : $0 == "word21" ? "words" : $0 }.joined(separator: " "), "Clearer")
            }
        }
        let (app, _) = app("ollama", stub: stub)
        enableVoiceLab(app)
        let (editor, undo) = try editor(app)
        defer { editor.close() }
        let session = try await rewrite(editor)
        for ordinal in session.blockedVoiceOrdinals { session.pricedAnyway.insert(ordinal) }
        try #require(session.includedVoice.count == 1)
        let generation = try giveTake(session, editor: editor)
        #expect(generation.readyToAccept)
        let hold = PublicationHold()
        generation.publishForTests = { _, _, _ in await hold.pause(); throw CancellationError() }
        let accepting = Task { await generation.accept(into: editor) }
        await hold.wait()
        step(undo) { editor.apply(.cutSelection(ids: ["w60"]), name: "Cut selection") }
        #expect(session.project == editor.project && session.current && proposal(session) != nil)
        step(undo) { editor.apply(.cutSelection(ids: ["w20"]), name: "Cut selection") }
        #expect(session.task.state == .changed && session.task.headline.text == "Clip 1 changed")
        hold.resume()
        #expect(await accepting.value == false)
        #expect(session.isOpen && session.task.state == .changed && editor.project.voiceLab.segments.isEmpty)
        undo.undo()
        #expect(proposal(session) != nil && session.current)
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
        await stub.untilWaiting()
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
        let first: [ConnectorSendPrompt.Reason]
        let later: [ConnectorSendPrompt.Reason]
        let title: String
        let note: String
        var testDescription: String { connector }
    }
    nonisolated static let routes: [Route] = [
        Route(connector: "anthropic", authMethod: nil, first: [.cost], later: [.cost], title: "Rewrite Clip 1…",
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
            #expect(cost?.message == "Rewrite sends the 36 words of clip 1 to Anthropic with your key.")
            #expect(cost?.confirm == "Allow and Send" && cost?.firstUse == true)
            #expect(cost?.note == "VoxClip can't tell what this costs. Check Anthropic's pricing.")
        }
        #expect(session.sendLine == route.note && editor.rewriteMenuTitle == route.title)
        #expect(session.proposalButton == (route.first.contains(.cost) ? "Rewrite…" : "Rewrite"))
        _ = try await rewrite(editor)
        #expect(sheets.take() == route.later)
        #expect(await stub.requests.count == 2)
    }

    // MARK: Ask again (V15)

    /// R2's Ask again sends the scope again with the Ask field's text and replaces the proposal (design.md §6.3.1).
    @Test func askAgainSendsTheFieldsTextAgain() async throws {
        let stub = ScopeStub()
        let (app, _) = app("ollama", stub: stub)
        let (editor, _) = try editor(app)
        defer { editor.close() }
        let session = try await rewrite(editor)
        let first = try #require(session.ownProposal)
        #expect(session.task.contextAction?.title == "Ask again")
        editor.rewriteInstruction = "Make it shorter"
        session.task.contextAction?.perform()
        await editor.rewriteOpenTask?.value
        await session.actionTask?.value
        let request = await stub.requests.last
        #expect(await stub.requests.count == 2 && request?.instruction.hasSuffix("Instruction: Make it shorter, mostly by cutting. Keep my words and my voice.") == true)
        #expect(session.task.turn == 2 && session.ownProposal != nil && session.ownProposal?.id != first.id && editor.openRewrite === session)
    }

    /// A change edited in its popover is the user's work: Ask again asks "Discard this change?" first, in place of R2's
    /// footer, and Keep Working sends nothing and keeps the proposal. The question stays through a review in the transcript
    /// and goes with a new step.
    @Test func askAgainAsksBeforeDiscardingAnEditedChange() async throws {
        let stub = ScopeStub()
        let (app, _) = app("ollama", stub: stub)
        let (editor, _) = try editor(app)
        defer { editor.close() }
        let session = try await rewrite(editor)
        let first = try #require(session.ownProposal)
        #expect(!session.hasEditedChanges && editor.editChange(1, text: "hello") && session.hasEditedChanges)
        session.task.contextAction?.perform()
        #expect(session.task.confirm?.question == "Discard this change?")
        session.showProposal()
        let asked = try #require(session.task.confirm)
        asked.cancel.perform()
        await editor.rewriteOpenTask?.value
        #expect(session.task.confirm == nil && session.ownProposal?.id == first.id && session.isOpen)
        #expect(await stub.requests.count == 1)
        // A Discard Changes left from a question answered meanwhile sends nothing.
        asked.confirm.perform()
        await editor.rewriteOpenTask?.value
        #expect(await stub.requests.count == 1)
        session.task.contextAction?.perform()
        #expect(session.task.confirm != nil)
        session.task.show(.running, headline: PanelHeadline(text: session.task.words.title))
        #expect(session.task.confirm == nil)
    }

    /// A declined cost sheet on Ask again replaces nothing: the proposal shows again with its reviews, in the transcript
    /// and the list, and nothing is sent.
    @Test func aDeclinedAskAgainShowsTheProposalAgain() async throws {
        let stub = ScopeStub(id: .anthropic)
        let (app, sheets) = app("anthropic", stub: stub)
        let (editor, _) = try editor(app)
        defer { editor.close() }
        let session = try await rewrite(editor)
        session.review(1, .undo)
        let shown = try #require(proposal(session))
        #expect(sheets.take() == [.cost] && session.task.contextAction?.title == "Ask again…")
        app.connectorConsentOverride = { _, _, sheet in sheets.shown.append(sheet); return false }
        session.task.contextAction?.perform()
        await editor.rewriteOpenTask?.value
        await session.actionTask?.value
        #expect(sheets.take() == [.cost] && proposal(session) == shown && session.ownProposal?[1]?.state == .excluded && session.isOpen)
        #expect(await stub.requests.count == 1)
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
        #expect(proposal(session) != nil && editor.rewrite === session && session.current)
        #expect(!session.generationIsCurrent(region: .default))
    }

    /// A voice change's window reads the words beside the passage, so a cut there, outside the scope, can move it: the
    /// review built again says so, and the takes made for the old window can no longer be used. Use Takes waits for that
    /// review; a cut far away leaves the takes ready. In connected speech the cut word touches the passage, so the window
    /// stays where it was, its seam now at the cut (voice-lab §8.4 step 5, 2026-11-09), and the takes stay ready, also off
    /// the sample grid (§10.1). A cut word that really overlaps the passage refuses the window, and its takes retire.
    @Test func aCutBesideThePassageRetiresItsTakes() async throws {
        let stub = ScopeStub()
        let (app, _) = app("ollama", stub: stub)
        enableVoiceLab(app)
        let (editor, undo) = try editor(app, tab: nil, contiguous: true)
        defer { editor.close() }
        editor.selectedWordIDs = ["w62", "w63", "w64"]
        let session = try await rewrite(editor)
        #expect(session.scope == .full && session.review?.voiceHunks.first?.window != nil)
        let generation = try giveTake(session, editor: editor)
        var published = 0
        generation.publishForTests = { _, _, _ in published += 1; throw CancellationError() }
        step(undo) { editor.apply(.cutSelection(ids: ["w20"]), name: "Cut selection") }
        await session.reviewing?.value
        #expect(generation.readyToAccept && session.review?.voiceHunks.first?.window != nil)
        let before = session.review?.voiceHunks.first?.window
        step(undo) { editor.apply(.cutSelection(ids: ["w61"]), name: "Cut selection") }
        await session.reviewing?.value
        #expect(session.review?.voiceHunks.first?.window == before && generation.readyToAccept)
        // Off the source grid the touching boundary meets the stored edge on the grid (voice-lab §10.1, 2026-11-10; it was
        // refused until then), so the window stays there too and its takes stay ready.
        editor.closeRewrite(returnFocus: false)
        let (offGrid, offGridUndo) = try self.editor(app, tab: nil, contiguous: true) { words in
            words[61].end += 1e-9; words[62].start += 1e-9
        }
        defer { offGrid.close() }
        offGrid.selectedWordIDs = ["w62", "w63", "w64"]
        let touching = try await rewrite(offGrid)
        let offGridWindow = try #require(touching.review?.voiceHunks.first?.window)
        let offGridTakes = try giveTake(touching, editor: offGrid)
        offGridTakes.publishForTests = { _, _, _ in throw CancellationError() }
        step(offGridUndo) { offGrid.apply(.cutSelection(ids: ["w61"]), name: "Cut selection") }
        await touching.reviewing?.value
        #expect(touching.review?.voiceHunks.first?.window == offGridWindow && offGridTakes.readyToAccept)
        // A word that really overlaps the passage is bridged while it is kept; cut, it crosses the seam at the cut, so the
        // review built again refuses the window and the takes for the old window retire.
        offGrid.closeRewrite(returnFocus: false)
        let (overlap, overlapUndo) = try self.editor(app, tab: nil, contiguous: true) { words in
            words[60].end -= 0.5; words[61].end = words[62].start + 0.1
        }
        defer { overlap.close() }
        overlap.selectedWordIDs = ["w62", "w63", "w64"]
        let crossing = try await rewrite(overlap)
        #expect(crossing.review?.voiceHunks.first?.window?.leftBridgeWordIds == ["w61"])
        let takes = try giveTake(crossing, editor: overlap)
        var publishedOverlap = 0
        takes.publishForTests = { _, _, _ in publishedOverlap += 1; throw CancellationError() }
        step(overlapUndo) { overlap.apply(.cutSelection(ids: ["w61"]), name: "Cut selection") }
        #expect(crossing.reviewing != nil && proposal(crossing) != nil && crossing.current)
        #expect(await crossing.acceptTakes() == false)
        #expect(publishedOverlap == 0 && !takes.readyToAccept && !takes.rows.isEmpty)
        #expect(crossing.review?.voiceHunks.first?.window == nil && crossing.review?.voiceHunks.first?.refusal == "This change can't be placed in this take. Your edits are saved.")
        #expect(published == 0)
    }

    /// A phrase in your voice with Voice Lab off shows no Beta tag, and R2 offers Turn On Voice Lab…, which opens the
    /// one-time sheet; its Turn on shows the tag on R2's headline (design.md R2 "Voice changes, Voice Lab off", §6.3.4).
    @Test func voiceLabPartsFollowTheSetting() async throws {
        let stub = ScopeStub()
        let (app, _) = app("ollama", stub: stub)
        let (editor, _) = try editor(app)
        defer { editor.close() }
        editor.selectedWordIDs = ["w12", "w13", "w14"]
        let session = try await rewrite(editor)
        #expect(session.review?.voiceHunks.isEmpty == false && !app.voiceLabRewriteEnabled)
        #expect(!session.showsVoiceLab && session.task.headline.tag == nil && session.task.footer.link?.title == "Turn On Voice Lab")
        editor.openVoiceJob()
        editor.enableVoiceLab()
        for _ in 0..<500 where session.task.headline.tag == nil { await Task.yield() }
        #expect(app.voiceLabRewriteEnabled && session.showsVoiceLab && session.isOpen)
        #expect(session.task.headline.tag == "Beta" && session.task.footer.link?.title != "Turn On Voice Lab")

        editor.selectedWordIDs = []
        let clip = try await rewrite(editor)
        #expect(clip.review?.voiceHunks.isEmpty == true && !clip.showsVoiceLab && clip.task.headline.tag == nil)
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
        await stub.untilWaiting()
        #expect(session.task.cards.first == .asked(preset: "Make it clearer", text: "keep my words where they work, change as little as possible."))
        let request = try #require(await stub.requests.first)
        #expect(request.instruction.hasSuffix("Instruction: Make it clearer. Keep my words where they work; change as little as possible."))
        await stub.release()
        await session.actionTask?.value
        // A preset is always offered, so it is not recorded; a typed instruction is.
        #expect(app.rewriteSuggestions(for: editor.project.id).count == 4)
        editor.rewriteInstruction = "Shorter intro"
        let again = Task { _ = try? await rewrite(editor) }
        await stub.untilWaiting()
        await stub.release()
        await again.value
        #expect(app.rewriteSuggestions(for: editor.project.id).map(\.menuTitle).last == "Recent: “Shorter intro”")
        #expect(app.rewriteSuggestions(for: UUID().uuidString).count == 4, "recents belong to their project")
    }
}

// MARK: Next steps (design.md R2 "Next steps", voice-lab.md §8.2.1)

extension RewriteScopeTests {
    /// Words 20–31 rewritten in two places: phrase 1 far too long for its slot, phrase 2 a short replacement.
    private static let twoPhrases = (Array(repeating: "collaboratively", count: 8) + (22...29).map { "word\($0)" } + ["Other", "fresh", "words"])
        .joined(separator: " ")
    private func nextStepsFixture(_ connectorID: ConnectorID = .ollama) async throws -> (RewriteSession, ScopeStub, EditorModel) {
        let stub = ScopeStub(id: connectorID)
        let (app, _) = app(connectorID.rawValue, stub: stub)
        let (editor, _) = try editor(app)
        editor.selectedWordIDs = Set((20...31).map { "w\($0)" })
        let session = try await rewrite(editor)
        enableVoiceLab(app)
        try session.receivePassage(Self.twoPhrases)
        session.finishRun(seconds: 0.1)
        session.reasking.suggestions = [RewriteNextAction(label: "Say it in 6 words", instruction: "Say phrase 1 in six words.", ordinals: [1])]
        session.showProposal()
        return (session, stub, editor)
    }
    private func steps(_ session: RewriteSession, _ id: String) -> NextSteps? { session.task.nextSteps.first { $0.id == id } }
    private func reply(_ text: String, actions: [[String: Any]] = []) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: ["rewrite": text, "nextActions": actions])
        return try #require(String(data: data, encoding: .utf8))
    }
    private func finish(_ session: RewriteSession, _ editor: EditorModel) async {
        await editor.rewriteOpenTask?.value
        await session.reasking.work?.value
    }

    /// A ✦ chip re-asks in the same session with its instruction as scoped feedback: only phrase 1 changes, phrase 2's
    /// reply is ignored and its review (left out) stays, and the new reply's suggestions replace the old ones.
    @Test func anAIChipReasksOnlyItsPhrasesAndFreezesTheRest() async throws {
        let (session, stub, editor) = try await nextStepsFixture()
        defer { editor.close() }
        #expect(session.changes.count == 2 && session.blockedVoiceOrdinals.contains(1))
        session.review(2, .undo)
        let frozen = session.changes[1], frozenParts = session.ownProposal?[2]?.parts
        let fit = try #require(steps(session, "fit"))
        let chip = try #require(fit.chips.first { $0.suggested })
        #expect(chip.action.title == "Say it in 6 words" && fit.ask?.placeholder == "Tell the AI what to do instead…")
        let request = RewriteReask(label: "Say it in 6 words", instruction: "Say phrase 1 in six words.", ordinals: [1], reason: .fit)
        let expected = try session.reaskFeedback(request, shared: try SharedResources.locate())
        #expect(expected.contains("Phrase 1: it takes about") && !expected.contains("Phrase 2"))
        let sentBefore = await stub.rewriteRequests.count
        await stub.configureRewrites([try reply((["better", "words"] + (22...29).map { "word\($0)" } + ["Totally", "new", "ending"]).joined(separator: " "),
            actions: [["label": "Drop 'better'", "instruction": "Drop the word better.", "ordinals": [1]], ["label": ""]])])
        chip.action.perform()
        await finish(session, editor)
        let sent = await stub.rewriteRequests
        #expect(sent.count == sentBefore + 1)
        #expect(sent.last?.instruction.hasSuffix(expected) == true)
        #expect(session.changes[0].hunk.newTokens == ["better", "words"])
        #expect(session.changes[1] == frozen && session.ownProposal?[2]?.parts == frozenParts)
        #expect(session.ownProposal?[2]?.state == .excluded && session.ownProposal?[1]?.state == .pending)
        #expect(session.reasking.suggestions.map(\.label) == ["Drop 'better'"])
        #expect(session.reasking.notice == "\(session.aiName) reworded phrase 1.")
        #expect(session.isOpen && session.task.state != .running && !editor.llmRuns.isBusy)
    }

    /// While a re-ask runs the panel says "Asking {AI}: “{label}”" with Stop, and the list waits; Stop sends nothing more,
    /// changes nothing and offers Ask again.
    @Test func stopEndsAReaskWithNothingChanged() async throws {
        let (session, stub, editor) = try await nextStepsFixture()
        defer { editor.close() }
        let before = session.changes
        await stub.configureRewrites([try reply("short words")], hold: true)
        try #require(steps(session, "fit")?.chips.first { $0.suggested }).action.perform()
        await editor.rewriteOpenTask?.value
        await stub.untilWaiting()
        #expect(session.task.headline.text == "Asking \(session.aiName): “Say it in 6 words”")
        #expect(session.task.wordingLocked && session.task.footer.primary == nil)
        try #require(session.task.headline.stop).perform()
        await stub.release()
        await session.reasking.work?.value
        #expect(session.changes == before && !session.isReasking && !editor.llmRuns.isBusy)
        #expect(session.reasking.notice == "Stopped. Nothing changed.")
        #expect(session.task.nextSteps.first?.chips.first?.action.id == "askAgain")
    }

    /// A chip that would discard paid takes asks first, inline, and sends nothing until Discard Changes.
    @Test func aReaskOverPaidTakesConfirmsFirst() async throws {
        let (session, stub, editor) = try await nextStepsFixture()
        defer { editor.close() }
        _ = try giveTake(session, editor: editor)
        #expect(session.hasPaidTakes)
        let sentBefore = await stub.rewriteRequests.count
        await stub.configureRewrites([try reply(Self.twoPhrases)])
        session.reask(RewriteReask(label: "Say it in 6 words", instruction: "Say phrase 1 in six words.", ordinals: [1], reason: .fit))
        #expect(session.task.confirm?.question == "Discard these 2 changes?")
        #expect(await stub.rewriteRequests.count == sentBefore && !session.isReasking)
        try #require(session.task.confirm).cancel.perform()
        #expect(session.hasPaidTakes && session.task.confirm == nil)
        session.reask(RewriteReask(label: "Say it in 6 words", instruction: "Say phrase 1 in six words.", ordinals: [1], reason: .fit))
        try #require(session.task.confirm).confirm.perform()
        await finish(session, editor)
        #expect(await stub.rewriteRequests.count == sentBefore + 1)
        #expect(!session.hasPaidTakes)
    }

    /// "Tell the AI what to do instead…" re-asks the stuck phrases with the typed words, as a chip would.
    @Test func freeTextReasksTheStuckPhrases() async throws {
        let (session, stub, editor) = try await nextStepsFixture()
        defer { editor.close() }
        let blocked = session.blockedVoiceOrdinals
        await stub.configureRewrites([try reply(Self.twoPhrases)])
        try #require(steps(session, "fit")?.ask).submit("Use plain words and keep the name")
        await finish(session, editor)
        let instruction = try #require(await stub.rewriteRequests.last?.instruction)
        #expect(instruction.contains("REQUESTED FIX") && instruction.contains("Use plain words and keep the name"))
        for ordinal in blocked { #expect(instruction.contains("Phrase \(ordinal): ")) }
    }

    /// Every stuck state shows chips: a phrase that does not fit, a refused surrounding sentence, a failed Rewrite and
    /// a stale reply; each one can act.
    @Test func everyStuckStateShowsNextSteps() async throws {
        let (session, _, editor) = try await nextStepsFixture()
        defer { editor.close() }
        #expect(session.task.nextSteps.compactMap(\.ask).count == 1)
        session.speechContextProblem = RewriteSpeechContextReview.copy(RewriteSpeechContextReview.Failure.unsupported)
        session.speechContextRefusedOrdinals = [1]
        session.showProposal()
        // MVP13 (cause d): the refusal names the change and acts; it no longer says to re-record.
        let context = try #require(steps(session, "context"))
        #expect(context.line?.hasPrefix("Change 1 at ") == true && context.line?.contains("Re-record") == false, "\(context.line ?? "")")
        #expect(context.chips.map(\.action.id).prefix(2) == ["leaveOut.1", "changedWordsOnly.1"], "\(context.chips.map(\.action.id))")
        #expect(context.chips.map(\.action.title).prefix(2) == ["Leave out this change", "Voice just the changed words"])
        #expect(context.chips.contains { $0.suggested && $0.action.title == "Rewrite without changing the sentence around it" })
        #expect(session.task.nextSteps.compactMap(\.ask).count == 1)
        context.chips[0].action.perform()
        #expect(session.ownProposal?[1]?.state == .excluded)
        session.fail(.message("The model returned no usable reply. Your edits are saved."))
        #expect(steps(session, "failure")?.ask != nil)
        session.showChanged()
        #expect(steps(session, "stale")?.ask != nil)
    }

    /// A refused takes plan is never a dead end (voice-lab.md §8.2.1): a collision names both phrases, the footer names the
    /// blocker instead of a price, and ✦ Merge with phrase 1 re-asks both phrases and lands one merged phrase.
    @Test func aCollisionNamesThePhrasesBlocksThePriceAndMergesInPlace() async throws {
        let (session, stub, editor) = try await nextStepsFixture()
        defer { editor.close() }
        for ordinal in session.blockedVoiceOrdinals { session.pricedAnyway.insert(ordinal) }
        session.showProposal()
        session.takePlanOrdinals = [1, 2]
        session.takePlanFailure = ClipTakePlan.Failure.placement(.collidesWithChange(0), index: 1)
        session.showProposal()
        let plan = try #require(steps(session, "plan"))
        #expect(plan.line == "Phrase 2 is too close to phrase 1 to voice separately.")
        // The reply's own suggestion for phrase 1 follows the built-in steps.
        #expect(plan.chips.map(\.action.id) == ["keepOriginal", "mergePhrases", "suggestion.0"] && plan.chips[1].suggested)
        #expect(plan.chips.map(\.action.title) == ["Keep original words for phrase 2", "Merge with phrase 1", "Say it in 6 words"])
        #expect(session.task.nextSteps.compactMap(\.ask).count == 1)
        #expect(session.task.footer.note == "Phrase 2 needs a fix above." && session.task.footer.primary?.title == "Keep Original Words for Phrase 2")
        let expected = try RewriteNextActionFeedback.merge(first: 1, second: 2, shared: try SharedResources.locate())
        await stub.configureRewrites([try reply("One merged and much shorter sentence")])
        plan.chips[1].action.perform()
        await finish(session, editor)
        let instruction = try #require(await stub.rewriteRequests.last?.instruction)
        #expect(instruction.contains(expected) && instruction.contains("Phrase 1: ") && instruction.contains("Phrase 2: "))
        #expect(session.changes.count == 1 && session.ownProposal?.changes.map(\.ordinal) == [1])
        #expect(session.changes[0].hunk.newTokens.joined(separator: " ") == "One merged and much shorter sentence")
        #expect(session.takePlanFailure == nil && steps(session, "plan") == nil)
        #expect(session.reasking.notice.contains("merged phrases 1, 2 into one phrase"))
        #expect(session.task.footer.note != "Phrase 2 needs a fix above.")
    }

    /// Keep original words for the refused phrase resolves the collision in place: the footer prices the rest again.
    @Test func keepingTheRefusedPhraseOriginalClearsTheBlocker() async throws {
        let (session, _, editor) = try await nextStepsFixture()
        defer { editor.close() }
        for ordinal in session.blockedVoiceOrdinals { session.pricedAnyway.insert(ordinal) }
        session.showProposal()
        session.takePlanOrdinals = [1, 2]
        session.takePlanFailure = ClipTakePlan.Failure.placement(.collidesWithChange(0), index: 1)
        session.showProposal()
        try #require(steps(session, "plan")?.chips.first).action.perform()
        #expect(session.ownProposal?[2]?.state == .excluded && session.takePlanFailure == nil)
        #expect(steps(session, "plan") == nil && session.task.footer.note != "Phrase 2 needs a fix above.")
    }

    /// Every other takes failure the panel can show has at least one chip that acts, and the footer names it.
    @Test(arguments: ["stale", "noSelection", "spendingCap", "unknownSpend", "geometry"])
    func everyTakesFailureHasAnActingChip(_ name: String) async throws {
        let (session, _, editor) = try await nextStepsFixture()
        defer { editor.close() }
        for ordinal in session.blockedVoiceOrdinals { session.pricedAnyway.insert(ordinal) }
        session.showProposal()
        session.takePlanOrdinals = [1, 2]
        let failure: ClipTakePlan.Failure = switch name {
        case "stale": .stale
        case "noSelection": .noSelection
        case "spendingCap": .spendingCap
        case "unknownSpend": .unknownSpend
        default: .placement(.geometry(.roomToneUnavailable), index: 0)
        }
        session.takePlanFailure = failure
        session.showProposal()
        let plan = try #require(steps(session, "plan"))
        #expect(!plan.chips.isEmpty && plan.line == ClipTakePlan.copy(failure))
        // The footer names the blocker and carries its step forward (MVP32 Clip 7: "Fix the problem above" with no button).
        let forward: [String: String] = ["stale": "freshPrice", "noSelection": "reviewTakes", "spendingCap": "freshPrice",
                                         "unknownSpend": "freshPrice", "geometry": "keepOriginal"]
        #expect(session.task.footer.primary?.id == forward[name] && session.task.footer.note == session.takePlanBlocker, "\(session.task.footer)")
        if name == "geometry" { #expect(plan.chips.first?.action.title == "Keep original words for phrase 1" && session.task.nextSteps.compactMap(\.ask).count == 1) }
        if name == "stale" { #expect(plan.chips.contains { $0.action.id == "freshPrice" }) }
    }
}
#endif
