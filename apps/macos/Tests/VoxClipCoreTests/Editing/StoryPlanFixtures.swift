import Foundation
import Testing
@testable import VoxClipCore

@Suite(.offlineFixtures) struct StoryPlanFixtures {
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
