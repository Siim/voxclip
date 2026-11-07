import Foundation
import Testing
@testable import VoxClipCore

/// Social loudness (ADR-R47) replayed from shared/fixtures/loudness/social-loudness-cases.json, which
/// tools/fixtures/loudness/generate_social_loudness.py writes and Windows Core SocialLoudnessReplayTests replays.
struct SocialLoudnessReplayTests {
    private static func document() throws -> [String: JSONValue] {
        try #require(JSONDecoder().decode(JSONValue.self, from: FixtureLoader.data("fixtures/loudness/social-loudness-cases.json")).aiObject)
    }
    private static func cases(_ kind: String) throws -> [JSONValue] {
        try document()["cases"]?.aiArray.filter { $0[ai: "kind"].aiString == kind } ?? []
    }
    private static func near(_ expected: JSONValue, _ actual: Double?, _ tolerance: Double = 1e-6) -> Bool {
        guard let wanted = expected.aiDouble else { return actual == nil }
        guard let actual else { return false }
        return abs(wanted - actual) < tolerance
    }

    /// One channel of a vector signal, rendered in Float64 and stored as Float32 like the generator.
    static func render(_ parts: [JSONValue], rate: Double) -> [Float] {
        var output: [Float] = []
        for part in parts {
            let count = part[ai: "samples"].aiInt ?? 0
            switch part[ai: "type"].aiString {
            case "sine":
                let amplitude = pow(10, (part[ai: "peakDbfs"].aiDouble ?? 0) / 20)
                let frequency = part[ai: "frequency"].aiDouble ?? 0
                for index in 0..<count {
                    let phase: Double = 2 * Double.pi * frequency * Double(index) / rate
                    output.append(Float(amplitude * sin(phase)))
                }
            case "noise":
                let amplitude = pow(10, (part[ai: "peakDbfs"].aiDouble ?? 0) / 20)
                let hann = part[ai: "envelope"].aiString == "hann"
                var state = UInt64(part[ai: "seed"].aiInt ?? 0)
                for index in 0..<count {
                    state = (1_664_525 * state + 1_013_904_223) % 4_294_967_296
                    var value: Double = amplitude * (Double(state) / 2_147_483_648 - 1)
                    if hann {
                        let window: Double = 0.5 - 0.5 * cos(2 * Double.pi * Double(index) / Double(count))
                        value *= window
                    }
                    output.append(Float(value))
                }
            default:
                output.append(contentsOf: repeatElement(0, count: count))
            }
        }
        return output
    }

    /// The case's stereo signal, interleaved.
    static func interleaved(_ item: JSONValue) -> [Float] {
        let rate = item[ai: "rate"].aiDouble ?? 48_000
        let channels = item[ai: "channels"].aiArray.map { render($0.aiArray, rate: rate) }
        let frames = channels[0].count
        var output = [Float](repeating: 0, count: frames * channels.count)
        for (channel, samples) in channels.enumerated() {
            for frame in 0..<frames { output[frame * channels.count + channel] = samples[frame] }
        }
        return output
    }

    @Test("The file has its keys, its counts and the Mac's constants")
    func fileShape() throws {
        let document = try Self.document()
        #expect(Set(document.keys) == ["format", "description", "constants", "caseCount", "counts", "cases"])
        #expect(document["format"]?.aiString == "voxclip-social-loudness-cases/1")
        #expect(document["caseCount"]?.aiInt == 24)
        #expect(document["counts"]?[ai: "rule"].aiInt == 12 && document["counts"]?[ai: "signal"].aiInt == 12)
        #expect(document["cases"]?.aiArray.count == 24)
        let constants = try #require(document["constants"]?.aiObject)
        let expected: [String: Double] = [
            "targetLufs": SocialLoudness.targetLufs, "ceilingDbtp": SocialLoudness.ceilingDbtp,
            "maximumBoostDb": SocialLoudness.maximumBoostDb, "maximumCutDb": SocialLoudness.maximumCutDb,
            "absoluteGateLufs": SocialLoudness.absoluteGateLufs, "relativeGateLu": SocialLoudness.relativeGateLu,
            "blockSeconds": SocialLoudness.stepSeconds * Double(SocialLoudness.blockSteps), "stepSeconds": SocialLoudness.stepSeconds,
        ]
        #expect(Set(constants.keys) == Set(expected.keys))
        for (key, value) in expected { #expect(abs((constants[key]?.aiDouble ?? .nan) - value) < 1e-12, "\(key)") }
    }

    @Test("The rule: target, boost and cut limits, the true-peak cap and silence")
    func rule() throws {
        let cases = try Self.cases("rule")
        #expect(cases.count == 12)
        for item in cases {
            let id = item[ai: "id"].aiString ?? ""
            let decision = SocialLoudness.decide(measuredLufs: item[ai: "measuredLufs"].aiDouble, truePeakDbtp: item[ai: "truePeakDbtp"].aiDouble)
            let expected = item[ai: "expected"]
            #expect(Self.near(expected[ai: "gainDb"], decision.gainDb), "\(id) gain")
            #expect(decision.limit.rawValue == expected[ai: "limit"].aiString, "\(id) limit")
            #expect(decision.capped == expected[ai: "capped"].aiBool, "\(id) capped")
        }
    }

    @Test("Signals: integrated loudness, true peak, the gain and the result, streamed in uneven chunks")
    func signals() throws {
        let cases = try Self.cases("signal")
        #expect(cases.count == 12)
        for item in cases {
            let id = item[ai: "id"].aiString ?? ""
            let samples = Self.interleaved(item)
            #expect(samples.count == 2 * (item[ai: "frames"].aiInt ?? -1), "\(id) frames")
            // Uneven chunks, so steps and the true-peak history cross every kind of boundary.
            var meter = try SocialLoudnessMeter(sampleRate: 48_000, channels: 2)
            var start = 0, chunk = 1
            try samples.withUnsafeBufferPointer { buffer in
                while start < buffer.count {
                    let end = min(buffer.count, start + 2 * chunk)
                    try meter.append(UnsafeBufferPointer(rebasing: buffer[start..<end]))
                    start = end; chunk = chunk * 7 % 5003 + 1
                }
            }
            let measurement = meter.finish()
            let (decision, report) = SocialLoudness.report(measurement)
            let expected = item[ai: "expected"]
            #expect(Self.near(expected[ai: "measuredLufs"], report.measuredLufs), "\(id) measured \(String(describing: report.measuredLufs))")
            #expect(Self.near(expected[ai: "truePeakDbtp"], measurement.truePeakDbtp), "\(id) true peak \(String(describing: measurement.truePeakDbtp))")
            #expect(Self.near(expected[ai: "gainDb"], report.gainDb), "\(id) gain")
            #expect(decision.limit.rawValue == expected[ai: "limit"].aiString, "\(id) limit \(decision.limit)")
            #expect(report.capped == expected[ai: "capped"].aiBool, "\(id) capped")
            #expect(Self.near(expected[ai: "outputLufs"], report.outputLufs), "\(id) output")
            #expect(Self.near(expected[ai: "outputTruePeakDbtp"], report.truePeakDbtp), "\(id) output peak")
        }
    }

    @Test("One append and the whole-buffer Voice Lab definitions agree with the streamed meter")
    func streamedEqualsWhole() throws {
        let item = try #require(Self.cases("signal").first { $0[ai: "id"].aiString == "speech-clicks-peak-cap" })
        let samples = Self.interleaved(item)
        var whole = try SocialLoudnessMeter(sampleRate: 48_000, channels: 2)
        try whole.append(samples)
        let measurement = whole.finish()
        let left = stride(from: 0, to: samples.count, by: 2).map { samples[$0] }
        let right = stride(from: 1, to: samples.count, by: 2).map { samples[$0] }
        let peak = max(try VoiceLabLoudness.truePeakDbtp(left, sampleRate: 48_000), try VoiceLabLoudness.truePeakDbtp(right, sampleRate: 48_000))
        #expect(abs(try #require(measurement.truePeakDbtp) - peak) < 1e-12)
        #expect(abs(try #require(measurement.integratedLufs()) - (item[ai: "expected"][ai: "measuredLufs"].aiDouble ?? 0)) < 1e-6)
    }

    @Test("A non-finite sample is invalid; the report encodes all five keys with nulls")
    func invalidInputAndReportShape() throws {
        var meter = try SocialLoudnessMeter(sampleRate: 48_000, channels: 2)
        #expect(throws: VoiceLabAudioMathError.invalidInput) { try meter.append([0, .nan]) }
        #expect(throws: VoiceLabAudioMathError.invalidInput) { _ = try SocialLoudnessMeter(sampleRate: 96_000, channels: 2) }
        let silent = SocialLoudnessReport(measuredLufs: nil, gainDb: 0, outputLufs: nil, truePeakDbtp: nil, capped: false)
        let encoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(silent))
        #expect(Set(encoded.aiObject?.keys.map { $0 } ?? []) == ["measuredLufs", "gainDb", "outputLufs", "truePeakDbtp", "capped"])
        #expect(encoded[ai: "measuredLufs"] == .null && encoded[ai: "gainDb"].aiDouble == 0)
        #expect(try JSONDecoder().decode(SocialLoudnessReport.self, from: JSONEncoder().encode(silent)) == silent)
        let report = SocialLoudnessReport(measuredLufs: -20.71, gainDb: 6.71, outputLufs: -14, truePeakDbtp: -3.456, capped: false)
        #expect(report.logLine == "loudness measured=-20.71 gain=6.71 output=-14.00 truePeak=-3.46 capped=false")
        #expect(silent.logLine == "loudness measured=none gain=0.00 output=none truePeak=none capped=false")
        #expect(SocialLoudness.linearGain(-20) == Float(0.1))
    }
}
