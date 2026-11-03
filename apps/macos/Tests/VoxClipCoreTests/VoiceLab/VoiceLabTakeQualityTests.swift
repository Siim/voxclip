import Foundation
import Testing
@testable import VoxClipCore

@Suite("Take ranking and QA vectors", .offlineFixtures)
struct VoiceLabTakeQualityTests {
    private struct Cases: Decodable {
        struct Rank: Decodable { let id: String; let window: Double; let residual: Double; let match: Double; let flatness: Double; let score: Double }
        struct QA: Decodable { let id: String; let expected: String; let recognized: [String]; let amplitude: Double; let afterAmplitude: Double?; let speaker: Double; let failures: [VoiceLabTakeQAFailure] }
        let schema: String
        let ranking: [Rank]
        let qa: [QA]
    }
    static func fit(window: Double, residual: Double) -> VoiceLabFitResult {
        let rate = 24_000.0
        let plan = VoiceLabFitPlan(edits: [], incoming: .init(padFrames: 0, borrowedSamples: 0), outgoing: .init(padFrames: 0, borrowedSamples: 0),
            trimStartFrame: 0, trimEndFrame: Int64((window + residual) * rate), windowStart: 0, windowEnd: window,
            windowStartSample: 0, windowEndSample: Int64(window * rate), outputFrames: Int64((window + residual) * rate), words: [])
        return residual == 0 ? .exact(plan) : .changedDuration(plan, naturalOut: window + residual, residualSeconds: residual)
    }
    @Test func rankingReplaysSharedFormula() throws {
        let cases = try JSONDecoder().decode(Cases.self, from: FixtureLoader.data("fixtures/voice-lab/take-run-cases.json"))
        #expect(cases.schema == "voxclip-take-run-cases/1")
        for row in cases.ranking {
            let score = try VoiceLabTakeQuality.rank(fit: Self.fit(window: row.window, residual: row.residual), windowSeconds: row.window,
                                                    matchRatio: row.match, flatness: row.flatness)
            #expect(abs(score - row.score) < 1e-12, "\(row.id)")
        }
    }
    @Test func qaCompositionReplaysSharedFailures() throws {
        let cases = try JSONDecoder().decode(Cases.self, from: FixtureLoader.data("fixtures/voice-lab/take-run-cases.json"))
        for row in cases.qa {
            let samples: [Float] = (0..<16_000).map { index in
                let amplitude = index >= 8_000 ? row.afterAmplitude ?? row.amplitude : row.amplitude
                return Float(amplitude * sin(2 * Double.pi * 220 * Double(index) / 16_000))
            }
            let result = try VoiceLabTakeQuality.evaluate(expected: row.expected, recognized: row.recognized, mixed: samples, sampleRate: 16_000,
                seams: row.afterAmplitude == nil ? [] : [8_000], speakerScore: row.speaker, threshold: 0.45)
            #expect(result.failures == row.failures, "\(row.id)")
            #expect(result.passed == row.failures.isEmpty)
        }
    }
    /// Live 2026-11-03 (car vlog): a gap seam sits in a pause, so one 400 ms side holds more speech than the other and the
    /// unedited source itself jumps 5 to 38 LU there. Only what a join adds beyond the source's own signed step is the join's.
    @Test func seamLoudnessCountsOnlyTheStepTheJoinAdds() throws {
        let rate = 24_000, seam = 12_000
        /// Speech-level tone, a 375 ms pause of background noise before the seam, then tone again from `speech` on.
        func signal(speech: Int, level: Double, background: Double) -> [Float] {
            (0..<(rate * 2)).map { index in
                let noise = Double((index * 7_919) % 1_001 - 500) / 500 * background
                let voiced = (index < seam - 9_000) || index >= speech
                let gain = index >= seam ? level : 1
                return Float((voiced ? 0.1 * gain * sin(2 * Double.pi * 180 * Double(index) / Double(rate)) : 0) + noise)
            }
        }
        let source = signal(speech: seam + 1_200, level: 1, background: 0.002)
        let sourceSteps = try VoiceLabLoudness.seamStepsLu(source, sampleRate: rate, seamSamples: [seam])
        #expect(sourceSteps[0] > 10)
        // A take that starts its speech 20 ms later at the same level passes; the plain jump would fail it.
        let take = signal(speech: seam + 1_680, level: 1, background: 0.002)
        let plain = try VoiceLabTakeQuality.evaluate(expected: "a", recognized: ["a"], mixed: take, sampleRate: rate, seams: [seam],
            speakerScore: nil, threshold: 0.45)
        #expect(plain.failures == [.loudness])
        let referenced = try VoiceLabTakeQuality.evaluate(expected: "a", recognized: ["a"], mixed: take, sampleRate: rate, seams: [seam],
            sourceSeamSteps: sourceSteps, speakerScore: nil, threshold: 0.45)
        #expect(referenced.passed && (referenced.values.lufsJumpLu ?? 9) < 1)
        // Speech 6 dB louder than the source's after the seam is still a step at the join.
        let loud = signal(speech: seam + 1_200, level: 2, background: 0.002)
        let louder = try VoiceLabTakeQuality.evaluate(expected: "a", recognized: ["a"], mixed: loud, sampleRate: rate, seams: [seam],
            sourceSeamSteps: sourceSteps, speakerScore: nil, threshold: 0.45)
        #expect(louder.failures == [.loudness] && (louder.values.lufsJumpLu ?? 0) > 5)
        // So is room tone that stops at a seam whose source has background on both sides.
        let quiet = (0..<(rate * 2)).map { index in Float(Double((index * 7_919) % 1_001 - 500) / 500 * 0.002) }
        let silent = quiet.enumerated().map { $0.offset >= seam ? Float(0) : $0.element }
        let flat = try VoiceLabLoudness.seamStepsLu(quiet, sampleRate: rate, seamSamples: [seam])
        let dropout = try VoiceLabTakeQuality.evaluate(expected: "a", recognized: ["a"], mixed: silent, sampleRate: rate, seams: [seam],
            sourceSeamSteps: flat, speakerScore: nil, threshold: 0.45)
        #expect(dropout.failures == [.loudness])
        // A take far louder than the speech it replaces, whose step mirrors the source's (as loud before the seam as the
        // source is quiet there), still fails: only a step between 0 and the source's own, in its direction, is free.
        let speechAfter = (0..<(rate * 2)).map { index in
            Float((index >= seam ? 0.1 * sin(2 * Double.pi * 180 * Double(index) / Double(rate)) : 0) + Double((index * 7_919) % 1_001 - 500) / 500 * 0.002)
        }
        let step = try VoiceLabLoudness.seamStepsLu(speechAfter, sampleRate: rate, seamSamples: [seam])
        #expect(step[0] > 20)
        let gain = pow(10, step[0] / 40)
        let mirrored = speechAfter.enumerated().map { index, sample in
            index < seam ? Float(0.1 * gain * sin(2 * Double.pi * 180 * Double(index) / Double(rate))) : sample
        }
        let mirroredStep = try VoiceLabLoudness.seamStepsLu(mirrored, sampleRate: rate, seamSamples: [seam])
        #expect(mirroredStep[0] < -5 && abs(mirroredStep[0]) <= step[0])
        let flipped = try VoiceLabTakeQuality.evaluate(expected: "a", recognized: ["a"], mixed: mirrored, sampleRate: rate, seams: [seam],
            sourceSeamSteps: step, speakerScore: nil, threshold: 0.45)
        #expect(flipped.failures == [.loudness] && (flipped.values.lufsJumpLu ?? 0) > 5)
        // (mixed step, source step, excess): within the source's step, the other way, beyond it, and none at the source.
        let cases: [(Double, Double, Double)] = [(5, 10, 0), (-1, 10, 1), (12, 10, 2), (-10, 10, 10), (0.5, 0, 0.5), (-3, -8, 0), (-9, -8, 1), (2, -8, 2)]
        for (mixed, source, excess) in cases {
            #expect(try VoiceLabLoudness.seamExcessLu(mixedSteps: [mixed], sourceSteps: [source]) == excess)
        }
        #expect(try VoiceLabLoudness.seamExcessLu(mixedSteps: cases.map { $0.0 }, sourceSteps: cases.map { $0.1 }) == 10)
        #expect(throws: VoiceLabAudioMathError.invalidInput) { try VoiceLabLoudness.seamExcessLu(mixedSteps: [1], sourceSteps: []) }
        #expect(throws: VoiceLabAudioMathError.invalidInput) { try VoiceLabLoudness.seamExcessLu(mixedSteps: [.nan], sourceSteps: [1]) }
        #expect(try VoiceLabLoudness.seamExcessLu(mixedSteps: [], sourceSteps: []) == 0)
    }
    /// Live take 3 (2026-11-03): a join inside a pause on both sides, where the take's pause before it is longer than the
    /// source's. The 400 ms windows read where speech falls, so the plain rule failed a join no one hears. A join whose
    /// generated side is in a pause compares that pause's level with the source's own pause beside the join, and a real
    /// room-tone level jump there still fails.
    @Test func aJoinInsideAPauseComparesThePauseLevels() throws {
        let rate = 24_000, seam = 12_000
        /// Tone (speech) until `speechEnd`, background at `before` up to the seam and `after` from it, tone again from
        /// `speechStart`. The tone fades over 20 ms at each edge, as speech decays, so its edge is not a broadband click.
        func signal(speechEnd: Int, speechStart: Int, before: Double, after: Double) -> [Float] {
            let ramp = 480
            return (0..<rate).map { index in
                let edge = index < speechEnd ? speechEnd - index : index >= speechStart ? index - speechStart + 1 : 0
                let envelope = edge == 0 ? 0 : edge >= ramp ? 1 : 0.5 - 0.5 * cos(Double.pi * Double(edge) / Double(ramp))
                let noise = Double((index * 7_919) % 1_001 - 500) / 500 * (index < seam ? before : after)
                return Float(0.1 * envelope * sin(2 * Double.pi * 180 * Double(index) / Double(rate)) + noise)
            }
        }
        // An outgoing join: the take is before the seam, the source after it.
        let source = signal(speechEnd: seam - 3_600, speechStart: seam + 4_320, before: 0.002, after: 0.002)
        let take = signal(speechEnd: seam - 8_400, speechStart: seam + 4_320, before: 0.002, after: 0.002)
        let sourceSteps = try VoiceLabLoudness.seamStepsLu(source, sampleRate: rate, seamSamples: [seam])
        let sourceRanges = try VoiceLabLoudness.sourcePausesLufs(source, sampleRate: rate, seamSamples: [seam], generatedAfter: [false])
        let takeSteps = try VoiceLabLoudness.seamStepsLu(take, sampleRate: rate, seamSamples: [seam])
        let takeLevels = try VoiceLabLoudness.generatedPauseLufs(take, sampleRate: rate, seamSamples: [seam], generatedAfter: [false])
        // The windows' own step differs by several LU only because the take's pause is longer.
        #expect(try VoiceLabLoudness.seamExcessLu(mixedSteps: takeSteps, sourceSteps: sourceSteps) > 4)
        let range = try #require(sourceRanges[0]?.range), level = try #require(takeLevels[0])
        #expect(range.upperBound - range.lowerBound < 1 && abs(level - range.lowerBound) < 1, "\(range) \(level)")
        let quiet = try VoiceLabTakeQuality.evaluate(expected: "a", recognized: ["a"], mixed: take, sampleRate: rate, seams: [seam],
            sourceSeamSteps: sourceSteps, sourceSeamPauses: sourceRanges, generatedAfter: [false], speakerScore: nil, threshold: 0.45)
        #expect(quiet.passed && (quiet.values.lufsJumpLu ?? 9) < 1)
        // Without the source's pause ranges the 400 ms windows decide, as before.
        let alone = try VoiceLabTakeQuality.evaluate(expected: "a", recognized: ["a"], mixed: take, sampleRate: rate, seams: [seam],
            sourceSeamSteps: sourceSteps, speakerScore: nil, threshold: 0.45)
        #expect(alone.failures == [.loudness])
        // Room tone 6 dB above the background it meets, inside the same pause, is a jump at the join.
        let loud = signal(speechEnd: seam - 8_400, speechStart: seam + 4_320, before: 0.004, after: 0.002)
        let jump = try VoiceLabTakeQuality.evaluate(expected: "a", recognized: ["a"], mixed: loud, sampleRate: rate, seams: [seam],
            sourceSeamSteps: sourceSteps, sourceSeamPauses: sourceRanges, generatedAfter: [false], speakerScore: nil, threshold: 0.45)
        #expect(jump.failures == [.loudness] && (jump.values.lufsJumpLu ?? 0) > 4)
        // Less than 0.1 s of pause on the generated side keeps the 400 ms windows; so does a source with no pause beside it.
        let short = signal(speechEnd: seam - 2_160, speechStart: seam + 4_320, before: 0.002, after: 0.002)
        #expect(try VoiceLabLoudness.generatedPauseLufs(short, sampleRate: rate, seamSamples: [seam], generatedAfter: [false]) == [nil])
        let busy = signal(speechEnd: seam + 1_200, speechStart: seam + 1_200, before: 0.002, after: 0.002)
        #expect(try VoiceLabLoudness.sourcePausesLufs(busy, sampleRate: rate, seamSamples: [seam], generatedAfter: [false]) == [nil])
        #expect(try VoiceLabLoudness.seamExcessLu(mixedSteps: [3], sourceSteps: [0], generatedPauseLevels: [-50], sourcePauses: [nil]) == 3)
        #expect(try VoiceLabLoudness.seamExcessLu(mixedSteps: [3], sourceSteps: [0], generatedPauseLevels: [-50], sourcePauses: [VoiceLabSourcePause(range: -49 ... -40, besideJoin: true)]) == 1)
        // A take pause that meets source speech, not a source pause, also passes when its 400 ms step does.
        let onset = VoiceLabSourcePause(range: -49 ... -40, besideJoin: false)
        #expect(try VoiceLabLoudness.seamExcessLu(mixedSteps: [3], sourceSteps: [5], generatedPauseLevels: [-30], sourcePauses: [onset]) == 0)
        #expect(try VoiceLabLoudness.seamExcessLu(mixedSteps: [9], sourceSteps: [5], generatedPauseLevels: [-30], sourcePauses: [onset]) == 4)
        #expect(throws: VoiceLabAudioMathError.invalidInput) {
            try VoiceLabLoudness.seamExcessLu(mixedSteps: [0], sourceSteps: [0], generatedPauseLevels: [], sourcePauses: [nil])
        }
        #expect(throws: VoiceLabAudioMathError.invalidInput) {
            try VoiceLabLoudness.generatedPauseLufs(take, sampleRate: rate, seamSamples: [rate + 1], generatedAfter: [true])
        }
        #expect(throws: VoiceLabAudioMathError.invalidInput) {
            try VoiceLabLoudness.sourcePausesLufs(take, sampleRate: rate, seamSamples: [seam], generatedAfter: [])
        }
    }
    @Test func incompleteSpeakerEvidenceCannotBeRankedOrSelected() throws {
        let qa = VoiceLabTakeQAResult(values: VoiceLabQA(), failures: [.insufficientGeneratedSpeech])
        let audio = VoiceLabTakeAudio(sampleRate: 24_000, trimmed: [0.1], mixed: [0.1], patchRange: 0..<1,
            seams: [], gainDb: 0, roomTone: nil, fit: Self.fit(window: 1, residual: 0))
        let incomplete = VoiceLabTakeRow(id: UUID(), index: 0, seed: 0, audio: audio, qa: qa,
            score: 1, failure: .qa([.insufficientGeneratedSpeech]))
        let result = VoiceLabTakeRunResult(rows: [incomplete], end: .completed)
        #expect(!qa.passed)
        #expect(qa.values.speakerScore == nil)
        #expect(!incomplete.selectable)
        #expect(result.ranked.isEmpty)
        #expect(result.best == nil)
        #expect(VoiceLabTakeQAFailure.insufficientGeneratedSpeech != .speaker)
        let encoded = try JSONEncoder().encode(VoiceLabTakeQAFailure.insufficientGeneratedSpeech)
        #expect(try JSONDecoder().decode(VoiceLabTakeQAFailure.self, from: encoded) == .insufficientGeneratedSpeech)
    }
    @Test func quoteSetCostIncludesEveryQACapAndWrapsSeeds() throws {
        let speech = CostEstimate(provider: "elevenlabs", operation: "textToSpeech", units: 5, unit: "character", usd: Decimal(string: "0.1"), basis: "fixture")
        let qa = CostEstimate(provider: "elevenlabs", operation: "speechToText", units: 290, unit: "second", usd: Decimal(string: "0.1"), basis: "fixture")
        let takes = (0..<3).map { index in
            VoiceLabTakeQuote(index: index, seed: UInt32.max &+ UInt32(index),
                synthesis: VoiceLabQuote(id: UUID(), operation: .textToSpeech, requestID: UUID(), estimate: speech, region: .default, endpoint: "tts", languageMode: nil, fingerprint: "fixture"),
                qa: VoiceLabQuote(id: UUID(), operation: .speechToText, requestID: UUID(), estimate: qa, region: .default, endpoint: "qa", languageMode: nil, fingerprint: "fixture"))
        }
        let quote = VoiceLabTakeRunQuote(id: UUID(), takes: takes, preparedAt: Date(timeIntervalSince1970: 1_000))
        #expect(quote.estimate.usd == Decimal(string: "0.6"))
        #expect(quote.takes.map(\.seed) == [UInt32.max, 0, 1])
        #expect(quote.expiresAt.timeIntervalSince(quote.preparedAt) == 300)
        if case .confirm = VoiceLabCostPresentation.kind(quote.estimate, isLipSync: false, providerName: "ElevenLabs") {} else { Issue.record("The total requires confirmation") }
        let unknownEstimate = CostEstimate(provider: "elevenlabs", operation: "speechToText", units: 290, unit: "second", basis: "unknown")
        let unknownQA = VoiceLabQuote(id: UUID(), operation: .speechToText, requestID: UUID(), estimate: unknownEstimate, region: .default, endpoint: "qa", languageMode: nil, fingerprint: "fixture")
        let unknown = VoiceLabTakeRunQuote(id: UUID(), takes: [.init(index: 0, seed: 1, synthesis: takes[0].synthesis, qa: unknownQA)], preparedAt: Date())
        #expect(unknown.estimate.usd == nil)
        if case .confirm = VoiceLabCostPresentation.kind(unknown.estimate, isLipSync: false, providerName: "ElevenLabs") {} else { Issue.record("Unknown QA pricing requires run confirmation") }
    }
}
