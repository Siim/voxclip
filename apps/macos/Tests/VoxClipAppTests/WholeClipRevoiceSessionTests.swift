#if DEBUG
import Foundation
import Testing
@testable import VoxClipCore
@testable import VoxClip

/// The whole-clip revoice's run (ADR-R46) on stubs: Script, Voice, Fit and Lip sync in order, the fit on the clip as
/// edited, the shorter-only reword round and its check before paying, Cancel and failure keeping the clip, Try Again and the
/// sync-3 upgrade never paying a step twice, Review's Use and Undo.
@Suite(.serialized) @MainActor struct WholeClipRevoiceSessionTests {
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
    }

    private static let words: [TimedWord] = ["So", "we", "drove", "north.", "It", "was", "cold."].enumerated().map {
        TimedWord(id: "w\($0.offset)", text: $0.element, start: Double($0.offset), end: Double($0.offset) + 0.8)
    }

    private func session(_ stubs: Stubs) -> WholeClipRevoiceSession {
        let session = WholeClipRevoiceSession()
        session.backend = Self.backend(stubs)
        return session
    }

    /// Stub steps that record what they are asked and spend the tables' prices (Claude mode's tests use them too).
    static func backend(_ stubs: Stubs) -> WholeClipRevoiceSession.Backend {
        let script = WholeClipScript.assemble(words: Self.words, cutWordIds: [], voiceHunks: [])!
        return .init(script: { script }, quote: { script, _ in
            .init(clipNumber: 7, clipSeconds: 31, spokenWords: script.words, reason: .manyWords(revoiced: 4, spoken: 7), patchUSD: Decimal(string: "0.1"),
                  phrases: 2, voiceUSD: Decimal(string: "0.06"), lipsyncUSD: Decimal(string: "1.55"), voiceName: "siim · DJI 0011", voiceNote: "matched to this video")
        }, voice: { script, progress in
            progress("part 1 of 1")
            if let error = stubs.voiceError { throw error }
            stubs.voices.append(script.text)
            let seconds = stubs.voiceSeconds.count > 1 ? stubs.voiceSeconds.removeFirst() : stubs.voiceSeconds[0]
            return .init(key: .init(script: script.text, recordId: "r1", model: "eleven_v4"), seconds: seconds, parts: 3, usd: Decimal(string: "0.06")!)
        }, videoSeconds: { stubs.video }, reword: { _, target, _, _ in
            stubs.rewords.append(target)
            return stubs.reword
        }, estimate: { script in stubs.estimates[script.text] }, lipsync: { _, factor, model, progress in
            stubs.lipsyncs.append(model)
            progress(0.5)
            if stubs.holdLipsync { await withCheckedContinuation { stubs.held = $0 } }
            try Task.checkCancellation()
            if stubs.failLipsync { throw LipsyncError.http(503) }
            return .init(model: model, usd: model == .sync3 ? Decimal(string: "4.13")! : Decimal(string: "1.55")!, factor: factor)
        }, lipsyncPrice: { model in model == .sync3 ? Decimal(string: "4.13") : Decimal(string: "1.55") },
           match: { _ in .init(take: 0.81, anchorBaseline: 0.54, realSpeech: 0.86) }, play: { _ in },
           use: { voice, synced, match in
            stubs.used += 1
            return WholeClipRevoiceRecord(id: "wholeclip-1", clipId: "clip-7", segmentIds: ["s"], script: voice.key.script, consentRecordId: "r1",
                                          videoRetime: synced.factor, lipsyncModel: synced.model.rawValue, usd: 1.61, match: match, createdAt: Date())
        }, undo: { _ in stubs.undone += 1 }, discard: { stubs.discarded += 1 }, report: { stubs.reports.append($0) })
    }

    @Test func aRunGoesScriptVoiceFitLipSyncThenReviewAndUse() async {
        let stubs = Stubs()
        let session = session(stubs)
        await session.refreshQuote()
        #expect(session.phase == .choose && session.quote?.wholeUSD == Decimal(string: "1.61"))
        session.start()
        #expect(session.phase == .running)
        await session.waitForRun()
        #expect(session.phase == .review)
        #expect(session.steps[.script] == .done("Script · 7 words, your edits applied"))
        #expect(session.steps[.voice] == .done("Voice · 0:30.6 in siim · DJI 0011 · 3 parts, one take"))
        #expect(session.steps[.fit] == .done("Fit · 0:30.6 for 0:31 of video, video matched (−1.3%)"))
        #expect(stubs.lipsyncs == [.lipsync2], "lipsync-2 by default")
        #expect(session.spent == Decimal(string: "1.61"))
        #expect(session.upgradeUSD == Decimal(string: "4.13"))
        #expect(WholeClipRevoiceCardMatch.line(session.match!) == "Sounds like you: 0.81 · siim's earlier takes 0.54 · your real speech 0.86")
        #expect(stubs.used == 0, "nothing goes into the clip before Use")
        await session.use()
        #expect(session.phase == .used && stubs.used == 1 && session.record?.lipsyncModel == WholeClipRevoice.Lipsync.lipsync2.rawValue)
        session.undoUse()
        #expect(stubs.undone == 1 && session.phase == .review)
    }

    @Test func aVoiceLongerThanTheEditedClipAsksForAShorterWordingThenFits() async {
        let stubs = Stubs()
        stubs.voiceSeconds = [36, 31.5]
        let shorter = WholeClipScript.assemble(words: Array(Self.words.prefix(4)), cutWordIds: [], voiceHunks: [])!
        stubs.reword = shorter
        let session = session(stubs)
        session.start()
        await session.waitForRun()
        #expect(stubs.rewords == [6], "a shorter wording of about 7 ÷ (36 ÷ 31) words")
        #expect(stubs.voices.count == 2 && stubs.voices.last == shorter.text, "the new wording is voiced")
        #expect(session.phase == .review)
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
        #expect(session.phase == .review && stubs.lipsyncs == [.lipsync2], "it reaches the lip sync: \(session.phase)")
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
        #expect(line.contains("trying again pays only what's left"))
        #expect(session.failure?.step == .fit && session.repeatsFit)
        #expect(stubs.lipsyncs.isEmpty && stubs.used == 0)
        // A wording estimated to fit is voiced.
        stubs.estimates[reworded.text] = 8.6
        stubs.voiceSeconds = [36, 31]
        let second = self.session(stubs)
        second.start()
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
        #expect(stubs.lipsyncs == [.lipsync2, .lipsync2])
    }

    @Test func aFailedLipSyncKeepsTheClipAndTryAgainPaysOnlyTheLipSync() async {
        let stubs = Stubs()
        stubs.failLipsync = true
        let session = session(stubs)
        session.start()
        await session.waitForRun()
        guard case .stopped(let line) = session.phase else { Issue.record("not stopped"); return }
        #expect(line.contains("fal.ai returned HTTP 503.") && line.contains("trying again pays only what's left"))
        #expect(session.steps[.lipsync] == .failed("fal.ai returned HTTP 503."))
        stubs.failLipsync = false
        session.start()
        await session.waitForRun()
        #expect(session.phase == .review && stubs.voices.count == 1 && stubs.lipsyncs.count == 2)
        #expect(session.spent == Decimal(string: "1.61"))
    }

    @Test func theSync3UpgradeReRunsOnlyTheLipSync() async {
        let stubs = Stubs()
        let session = session(stubs)
        session.start()
        await session.waitForRun()
        session.upgrade()
        await session.waitForRun()
        #expect(session.phase == .review)
        #expect(stubs.voices.count == 1 && stubs.lipsyncs == [.lipsync2, .sync3])
        #expect(session.synced?.model == .sync3 && session.upgradeUSD == nil)
        await session.use()
        #expect(session.record?.lipsyncModel == WholeClipRevoice.Lipsync.sync3.rawValue)
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
        #expect(actions.map(\.id) == ["wholeClipPatch", "wholeClipRetry"], "\(actions.map(\.id))")
        #expect(stubs.voices.count == 1, "no second voice")
        // Once the clip's script changes, Try Again leads again.
        let changed = WholeClipScript.assemble(words: Array(Self.words.prefix(4)), cutWordIds: [], voiceHunks: [])!
        session.backend?.script = { changed }
        #expect(rewrite.wholeClipStoppedActions().map(\.id) == ["wholeClipRetry", "wholeClipPatch"])
    }

    @Test func anAutomaticRunPutsTheResultInWithNoClick() async {
        let stubs = Stubs()
        let session = session(stubs)
        session.start(automatic: true)
        await session.waitForRun()
        #expect(session.phase == .used && stubs.used == 1)
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
