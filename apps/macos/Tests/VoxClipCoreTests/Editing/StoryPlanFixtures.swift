import Foundation
import Testing
@testable import VoxClipCore

@Suite(.offlineFixtures) struct StoryPlanFixtures {
    @Test func storyOpeningStartsInPlaybackOrder() throws {
        let project = try JSONProjectStore.decode(FixtureLoader.data("fixtures/story-clips/story-project.voxclip"))
        let clip = try #require(project.edits.clips.first { $0.parts != nil })
        let opening = try #require(ClipPicture.openingClip(project, clipID: clip.id))
        let transcript = try #require(project.transcript)
        let candidates = try #require(FrameClip(transcript: transcript, clip: clip, cutWordIds: []))
        #expect(opening.words[opening.first].id == clip.playParts[0].startWordId)
        #expect(opening.words[opening.last].id == clip.playParts[0].endWordId)
        #expect(candidates == opening)
    }

    @Test func storyEffectsAndSavedLipSyncStopAtTheOwningPart() {
        let later = MediaInterval(startSample: 144_000, endSample: 168_000)
        let earlier = MediaInterval(startSample: 120_000, endSample: 144_000)
        let legacy = EditPlan(sampleRate: 48_000, totalSamples: 192_000, kept: [later, earlier], partSeams: [24_000])
        let effect = ClipEffect(id: "speed", clipId: "story", kind: .speedForPart, start: 2.5, end: 3, rate: 2)
        let timing = ClipSpeedTiming(speed: 1, timeline: .legacy(legacy), effects: [effect])
        #expect(timing.rendered(0.5) == 0.5)
        #expect(timing.rendered(1) == 0.75)

        let second = VoiceLabOutputPiece(kind: .synth, sourceStartSample: 120_000, sourceEndSample: 144_000,
            outputStartSample: 24_000, outputEndSample: 48_000, segmentId: "speech", assetId: nil, audio: nil)
        let first = VoiceLabOutputPiece(kind: .source, sourceStartSample: 144_000, sourceEndSample: 168_000,
            outputStartSample: 0, outputEndSample: 24_000, segmentId: nil, assetId: nil, audio: nil)
        let voice = VoiceLabOutputPlan(sampleRate: 48_000, totalSourceSamples: 192_000, pieces: [first, second],
            captions: [], scope: .clip("story"), partSeams: [24_000])
        #expect(LipsyncRenderWindow.savedOutputRange(start: 120_000, end: 144_000, piece: second, plan: voice) == 24_000..<48_000)
        #expect(LipsyncRenderWindow.savedOutputRange(start: 120_000, end: 145_000, piece: second, plan: voice) == nil)
    }

    @Test func storyPlansReplay() throws {
        let data = try FixtureLoader.data("fixtures/story-clips/plan-vectors.json")
        let cases = FixtureValue(try JSONDecoder().decode(JSONValue.self, from: data)).array
        #expect(cases.count == 4)
        for row in cases {
            var project = try JSONProjectStore.decode(FixtureLoader.data("fixtures/" + row["base"].string))
            let data = try JSONEncoder().encode(row["clip"].value)
            let clip = try ProjectJSON.decoder().decode(ClipRange.self, from: data)
            project.edits.clips = [clip]
            project.edits.activeClipId = clip.id
            project.edits.cutWordIds = row["cuts"].array.map(\.string)
            project.edits.cutPauseIds = []
            if row["edges"].bool, var transcript = project.transcript {
                transcript.words[0].start = 0
                transcript.words[transcript.words.count - 1].end = project.media.source.durationSeconds
                project.transcript = transcript
            }
            if row["reject"].bool {
                #expect(throws: VoxClipError.self) { try ProjectJSON.encode(project) }
                #expect(throws: (any Error).self) { try RenderCallerInputs.timeline(project: project, clipID: clip.id) }
                continue
            }
            project = try StoryClips.forWriting(project)
            let state = try EditState(transcript: #require(project.transcript), edits: project.edits)
            let rate = row["rate"].number
            let plan = try EditPlan.build(transcript: state.transcript, editState: state, activeClip: clip,
                                          duration: project.media.source.durationSeconds, sampleRate: rate)
            func samples(_ key: String) -> [MediaInterval] {
                row[key].array.map { MediaInterval(startSample: Int64($0.array[0].int), endSample: Int64($0.array[1].int)) }
            }
            #expect(plan.kept == samples("kept"), "\(row["id"].string)")
            #expect(plan.cuts == samples("complement"))
            #expect(plan.partSeams == row["seams"].array.map { Int64($0.int) })
            let timeline = TimelinePieces(.legacy(plan))
            #expect(timeline.pieces.indices.filter(timeline.isPartSeam(at:)).map { timeline.pieces[$0].edited.lowerBound } == plan.partSeams.map { Double($0) / rate })
            #expect(timeline.pieces(on: .source).map(\.source.lowerBound) == timeline.pieces.map(\.source.lowerBound).sorted())
            #expect(plan.fadeParts.map { [$0.outputStart, $0.fadeIn, $0.fadeOut] } == row["fades"].array.map { $0.array.map { Int64($0.int) } })
            let captions = captionCopy(try buildSegments(state, activeClip: clip), plan: plan)
            #expect(captions.map(\.id) == row["captions"].array.map { $0.array[0].string })
            for (caption, expected) in zip(captions, row["captions"].array) {
                #expect(abs(caption.start * rate - expected.array[1].number) < 1e-6)
                #expect(abs(caption.end * rate - expected.array[2].number) < 1e-6)
            }
            #expect(captions.filter(\.startsPart).count == plan.partSeams.count)
            for probe in row["probes"].array {
                let source = probe.array[0].number / rate, output = probe.array[1].number / rate
                #expect(plan.mapTime(source) == output)
                #expect(plan.sourceTime(output) == source)
            }
            if !row["voice"].isNull {
                guard case .voiceLab(let voice) = try RenderCallerInputs.timeline(project: project, clipID: clip.id) else {
                    Issue.record("Expected the paid patch to play"); continue
                }
                let patch = try #require(voice.pieces.first { $0.segmentId == row["voice"]["segmentId"].string })
                #expect(patch.sourceStartSample == Int64(row["voice"]["source"].int))
                #expect(patch.outputStartSample == Int64(row["voice"]["output"].int))
                #expect(voice.mapTime(Double(patch.sourceStartSample) / rate) == Double(patch.outputStartSample) / rate)
            } else {
                guard case .legacy(let rendered) = try RenderCallerInputs.timeline(project: project, clipID: clip.id) else {
                    Issue.record("Expected the story's source-only plan"); continue
                }
                #expect(rendered == plan)
            }
        }
    }
}
