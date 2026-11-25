#if DEBUG
import Foundation
import Testing
@_spi(Testing) @testable import VoxClipCore
@_spi(Testing) @testable import VoxClipMedia
@testable import VoxClip

/// A fal.ai key and nothing else, by presence only; saving one is a test bug.
private struct FalKeyOnly: ProviderKeyStore {
    func hasKey(for provider: String) async -> Bool { provider == "fal" }
    func save(_ value: String, for provider: String) async throws { Issue.record("whole-clip tests never save keys") }
}

/// The whole-clip revoice's run (ADR-R46) on stubs: Script, Voice, Fit and Lip sync in order, the fit on the clip as
/// edited, the shorter-only reword round and its check before paying, Cancel and failure keeping the clip, Try Again and the
/// sync-3 upgrade never paying a step twice, Review's Use and Undo.
@Suite(.serialized) @MainActor struct WholeClipRevoiceSessionTests {
    @Test func storyClipVoiceActionsAreDisabledBeforeAnyVoicePreparation() throws {
        let shared = try SharedResources.locate()
        var project = try JSONProjectStore.decode(Data(contentsOf: shared.root.appendingPathComponent("fixtures/projects/interview-take.voxclip")))
        let words = try #require(project.transcript?.words)
        let parts = [ClipPart(id: "late", startWordId: words[8].id, endWordId: words[10].id),
                     ClipPart(id: "early", startWordId: words[3].id, endWordId: words[5].id),
                     ClipPart(id: "earliest", startWordId: words[0].id, endWordId: words[1].id)]
        try project.applyEditing(.addClip(ClipRange(id: "story", startWordId: words[0].id, endWordId: words[10].id, parts: parts)))
        let app = AppModel(settingsStore: RegressionSettingsStore())
        let editor = EditorModel(document: VoxClipDocument(project: project, demo: true), app: app, preview: DemoPreviewEngine())
        defer { editor.close() }
        let rewrite = RewriteSession(editor: editor, scope: .clip("story"), envelope: nil, connector: nil)
        let reason = "Lip sync can't run across the 2 seams of a story clip yet. Make a clip of the part first."
        #expect(rewrite.wholeClipUnavailable == reason)
        #expect(rewrite.wholeClipPrimaryUnavailable == reason)
        #expect(rewrite.changedPhrasesUnavailable == "Voice changes work on one part at a time. Make a clip of the part first.")
        #expect(rewrite.wholeClipPrimary() == nil)
    }

    @MainActor final class Stubs {
        var voices: [String] = []
        var lipsyncs: [WholeClipRevoice.Lipsync] = []
        var rewords: [Int] = []
        var used = 0, undone = 0, discarded = 0
        var voiceSeconds: [Double] = [30.6]
        var video = 31.0
        var failLipsync = false
        var holdLipsync = false
        var held: CheckedContinuation<Void, Never>?
        var reword: WholeClipScript? = nil
        /// The speaking-rate estimate per script text (check before paying); nil: no estimate.
        var estimates: [String: Double] = [:]
        /// Thrown by the Voice step before anything is said.
        var voiceError: (any Error)?
        var reports: [String] = []
        /// The Fit step's picture check: what it returns, what it throws, and each voice it was asked for.
        var picture = WholeClipRevoiceSession.Picture(speed: 1, outputSeconds: 31, laidOut: false)
        var pictureError: (any Error)?
        var pictures: [Double] = []
        /// Thrown by the lip sync itself (a job or its preparation).
        var lipsyncError: (any Error)?
        var lipsyncFactors: [Double] = []
        var quotedModels: [WholeClipRevoice.Lipsync] = []
        /// The lip sync re-imported this billed attempt's kept result (nothing new paid).
        var recoveredRequest: String?
        /// The order the paid and free steps ran in.
        var order: [String] = []
        /// The fal.ai key is there (the card's price, or Settings).
        var hasKey = true
        /// Thrown by the free checks before a voice is paid (the source within the lip sync's limits).
        var preflightError: (any Error)?
        var preflights = 0
        /// The scope guard for what the voice is made from (`RewriteSession.wholeClipInputsStillCurrent`): the Fit step's
        /// picture stops as the live one does once it is false.
        var isCurrent: (@MainActor () -> Bool)?
        /// The lip syncs applied to the parts, as the live plan holds them, when a test follows them.
        var tracksApplied = false
        var applied: [Int: RewriteLipsyncSession.Applied] = [:]
        /// Restores refused (the live plan's offer can't be made again).
        var refuseRestore = false
        var restores = 0
        /// What each lip sync was allowed to pay (`WholeClipRevoiceSession.lipsyncMayPay`).
        var mayPay: [Bool] = []
        /// Thrown by the next Use, then cleared.
        var useError: (any Error)?
        /// The lip-sync assets each Use put in.
        var usedAssets: [[String]] = []
        /// The laid-out voice's longest part past its window (`Voice.overrun`), per voice made.
        var overruns: [Double?] = []
        /// Thrown instead of the cancel when the held lip sync is cancelled: fal.ai's billed, kept result (C's set-aside).
        var cancelledError: (any Error)?
        /// Each voice put in without lip sync (its script), and what the next such Use throws, then cleared.
        var voiceOnlyUses: [String] = []
        var voiceOnlyError: (any Error)?
        /// The voice's price in the quote for a script (the tables price more words higher); nil: 0.06 for every script.
        var quoteVoiceUSD: ((WholeClipScript) -> Decimal)?
        /// What each voice made costs (0 for one a journal adopted for free).
        var voiceUSD = Decimal(string: "0.06")!
        /// The Fit step's picture stops as plain stale while no more than this many voices were made: the live plan holding
        /// them was let go with nothing paid (`RewriteSession.checkWholeClipPlan`), so only a new voice gets past it.
        var staleUntilVoice = 0
        /// An AI is there to ask for a shorter wording.
        var canReword = true
        /// What stops the Voice step until something outside the card changes (`Backend.voiceReadiness`).
        var readiness: WholeClipRevoiceSession.Stop?
        /// The voice plan held now has paid parts of the script (`Backend.partlyVoiced`).
        var partlyVoiced = false
        weak var session: WholeClipRevoiceSession?
    }

    /// An applied lip sync of `model` over one window, as the live plan keeps it (`RewriteLipsyncSession.Applied`).
    static func applied(_ model: WholeClipRevoice.Lipsync) throws -> RewriteLipsyncSession.Applied {
        let piece = VoiceLabOutputPiece(kind: .source, sourceStartSample: 0, sourceEndSample: 480_000,
            outputStartSample: 0, outputEndSample: 480_000, segmentId: nil, assetId: nil, audio: nil)
        let output = VoiceLabOutputPlan(sampleRate: 48_000, totalSourceSamples: 480_000, pieces: [piece], captions: [], scope: .full)
        let source = try LipsyncWindow.make(seamIn: 96_000, seamOut: 144_000, totalSamples: 480_000, sampleRate: 48_000, phraseID: 0)
        let window = try LipsyncRenderWindow(source: source, plan: output)
        let usd: Decimal = Decimal(string: "1.55")!
        let estimate = CostEstimate(provider: "fal", operation: "lipsync", units: 3, unit: "second", usd: usd, basis: "fixture")
        let asset = VoiceLabVideoAsset(id: "asset-" + model.name, file: "fixture.mp4", sha256: String(repeating: "a", count: 64),
            durationSeconds: 3, frameRate: 30, width: 320, height: 180)
        let provenance = LipsyncResultProvenance(provider: "fal", model: model.rawValue, requestID: "request-" + model.name,
            quoteID: UUID(), videoInputSHA256: asset.sha256, audioInputSHA256: asset.sha256, outputSHA256: asset.sha256,
            syncMode: .cutOff, seed: nil, submittedAt: Date(), importedAt: Date(), estimate: estimate)
        return .init(result: ImportedLipsyncResult(asset: asset, url: URL(fileURLWithPath: "/synthetic/result.mp4"), provenance: provenance),
                     window: window, dependencies: [0])
    }

    private static let words: [TimedWord] = ["So", "we", "drove", "north.", "It", "was", "cold."].enumerated().map {
        TimedWord(id: "w\($0.offset)", text: $0.element, start: Double($0.offset), end: Double($0.offset) + 0.8)
    }

    private func session(_ stubs: Stubs) -> WholeClipRevoiceSession {
        let session = WholeClipRevoiceSession()
        session.backend = Self.backend(stubs)
        stubs.session = session
        return session
    }

    /// A Rewrite on the fixture's clip, for the card's actions and the live currency.
    private struct Live {
        let root: URL
        let editor: EditorModel
        let rewrite: RewriteSession
    }
    private func live(ready: Bool = false, _ edit: (inout Project) -> Void = { _ in }) throws -> Live {
        let shared = try SharedResources.locate()
        var project = try JSONProjectStore.decode(Data(contentsOf: shared.root.appendingPathComponent("fixtures/voice-lab/passage-render-v3.voxclip")))
        edit(&project)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-whole-clip-" + UUID().uuidString, isDirectory: true)
        let app = AppModel(settingsStore: RegressionSettingsStore(), locations: DataLocations(environment: ["VOXCLIP_DATA_DIR": root.path]))
        let editor = EditorModel(document: VoxClipDocument(project: project, demo: true), app: app, preview: DemoPreviewEngine())
        let envelope = ready ? AudioEnvelope(sampleRate: 1_000, levels: Array(repeating: 0.1, count: 700)) : nil
        if ready {
            app.settings.values["voiceLab.enabled"] = .bool(true)
            app.settings.values["voiceLab.betaNoticeAccepted"] = .bool(true)
            editor.mediaResolved = true
            editor.refresh()
        }
        return Live(root: root, editor: editor, rewrite: RewriteSession(editor: editor, scope: .clip("clip-main"), envelope: envelope, connector: nil))
    }
    private func close(_ live: Live) {
        live.editor.close()
        try? FileManager.default.removeItem(at: live.root)
    }

    /// Stub steps that record what they are asked and spend the tables' prices (Claude mode's tests use them too).
    static let script = WholeClipScript.assemble(words: Self.words, cutWordIds: [], voiceHunks: [])!

    static func backend(_ stubs: Stubs) -> WholeClipRevoiceSession.Backend {
        let script = Self.script
        return .init(script: { script }, quote: { script, model in
            stubs.quotedModels.append(model)
            return .init(clipNumber: 7, clipSeconds: 31, spokenWords: script.words, reason: .manyWords(revoiced: 4, spoken: 7), patchUSD: Decimal(string: "0.1"),
                  phrases: 2, voiceUSD: stubs.quoteVoiceUSD?(script) ?? Decimal(string: "0.06"), lipsyncUSD: Decimal(string: "1.55"),
                  voiceName: "siim · DJI 0011", voiceNote: "matched to this video")
        }, voice: { script, progress in
            progress("part 1 of 1")
            if let error = stubs.voiceError { throw error }
            stubs.voices.append(script.text); stubs.order.append("voice")
            let seconds = stubs.voiceSeconds.count > 1 ? stubs.voiceSeconds.removeFirst() : stubs.voiceSeconds[0]
            let overrun = stubs.overruns.isEmpty ? nil : stubs.overruns.removeFirst()
            return .init(key: .init(script: script.text, recordId: "r1", model: "eleven_v4"), seconds: seconds, parts: 3, usd: stubs.voiceUSD,
                         overrun: overrun)
        }, videoSeconds: { stubs.video }, reword: { _, target, _, _ in
            stubs.rewords.append(target); stubs.order.append("reword")
            return stubs.reword
        }, canReword: { stubs.canReword }, estimate: { script in stubs.estimates[script.text] },
           partlyVoiced: { _ in stubs.partlyVoiced }, voiceReadiness: { stubs.readiness }, picture: { voice in
            stubs.pictures.append(voice.seconds); stubs.order.append("picture")
            if stubs.voices.count <= stubs.staleUntilVoice { throw ClipTakePlan.Failure.stale }
            if let current = stubs.isCurrent, !current() { throw WholeClipRevoiceSession.Stop.voiceInputsChanged(clip: 7, usd: voice.usd) }
            if let error = stubs.pictureError { throw error }
            return stubs.picture
        }, lipsync: { _, factor, model, progress in
            stubs.lipsyncs.append(model); stubs.lipsyncFactors.append(factor); stubs.order.append("lipsync")
            stubs.mayPay.append(stubs.session?.lipsyncMayPay ?? true)
            if let error = stubs.lipsyncError { throw error }
            progress(0.5)
            if stubs.holdLipsync { await withCheckedContinuation { stubs.held = $0 } }
            if Task.isCancelled, let kept = stubs.cancelledError { throw kept }
            try Task.checkCancellation()
            if stubs.failLipsync { throw LipsyncError.http(503) }
            if stubs.tracksApplied { stubs.applied = [0: try Self.applied(model)] }
            return .init(model: model, usd: Decimal(string: "1.55")!, factor: factor,
                         requestID: stubs.recoveredRequest, recovered: stubs.recoveredRequest != nil)
        }, lipsyncPrice: { _ in Decimal(string: "1.55") },
           match: { _ in .init(take: 0.81, anchorBaseline: 0.54, realSpeech: 0.86) }, play: { _ in },
           use: { voice, synced, match in
            if let error = stubs.useError { stubs.useError = nil; throw error }
            stubs.used += 1
            stubs.usedAssets.append(stubs.applied.values.map(\.result.asset.id).sorted())
            return WholeClipRevoiceRecord(id: "wholeclip-1", clipId: "clip-7", segmentIds: ["s"], script: voice.key.script, consentRecordId: "r1",
                                          videoRetime: synced.factor, lipsyncModel: synced.model.rawValue, usd: 1.61, match: match, createdAt: Date())
        }, undo: { _ in stubs.undone += 1 }, discard: { stubs.discarded += 1 }, report: { stubs.reports.append($0) },
           hasKey: { stubs.hasKey }, preflight: {
            stubs.preflights += 1
            if let error = stubs.preflightError { throw error }
        }, appliedLipsync: { stubs.tracksApplied ? stubs.applied : [:] }, restoreLipsync: { entries in
            stubs.restores += 1
            guard !entries.isEmpty else { return true }
            if stubs.applied.isEmpty, !stubs.refuseRestore { stubs.applied = entries }
            return Set(stubs.applied.keys) == Set(entries.keys)
        }, useVoiceOnly: { voice in
            if let error = stubs.voiceOnlyError { stubs.voiceOnlyError = nil; throw error }
            stubs.voiceOnlyUses.append(voice.key.script)
        })
    }

    @Test func aSecondQuoteRequestWaitsForThePriceAlreadyInFlight() async throws {
        let session = session(Stubs())
        var backend = try #require(session.backend)
        let price = backend.quote
        var releaseQuote: CheckedContinuation<Void, Never>?
        var quoteCalls = 0
        backend.quote = { script, model in
            quoteCalls += 1
            if quoteCalls == 1 { await withCheckedContinuation { releaseQuote = $0 } }
            return try await price(script, model)
        }
        session.backend = backend
        defer { releaseQuote?.resume() }
        let first = Task { await session.refreshQuote() }
        await TestDeadline.until { releaseQuote != nil }
        var checkingPrice = false
        let second = Task {
            checkingPrice = true
            await session.refreshQuote()
            return session.quote?.wholeUSD
        }
        await TestDeadline.until { checkingPrice }
        let release = try #require(releaseQuote)
        releaseQuote = nil
        release.resume()
        #expect(await second.value == Decimal(string: "1.61"))
        await first.value
        #expect(quoteCalls == 1 && !session.quoting)
    }

    @Test func aRunGoesScriptVoiceFitLipSyncThenReviewAndUse() async {
        let stubs = Stubs()
        let session = session(stubs)
        await session.refreshQuote()
        #expect(stubs.quotedModels == [.sync3])
        #expect(session.phase == .choose && session.quote?.wholeUSD == Decimal(string: "1.61"))
        session.start()
        #expect(session.phase == .running)
        await session.waitForRun()
        #expect(session.phase == .review)
        #expect(session.steps[.script] == .done("Script · 7 words, your edits applied"))
        #expect(session.steps[.voice] == .done("Voice · 0:30.6 in siim · DJI 0011 · 3 parts, one take"))
        #expect(session.steps[.fit] == .done("Fit · 0:30.6 for 0:31 of video, video matched (−1.3%)"))
        #expect(stubs.lipsyncs == [.sync3], "sync-3 for whole-clip runs")
        #expect(session.spent == Decimal(string: "1.61"))
        #expect(WholeClipRevoiceCardMatch.line(session.match!) == "Sounds like you: 0.81 · siim's earlier takes 0.54 · your real speech 0.86")
        #expect(stubs.used == 0, "nothing goes into the clip before Use")
        await session.use()
        #expect(session.phase == .used && stubs.used == 1 && session.record?.lipsyncModel == WholeClipRevoice.Lipsync.sync3.rawValue)
        session.undoUse()
        #expect(stubs.undone == 1 && session.phase == .review)
    }

    @Test func aVoiceLongerThanTheEditedClipAsksForAShorterWordingThenFits() async {
        let stubs = Stubs()
        stubs.voiceSeconds = [36, 31.5]
        let shorter = WholeClipScript.assemble(words: Array(Self.words.prefix(4)), cutWordIds: [], voiceHunks: [])!
        stubs.reword = shorter
        let session = session(stubs)
        await session.refreshQuote()
        session.start()
        await session.waitForRun()
        #expect(stubs.rewords == [6], "a shorter wording of about 7 ÷ (36 ÷ 31) words")
        // The click approved one voice: the shorter wording's voice waits for its own priced click (wholeclip-reword-pays-unapproved).
        #expect(stubs.voices.count == 1, "no second voice without a click: \(stubs.voices)")
        guard case .stopped(let line) = session.phase else { Issue.record("not stopped: \(session.phase)"); return }
        #expect(line.hasPrefix("A shorter wording of 4 words fits the clip. Voicing it is a new voice"), "\(line)")
        #expect(session.shorterWording?.script == shorter && session.shorterWording?.usd == Decimal(string: "1.61"))
        #expect(session.steps[.script] == .done("Script · 4 words, reworded to fit"))
        session.voiceShorterWording()
        await session.waitForRun()
        #expect(stubs.voices.count == 2 && stubs.voices.last == shorter.text, "the new wording is voiced on its click")
        #expect(session.phase == .review && stubs.rewords.count == 1)
        #expect(session.steps[.script] == .done("Script · 4 words, reworded to fit"))
    }

    @Test func aVoiceThatCannotFitSaysSoAndKeepsTheClip() async {
        let stubs = Stubs()
        stubs.voiceSeconds = [40]
        stubs.reword = nil
        let session = session(stubs)
        session.start()
        await session.waitForRun()
        guard case .stopped(let line) = session.phase else { Issue.record("not stopped: \(session.phase)"); return }
        #expect(line.hasPrefix("The new voice runs 0:40 for 0:31 of video, longer than the clip can hold."))
        #expect(stubs.lipsyncs.isEmpty && stubs.used == 0, "no lip sync and nothing in the clip")
        #expect(session.isStopped && session.failure?.step == .fit)
    }

    @Test func theWholeClipPriceIncludesWordChecksButNoSpeakerRetryReserve() async throws {
        let stubs = Stubs()
        let session = session(stubs)
        let originalQuote = try #require(session.backend?.quote)
        session.backend?.quote = { script, model in
            var quote = try await originalQuote(script, model)
            quote.wordChecksUSD = Decimal(string: "0.02")
            return quote
        }
        await session.refreshQuote()
        #expect(session.quote?.wholeUSD == Decimal(string: "1.63"))
        session.start()
        await session.waitForRun()
        #expect(session.phase == .review)
        #expect(session.spent == Decimal(string: "1.61"))
    }

    @Test func partialVoiceSpendAndRetryPriceAreSeparateAndTheFailedCheckIsNamed() async {
        let stubs = Stubs()
        let session = session(stubs)
        stubs.voiceError = WholeClipRevoiceSession.Stop.partVoice(part: 2, reason: "The voice did not match.", checks: [.speaker])
        session.backend?.unfinishedVoicePrice = { Decimal(string: "0.02") }
        session.backend?.unsettledVoiceSpend = { Decimal(string: "0.06")! }
        await session.refreshQuote()
        session.start()
        await session.waitForRun()
        #expect(session.failure?.step == .voice && session.failure?.part == 2)
        #expect(stubs.reports.first?.contains("checks=speaker part=2") == true)
        #expect(session.spent == Decimal(string: "0.06"))
        #expect(session.retryUSD == Decimal(string: "1.57"))
        #expect(stubs.lipsyncs.isEmpty)
    }

    /// The user's live run in MVP44 (2026-11-08), as numbers: 49 spoken words, the clip 0:31.4 as edited, its parts' windows
    /// 48.6 s of source, and a 27 s voice. The fit reads the clip as edited, asks for no longer wording, and goes on to the
    /// lip sync; the run used to ask for ≈ 124 words three times and stop with `cannotFit`.
    @Test func theUsersClipIsLaidOutOnTheEditedClipWithNoLongerWording() async {
        let stubs = Stubs()
        stubs.voiceSeconds = [27]
        stubs.video = WholeClipUserCase.editedSeconds
        let session = session(stubs)
        session.start()
        await session.waitForRun()
        #expect(stubs.rewords.isEmpty, "never a longer wording: \(stubs.rewords)")
        #expect(stubs.voices.count == 1, "one voice")
        #expect(session.steps[.fit] == .done("Fit · 0:27 for 0:31.4 of video, laid out on the clip's pauses (−14.0%)"))
        #expect(session.phase == .review && stubs.lipsyncs == [.sync3], "it reaches the lip sync: \(session.phase)")
        // The old fit read the source windows and asked for a longer wording.
        #expect(WholeClipRevoice.fit(voiceSeconds: 27, videoSeconds: WholeClipUserCase.sourceSeconds, words: 49, round: 0) == .laidOut(factor: 27 / WholeClipUserCase.sourceSeconds))
    }

    /// Check before paying: a shorter wording whose estimate still runs past the clip makes no voice and stops inline with
    /// the Stopped card's chips, the patch first.
    @Test func aRewordThatCameBackNoShorterStopsWithoutMakingAVoice() async throws {
        let stubs = Stubs()
        stubs.voiceSeconds = [36]
        let base = WholeClipScript.assemble(words: Self.words, cutWordIds: [], voiceHunks: [])!
        let reworded = WholeClipScript.assemble(words: Array(Self.words.prefix(6)), cutWordIds: [], voiceHunks: [])!
        stubs.reword = reworded
        stubs.estimates = [base.text: 10, reworded.text: 9.8]
        let session = session(stubs)
        session.start()
        await session.waitForRun()
        #expect(stubs.rewords.count == 1 && stubs.voices.count == 1, "no voice for a wording that can't fit: \(stubs.voices)")
        guard case .stopped(let line) = session.phase else { Issue.record("not stopped: \(session.phase)"); return }
        #expect(line.hasPrefix("The shorter wording would still run about 0:35.3 for 0:31 of video, so no new voice was made."), "\(line)")
        #expect(line.contains("Spent so far:"))
        #expect(session.failure?.step == .fit && session.repeatsFit)
        #expect(stubs.lipsyncs.isEmpty && stubs.used == 0)
        // A wording estimated to fit is voiced.
        stubs.estimates[reworded.text] = 8.6
        stubs.voiceSeconds = [36, 31]
        let second = self.session(stubs)
        await second.refreshQuote()
        second.start()
        await second.waitForRun()
        #expect(second.shorterWording?.script == reworded && stubs.voices.count == 2, "the checked wording waits for its click")
        second.voiceShorterWording()
        await second.waitForRun()
        #expect(second.phase == .review && stubs.voices.count == 3 && stubs.voices.last == reworded.text, "\(second.phase)")
    }

    @Test func cancelKeepsTheClipAndTryAgainNeverPaysTheVoiceTwice() async {
        let stubs = Stubs()
        stubs.holdLipsync = true
        let session = session(stubs)
        session.start()
        for _ in 0..<10_000 where stubs.held == nil { await Task.yield() }
        #expect(session.progress == 0.5)
        session.cancel()
        stubs.held?.resume(); stubs.held = nil
        await session.waitForRun()
        guard case .stopped(let line) = session.phase else { Issue.record("not stopped"); return }
        #expect(line.hasPrefix("Cancelled. Your clip is unchanged."))
        #expect(stubs.used == 0)
        stubs.holdLipsync = false
        session.start()
        await session.waitForRun()
        #expect(session.phase == .review)
        #expect(stubs.voices.count == 1, "the paid voice is reused")
        #expect(stubs.lipsyncs == [.sync3, .sync3])
    }

    @Test func aFailedLipSyncKeepsTheClipAndTryAgainPaysOnlyTheLipSync() async {
        let stubs = Stubs()
        stubs.failLipsync = true
        let session = session(stubs)
        session.start()
        await session.waitForRun()
        guard case .stopped(let line) = session.phase else { Issue.record("not stopped"); return }
        #expect(line.contains("fal.ai returned HTTP 503.") && line.contains("Spent so far:"))
        #expect(session.steps[.lipsync] == .failed("fal.ai returned HTTP 503."))
        stubs.failLipsync = false
        session.start()
        await session.waitForRun()
        #expect(session.phase == .review && stubs.voices.count == 1 && stubs.lipsyncs.count == 2)
        #expect(session.spent == Decimal(string: "1.61"))
    }

    /// MVP46: fal.ai billed a lip sync whose result failed its checks. The Stopped copy says what happened and that fal.ai
    /// charged for it, the spent total includes it, its result is kept so Try Again is free, and a free re-import of it
    /// is not counted twice.
    @Test func aBilledLipSyncFailureNamesTheChargeAndTryAgainIsFree() async throws {
        let shared = try SharedResources.locate()
        let project = try JSONProjectStore.decode(Data(contentsOf: shared.root.appendingPathComponent("fixtures/voice-lab/passage-render-v3.voxclip")))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-whole-clip-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(settingsStore: RegressionSettingsStore(), locations: DataLocations(environment: ["VOXCLIP_DATA_DIR": root.path]))
        let editor = EditorModel(document: VoxClipDocument(project: project, demo: true), app: app, preview: DemoPreviewEngine())
        defer { editor.close() }
        let rewrite = RewriteSession(editor: editor, scope: .clip("clip-main"), envelope: nil, connector: nil)
        let stubs = Stubs()
        let short = LipsyncResultCheck.duration(LipsyncResultLength(got: 25.75, needed: 25.92, uploaded: 26.44, fps: 30))
        stubs.lipsyncError = WholeClipRevoiceSession.LipsyncFailed(error: short, local: false, usd: Decimal(string: "1.55"),
                                                                   requestID: "r-1", freeRetry: true)
        let session = session(stubs)
        rewrite.wholeClip = session
        await session.refreshQuote()
        session.start()
        await session.waitForRun()
        guard case .stopped(let line) = session.phase else { Issue.record("not stopped"); return }
        let charge = VoiceLabCostPresentation.format(Decimal(string: "1.55")!)
        #expect(line.hasPrefix("Couldn't lip sync: fal.ai's video came back 0.2 s shorter than the voice. fal.ai accepted the job (estimated cost: \(charge)). Try Again checks the same job for free."), "\(line)")
        #expect(line.contains("Spent so far: \(VoiceLabCostPresentation.format(Decimal(string: "1.61")!))"), "\(line)")
        #expect(session.spent == Decimal(string: "1.61"))
        #expect(session.retryUSD == 0)
        let stopped = rewrite.proposalContent()
        #expect(stopped.cards == [.wholeClip] && stopped.footer == PanelFooter() && stopped.askAgain == nil)
        let retry = try #require(rewrite.wholeClipStoppedActions().first)
        #expect(retry.id == "wholeClipRetry" && retry.title == "Try Again · free", "\(retry.title)")
        // The free re-import moves the charge into the ledger: still 1.61 in all.
        stubs.lipsyncError = nil; stubs.recoveredRequest = "r-1"
        session.start()
        await session.waitForRun()
        #expect(session.phase == .review && stubs.voices.count == 1)
        #expect(session.spent == Decimal(string: "1.61"))
        let review = rewrite.proposalContent()
        #expect(review.cards == [.wholeClip] && review.footer == PanelFooter() && review.askAgain == nil)
    }

    /// A billed failure whose result isn't kept: Try Again pays the lip sync again, and both charges count.
    @Test func aBilledFailureWithNothingKeptPricesTryAgainAndCountsBothCharges() async {
        let stubs = Stubs()
        stubs.lipsyncError = WholeClipRevoiceSession.LipsyncFailed(error: LipsyncResultCheck.duration(.init(got: 4, needed: 6, uploaded: 7, fps: 30)), local: false,
                                                                   usd: Decimal(string: "1.55"), requestID: "accepted-job", freeRetry: false)
        let session = session(stubs)
        await session.refreshQuote()
        session.start()
        await session.waitForRun()
        guard case .stopped(let line) = session.phase else { Issue.record("not stopped"); return }
        #expect(line.contains("fal.ai accepted the job") && !line.contains("for free"), "\(line)")
        #expect(session.retryUSD == Decimal(string: "1.55"))
        stubs.lipsyncError = nil
        session.start()
        await session.waitForRun()
        #expect(session.phase == .review)
        #expect(session.spent == Decimal(string: "3.16"))
    }

    @Test(arguments: [false, true]) func aPictureRetryCannotBuySpeechForAChangedTimeline(changeWords: Bool) async throws {
        let stubs = Stubs()
        stubs.voiceSeconds = [28.6]; stubs.video = 28.2
        stubs.lipsyncError = WholeClipRevoiceSession.LipsyncFailed(error: LipsyncNotSubmitted(error: LipsyncError.invalidResponse), local: false)
        let session = session(stubs)
        session.start(); await session.waitForRun()
        let kept = try #require(session.voice)
        #expect(stubs.lipsyncs == [.standard])
        stubs.lipsyncError = nil
        if changeWords {
            // Same audible text; a different source word map invalidates the paid take.
            let words = Self.words.map { TimedWord(id: "new-" + $0.id, text: $0.text, start: $0.start + 1, end: $0.end + 1) }
            let mapped = try #require(WholeClipScript.assemble(words: words, cutWordIds: [], voiceHunks: []))
            session.backend?.script = { mapped }
        } else { stubs.video = 14 }
        session.start(); await session.waitForRun()
        #expect(session.isStopped && session.voice == kept)
        #expect(stubs.lipsyncs == [.standard] && stubs.voices == [kept.key.script] && stubs.rewords.isEmpty)
    }

    @Test func lostQueueReceiptDoesNotCountTheQuoteOrLetAnotherClickResubmit() async {
        let stubs = Stubs()
        stubs.lipsyncError = WholeClipRevoiceSession.LipsyncFailed(error: LipsyncError.submissionUncertain, local: false, usd: 1.55)
        let session = session(stubs)
        await session.refreshQuote(); session.start(); await session.waitForRun()
        guard case .stopped(let line) = session.phase else { Issue.record("expected a stop"); return }
        #expect(session.failure?.repeats == true && line.contains("couldn't confirm"))
        #expect(session.spent == 0.06 && session.billedLipsyncs.isEmpty)
        stubs.lipsyncError = nil; session.start(); await session.waitForRun()
        #expect(session.isStopped && stubs.lipsyncs.count == 1 && stubs.voices.count == 1)
    }

    @Test func undoOnReviewKeepsTheOriginalAndOffersTheChoiceAgain() async {
        let stubs = Stubs()
        let session = session(stubs)
        session.start()
        await session.waitForRun()
        await session.discard()
        #expect(session.phase == .choose && stubs.discarded == 1 && stubs.used == 0)
    }

    /// The second part of the user's clip (MVP42, 2026-11-08): its seam would sit beside a cut, so placement refuses it.
    static let refusal = ClipTakePlan.Failure.placement(.geometry(.seamFadeCrossesCut(incoming: true, needed: 288, available: 0)), index: 1)

    @Test func aPartThatCantBePlacedSaysWhichPartLogsOneLineAndWouldOnlyRepeat() async {
        let stubs = Stubs()
        stubs.voiceError = WholeClipRevoiceSession.Unsent(error: Self.refusal)
        let session = session(stubs)
        await session.refreshQuote()
        session.start()
        await session.waitForRun()
        let copy = "Part 2 can't be joined to the recording there. Nothing was sent."
        #expect(session.phase == .stopped(copy), "not the lip-sync copy: \(session.phase)")
        #expect(session.steps[.voice] == .failed(copy))
        #expect(session.failure == WholeClipRevoiceSession.Failure(step: .voice, part: 2, repeats: true))
        #expect(stubs.reports == ["whole clip failure step=voice type=ClipTakePlan.Failure case=placement.geometry.seamFadeCrossesCut part=2"])
        #expect(stubs.voices.isEmpty && stubs.lipsyncs.isEmpty && session.spent == 0)
        // Unwrapped, the refusal still says which part and would still only repeat.
        #expect(WholeClipRevoiceSession.copy(Self.refusal) == copy && WholeClipRevoiceSession.repeats(Self.refusal))
        #expect(WholeClipRevoiceSession.copy(ClipTakePlan.Failure.placement(.collidesWithChange(0), index: 2))
                == "Part 3: Too close to the change before it to voice separately. Edit them together or leave one out. Nothing was sent.")
        #expect(WholeClipRevoiceSession.copy(ClipTakePlan.Failure.placement(.geometry(.seamFadeOutsideTake(isStart: true)), index: 0))
                == "Part 1 can't be joined to the recording there: it is too close to the start of the take. Nothing was sent.")
    }

    @Test func aNetworkFailureCanSucceedOnARetry() async {
        let stubs = Stubs()
        stubs.voiceError = VoiceLabError.network
        let session = session(stubs)
        session.start()
        await session.waitForRun()
        #expect(session.phase == .stopped(RewriteSession.voiceLabCopy(.network)))
        #expect(session.failure == WholeClipRevoiceSession.Failure(step: .voice, part: nil, repeats: false))
        #expect(stubs.reports == ["whole clip failure step=voice type=VoiceLabError case=network"])
    }

    @Test func onlyLipSyncErrorsUseTheLipSyncCopy() {
        #expect(WholeClipRevoiceSession.copy(LipsyncError.http(503)) == "fal.ai returned HTTP 503.")
        #expect(WholeClipRevoiceSession.copy(ClipTakePlan.Failure.nothingToVoice) == ClipTakePlan.copy(ClipTakePlan.Failure.nothingToVoice))
        #expect(WholeClipRevoiceSession.copy(VoxClipError.offline) == RewriteSession.refusal(VoxClipError.offline))
        #expect(!WholeClipRevoiceSession.copy(VoxClipError.offline).contains("The job could not be completed"))
    }

    @Test func aScriptThatFailsStopsAtTheScriptAndWouldOnlyRepeat() async {
        let stubs = Stubs()
        let session = session(stubs)
        session.backend?.script = { throw ClipTakePlan.Failure.nothingToVoice }
        session.start()
        await session.waitForRun()
        #expect(session.failure == WholeClipRevoiceSession.Failure(step: .script, part: nil, repeats: true))
        #expect(session.steps[.script] == .failed(ClipTakePlan.copy(ClipTakePlan.Failure.nothingToVoice)))
        #expect(stubs.reports == ["whole clip failure step=script type=ClipTakePlan.Failure case=nothingToVoice"])
    }

    /// The card's stopped actions in a Rewrite: after a stop that would only repeat, the patch alone, never a priced Try
    /// Again; after a network failure, Try Again with what is left to pay, then the patch.
    @Test func theStoppedCardOffersThePatchAndTryAgainOnlyWhenARetryCanSucceed() async throws {
        let shared = try SharedResources.locate()
        let project = try JSONProjectStore.decode(Data(contentsOf: shared.root.appendingPathComponent("fixtures/voice-lab/passage-render-v3.voxclip")))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-whole-clip-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(settingsStore: RegressionSettingsStore(), locations: DataLocations(environment: ["VOXCLIP_DATA_DIR": root.path]))
        let editor = EditorModel(document: VoxClipDocument(project: project, demo: true), app: app, preview: DemoPreviewEngine())
        defer { editor.close() }
        let rewrite = RewriteSession(editor: editor, scope: .clip("clip-main"), envelope: nil, connector: nil)
        for (error, expected) in [(Self.refusal as any Error, ["wholeClipPatch"]), (VoiceLabError.network, ["wholeClipRetry", "wholeClipPatch"])] {
            let stubs = Stubs()
            stubs.voiceError = error
            let session = session(stubs)
            rewrite.wholeClip = session
            await session.refreshQuote()
            session.start()
            await session.waitForRun()
            let actions = rewrite.wholeClipStoppedActions()
            #expect(actions.map(\.id) == expected, "\(error)")
            #expect(actions.last?.title == "Voice Only the Changed Phrases" && actions.last?.priced == false)
            if expected.count == 2 { #expect(actions[0].title == "Try Again · " + VoiceLabCostPresentation.format(Decimal(string: "1.61")!) && actions[0].priced, "\(actions[0].title)") }
            else { #expect(!actions.contains { $0.priced || $0.title.contains("$") }, "no price for work that can't happen") }
        }
        // A voice that can't fit, over the same script: Try Again would meet the same fit, so the patch is the primary and
        // nothing is voiced until the user picks.
        let stubs = Stubs()
        stubs.voiceSeconds = [40]
        let session = session(stubs)
        rewrite.wholeClip = session
        await session.refreshQuote()
        session.start()
        await session.waitForRun()
        let actions = rewrite.wholeClipStoppedActions()
        // No shorter wording came back: asking again is free, and no priced Try Again could pass (wholeclip-retry-after-fit-stop).
        #expect(actions.map(\.id) == ["wholeClipPatch", "wholeClipShorter"], "\(actions.map(\.id))")
        #expect(actions[1].title == "Shorter Wording · free" && !actions[1].priced)
        #expect(actions[0].title == "Voice Only the Changed Phrases (drops the paid voice)")
        #expect(stubs.voices.count == 1, "no second voice")
        // Once the clip's words change, the paid voice no longer matches them: Start Over prices the clip as it is.
        let changed = WholeClipScript.assemble(words: Array(Self.words.prefix(4)), cutWordIds: [], voiceHunks: [])!
        session.backend?.script = { changed }
        #expect(rewrite.wholeClipStoppedActions().map(\.id) == ["wholeClipStartOver", "wholeClipPatch"])
    }

    /// The user's MVP45 run (2026-11-08), as numbers: "Clip 1 · 0:31.4", a 52-word voice of 20.2 s for 0:31.3 of video. It
    /// read "laid out on the clip's pauses (−35.4%)" and then failed at the lip sync with a reason known at Fit. Now the Fit
    /// step checks the picture first, the picture plays 1.2× (Core's layout: 24.1 s of output over 28.9 s of picture,
    /// `WholeClipPictureSpeedTests`), and the lip sync is offered over that picture, at that speed.
    @Test func theUsersCaseChecksThePictureAtFitThenLipSyncsTheSpedPicture() async {
        let stubs = Stubs()
        stubs.voiceSeconds = [20.2]
        stubs.video = 31.3
        stubs.picture = .init(speed: 1.2, outputSeconds: 24.12, laidOut: true)
        let session = session(stubs)
        session.start()
        await session.waitForRun()
        #expect(session.phase == .review, "\(session.phase)")
        #expect(session.steps[.fit] == .done("Fit · 0:20.2 for 0:31.3 of video, picture 1.20× and laid out on the clip's pauses"))
        #expect(stubs.order == ["voice", "picture", "lipsync"], "the picture is matched at Fit, before the lip sync")
        #expect(stubs.pictures == [20.2] && stubs.lipsyncFactors == [1.2])
        await session.use()
        #expect(session.record?.videoRetime == 1.2, "the record keeps the picture's speed")
    }

    /// A picture that can't be matched stops at Fit with its reason, makes no lip-sync call, and the patch is the way on.
    @Test func anInfeasiblePictureStopsAtFitWithNoLipSync() async throws {
        let stubs = Stubs()
        stubs.voiceSeconds = [20.2]
        stubs.pictureError = WholeClipRevoiceSession.Stop.pictureUnmatched(part: 1)
        let session = session(stubs)
        session.start()
        await session.waitForRun()
        let copy = "Part 1's picture can't be matched to its voice on the clip as edited. Nothing was sent for lip sync."
        guard case .stopped(let line) = session.phase else { Issue.record("\(session.phase)"); return }
        #expect(line.hasPrefix(copy) && line.contains("Spent so far:"), "\(line)")
        #expect(session.steps[.fit] == .failed(copy) && session.steps[.lipsync] == .waiting)
        #expect(stubs.lipsyncs.isEmpty, "no lip-sync call")
        #expect(session.failure == WholeClipRevoiceSession.Failure(step: .fit, part: 1, repeats: true))
        #expect(stubs.reports == ["whole clip failure step=fit type=WholeClipRevoiceSession.Stop case=pictureUnmatched part=1"])
        // A preparation failure behind it is named with its own case, and would repeat too.
        let unmatched = WholeClipRevoiceSession.Unmatched(error: ClipTakePlan.Failure.unknownSpend)
        #expect(WholeClipRevoiceSession.repeats(unmatched))
        #expect(RewriteSession.failureKind(WholeClipRevoiceSession.cause(unmatched)) == "type=ClipTakePlan.Failure case=unknownSpend")
    }

    /// MVP45: the lip sync failed on this Mac (a 4K window that couldn't be prepared), was logged as `noVoice` with the
    /// generic "The job could not be completed." copy, and every Try Again met the same stop at once. Now the stop names
    /// what failed with its real case, offers no priced Try Again, and a retry runs the picture check and the lip sync
    /// again from a clean start, so once the cause is gone it goes through.
    @Test func aLocalLipSyncFailureSaysWhatFailedAndARetryStartsClean() async {
        let stubs = Stubs()
        stubs.lipsyncError = WholeClipRevoiceSession.LipsyncFailed(error: LipsyncPreparationError.unsupportedVideo, local: true)
        let session = session(stubs)
        session.start()
        await session.waitForRun()
        let copy = "Couldn't lip sync: This part cannot be prepared for lip sync. Your original video is unchanged. Nothing was sent to fal.ai."
        guard case .stopped(let line) = session.phase else { Issue.record("\(session.phase)"); return }
        #expect(line.hasPrefix(copy) && !line.contains("The job could not be completed"), "\(line)")
        #expect(session.failure == WholeClipRevoiceSession.Failure(step: .lipsync, part: nil, repeats: true))
        #expect(stubs.reports == ["whole clip failure step=lipsync type=LipsyncPreparationError case=unsupportedVideo"])
        // The same stop again: the second failure knows it repeated.
        session.start()
        await session.waitForRun()
        #expect(session.failure?.again == true && stubs.pictures.count == 2 && stubs.lipsyncs.count == 2, "both checks ran again")
        // Once the cause is gone, Try Again goes through on the paid voice.
        stubs.lipsyncError = nil
        session.start()
        await session.waitForRun()
        #expect(session.phase == .review && stubs.voices.count == 1, "the voice was paid once")
    }

    /// A provider failure that stops the same way twice: Try Again stays offered, priced, but the patch leads.
    @Test func theSameProviderFailureTwiceMakesThePatchPrimary() async throws {
        let shared = try SharedResources.locate()
        let project = try JSONProjectStore.decode(Data(contentsOf: shared.root.appendingPathComponent("fixtures/voice-lab/passage-render-v3.voxclip")))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-whole-clip-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(settingsStore: RegressionSettingsStore(), locations: DataLocations(environment: ["VOXCLIP_DATA_DIR": root.path]))
        let editor = EditorModel(document: VoxClipDocument(project: project, demo: true), app: app, preview: DemoPreviewEngine())
        defer { editor.close() }
        let rewrite = RewriteSession(editor: editor, scope: .clip("clip-main"), envelope: nil, connector: nil)
        let stubs = Stubs()
        stubs.lipsyncError = WholeClipRevoiceSession.LipsyncFailed(error: LipsyncError.http(503), local: false)
        let session = session(stubs)
        rewrite.wholeClip = session
        await session.refreshQuote()
        session.start()
        await session.waitForRun()
        #expect(rewrite.wholeClipStoppedActions().map(\.id) == ["wholeClipRetry", "wholeClipVoiceOnly", "wholeClipPatch"], "a provider failure can succeed on a retry")
        session.start()
        await session.waitForRun()
        #expect(rewrite.wholeClipStoppedActions().map(\.id) == ["wholeClipVoiceOnly", "wholeClipPatch", "wholeClipRetry"], "the same stop twice: the patch leads the paid ones")
        // A local failure offers no priced Try Again at all; the paid voice can still go in without lip sync, free.
        stubs.lipsyncError = WholeClipRevoiceSession.LipsyncFailed(error: LipsyncPreparationError.unsupportedVideo, local: true)
        session.start()
        await session.waitForRun()
        let actions = rewrite.wholeClipStoppedActions()
        #expect(actions.map(\.id) == ["wholeClipVoiceOnly", "wholeClipPatch"] && !actions.contains { $0.priced })
    }

    @Test func anAutomaticRunPutsTheResultInWithNoClick() async {
        let stubs = Stubs()
        let session = session(stubs)
        session.start(automatic: true)
        await session.waitForRun()
        #expect(session.phase == .used && stubs.used == 1)
    }

    // MARK: Rewrite and lip-sync reliability (package B)

    /// wholeclip-fit-stale-retry-loop, wholeclip-stale-snapshot-blocks-free-lipsync-retry: the voice is paid, the lip sync
    /// fails, then a save and a music track change the project. The plan's currency reads what the voice is made from
    /// (`RewriteSession.wholeClipInputsStillCurrent`), so Try Again reaches the lip sync over the paid voice. A word cut in the
    /// clip is what changes it.
    @Test func aSaveOrMusicNeverMakesThePaidVoiceStaleButAWordEditDoes() async throws {
        let live = try live()
        defer { close(live) }
        let stubs = Stubs()
        stubs.isCurrent = live.rewrite.wholeClipInputsStillCurrent()
        stubs.lipsyncError = WholeClipRevoiceSession.LipsyncFailed(error: LipsyncNotSubmitted(error: URLError(.networkConnectionLost)), local: false)
        let session = session(stubs)
        live.rewrite.wholeClip = session
        await session.refreshQuote()
        session.start()
        await session.waitForRun()
        #expect(session.failure?.step == .lipsync && stubs.voices.count == 1)
        // A save (modifiedAt only), then music under the clip.
        var saved = live.editor.project
        saved.modifiedAt = saved.modifiedAt.addingTimeInterval(60)
        live.editor.document.replaceProject(saved)
        var music = live.editor.project
        music.music = [ProjectMusic(id: "music-a", clipId: "clip-main", asset: MusicAsset(file: music.id + "/music-own.wav",
            sha256: String(repeating: "c", count: 64), durationSeconds: 30), source: .file, title: "own", license: .own)]
        music.schemaVersion = 4
        live.editor.replace(music, name: "Add music")
        #expect(stubs.isCurrent?() == true, "a save and music are not part of what the voice is made from")
        #expect(live.rewrite.wholeClipStoppedActions().first?.id == "wholeClipRetry")
        stubs.lipsyncError = nil
        session.start()
        await session.waitForRun()
        #expect(session.phase == .review, "\(session.phase)")
        #expect(stubs.lipsyncs.count == 2 && stubs.voices.count == 1, "the lip sync is reached with no second voice")
        // A cut word in the clip is an edit of what the voice is made from.
        var cut = live.editor.project
        cut.edits.cutWordIds.append("w5")
        live.editor.replace(cut, name: "Cut")
        #expect(stubs.isCurrent?() == false)
    }

    /// wholeclip-voice-stale-after-paid-voice, wholeclip-retry-loops-on-stale: a paid voice, then the clip's words change.
    /// The stop says so and keeps the voice: no priced Try Again that can only stop again, but Start Over (priced for the
    /// clip as it is) and the patch. Undo brings Try Again back over the paid voice.
    @Test func aWordEditAfterThePaidVoiceStopsWithInputsChangedAndUndoBringsTryAgainBack() async throws {
        let live = try live()
        defer { close(live) }
        let stubs = Stubs()
        stubs.lipsyncError = WholeClipRevoiceSession.LipsyncFailed(error: LipsyncError.http(503), local: false)
        let session = session(stubs)
        live.rewrite.wholeClip = session
        await session.refreshQuote()
        session.start()
        await session.waitForRun()
        let original = try #require(session.backend?.script)
        let edited = WholeClipScript.assemble(words: Array(Self.words.prefix(4)), cutWordIds: [], voiceHunks: [])!
        session.backend?.script = { edited }
        var actions = live.rewrite.wholeClipStoppedActions()
        #expect(actions.map(\.id) == ["wholeClipStartOver", "wholeClipPatch"], "\(actions.map(\.id))")
        #expect(!actions.contains { $0.id == "wholeClipRetry" })
        stubs.lipsyncError = nil
        session.start()
        await session.waitForRun()
        guard case .stopped(let line) = session.phase else { Issue.record("\(session.phase)"); return }
        #expect(line.hasPrefix("You edited Clip 7 after its voice was made, so the paid voice (\(VoiceLabCostPresentation.format(Decimal(string: "0.06")!))) no longer matches."), "\(line)")
        #expect(session.failure?.repeats == true && !line.contains("Nothing was sent"))
        #expect(stubs.voices.count == 1 && stubs.lipsyncs.count == 1, "nothing new paid")
        actions = live.rewrite.wholeClipStoppedActions()
        #expect(actions.map(\.id) == ["wholeClipStartOver", "wholeClipPatch"])
        #expect(actions[0].title == "Start Over · " + VoiceLabCostPresentation.format(Decimal(string: "1.61")!) && actions[0].priced)
        // Undo: the paid voice matches again, and Try Again uses it.
        session.backend?.script = original
        actions = live.rewrite.wholeClipStoppedActions()
        #expect(actions.first?.id == "wholeClipRetry", "\(actions.map(\.id))")
        session.start()
        await session.waitForRun()
        #expect(session.phase == .review && stubs.voices.count == 1 && stubs.lipsyncs.count == 2)
    }

    /// stale-unsent-hides-retry: a plan that went stale before anything was paid is made fresh by the next click, so Try
    /// Again is offered (with the price of the clip as it is); a stale stop over a paid voice is the inputs-changed stop.
    @Test func anUnpaidStaleStopOffersAFreshTryAgain() async throws {
        let live = try live()
        defer { close(live) }
        let stubs = Stubs()
        stubs.voiceError = WholeClipRevoiceSession.Unsent(error: ClipTakePlan.Failure.stale)
        let session = session(stubs)
        live.rewrite.wholeClip = session
        await session.refreshQuote()
        session.start()
        await session.waitForRun()
        #expect(session.failure?.repeats == false && session.spent == 0)
        #expect(live.rewrite.wholeClipStoppedActions().map(\.id) == ["wholeClipRetry", "wholeClipPatch"])
        stubs.voiceError = nil
        session.start()
        await session.waitForRun()
        #expect(session.phase == .review)
        // The classification behind the card.
        typealias Session = WholeClipRevoiceSession
        #expect(!Session.repeats(Session.Unsent(error: ClipTakePlan.Failure.stale)))
        #expect(!Session.repeats(Session.Unsent(error: Session.LipsyncFailed(error: LipsyncError.missingKey, local: true))))
        #expect(Session.repeats(Session.Unsent(error: Self.refusal)))
        #expect(Session.repeats(Session.Stop.voiceInputsChanged(clip: 1, usd: 1)))
        var refused = LipsyncNotSubmitted(error: LipsyncError.http(422)); refused.queueRefused = true
        #expect(Session.repeats(Session.LipsyncFailed(error: refused, local: false)), "fal.ai declined this media: the same inputs meet it again")
        #expect(!Session.repeats(Session.LipsyncFailed(error: LipsyncNotSubmitted(error: LipsyncError.http(503)), local: false)))
    }

    /// whole-clip-fixable-stops-patch-only: with no fal.ai key nothing is priced; the primary opens Settings. Once the key is
    /// saved the card offers the price, and the stop's Try Again.
    @Test func noFalKeyOffersSettingsUntilTheKeyIsAdded() async throws {
        let live = try live(ready: true) { $0.voiceLab.segments = [] }
        defer { close(live) }
        let stubs = Stubs()
        stubs.hasKey = false
        stubs.voiceError = WholeClipRevoiceSession.Unsent(error: WholeClipRevoiceSession.LipsyncFailed(error: LipsyncError.missingKey, local: true))
        let session = session(stubs)
        live.rewrite.wholeClip = session
        await session.refreshQuote()
        let primary = try #require(live.rewrite.wholeClipPrimary())
        #expect(primary.id == "wholeClipAddKey" && primary.title == "Add fal.ai Key…" && !primary.priced)
        session.start()
        await session.waitForRun()
        #expect(session.failure?.repeats == false && !session.keyAvailable)
        #expect(live.rewrite.wholeClipStoppedActions().map(\.id) == ["wholeClipAddKey", "wholeClipPatch"])
        // The key is saved in Settings (connectorReadinessRevision moves; the card reads the key again).
        stubs.hasKey = true
        await session.refreshReadiness()
        #expect(live.rewrite.wholeClipStoppedActions().map(\.id) == ["wholeClipRetry", "wholeClipPatch"])
        stubs.voiceError = nil
        session.start()
        await session.waitForRun()
        #expect(session.phase == .review)
    }

    /// wholeclip-fit-drops-paid-lipsync, retry-unapplies-paid-lipsync, whole-clip-retry-undoes-paid-lipsync,
    @Test func aFailedUseKeepsThePaidLipSyncForFreeRetry() async throws {
        let live = try live()
        defer { close(live) }
        let stubs = Stubs()
        stubs.tracksApplied = true
        let session = session(stubs)
        live.rewrite.wholeClip = session
        await session.refreshQuote()
        session.start()
        await session.waitForRun()
        #expect(session.phase == .review && stubs.applied[0]?.result.asset.id == "asset-sync-3")
        // Use fails once: Try Use Again · free, nothing voiced or patched.
        stubs.useError = VoiceLabProjectError.staleRenderContract
        await session.use()
        #expect(session.failure?.atUse == true && session.failure?.repeats == false)
        let actions = live.rewrite.wholeClipStoppedActions()
        #expect(actions.map(\.id) == ["wholeClipUseAgain", "wholeClipPatch"] && actions[0].title == "Try Use Again · free" && !actions[0].priced)
        await session.useAgain()
        #expect(session.phase == .used && stubs.usedAssets == [["asset-sync-3"]], "\(stubs.usedAssets)")
        #expect(stubs.lipsyncs == [.sync3] && stubs.voices.count == 1, "nothing paid twice")
    }

    /// A lip sync paid over this voice and picture is priced at nothing on Try Again, and put back rather than paid again
    /// (C's imported index answers a lip sync that may not pay). Use refuses when the paid lip sync can't be put back.
    @Test func aPaidLipSyncIsPutBackForFreeAndUseNeverDropsIt() async throws {
        let stubs = Stubs()
        stubs.tracksApplied = true
        let session = session(stubs)
        await session.refreshQuote()
        session.start()
        await session.waitForRun()
        // Something took the lip sync off the parts and it can't be restored as it was.
        stubs.applied = [:]; stubs.refuseRestore = true
        await session.use()
        guard case .stopped(let line) = session.phase else { Issue.record("\(session.phase)"); return }
        #expect(line.hasPrefix("The paid lip sync is no longer on the clip's parts, so nothing was put in."), "\(line)")
        #expect(stubs.used == 0 && session.failure?.step == .lipsync && session.failure?.repeats == false)
        #expect(session.retryUSD == 0, "the lip sync was paid over this voice and picture")
        stubs.refuseRestore = false
        session.start()
        await session.waitForRun()
        #expect(session.phase == .review)
        await session.use()
        #expect(session.phase == .used && stubs.usedAssets == [["asset-sync-3"]])
        #expect(stubs.lipsyncs.count == 1, "put back, never paid again: \(stubs.lipsyncs)")
    }

    /// wholeclip-retry-after-fit-stop: a Fit stop whose way on is a shorter wording offers it for free; asking again calls
    /// the AI again (never "This retry only covers lip sync") and the wording's voice waits for its priced click.
    @Test func aFitStopAsksForAShorterWordingAgainForFree() async throws {
        let live = try live()
        defer { close(live) }
        let stubs = Stubs()
        stubs.voiceSeconds = [36, 31]
        stubs.reword = nil
        let session = session(stubs)
        live.rewrite.wholeClip = session
        await session.refreshQuote()
        session.start()
        await session.waitForRun()
        #expect(session.failure?.step == .fit && session.failure?.rewordable == true && stubs.rewords.count == 1)
        let shorter = WholeClipScript.assemble(words: Array(Self.words.prefix(4)), cutWordIds: [], voiceHunks: [])!
        stubs.reword = shorter
        let ask = try #require(live.rewrite.wholeClipStoppedActions().first { $0.id == "wholeClipShorter" })
        #expect(ask.title == "Shorter Wording · free")
        session.askShorterWording()
        await session.waitForRun()
        #expect(stubs.rewords.count == 2 && stubs.voices.count == 1, "the AI is asked again, and nothing is voiced")
        guard case .stopped(let line) = session.phase else { Issue.record("\(session.phase)"); return }
        #expect(!line.contains("This retry only covers lip sync"))
        let voice = try #require(live.rewrite.wholeClipStoppedActions().first)
        #expect(voice.id == "wholeClipVoiceShorter" && voice.title == "Voice the Shorter Wording · " + VoiceLabCostPresentation.format(Decimal(string: "1.61")!) && voice.priced)
        session.voiceShorterWording()
        await session.waitForRun()
        #expect(session.phase == .review && stubs.voices == [Self.script.text, shorter.text])
    }

    /// wholeclip-voice-stale-after-paid-voice: a Fit stop keeps no voice for the retry (no picture yet), but its voice was
    /// paid; a word edit then stops Try Again before it voices the new words, and Start Over prices them.
    @Test func aWordEditAfterAPaidVoiceThatStoppedAtTheFitPaysNothingOnTryAgain() async throws {
        let live = try live()
        defer { close(live) }
        let stubs = Stubs()
        stubs.voiceSeconds = [36, 31]
        stubs.reword = nil
        let session = session(stubs)
        live.rewrite.wholeClip = session
        await session.refreshQuote()
        session.start()
        await session.waitForRun()
        #expect(session.failure?.step == .fit && stubs.voices.count == 1)
        let edited = WholeClipScript.assemble(words: Array(Self.words.prefix(4)), cutWordIds: [], voiceHunks: [])!
        session.backend?.script = { edited }
        session.start()
        await session.waitForRun()
        guard case .stopped(let line) = session.phase else { Issue.record("\(session.phase)"); return }
        #expect(line.hasPrefix("You edited Clip 7 after its voice was made"), "\(line)")
        #expect(stubs.voices.count == 1, "nothing new voiced")
        #expect(live.rewrite.wholeClipStoppedActions().first?.id == "wholeClipStartOver")
    }

    /// wholeclip-retry-after-reword-voice-stop: the reworded voice stops at the Voice step; Try Again voices the reworded
    /// script's unfinished parts (no lip-sync-only refusal).
    @Test func aRewordedVoiceThatStopsAtTheVoiceRetriesTheRewordedScript() async throws {
        let stubs = Stubs()
        stubs.voiceSeconds = [36, 31]
        let shorter = WholeClipScript.assemble(words: Array(Self.words.prefix(4)), cutWordIds: [], voiceHunks: [])!
        stubs.reword = shorter
        let session = session(stubs)
        await session.refreshQuote()
        session.start()
        await session.waitForRun()
        #expect(session.shorterWording?.script == shorter)
        stubs.voiceError = WholeClipRevoiceSession.Stop.partVoice(part: 2, reason: "The voice did not match.", checks: [.speaker])
        session.voiceShorterWording()
        await session.waitForRun()
        #expect(session.failure?.step == .voice && session.failure?.repeats == false)
        stubs.voiceError = nil
        session.start()
        await session.waitForRun()
        #expect(session.phase == .review, "\(session.phase)")
        #expect(stubs.voices.last == shorter.text, "the reworded script is voiced: \(stubs.voices)")
    }

    /// wholeclip-no-prepay-fit-check: a script whose calibrated estimate runs 1.3× the clip as edited is reworded before the
    /// first voice; only the shorter wording is voiced, under the first click.
    @Test func aScriptEstimatedTooLongIsRewordedBeforeTheFirstVoice() async throws {
        let stubs = Stubs()
        stubs.voiceSeconds = [30]
        let shorter = WholeClipScript.assemble(words: Array(Self.words.prefix(4)), cutWordIds: [], voiceHunks: [])!
        stubs.reword = shorter
        stubs.estimates = [Self.script.text: 31 * 1.3, shorter.text: 30]
        let session = session(stubs)
        await session.refreshQuote()
        session.start()
        await session.waitForRun()
        #expect(stubs.order.prefix(2) == ["reword", "voice"], "\(stubs.order)")
        #expect(stubs.voices == [shorter.text] && session.phase == .review)
        // No shorter wording back: nothing is voiced, and asking again is free.
        let second = Stubs()
        second.reword = nil
        second.estimates = [Self.script.text: 31 * 1.3]
        let other = self.session(second)
        await other.refreshQuote()
        other.start()
        await other.waitForRun()
        guard case .stopped(let line) = other.phase else { Issue.record("\(other.phase)"); return }
        #expect(line.hasPrefix("The script would run about 0:40.3 for 0:31 of video, and no shorter wording came back, so no voice was made."), "\(line)")
        #expect(second.voices.isEmpty && other.failure?.step == .fit && other.canAskShorterWording)
    }

    /// no-voice-only-and-late-checks: a source the lip sync can't take (120 fps) stops before any voice is paid. The live
    /// check is the lip sync's own preflight on the source.
    @Test func aSourceTheLipSyncCantTakeStopsBeforeTheVoice() async throws {
        let stubs = Stubs()
        stubs.preflightError = WholeClipRevoiceSession.Unsent(error: WholeClipRevoiceSession.LipsyncFailed(error: LipsyncPreparationError.unsupportedVideo, local: true))
        let session = session(stubs)
        await session.refreshQuote()
        session.start()
        await session.waitForRun()
        #expect(stubs.voices.isEmpty && session.spent == 0 && session.failure?.repeats == true, "never voiced")
        let live = try live { $0.media.source.video?.frameRate = 120 }
        defer { close(live) }
        let real = WholeClipRevoiceSession()
        live.rewrite.configureWholeClip(real)
        let preflight = try #require(real.backend?.preflight)
        await #expect(throws: WholeClipRevoiceSession.Unsent.self) { try await preflight() }
    }

    /// submission-uncertain-dead-end: a lost submit answer waits for the user's own "I Checked fal.ai" (it may charge twice);
    /// an automatic run never takes it, and it runs only the lip sync over the paid voice.
    @Test func aLostSubmitAnswerWaitsForTheUsersCheck() async throws {
        let live = try live()
        defer { close(live) }
        let stubs = Stubs()
        stubs.lipsyncError = WholeClipRevoiceSession.LipsyncFailed(error: LipsyncError.submissionUncertain, local: false, usd: 1.55)
        let session = session(stubs)
        live.rewrite.wholeClip = session
        await session.refreshQuote()
        session.start(automatic: true, budget: 10)
        await session.waitForRun()
        #expect(session.submissionUnconfirmed && stubs.lipsyncs.count == 1)
        session.start(automatic: true, budget: 10)
        await session.waitForRun()
        #expect(stubs.lipsyncs.count == 1, "an automatic run never resubmits")
        let actions = live.rewrite.wholeClipStoppedActions()
        #expect(actions.map(\.id) == ["wholeClipCheckedFal", "wholeClipVoiceOnly", "wholeClipPatch"], "\(actions.map(\.id))")
        #expect(actions[0].title == "I Checked fal.ai · Lip Sync Again · \(VoiceLabCostPresentation.format(Decimal(string: "1.55")!)) (fal.ai may charge twice)")
        stubs.lipsyncError = nil
        session.lipsyncAfterCheckingFal()
        await session.waitForRun()
        #expect(session.phase == .review && stubs.lipsyncs.count == 2 && stubs.voices.count == 1 && stubs.pictures.count == 1,
                "only the lip sync ran again")
        #expect(!session.submissionUnconfirmed)
    }

    /// whole-clip-not-current-says-make-voice: the live Voice step says what stopped it. With the fal.ai key there and
    /// nothing paid, a Rewrite with no voice chosen says so, and nothing is sent.
    @Test func theLiveVoiceStepSaysWhatIsMissing() async throws {
        let live = try live()
        defer { close(live) }
        live.editor.app.providerKeyStoreOverride = FalKeyOnly()
        let session = WholeClipRevoiceSession()
        live.rewrite.configureWholeClip(session)
        let backend = try #require(session.backend)
        // The stop is one Try Again waits out (whole-clip-fixable-stops-patch-only): choosing a voice lets it pass.
        #expect(backend.voiceReadiness() == .voiceMissing)
        do {
            _ = try await backend.voice(Self.script) { _ in }
            Issue.record("no voice is chosen")
        } catch {
            guard case WholeClipRevoiceSession.Stop.voiceMissing = error else { Issue.record("\(error)"); return }
            #expect(WholeClipRevoiceSession.copy(error) == "Make your voice in Rewrite first. Nothing was sent.")
            #expect(!WholeClipRevoiceSession.repeats(error))
        }
    }

    /// whole-clip-fixable-stops-patch-only: a stop with no voice chosen waits for one. Until it is chosen the card offers
    /// the patch (a Try Again would meet the same stop); once it is, Try Again is back and passes.
    @Test func aStopWithNoVoiceChosenOffersTryAgainOnceOneIs() async throws {
        let live = try live()
        defer { close(live) }
        let stubs = Stubs()
        stubs.readiness = .voiceMissing
        stubs.voiceError = WholeClipRevoiceSession.Stop.voiceMissing
        let session = session(stubs)
        live.rewrite.wholeClip = session
        await session.refreshQuote()
        session.start()
        await session.waitForRun()
        #expect(session.failure?.step == .voice && session.failure?.repeats == false && session.waitsForReadiness)
        #expect(live.rewrite.wholeClipStoppedActions().map(\.id) == ["wholeClipPatch"])
        // A voice is made and chosen.
        stubs.readiness = nil; stubs.voiceError = nil
        #expect(!session.waitsForReadiness)
        #expect(live.rewrite.wholeClipStoppedActions().map(\.id) == ["wholeClipRetry", "wholeClipPatch"])
        session.start()
        await session.waitForRun()
        #expect(session.phase == .review && stubs.voices.count == 1)
        typealias Session = WholeClipRevoiceSession
        for stop in [Session.Stop.voiceMissing, .unavailable, .locked, .rewriteChanged(clip: 1)] {
            #expect(!Session.repeats(stop) && !Session.repeats(Session.Unsent(error: stop)), "\(stop)")
        }
    }

    /// whole-clip-stale-try-again-loop: an edit of the clip since the Rewrite was made, with no paid voice, is not a plain
    /// stale that a fresh plan could pass (`voiceSpendCurrent` compares with the Rewrite's own opening): the Voice step says
    /// so, and its Try Again waits for an Undo.
    @Test func anEditSinceTheRewriteStopsTheVoiceStepUntilUndo() async throws {
        let live = try live()
        defer { close(live) }
        live.editor.app.providerKeyStoreOverride = FalKeyOnly()
        let session = WholeClipRevoiceSession()
        live.rewrite.configureWholeClip(session)
        let backend = try #require(session.backend)
        let original = live.editor.project
        var cut = original
        cut.edits.cutWordIds.append("w5")
        live.editor.document.replaceProject(cut)
        #expect(!live.rewrite.voiceSpendCurrent)
        guard case .rewriteChanged? = backend.voiceReadiness() else { Issue.record("\(String(describing: backend.voiceReadiness()))"); return }
        do {
            _ = try await backend.voice(Self.script) { _ in }
            Issue.record("the Rewrite is out of date")
        } catch {
            guard case WholeClipRevoiceSession.Stop.rewriteChanged = error else { Issue.record("\(error)"); return }
            #expect(WholeClipRevoiceSession.copy(error).contains("after this Rewrite was made") && !WholeClipRevoiceSession.repeats(error))
        }
        live.editor.document.replaceProject(original)
        guard case .voiceMissing? = backend.voiceReadiness() else { Issue.record("\(String(describing: backend.voiceReadiness()))"); return }
    }

    /// no-voice-only-and-late-checks (lead decision): a paid voice whose lip sync can't run goes in without it, free, as
    /// ordinary Voice Lab segments; only the user's click does it. A stop before the picture matched offers no such Use.
    @Test func aPaidVoiceWhoseLipSyncCantRunCanGoInWithoutIt() async throws {
        let live = try live()
        defer { close(live) }
        let stubs = Stubs()
        stubs.lipsyncError = WholeClipRevoiceSession.LipsyncFailed(error: LipsyncPreparationError.unsupportedVideo, local: true)
        let session = session(stubs)
        live.rewrite.wholeClip = session
        await session.refreshQuote()
        session.start(automatic: true, budget: 10)
        await session.waitForRun()
        #expect(session.isStopped && stubs.voiceOnlyUses.isEmpty, "an automatic run never takes it")
        let actions = live.rewrite.wholeClipStoppedActions()
        #expect(actions.map(\.id) == ["wholeClipVoiceOnly", "wholeClipPatch"], "\(actions.map(\.id))")
        #expect(actions[0].title == "Use the Voice Without Lip Sync · free" && !actions[0].priced)
        // A failed Use keeps the stop and the action; the clip is unchanged.
        stubs.voiceOnlyError = VoiceLabProjectError.staleRenderContract
        await session.useVoiceOnly()
        guard case .stopped(let line) = session.phase else { Issue.record("\(session.phase)"); return }
        #expect(line.hasPrefix("Couldn't put the voice in without lip sync:") && line.contains("Your clip is unchanged."), "\(line)")
        #expect(live.rewrite.wholeClipStoppedActions().map(\.id) == ["wholeClipVoiceOnly", "wholeClipPatch"])
        await session.useVoiceOnly()
        #expect(session.phase == .used && session.usedVoiceOnly && session.record == nil)
        #expect(stubs.voiceOnlyUses == [Self.script.text] && stubs.voices.count == 1 && stubs.used == 0, "the paid voice, nothing new")
        // The Fit step's own lip-sync check refused after the voice was paid: offered. A picture that can't be matched or a
        // stop at the voice: not offered.
        for (error, offered) in [(WholeClipRevoiceSession.LipsyncFailed(error: LipsyncError.http(422), local: true) as any Error, true),
                                 (WholeClipRevoiceSession.Unmatched(error: VoiceLabProjectError.staleRenderContract), false)] {
            let stubs = Stubs()
            stubs.pictureError = error
            let session = self.session(stubs)
            live.rewrite.wholeClip = session
            await session.refreshQuote()
            session.start()
            await session.waitForRun()
            #expect(session.failure?.step == .fit && session.canUseVoiceOnly == offered, "\(error)")
            #expect(live.rewrite.wholeClipStoppedActions().contains { $0.id == "wholeClipVoiceOnly" } == offered)
        }
        let unvoiced = Stubs()
        unvoiced.voiceError = VoiceLabError.network
        let stopped = self.session(unvoiced)
        await stopped.refreshQuote()
        stopped.start()
        await stopped.waitForRun()
        #expect(stopped.isStopped && !stopped.canUseVoiceOnly, "no paid voice")
    }

    /// Billed results on cancel: fal.ai finished the job just as Cancel landed. The charge is counted, the result is kept,
    /// and Try Again is free (the stop says so once).
    @Test func aCancelAfterFalFinishedKeepsTheBilledLipSync() async throws {
        let stubs = Stubs()
        stubs.holdLipsync = true
        stubs.cancelledError = WholeClipRevoiceSession.LipsyncFailed(error: RewriteLipsyncSession.SetAside(cancelled: true), local: false,
                                                                     usd: Decimal(string: "1.55"), requestID: "late", freeRetry: true)
        let session = session(stubs)
        await session.refreshQuote()
        session.start()
        for _ in 0..<10_000 where stubs.held == nil { await Task.yield() }
        session.cancel()
        stubs.held?.resume(); stubs.held = nil
        await session.waitForRun()
        guard case .stopped(let line) = session.phase else { Issue.record("\(session.phase)"); return }
        let charge = VoiceLabCostPresentation.format(Decimal(string: "1.55")!)
        #expect(line.hasPrefix("Cancelled. fal.ai finished the lip sync (\(charge)); it's kept, so Try Again is free."), "\(line)")
        #expect(session.failure == nil && session.lipsyncKept && session.retryUSD == 0 && session.spent == Decimal(string: "1.61"))
        // Try Again re-imports it: no new voice, and the charge counted once.
        stubs.cancelledError = nil; stubs.holdLipsync = false; stubs.recoveredRequest = "late"
        session.start()
        await session.waitForRun()
        #expect(session.phase == .review && stubs.voices.count == 1 && session.spent == Decimal(string: "1.61"))
        // A result set aside without a cancel says it's kept and free once.
        let aside = WholeClipRevoiceSession.copy(WholeClipRevoiceSession.LipsyncFailed(error: RewriteLipsyncSession.SetAside(cancelled: false),
            local: false, usd: Decimal(string: "1.55"), requestID: "r", freeRetry: true))
        #expect(aside.components(separatedBy: "for free").count == 2, "\(aside)")
    }

    @Test func thePatchPickOnlyChoosesTheDefault() async throws {
        let live = try live()
        defer { close(live) }
        let stubs = Stubs()
        let session = session(stubs)
        live.rewrite.wholeClip = session
        await session.refreshQuote()
        live.rewrite.selectWholeClipMode(false)
        #expect(!session.wholeSelected && live.rewrite.wholeClipCard() == .wholeClip)
        live.rewrite.selectWholeClipMode(true)
        #expect(session.wholeSelected)
        let record = WholeClipRevoiceRecord(id: "wholeclip-1", clipId: "clip-main", segmentIds: ["s"], script: "x", consentRecordId: "r1",
                                            videoRetime: 1, lipsyncModel: WholeClipRevoice.Lipsync.lipsync2.rawValue, usd: 1, match: nil, createdAt: Date())
        live.editor.removeWholeClip(record)
        #expect(live.editor.wholeClipPicks["clip-main"] == nil, "Undo Whole Clip offers it again as the default")
    }

    /// whole-clip-card-hidden-after-pick: the patch pick is for the proposal it was made on. A new proposal for the clip in a
    /// later Rewrite starts from the default again (the whole clip, full card), never the compact row the earlier pick left.
    @Test func aNewProposalInALaterRewriteStartsFromTheWholeClipAgain() async throws {
        let live = try live()
        defer { close(live) }
        let stubs = Stubs()
        let first = session(stubs)
        live.rewrite.adopt(TranscriptProposal(clipID: "clip-main", title: "Rewrite clip 1", changes: []))
        live.rewrite.wholeClip = first
        first.proposalID = live.rewrite.proposalID
        await first.refreshQuote()
        live.rewrite.patchInstead()
        #expect(live.editor.wholeClipPicks["clip-main"] == WholeClipPick(whole: false, proposal: live.rewrite.proposalID))
        live.rewrite.close()
        // A later Rewrite on the same clip with a new reply.
        let later = RewriteSession(editor: live.editor, scope: .clip("clip-main"), envelope: nil, connector: nil)
        later.adopt(TranscriptProposal(clipID: "clip-main", title: "Rewrite clip 1", changes: []))
        let second = session(Stubs())
        second.proposalID = later.proposalID
        later.wholeClip = second
        await second.refreshQuote()
        #expect(later.proposalID != live.rewrite.proposalID)
        #expect(second.wholeSelected, "the earlier pick was for another proposal")
        later.selectWholeClipMode(false)
        #expect(later.wholeClipCard() == .wholeClip && !second.wholeSelected)
        later.close()
    }

    /// wholeclip-drops-unfit-changes: the whole clip's script says the changes the wording fit kept as recorded (they ran
    /// long for their slots, which is why the whole clip is offered); the user's own exclusions stay out.
    @Test func theScriptSaysTheChangesTheFitKeptAsRecorded() async throws {
        let live = try live()
        defer { close(live) }
        let rewrite = live.rewrite
        let kept = VoiceLabDiffHunk(kind: .voice, sourceWordIds: ["w5"], newTokens: ["launch", "proudly"], correctedTexts: [], absorbedItemIds: [],
                                    bridgeWordIds: [], sourceStartIndex: 3, sourceEndIndex: 4, anchorSeconds: nil)
        rewrite.receive([RewriteChange(hunk: kept)])
        rewrite.wordingFit.kept.insert(1)
        let whole = WholeClipRevoiceSession()
        rewrite.configureWholeClip(whole)
        let script = try #require(try whole.backend?.script())
        #expect(script.text.contains("launch proudly"), "\(script.text)")
        rewrite.wordingFit.kept.remove(1)
        #expect(try #require(try whole.backend?.script()).text.contains("ship"), "a change neither included nor kept keeps its words")
    }

    /// wholeclip-reword-pays-unapproved: an automatic run voices a shorter wording only when its fresh quote fits what is
    /// left of the run's budget (with the lip sync still to pay); over it, nothing more is voiced.
    @Test func anAutomaticRunVoicesAShorterWordingOnlyWithinItsBudget() async throws {
        for budget in [Decimal(string: "1.7")!, Decimal(string: "1.65")!] {
            let stubs = Stubs()
            stubs.voiceSeconds = [36, 31]
            stubs.reword = WholeClipScript.assemble(words: Array(Self.words.prefix(4)), cutWordIds: [], voiceHunks: [])!
            let session = session(stubs)
            await session.refreshQuote()
            session.start(automatic: true, budget: budget)
            await session.waitForRun()
            // 1.7 covers the first voice (0.06), the reworded one (0.06) and the lip sync (1.55); 1.65 doesn't.
            if budget == Decimal(string: "1.7")! {
                #expect(stubs.voices.count == 2 && session.phase == .used, "\(session.phase)")
            } else {
                #expect(stubs.voices.count == 1 && session.shorterWording != nil, "no second voice over the budget")
            }
        }
    }

    /// wholeclip-fit-raw-aggregate: a part whose laid-out take runs past its own window, while the whole voice is within the
    /// clip, is a Fit asking for a shorter wording, with the voice kept; never "matched", then a picture that can't follow.
    @Test func aPartRunningPastItsWindowAsksForAShorterWording() async throws {
        let stubs = Stubs()
        stubs.voiceSeconds = [31]
        stubs.overruns = [1.1]
        stubs.reword = nil
        let session = session(stubs)
        await session.refreshQuote()
        session.start()
        await session.waitForRun()
        #expect(stubs.rewords == [6], "≈ 7 ÷ 1.1 words: \(stubs.rewords)")
        #expect(stubs.pictures.isEmpty && stubs.lipsyncs.isEmpty, "known at Fit, before the picture")
        guard case .stopped(let line) = session.phase else { Issue.record("\(session.phase)"); return }
        #expect(line.hasPrefix("Part of the new voice runs longer than its place in the clip as edited"), "\(line)")
        #expect(session.failure?.step == .fit && session.voice != nil)
    }

    // MARK: Review fixes (package B)

    private static func usd(_ text: String) -> String { VoiceLabCostPresentation.format(Decimal(string: text)!) }

    /// Start Over's price is what its click charges: an edit that makes the clip cost more after the stop shows the old
    /// price until the card prices it again. A click at the old price prices the clip first, lets nothing go and pays
    /// nothing, and the button then carries the new price for its own click.
    @Test func startOverNeverChargesMoreThanTheClickedPrice() async throws {
        let live = try live()
        defer { close(live) }
        let stubs = Stubs()
        // More words cost more (the tables price the script's characters).
        stubs.quoteVoiceUSD = { $0.words > 7 ? Decimal(string: "0.5")! : Decimal(string: "0.06")! }
        stubs.lipsyncError = WholeClipRevoiceSession.LipsyncFailed(error: LipsyncError.http(503), local: false)
        let session = session(stubs)
        live.rewrite.wholeClip = session
        await session.refreshQuote()
        session.start()
        await session.waitForRun()
        #expect(session.failure?.step == .lipsync && stubs.voices.count == 1)
        // The edit brings back words: the clip's script is longer.
        let longer = WholeClipScript.assemble(words: Self.words + [TimedWord(id: "w7", text: "Really.", start: 7, end: 7.8)], cutWordIds: [], voiceHunks: [])!
        session.backend?.script = { longer }
        let shown = try #require(live.rewrite.wholeClipStoppedActions().first)
        #expect(shown.id == "wholeClipStartOver" && shown.title == "Start Over · " + Self.usd("1.61"), "\(shown.title)")
        #expect(session.needsRequote, "the card prices the clip as it is now")
        stubs.lipsyncError = nil
        await live.rewrite.startWholeClipOver(approved: Decimal(string: "1.61")!).value
        #expect(stubs.voices.count == 1 && stubs.discarded == 0 && session.isStopped && session.voice != nil, "nothing let go or paid")
        let repriced = try #require(live.rewrite.wholeClipStoppedActions().first)
        #expect(repriced.id == "wholeClipStartOver" && repriced.title == "Start Over · " + Self.usd("2.05") && repriced.priced, "\(repriced.title)")
        #expect(!session.needsRequote)
        // Its own click, at the price it shows, runs.
        await live.rewrite.startWholeClipOver(approved: Decimal(string: "2.05")!).value
        await session.waitForRun()
        #expect(stubs.discarded == 1 && stubs.voices == [Self.script.text, longer.text] && session.phase == .review, "\(session.phase)")
    }

    /// wholeclip-no-prepay-fit-check after Start Over: the voice let go stays in the spend, and the new script's first voice
    /// still gets the free check before paying. Parts already paid for a script keep it as it is.
    @Test func startOverChecksTheNewScriptBeforePayingItsVoice() async throws {
        let stubs = Stubs()
        stubs.lipsyncError = WholeClipRevoiceSession.LipsyncFailed(error: LipsyncError.http(503), local: false)
        let session = session(stubs)
        await session.refreshQuote()
        session.start()
        await session.waitForRun()
        let edited = WholeClipScript.assemble(words: Array(Self.words.prefix(6)), cutWordIds: [], voiceHunks: [])!
        let shorter = WholeClipScript.assemble(words: Array(Self.words.prefix(4)), cutWordIds: [], voiceHunks: [])!
        session.backend?.script = { edited }
        stubs.estimates = [edited.text: 31 * 1.3, shorter.text: 30]
        stubs.reword = shorter
        stubs.lipsyncError = nil
        let started = await session.startOver(approved: 10)
        #expect(started && session.spent == Decimal(string: "0.06") && session.heldVoiceSpent == 0, "the voice let go is counted, not held")
        stubs.order = []
        session.start()
        await session.waitForRun()
        #expect(stubs.order.prefix(2) == ["reword", "voice"] && stubs.voices.last == shorter.text, "\(stubs.order)")
        #expect(session.phase == .review)
        // Parts of this script already paid for: the check keeps the script, so they are kept.
        let partial = Stubs()
        partial.partlyVoiced = true
        partial.voiceSeconds = [36]
        partial.reword = shorter
        partial.estimates = [Self.script.text: 31 * 1.3]
        let other = self.session(partial)
        await other.refreshQuote()
        other.start()
        await other.waitForRun()
        #expect(partial.rewords == [6] && partial.order.first == "voice", "the Fit step's measured round, not the check before paying: \(partial.order)")
    }

    /// After Start Over the voice let go is no longer held: a stop of the new run that paid nothing offers a plain patch
    /// (it drops no paid voice), and an edit then is a Try Again, not Start Over.
    @Test func aVoiceLetGoIsNotNamedAsHeld() async throws {
        let live = try live()
        defer { close(live) }
        let stubs = Stubs()
        stubs.lipsyncError = WholeClipRevoiceSession.LipsyncFailed(error: LipsyncError.http(503), local: false)
        let session = session(stubs)
        live.rewrite.wholeClip = session
        await session.refreshQuote()
        session.start()
        await session.waitForRun()
        #expect(live.rewrite.wholeClipStoppedActions().last?.title == "Voice Only the Changed Phrases (drops the paid voice)")
        let edited = WholeClipScript.assemble(words: Array(Self.words.prefix(6)), cutWordIds: [], voiceHunks: [])!
        session.backend?.script = { edited }
        stubs.voiceError = VoiceLabError.network
        await live.rewrite.startWholeClipOver(approved: 10).value
        await session.waitForRun()
        #expect(session.failure?.step == .voice && session.heldVoiceSpent == 0 && session.spent == Decimal(string: "0.06"))
        #expect(live.rewrite.wholeClipStoppedActions().map(\.title).last == "Voice Only the Changed Phrases")
        let again = WholeClipScript.assemble(words: Array(Self.words.prefix(5)), cutWordIds: [], voiceHunks: [])!
        session.backend?.script = { again }
        #expect(!session.stoppedForInputs)
        #expect(live.rewrite.wholeClipStoppedActions().first?.id == "wholeClipRetry")
        stubs.voiceError = nil; stubs.lipsyncError = nil
        session.start()
        await session.waitForRun()
        #expect(session.phase == .review && stubs.voices == [Self.script.text, again.text], "\(session.phase)")
    }

    /// A voice that cost nothing (a journal's take adopted for free) whose plan went stale is let go with its plan
    /// (`checkWholeClipPlan`): Try Again makes a fresh one instead of meeting the same stale stop again.
    @Test func aFreeVoiceWhosePlanWasLetGoIsMadeAgainOnTryAgain() async throws {
        let live = try live()
        defer { close(live) }
        let stubs = Stubs()
        stubs.voiceUSD = 0
        stubs.staleUntilVoice = 1
        let session = session(stubs)
        live.rewrite.wholeClip = session
        await session.refreshQuote()
        session.start()
        await session.waitForRun()
        #expect(session.failure?.step == .fit && session.failure?.repeats == false && session.voice == nil, "\(session.phase)")
        #expect(live.rewrite.wholeClipStoppedActions().first?.id == "wholeClipRetry")
        session.start()
        await session.waitForRun()
        #expect(session.phase == .review && stubs.voices.count == 2, "\(session.phase)")
    }

    /// Without an AI to ask, a Fit stop offers no "Shorter Wording · free" that could only fail again; once one is
    /// connected it does.
    @Test func noAIMeansNoShorterWordingToAskFor() async throws {
        let live = try live()
        defer { close(live) }
        let stubs = Stubs()
        stubs.canReword = false
        stubs.voiceSeconds = [36]
        stubs.reword = nil
        let session = session(stubs)
        live.rewrite.wholeClip = session
        await session.refreshQuote()
        session.start()
        await session.waitForRun()
        #expect(session.failure?.step == .fit && session.failure?.rewordable == true && !session.canAskShorterWording)
        #expect(live.rewrite.wholeClipStoppedActions().map(\.id) == ["wholeClipPatch"])
        stubs.canReword = true
        #expect(session.canAskShorterWording && live.rewrite.wholeClipStoppedActions().contains { $0.id == "wholeClipShorter" })
    }

    /// A paid voice made with a voice no longer chosen says so, not "You edited Clip N".
    @Test func aVoiceSwitchIsNamedApartFromAnEdit() {
        typealias Session = WholeClipRevoiceSession
        let switched = Session.copy(Session.Stop.voiceInputsChanged(clip: 7, usd: Decimal(string: "0.06")!, voiceSwitched: true))
        #expect(switched.hasPrefix("You chose another voice after Clip 7's voice was made, so the paid voice (\(Self.usd("0.06"))) no longer matches."), "\(switched)")
        #expect(!switched.contains("You edited"))
        #expect(Session.copy(Session.Stop.voiceInputsChanged(clip: 7, usd: Decimal(string: "0.06")!)).hasPrefix("You edited Clip 7 after its voice was made"))
    }

    /// ✦ Claude does it all's seam (`needsYou`): a stop over money spent, a shorter wording waiting for its click or a lost
    /// submit answer is the user's, never the patch on top; a stop before anything was paid is not.
    @Test func stopsOverPaidWorkNeedTheUser() async throws {
        let paid = Stubs()
        paid.lipsyncError = WholeClipRevoiceSession.LipsyncFailed(error: LipsyncError.http(503), local: false)
        let lipsync = session(paid)
        await lipsync.refreshQuote()
        lipsync.start(automatic: true, budget: 10)
        await lipsync.waitForRun()
        #expect(lipsync.isStopped && lipsync.needsYou)
        let reword = Stubs()
        reword.voiceSeconds = [36, 31]
        reword.reword = WholeClipScript.assemble(words: Array(Self.words.prefix(4)), cutWordIds: [], voiceHunks: [])!
        let held = session(reword)
        await held.refreshQuote()
        held.start(automatic: true)
        await held.waitForRun()
        #expect(held.shorterWording != nil && held.failure?.step == .fit && held.needsYou, "no budget: the reword waits for the user")
        let unpaid = Stubs()
        unpaid.voiceError = VoiceLabError.network
        let none = session(unpaid)
        await none.refreshQuote()
        none.start(automatic: true, budget: 10)
        await none.waitForRun()
        #expect(none.isStopped && !none.needsYou)
    }
}

/// The user's MVP44 clip as the panel and the log showed it (shared/fixtures/voice-lab/whole-clip-fit-cases.json, numbers
/// only): the clip 0:31.4 as edited, its parts' windows 48.6 s of source.
enum WholeClipUserCase {
    private struct File: Decodable { struct Clip: Decodable { struct Shown: Decodable { let editedSeconds: Double; let sourceWindowSeconds: Double }; let shown: Shown }; let usersClip: Clip }
    private static let shown: File.Clip.Shown? = {
        guard let shared = try? SharedResources.locate(),
              let data = try? Data(contentsOf: shared.root.appendingPathComponent("fixtures/voice-lab/whole-clip-fit-cases.json")) else { return nil }
        return try? JSONDecoder().decode(File.self, from: data).usersClip.shown
    }()
    static var editedSeconds: Double { shown?.editedSeconds ?? .nan }
    static var sourceSeconds: Double { shown?.sourceWindowSeconds ?? .nan }
}

/// The Review's match line, as the card shows it.
enum WholeClipRevoiceCardMatch {
    @MainActor static func line(_ match: WholeClipRevoiceRecord.Match) -> String { WholeClipRevoiceCardLines.matchLine(match, voice: "siim") }
}
#endif
