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
        let (vectors, original) = try load()
        let keyA = vectors["recordingA"].string, keyB = vectors["recordingB"].string
        let matches = TakeMatch.build(clock: ProjectClock.build(original))
        let punchline = try #require(matches.solo.first { $0.key == keyA })
        let opening = try #require(matches.beats.first)
        let started = try apply(.startFromRecording(key: keyB), original, "Start from recording")
        let initial = try #require(started.project.edits.clips.first)
        expectRanges(vectors["started"], initial)
        var partial = started.project
        partial.edits.clips[0].parts = nil
        partial.edits.clips[0].kind = nil
        partial.edits.clips[0].endWordId = initial.playParts[0].endWordId
        #expect(RecordingEdits.placement(clipId: initial.id, soloRun: punchline, project: partial) == nil)

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
        let timeline = TimelinePieces(.legacy(plan))
        #expect(timeline.pieces.indices.filter(timeline.isRecordingSeam(at:)).map {
            Int((timeline.pieces[$0].edited.lowerBound * plan.sampleRate).rounded())
        } == final["recordingSeams"].array.map(\.int))
        let sources = try plan.kept.map { span in try #require(clock.resolve(Int(span.startSample))) }
        let expectedSources = final["parts"].array.flatMap { row in row["kept"].array.map { (row["sourceKey"].string, $0.array.map(\.int)) } }
        #expect(sources.map(\.key) == expectedSources.map { $0.0 })
        #expect(zip(sources, plan.kept).map { [$0.localSample, $0.localSample + Int($1.count)] } == expectedSources.map { $0.1 })

        let leftOut = try #require(started.details?.leftOut.first)
        #expect([leftOut.startWordId, leftOut.endWordId] == vectors["leftOut"].array.map(\.string))
        let restored = try apply(.insertLine(clipId: initial.id, key: keyB, startWordId: leftOut.startWordId,
                                             endWordId: leftOut.endWordId, afterWordId: initial.playParts[0].endWordId), started.project, "Add part")
        let single = try #require(restored.project.edits.clips.first)
        expectRanges(vectors["putBack"], single)
        #expect(single.playParts.first?.id == initial.playParts[0].id)
        #expect(restored.details?.joins.count == 2)
    }

    @Test func replacingAMiddleLineKeepsReframesAndThePartBeforeIt() throws {
        let (vectors, original) = try load()
        var project = original
        let joined = vectors["putBack"].array[0].array.map(\.string)
        let punchline = vectors["final"]["ranges"].array[3].array.map(\.string)
        let reframe = ReframeSettings(mode: ReframeSettings.faceMode, centerX: 0.4, centerY: 0.6)
        let parts = [ClipPart(id: "main", startWordId: joined[0], endWordId: joined[1], reframe: reframe),
                     ClipPart(id: "existing", startWordId: punchline[0], endWordId: punchline[1], reframe: reframe)]
        let id = "story"
        project.edits.clips = [ClipRange(id: id, startWordId: joined[0], endWordId: punchline[1], parts: parts, kind: .story)]
        project.edits.activeClipId = id
        let solo = try #require(TakeMatch.build(clock: ProjectClock.build(project)).solo.first { $0.key == vectors["recordingA"].string })
        let beatId = try #require(solo.afterBeatId)
        let applied = try apply(.useLineVersion(clipId: id, beatId: beatId, key: solo.key), project, "Use version")
        let changed = try #require(applied.project.edits.clips.first?.playParts)
        try #require(changed.count == 4)
        #expect(changed.prefix(3).map { [$0.startWordId, $0.endWordId] } == vectors["middle"].array.map { $0.array.map(\.string) })
        #expect(changed.map(\.reframe) == Array(repeating: reframe, count: 4))
        #expect(changed.first?.id == parts[0].id && changed.last == parts[1])
        #expect(applied.details?.splitPartId == parts[0].id)
        #expect(applied.details?.madePartIds == Array(changed[1...2]).map(\.id))
        #expect(RecordingEdits.placement(clipId: id, soloRun: solo, project: applied.project) == changed[1].endWordId)
        let unchanged = try RecordingEdits.apply(.useLineVersion(clipId: id, beatId: beatId, key: solo.key), project: applied.project).get()
        #expect(unchanged.undoStep == nil)
    }

    @Test func connectedItemsFollowTheirSourceWordsAcrossVersions() throws {
        let (vectors, original) = try load()
        let keyA = vectors["recordingA"].string, keyB = vectors["recordingB"].string
        var project = try apply(.startFromRecording(key: keyB), original, "Start from recording").project
        let id = try #require(project.edits.activeClipId)
        let beat = try #require(TakeMatch.build(clock: ProjectClock.build(project)).beats.first)
        project.motionCues = [MotionCue(id: "replaced", clipID: id, sourceStart: 0.3, sourceEnd: 0.5),
                              MotionCue(id: "kept", clipID: id, sourceStart: 1.2, sourceEnd: 1.4)]
        let swapped = try apply(.useLineVersion(clipId: id, beatId: beat.id, key: keyA), project, "Use version").project
        let restored = try apply(.useLineVersion(clipId: id, beatId: beat.id, key: keyB), swapped, "Use version").project
        func items(_ snapshot: Project) throws -> [TimelineItem] {
            let state = try #require(try EditState(project: snapshot))
            let clip = try #require(state.activeClip)
            let plan = try buildStoryPlan(state, clip: clip, duration: snapshot.media.source.durationSeconds, sampleRate: 48_000)
            return TimelineItems.layout(project: snapshot, plan: plan, scope: id, axis: .edited).items
        }
        let swappedItems = try items(swapped)
        #expect(swappedItems.first { $0.id == .motion("replaced") }?.hidden == true)
        let kept = try #require(swappedItems.first { $0.id == .motion("kept") })
        #expect(!kept.hidden && kept.partID == swapped.edits.clips[0].playParts[1].id)
        #expect(try items(restored) == items(project))
        #expect(restored.motionCues == project.motionCues)
    }

    @Test func onlyTheAlignedClauseComesInFromARunOnVersion() throws {
        let (vectors, original) = try load()
        let row = vectors["runOn"]
        var sources = try #require(original.media.spokenSources)
        let index = try #require(sources[0].transcript.words.firstIndex { $0.id == row["afterWordId"].string })
        sources[0].transcript.words[index].text = row["clauseBreak"].string
        let tail = row["tail"].array.map { value in
            TimedWord(id: value.array[0].string, text: value.array[1].string, start: value.array[2].number, end: value.array[3].number)
        }
        sources[0].transcript.words.insert(contentsOf: tail, at: index + 1)
        var project = original
        project.media.spokenSources = sources
        let keyA = vectors["recordingA"].string, keyB = vectors["recordingB"].string
        let beat = try #require(TakeMatch.build(clock: ProjectClock.build(project)).beats.first)
        #expect(beat.takes.first { $0.key == keyA }?.endWordId == sources[0].wordIdPrefix + tail.last!.id)
        let started = try apply(.startFromRecording(key: keyB), project, "Start from recording")
        let clip = try #require(started.project.edits.clips.first)
        let swapped = try apply(.useLineVersion(clipId: clip.id, beatId: beat.id, key: keyA), started.project, "Use version")
        expectRanges(vectors["swapped"], try #require(swapped.project.edits.clips.first))
        let restored = try apply(.useLineVersion(clipId: clip.id, beatId: beat.id, key: keyB), swapped.project, "Use version")
        #expect(restored.project.edits.clips.first?.playParts == clip.playParts)
    }

    private func load() throws -> (FixtureValue, Project) {
        let data = try FixtureLoader.data("fixtures/recordings/command-cases.json")
        let vectors = FixtureValue(try JSONDecoder().decode(JSONValue.self, from: data))
        #expect(vectors["schema"].string == "voxclip-recording-commands/1")
        return (vectors, try JSONProjectStore.decode(FixtureLoader.data("fixtures/recordings/" + vectors["project"].string)))
    }

    private func expectRanges(_ expected: FixtureValue, _ clip: ClipRange) {
        #expect(clip.playParts.map { [$0.startWordId, $0.endWordId] } == expected.array.map { $0.array.map(\.string) })
    }

    private func apply(_ edit: RecordingEdit, _ project: Project, _ name: String) throws -> RecordingEditOutcome {
        let result = try RecordingEdits.apply(edit, project: project).get()
        #expect(result.undoName == name)
        let step = try #require(result.undoStep)
        #expect(step.name == name)
        #expect(try JSONProjectStore.encode(step.before) == JSONProjectStore.encode(project))
        let bytes = try JSONProjectStore.encode(result.project)
        #expect(try JSONProjectStore.encode(step.after) == bytes)
        #expect(try JSONProjectStore.encode(JSONProjectStore.decode(bytes)) == bytes)
        return result
    }
}
