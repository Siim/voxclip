import Foundation
import Testing
@testable import VoxClipCore

@Suite struct EditingProperties {
    @Test func reducerRejectsUnsavableTextAndClipIDs() throws {
        var project = try EditingPersistence().project("clip-from-long-take")
        project.edits.clips = []
        project.edits.activeClipId = nil
        project.share.captions = [:]
        let initial = try EditState(transcript: #require(project.transcript), edits: project.edits)
        let wordID = initial.transcript.words[0].id
        let resultID = try #require(project.ai.results.first).id
        let validTitle = String(repeating: "👩‍💻", count: 40)
        let longTitle = validTitle + "x"
        let longCorrection = String(repeating: "👩‍💻", count: 67)
        #expect(longTitle.count < EditingLimits.maxClipTitleScalars)
        #expect(longCorrection.count < EditingLimits.maxCorrectionScalars)
        func checkEncodes(_ state: EditState) throws {
            var snapshot = project
            snapshot.edits = state.projectEdits
            #expect(try JSONProjectStore.decode(ProjectJSON.encode(snapshot)) == snapshot)
            #expect(try JSONProjectStore.decode(JSONProjectStore.encode(snapshot)) == snapshot)
        }
        let rejected = EditReducer.reduce(initial, command: .correct(id: wordID, text: longCorrection))
        #expect(rejected == initial)
        try checkEncodes(rejected)
        let correction = String(repeating: "👍🏽", count: 100)
        let corrected = EditReducer.reduce(initial, command: .correct(id: wordID, text: correction))
        #expect(corrected.corrections[wordID] == correction)
        try checkEncodes(corrected)
        for id in ["", "bad/id", "é", "a\n", String(repeating: "a", count: 65)] {
            let clip = ClipRange(id: id, startWordId: wordID, endWordId: wordID)
            for command in [EditCommand.addClip(clip), .addAIClips(resultId: resultID, clips: [clip]), .renameClip(id: id, title: "title")] {
                let reduced = EditReducer.reduce(initial, command: command)
                #expect(reduced == initial)
                try checkEncodes(reduced)
            }
            let invalidReference = ClipRange(id: "bad-reference", startWordId: wordID, endWordId: wordID, aiResultId: id, aiClipIndex: 0)
            #expect(EditReducer.reduce(initial, command: .addClip(invalidReference)) == initial)
            #expect(EditReducer.reduce(initial, command: .addAIClips(resultId: id, clips: [clip])) == initial)
        }
        let negativeIndex = ClipRange(id: "negative-index", startWordId: wordID, endWordId: wordID, aiResultId: resultID, aiClipIndex: -1)
        #expect(EditReducer.reduce(initial, command: .addClip(negativeIndex)) == initial)
        let invalid = ClipRange(id: "invalid-title", startWordId: wordID, endWordId: wordID, title: longTitle)
        for command in [EditCommand.addClip(invalid), .addAIClips(resultId: resultID, clips: [invalid])] {
            let reduced = EditReducer.reduce(initial, command: command)
            #expect(reduced == initial)
            try checkEncodes(reduced)
        }
        let valid = ClipRange(id: String(repeating: "a", count: 64), startWordId: wordID, endWordId: wordID, title: validTitle)
        for command in [EditCommand.addClip(valid), .addAIClips(resultId: resultID, clips: [invalid, valid])] {
            let reduced = EditReducer.reduce(initial, command: command)
            #expect(reduced.clips.count == 1 && reduced.clips[0].title == validTitle)
            try checkEncodes(reduced)
            let renamed = EditReducer.reduce(reduced, command: .renameClip(id: valid.id, title: "  " + longTitle + "  "))
            #expect(renamed == reduced)
            try checkEncodes(renamed)
            let allowed = EditReducer.reduce(reduced, command: .renameClip(id: valid.id, title: "  " + validTitle + "  "))
            #expect(allowed.clips[0].title == validTitle)
            try checkEncodes(allowed)
        }
    }

    @Test func contextualReducerRejectsAIIndicesOutsideTheReferencedResult() throws {
        var project = try EditingPersistence().project("clip-from-long-take")
        project.edits.clips = []
        project.edits.activeClipId = nil
        project.share.captions = [:]
        let initial = try EditState(transcript: #require(project.transcript), edits: project.edits)
        let wordID = initial.transcript.words[0].id
        let result = try #require(project.ai.results.first)
        var history = EditHistory(state: initial)
        history.apply(.toggle(id: wordID), aiResults: project.ai.results)
        history.undo()
        let historyBeforeRejection = history
        #expect(history.canRedo && history.undoStates.isEmpty)
        let references: [(String?, Int?)] = [(result.id, -1), (result.id, result.clips.count), (result.id, .max),
                                             ("missing-result", 0), (nil, 0), ("bad/id", 0)]
        for (id, index) in references {
            let clip = ClipRange(id: "invalid-reference", startWordId: wordID, endWordId: wordID, aiResultId: id, aiClipIndex: index)
            let command = EditCommand.addClip(clip)
            #expect(EditReducer.reduce(initial, command: command, aiResults: project.ai.results) == initial)
            var snapshot = project
            try snapshot.applyEditing(command)
            #expect(snapshot == project)
            history.apply(command, aiResults: project.ai.results)
            #expect(history == historyBeforeRejection)
            #expect(history.state.projectEdits == snapshot.edits)
        }
        let prepared = (0...result.clips.count).map { index in
            ClipRange(id: "prepared-\(index)", startWordId: wordID, endWordId: wordID)
        }
        for command in [EditCommand.addAIClips(resultId: result.id, clips: prepared), .addAIClips(resultId: "missing-result", clips: [prepared[0]])] {
            #expect(EditReducer.reduce(initial, command: command, aiResults: project.ai.results) == initial)
            var snapshot = project
            try snapshot.applyEditing(command)
            #expect(snapshot == project)
            history.apply(command, aiResults: project.ai.results)
            #expect(history == historyBeforeRejection)
            #expect(history.state.projectEdits == snapshot.edits)
        }
        let lastIndex = try #require(result.clips.indices.last)
        let valid = ClipRange(id: "valid-reference", startWordId: wordID, endWordId: wordID, origin: .ai, aiResultId: result.id, aiClipIndex: lastIndex)
        let reduced = EditReducer.reduce(initial, command: .addClip(valid), aiResults: project.ai.results)
        #expect(reduced.clips == [valid])
        try project.applyEditing(.addClip(valid))
        #expect(project.edits == reduced.projectEdits)
        history.apply(.addClip(valid), aiResults: project.ai.results)
        #expect(history.state == reduced && history.state.projectEdits == project.edits)
        #expect(history.undoStates == [initial] && history.redoStates.isEmpty)
        history.undo()
        #expect(history.state == initial)
        history.redo()
        #expect(history.state == reduced)
        #expect(try JSONProjectStore.decode(JSONProjectStore.encode(project)) == project)
        let batchCommand = EditCommand.addAIClips(resultId: result.id, clips: [prepared[0]])
        let batch = EditReducer.reduce(initial, command: batchCommand, aiResults: project.ai.results)
        #expect(batch.clips.count == 1 && batch.clips[0].aiResultId == result.id && batch.clips[0].aiClipIndex == 0)
        project.edits = initial.projectEdits
        try project.applyEditing(batchCommand)
        history.undo()
        history.apply(batchCommand, aiResults: project.ai.results)
        #expect(history.state == batch && history.state.projectEdits == project.edits)
        #expect(history.undoStates == [initial] && history.redoStates.isEmpty)
        history.undo()
        #expect(history.state == initial)
        history.redo()
        #expect(history.state == batch)
    }

    @Test func singleKeptRangeFadesAtBothClipEdges() throws {
        let plan = try buildEditPlan([
            EditSegment(id: "head", kind: .range, start: 0, end: 0.5, cut: true),
            EditSegment(id: "tail", kind: .range, start: 1.5, end: 2, cut: true)
        ], duration: 2, sampleRate: 1000)
        #expect(plan.joins == [Join(outSample: 0, fadeOutLen: 0, fadeInLen: 5), Join(outSample: 1000, fadeOutLen: 5, fadeInLen: 0)])
        for sample in -1...plan.outputSamples {
            #expect(EditingFixtures().gainFromJoins(plan.joins, at: sample) == plan.joinGain(at: sample))
        }
        let decoded = try JSONDecoder().decode(EditPlan.self, from: JSONEncoder().encode(plan))
        #expect(decoded == plan)
        #expect(decoded.fadeParts == plan.fadeParts)
        var changed = decoded
        changed.kept = [MediaInterval(startSample: 0, endSample: changed.totalSamples)]
        #expect(changed.fadeParts == [FadePart(outputStart: 0, length: 2000, fadeIn: 0, fadeOut: 0)])
    }

    @Test func indexedCutRangesMatchReferenceExactly() throws {
        var seed: UInt64 = 91
        func next(_ limit: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 32) % UInt64(limit))
        }
        let segments = (0..<500).map { position in
            let start = Double(next(100)) / 10
            return EditSegment(id: "segment-\(position)", kind: position % 4 == 0 ? .pause : .word,
                               start: start, end: start + Double(1 + next(50)) / 10, cut: next(2) == 0)
        }
        let index = CutRangeIndex(segments), speech = speechIndices(segments)
        for position in segments.indices {
            let segment = segments[position]
            let expected: TimeRange
            if segment.kind == .pause {
                var before: EditSegment?
                for position in speech {
                    let word = segments[position]
                    if word.end <= segment.start + 1e-6, before == nil || word.end > before!.end { before = word }
                }
                let after = speech.first { segments[$0].start >= segment.end - 1e-6 }.map { segments[$0] }
                expected = TimeRange(start: segment.start + (before.map { !$0.cut } == true ? 0.15 : 0),
                                     end: segment.end - (after.map { !$0.cut } == true ? 0.15 : 0))
            } else {
                let rank = try #require(speech.firstIndex(of: position))
                let earlierEnd = speech.prefix(rank).reduce(0.0) { max($0, segments[$1].end) }
                let nextStart = rank + 1 < speech.count ? segments[speech[rank + 1]].start : 20
                expected = earlierEnd >= segment.end ? TimeRange(start: segment.start, end: segment.end) :
                    TimeRange(start: segment.start - min(0.1, max(0, segment.start - earlierEnd) / 2),
                              end: segment.end + min(0.1, max(0, nextStart - segment.end) / 2))
            }
            let actual = rawCutRange(at: position, segments: segments, index: index, duration: 20, pauseKeep: 0.15)
            #expect(actual.start == expected.start)
            #expect(actual.end == expected.end)
        }
    }

    @Test func rawRangeComparisonAcceptsSignedZero() {
        let negativeZero = -Double.zero
        #expect(negativeZero.sign == .minus)
        EditingFixtures().compare(.init(.number(0)), .init(.number(negativeZero)), path: "expected.segmentCuts[0].rawStart")
        EditingFixtures().compare(.init(.number(negativeZero)), .init(.number(0)), path: "expected.segmentCuts[0].rawEnd")
    }

    @Test func derivedPlanValuesStayConsistentAfterInitializationDecodingAndMutation() throws {
        func check(_ plan: EditPlan) {
            #expect(plan.outputSamples == plan.kept.reduce(0) { $0 + $1.count })
            for sample in -2...(plan.outputSamples + 2) {
                #expect(EditingFixtures().gainFromJoins(plan.joins, at: sample) == plan.joinGain(at: sample))
            }
        }
        var plan = EditPlan(sampleRate: 1000, totalSamples: 3000,
                            kept: [MediaInterval(startSample: 500, endSample: 1500), MediaInterval(startSample: 2000, endSample: 2500)])
        #expect(plan.outputSamples == 1500)
        check(plan)
        let raw = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(plan))
        guard case .object(var object) = raw else { Issue.record("Expected plan object"); return }
        object["outputSamples"] = .number(1)
        object["joins"] = .array([.object(["outSample": .number(42), "fadeOutLen": .number(99), "fadeInLen": .number(99)])])
        let stale = try JSONDecoder().decode(EditPlan.self, from: JSONEncoder().encode(JSONValue.object(object)))
        #expect(stale == plan)
        check(stale)
        object.removeValue(forKey: "joins")
        let decoded = try JSONDecoder().decode(EditPlan.self, from: JSONEncoder().encode(JSONValue.object(object)))
        #expect(decoded == plan)
        check(decoded)
        plan.sampleRate = 48000
        check(plan)
        plan.totalSamples = 2500
        check(plan)
        plan.kept = [MediaInterval(startSample: 0, endSample: 700), MediaInterval(startSample: 2000, endSample: 2500)]
        check(plan)
        plan.outputSamples = -1
        plan.joins = []
        check(plan)
        plan.kept = []
        #expect(plan.joins.isEmpty && plan.fadeParts.isEmpty && plan.outputSamples == 0)
        check(plan)
    }

    @Test(arguments: [Int64(1), Int64(95998)])
    func canonicalPlanInitializerDerivesZeroLengthFadeSides(firstPartLength: Int64) {
        let kept = [MediaInterval(startSample: 0, endSample: firstPartLength),
                    MediaInterval(startSample: firstPartLength + 1, endSample: 96000)]
        let plan = EditPlan(sampleRate: 48000, totalSamples: 96000,
                            cuts: [MediaInterval(startSample: firstPartLength, endSample: firstPartLength + 1)], kept: kept)
        let fadeOut: Int64 = firstPartLength == 1 ? 0 : 240
        let fadeIn: Int64 = firstPartLength == 1 ? 240 : 0
        #expect(plan.kept == kept)
        #expect(plan.outputSamples == 95999)
        #expect(plan.joins == [Join(outSample: firstPartLength, fadeOutLen: fadeOut, fadeInLen: fadeIn)])
        #expect(plan.joinGain(at: firstPartLength - 1) == (fadeOut == 0 ? 1 : 0))
        #expect(plan.joinGain(at: firstPartLength) == (fadeIn == 0 ? 1 : 0))
        let identity = EditPlan(sampleRate: 48000, totalSamples: 48000,
                                kept: [MediaInterval(startSample: 0, endSample: 48000)])
        #expect(identity.outputSamples == 48000 && identity.duration == 1 && identity.joins.isEmpty)
    }

    @Test func mappingsAreExactMonotoneOnSampleGrid() throws {
        var seed: UInt64 = 8128
        func next(_ limit: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 32) % UInt64(limit))
        }
        for index in 0..<300 {
            let rate = [1000.0, 16000, 44100, 48000][index % 4]
            let total = 500 + next(1500)
            let cuts = (0..<next(15)).map { position -> EditSegment in
                let first = next(total + 200) - 100, length = 1 + next(300)
                return EditSegment(id: "r\(position)", kind: .range, start: Double(first) / rate, end: Double(first + length) / rate, cut: true)
            }
            let plan = try buildEditPlan(cuts, duration: Double(total) / rate, sampleRate: rate)
            #expect(plan.kept.reduce(0) { $0 + $1.count } + plan.cuts.reduce(0) { $0 + $1.count } == plan.totalSamples)
            for pair in zip(plan.cuts, plan.cuts.dropFirst()) { #expect(pair.0.endSample < pair.1.startSample) }
            for sample in 0..<plan.outputSamples {
                let edited = Double(sample) / rate
                #expect(plan.mapTime(plan.sourceTime(edited)) == edited)
            }
            var previous = -1.0
            for sample in 0...plan.totalSamples {
                let source = Double(sample) / rate, edited = plan.mapTime(source)
                #expect(edited >= previous)
                previous = edited
                if plan.cutContaining(source) == nil { #expect(plan.sourceTime(edited) == source) }
            }
            for interval in plan.kept.dropFirst() {
                let source = Double(interval.startSample) / rate
                #expect(plan.sourceTime(plan.mapTime(source)) == source)
            }
        }
    }

    @Test func captionSweepPreservesInputOrderAndMapsOverlappingBoundariesExactly() throws {
        var seed: UInt64 = 4021
        func next(_ limit: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 32) % UInt64(limit))
        }
        for iteration in 0..<300 {
            let rate = [1.0, 1000, 44100, 48000][iteration % 4]
            var segments = (0..<100).map { index in
                let start = Double(next(2000) - 100) / rate
                return EditSegment(id: "word-\(index)", kind: index % 7 == 0 ? .pause : .word,
                                   wordKind: index % 11 == 0 ? .event : .word, text: "text-\(index)",
                                   start: start, end: start + Double(next(500)) / rate, cut: next(3) == 0)
            }
            segments += [EditSegment(id: "zero", kind: .word, start: -0.0, end: 1 / rate, cut: false),
                         EditSegment(id: "invalid", kind: .word, start: .nan, end: .infinity, cut: false)]
            let plan = try buildEditPlan(segments, duration: 2000 / rate, sampleRate: rate)
            let expected = segments.compactMap { segment -> CaptionWord? in
                guard segment.kind == .word, segment.wordKind == .word, !segment.cut, validSegment(segment) else { return nil }
                let start = plan.mapTime(segment.start), end = plan.mapTime(segment.end)
                return end > start ? CaptionWord(id: segment.id, text: segment.text, start: start, end: end) : nil
            }
            #expect(captionCopy(segments, plan: plan) == expected)
            #expect(captionCopy([], plan: plan).isEmpty)
        }
        let samples: [Int64] = [.max, 1 << 32, 0, 1 << 48, 255, 256, 0, .max - 1]
        #expect(orderedCaptionBoundaries(samples).map { samples[$0] } == samples.sorted())
    }

    @Test func plannerRejectsInvalidMediaAndUncutRanges() {
        for (duration, rate) in [(Double.nan, 48000.0), (.infinity, 48000), (-1, 48000), (1, 0), (1, .nan), (1, .infinity), (.greatestFiniteMagnitude, 48000)] {
            #expect(throws: VoxClipError.self) { try buildEditPlan([], duration: duration, sampleRate: rate) }
        }
        #expect(throws: VoxClipError.self) { try buildEditPlan([EditSegment(id: "exact", kind: .range, start: 0, end: 1, cut: false)], duration: 2, sampleRate: 48000) }
    }

    @Test func fixedOneAIConformance() {
        let cases: [(Double, String)] = [(0.05, "0.1"), (0.15, "0.1"), (0.25, "0.3"), (0.35, "0.3"), (0.45, "0.5"), (1.25, "1.3"),
                                         (1.45, "1.4"), (2.05, "2.0"), (2.25, "2.3"), (9.95, "9.9"), (99.95, "100.0"),
                                         (1.2499999999999998, "1.2"), (1.2500000000000002, "1.3"), (.leastNonzeroMagnitude, "0.0"), (4503599627370496, "4503599627370496.0"),
                                         (1e21, "1e+21"), (.greatestFiniteMagnitude, "1.7976931348623157e+308")]
        for (value, expected) in cases { #expect(toFixed1(value) == expected) }
    }

    @Test func analysisDerivesNativeFrameLengthInsteadOfEnvelopeHint() throws {
        for rate in [22050.0, 44101, 48000, 25] {
            let frameLength = max(1, EditingPrimitives.jsRound(rate * 0.01)) / rate
            let words = [TimedWord(id: "word", text: "speech", start: 20 * frameLength, end: 30 * frameLength)]
            var levels = Array(repeating: Float(0), count: 100)
            for frame in 15..<35 { levels[frame] = 1 }
            let canonical = AudioEnvelope(sampleRate: rate, frameSeconds: frameLength, levels: levels)
            let expected = try refineWordBoundaries(words, envelope: canonical)
            #expect(expected[0].start < words[0].start)
            for hint in [0.01, 0.5, 0, Double.nan] {
                let mismatched = AudioEnvelope(sampleRate: rate, frameSeconds: hint, levels: levels)
                let analysis = try #require(LevelAnalysis(words: words, envelope: mismatched))
                #expect(analysis.frameLength.bitPattern == frameLength.bitPattern)
                #expect(analysis.total == Double(levels.count) * frameLength)
                #expect(try refineWordBoundaries(words, envelope: mismatched) == expected)
                #expect(EditingImport.tightenIntoSound(words, envelope: mismatched, timing: .runGrouped) == EditingImport.tightenIntoSound(words, envelope: canonical, timing: .runGrouped))
                #expect(EditingImport.findUnlabeledSpeech(words, envelope: mismatched) == EditingImport.findUnlabeledSpeech(words, envelope: canonical))
            }
        }
    }

    @Test func fixedOneMatches100000NodeReferenceValues() {
        var seed = 7.0
        var text = ""
        for _ in 0..<100_000 {
            seed = (seed * 16807).truncatingRemainder(dividingBy: 2147483647)
            let value = (seed / 2147483647) * 10000
            text += toFixed1(value) + "\n"
        }
        #expect(SourceContentKey.sha256(Data(text.utf8)) == "dd930b4b793b0dab42e210c8c6c02155ed3dac31d805aff9e295f6f1f0b4b41d")
    }

    @Test func historyRestoresSnapshotsAndInvalidatesRedo() throws {
        let runner = EditingFixtures()
        let words = [TimedWord(id: "pause-misleading", text: "um", start: 0.1, end: 0.5), TimedWord(id: "next", text: "next", start: 2, end: 2.5)]
        let transcript = runner.transcript(words, duration: 3)
        var history = EditHistory(state: EditState(transcript: transcript, pauses: try detectPauses(words, thresholdSeconds: 0.8)))
        let initial = history.state
        history.apply(.cutSelection(ids: [words[0].id, "pause-after-pause-misleading"]))
        #expect(history.state.cutWordIds == [words[0].id])
        #expect(history.state.cutPauseIds == ["pause-after-pause-misleading"])
        history.apply(.correct(id: words[1].id, text: "  going to  "))
        let corrected = history.state
        history.undo(); history.undo()
        #expect(history.state == initial)
        history.redo(); history.redo()
        #expect(history.state == corrected)
        history.undo(); history.apply(.restoreSelection(ids: [words[0].id]))
        #expect(!history.canRedo)
        #expect(history.state.transcript == initial.transcript)
        for _ in 0..<550 { history.apply(.toggle(id: words[0].id)) }
        #expect(history.undoStates.count == 500)
    }

    @Test func rangeLayerScopeAndClipMutations() throws {
        let items = [TimedWord(id: "a", text: "um", start: 0.1, end: 0.5), TimedWord(id: "b", text: "word", start: 2, end: 2.5),
                     TimedWord(id: "c", text: "um", start: 4, end: 4.5), TimedWord(id: "d", text: "end", start: 6, end: 6.5)]
        var state = EditState(transcript: EditingFixtures().transcript(items, duration: 7), pauses: try detectPauses(items, thresholdSeconds: 0.8))
        let clip = ClipRange(id: "clip", startWordId: "b", endWordId: "c", selected: false)
        state = EditReducer.reduce(state, command: .addClip(clip))
        #expect(state.clips[0].selected)
        state = EditReducer.reduce(state, command: .setActiveClip(clipId: "clip"))
        state = EditReducer.reduce(state, command: .cutFillers)
        #expect(state.cutWordIds == ["c"])
        state = EditReducer.reduce(state, command: .tightenPauses)
        #expect(state.cutPauseIds == ["pause-after-b"])
        state = EditReducer.reduce(state, command: .correct(id: "b", text: "o\u{303}"))
        #expect(state.corrections["b"] == "õ")
        state = EditReducer.reduce(state, command: .restoreCuts)
        #expect(state.cutWordIds.isEmpty && state.cutPauseIds.isEmpty)
        #expect(state.corrections["b"] == "õ")
        state = EditReducer.reduce(state, command: .renameClip(id: "clip", title: " \n "))
        #expect(state.clips[0].title == nil)
        state = EditReducer.reduce(state, command: .updateClip(id: "clip", startIndex: 0, endIndex: 2))
        #expect(state.clips[0].startWordId == "a")
        state = EditReducer.reduce(state, command: .setClipSelected(id: "clip", selected: false))
        #expect(!state.clips[0].selected)
        state = EditReducer.reduce(state, command: .addAIClips(resultId: "ai", clips: [ClipRange(id: "duplicate", startWordId: "a", endWordId: "c"), ClipRange(id: "new", startWordId: "b", endWordId: "d")]))
        #expect(state.clips.count == 2 && state.clips[1].aiClipIndex == 1)
        state = EditReducer.reduce(state, command: .removeClip(id: "clip"))
        #expect(state.activeClipId == nil && state.clips.count == 1)
        #expect(state.corrections["b"] == "õ")
    }

    @Test func thresholdCorrectionAndBulkRestore() throws {
        let items = [TimedWord(id: "event", text: "(laugh)", kind: .event, start: 0, end: 0.2),
                     TimedWord(id: "a", text: "word", start: 1.2, end: 1.5), TimedWord(id: "b", text: "…", kind: .unlabeledSpeech, start: 2.8, end: 3)]
        var state = EditState(transcript: EditingFixtures().transcript(items, duration: 4), pauses: try detectPauses(items, thresholdSeconds: 0.8))
        state = EditReducer.reduce(state, command: .correct(id: "event", text: "um"))
        #expect(state.corrections.isEmpty)
        state = EditReducer.reduce(state, command: .correct(id: "a", text: "um"))
        state = EditReducer.reduce(state, command: .cutFillers)
        #expect(state.cutWordIds == ["a", "b"])
        state = EditReducer.reduce(state, command: .correct(id: "a", text: "word"))
        #expect(state.corrections.isEmpty)
        state = EditReducer.reduce(state, command: .tightenPauses)
        state = EditReducer.reduce(state, command: .setPauseThreshold(seconds: 1.1))
        #expect(state.cutPauseIds == ["pause-after-a"])
        state = EditReducer.reduce(state, command: .setPauseKeep(seconds: 0.05))
        #expect(state.pauseKeepSeconds == 0.05)
        let snapshot = state
        state = EditReducer.reduce(state, command: .setPauseKeep(seconds: .nan))
        state = EditReducer.reduce(state, command: .setPauseThreshold(seconds: -1))
        #expect(state == snapshot)
        state = EditReducer.reduce(state, command: .cutSelection(ids: ["a", "b"]))
        #expect(state.cutWordIds.isEmpty)
    }
}
