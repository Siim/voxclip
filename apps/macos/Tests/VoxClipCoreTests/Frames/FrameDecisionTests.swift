import Foundation
import Testing
@testable import VoxClipCore

/// ADR-R48: the frame decisions on fabricated observations.
@Suite("Frame decisions")
struct FrameDecisionTests {
    // MARK: Eye aspect ratio

    @Test func eyeAspectRatioIsContourHeightOverWidth() throws {
        let points: [(x: Double, y: Double)] = [(0, 5), (10, 4), (20, 5), (30, 6), (40, 5), (30, 12), (20, 13), (10, 12)]
        #expect(EyeAspect.ratio(points) == 9.0 / 40.0)
        #expect(EyeAspect.ratio([(0, 0), (1, 1)]) == nil)
        #expect(EyeAspect.ratio([(5, 0), (5, 3), (5, 6)]) == nil)
    }

    @Test func eyesAreOpenAtTheThresholdAndClosedJustBelowIt() {
        let threshold = EyeAspect.closedBelow
        #expect(threshold == 0.20)
        #expect(EyeAspect.state(left: threshold, right: threshold) == .open)
        #expect(EyeAspect.state(left: threshold - 0.001, right: threshold - 0.001) == .closed)
        // The mean decides: one eye at 0.17 and one at 0.24 is open (0.205).
        #expect(EyeAspect.state(left: 0.17, right: 0.24) == .open)
        #expect(EyeAspect.state(left: 0.17, right: 0.22) == .closed)
        #expect(EyeAspect.state(left: nil, right: nil) == .unknown)
        #expect(FrameFace(rect: Self.centred, leftEyeAspect: 0.19, rightEyeAspect: 0.19).eyes == .closed)
    }

    @Test func facingTheCameraComesFromYawAndPitch() {
        #expect(FrameFace.yawLimit == 0.35 && FrameFace.pitchLimit == 0.35)
        #expect(FrameFace(rect: Self.centred, yaw: 0, pitch: 0.1).facesCamera(pitchBaseline: 0) == true)
        #expect(FrameFace(rect: Self.centred, yaw: 0.79).facesCamera(pitchBaseline: nil) == false)
        #expect(FrameFace(rect: Self.centred).facesCamera(pitchBaseline: 0.2) == nil)
        // Yaw is continuous now (revision 3): a head turned 0.3 rad faces, 0.4 rad does not, either way.
        #expect(FrameFace(rect: Self.centred, yaw: 0.3, pitch: 0.15).facesCamera(pitchBaseline: 0.15) == true)
        #expect(FrameFace(rect: Self.centred, yaw: -0.4, pitch: 0.15).facesCamera(pitchBaseline: 0.15) == false)
    }

    /// Pitch is judged against the recording's typical pitch, so a camera set below or above the eyes never counts as
    /// looking away; a head tilted further than the limit from it does (ADR-R48, 2026-11-08).
    @Test func pitchIsJudgedAgainstTheRecordingsCameraHeight() {
        // A constant camera-height pitch of 0.45 faces against its own baseline; an absolute rule would call it away.
        let level = FrameFace(rect: Self.centred, yaw: 0, pitch: 0.45)
        #expect(level.facesCamera(pitchBaseline: 0.45) == true)
        #expect(level.facesCamera(pitchBaseline: nil) == false, "without a baseline pitch is judged from 0")
        // More than the limit from the baseline, either way, does not face.
        #expect(FrameFace(rect: Self.centred, yaw: 0, pitch: 0.85).facesCamera(pitchBaseline: 0.45) == false)
        #expect(FrameFace(rect: Self.centred, yaw: 0, pitch: 0.05).facesCamera(pitchBaseline: 0.45) == false)
        #expect(FrameFace(rect: Self.centred, yaw: 0, pitch: 0.75).facesCamera(pitchBaseline: 0.45) == true)
        // Yaw over the limit does not face, whatever the pitch.
        #expect(FrameFace(rect: Self.centred, yaw: 0.5, pitch: 0.45).facesCamera(pitchBaseline: 0.45) == false)
    }

    @Test func thePitchBaselineIsTheMedianPitchOfTheFaces() {
        func seen(_ pitch: Double?) -> FrameObservation {
            FrameObservation(time: 0, faceCount: 1, face: FrameFace(rect: Self.centred, yaw: 0, pitch: pitch))
        }
        #expect(FrameFace.pitchBaseline([seen(0.1), seen(0.5), seen(0.2)]) == 0.2)
        #expect(FrameFace.pitchBaseline([seen(0.1), seen(0.3), FrameObservation(time: 1), seen(nil)]) == 0.2)
        #expect(FrameFace.pitchBaseline([seen(nil), FrameObservation(time: 1)]) == nil)
        let analysis = FrameAnalysis(contentKey: "k", sentences: [seen(0.1)], opening: [seen(0.3), seen(0.4)], timings: FrameAnalysisTimings())
        #expect(analysis.pitchBaseline == 0.3)
    }

    // MARK: Opening frame

    @Test func openingShiftStaysInTheSilenceAndNeverCrossesAWord() throws {
        // "Before." ends at 9.6; the clip's first word starts at 10.0. Clear looks at 9.4 and 9.5 lie inside "Before."
        let clip = try #require(Self.clip(previousEnd: 9.6, start: 10.0))
        var scan = Self.scan(from: 9.4, through: 10.6) { time in time < 9.6 || abs(time - 9.8) < 1e-6 }
        let choice = try #require(OpeningFrame.choose(clip, scan: scan, pitchBaseline: nil))
        #expect(abs(choice.shift - -0.2) < 1e-9)
        #expect(abs(choice.time - 9.8) < 1e-9)
        #expect(choice.time >= clip.leadInFloor && choice.time <= clip.start)
        // Only frames after the start, or inside the earlier word, are clear: the start stays.
        scan = Self.scan(from: 9.4, through: 10.6) { time in time < 9.6 || time > 10.05 }
        #expect(OpeningFrame.choose(clip, scan: scan, pitchBaseline: nil) == nil)
    }

    @Test func openingKeepsAClearStartAndLooksNoFurtherBackThanTheScan() throws {
        let clip = try #require(Self.clip(previousEnd: 7.0, start: 10.0))
        #expect(OpeningFrame.choose(clip, scan: Self.scan(from: 9.4, through: 10.6) { _ in true }, pitchBaseline: nil) == OpeningFrameChoice(shift: 0, time: 10.0))
        // A clear look 1 s before the start is outside the ±0.6 s scan, even in silence.
        #expect(OpeningFrame.choose(clip, scan: [Self.frame(9.0, clear: true), Self.frame(10.0, clear: false)], pitchBaseline: nil) == nil)
        let earliest = try #require(OpeningFrame.choose(clip, scan: Self.scan(from: 9.4, through: 10.6) { $0 < 9.95 }, pitchBaseline: nil))
        #expect(abs(earliest.time - 9.4) < 1e-9)
    }

    /// Dim footage scores 0.30–0.44 throughout: an open-eyed start moves only for a clearly better frame, and a shut-eyed
    /// one moves to an open look below the absolute floor (lead evaluation 2026-11-08).
    @Test func openingMovesForAFaultNotForASlightlyBetterDimFrame() throws {
        let clip = try #require(Self.clip(previousEnd: 7.0, start: 10.0))
        func look(_ time: Double, quality: Double, eyes: Double = 0.3, yaw: Double = 0) -> FrameObservation {
            FrameObservation(time: time, faceCount: 1, face: FrameFace(rect: Self.centred, captureQuality: quality,
                                                                        leftEyeAspect: eyes, rightEyeAspect: eyes, yaw: yaw, pitch: 0))
        }
        // The evaluation's false positives: open eyes at 0.386 and 0.385, an earlier frame at 0.438 and 0.416. The start stays.
        #expect(OpeningFrame.choose(clip, scan: [look(9.6, quality: 0.438), look(10.0, quality: 0.386)], pitchBaseline: nil) == nil)
        #expect(OpeningFrame.choose(clip, scan: [look(9.7, quality: 0.416), look(10.0, quality: 0.385)], pitchBaseline: nil) == nil)
        // Clearly better (at least `qualityMargin` above, and good): it moves.
        let sharper = try #require(OpeningFrame.choose(clip, scan: [look(9.6, quality: 0.55), look(10.0, quality: 0.3)], pitchBaseline: nil))
        #expect(abs(sharper.time - 9.6) < 1e-9)
        // Shut eyes at the start move to an open look even on dim footage (0.3 is above the floor less the margin)...
        let blink = try #require(OpeningFrame.choose(clip, scan: [look(9.6, quality: 0.3), look(10.0, quality: 0.36, eyes: 0.1)], pitchBaseline: nil))
        #expect(abs(blink.time - 9.6) < 1e-9)
        // ...and so does a face turned away, but never to a frame too poor to use.
        let turned = try #require(OpeningFrame.choose(clip, scan: [look(9.5, quality: 0.33), look(10.0, quality: 0.5, yaw: 0.8)], pitchBaseline: nil))
        #expect(abs(turned.time - 9.5) < 1e-9)
        #expect(OpeningFrame.choose(clip, scan: [look(9.6, quality: 0.2), look(10.0, quality: 0.36, eyes: 0.1)], pitchBaseline: nil) == nil)
    }

    /// Footage shot from below sits at a constant pitch: against its baseline the start is a clear look and stays; a head
    /// tilted well past it moves the start to a level look in the pause.
    @Test func openingJudgesPitchAgainstTheRecordingsBaseline() throws {
        let clip = try #require(Self.clip(previousEnd: 7.0, start: 10.0))
        func look(_ time: Double, pitch: Double) -> FrameObservation {
            FrameObservation(time: time, faceCount: 1, face: FrameFace(rect: Self.centred, captureQuality: 0.6,
                                                                        leftEyeAspect: 0.3, rightEyeAspect: 0.3, yaw: 0, pitch: pitch))
        }
        let level = [look(9.6, pitch: 0.45), look(10.0, pitch: 0.45)]
        #expect(OpeningFrame.choose(clip, scan: level, pitchBaseline: 0.45) == OpeningFrameChoice(shift: 0, time: 10.0))
        #expect(OpeningFrame.choose(clip, scan: level, pitchBaseline: nil) == nil, "judged from 0 nothing faces")
        let tilted = try #require(OpeningFrame.choose(clip, scan: [look(9.6, pitch: 0.45), look(10.0, pitch: 0.9)], pitchBaseline: 0.45))
        #expect(abs(tilted.time - 9.6) < 1e-9)
        let away = look(10.0, pitch: 0.9)
        #expect(ClipPicture.openingReason(away, pitchBaseline: 0.45) == "You were looking away on the first frame")
        #expect(ClipPicture.openingReason(away, pitchBaseline: 0.9) == "The first frame was blurred")
    }

    @Test func clipLeadInFloorIsTheEndOfTheItemBeforeItsFirstKeptWord() throws {
        let words = [TimedWord(id: "a", text: "One.", start: 1, end: 2), TimedWord(id: "b", text: "um", start: 2.2, end: 2.6),
                     TimedWord(id: "c", text: "Two", start: 3, end: 3.4), TimedWord(id: "d", text: "words.", start: 3.5, end: 4)]
        let clip = try #require(FrameClip(words: words, first: 1, last: 3, cutWordIds: ["b"]))
        #expect(clip.kept == [2, 3])
        #expect(clip.start == 3 && clip.end == 4)
        // The cut "um" is still a word in the source, so a shift may not reach into it.
        #expect(clip.leadInFloor == 2.6)
        #expect(FrameClip(words: words, first: 1, last: 1, cutWordIds: ["b"]) == nil)
    }

    // MARK: Face-follow crop

    @Test func cropIgnoresJitterAndOneWrongDetection() throws {
        let offsets = [0.0, 0.02, -0.03, 0.01, -0.02, 0.03, -0.01, 0.02, 0.0, -0.03]
        var samples: [(time: Double, face: ClipEffect.Rect?)] = offsets.enumerated().map { index, offset in
            (Double(index) * 0.5, Self.face(centreX: 0.6 + offset))
        }
        samples[5].face = Self.face(centreX: 0.1)
        samples[7].face = nil
        let plan = try #require(FaceFollowCrop.plan(samples, sourceAspect: 16.0 / 9.0, targetAspect: 9.0 / 16.0))
        #expect(abs(plan.cropWidth - 0.31640625) < 1e-9 && plan.cropHeight == 1)
        #expect(plan.isStatic)
        #expect(abs(plan.centerX - 0.6) < 0.02)
        #expect(plan.path.count == samples.count)
    }

    @Test func cropPansSlowlyAfterAMoveAndStaysInsideThePicture() throws {
        let samples: [(time: Double, face: ClipEffect.Rect?)] = (0..<20).map { index in
            (Double(index) * 0.5, Self.face(centreX: index < 8 ? 0.3 : 0.98))
        }
        let plan = try #require(FaceFollowCrop.plan(samples, sourceAspect: 16.0 / 9.0, targetAspect: 1))
        let half = plan.cropWidth / 2
        let xs = plan.path.map(\.x)
        #expect(!plan.isStatic)
        for (index, x) in xs.enumerated() {
            #expect(x >= half - 1e-9 && x <= 1 - half + 1e-9)
            guard index > 0 else { continue }
            let elapsed = plan.path[index].t - plan.path[index - 1].t
            #expect(x >= xs[index - 1] - 1e-9)
            #expect(x - xs[index - 1] <= FaceFollowCrop.maximumSpeed * plan.cropWidth * elapsed + 1e-9)
        }
        #expect(abs((xs.last ?? 0) - (1 - half)) < 1e-9)
    }

    @Test func cropWithoutFacesIsCentredAndASquareSourceNeedsNoCropForSquare() throws {
        let plan = try #require(FaceFollowCrop.plan([(0, nil), (1, nil)], sourceAspect: 16.0 / 9.0, targetAspect: 9.0 / 16.0))
        #expect(plan.centerX == 0.5 && plan.path.allSatisfy { $0.x == 0.5 })
        let square = try #require(FaceFollowCrop.plan([(0, Self.face(centreX: 0.9))], sourceAspect: 1, targetAspect: 1))
        #expect(square.cropWidth == 1 && square.centerX == 0.5)
        #expect(FaceFollowCrop.plan([], sourceAspect: 0, targetAspect: 1) == nil)
    }

    // MARK: Cover

    @Test func coverPrefersACentredSharpOpenFaceAndSkipsBlinks() throws {
        let sharp = FrameObservation(time: 2, faceCount: 1, face: FrameFace(rect: Self.centred, captureQuality: 0.8, leftEyeAspect: 0.3, rightEyeAspect: 0.3, yaw: 0, pitch: 0))
        let offCentre = FrameObservation(time: 4, faceCount: 1, face: FrameFace(rect: Self.face(centreX: 0.85), captureQuality: 0.8, leftEyeAspect: 0.3, rightEyeAspect: 0.3, yaw: 0, pitch: 0))
        let soft = FrameObservation(time: 6, faceCount: 1, face: FrameFace(rect: Self.centred, captureQuality: 0.3, leftEyeAspect: 0.3, rightEyeAspect: 0.3, yaw: 0, pitch: 0))
        let closed = FrameObservation(time: 8, faceCount: 1, face: FrameFace(rect: Self.centred, captureQuality: 0.9, leftEyeAspect: 0.1, rightEyeAspect: 0.1))
        let frames = [offCentre, soft, sharp, closed]
        #expect(CoverFrame.pick(frames, pitchBaseline: nil)?.time == 2)
        let sharpScore = try #require(CoverFrame.score(sharp, neighbours: frames, pitchBaseline: nil))
        let offScore = try #require(CoverFrame.score(offCentre, neighbours: frames, pitchBaseline: nil))
        let softScore = try #require(CoverFrame.score(soft, neighbours: frames, pitchBaseline: nil))
        #expect(sharpScore > offScore && sharpScore > softScore)
        #expect(CoverFrame.score(closed, neighbours: frames, pitchBaseline: nil) == nil)
        // The same sharp frame 0.1 s after a closed-eye frame is mid-blink.
        let blink = FrameObservation(time: 1.9, faceCount: 1, face: FrameFace(rect: Self.centred, leftEyeAspect: 0.05, rightEyeAspect: 0.05))
        #expect(CoverFrame.score(sharp, neighbours: frames + [blink], pitchBaseline: nil) == nil)
        // Then the soft centred face (0.65) beats the sharp one at the edge (0.64).
        #expect(CoverFrame.pick(frames + [blink], pitchBaseline: nil)?.time == 6)
        #expect(CoverFrame.pick([closed, FrameObservation(time: 9)], pitchBaseline: nil) == nil)
    }

    /// The cover's facing part reads pitch against the recording's baseline: a level face shot from below scores as facing.
    @Test func coverFacingUsesThePitchBaseline() throws {
        let low = FrameObservation(time: 2, faceCount: 1, face: FrameFace(rect: Self.centred, captureQuality: 0.6, leftEyeAspect: 0.3,
                                                                         rightEyeAspect: 0.3, yaw: 0, pitch: 0.45))
        let level = try #require(CoverFrame.score(low, neighbours: [low], pitchBaseline: 0.45))
        let judgedFromZero = try #require(CoverFrame.score(low, neighbours: [low], pitchBaseline: nil))
        #expect(abs(level - judgedFromZero - CoverFrame.facingWeight) < 1e-12)
    }

    // MARK: Screens and blur spans

    @Test func screensNeedARectangleWithDenseTextOrALargeTextCluster() {
        let phone = ClipEffect.Rect(x: 0.6, y: 0.3, width: 0.2, height: 0.4)
        let lines = (0..<4).map { ClipEffect.Rect(x: 0.62, y: 0.35 + Double($0) * 0.06, width: 0.15, height: 0.03) }
        let screens = FrameScreens.detect(rectangles: [phone], texts: lines)
        #expect(screens.count == 1 && screens.first?.framed == true && screens.first?.textBoxes == 4)
        #expect(FrameScreens.detect(rectangles: [phone], texts: Array(lines.prefix(2))).isEmpty)
        #expect(FrameScreens.detect(rectangles: [], texts: lines).isEmpty)
        let page = (0..<8).map { ClipEffect.Rect(x: 0.1, y: 0.1 + Double($0) * 0.04, width: 0.3, height: 0.025) }
        let cluster = FrameScreens.detect(rectangles: [], texts: page)
        #expect(cluster.count == 1 && cluster.first?.framed == false && cluster.first?.textBoxes == 8)
    }

    @Test func blurSpansMergeAMatchingScreenOverTimeAndSplitOnAGapOrAMove() {
        let left = ClipEffect.Rect(x: 0.1, y: 0.2, width: 0.2, height: 0.4)
        let nudged = ClipEffect.Rect(x: 0.12, y: 0.21, width: 0.2, height: 0.4)
        let right = ClipEffect.Rect(x: 0.7, y: 0.2, width: 0.2, height: 0.4)
        let frames = [Self.screen(1, left), Self.screen(2, nudged), Self.screen(3, left), Self.screen(3, right),
                      FrameObservation(time: 4), Self.screen(9, left)]
        let spans = FrameBlurSpans.merge(frames, maxGap: 2, pad: 0.5)
        #expect(spans.count == 3)
        #expect(spans[0].start == 0.5 && spans[0].end == 3.5 && spans[0].frames == 3)
        #expect(abs(spans[0].rect.x - 0.1) < 1e-9 && abs(spans[0].rect.width - 0.22) < 1e-9)
        #expect(spans[1].start == 2.5 && spans[1].frames == 1)
        #expect(spans[2].start == 8.5 && spans[2].end == 9.5)
    }

    // MARK: Sampling

    @Test func oneSampleForEachSentenceUpToTheLimitFirstAndLastKept() throws {
        var words: [TimedWord] = []
        for sentence in 0..<30 {
            for word in 0..<3 {
                let index = sentence * 3 + word
                let start = Double(index) * 0.5
                words.append(TimedWord(id: "w\(index)", text: word == 2 ? "end." : "word", start: start, end: start + 0.4))
            }
        }
        let clip = try #require(FrameClip(words: words, first: 0, last: words.count - 1, cutWordIds: []))
        let all = FrameSampling.sentenceSamples(clip, limit: 100)
        #expect(all.count == 30)
        #expect(all[0].firstWord == 0 && all[0].lastWord == 2 && abs(all[0].time - 0.7) < 1e-9)
        let limited = FrameSampling.sentenceSamples(clip)
        #expect(limited.count == FrameSampling.maximumSentences)
        #expect(limited.first == all.first && limited.last == all.last)
        #expect(zip(limited, limited.dropFirst()).allSatisfy { $0.time < $1.time })
        #expect(FrameSampling.openingTimes(start: 10).count == 13)
        #expect(FrameSampling.openingTimes(start: 0.2) == [0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8])
    }

    // MARK: Helpers

    static let centred = ClipEffect.Rect(x: 0.4, y: 0.3, width: 0.2, height: 0.4)

    static func face(centreX: Double) -> ClipEffect.Rect {
        ClipEffect.Rect(x: centreX - 0.1, y: 0.3, width: 0.2, height: 0.4)
    }

    static func frame(_ time: Double, clear: Bool) -> FrameObservation {
        let eyes = clear ? 0.3 : 0.1
        return FrameObservation(time: time, faceCount: 1, face: FrameFace(rect: centred, captureQuality: 0.7, leftEyeAspect: eyes, rightEyeAspect: eyes, yaw: 0, pitch: 0))
    }

    static func scan(from start: Double, through end: Double, clear: (Double) -> Bool) -> [FrameObservation] {
        let count = Int(((end - start) / 0.1).rounded())
        return (0...count).map { step in
            let time = ((start + Double(step) * 0.1) * 1000).rounded() / 1000
            return frame(time, clear: clear(time))
        }
    }

    /// "Before." ending at `previousEnd`, then a clip whose first word starts at `start`.
    static func clip(previousEnd: Double, start: Double) -> FrameClip? {
        let words = [TimedWord(id: "p", text: "Before.", start: previousEnd - 1, end: previousEnd),
                     TimedWord(id: "a", text: "Hello", start: start, end: start + 0.4),
                     TimedWord(id: "b", text: "there.", start: start + 0.5, end: start + 0.9)]
        return FrameClip(words: words, first: 1, last: 2, cutWordIds: [])
    }

    static func screen(_ time: Double, _ rect: ClipEffect.Rect) -> FrameObservation {
        FrameObservation(time: time, screens: [FrameScreen(rect: rect, textBoxes: 5, textCoverage: 0.2, framed: true)])
    }
}

/// Replays shared/fixtures/clip-frames/face-facing-cases.json (ADR-R48): the recording's typical pitch and facing the
/// camera from Vision's continuous yaw and pitch. The Windows twin owes the same replay.
@Suite(.offlineFixtures) struct FaceFacingVectorTests {
    struct Cases: Decodable {
        struct Baseline: Decodable { var id: String; var pitches: [Double?]; var expect: Double? }
        struct Facing: Decodable { var id: String; var yaw: Double?; var pitch: Double?; var pitchBaseline: Double?; var expect: Bool? }
        var format: String
        var yawLimit: Double
        var pitchLimit: Double
        var baseline: [Baseline]
        var facing: [Facing]
    }

    static func cases() throws -> Cases {
        try JSONDecoder().decode(Cases.self, from: FixtureLoader.data("fixtures/clip-frames/face-facing-cases.json"))
    }

    @Test func formatIsItsOwnFileAndTheLimitsMatch() throws {
        let cases = try Self.cases()
        #expect(cases.format == "voxclip-face-facing-cases/1")
        #expect(cases.yawLimit == FrameFace.yawLimit && cases.pitchLimit == FrameFace.pitchLimit)
    }

    @Test func baselinesReplay() throws {
        let rect = ClipEffect.Rect(x: 0.4, y: 0.3, width: 0.2, height: 0.4)
        for vector in try Self.cases().baseline {
            let frames = vector.pitches.enumerated().map { index, pitch in
                FrameObservation(time: Double(index), faceCount: 1, face: FrameFace(rect: rect, yaw: 0, pitch: pitch))
            }
            #expect(FrameFace.pitchBaseline(frames) == vector.expect, "\(vector.id)")
        }
    }

    @Test func facingReplays() throws {
        let rect = ClipEffect.Rect(x: 0.4, y: 0.3, width: 0.2, height: 0.4)
        for vector in try Self.cases().facing {
            let face = FrameFace(rect: rect, yaw: vector.yaw, pitch: vector.pitch)
            #expect(face.facesCamera(pitchBaseline: vector.pitchBaseline) == vector.expect, "\(vector.id)")
        }
    }
}
