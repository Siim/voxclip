import Foundation
import Testing
@testable import VoxClipCore

/// `fit-cases.json` (tools/fixtures/voice-lab/generate_fit.py, run by generate.py). JSONDecoder keeps binary64 numbers
/// exactly. Words are `[text, start, end]`, envelope runs `[level, count]` and edits `[kind, start, count]`.
private struct FitDocument: Decodable {
    var schema: String
    var constants: [String: Double]
    var categories: [String: Int]
    var cases: [FitCase]
    var propertyFuzz: FitFuzz
    var propertyCases: [FitCase]
    var caseCount: Int
}

private struct FitFuzz: Decodable {
    var seed: Int
    var cases: Int
}

private struct FitCase: Decodable {
    var name: String
    var input: FitInput
    var expected: FitExpected
}

private struct FitInput: Decodable {
    var sourceSampleRate: Double
    var window: FitWindow
    var incomingSilence: Double?
    var outgoingSilence: Double?
    var take: FitTakeInput
    var tokens: [String]
}

private struct FitWindow: Decodable {
    var startSample: Int64
    var endSample: Int64
    var leftKind: String
    var rightKind: String
    var start: Double?
    var end: Double?
}

private struct FitTakeInput: Decodable {
    var assetFrames: Int64
    var assetSampleRate: Int
    var trimStart: Double
    var trimEnd: Double
    var words: [FitWordRow]
    var envelope: FitEnvelope
}

private struct FitEnvelope: Decodable {
    var sampleRate: Double
    var runs: [[Double]]
}

private struct FitWordRow: Decodable {
    var text: String
    var start: Double
    var end: Double
    init(from decoder: any Decoder) throws {
        var row = try decoder.unkeyedContainer()
        text = try row.decode(String.self); start = try row.decode(Double.self); end = try row.decode(Double.self)
    }
}

private struct FitEditRow: Decodable, Equatable {
    var kind: String
    var start: Int64
    var count: Int64
    init(kind: String, start: Int64, count: Int64) { self.kind = kind; self.start = start; self.count = count }
    init(from decoder: any Decoder) throws {
        var row = try decoder.unkeyedContainer()
        kind = try row.decode(String.self); start = try row.decode(Int64.self); count = try row.decode(Int64.self)
    }
}

private struct FitExpected: Decodable {
    var error: String?
    var result: String?
    var naturalOut: Double?
    var residualSeconds: Double?
    var edits: [FitEditRow]?
    var incoming: [Int64]?
    var outgoing: [Int64]?
    var trims: [Int64]?
    var window: [Int64]?
    var outputFrames: Int64?
    var windowStart: Double?
    var windowEnd: Double?
    var words: [[Double]]?
}

/// The shared fit vectors on this Core: every named and property case, each with the §8.9.2 properties checked again
/// on the plan this Core returns.
@Suite("Voice Lab fit planner")
struct VoiceLabFitPlannerTests {
    private static let document: FitDocument? = try? JSONDecoder().decode(FitDocument.self,
                                                                          from: FixtureLoader.data("fixtures/voice-lab/fit-cases.json"))

    private func kind(_ name: String) -> VoiceLabSeamKind { VoiceLabSeamKind(rawValue: name) ?? VoiceLabSeamKind.none }

    private func window(_ input: FitInput) -> VoiceLabWindow {
        let rate = input.sourceSampleRate, value = input.window
        // The planner reads only a seam's kind and sample. A rate it refuses can be too high to convert a fade at.
        let convertible = rate * VoiceLabPatchConstants.SEAM_FADE < VoiceLabGeometry.sampleLimit
        func seam(_ name: String, _ sample: Int64, _ time: Double) -> VoiceLabSeamPlacement {
            let fade: Int64 = switch kind(name) {
            case .gap where convertible: VoiceLabGeometry.samples(VoiceLabPatchConstants.SEAM_FADE, rate)
            case .hard where convertible: VoiceLabGeometry.samples(VoiceLabPatchConstants.HARD_SEAM_FADE, rate)
            default: 0
            }
            return VoiceLabSeamPlacement(kind: kind(name), time: time, sample: sample, fadeSamples: fade)
        }
        let start = value.start ?? Double(value.startSample) / rate, end = value.end ?? Double(value.endSample) / rate
        return VoiceLabWindow(firstWordId: "w0", lastWordId: "w0", leftBridgeWordIds: [], rightBridgeWordIds: [], start: start,
                              end: end, startSample: value.startSample, endSample: value.endSample,
                              leftSeam: seam(value.leftKind, value.startSample, start), rightSeam: seam(value.rightKind, value.endSample, end))
    }

    private func take(_ input: FitInput) -> VoiceLabFitTake {
        let value = input.take
        let levels: [Float] = value.envelope.runs.flatMap { run in Array(repeating: Float(run[0]), count: Int(run[1])) }
        // Provider words arrive unmarked, so every replay shows that the planner marks its words synthetic.
        let words: [VoiceLabWord] = value.words.map { VoiceLabWord(text: $0.text, start: $0.start, end: $0.end, synthetic: false) }
        return VoiceLabFitTake(assetFrames: value.assetFrames, assetSampleRate: value.assetSampleRate, trimStart: value.trimStart,
                               trimEnd: value.trimEnd, words: words,
                               envelope: AudioEnvelope(sampleRate: value.envelope.sampleRate, levels: levels))
    }

    private func code(_ error: VoiceLabGeometryError) -> String {
        switch error {
        case .invalidInput(nil): "invalidInput"
        case .alignmentUnavailable: "alignmentUnavailable"
        case .alignmentMismatch: "alignmentMismatch"
        case .invalidWordTiming: "invalidWordTiming"
        case .fitTouchesVoice: "fitTouchesVoice"
        default: "\(error)"
        }
    }

    private func plan(_ input: FitInput) throws -> VoiceLabFitResult {
        try VoiceLabFitPlanner.plan(window: window(input), incomingSilence: input.incomingSilence, outgoingSilence: input.outgoingSilence,
                                    take: take(input), tokens: input.tokens, sourceSampleRate: input.sourceSampleRate)
    }

    /// Replays one vector: its typed refusal, or its plan field by field. Named vectors also carry the window times and
    /// word times; property cases leave them to the formulas `checkProperties` applies to every plan.
    private func replay(_ test: FitCase) {
        let name = test.name, expected = test.expected
        let result: VoiceLabFitResult
        do {
            result = try plan(test.input)
        } catch let error as VoiceLabGeometryError {
            #expect(code(error) == expected.error, "\(name)")
            return
        } catch {
            Issue.record("\(name): \(error)")
            return
        }
        guard expected.error == nil else { Issue.record("\(name): expected \(expected.error ?? "")"); return }
        let plan = result.plan
        switch result {
        case .exact:
            #expect(expected.result == "exact", "\(name)")
        case let .changedDuration(_, naturalOut, residualSeconds):
            #expect(expected.result == "changedDuration" && expected.naturalOut == naturalOut
                    && expected.residualSeconds == residualSeconds, "\(name)")
        }
        let edits: [FitEditRow] = plan.edits.map { FitEditRow(kind: $0.kind.rawValue, start: $0.start, count: $0.count) }
        #expect(expected.edits == edits, "\(name)")
        #expect(expected.incoming == [plan.incoming.padFrames, plan.incoming.borrowedSamples], "\(name)")
        #expect(expected.outgoing == [plan.outgoing.padFrames, plan.outgoing.borrowedSamples], "\(name)")
        #expect(expected.trims == [plan.trimStartFrame, plan.trimEndFrame], "\(name)")
        #expect(expected.window == [plan.windowStartSample, plan.windowEndSample], "\(name)")
        #expect(expected.outputFrames == plan.outputFrames, "\(name)")
        if let words = expected.words {
            #expect(words == plan.words.map { [$0.start, $0.end] }, "\(name)")
            #expect(expected.windowStart == plan.windowStart && expected.windowEnd == plan.windowEnd, "\(name)")
        }
        checkProperties(result, test.input, name)
    }

    /// §8.9.2 on one plan, derived from the plan and the input alone, as generate_fit.py checks them: no edit or join
    /// touches a word span or a voiced frame, each edit is centred in its run within the run's limits, the output adds up
    /// and fills the window (or changes length with the sign of ρ), the seams keep their limits, and every word keeps its
    /// aligned frames.
    private func checkProperties(_ result: VoiceLabFitResult, _ input: FitInput, _ name: String) {
        let plan = result.plan, value = input.take, rate = input.sourceSampleRate
        let assetRate = Double(value.assetSampleRate)
        let size = VoiceLabGeometry.frameSize(assetRate), fade = VoiceLabGeometry.samples(VoiceLabPatchConstants.SEAM_FADE, assetRate)
        let levels: [Float] = value.envelope.runs.flatMap { run in Array(repeating: Float(run[0]), count: Int(run[1])) }
        let unvoiced: [Bool] = levels.map { Double($0) < VoiceLabPatchConstants.VOICED_FRAME_LEVEL }
        let spans: [(start: Int64, end: Int64)] = value.words.map { (word: FitWordRow) -> (start: Int64, end: Int64) in
            let startFrame: Double = word.start * assetRate
            let endFrame: Double = word.end * assetRate
            let roundedStart: Double = startFrame.rounded(.down)
            let roundedEnd: Double = endFrame.rounded(.up)
            return (Int64(roundedStart), Int64(roundedEnd))
        }
        let t0 = VoiceLabGeometry.samples(value.trimStart, assetRate), t1 = VoiceLabGeometry.samples(value.trimEnd, assetRate)
        let edgeIn: Int64 = input.window.leftKind == "none"
            ? max(0, VoiceLabGeometry.samples(input.incomingSilence ?? 0, assetRate) - (spans[0].start - t0)) : 0
        let edgeOut: Int64 = input.window.rightKind == "none"
            ? max(0, VoiceLabGeometry.samples(input.outgoingSilence ?? 0, assetRate) - (t1 - spans[spans.count - 1].end)) : 0
        let natural = edgeIn + edgeOut + t1 - t0
        let n0 = input.window.endSample - input.window.startSample
        let sourceSampleCount: Double = Double(n0)
        let targetFrameCount: Double = sourceSampleCount * assetRate / rate
        let roundedTarget: Double = EditingPrimitives.jsRound(targetFrameCount)
        let targetFrames: Int64 = Int64(roundedTarget)
        let rho: Int64 = natural - targetFrames

        // The never-touch-voice invariant and the output's length.
        var cursor = plan.trimStartFrame
        var frames = plan.incoming.padFrames + plan.trimEndFrame - plan.trimStartFrame + plan.outgoing.padFrames
        for edit in plan.edits {
            let lo = edit.start - fade / 2, hi = edit.start + edit.count + fade - fade / 2
            #expect(edit.count > 0 && cursor <= lo && hi <= plan.trimEndFrame, "\(name): edit at \(edit.start)")
            #expect(!spans.contains { $0.start < hi && lo < $0.end }, "\(name): edit at \(edit.start) touches a word")
            let blocks = (lo / size)..<((hi + size - 1) / size)
            #expect(blocks.allSatisfy { $0 < Int64(unvoiced.count) && unvoiced[Int($0)] }, "\(name): edit at \(edit.start) touches voice")
            cursor = hi
            frames += edit.kind == .insert ? edit.count : -edit.count
            #expect(edit.kind == (rho > 0 ? .remove : .insert), "\(name)")
            // The run that holds the edit, its centre and its limits.
            guard let word = spans.indices.dropLast().last(where: { spans[$0].end <= edit.start }) else {
                Issue.record("\(name): edit before the first word"); continue
            }
            var first = edit.start / size, last = (edit.start + edit.count + size - 1) / size
            while first * size - size >= spans[word].end {
                let previousBlock: Int64 = first - 1
                let previousIndex: Int = Int(previousBlock)
                guard unvoiced[previousIndex] else { break }
                first -= 1
            }
            let followingWord: Int = word + 1
            let unvoicedCount: Int64 = Int64(unvoiced.count)
            while last * size + size <= spans[followingWord].start && last < unvoicedCount {
                let lastIndex: Int = Int(last)
                guard unvoiced[lastIndex] else { break }
                last += 1
            }
            let length = (last - first) * size
            #expect(edit.start - first * size == (length - edit.count) / 2 && edit.count + fade <= length, "\(name)")
            if edit.kind == .remove {
                let punctuation = input.tokens[word].unicodeScalars.last.map(VoiceLabFitPlanner.isPunctuation) ?? false
                let floor = punctuation ? VoiceLabPatchConstants.PAUSE_FLOOR_PUNCT : VoiceLabPatchConstants.PAUSE_FLOOR_PHRASE
                #expect(length - edit.count >= VoiceLabGeometry.samples(floor, assetRate), "\(name)")
            } else {
                #expect(edit.count <= VoiceLabGeometry.samples(VoiceLabPatchConstants.PAUSE_GROWTH_MAX, assetRate), "\(name)")
            }
        }
        #expect(frames == plan.outputFrames, "\(name)")
        let windowSamples: Int64 = plan.windowEndSample - plan.windowStartSample
        let windowSampleCount: Double = Double(windowSamples)
        let windowFrameCount: Double = windowSampleCount * assetRate / rate
        let roundedWindowFrames: Double = EditingPrimitives.jsRound(windowFrameCount)
        let windowFrames: Int64 = Int64(roundedWindowFrames)
        switch result {
        case .exact:
            #expect(plan.outputFrames == windowFrames, "\(name)")
        case let .changedDuration(_, naturalOut, residualSeconds):
            let residual = plan.outputFrames - windowFrames
            #expect(residual != 0 && (residual > 0) == (rho > 0), "\(name)")
            #expect(residualSeconds == Double(residual) / assetRate && naturalOut == Double(natural) / assetRate, "\(name)")
        }

        // Seams: borrowing keeps PAUSE_SLACK_KEEP and happens only at gaps; pads stay within their limits beyond the edge pad.
        let keep = VoiceLabGeometry.samples(VoiceLabPatchConstants.PAUSE_SLACK_KEEP, rate)
        let sides: [(seam: VoiceLabFitSeam, kind: String, silence: Double?, edge: Int64)] = [
            (plan.incoming, input.window.leftKind, input.incomingSilence, edgeIn), (plan.outgoing, input.window.rightKind, input.outgoingSilence, edgeOut),
        ]
        for side in sides {
            let lend: Int64 = side.kind == "gap" ? max(0, VoiceLabGeometry.samples(side.silence ?? 0, rate) - keep) : 0
            let cap = VoiceLabGeometry.samples(side.kind == "hard" ? VoiceLabPatchConstants.HARD_SEAM_PAD_MAX : VoiceLabPatchConstants.SEAM_PAD_MAX, assetRate)
            #expect(side.seam.borrowedSamples >= 0 && side.seam.borrowedSamples <= lend, "\(name)")
            #expect(side.seam.padFrames >= 0 && side.seam.padFrames - side.edge <= cap, "\(name)")
            #expect(side.kind != "hard" || side.seam.padFrames >= side.edge, "\(name)")
        }
        #expect(plan.windowStart == Double(plan.windowStartSample) / rate, "\(name)")
        #expect(plan.windowEnd == Double(plan.windowEndSample) / rate, "\(name)")

        // Every word keeps its aligned frames and moves by the incoming pad and the edits before it. Its times stop at the
        // output's duration as the recipe states it, so the §10.5 render validator's word rule holds.
        let duration: Double
        switch result {
        case .exact: duration = plan.windowEnd - plan.windowStart
        case let .changedDuration(_, _, residualSeconds): duration = plan.windowEnd - plan.windowStart + residualSeconds
        }
        let outSamples = VoiceLabGeometry.samples(duration, rate)
        if case .exact = result { #expect(outSamples == plan.windowEndSample - plan.windowStartSample, "\(name)") }
        #expect(plan.words.count == value.words.count, "\(name)")
        var previous = 0.0
        for (index, word) in zip(value.words.indices, value.words) where index < plan.words.count {
            let priorEdits: [VoiceLabFitEdit] = plan.edits.filter { $0.start < spans[index].start }
            let shift: Int64 = priorEdits.reduce(0) { (sum: Int64, edit: VoiceLabFitEdit) -> Int64 in
                let delta: Int64 = edit.kind == .insert ? edit.count : -edit.count
                return sum + delta
            }
            let offsetFrames: Int64 = plan.incoming.padFrames - plan.trimStartFrame + shift
            let offsetFrameCount: Double = Double(offsetFrames)
            let offset: Double = offsetFrameCount / assetRate
            let wordStart = min(word.start + offset, duration), wordEnd = min(word.end + offset, duration)
            let out = plan.words[index]
            #expect(out == VoiceLabWord(text: word.text, start: wordStart, end: wordEnd, synthetic: true), "\(name)")
            #expect(spans[index].start + offsetFrames >= 0 && spans[index].end + offsetFrames <= plan.outputFrames, "\(name)")
            #expect(out.end <= duration && VoiceLabGeometry.samples(out.end, rate) <= outSamples, "\(name)")
            #expect(out.start >= previous && out.end > out.start, "\(name)")
            #expect(VoiceLabGeometry.samples(out.end, rate) > VoiceLabGeometry.samples(out.start, rate), "\(name)")
            previous = out.end
        }
    }

    @Test func constantsMatchSection83AndTheVectors() throws {
        let document = try #require(Self.document)
        #expect(document.schema == "voxclip-voice-lab-fit-cases/1")
        let constants: [String: Double] = [
            "SEAM_FADE": VoiceLabPatchConstants.SEAM_FADE, "HARD_SEAM_FADE": VoiceLabPatchConstants.HARD_SEAM_FADE,
            "TTS_TRIM_LEAD": VoiceLabPatchConstants.TTS_TRIM_LEAD, "TTS_TRIM_TAIL": VoiceLabPatchConstants.TTS_TRIM_TAIL,
            "PAUSE_SLACK_KEEP": VoiceLabPatchConstants.PAUSE_SLACK_KEEP, "SEAM_PAD_MAX": VoiceLabPatchConstants.SEAM_PAD_MAX,
            "HARD_SEAM_PAD_MAX": VoiceLabPatchConstants.HARD_SEAM_PAD_MAX, "PAUSE_FLOOR_PHRASE": VoiceLabPatchConstants.PAUSE_FLOOR_PHRASE,
            "PAUSE_FLOOR_PUNCT": VoiceLabPatchConstants.PAUSE_FLOOR_PUNCT, "PAUSE_GROWTH_MAX": VoiceLabPatchConstants.PAUSE_GROWTH_MAX,
            "LENGTH_AIM_MIN": VoiceLabPatchConstants.LENGTH_AIM_MIN, "LENGTH_AIM_MAX": VoiceLabPatchConstants.LENGTH_AIM_MAX,
            "VOICED_FRAME": VoiceLabPatchConstants.VOICED_FRAME, "VOICED_FRAME_LEVEL": VoiceLabPatchConstants.VOICED_FRAME_LEVEL,
            "RMS_FRAME": VoiceLabPatchConstants.RMS_FRAME,
        ]
        #expect(document.constants == constants)
        // The §8.3 values themselves, so the generator and the Core cannot drift together.
        let section83: [Double] = [0.3, 0.060, 0.060, 0.150, 0.25, 0.92, 0.97]
        #expect([VoiceLabPatchConstants.SEAM_PAD_MAX, VoiceLabPatchConstants.HARD_SEAM_PAD_MAX, VoiceLabPatchConstants.PAUSE_FLOOR_PHRASE,
                 VoiceLabPatchConstants.PAUSE_FLOOR_PUNCT, VoiceLabPatchConstants.PAUSE_GROWTH_MAX, VoiceLabPatchConstants.LENGTH_AIM_MIN,
                 VoiceLabPatchConstants.LENGTH_AIM_MAX] == section83)
    }

    @Test func documentCountsEveryCase() throws {
        let document = try #require(Self.document)
        #expect(document.caseCount == document.cases.count + document.propertyCases.count)
        #expect(document.categories.values.reduce(0, +) == document.cases.count)
        #expect(document.propertyFuzz.seed == 20_261_027 && document.propertyFuzz.cases == 2000 && document.propertyCases.count == 2000)
        #expect(Set(document.cases.map(\.name)).count == document.cases.count)
    }

    @Test func everyAcceptedPlanBuildsAUnityRenderRecipe() throws {
        let document = try #require(Self.document)
        let template = try JSONProjectStore.decode(FixtureLoader.data("fixtures/voice-lab/passage-render-v3.voxclip"))
        var accepted = 0
        for test in document.cases + document.propertyCases where test.expected.error == nil {
            let result = try plan(test.input)
            let fitted: VoiceLabFitPlan, duration: Double
            switch result {
            case let .exact(value): fitted = value; duration = value.windowEnd - value.windowStart
            case let .changedDuration(value, _, residual): fitted = value; duration = value.windowEnd - value.windowStart + residual
            }
            let rate = test.input.sourceSampleRate, assetRate = test.input.take.assetSampleRate
            let placed = window(test.input)
            let halfAssetRate: Int = assetRate / 2
            let trimStartFrame: Int64 = Int64(halfAssetRate)
            let sourceOffset = max(0, placed.leftSeam.fadeSamples / 2 - fitted.windowStartSample)
            let sourceStartSample = fitted.windowStartSample + sourceOffset
            let sourceEndSample = fitted.windowEndSample + sourceOffset
            let sourceStart = Double(sourceStartSample) / rate, sourceEnd = Double(sourceEndSample) / rate
            let trimStart = Double(trimStartFrame) / Double(assetRate)
            let trimEndFrame: Int64 = trimStartFrame + fitted.outputFrames
            let trimEndFrameCount: Double = Double(trimEndFrame)
            let assetFrameRate: Double = Double(assetRate)
            let trimEnd: Double = trimEndFrameCount / assetFrameRate
            let asset = VoiceLabAsset(id: "asset-fitted", file: template.id + "/asset-fitted.wav", sha256: String(repeating: "ab", count: 32),
                                      durationSeconds: trimEnd + 0.5, sampleRate: assetRate, createdAt: Date(timeIntervalSince1970: 1_793_000_000))
            var project = template, segment = template.voiceLab.segments[0]
            project.media.source.audio?.sampleRate = Int(rate)
            project.media.source.durationSeconds = placed.rightSeam.kind == .none ? sourceEnd : sourceEnd + 1
            project.voiceLab.assets = [asset]
            project.voiceLab.cleanAudio = VoiceLabCleanAudio(mode: .off)
            project.edits.clips = []; project.edits.activeClipId = nil
            segment.replace.start = sourceStart; segment.replace.end = sourceEnd
            var recipe = try #require(segment.candidates[0].recipe)
            recipe.audio = VoiceLabAudio(assetId: asset.id, trimStart: trimStart, trimEnd: trimEnd, stretch: 1, gainDb: 0)
            recipe.outDuration = duration; recipe.words = fitted.words; recipe.roomTone = nil
            recipe.qa.transcriptTokens = fitted.words.count; recipe.qa.transcriptExact = true
            recipe.chunks = [VoiceLabChunk(sourceStartSample: sourceStartSample, sourceEndSample: sourceEndSample,
                                           requestId: "request-fitted", seed: recipe.seed, assetId: asset.id, assetSha256: asset.sha256,
                                           assembledStartFrame: trimStartFrame, assembledEndFrame: trimStartFrame + fitted.outputFrames)]
            recipe.seams = VoiceLabSeams(
                in: try VoiceLabHandles.seam(kind: placed.leftSeam.kind, fadeSamples: placed.leftSeam.fadeSamples, incoming: true,
                                             assetSampleRate: assetRate, sourceSampleRate: rate, stretch: 1),
                out: try VoiceLabHandles.seam(kind: placed.rightSeam.kind, fadeSamples: placed.rightSeam.fadeSamples, incoming: false,
                                              assetSampleRate: assetRate, sourceSampleRate: rate, stretch: 1))
            recipe.video.sourceStartSample = sourceStartSample; recipe.video.sourceEndSample = sourceEndSample
            recipe.video.outputSamples = VoiceLabGeometry.samples(duration, rate)
            let atEnd = placed.rightSeam.kind == .none
            let shortFullTake = atEnd && sourceStartSample == 0 && sourceEnd <= 0.5
            let firstSourceTime = atEnd && !shortFullTake ? max(0.5, sourceStart) : sourceStart
            let sourceSpan = sourceEnd - firstSourceTime
            let originalStart = firstSourceTime + sourceSpan / 3
            let originalEnd = firstSourceTime + sourceSpan * 2 / 3
            project.transcript?.words = [TimedWord(id: "word-fitted-source", text: "source", kind: .word, start: originalStart, end: originalEnd)]
            project.transcript?.durationSeconds = project.media.source.durationSeconds
            segment.replace.firstWordId = "word-fitted-source"; segment.replace.lastWordId = "word-fitted-source"
            if shortFullTake {
                segment.scope = .fullTake; segment.groupId = "group-fitted"
            } else {
                let toneStart: Int64 = atEnd ? 0 : sourceEndSample
                let toneLength = VoiceLabGeometry.samples(0.5, rate)
                recipe.roomTone = VoiceLabRoomTone(sourceStartSample: toneStart, sourceEndSample: toneStart + toneLength, gainDb: 0)
            }
            if case .changedDuration = result {
                recipe.video.mode = .lipsync
                recipe.video.assetId = "video-fitted"; recipe.video.provider = "sync"; recipe.video.model = "lipsync-2"
                recipe.video.requestId = "request-fitted-video"; recipe.video.syncMode = "remap"
                recipe.video.windowStartSample = sourceStartSample; recipe.video.windowEndSample = sourceEndSample
                project.voiceLab.videoAssets = [VoiceLabVideoAsset(id: "video-fitted", file: project.id + "/video-fitted.mp4", sha256: asset.sha256,
                                                                  durationSeconds: duration + 1, frameRate: 30, width: 640, height: 360)]
            }
            segment.audio = recipe.audio; segment.outDuration = duration; segment.words = fitted.words
            segment.candidates = [VoiceLabCandidate(assetId: asset.id, score: 0.9)]
            segment.candidates[0].recipe = recipe
            project.voiceLab.segments = [segment]
            do {
                try VoiceLabProject.validate(project)
                try VoiceLabRenderValidation.validate(project)
                let output = try VoiceLabOutputPlanner.build(project, scope: .full)
                let prepared = try VoiceLabRenderContract.prepare(project, scope: .full, labelPosition: .topRight)
                #expect(prepared.outputPlan == output, "\(test.name)")
                if case .exact = result {
                    #expect(prepared.selectedSegmentRecipes.first?.recipe.video.mode == .source, "\(test.name)")
                } else {
                    #expect(prepared.selectedSegmentRecipes.first?.recipe.video.mode == .lipsync, "\(test.name)")
                    #expect(throws: VoiceLabProjectError.videoModeUnsupported) {
                        try VoiceLabRenderInput(project: project, scope: .full, labelPosition: .topRight,
                                                paidRoot: URL(fileURLWithPath: "/not-opened"), prepared: prepared)
                    }
                }
                accepted += 1
            }
            catch { Issue.record("\(test.name): fitted recipe refused: \(error)") }
        }
        #expect(accepted == (document.cases + document.propertyCases).filter { $0.expected.error == nil }.count)
    }

    @Test func namedVectors() throws {
        let document = try #require(Self.document)
        for test in document.cases { replay(test) }
    }

    @Test func propertyCases() throws {
        let document = try #require(Self.document)
        for test in document.propertyCases { replay(test) }
    }

    /// Inputs the JSON vectors cannot carry: non-finite numbers, a seam sample off the window and a seam a window never has.
    @Test func nonFiniteAndInconsistentInputsAreInvalid() throws {
        let document = try #require(Self.document)
        let base = try #require(document.cases.first { $0.name == "pause-punctuation-first" }).input
        let good = take(base), placed = window(base)
        func refusal(_ window: VoiceLabWindow = placed, incoming: Double? = 0.6, take: VoiceLabFitTake = good, rate: Double = 48000) -> String? {
            do {
                _ = try VoiceLabFitPlanner.plan(window: window, incomingSilence: incoming, outgoingSilence: 0.6, take: take, tokens: base.tokens,
                                                sourceSampleRate: rate)
                return nil
            } catch let error as VoiceLabGeometryError {
                return code(error)
            } catch { return "\(error)" }
        }
        #expect(refusal() == nil)
        #expect(refusal(rate: .nan) == "invalidInput")
        #expect(refusal(rate: .infinity) == "invalidInput")
        #expect(refusal(incoming: .nan) == "invalidInput")
        #expect(refusal(incoming: .infinity) == "invalidInput")
        var shifted = placed
        shifted.leftSeam.sample += 1
        #expect(refusal(shifted) == "invalidInput")
        var timeless = placed
        timeless.start = .nan
        #expect(refusal(timeless) == "invalidInput")
        var broken = good
        broken.trimEnd = .nan
        #expect(refusal(take: broken) == "invalidInput")
        broken = good
        broken.envelope.levels[3] = .nan
        #expect(refusal(take: broken) == "invalidInput")
        broken = good
        broken.envelope.levels[3] = -1
        #expect(refusal(take: broken) == "invalidInput")
        broken = good
        broken.assetSampleRate = 0
        #expect(refusal(take: broken) == "invalidInput")
        broken = good
        broken.words[1].start = .nan
        #expect(refusal(take: broken) == "invalidWordTiming")
    }

    @Test func everyWordIsSyntheticWithItsProviderText() throws {
        let document = try #require(Self.document)
        let test = try #require(document.cases.first { $0.name == "punctuation-categories" })
        let result = try plan(test.input)
        #expect(result.plan.words.map(\.text) == test.input.take.words.map(\.text))
        let synthetic = result.plan.words.allSatisfy { $0.synthetic }
        #expect(synthetic)
    }
}
