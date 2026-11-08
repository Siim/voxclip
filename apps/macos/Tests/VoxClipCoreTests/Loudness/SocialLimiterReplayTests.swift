import Foundation
import Testing
@testable import VoxClipCore

/// The social-loudness true-peak limiter (ADR-R47, amended 2026-11-08) replayed from
/// shared/fixtures/loudness/social-limiter-cases.json, which tools/fixtures/loudness/generate_social_loudness.py writes
/// and Windows Core SocialLimiterReplayTests replays.
struct SocialLimiterReplayTests {
    private static func document() throws -> [String: JSONValue] {
        try #require(JSONDecoder().decode(JSONValue.self, from: FixtureLoader.data("fixtures/loudness/social-limiter-cases.json")).aiObject)
    }
    private static func cases(_ kind: String) throws -> [JSONValue] {
        try document()["cases"]?.aiArray.filter { $0[ai: "kind"].aiString == kind } ?? []
    }
    private static func near(_ expected: JSONValue, _ actual: Double?, _ tolerance: Double = 1e-6) -> Bool {
        guard let wanted = expected.aiDouble else { return actual == nil }
        guard let actual else { return false }
        return abs(wanted - actual) < tolerance
    }

    /// Streams `samples` through `limiter` in uneven chunks, so the lookahead and the detection history cross every
    /// kind of boundary, and returns every output frame.
    static func stream(_ samples: [Float], through limiter: inout SocialLimiter) -> [Float] {
        var output: [Float] = []
        output.reserveCapacity(samples.count)
        var start = 0, chunk = 1
        samples.withUnsafeBufferPointer { buffer in
            while start < buffer.count {
                let end = min(buffer.count, start + 2 * chunk)
                var piece = [Float](repeating: 0, count: end - start)
                let written = piece.withUnsafeMutableBufferPointer {
                    limiter.process(UnsafeBufferPointer(rebasing: buffer[start..<end]), into: $0)
                }
                output.append(contentsOf: piece.prefix(2 * written))
                start = end; chunk = chunk * 7 % 5003 + 1
            }
        }
        output.append(contentsOf: limiter.finish())
        return output
    }

    static func measure(_ samples: [Float]) throws -> SocialLoudnessMeasurement {
        var meter = try SocialLoudnessMeter(sampleRate: 48_000, channels: 2)
        try meter.append(samples)
        return meter.finish()
    }

    /// The whole rule over one mix, as the exporters run it: measure, plan, simulate and land, export.
    static func export(_ samples: [Float]) throws -> (plan: SocialLoudnessDecision, trials: [(gainDb: Double, lufs: Double?)],
                                                       decision: SocialLoudnessDecision, output: [Float],
                                                       limiter: SocialLimiter, report: SocialLoudnessReport) {
        let measurement = try measure(samples)
        let plan = SocialLoudness.decide(measuredLufs: measurement.integratedLufs(), truePeakDbtp: measurement.truePeakDbtp)
        var trials: [(gainDb: Double, lufs: Double?)] = []
        var settled: SocialLoudnessDecision?
        while settled == nil {
            switch SocialLoudness.landing(plan, truePeakDbtp: measurement.truePeakDbtp, trials: trials) {
            case .settled(let decision): settled = decision
            case .simulate(let gain):
                var limiter = try SocialLimiter(gainDb: gain, limiting: true, sampleRate: 48_000, channels: 2)
                trials.append((gain, try measure(stream(samples, through: &limiter)).integratedLufs()))
            }
        }
        let decision = try #require(settled)
        var limiter = try SocialLimiter(gainDb: decision.gainDb, limiting: decision.limiting, sampleRate: 48_000, channels: 2)
        let output = stream(samples, through: &limiter)
        let report = SocialLoudness.report(measurement: measurement, decision: decision, limiter: limiter,
                                           output: decision.limiting ? try measure(output) : nil)
        return (plan, trials, decision, output, limiter, report)
    }

    /// Every probe: [frame, reductionDb, left, right]; the reduction is read back from the output over the gained input.
    static func checkProbes(_ item: JSONValue, input: [Float], output: [Float], gainDb: Double) {
        let id = item[ai: "id"].aiString ?? ""
        let gain = pow(10, gainDb / 20)
        for probe in item[ai: "probes"].aiArray {
            let values = probe.aiArray
            let frame = values[0].aiInt ?? -1
            #expect(abs(Double(output[2 * frame]) - (values[2].aiDouble ?? .nan)) < 2e-6, "\(id) left @\(frame)")
            #expect(abs(Double(output[2 * frame + 1]) - (values[3].aiDouble ?? .nan)) < 2e-6, "\(id) right @\(frame)")
            // Where the input is far from zero, the output over the gained input is the reduction.
            let source = Double(input[2 * frame]) * gain
            if abs(source) > 1e-3 {
                let reduction = -20 * log10(Double(output[2 * frame]) / source)
                #expect(abs(reduction - (values[1].aiDouble ?? .nan)) < 1e-4, "\(id) reduction @\(frame): \(reduction)")
            }
        }
    }

    @Test("The file has its keys, its counts and the Mac's constants")
    func fileShape() throws {
        let document = try Self.document()
        #expect(Set(document.keys) == ["format", "description", "constants", "caseCount", "counts", "cases"])
        #expect(document["format"]?.aiString == "voxclip-social-limiter-cases/1")
        #expect(document["caseCount"]?.aiInt == 7 && document["cases"]?.aiArray.count == 7)
        #expect(document["counts"]?[ai: "export"].aiInt == 6 && document["counts"]?[ai: "envelope"].aiInt == 1)
        let constants = try #require(document["constants"]?.aiObject)
        let expected: [String: Double] = [
            "targetLufs": SocialLoudness.targetLufs, "ceilingDbtp": SocialLoudness.ceilingDbtp,
            "maximumReductionDb": SocialLoudness.maximumReductionDb, "lookaheadSeconds": SocialLimiter.lookaheadSeconds,
            "lookaheadFrames": 240, "releaseSeconds": SocialLimiter.releaseSeconds,
            "releaseFloorDb": SocialLimiter.releaseFloorDb, "detectionTaps": Double(SocialLimiter.detectionTaps),
            "landingToleranceLu": SocialLoudness.landingToleranceLu,
        ]
        #expect(Set(constants.keys) == Set(expected.keys))
        for (key, value) in expected { #expect(abs((constants[key]?.aiDouble ?? .nan) - value) < 1e-12, "\(key)") }
        let limiter = try SocialLimiter(gainDb: 0, limiting: true, sampleRate: 48_000, channels: 2)
        #expect(limiter.latency == 240 + 11)
    }

    @Test("Export cases: the plan, the simulated pre-passes that land it, the output and its samples")
    func exports() throws {
        let cases = try Self.cases("export")
        #expect(cases.count == 6)
        for item in cases {
            let id = item[ai: "id"].aiString ?? ""
            let samples = SocialLoudnessReplayTests.interleaved(item)
            #expect(samples.count == 2 * (item[ai: "frames"].aiInt ?? -1), "\(id) frames")
            let run = try Self.export(samples)
            let expected = item[ai: "expected"]
            #expect(run.output.count == samples.count, "\(id) every frame out")
            #expect(Self.near(expected[ai: "measuredLufs"], run.report.measuredLufs), "\(id) measured")
            #expect(Self.near(expected[ai: "plan"][ai: "gainDb"], run.plan.gainDb), "\(id) plan gain")
            #expect(run.plan.limit.rawValue == expected[ai: "plan"][ai: "limit"].aiString, "\(id) plan limit")
            #expect(run.plan.limiting == expected[ai: "plan"][ai: "limiting"].aiBool, "\(id) plan limiting")
            let trials = expected[ai: "trials"].aiArray
            #expect(run.trials.count == trials.count, "\(id) trials \(run.trials)")
            for (trial, wanted) in zip(run.trials, trials) {
                #expect(Self.near(wanted.aiArray[0], trial.gainDb) && Self.near(wanted.aiArray[1], trial.lufs), "\(id) trial \(trial)")
            }
            #expect(Self.near(expected[ai: "gainDb"], run.report.gainDb), "\(id) gain \(run.report.gainDb)")
            #expect(run.decision.limit.rawValue == expected[ai: "limit"].aiString, "\(id) limit")
            #expect(run.report.capped == expected[ai: "capped"].aiBool, "\(id) capped")
            #expect(run.decision.limiting == expected[ai: "limiting"].aiBool, "\(id) limiting")
            #expect(Self.near(expected[ai: "outputLufs"], run.report.outputLufs), "\(id) output \(String(describing: run.report.outputLufs))")
            #expect(Self.near(expected[ai: "outputTruePeakDbtp"], run.report.truePeakDbtp), "\(id) output peak")
            #expect(Self.near(expected[ai: "limiterMaxReductionDb"], run.report.limiterMaxReductionDb), "\(id) reduction")
            #expect(abs(run.limiter.limitedFrames - (expected[ai: "limitedFrames"].aiInt ?? -9)) <= 2, "\(id) limited \(run.limiter.limitedFrames)")
            #expect(abs(run.report.limitedPercent - (expected[ai: "limitedPercent"].aiDouble ?? .nan)) < 0.01, "\(id) limited share")
            if let peak = run.report.truePeakDbtp { #expect(peak <= SocialLoudness.ceilingDbtp + 1e-6, "\(id) ceiling \(peak)") }
            if run.decision.limit == .none, let output = run.report.outputLufs {
                #expect(abs(output - SocialLoudness.targetLufs) <= 0.5, "\(id) lands \(output)")
            }
            Self.checkProbes(item, input: samples, output: run.output, gainDb: run.decision.gainDb)
        }
    }

    @Test("Gain alone leaves every sample at Float(sample × gain), with no latency")
    func pureGainIsExact() throws {
        let item = try #require(Self.cases("export").first { $0[ai: "id"].aiString == "talk-pure-gain" })
        let samples = SocialLoudnessReplayTests.interleaved(item)
        let run = try Self.export(samples)
        #expect(!run.decision.limiting && run.limiter.latency == 0 && run.limiter.limitedFrames == 0)
        let gain = pow(10, run.decision.gainDb / 20)
        #expect(run.output.indices.allSatisfy { run.output[$0] == Float(Double(samples[$0]) * gain) })
    }

    @Test("Envelope: the raised-cosine attack before the click, the hold over its detection and the 80 ms release")
    func envelope() throws {
        let cases = try Self.cases("envelope")
        #expect(cases.count == 1)
        for item in cases {
            let id = item[ai: "id"].aiString ?? ""
            let samples = SocialLoudnessReplayTests.interleaved(item)
            let gainDb = item[ai: "gainDb"].aiDouble ?? .nan
            var limiter = try SocialLimiter(gainDb: gainDb, limiting: true, sampleRate: 48_000, channels: 2)
            let output = Self.stream(samples, through: &limiter)
            let expected = item[ai: "expected"]
            #expect(output.count == samples.count)
            #expect(Self.near(expected[ai: "outputTruePeakDbtp"], try Self.measure(output).truePeakDbtp), "\(id) peak")
            #expect(Self.near(expected[ai: "limiterMaxReductionDb"], limiter.maximumReductionDb), "\(id) reduction")
            #expect(abs(limiter.limitedFrames - (expected[ai: "limitedFrames"].aiInt ?? -9)) <= 2, "\(id) limited")
            Self.checkProbes(item, input: samples, output: output, gainDb: gainDb)
        }
    }

    @Test("Invalid parameters throw; frames under the ceiling far from a peak pass with the gain alone")
    func parametersAndPassThrough() throws {
        #expect(throws: VoiceLabAudioMathError.invalidInput) { _ = try SocialLimiter(gainDb: .nan, limiting: true, sampleRate: 48_000, channels: 2) }
        #expect(throws: VoiceLabAudioMathError.invalidInput) { _ = try SocialLimiter(gainDb: 0, limiting: true, sampleRate: 96_000, channels: 2) }
        // A quiet tone with one loud frame in the middle: only the frames within the lookahead before it and the
        // release after it change.
        var samples = (0..<9600).flatMap { index -> [Float] in
            let value = Float(0.1 * sin(Double(index) * 0.05))
            return [value, value]
        }
        samples[2 * 4800] = 1.5
        var limiter = try SocialLimiter(gainDb: 0, limiting: true, sampleRate: 48_000, channels: 2)
        let output = Self.stream(samples, through: &limiter)
        let first = output.indices.first { output[$0] != samples[$0] }.map { $0 / 2 } ?? -1
        #expect(first >= 4800 - 251 && first < 4800, "first changed frame \(first)")
        #expect(output[0..<(2 * (4800 - 251))].elementsEqual(samples[0..<(2 * (4800 - 251))]))
        #expect(abs(limiter.maximumReductionDb - (20 * log10(1.5) + 1)) < 0.5)
    }
}
