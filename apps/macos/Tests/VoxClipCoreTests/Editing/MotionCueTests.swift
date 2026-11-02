import Foundation
import Testing
@testable import VoxClipCore

@Suite(.offlineFixtures) struct MotionCueTests {
    private func cue(id: String = "motion", clipID: String = "clip", start: Double = 10, end: Double = 14, scale: Double = 1.2) -> MotionCue {
        MotionCue(id: id, clipID: clipID, sourceStart: start, sourceEnd: end,
                  keyframes: [MotionKeyframe(progress: 0), MotionKeyframe(progress: 1, scale: scale, anchorX: 1, anchorY: 0)])
    }

    @Test func clampsNonfiniteAndOutOfRangeFraming() {
        let frame = MotionKeyframe(progress: .infinity, scale: .nan, anchorX: -5, anchorY: 9)
        #expect(frame.progress == 0 && frame.scale == 1 && frame.anchorX == 0 && frame.anchorY == 1)
        let maximum = MotionCropTransform(scale: 20, anchorX: 10, anchorY: -2)
        #expect(maximum.scale == 1.35 && maximum.anchorX == 1 && maximum.anchorY == 0)
        #expect(maximum.cropX >= 0 && maximum.cropY >= 0)
        #expect(maximum.cropX + maximum.cropWidth <= 1)
        #expect(maximum.cropY + maximum.cropHeight <= 1)
    }

    @Test func keyframesAreBoundedSortedUniqueAndIncludeEndpoints() {
        let frames = (0..<30).reversed().map { MotionKeyframe(progress: Double($0) / 30, scale: 1.1) }
        let value = MotionCue(id: "motion", clipID: "clip", sourceStart: 1, sourceEnd: 500, keyframes: frames)
        #expect(value.keyframes.count <= MotionCue.maximumKeyframes)
        #expect(value.keyframes.first?.progress == 0 && value.keyframes.last?.progress == 1)
        #expect(value.keyframes.map(\.progress) == value.keyframes.map(\.progress).sorted())
        #expect(Set(value.keyframes.map(\.progress)).count == value.keyframes.count)
        #expect(value.sourceEnd == 121)
        let duplicate = MotionCue(id: "dup", clipID: "clip", sourceStart: 1, sourceEnd: 2,
            keyframes: [MotionKeyframe(progress: 0.5, scale: 1.1), MotionKeyframe(progress: 0.5, scale: 1.3)])
        #expect(duplicate.keyframes.count == 3 && duplicate.keyframes[1].scale == 1.1)
    }

    @Test func smoothstepIsRestrainedAndHalfOpen() {
        let value = cue(scale: 1.35)
        #expect(value.transform(atSourceTime: 9) == .identity)
        #expect(value.transform(atSourceTime: 10).scale == 1)
        #expect(abs(value.transform(atSourceTime: 11).scale - 1.0546875) < 1e-12)
        #expect(abs(value.transform(atSourceTime: 12).scale - 1.175) < 1e-12)
        #expect(value.transform(atSourceTime: 14) == .identity)
        #expect(value.transform(atSourceTime: .nan) == .identity)
        for index in 0..<400 {
            let transform = value.transform(atSourceTime: 10 + Double(index) / 100)
            #expect((1...1.35).contains(transform.scale))
            #expect((0...1).contains(transform.anchorX) && (0...1).contains(transform.anchorY))
            #expect(transform.cropX + transform.cropWidth <= 1 + 1e-12)
            #expect(transform.cropY + transform.cropHeight <= 1 + 1e-12)
        }
    }

    @Test func clipScopeReduceMotionAndOverlapPriorityAreDeterministic() {
        let first = cue(id: "a", scale: 1.1)
        let second = cue(id: "b", scale: 1.3)
        #expect(MotionCue.transform(atSourceTime: 12, clipID: nil, cues: [first]) == .identity)
        #expect(MotionCue.transform(atSourceTime: 12, clipID: "other", cues: [first]) == .identity)
        #expect(MotionCue.transform(atSourceTime: 12, clipID: "clip", cues: [first], reduceMotion: true) == .identity)
        #expect(MotionCue.transform(atSourceTime: 12, clipID: "clip", cues: [second, first]) == first.transform(atSourceTime: 12))
        #expect(MotionCue.transform(atSourceTime: 12, clipID: "clip", cues: [first, second]) == first.transform(atSourceTime: 12))
        #expect(MotionCue.transform(atSourceTime: 12, clipID: "clip", cues: [first], reduceMotion: false).scale > 1)
    }

    @Test func sourceIntervalsSkipCutsAndMapRetimedPiecesAffinely() throws {
        let pieces = TimelinePieces([
            TimelinePiece(source: 0..<3, edited: 0..<3),
            TimelinePiece(source: 5..<7, edited: 3..<5),
            TimelinePiece(source: 7..<10, edited: 5..<11, kind: .ai)
        ])
        let value = cue(start: 1, end: 9)
        let intervals = value.mappedIntervals(in: pieces)
        #expect(intervals.map(\.source) == [1..<3, 5..<7, 7..<9])
        #expect(intervals.map(\.edited) == [1..<3, 3..<5, 5..<9])
        #expect(cue(start: 3, end: 5).mappedIntervals(in: pieces).isEmpty)
        let retimed = try #require(intervals.last)
        let editedMidpoint = (retimed.edited.lowerBound + retimed.edited.upperBound) / 2
        let sourceMidpoint = 7 + (editedMidpoint - 5) / 2
        #expect(sourceMidpoint == 8)
        #expect(value.transform(atSourceTime: sourceMidpoint) == value.transform(atSourceTime: 8))
    }

    @Test func invalidIntervalsDoNotProduceMotion() {
        for value in [cue(start: .nan, end: .nan), cue(start: .nan, end: 12), cue(start: 10, end: 2), cue(start: 10, end: 10.01), cue(id: "")] {
            #expect(!value.isValid)
            #expect(value.transform(atSourceTime: 10) == .identity)
            #expect(value.mappedIntervals(in: TimelinePieces([TimelinePiece(source: 0..<20, edited: 0..<20)])).isEmpty)
        }
        #expect(cue(start: 10, end: 10.1).isValid)
    }

    @Test func cueCodecRoundtripKeepsCanonicalTransforms() throws {
        let value = cue()
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(MotionCue.self, from: data)
        #expect(decoded == value)
        #expect(decoded.transform(atSourceTime: 12) == value.transform(atSourceTime: 12))
        let unbounded = Data(#"{"id":"motion","clipID":"clip","sourceStart":1,"sourceEnd":2,"keyframes":[{"progress":0,"scale":20,"anchorX":-5,"anchorY":10}]}"#.utf8)
        let bounded = try JSONDecoder().decode(MotionCue.self, from: unbounded)
        #expect(bounded.keyframes.count == 2)
        #expect(bounded.keyframes.allSatisfy { $0.scale == 1.35 && $0.anchorX == 0 && $0.anchorY == 1 })
    }

    @Test func projectPersistenceKeepsMotionAndOriginalNarration() throws {
        let shared = try SharedResources.locate()
        var project = try JSONProjectStore.decode(Data(contentsOf: shared.root.appendingPathComponent("fixtures/projects/interview-take.voxclip")))
        let narration = project.transcript
        let media = project.media
        let edits = project.edits
        let value = cue(clipID: "motion-clip", start: 1, end: 2)
        project.edits.clips.append(ClipRange(id: "motion-clip", startWordId: try #require(project.transcript?.words.first?.id), endWordId: try #require(project.transcript?.words.last?.id)))
        project = try ContextDemoProject.settingMotionCues([value], in: project)
        #expect(project.schemaVersion == 4)
        let decoded = try JSONProjectStore.decode(JSONProjectStore.encode(project))
        #expect(decoded.motionCues == [value])
        #expect(decoded.transcript == narration && decoded.media == media)
        #expect(decoded.edits.cutWordIds == edits.cutWordIds && decoded.edits.cutPauseIds == edits.cutPauseIds)
    }

    @Test func legacyVoiceSegmentsAreNotImplicitlyUpgradedForMotion() throws {
        let shared = try SharedResources.locate()
        let project = try JSONProjectStore.decode(Data(contentsOf: shared.root.appendingPathComponent("fixtures/voice-lab/passage-project.voxclip")))
        #expect(project.schemaVersion == 2 && !project.voiceLab.segments.isEmpty)
        #expect(throws: VoiceLabProjectError.legacySegmentsNeedReview) {
            try ContextDemoProject.settingMotionCues([cue()], in: project)
        }
        #expect(project.schemaVersion == 2 && project.motionCues.isEmpty)
    }

    @Test func removingOneClipRemovesOnlyItsCuesBeforeSaving() throws {
        let shared = try SharedResources.locate()
        var project = try JSONProjectStore.decode(Data(contentsOf: shared.root.appendingPathComponent("fixtures/projects/interview-take.voxclip")))
        let firstWord = try #require(project.transcript?.words.first?.id)
        let lastWord = try #require(project.transcript?.words.last?.id)
        project.edits.clips = [
            ClipRange(id: "clip", startWordId: firstWord, endWordId: lastWord),
            ClipRange(id: "other-clip", startWordId: firstWord, endWordId: lastWord)
        ]
        let removed = cue(start: 1, end: 2)
        let retained = cue(id: "other-motion", clipID: "other-clip", start: 1, end: 2)
        project = try ContextDemoProject.settingMotionCues([removed, retained], in: project)
        let narration = project.transcript
        let media = project.media
        try project.applyEditing(.removeClip(id: "clip"))
        #expect(project.edits.clips.map(\.id) == ["other-clip"])
        #expect(project.motionCues == [retained])
        let saved = try JSONProjectStore.decode(JSONProjectStore.encode(project))
        #expect(saved.motionCues == [retained] && saved.edits.clips == project.edits.clips)
        #expect(saved.transcript == narration && saved.media == media)
    }
}
