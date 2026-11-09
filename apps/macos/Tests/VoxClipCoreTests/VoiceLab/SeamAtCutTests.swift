import Foundation
import Testing
@testable import VoxClipCore

/// A seam at a cut (voice-lab §8.4 step 5, 2026-11-09). The user's heavily edited clip (MVP48, about 31 s kept of a 48.6 s
/// span) stopped "Voice Only the Changed Phrases" at `placement.geometry.seamFadeCrossesCut` after Claude's rewrite. Two
/// phrase starts sit right against a cut there, and both incoming hard seams were refused with `needed: 288, available: 0`:
/// - the phrase after a three-word cut (w13–w15) whose gap to the phrase is 0.110 s, under `SEAM_MIN_GAP`, so the seam is
///   hard at 8.240 s. Once the phrase's words are dropped the cut's reach takes the whole gap, leaving no kept source;
/// - the phrase after a one-word cut (w19) that touches it: the seam is hard at its first word's start, 11.135 s.
/// Both windows already started where the cut ends. Prepare renders such a seam by fading from the output piece before the
/// cut, which the cut join plays anyway; only `place` asked for kept source contiguous with the seam. The take below is
/// that clip's first 24 items as anonymised numbers (times only, the same cuts and pause settings) with a synthetic envelope.
@Suite(.offlineFixtures) struct SeamAtCutTests {
    static let times: [(Double, Double)] = [
        (0, 0.34500000000000003), (0.34500000000000003, 0.595), (0.595, 1.045), (1.045, 1.625), (1.625, 2.32), (2.93, 3.9),
        (4.03, 4.425), (4.425, 5.015), (5.015, 5.11), (5.12, 5.195), (5.195, 5.54), (5.58, 6), (6.6000000000000005, 6.7250000000000005),
        (6.7250000000000005, 7.23), (7.23, 8.16), (8.27, 8.69), (8.75, 9.155), (9.155, 9.83), (10.47, 11.135), (11.135, 11.335),
        (11.335, 11.51), (11.540000000000001, 11.675), (11.675, 12.27), (12.81, 13.11),
    ]
    static let scope = VoiceLabOutputScope.clip("clip-1")

    static func take() throws -> (project: Project, envelope: AudioEnvelope) {
        var project = try JSONProjectStore.decode(FixtureLoader.data("fixtures/voice-lab/passage-render-v3.voxclip"))
        project.voiceLab.segments = []; project.voiceLab.assets = []
        let words = times.enumerated().map { TimedWord(id: "w\($0.offset + 1)", text: "x", start: $0.element.0, end: $0.element.1) }
        project.transcript?.words = words
        project.media.source.durationSeconds = 14
        project.media.source.audio?.sampleRate = 48_000
        project.edits.cutWordIds = ["w13", "w14", "w15", "w19"]
        project.edits.cutPauseIds = []
        project.edits.pauseThresholdSeconds = 0.8
        project.edits.pauseKeepSeconds = 0.15
        project.edits.clips = [ClipRange(id: "clip-1", startWordId: "w5", endWordId: "w24")]
        project.edits.activeClipId = "clip-1"
        var levels = [Float](repeating: 0.0005, count: 1_400)
        for word in words { for frame in Int(word.start * 100)..<min(levels.count, Int(word.end * 100)) { levels[frame] = 0.1 } }
        return (project, AudioEnvelope(sampleRate: 48_000, levels: levels))
    }

    static func hunk(_ ids: [String]) -> VoiceLabDiffHunk {
        VoiceLabDiffHunk(kind: .voice, sourceWordIds: ids, newTokens: ["new"], correctedTexts: [], absorbedItemIds: [],
                         bridgeWordIds: [], sourceStartIndex: 0, sourceEndIndex: 0, anchorSeconds: nil)
    }

    /// Before the rule: `seamFadeCrossesCut(incoming: true, needed: 288, available: 0)` for both.
    @Test(arguments: [("w16", "w18", Int64(395_520)), ("w20", "w23", Int64(534_480))])
    func phraseRightAfterACutPlaces(_ first: String, _ last: String, _ seam: Int64) throws {
        let (project, envelope) = try Self.take()
        let window = try VoiceLabWindowPlanner.place(project: project, scope: Self.scope, envelope: envelope,
                                                     firstWordId: first, lastWordId: last)
        // The hard seam stays where it was, at the cut: the window absorbs no cut word, so the user's cut timing holds.
        #expect(window.leftSeam == VoiceLabSeamPlacement(kind: .hard, time: Double(seam) / 48_000, sample: seam, fadeSamples: 576))
        #expect(window.firstWordId == first && window.leftBridgeWordIds.isEmpty)
        // It renders as the take plan checks it, in the clip and in the full take, where the segment also plays.
        for scope in [Self.scope, .full] { try VoiceLabRenderContract.validatePlacement(project, scope: scope, window: window) }
    }

    /// The whole review places: the phrases at the cuts and one elsewhere, each its own window.
    @Test func everyPhraseOfTheReviewPlaces() throws {
        let (project, envelope) = try Self.take()
        let hunks = [Self.hunk(["w7", "w8"]), Self.hunk(["w16", "w17", "w18"]), Self.hunk(["w20", "w21", "w22", "w23"])]
        let results = VoiceLabWindowPlanner.placeAll(project: project, scope: Self.scope, envelope: envelope, hunks: hunks)
        var windows: [VoiceLabWindow] = []
        for result in results {
            guard case .placed(let indices, _, let window) = result else { Issue.record("refused: \(result)"); continue }
            #expect(indices.count == 1)
            windows.append(window)
        }
        #expect(windows.count == 3)
        for scope in [Self.scope, .full] { try VoiceLabRenderContract.validatePlacement(project, scope: scope, windows: windows) }
    }
}
