#if DEBUG
import Foundation
import AppKit
import Testing
@testable import VoxClipCore
@testable import VoxClipMedia
@testable import VoxClip

private struct GenerationTestKeys: KeyProvider {
    func key(for provider: String) async throws -> String? { Issue.record("State tests must not ask for credentials"); return nil }
}

@Suite("Headless Rewrite generation", .serialized)
@MainActor struct RewriteGenerationTests {
    @Test func proposalErrorsNameTheConnectorAndRewrite() {
        #expect(RewriteSession.proposalError(.unauthorized, provider: "Example", model: "test").hasPrefix("Example rejected"))
        #expect(RewriteSession.proposalError(.refused(category: nil), provider: "Example", model: "test").contains("declined to rewrite"))
        #expect(RewriteSession.proposalError(.truncated, provider: "Example", model: "test").contains("rewrite was incomplete"))
    }
    private func session(current: @escaping @MainActor () -> Bool = { true }) -> RewriteGenerationSession {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = VoiceConsentStore(locations: DataLocations(environment: ["VOXCLIP_DATA_DIR": root.path]))
        let client = ElevenLabsVoiceLab(keys: GenerationTestKeys(), region: .default)
        return RewriteGenerationSession(run: VoiceLabTakeRun(client: client, store: store, speaker: .unavailable,
            storage: VoiceLabTakeStorage(projectId: UUID().uuidString.lowercased(), paidRoot: root.appendingPathComponent("VoiceLab"), scratchRoot: root.appendingPathComponent("scratch")), dispatchIfCurrent: { start in
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
        #expect(session.phase == .lengthChanged && session.bestID == take.id && session.selectedID == take.id)
        #expect(!session.readyToAccept && session.videoChoice == nil)
        #expect(session.select(take.id) && !session.readyToAccept)
        #expect(!session.chooseVideo(.source))
        #expect(!session.chooseVideo(.retimed) && !session.readyToAccept)
        #expect(!session.chooseVideo(.lipsync) && session.videoChoice == nil)
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
    @Test func pauseNotesHaveStableCrossPlatformSigns() {
        #expect(RewriteGenerationSession.pauseFitNote(0.4) == "pauses +0.4 s")
        #expect(RewriteGenerationSession.pauseFitNote(-0.4) == "pauses −0.4 s")
        #expect(RewriteGenerationSession.pauseFitNote(0) == "pauses +0.0 s")
    }
    @Test func completionAnnouncementsCountOnlyActualTakes() {
        #expect(RewriteGenerationSession.completionAnnouncement(count: 3, fittedTake: nil) == "Three takes ready.")
        #expect(RewriteGenerationSession.completionAnnouncement(count: 1, fittedTake: nil) == "One take ready.")
        #expect(RewriteGenerationSession.completionAnnouncement(count: 2, fittedTake: nil) == "Two takes ready.")
        #expect(RewriteGenerationSession.completionAnnouncement(count: 1, fittedTake: 1) == "Take 1 fits.")
    }
    @Test func completionAnnouncementsCountEveryFailedTake() {
        for failures in [1, 2] {
            for fits in [false, true] {
                let session = session()
                session.review(VoiceLabTakeRunResult(rows: [row(index: 0, failure: true),
                    row(index: 1, residual: 0.5, failure: failures == 2, score: 0.1),
                    row(index: 2, residual: fits ? 0 : 0.5, score: 0.9)], end: .completed))
                let count = failures == 1 ? "one" : "two"
                let expected = fits ? "Take 3 fits. \(count.capitalized) failed the speech check." : "Three takes ready, \(count) failed the speech check."
                #expect(session.announcement == expected)
            }
        }
    }
    @Test func remoteLocalServerNeverClaimsNothingLeavesTheMac() {
        for url in ["http://localhost:11434", "http://127.0.0.1:8080", "http://[::1]:8080"] {
            #expect(RewriteSession.localSendLine(count: 12, baseURL: url) == "Runs on this Mac. Nothing leaves it.")
        }
        #expect(RewriteSession.localSendLine(count: 12, baseURL: "http://192.168.1.2:8080") == "Sends these 12 words to 192.168.1.2.")
        #expect(RewriteSession.localSendLine(count: 12, baseURL: "https://inference.example.test") == "Sends these 12 words to inference.example.test.")
        #expect(!RewriteSession.localSendLine(count: 12, baseURL: "invalid").contains("Nothing leaves"))
    }
    @Test func unavailableCleaningHasAnExplicitReasonAndSafeAlternative() {
        let copy = RewriteSession.refusal(VoiceLabGeometryError.roomToneUnavailable)
        #expect(copy.contains("Clean audio is not available in this build."))
        #expect(copy.contains("Re-record this sentence instead."))
    }
    @Test func theBestTakeAutoplaysOnlyOnceAndNeverAfterAnotherSelection() {
        let session = session(); let first = row(index: 0); let second = row(index: 1, score: 0.9)
        session.review(.init(rows: [first, second], end: .completed))
        #expect(session.takeToAutoplay()?.id == first.id)
        #expect(session.takeToAutoplay() == nil)
        #expect(session.select(second.id))
        #expect(session.takeToAutoplay() == nil)
    }
    @Test func layoutAuditIgnoresEmptyScrollerFramesButNotVisibleOverflow() {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        let element = NSView(frame: NSRect(x: -1, y: 10, width: 17, height: 0))
        element.setAccessibilityElement(true)
        host.addSubview(element)
        #expect(DebugRightColumn.accessibilityOverflow(host).isEmpty)
        element.frame.size.height = 17
        #expect(!DebugRightColumn.accessibilityOverflow(host).isEmpty)
    }
    @Test func layoutAuditIntersectsEveryNestedScrollViewport() {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        let outer = NSScrollView(frame: host.bounds)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 900))
        outer.clipsToBounds = true; outer.contentView.clipsToBounds = true
        outer.documentView = content; host.addSubview(outer)
        let inner = NSScrollView(frame: NSRect(x: 0, y: 600, width: 300, height: 100))
        inner.clipsToBounds = true; inner.contentView.clipsToBounds = true
        inner.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        content.addSubview(inner)
        #expect(DebugRightColumn.viewOverflow(host).isEmpty)
        outer.clipsToBounds = false; outer.contentView.clipsToBounds = false
        #expect(!DebugRightColumn.viewOverflow(host).isEmpty)
    }
}
#endif
