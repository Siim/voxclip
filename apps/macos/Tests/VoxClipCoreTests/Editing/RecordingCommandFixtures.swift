import Foundation
import Testing
@testable import VoxClipCore

@Suite(.offlineFixtures) struct RecordingCommandFixtures {
    @Test func startsFromTheWholeRecordingExceptRestarts() throws {
        let original = try JSONProjectStore.decode(FixtureLoader.data("fixtures/recordings/reference-recordings.voxclip"))
        let started = try RecordingEdits.apply(.startFromRecording(key: original.media.source.contentKey), project: original).get()
        let clip = try #require(started.project.edits.clips.last)
        #expect(started.undoName == "Start from recording")
        #expect(clip.id == started.project.edits.activeClipId)
        #expect(clip.title == "I started Superscribe as a dictation tool.")
        #expect(clip.playParts.map(\.startWordId) == ["w1", "w18"])
        #expect(clip.playParts.map(\.endWordId) == ["w13", "w27"])
        #expect(started.details?.leftOut.map(\.startWordId) == ["w14"])
    }

    @Test func replaysTheReferenceStoryAndRestoresTheOriginalParts() throws {
        let data = try FixtureLoader.data("fixtures/recordings/command-cases.json")
        let vectors = FixtureValue(try JSONDecoder().decode(JSONValue.self, from: data))
        #expect(vectors["schema"].string == "voxclip-recording-commands/1")
        let original = try JSONProjectStore.decode(FixtureLoader.data("fixtures/recordings/" + vectors["project"].string))
        let keyA = vectors["recordingA"].string, keyB = vectors["recordingB"].string
        let matches = TakeMatch.build(clock: ProjectClock.build(original))
        let punchline = try #require(matches.solo.first { $0.key == keyA })
        let opening = try #require(matches.beats.first)
        let started = try apply(.startFromRecording(key: keyB), original, "Start from recording")
        let initial = try #require(started.project.edits.clips.first)
        expectRanges(vectors["started"], initial)
        let missing = TakeMatch.SoloRun(key: keyA, startWordId: punchline.startWordId, endWordId: punchline.endWordId,
                                       sentenceCount: punchline.sentenceCount, afterBeatId: "absent", beforeBeatId: nil)
        #expect(RecordingEdits.placement(clipId: initial.id, soloRun: missing, project: started.project) == nil)

        let swapped = try apply(.useLineVersion(clipId: initial.id, beatId: opening.id, key: keyA), started.project, "Use version")
        expectRanges(vectors["swapped"], try #require(swapped.project.edits.clips.first))
        let back = try apply(.useLineVersion(clipId: initial.id, beatId: opening.id, key: keyB), swapped.project, "Use version")
        #expect(back.project.edits.clips.first?.playParts == initial.playParts)
        let placement = RecordingEdits.placement(clipId: initial.id, soloRun: punchline, project: swapped.project)
        #expect(placement == vectors["placement"].string)
        let inserted = try apply(.insertLine(clipId: initial.id, key: keyA, startWordId: punchline.startWordId,
                                             endWordId: punchline.endWordId, afterWordId: placement), swapped.project, "Add part")
        let final = vectors["final"]
        let clip = try #require(inserted.project.edits.clips.first)
        expectRanges(final["ranges"], clip)
        let clock = ProjectClock.build(inserted.project)
        let state = try #require(try EditState(project: inserted.project))
        let plan = try buildStoryPlan(state, clip: clip, duration: original.media.source.durationSeconds, sampleRate: Double(clock.sampleRate))
        #expect(plan.kept == final["kept"].array.map { MediaInterval(startSample: Int64($0.array[0].int), endSample: Int64($0.array[1].int)) })
        #expect(plan.outputSamples == Int64(final["outputSamples"].int))
        #expect(plan.partSeams == final["partSeams"].array.map { Int64($0.int) })

        let leftOut = try #require(started.details?.leftOut.first)
        #expect([leftOut.startWordId, leftOut.endWordId] == vectors["leftOut"].array.map(\.string))
        let restored = try apply(.insertLine(clipId: initial.id, key: keyB, startWordId: leftOut.startWordId,
                                             endWordId: leftOut.endWordId, afterWordId: initial.playParts[0].endWordId), started.project, "Add part")
        let single = try #require(restored.project.edits.clips.first)
        expectRanges(vectors["putBack"], single)
        #expect(single.playParts.first?.id == initial.playParts[0].id)
        #expect(restored.details?.joins.count == 2)
    }

    private func expectRanges(_ expected: FixtureValue, _ clip: ClipRange) {
        #expect(clip.playParts.map { [$0.startWordId, $0.endWordId] } == expected.array.map { $0.array.map(\.string) })
    }

    private func apply(_ edit: RecordingEdit, _ project: Project, _ name: String) throws -> RecordingEditOutcome {
        let result = try RecordingEdits.apply(edit, project: project).get()
        #expect(result.undoName == name)
        let bytes = try JSONProjectStore.encode(result.project)
        #expect(try JSONProjectStore.encode(JSONProjectStore.decode(bytes)) == bytes)
        return result
    }
}
