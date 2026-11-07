#if DEBUG
import Foundation
import Testing
@testable import VoxClipCore
@testable import VoxClip

/// The whole-clip revoice's run (ADR-R46) on stubs: Script, Voice, Fit and Lip sync in order, the reword round, Cancel and
/// failure keeping the clip, Try Again and the sync-3 upgrade never paying a step twice, Review's Use and Undo.
@Suite(.serialized) @MainActor struct WholeClipRevoiceSessionTests {
    @MainActor final class Stubs {
        var voices: [String] = []
        var lipsyncs: [WholeClipRevoice.Lipsync] = []
        var rewords: [(Bool, Int)] = []
        var used = 0, undone = 0, discarded = 0
        var voiceSeconds: [Double] = [30.6]
        var video = 31.0
        var failLipsync = false
        var holdLipsync = false
        var held: CheckedContinuation<Void, Never>?
        var reword: WholeClipScript? = nil
    }

    private static let words: [TimedWord] = ["So", "we", "drove", "north.", "It", "was", "cold."].enumerated().map {
        TimedWord(id: "w\($0.offset)", text: $0.element, start: Double($0.offset), end: Double($0.offset) + 0.8)
    }

    private func session(_ stubs: Stubs) -> WholeClipRevoiceSession {
        let session = WholeClipRevoiceSession()
        let script = WholeClipScript.assemble(words: Self.words, cutWordIds: [], voiceHunks: [])!
        session.backend = .init(script: { script }, quote: { script, _ in
            .init(clipNumber: 7, clipSeconds: 31, spokenWords: script.words, reason: .manyWords(revoiced: 4, spoken: 7), patchUSD: Decimal(string: "0.1"),
                  phrases: 2, voiceUSD: Decimal(string: "0.06"), lipsyncUSD: Decimal(string: "1.55"), voiceName: "siim · DJI 0011", voiceNote: "matched to this video")
        }, voice: { script, progress in
            progress("part 1 of 1")
            stubs.voices.append(script.text)
            let seconds = stubs.voiceSeconds.count > 1 ? stubs.voiceSeconds.removeFirst() : stubs.voiceSeconds[0]
            return .init(key: .init(script: script.text, recordId: "r1", model: "eleven_v4"), seconds: seconds, parts: 3, usd: Decimal(string: "0.06")!)
        }, videoSeconds: { stubs.video }, reword: { _, shorter, target, _, _ in
            stubs.rewords.append((shorter, target))
            return stubs.reword
        }, lipsync: { _, factor, model, progress in
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
        }, undo: { _ in stubs.undone += 1 }, discard: { stubs.discarded += 1 })
        return session
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

    @Test func outsideEightPercentAMeasuredWordingIsAskedForThenFits() async {
        let stubs = Stubs()
        stubs.voiceSeconds = [36, 31.5]
        let shorter = WholeClipScript.assemble(words: Array(Self.words.prefix(4)), cutWordIds: [], voiceHunks: [])!
        stubs.reword = shorter
        let session = session(stubs)
        session.start()
        await session.waitForRun()
        #expect(stubs.rewords.count == 1 && stubs.rewords[0].0 == true && stubs.rewords[0].1 == 6)
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
        #expect(line.hasPrefix("The new voice runs 0:40 for 0:31 of video, more than one even retime can match."))
        #expect(stubs.lipsyncs.isEmpty && stubs.used == 0, "no lip sync and nothing in the clip")
        #expect(session.isStopped)
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

    @Test func anAutomaticRunPutsTheResultInWithNoClick() async {
        let stubs = Stubs()
        let session = session(stubs)
        session.start(automatic: true)
        await session.waitForRun()
        #expect(session.phase == .used && stubs.used == 1)
    }
}

/// The Review's match line, as the card shows it.
enum WholeClipRevoiceCardMatch {
    @MainActor static func line(_ match: WholeClipRevoiceRecord.Match) -> String { WholeClipRevoiceCardLines.matchLine(match, voice: "siim") }
}
#endif
