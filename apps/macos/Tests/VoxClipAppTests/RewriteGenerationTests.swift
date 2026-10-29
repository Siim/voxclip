#if DEBUG
import Foundation
import Testing
@testable import VoxClipCore
@testable import VoxClipMedia
@testable import VoxClip

private struct GenerationTestKeys: KeyProvider {
    func key(for provider: String) async throws -> String? { Issue.record("State tests must not ask for credentials"); return nil }
}

@Suite("Headless Rewrite generation", .serialized)
@MainActor struct RewriteGenerationTests {
    private func session(current: @escaping @MainActor () -> Bool = { true }) -> RewriteGenerationSession {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = VoiceConsentStore(locations: DataLocations(environment: ["VOXCLIP_DATA_DIR": root.path]))
        let client = ElevenLabsVoiceLab(keys: GenerationTestKeys(), region: .default)
        return RewriteGenerationSession(run: VoiceLabTakeRun(client: client, store: store, speaker: .unavailable, dispatchIfCurrent: { start in
            try await MainActor.run {
                guard current() else { throw VoiceLabError.consentRequired }
                try start()
            }
        }, inputsAreCurrent: { true }), inputsAreCurrent: current)
    }
    private func row(index: Int, residual: Double = 0, failure: Bool = false, score: Double = 1) -> VoiceLabTakeRow {
        let plan = VoiceLabFitPlan(edits: [], incoming: .init(padFrames: 0, borrowedSamples: 0), outgoing: .init(padFrames: 0, borrowedSamples: 0),
            trimStartFrame: 0, trimEndFrame: 24_000, windowStart: 1, windowEnd: 2, windowStartSample: 24_000, windowEndSample: 48_000,
            outputFrames: 24_000, words: [VoiceLabWord(text: "Hello", start: 0.1, end: 0.9, synthetic: true)])
        let fit: VoiceLabFitResult = residual == 0 ? .exact(plan) : .changedDuration(plan, naturalOut: 1 + residual, residualSeconds: residual)
        let audio = VoiceLabTakeAudio(sampleRate: 24_000, trimmed: [0.1], mixed: [0.1], patchRange: 0..<1, seams: [], gainDb: 0, roomTone: nil, fit: fit)
        let qa = VoiceLabTakeQAResult(values: VoiceLabQA(transcriptMatch: 1, lufsJumpLu: 0, peakDbfs: -20, speakerScore: failure ? 0.1 : 0.8), failures: failure ? [.speaker] : [])
        return VoiceLabTakeRow(id: UUID(), index: index, seed: UInt32(index), audio: audio, qa: qa, score: score, failure: failure ? .qa([.speaker]) : nil)
    }
    @Test func exactBestIsPreselectedButRejectedRowsNeverAre() {
        let session = session()
        let rejected = row(index: 0, failure: true, score: 1)
        let best = row(index: 1, score: 0.9)
        session.review(VoiceLabTakeRunResult(rows: [rejected, best], end: .earlyStop))
        #expect(session.bestID == best.id && session.selectedID == best.id && session.readyToAccept)
        #expect(!session.select(rejected.id))
        session.invalidate()
        #expect(session.rows.isEmpty && !session.readyToAccept && session.quote == nil)
    }
    @Test func changedLengthRequiresExplicitTakeAndVideoChoices() {
        let session = session(); let take = row(index: 0, residual: 0.5)
        session.review(VoiceLabTakeRunResult(rows: [take], end: .completed))
        #expect(session.phase == .lengthChanged && session.bestID == take.id && session.selectedID == nil)
        #expect(!session.readyToAccept && !session.chooseVideo(.retimed))
        #expect(session.select(take.id) && !session.readyToAccept)
        #expect(!session.chooseVideo(.source))
        #expect(session.chooseVideo(.retimed) && session.readyToAccept)
        session.cancel()
        #expect(!session.readyToAccept && !session.select(take.id))
    }
    @Test func nonePassedFatalAndStaleStatesCannotBeAccepted() {
        let session = session()
        session.review(VoiceLabTakeRunResult(rows: [row(index: 0, failure: true)], end: .completed))
        #expect(session.phase == .nonePassed && session.selectedID == nil && !session.readyToAccept)
        let passing = row(index: 1)
        session.review(VoiceLabTakeRunResult(rows: [passing], end: .fatal))
        #expect(session.phase == .failed && !session.select(passing.id) && !session.readyToAccept)
        let stale = self.session(current: { false })
        stale.review(VoiceLabTakeRunResult(rows: [passing], end: .completed))
        #expect(!stale.readyToAccept)
    }
}
#endif
