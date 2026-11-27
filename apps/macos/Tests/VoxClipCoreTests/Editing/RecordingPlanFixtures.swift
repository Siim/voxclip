import Foundation
import Testing
@testable import VoxClipCore

@Suite(.offlineFixtures) struct RecordingPlanFixtures {
    @Test func aSavedPrimaryVoicePatchKeepsItsOutputBeforeTheRecordingSeam() throws {
        var project = try JSONProjectStore.decode(FixtureLoader.data("fixtures/voice-lab/passage-render-v3.voxclip"))
        let primary = try VoiceLabOutputPlanner.build(project, scope: .full)
        let companion = try JSONProjectStore.decode(FixtureLoader.data("fixtures/recordings/two-recordings.voxclip"))
        project.schemaVersion = 7
        project.media.additionalSources = companion.media.additionalSources
        project.media.spokenSources = companion.media.spokenSources
        project.media.spokenSources?[0].offsetSeconds = Int(ceil(project.media.source.durationSeconds)) + 1
        let plan = try VoiceLabOutputPlanner.build(project, scope: .full)
        #expect(primary.requiresSyntheticRendering)
        #expect(Array(plan.pieces.prefix(primary.pieces.count)) == primary.pieces)
        #expect(Array(plan.captions.prefix(primary.captions.count)) == primary.captions)
        let timeline = TimelinePieces(.voiceLab(plan))
        #expect(timeline.pieces.indices.filter(timeline.isRecordingSeam(at:)) == [primary.pieces.count])
        let next = try #require(plan.captions.dropFirst(primary.captions.count).first)
        #expect(next.id == "r2.w1" && next.startsPart)
    }

    @Test func oneRecordingKeepsLegacyPlansOnRandomProjects() throws {
        let base = try JSONProjectStore.decode(FixtureLoader.data("fixtures/story-clips/story-project.voxclip"))
        var random: UInt64 = 0xC31
        func next(_ upper: Int) -> Int {
            random = random &* 6_364_136_223_846_793_005 &+ 1
            return Int((random >> 32) % UInt64(upper))
        }
        for seed in 0..<64 {
            var project = base
            var transcript = try #require(project.transcript)
            var time = Double(next(200)) / 1_000
            for index in transcript.words.indices {
                transcript.words[index].start = time
                time += Double(1 + next(700)) / 1_000
                transcript.words[index].end = time
                time += Double(next(1_500)) / 1_000
            }
            let duration = time + 0.3
            let rate = seed.isMultiple(of: 2) ? 48_000.0 : 44_100.0
            project.media.source.durationSeconds = duration
            project.media.source.audio?.sampleRate = Int(rate)
            transcript.durationSeconds = duration
            project.transcript = transcript
            let words = transcript.words
            let early = ClipRange(id: "early", startWordId: words[next(2)].id, endWordId: words[1 + next(2)].id,
                                  leadInSeconds: Double(next(600)) / 1_000)
            let late = ClipRange(id: "late", startWordId: words[4 + next(2)].id, endWordId: words[6 + next(3)].id)
            var story = ClipRange(id: "story", startWordId: early.startWordId, endWordId: late.endWordId)
            story.parts = seed.isMultiple(of: 2) ? late.playParts + early.playParts : early.playParts + late.playParts
            story.kind = .story
            story.leadInSeconds = Double(next(600)) / 1_000
            let threshold = Double(350 + next(700)) / 1_000
            let pauses = try detectPauses(words, thresholdSeconds: threshold)
            project.edits = ProjectEdits(pauseThresholdSeconds: threshold, pauseKeepSeconds: Double(next(300)) / 1_000,
                                        cutWordIds: words.filter { _ in next(4) == 0 }.map(\.id),
                                        cutPauseIds: pauses.filter { _ in next(2) == 0 }.map(\.id),
                                        corrections: [words[1].id: "corrected words"], clips: [early, story])
            let clock = try #require(try EditState(project: project))
            let legacy = try EditState(transcript: transcript, edits: project.edits)
            func legacySingle(_ clip: ClipRange?) throws -> EditPlan {
                try buildEditPlan(buildSegments(legacy, activeClip: clip), duration: duration, sampleRate: rate,
                                  pauseKeepSeconds: legacy.pauseKeepSeconds)
            }
            for clip in [nil, early, story] {
                let segments = try buildSegments(legacy, activeClip: clip)
                let expected: EditPlan
                if let clip, clip.parts != nil {
                    let parts = try clip.playParts.enumerated().map { index, part in
                        try legacySingle(ClipRange(id: part.id, startWordId: part.startWordId, endWordId: part.endWordId,
                                                   leadInSeconds: index == 0 ? clip.leadInSeconds : nil))
                    }.filter { !$0.kept.isEmpty }
                    let kept = parts.flatMap(\.kept)
                    var output: Int64 = 0
                    let seams = parts.map { plan in defer { output += plan.outputSamples }; return output }.dropFirst()
                    let total = Int64((duration * rate).rounded())
                    expected = EditPlan(sampleRate: rate, totalSamples: total,
                                        cuts: complement(kept.sorted { $0.startSample < $1.startSample }, total: total),
                                        kept: kept, partSeams: Array(seams))
                } else { expected = try legacySingle(clip) }
                #expect(try EditPlan.build(transcript: clock.transcript, editState: clock, activeClip: clip,
                                           duration: duration, sampleRate: rate) == expected, "random project \(seed)")
                let scope = clip.map { VoiceLabOutputScope.clip($0.id) } ?? .full
                let voice = try VoiceLabOutputPlanner.build(project, scope: scope)
                let pieces = zip(expected.kept, expected.fadeParts).map { span, fade in
                    VoiceLabOutputPiece(kind: .source, sourceStartSample: span.startSample, sourceEndSample: span.endSample,
                                        outputStartSample: fade.outputStart, outputEndSample: fade.outputStart + span.count,
                                        segmentId: nil, assetId: nil, audio: nil)
                }
                #expect(voice == VoiceLabOutputPlan(sampleRate: rate, totalSourceSamples: expected.totalSamples, pieces: pieces,
                                                  captions: captionCopy(segments, plan: expected), scope: scope, partSeams: expected.partSeams),
                        "random project \(seed)")
            }
        }
    }

    @Test func plansKeepOnlyRecordingSamplesInPlaybackOrder() throws {
        let data = try FixtureLoader.data("fixtures/recordings/plan-cases.json")
        let fixture = FixtureValue(try JSONDecoder().decode(JSONValue.self, from: data))
        #expect(fixture["schema"].string == "voxclip-recording-plans/1")
        let rate = fixture["sampleRate"].number
        try #require(!fixture["cases"].array.isEmpty)
        for row in fixture["cases"].array {
            let id = row["id"].string
            let bytes = try FixtureLoader.data("fixtures/recordings/" + row["project"].string)
            var document = FixtureValue(try JSONDecoder().decode(JSONValue.self, from: bytes)).object
            var edits = row["edits"].object
            let clip = row["clip"]
            edits["clips"] = .array(clip.isNull ? [] : [clip.value])
            edits["activeClipId"] = clip.isNull ? .null : clip["id"].value
            document["edits"] = .object(edits)
            let project = try JSONProjectStore.decode(JSONEncoder().encode(JSONValue.object(document)))
            let state = try #require(try EditState(project: project))
            let active = state.activeClip
            let plan = try EditPlan.build(transcript: state.transcript, editState: state, activeClip: active,
                                          duration: project.media.source.durationSeconds, sampleRate: rate)
            func intervals(_ key: String) -> [MediaInterval] {
                row[key].array.map { MediaInterval(startSample: Int64($0.array[0].int), endSample: Int64($0.array[1].int)) }
            }
            #expect(plan.totalSamples == Int64(row["totalSamples"].int), "\(id)")
            #expect(plan.outputSamples == Int64(row["outputSamples"].int), "\(id)")
            #expect(plan.kept == intervals("kept"), "\(id)")
            #expect(plan.cuts == intervals("cuts"), "\(id)")
            #expect(plan.partSeams == row["partSeams"].array.map { Int64($0.int) }, "\(id)")
            #expect(state.pauses.map(\.id) == row["pauseIds"].array.map(\.string), "\(id)")
            let fades = plan.fadeParts.map { [$0.outputStart, $0.fadeIn, $0.fadeOut] }
            #expect(fades == row["fades"].array.map { $0.array.map { Int64($0.int) } }, "\(id)")
            #expect(try JSONDecoder().decode(EditPlan.self, from: JSONEncoder().encode(plan)) == plan, "\(id)")
            let scope = active.map { VoiceLabOutputScope.clip($0.id) } ?? .full
            let voice = try VoiceLabOutputPlanner.build(project, scope: scope)
            #expect(try RenderCallerInputs.editPlan(project: project, clipID: active?.id) == plan, "\(id)")
            #expect(voice.totalSourceSamples == plan.totalSamples, "\(id)")
            #expect(voice.outputSamples == plan.outputSamples, "\(id)")
            #expect(voice.partSeams == plan.partSeams, "\(id)")
            #expect(voice.pieces.map { MediaInterval(startSample: $0.sourceStartSample, endSample: $0.sourceEndSample) } == intervals("kept"), "\(id)")
            for timeline in [RenderTimeline.legacy(plan), .voiceLab(voice)] {
                let pieces = TimelinePieces(timeline)
                let seams = pieces.pieces.indices.filter(pieces.isRecordingSeam(at:)).map { Int((pieces.pieces[$0].edited.lowerBound * rate).rounded()) }
                #expect(seams == row["recordingSeams"].array.map(\.int), "\(id)")
            }
            for captions in [captionCopy(try buildSegments(state, activeClip: active), plan: plan), voice.captions] {
                #expect(captions.count == row["captions"].array.count, "\(id)")
                for (word, expected) in zip(captions, row["captions"].array.map(\.array)) {
                    #expect(word.id == expected[0].string && word.text == expected[1].string, "\(id)")
                    #expect(Int((word.start * rate).rounded()) == expected[2].int && Int((word.end * rate).rounded()) == expected[3].int, "\(id): \(word.id)")
                    #expect((word.startsPart == true) == expected[4].bool, "\(id): \(word.id)")
                }
            }
            let clock = ProjectClock.build(project)
            for (span, expected) in zip(plan.kept, row["sources"].array.map(\.array)) {
                let resolved = try #require(clock.resolve(Int(span.startSample)))
                #expect(resolved.key == expected[0].string && resolved.localSample == expected[1].int, "\(id)")
                #expect(resolved.localSample + Int(span.count) == expected[2].int, "\(id)")
                let middle = Double(span.startSample + span.count / 2) / rate
                #expect(plan.sourceTime(plan.mapTime(middle)) == middle, "\(id)")
                #expect(voice.sourceTime(voice.mapTime(middle)) == middle, "\(id)")
            }
        }
    }
}
