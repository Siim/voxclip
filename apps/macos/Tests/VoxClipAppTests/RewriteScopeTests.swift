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
    private var waiting: CheckedContinuation<Void, Never>?
    private var arrivals: [CheckedContinuation<Void, Never>] = []
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
        if hold { await withCheckedContinuation { waiting = $0; arrivals.forEach { $0.resume() }; arrivals = [] } }
        let text = request.tag == "patch-rewrite" ? RewriteFixtureReply.patch(reply(RewriteFixtureReply.lines(of: request))) : "{\"rewrite\":\"A clearer passage\"}"
        return RawCompletion(text: text, model: model, stop: .complete)
    }
    /// Returns once a send waits for `release()`; a release before that would leave the send waiting for good.
    func untilWaiting() async { if waiting == nil { await withCheckedContinuation { arrivals.append($0) } } }
    func release() { waiting?.resume(); waiting = nil }
}

/// Takes never ask for an ElevenLabs key here: nothing is generated or sent.
private struct ScopeTakeKeys: KeyProvider {
    func key(for provider: String) async throws -> String? { Issue.record("Rewrite scope tests must not ask for credentials"); return nil }
}

/// Holds a take's publication until the test lets it go.
@MainActor private final class PublicationHold {
    private var reached = false
    private var arrival: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?
    func pause() async { await withCheckedContinuation { release = $0; reached = true; arrival?.resume(); arrival = nil } }
    func wait() async { if !reached { await withCheckedContinuation { arrival = $0 } } }
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
    var shown: [LLMSendSheet] = []
    func take() -> [LLMSendSheet.Reason] { defer { shown = [] }; return shown.map(\.reason) }
}

/// `RewriteSession` takes a scope (impl-plan V13, plan M7): a clip and Full take through C1's plan, `PatchRewriteService`
/// and C2's diff, a selection through `VoiceRewriteService`; the free changes as one undo step; R3 and the way back; the
/// send's confirmation on an API key only; Edit › Rewrite {scope}; the Ask suggestions; and no Voice Lab gate. Stub
/// connectors and in-memory settings only; the app model never starts.
@Suite("Rewrite takes a scope", .serialized, .enabled(if: ProcessInfo.processInfo.environment["VOXCLIP_DATA_DIR"] != nil, "Use an isolated VOXCLIP_DATA_DIR for app-model tests; only stub connectors are called."))
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
                        contiguous: Bool = false) throws -> (EditorModel, UndoManager) {
        let shared = try SharedResources.locate()
        var project = try DemoEditing.loadFixture(shared.root.appendingPathComponent("fixtures/projects/interview-take.voxclip"))
        project.id = UUID().uuidString.lowercased()
        project.edits = ProjectEdits()
        project.transcript?.words = (0..<count).map { index in
            TimedWord(id: "w\(index)", text: index % 20 == 19 ? "word\(index)." : "word\(index)", start: Double(index) + 1, end: Double(index) + (contiguous ? 2 : 1.4))
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
    /// Gives `session` one reviewed take, ready to use: no provider is called.
    private func giveTake(_ session: RewriteSession, editor: EditorModel) throws -> RewriteGenerationSession {
        let root = editor.app.locations.root
        session.configureGeneration(client: ElevenLabsVoiceLab(keys: ScopeTakeKeys(), region: .default),
                                    store: VoiceConsentStore(locations: DataLocations(environment: ["VOXCLIP_DATA_DIR": root.path])), speaker: .unavailable)
        let generation = try #require(session.generation)
        let plan = VoiceLabFitPlan(edits: [], incoming: .init(padFrames: 0, borrowedSamples: 0), outgoing: .init(padFrames: 0, borrowedSamples: 0),
            trimStartFrame: 0, trimEndFrame: 24_000, windowStart: 1, windowEnd: 2, windowStartSample: 24_000, windowEndSample: 48_000,
            outputFrames: 24_000, words: [VoiceLabWord(text: "Hello", start: 0.1, end: 0.9, synthetic: true)])
        let audio = VoiceLabTakeAudio(sampleRate: 24_000, trimmed: [0.1], mixed: [0.1], patchRange: 0..<1, seams: [], gainDb: 0, roomTone: nil, fit: .exact(plan))
        let qa = VoiceLabTakeQAResult(values: VoiceLabQA(transcriptMatch: 1, lufsJumpLu: 0, peakDbfs: -20, speakerScore: 0.8), failures: [])
        let row = VoiceLabTakeRow(id: UUID(), index: 0, seed: 0, audio: audio, qa: qa, score: 1, failure: nil)
        let window = VoiceLabWindow(firstWordId: "w20", lastWordId: "w21", leftBridgeWordIds: [], rightBridgeWordIds: [], start: 21, end: 22.4,
            startSample: 21_000, endSample: 22_400, leftSeam: .init(kind: .gap, time: 21, sample: 21_000, fadeSamples: 20),
            rightSeam: .init(kind: .gap, time: 22.4, sample: 22_400, fadeSamples: 20))
        let input = VoiceLabTakeInput(text: "new words", modelID: "fixture-model", recordID: "fixture-record", language: "en", seed: 7,
            contentKey: editor.project.media.source.contentKey, source: [], sourceSampleRate: 1_000, items: editor.words,
            window: window, incomingSilence: nil, outgoingSilence: nil, providerConsent: true)
        generation.review(VoiceLabTakeRunResult(rows: [row], end: .completed), input: input)
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
    /// the placement refuses its window, as a seam's fade would cross the cut; that only stops its phrase in your voice,
    /// and the request takes the selection's span as its length, as C1's lines do. With no waveform the same holds, and the
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
        #expect(session.review?.voiceHunks.first?.refusal == "This change can't be placed in this take. Your edits are saved.")

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
        try #require(session.includedVoice.count == 1)
        let generation = try giveTake(session, editor: editor)
        #expect(generation.readyToAccept)
        let hold = PublicationHold()
        generation.publishForTests = { _, _, _ in await hold.pause(); throw CancellationError() }
        let accepting = Task { await session.acceptTakes() }
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
        #expect(sheets.take() == [.privacy, .cost] && session.task.contextAction?.title == "Ask again…")
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
    /// review; a cut far away leaves the takes ready.
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
        step(undo) { editor.apply(.cutSelection(ids: ["w61"]), name: "Cut selection") }
        #expect(session.reviewing != nil && proposal(session) != nil && session.current)
        #expect(await session.acceptTakes() == false)
        #expect(published == 0 && !generation.readyToAccept && !generation.rows.isEmpty)
        #expect(session.review?.voiceHunks.first?.window == nil && session.review?.voiceHunks.first?.refusal == "This change can't be placed in this take. Your edits are saved.")
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
        #expect(!session.showsVoiceLab && session.task.headline.tag == nil && session.task.footer.link?.title == "Turn On Voice Lab…")
        editor.showVoiceLabOptIn = true
        editor.enableVoiceLab()
        for _ in 0..<500 where session.task.headline.tag == nil { await Task.yield() }
        #expect(app.voiceLabRewriteEnabled && !editor.showVoiceLabOptIn && session.showsVoiceLab && session.isOpen)
        #expect(session.task.headline.tag == "Beta" && session.task.footer.link?.title != "Turn On Voice Lab…")

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
#endif
