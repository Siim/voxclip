import Foundation
import Testing
@testable import VoxClipCore

/// Serialized so the timing test does not share the CPU with this suite's own vector run.
@Suite("Voice Lab audio math", .serialized)
struct VoiceLabAudioMathTests {
    private static func sine(_ frequency: Double, peakDbfs: Double, count: Int, rate: Int, phase: Double = 0) -> [Float] {
        let amplitude = pow(10, peakDbfs / 20)
        return (0..<count).map { Float(amplitude * sin(2.0 * Double.pi * frequency * Double($0) / Double(rate) + phase)) }
    }
    private static func noise(seed: UInt32, peakDbfs: Double, count: Int) -> [Float] {
        let amplitude = pow(10, peakDbfs / 20)
        var state = seed
        return (0..<count).map { _ in
            state = state &* 1_664_525 &+ 1_013_904_223
            return Float(amplitude * (Double(state) / 2_147_483_648.0 - 1.0))
        }
    }
    /// Noise bursts between pauses, so the envelope has a shape to correlate.
    private static func speech(rate: Int, seed: UInt32) -> [Float] {
        let parts: [(seconds: Double, level: Double?)] = [(0.23, -18), (0.11, nil), (0.37, -24), (0.07, nil), (0.19, -15),
                                                          (0.21, nil), (0.41, -21), (0.13, nil), (0.29, -27), (0.17, nil)]
        return parts.enumerated().flatMap { index, part in
            let count = VoiceLabLoudness.sampleCount(part.seconds, rate)
            return part.level.map { noise(seed: seed + UInt32(index), peakDbfs: $0, count: count) } ?? [Float](repeating: 0, count: count)
        }
    }
    /// The 10 ms envelope Media supplies: whole frames from sample 0, each RMS in Float64 and stored as Float32.
    private static func envelope(_ samples: [Float], rate: Int) -> AudioEnvelope {
        let frame = VoiceLabLoudness.sampleCount(0.01, rate)
        var levels: [Float] = []
        samples.withUnsafeBufferPointer { buffer in
            var start = 0
            while start + frame <= buffer.count {
                var sum = 0.0, index = start
                while index < start + frame {
                    let value = Double(buffer.baseAddress![index])
                    sum += value * value
                    index += 1
                }
                levels.append(Float((sum / Double(frame)).squareRoot()))
                start += frame
            }
        }
        return AudioEnvelope(sampleRate: Double(rate), levels: levels)
    }
    private struct Signal: Decodable {
        struct Part: Decodable {
            let type: String
            let samples: Int
            let frequency, peakDbfs, phase: Double?
            let seed: UInt32?
        }
        let rate: Int
        let parts: [Part]
        let gainDb: Double?
    }
    private struct Expected: Decodable {
        let shelf, highPass, jumps: [Double]?
        let voicedRmsDb, samplePeakDbfs, truePeakDbtp, lufs, lufsJumpLu, stdev, flatness, peak: Double?
        let sourceVoicedRmsDb, candidateVoicedRmsDb, candidateTruePeakDbtp, gainDb: Double?
        let oversampling, windows, delta, lag: Int?
        let kind, error: String?
    }
    private struct Case: Decodable {
        let id, kind: String
        let rate, windowStart, inputSamples, outputSamples: Int?
        let signal, source, candidate, input, output: Signal?
        let seams, window: [Int]?
        let searchSeconds: Double?
        let inputLevels, outputLevels: [Float]?
        let expected: Expected
    }
    private struct Vectors: Decodable {
        struct Tolerances: Decodable { let db, truePeakDb, flatness, correlation, coefficient: Double }
        struct Published: Decodable { let shelf, highPass: [Double] }
        let version: Int
        let tolerances: Tolerances
        let publishedKWeighting48k: Published
        let cases: [Case]
    }
    /// Renders a vector signal in Float64, in the README's operation order, and rounds each sample once to Float32.
    private static func render(_ signal: Signal) throws -> [Float] {
        let gain = pow(10, (signal.gainDb ?? 0) / 20)
        var samples: [Float] = []
        for part in signal.parts {
            switch part.type {
            case "sine":
                let amplitude = pow(10, try #require(part.peakDbfs) / 20)
                let frequency = try #require(part.frequency), phase = try #require(part.phase)
                for n in 0..<part.samples {
                    samples.append(Float(amplitude * sin(2.0 * Double.pi * frequency * Double(n) / Double(signal.rate) + phase) * gain))
                }
            case "noise":
                let amplitude = pow(10, try #require(part.peakDbfs) / 20)
                var state = try #require(part.seed)
                for _ in 0..<part.samples {
                    state = state &* 1_664_525 &+ 1_013_904_223
                    samples.append(Float(amplitude * (Double(state) / 2_147_483_648.0 - 1.0) * gain))
                }
            case "silence":
                samples.append(contentsOf: repeatElement(0, count: part.samples))
            default:
                throw VoiceLabAudioMathError.invalidInput
            }
        }
        return samples
    }
    /// 1 kHz fills each 10 ms frame with whole cycles at 24, 44.1 and 48 kHz, so every frame has the sine's RMS.
    private static func tone(rmsDbfs: Double, count: Int, rate: Int) -> [Float] {
        sine(1000, peakDbfs: rmsDbfs + 20 * log10(2.0.squareRoot()), count: count, rate: rate)
    }

    @Test func voicedFramesUseTheRoundedTenMillisecondGrid() throws {
        #expect(VoiceLabLoudness.sampleCount(0.01, 44_100) == 441)
        #expect(VoiceLabLoudness.sampleCount(0.01, 22_050) == 221)
        #expect(VoiceLabLoudness.sampleCount(0.01, 11_025) == 110)
        let edge = Self.tone(rmsDbfs: -44.95, count: 24_000, rate: 48_000) + Self.tone(rmsDbfs: -45.05, count: 24_000, rate: 48_000)
        #expect(abs(try #require(try VoiceLabLoudness.voicedRmsDb(edge, sampleRate: 48_000)) + 44.95) < 1e-4)
        #expect(try VoiceLabLoudness.voicedRmsDb(Self.tone(rmsDbfs: -45.05, count: 44_100, rate: 44_100), sampleRate: 44_100) == nil)
        #expect(try VoiceLabLoudness.voicedRmsDb([Float](repeating: 0, count: 4_800), sampleRate: 48_000) == nil)
        #expect(try VoiceLabLoudness.voicedRmsDb([], sampleRate: 48_000) == nil)
        // A loud trailing partial frame is ignored, and a quiet frame does not dilute the voiced mean square.
        let voiced = Self.tone(rmsDbfs: -20, count: 2_400, rate: 24_000)
        let padded = voiced + [Float](repeating: 0, count: 240) + [Float](repeating: 1, count: 239)
        #expect(try VoiceLabLoudness.voicedRmsDb(padded, sampleRate: 24_000) == VoiceLabLoudness.voicedRmsDb(voiced, sampleRate: 24_000))
    }

    @Test func voicedLevelRejectsUnusableInput() {
        #expect(throws: VoiceLabAudioMathError.invalidInput) { try VoiceLabLoudness.voicedRmsDb([0], sampleRate: 0) }
        #expect(throws: VoiceLabAudioMathError.invalidInput) { try VoiceLabLoudness.voicedRmsDb([0], sampleRate: 49) }
        #expect(throws: VoiceLabAudioMathError.invalidInput) { try VoiceLabLoudness.voicedRmsDb([0, .nan], sampleRate: 48_000) }
        #expect(throws: VoiceLabAudioMathError.invalidInput) { try VoiceLabLoudness.voicedRmsDb([.infinity], sampleRate: 48_000) }
    }

    @Test func levelGainClampsThenCapsTheTruePeak() throws {
        #expect(try VoiceLabLoudness.levelGainDb(sourceVoicedRmsDb: -20, candidateVoicedRmsDb: -26, candidateTruePeakDbtp: -18) == 6)
        #expect(try VoiceLabLoudness.levelGainDb(sourceVoicedRmsDb: -10, candidateVoicedRmsDb: -35, candidateTruePeakDbtp: -30) == 12)
        #expect(try VoiceLabLoudness.levelGainDb(sourceVoicedRmsDb: -40, candidateVoicedRmsDb: -10, candidateTruePeakDbtp: -6) == -12)
        #expect(try VoiceLabLoudness.levelGainDb(sourceVoicedRmsDb: -3, candidateVoicedRmsDb: -13, candidateTruePeakDbtp: -9.5) == 8.5)
        // The cap applies after the clamp, so it can take the gain below −12 dB.
        #expect(try VoiceLabLoudness.levelGainDb(sourceVoicedRmsDb: -40, candidateVoicedRmsDb: -10, candidateTruePeakDbtp: 12) == -13)
        #expect(throws: VoiceLabAudioMathError.noVoicedAudio) {
            try VoiceLabLoudness.levelGainDb(sourceVoicedRmsDb: nil, candidateVoicedRmsDb: -20, candidateTruePeakDbtp: -10)
        }
        #expect(throws: VoiceLabAudioMathError.noVoicedAudio) {
            try VoiceLabLoudness.levelGainDb(sourceVoicedRmsDb: -20, candidateVoicedRmsDb: nil, candidateTruePeakDbtp: -10)
        }
        #expect(throws: VoiceLabAudioMathError.invalidInput) {
            try VoiceLabLoudness.levelGainDb(sourceVoicedRmsDb: -20, candidateVoicedRmsDb: -20, candidateTruePeakDbtp: .nan)
        }
    }

    @Test func truePeakUsesTheAnnexTwoFilterAtTheRatesOversampling() throws {
        #expect([95_999, 96_000, 191_999, 192_000].map { VoiceLabLoudness.oversampling(sampleRate: $0) } == [4, 2, 2, 1])
        // A unit impulse passes the published taps straight through, so the filter alone peaks at the 0.97216796875
        // tap; the true peak is the larger sample peak, 0 dBFS, at every rate.
        var impulse = [Float](repeating: 0, count: 64)
        impulse[20] = 1
        #expect(try VoiceLabLoudness.truePeakDbtp(impulse, sampleRate: 48_000) == 0)
        #expect(try VoiceLabLoudness.truePeakDbtp(impulse, sampleRate: 96_000) == 0)
        #expect(try VoiceLabLoudness.truePeakDbtp(impulse, sampleRate: 192_000) == 0)
        // Two adjacent full-scale samples meet the 0.465 and 0.780 taps of phases 1 and 2, above the samples.
        impulse[21] = 1
        #expect(try VoiceLabLoudness.truePeakDbtp(impulse, sampleRate: 48_000) == 20 * log10(0.4650878906250 + 0.7797851562500))
        #expect(try VoiceLabLoudness.truePeakDbtp(impulse, sampleRate: 96_000) == 20 * log10(0.4650878906250 + 0.7797851562500))
        // fs/4 at 45° puts every sample at −3.01 dBFS while the waveform peaks between them.
        for rate in [24_000, 44_100, 48_000, 96_000] {
            let wave = Self.sine(Double(rate) / 4, peakDbfs: 0, count: rate / 10, rate: rate, phase: .pi / 4)
            #expect(abs(try VoiceLabLoudness.samplePeakDbfs(wave) + 3.0103) < 1e-4)
            #expect(abs(try VoiceLabLoudness.truePeakDbtp(wave, sampleRate: rate) - 0.0826) < 1e-3)
        }
        let high = Self.sine(48_000, peakDbfs: 0, count: 19_200, rate: 192_000, phase: .pi / 4)
        #expect(try VoiceLabLoudness.truePeakDbtp(high, sampleRate: 192_000) == VoiceLabLoudness.samplePeakDbfs(high))
        #expect(try VoiceLabLoudness.truePeakDbtp([Float](repeating: 0, count: 100), sampleRate: 48_000) == -.infinity)
        #expect(try VoiceLabLoudness.samplePeakDbfs([]) == -.infinity)
        #expect(throws: VoiceLabAudioMathError.invalidInput) { try VoiceLabLoudness.samplePeakDbfs([1, .nan]) }
        #expect(throws: VoiceLabAudioMathError.invalidInput) { try VoiceLabLoudness.truePeakDbtp([0], sampleRate: -1) }
    }

    @Test func neighbourhoodLevelExcludesTheWindowAndFramesEachSideFromItsStart() throws {
        let quiet = Self.tone(rmsDbfs: -30, count: 48_000, rate: 48_000), loud = Self.tone(rmsDbfs: -10, count: 24_000, rate: 48_000)
        // Neither the window nor the audio more than 3 s from it counts.
        let take = loud + quiet + quiet + quiet + loud + quiet + quiet + quiet + loud
        #expect(abs(try VoiceLabLoudness.neighbourhoodVoicedRmsDb(take, sampleRate: 48_000, window: 168_000..<192_000) + 30) < 1e-4)
        // The before side's 100 loud samples are its trailing partial frame and are ignored; the after side's 43 loud
        // samples open its first frame, which starts at the window's end.
        let ragged = [Float](repeating: 0, count: 4_800) + [Float](repeating: 0.5, count: 100) + loud.prefix(4_830)
            + [Float](repeating: 0.1, count: 43) + [Float](repeating: 0, count: 4_757)
        let level = try VoiceLabLoudness.neighbourhoodVoicedRmsDb(ragged, sampleRate: 48_000, window: 4_900..<9_730)
        #expect(abs(level - 20 * log10((43 * 0.01 / 480).squareRoot())) < 1e-4)
        // A voiced window between silent or empty sides has no level.
        #expect(throws: VoiceLabAudioMathError.noVoicedAudio) {
            try VoiceLabLoudness.neighbourhoodVoicedRmsDb([Float](repeating: 0, count: 4_800) + loud, sampleRate: 48_000, window: 4_800..<28_800)
        }
        #expect(throws: VoiceLabAudioMathError.invalidInput) { try VoiceLabLoudness.neighbourhoodVoicedRmsDb(quiet, sampleRate: 48_000, window: -1..<10) }
        #expect(throws: VoiceLabAudioMathError.invalidInput) { try VoiceLabLoudness.neighbourhoodVoicedRmsDb(quiet, sampleRate: 48_000, window: 0..<48_001) }
        // An absurd rate clamps the 3 s reach to the take instead of overflowing.
        #expect(throws: VoiceLabAudioMathError.noVoicedAudio) { try VoiceLabLoudness.neighbourhoodVoicedRmsDb(quiet, sampleRate: .max, window: 0..<10) }
    }

    @Test func measuredLevelGainUsesTheCandidatesInterSamplePeak() throws {
        let source = Self.sine(997, peakDbfs: 0, count: 48_000, rate: 48_000)
        let candidate = Self.sine(6_000, peakDbfs: -10, count: 24_000, rate: 24_000, phase: .pi / 4)
        let gain = try VoiceLabLoudness.levelGainDb(source: source, sourceSampleRate: 48_000, window: 19_200..<28_800,
                                                    candidate: candidate, candidateSampleRate: 24_000)
        // The voiced difference is 10 dB; the true peak (−9.917 dBTP), not the −13.01 dBFS sample peak, caps it.
        #expect(abs(gain - 8.917) < 1e-3)
        #expect(throws: VoiceLabAudioMathError.noVoicedAudio) {
            try VoiceLabLoudness.levelGainDb(source: source, sourceSampleRate: 48_000, window: 19_200..<28_800,
                                             candidate: [Float](repeating: 0, count: 2_400), candidateSampleRate: 24_000)
        }
        // A candidate that cannot be measured fails as invalid input, even beside a silent neighbourhood.
        #expect(throws: VoiceLabAudioMathError.invalidInput) {
            try VoiceLabLoudness.levelGainDb(source: [Float](repeating: 0, count: 48_000), sourceSampleRate: 48_000, window: 0..<10,
                                             candidate: [.nan], candidateSampleRate: 24_000)
        }
    }

    @Test func kWeightingMatchesThePublished48kHzCoefficients() {
        let stages = VoiceLabLoudness.kWeighting(sampleRate: 48_000)
        let shelf = [1.53512485958697, -2.69169618940638, 1.19839281085285, -1.69065929318241, 0.73248077421585]
        let highPass = [1.0, -2.0, 1.0, -1.99004745483398, 0.99007225036621]
        for (stage, published) in [(stages.shelf, shelf), (stages.highPass, highPass)] {
            for (value, expected) in zip([stage.b0, stage.b1, stage.b2, stage.a1, stage.a2], published) {
                #expect(abs(value - expected) < 1e-6)
            }
        }
    }

    @Test func momentaryLoudnessMeetsTheSineAnchors() throws {
        for rate in [48_000, 44_100] {
            for (peak, expected) in [(0.0, -3.01), (-20.0, -23.01)] {
                let wave = Self.sine(997, peakDbfs: peak, count: rate, rate: rate)
                let start = rate - VoiceLabLoudness.sampleCount(0.4, rate)
                #expect(abs(try VoiceLabLoudness.momentaryLufs(wave, sampleRate: rate, windowStart: start) - expected) <= 0.05)
            }
        }
        #expect(try VoiceLabLoudness.momentaryLufs([Float](repeating: 0, count: 19_200), sampleRate: 48_000, windowStart: 0) == -.infinity)
        #expect(throws: VoiceLabAudioMathError.invalidInput) {
            try VoiceLabLoudness.momentaryLufs([Float](repeating: 0, count: 19_199), sampleRate: 48_000, windowStart: 0)
        }
        #expect(throws: VoiceLabAudioMathError.invalidInput) {
            try VoiceLabLoudness.momentaryLufs([Float](repeating: 0, count: 19_200), sampleRate: 48_000, windowStart: -1)
        }
    }

    @Test func seamJumpComparesTheWindowsEitherSideOfEachSeam() throws {
        // 1 kHz has whole cycles in 0.6 s and 0.25 s, so each level step keeps the sine's phase.
        let steady = Self.sine(1000, peakDbfs: -20, count: 57_600, rate: 48_000)
        #expect(try VoiceLabLoudness.seamJumpLu(steady, sampleRate: 48_000, seamSample: 28_800) < 0.01)
        let rising = Self.sine(1000, peakDbfs: -20, count: 26_460, rate: 44_100) + Self.sine(1000, peakDbfs: -18.1, count: 26_460, rate: 44_100)
        #expect(abs(try VoiceLabLoudness.seamJumpLu(rising, sampleRate: 44_100, seamSample: 26_460) - 1.9) < 0.01)
        let quiet = Self.sine(1000, peakDbfs: -75, count: 48_000, rate: 48_000)
        #expect(try VoiceLabLoudness.seamJumpLu(quiet, sampleRate: 48_000, seamSample: 24_000) == 0)
        // At the buffer edge a window shortens, down to 0.1 s on either side.
        let edge = Self.sine(1000, peakDbfs: -20, count: 12_000, rate: 48_000) + Self.sine(1000, peakDbfs: -21, count: 36_000, rate: 48_000)
        #expect(abs(try VoiceLabLoudness.seamJumpLu(edge, sampleRate: 48_000, seamSample: 12_000) - 1) < 0.01)
        #expect(try VoiceLabLoudness.seamJumpLu(steady, sampleRate: 48_000, seamSample: 4_800) < 0.01)
        #expect(try VoiceLabLoudness.seamJumpLu(steady, sampleRate: 48_000, seamSample: 52_800) < 0.01)
        #expect(throws: VoiceLabAudioMathError.insufficientContext) { try VoiceLabLoudness.seamJumpLu(steady, sampleRate: 48_000, seamSample: 4_799) }
        #expect(throws: VoiceLabAudioMathError.insufficientContext) { try VoiceLabLoudness.seamJumpLu(steady, sampleRate: 48_000, seamSample: 52_801) }
        #expect(throws: VoiceLabAudioMathError.invalidInput) { try VoiceLabLoudness.seamJumpLu(steady, sampleRate: 48_000, seamSample: 57_601) }
        // A digitally silent side counts as −70 LUFS, so a cut into speech reads a finite 47 LU, which fails QA.
        let cut = [Float](repeating: 0, count: 24_000) + Self.sine(1000, peakDbfs: -20, count: 24_000, rate: 48_000)
        #expect(abs(try VoiceLabLoudness.seamJumpLu(cut, sampleRate: 48_000, seamSample: 24_000) - 46.99610474618582) < 1e-6)
        // A recipe carries its largest jump, and 0 when every seam is `none`.
        #expect(try VoiceLabLoudness.lufsJumpLu(edge, sampleRate: 48_000, seamSamples: []) == 0)
        let jumps = try VoiceLabLoudness.seamJumps(rising, sampleRate: 44_100, seamSamples: [8_820, 26_460])
        #expect(jumps.count == 2 && jumps[0] < 0.01)
        #expect(try VoiceLabLoudness.lufsJumpLu(rising, sampleRate: 44_100, seamSamples: [8_820, 26_460]) == jumps[1])
    }

    @Test func flatnessScoresTheSpreadOfMomentaryLoudness() throws {
        let steady = try VoiceLabLoudness.flatnessMeasurement(Self.sine(1000, peakDbfs: -20, count: 96_000, rate: 48_000), sampleRate: 48_000)
        #expect(steady.windows == 17 && steady.flatness > 0.999)
        let halves = Self.sine(1000, peakDbfs: -20, count: 48_000, rate: 48_000) + Self.sine(1000, peakDbfs: -23, count: 48_000, rate: 48_000)
        let stepped = try VoiceLabLoudness.flatnessMeasurement(halves, sampleRate: 48_000)
        #expect(stepped.windows == 17 && abs(stepped.stdev - 1.3864) < 1e-3 && stepped.flatness == 1 - stepped.stdev / 6)
        // The quiet second's windows sit below −70 LUFS and drop out; the loud second and the three windows reaching
        // into it remain.
        let rising = Self.sine(1000, peakDbfs: -80, count: 48_000, rate: 48_000) + Self.sine(1000, peakDbfs: -20, count: 48_000, rate: 48_000)
        let gated = try VoiceLabLoudness.flatnessMeasurement(rising, sampleRate: 48_000)
        #expect(gated.windows == 10 && abs(gated.flatness - 0.6824) < 1e-3)
        let wide = [(35, -10.0), (36, -30.0), (37, -10.0), (38, -30.0)].flatMap { Self.noise(seed: UInt32($0.0), peakDbfs: $0.1, count: 12_000) }
        #expect(try VoiceLabLoudness.flatness(wide, sampleRate: 24_000) == 0)
        let single = try VoiceLabLoudness.flatnessMeasurement(Self.noise(seed: 39, peakDbfs: -20, count: 21_600), sampleRate: 48_000)
        #expect(single.windows == 1 && single.stdev == 0 && single.flatness == 1)
        let silent = try VoiceLabLoudness.flatnessMeasurement([Float](repeating: 0, count: 44_100), sampleRate: 44_100)
        #expect(silent.windows == 0 && silent.flatness == 1)
        #expect(try VoiceLabLoudness.flatness([], sampleRate: 48_000) == 1)
    }

    @Test func conformTrimsSmallDifferencesAndAlignsLargerOnes() throws {
        let rate = 48_000, speech = Self.speech(rate: rate, seed: 100)
        func decide(_ output: [Float], search: Double = VoiceLabConform.cleanAudioSearchSeconds) throws -> VoiceLabConformDecision {
            try VoiceLabConform.decide(inputEnvelope: Self.envelope(speech, rate: rate), outputEnvelope: Self.envelope(output, rate: rate),
                                       inputSamples: speech.count, outputSamples: output.count, sampleRate: rate, searchSeconds: search)
        }
        let silence = { (count: Int) in [Float](repeating: 0, count: count) }
        #expect(try decide(speech + silence(960)) == .trimOrPad(delta: 960))
        #expect(try decide(Array(speech.dropLast(960))) == .trimOrPad(delta: -960))
        // 21 ms late: the nearest whole frame is 20 ms, which is within 20 ms of Δ.
        guard case .shift(let lag, let peak) = try decide(silence(1_008) + speech) else { Issue.record("21 ms late did not shift"); return }
        #expect(lag == 960 && abs(peak - 0.9947) < 1e-3)
        #expect(try decide(silence(5_760) + speech) == .shift(lag: 5_760, peak: 1))
        // Extra audio at the end only: the envelopes align at lag 0, but Δ is 100 ms.
        #expect(try decide(speech + silence(4_800)) == .outOfSync(peak: 1, lag: 0))
        // 0.4 s late lies outside the voice changer's ±0.3 s search and inside Clean audio's ±0.5 s.
        guard case .outOfSync = try decide(silence(19_200) + speech, search: VoiceLabConform.voiceChangerSearchSeconds) else {
            Issue.record("0.4 s late aligned within ±0.3 s"); return
        }
        #expect(try decide(silence(19_200) + speech) == .shift(lag: 19_200, peak: 1))
        guard case .outOfSync(let unrelated, _) = try decide(Self.noise(seed: 399, peakDbfs: -20, count: speech.count + 4_800)) else {
            Issue.record("unrelated audio aligned"); return
        }
        #expect(abs(unrelated - 0.1455) < 1e-3)
    }

    @Test func conformBreaksTiesBySmallestThenNegativeLag() throws {
        func decide(_ input: [Float], _ output: [Float]) throws -> VoiceLabConformDecision {
            try VoiceLabConform.decide(inputEnvelope: AudioEnvelope(sampleRate: 48_000, levels: input),
                                       outputEnvelope: AudioEnvelope(sampleRate: 48_000, levels: output),
                                       inputSamples: input.count * 480, outputSamples: output.count * 480, sampleRate: 48_000,
                                       searchSeconds: VoiceLabConform.voiceChangerSearchSeconds)
        }
        let alternating: [Float] = [1, 0, 1, 0, 1, 0, 1, 0, 1, 0]
        #expect(try decide(alternating, alternating + [1, 0, 1]) == .outOfSync(peak: 1, lag: 0))
        #expect(try decide(alternating, [0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1]) == .outOfSync(peak: 1, lag: -480))
        #expect(VoiceLabConform.correlation([1, 1, 1], [2, 3, 4], lag: 0) == 0)
        #expect(VoiceLabConform.correlation([1, 2, 3], [2, 4, 6], lag: 3) == 0)
        #expect(VoiceLabConform.correlation([1, 2, 3], [9, 2, 4, 6], lag: 1) == 1)
    }

    @Test func conformScoresOnlyOverlapsOfHalfTheShorterEnvelopeAndAtMostOne() {
        let ramp: [Double] = [1, 2, 3, 4, 5, 6]
        // ceil(6 / 2) = 3 frames: a 3-frame overlap scores, a 2-frame one does not.
        #expect(VoiceLabConform.correlation(ramp, ramp, lag: 3) == 1)
        #expect(VoiceLabConform.correlation(ramp, ramp, lag: 4) == 0)
        #expect(VoiceLabConform.correlation(ramp, ramp, lag: -4) == 0)
        // Odd and unequal lengths: the minimum is ceil(min(9, 7) / 2) = 4 frames, not floor (3) or the input's ceil (5).
        let nine: [Double] = [1, 2, 3, 4, 5, 6, 7, 8, 9], seven: [Double] = [1, 2, 3, 4, 5, 6, 7]
        #expect(VoiceLabConform.correlation(nine, seven, lag: 3) == 1)
        #expect(VoiceLabConform.correlation(nine, seven, lag: 4) == 0)
        #expect(VoiceLabConform.correlation(nine, seven, lag: -5) == 1)
        #expect(VoiceLabConform.correlation(nine, seven, lag: -6) == 0)
        // These Float32 levels, one at 0.9 of the other, correlate 1.0000000000000002 before the clamp.
        let level = [Float(1.1), 7.5, 1.3].map(Double.init), quieter = [Float(0.99), 6.75, 1.17].map(Double.init)
        #expect(VoiceLabConform.correlation(level, quieter, lag: 0) == 1)
    }

    @Test func conformRejectsEnvelopesOffTheInputGrid() throws {
        let levels = [Float](repeating: 0.1, count: 100)
        let envelope = AudioEnvelope(sampleRate: 48_000, levels: levels)
        func decide(_ input: AudioEnvelope = envelope, inputSamples: Int = 48_000, rate: Int = 48_000, search: Double = 0.3) throws -> VoiceLabConformDecision {
            try VoiceLabConform.decide(inputEnvelope: input, outputEnvelope: envelope, inputSamples: inputSamples, outputSamples: 48_000,
                                       sampleRate: rate, searchSeconds: search)
        }
        #expect(try decide() == .trimOrPad(delta: 0))
        #expect(try decide(inputSamples: 48_479) == .trimOrPad(delta: -479))
        #expect(throws: VoiceLabAudioMathError.invalidInput) { try decide(inputSamples: 48_480) }
        #expect(throws: VoiceLabAudioMathError.invalidInput) { try decide(AudioEnvelope(sampleRate: 44_100, levels: levels)) }
        #expect(throws: VoiceLabAudioMathError.invalidInput) { try decide(AudioEnvelope(sampleRate: 48_000, frameSeconds: 0.02, levels: levels)) }
        #expect(throws: VoiceLabAudioMathError.invalidInput) { try decide(AudioEnvelope(sampleRate: 48_000, levels: levels.dropLast() + [.nan])) }
        #expect(throws: VoiceLabAudioMathError.invalidInput) { try decide(search: -0.1) }
        #expect(throws: VoiceLabAudioMathError.invalidInput) { try decide(search: .infinity) }
        #expect(throws: VoiceLabAudioMathError.invalidInput) { try decide(rate: 0) }
        // Both frame-length conventions name the same 221-sample frame at 22.05 kHz.
        for frameSeconds in [0.01, 221.0 / 22_050] {
            let odd = AudioEnvelope(sampleRate: 22_050, frameSeconds: frameSeconds, levels: [Float](repeating: 0.1, count: 99))
            #expect(try VoiceLabConform.decide(inputEnvelope: odd, outputEnvelope: odd, inputSamples: 21_879, outputSamples: 21_879,
                                               sampleRate: 22_050, searchSeconds: 0.3) == .trimOrPad(delta: 0))
        }
    }

    @Test func sharedVectorsMatchTheNumPyReference() throws {
        let vectors = try JSONDecoder().decode(Vectors.self, from: FixtureLoader.data("fixtures/voice-lab/audio-math-cases.json"))
        #expect(vectors.version == 1)
        let bounds = vectors.tolerances
        var largest: [String: Double] = [:], anchors: [String] = [], checked = 0
        // A null expectation is −∞ for a peak or a loudness.
        func check(_ metric: String, _ actual: Double, _ expected: Double?, _ bound: Double, _ id: String) {
            guard let expected else { #expect(actual == -.infinity, "\(id) \(metric): \(actual)"); return }
            largest[metric] = max(largest[metric] ?? 0, abs(actual - expected))
            #expect(abs(actual - expected) <= bound, "\(id) \(metric): \(actual) against \(expected)")
        }
        func voiced(_ actual: Double?, _ expected: Double?, _ id: String) {
            #expect((actual == nil) == (expected == nil), "\(id) voicedRmsDb")
            if let actual, let expected { check("voicedRmsDb", actual, expected, bounds.db, id) }
        }
        // The neighbourhood level, or nil where it throws noVoicedAudio.
        func neighbourhood(_ samples: [Float], _ rate: Int, _ window: [Int]) throws -> Double? {
            do {
                return try VoiceLabLoudness.neighbourhoodVoicedRmsDb(samples, sampleRate: rate, window: window[0]..<window[1])
            } catch VoiceLabAudioMathError.noVoicedAudio {
                return nil
            }
        }
        func coefficients(_ stages: (shelf: VoiceLabBiquad, highPass: VoiceLabBiquad)) -> [Double] {
            [stages.shelf, stages.highPass].flatMap { [$0.b0, $0.b1, $0.b2, $0.a1, $0.a2] }
        }
        let published = vectors.publishedKWeighting48k.shelf + vectors.publishedKWeighting48k.highPass
        for (value, reference) in zip(coefficients(VoiceLabLoudness.kWeighting(sampleRate: 48_000)), published) {
            #expect(abs(value - reference) < 1e-6)
        }
        for item in vectors.cases {
            let expected = item.expected
            switch item.kind {
            case "kWeighting":
                let reference = try #require(expected.shelf) + #require(expected.highPass)
                for (value, coefficient) in zip(coefficients(VoiceLabLoudness.kWeighting(sampleRate: try #require(item.rate))), reference) {
                    check("coefficient", value, coefficient, bounds.coefficient, item.id)
                }
            case "voiced":
                let signal = try #require(item.signal)
                voiced(try VoiceLabLoudness.voicedRmsDb(Self.render(signal), sampleRate: signal.rate), expected.voicedRmsDb, item.id)
            case "peaks":
                let signal = try #require(item.signal), samples = try Self.render(signal)
                #expect(VoiceLabLoudness.oversampling(sampleRate: signal.rate) == expected.oversampling, "\(item.id)")
                check("samplePeakDbfs", try VoiceLabLoudness.samplePeakDbfs(samples), expected.samplePeakDbfs, bounds.db, item.id)
                check("truePeakDbtp", try VoiceLabLoudness.truePeakDbtp(samples, sampleRate: signal.rate), expected.truePeakDbtp, bounds.truePeakDb, item.id)
            case "neighbourhood":
                let signal = try #require(item.signal)
                let level = try neighbourhood(Self.render(signal), signal.rate, try #require(item.window))
                #expect((level == nil) == (expected.error == "noVoicedAudio"), "\(item.id)")
                voiced(level, expected.voicedRmsDb, item.id)
            case "levelGain":
                let source = try #require(item.source), candidate = try #require(item.candidate), window = try #require(item.window)
                let sourceSamples = try Self.render(source), candidateSamples = try Self.render(candidate)
                voiced(try neighbourhood(sourceSamples, source.rate, window), expected.sourceVoicedRmsDb, item.id)
                voiced(try VoiceLabLoudness.voicedRmsDb(candidateSamples, sampleRate: candidate.rate), expected.candidateVoicedRmsDb, item.id)
                check("truePeakDbtp", try VoiceLabLoudness.truePeakDbtp(candidateSamples, sampleRate: candidate.rate),
                      expected.candidateTruePeakDbtp, bounds.truePeakDb, item.id)
                let gain = {
                    try VoiceLabLoudness.levelGainDb(source: sourceSamples, sourceSampleRate: source.rate, window: window[0]..<window[1],
                                                     candidate: candidateSamples, candidateSampleRate: candidate.rate)
                }
                if expected.error == "noVoicedAudio" {
                    #expect(throws: VoiceLabAudioMathError.noVoicedAudio, "\(item.id)") { try gain() }
                } else {
                    check("gainDb", try gain(), expected.gainDb, bounds.db, item.id)
                }
            case "momentary":
                let signal = try #require(item.signal)
                let lufs = try VoiceLabLoudness.momentaryLufs(Self.render(signal), sampleRate: signal.rate, windowStart: try #require(item.windowStart))
                check("momentaryLufs", lufs, expected.lufs, bounds.db, item.id)
                if item.id.hasPrefix("anchor-") { anchors.append("\(item.id)=\(lufs)") }
            case "seamJump":
                let signal = try #require(item.signal), samples = try Self.render(signal), seams = try #require(item.seams)
                if expected.error == "insufficientContext" {
                    #expect(throws: VoiceLabAudioMathError.insufficientContext, "\(item.id)") {
                        try VoiceLabLoudness.lufsJumpLu(samples, sampleRate: signal.rate, seamSamples: seams)
                    }
                } else {
                    let jumps = try VoiceLabLoudness.seamJumps(samples, sampleRate: signal.rate, seamSamples: seams)
                    let references = try #require(expected.jumps)
                    #expect(jumps.count == references.count, "\(item.id)")
                    for (jump, reference) in zip(jumps, references) { check("seamJumpLu", jump, reference, bounds.db, item.id) }
                    check("lufsJumpLu", try VoiceLabLoudness.lufsJumpLu(samples, sampleRate: signal.rate, seamSamples: seams),
                          expected.lufsJumpLu, bounds.db, item.id)
                }
            case "flatness":
                let signal = try #require(item.signal)
                let measured = try VoiceLabLoudness.flatnessMeasurement(Self.render(signal), sampleRate: signal.rate)
                #expect(measured.windows == expected.windows, "\(item.id)")
                check("flatnessStdev", measured.stdev, expected.stdev, bounds.db, item.id)
                check("flatness", measured.flatness, expected.flatness, bounds.flatness, item.id)
            case "conform", "conformEnvelope":
                let decision: VoiceLabConformDecision
                if item.kind == "conform" {
                    let input = try #require(item.input), output = try #require(item.output)
                    let a = try Self.render(input), b = try Self.render(output)
                    decision = try VoiceLabConform.decide(
                        inputEnvelope: Self.envelope(a, rate: input.rate), outputEnvelope: Self.envelope(b, rate: output.rate),
                        inputSamples: a.count, outputSamples: b.count, sampleRate: input.rate, searchSeconds: try #require(item.searchSeconds))
                } else {
                    let rate = try #require(item.rate)
                    decision = try VoiceLabConform.decide(
                        inputEnvelope: AudioEnvelope(sampleRate: Double(rate), levels: try #require(item.inputLevels)),
                        outputEnvelope: AudioEnvelope(sampleRate: Double(rate), levels: try #require(item.outputLevels)),
                        inputSamples: try #require(item.inputSamples), outputSamples: try #require(item.outputSamples),
                        sampleRate: rate, searchSeconds: try #require(item.searchSeconds))
                }
                switch decision {
                case .trimOrPad(let delta):
                    #expect(expected.kind == "trimOrPad" && delta == expected.delta, "\(item.id): \(decision)")
                case .shift(let lag, let peak):
                    #expect(expected.kind == "shift" && lag == expected.lag, "\(item.id): \(decision)")
                    check("conformPeak", peak, expected.peak, bounds.correlation, item.id)
                case .outOfSync(let peak, let lag):
                    #expect(expected.kind == "outOfSync" && lag == expected.lag, "\(item.id): \(decision)")
                    check("conformPeak", peak, expected.peak, bounds.correlation, item.id)
                }
            default:
                Issue.record("Unknown audio math case kind \(item.kind) in \(item.id)")
                continue
            }
            checked += 1
        }
        #expect(checked == vectors.cases.count && checked >= 92)
        print("audio-math vectors: \(checked) cases; anchors \(anchors.joined(separator: " "))")
        print("audio-math largest difference per metric: " + largest.keys.sorted().map { "\($0)=\(largest[$0]!)" }.joined(separator: " "))
    }

    /// One timed pass of the measurements a caller makes on a 60 s, 48 kHz take: a single measurement, no repetition.
    /// It counts this thread's CPU time, so other work on a shared machine does not stretch the measurement.
    // CPU time, because Swift Testing runs other suites in parallel on this shared Mac; Windows times wall clock alone.
    @Test func sixtySecondsAt48kHzMeasureWithinTwoSeconds() throws {
        let rate = 48_000, speech = Self.speech(rate: rate, seed: 500)
        var input: [Float] = []
        while input.count < 60 * rate { input += speech }
        input.removeLast(input.count - 60 * rate)
        let output = [Float](repeating: 0, count: 4_800) + input
        let inputEnvelope = Self.envelope(input, rate: rate), outputEnvelope = Self.envelope(output, rate: rate)
        let started = ContinuousClock.now, startedCPU = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        _ = try VoiceLabLoudness.levelGainDb(source: input, sourceSampleRate: rate, window: 29 * rate..<31 * rate, candidate: input,
                                             candidateSampleRate: rate)
        _ = try VoiceLabLoudness.samplePeakDbfs(input)
        _ = try VoiceLabLoudness.lufsJumpLu(input, sampleRate: rate, seamSamples: [20 * rate, 40 * rate])
        _ = try VoiceLabLoudness.flatness(input, sampleRate: rate)
        _ = try VoiceLabConform.decide(inputEnvelope: inputEnvelope, outputEnvelope: outputEnvelope, inputSamples: input.count,
                                       outputSamples: output.count, sampleRate: rate, searchSeconds: VoiceLabConform.cleanAudioSearchSeconds)
        let cpu = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - startedCPU) / 1e9, wall = ContinuousClock.now - started
        print("audio-math 60 s at 48 kHz: \(cpu) s CPU, \(wall) wall")
        #expect(cpu < 2, "60 s at 48 kHz took \(cpu) s of CPU time")
    }
}
