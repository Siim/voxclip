import Foundation
import Testing
@testable import VoxClipCore

@Suite(.offlineFixtures) struct RecordingClockFixtures {
    private func load() throws -> (FixtureValue, Project) {
        let data = try FixtureLoader.data("fixtures/recordings/clock-cases.json")
        let cases = FixtureValue(try JSONDecoder().decode(JSONValue.self, from: data))
        #expect(cases["schema"].string == "voxclip-recording-clock/1")
        let project = try JSONProjectStore.decode(FixtureLoader.data("fixtures/recordings/" + cases["project"].string))
        return (cases, project)
    }

    @Test func malformedSpokenSourcesAreRefusedOnBothReadPaths() throws {
        let (cases, project) = try load()
        let bytes = try ProjectJSON.encode(project)
        let document = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        for row in cases["invalidSpokenSources"].array {
            var invalid = document
            var media = try #require(invalid["media"] as? [String: Any])
            let base = try #require((media["spokenSources"] as? [[String: Any]])?.first)
            let overrides = try #require(row.object["overrides"])
            let replacement = try JSONSerialization.jsonObject(with: JSONEncoder().encode(overrides), options: .fragmentsAllowed)
            media["spokenSources"] = (replacement as? [[String: Any]])?.map { base.merging($0) { _, updated in updated } } as Any? ?? NSNull()
            invalid["media"] = media
            let input = try JSONSerialization.data(withJSONObject: invalid)
            #expect(throws: (any Error).self, "\(row["name"].string)") { try ProjectJSON.decode(input) }
            #expect(throws: (any Error).self, "\(row["name"].string)") { try JSONProjectStore.decode(input) }
        }
    }

    @Test func resolvesClockEdgesAndResamplesCompanionWords() throws {
        let (cases, project) = try load()
        let clock = ProjectClock.build(project)
        #expect(clock.sampleRate == cases["sampleRate"].int)
        try #require(clock.regions.count == cases["regions"].array.count)
        for (region, vector) in zip(clock.regions, cases["regions"].array) {
            #expect(region.key == vector["key"].string)
            #expect(region.label == vector["label"].string)
            #expect(region.prefix == vector["prefix"].string)
            #expect(region.offsetSamples == vector["offsetSamples"].int)
            #expect(region.durationSamples == vector["durationSamples"].int)
            #expect(region.gainDb == vector["gainDb"].number)
            #expect(region.colourIndex == vector["colourIndex"].int)
            #expect(clock.mapTime(key: region.key, localSample: -1) == nil)
            #expect(clock.mapTime(key: region.key, localSample: region.durationSamples) == nil)
        }
        #expect(clock.guardGaps.map { [$0.lowerBound, $0.upperBound] } == cases["guardGaps"].array.map { $0.array.map(\.int) })
        for row in cases["resolve"].array {
            let sample = row["clockSample"].int
            let expected = row["source"]
            if expected.isNull {
                #expect(clock.resolve(sample) == nil)
                #expect(clock.sourceTime(sample) == nil)
                continue
            }
            let resolved = try #require(clock.resolve(sample))
            let inverted = try #require(clock.sourceTime(sample))
            #expect(resolved.key == expected["key"].string && inverted.key == resolved.key)
            #expect(resolved.localSample == expected["localSample"].int && inverted.localSample == resolved.localSample)
            #expect(clock.mapTime(key: resolved.key, localSample: resolved.localSample) == sample)
            let rate = Double(clock.sampleRate)
            let local = try #require(clock.localTime(Double(sample) / rate))
            #expect(clock.clockTime(key: local.key, localSeconds: local.localSeconds) == Double(sample) / rate)
        }
        for row in cases["shiftedWords"].array {
            let word = try #require(clock.words.first { $0.id == row["id"].string })
            #expect(clock.region(of: word.id)?.prefix == "r2.")
            let samples = [word.start, word.end, word.rawStart, word.rawEnd].map { seconds in
                seconds.map { Int(EditingPrimitives.jsRound($0 * Double(clock.sampleRate))) }
            }
            #expect(samples == row["samples"].array.map { $0.isNull ? nil : $0.int })
        }
        let root = try #require(project.transcript)
        #expect(Array(clock.words.prefix(root.words.count)) == root.words)
    }

    @Test func resolvesEditsAndRefusesSelectionAcrossRecordings() throws {
        let (cases, project) = try load()
        let state = try #require(try EditState(project: project))
        let expected = cases["edits"]
        #expect(state.cutWordIds == Set(expected["cutWordIds"].array.map(\.string)))
        #expect(state.cutPauseIds == Set(expected["cutPauseIds"].array.map(\.string)))
        #expect(state.corrections == expected["corrections"].object.mapValues { FixtureValue($0).string })
        #expect(state.pauses.map(\.id) == ["pause-after-w1", "pause-after-r2.w1"])
        let corrected = try #require(state.transcript.words.first { $0.id == "r2.w1" })
        #expect(state.textOf(corrected) == "Report")
        #expect(try JSONProjectStore.decode(JSONProjectStore.encode(project)).edits == project.edits)
        let selection = cases["selection"]
        let part = ClipPart(id: "crosses", startWordId: selection["startWordId"].string, endWordId: selection["endWordId"].string)
        #expect(RecordingEdits.apply(.addPart(clipId: "clip-main", part: part), project: project).failure?.message == selection["refusal"].string)
        #expect(RecordingEdits.apply(.removeSpokenSource(key: cases["removal"]["removedKey"].string), project: project).failure?.message ==
                "Two recordings uses 1 part from 0010. Remove that part first.")
    }

    @Test func sourceTimelineOffersWordAnchorsInCompanionParts() throws {
        let (cases, project) = try load()
        let clock = ProjectClock.build(project)
        let plan = EditPlan(sampleRate: Double(clock.sampleRate), totalSamples: Int64(clock.totalSamples))
        let layout = TimelineItems.layout(project: project, plan: plan, scope: "clip-main", axis: .source)
        let expected = Double(cases["shiftedWords"].array[0]["samples"].array[0].int) / plan.sampleRate
        #expect(layout.snapTargets.contains { $0.kind == .word && $0.time == expected })
    }

    @Test func removingRecordingDoesNotCompactOrReusePrefix() throws {
        let (cases, original) = try load()
        let row = cases["removal"]
        let source = try #require(original.media.spokenSources?.first)
        var project = original
        project.edits = ProjectEdits()
        let removedKey = row["removedKey"].string
        let removed = try RecordingEdits.apply(.removeSpokenSource(key: removedKey), project: project).get()
        #expect(removed.undoName == "Remove recording")
        #expect(removed.project.media.additionalSources == project.media.additionalSources)
        let restored = try JSONProjectStore.decode(JSONProjectStore.encode(removed.project))
        #expect(restored.schemaVersion == 6 && restored.media.spokenSources == nil)
        let next = try RecordingEdits.apply(.addSpokenSource(key: row["nextKey"].string, transcript: source.transcript), project: restored).get()
        #expect(next.undoName == "Add recording")
        #expect(next.project.media.spokenSources?.first?.wordIdPrefix == row["survivingPrefix"].string)
        #expect(ProjectClock.build(next.project).region(of: "r2.w1") == nil)
        let readded = try RecordingEdits.apply(.addSpokenSource(key: removedKey, transcript: source.transcript), project: next.project).get().project
        let region = try #require(readded.media.spokenSources?.last)
        #expect(region.wordIdPrefix == row["readdedPrefix"].string)
        #expect(region.offsetSeconds == row["afterBothOffset"].int)
        let withoutFirst = try RecordingEdits.apply(.removeSpokenSource(key: row["nextKey"].string), project: readded).get().project
        #expect(withoutFirst.media.spokenSources == [region])
    }

    @Test func singleRegionPreservesEveryRootTranscriptValue() throws {
        let (_, original) = try load()
        var seed: UInt64 = 3101
        func random() -> Double {
            seed = 1_664_525 &* seed &+ 1_013_904_223
            return Double(seed & 0xffff) / 65_536
        }
        for run in 0..<64 {
            var project = original
            project.media.spokenSources = nil
            project.schemaVersion = 6
            var root = try #require(project.transcript)
            root.words = (0..<run).map { index in
                let start = Double(index) + random() * 0.2
                return TimedWord(id: "local.\(index)", text: "Word", start: start, end: start + 0.3 + random() * 0.2,
                                 rawStart: max(0, start - 0.001), rawEnd: start + 0.5)
            }
            root.durationSeconds = Double(run) + random()
            project.transcript = root
            let clock = ProjectClock.build(project)
            #expect(clock.transcript == root)
            #expect(clock.regions.count == 1)
        }
    }

    @Test func reordersAndTrimsPartsWithoutMovingSourceEdits() throws {
        let (_, project) = try load()
        let clip = try #require(project.edits.clips.first)
        let part = clip.playParts[0]
        let reordered = try RecordingEdits.apply(.movePart(clipId: clip.id, partId: part.id, afterPartId: clip.playParts[1].id), project: project).get()
        #expect(reordered.undoName == "Move part")
        #expect(reordered.project.edits.clips[0].playParts == Array(clip.playParts.reversed()))
        let trimmed = try RecordingEdits.apply(.trimPart(clipId: clip.id, partId: part.id, startWordId: "r2.w1", endWordId: "r2.w1"), project: reordered.project).get()
        #expect(trimmed.undoName == "Trim part")
        #expect(trimmed.project.edits.clips[0].playParts[1].reframe == part.reframe)
        let removed = try RecordingEdits.apply(.removePart(clipId: clip.id, partId: part.id), project: trimmed.project).get()
        #expect(removed.undoName == "Remove part")
        #expect(removed.project.edits.clips[0].playParts[0].startWordId == "w1")
        #expect(removed.project.edits.cutWordIds == project.edits.cutWordIds)
        #expect(removed.project.edits.corrections == project.edits.corrections)
        let added = try RecordingEdits.apply(.addPart(clipId: clip.id, part: part, afterPartId: clip.id), project: removed.project).get()
        #expect(added.undoName == "Add part")
        #expect(added.project.edits.clips[0].playParts[1] == part)
    }
}

private extension Result where Failure == RecordingEditRefusal {
    var failure: Failure? { if case .failure(let refusal) = self { return refusal }; return nil }
}
