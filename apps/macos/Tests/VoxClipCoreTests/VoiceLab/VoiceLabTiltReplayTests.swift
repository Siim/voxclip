#if DEBUG
import Foundation
import Testing
@testable import VoxClipCore

/// Replays shared/fixtures/voice-lab/tilt-cases.json (voice-lab §8.7 item 2b): the tone match's band measurement, slope,
/// clamped stepped tilt, and its shelf cascade's coefficients, magnitude and outputs. Fails on an unknown kind.
@Suite("Tone match vectors", .offlineFixtures)
struct VoiceLabTiltReplayTests {
    private struct Document: Decodable {
        let schema: String
        let constants: Constants
        let tolerances: Tolerances
        let caseCount: Int
        let cases: [Case]
    }
    private struct Constants: Decodable {
        let maximumDbPerOctave: Double; let stepDbPerOctave: Double; let pivotHz: Double; let shelfHz: [Double]
        let bandIndices: [Int]; let voicedRmsDb: Double; let minimumBands: Int; let neighbourhoodSeconds: Double
    }
    private struct Tolerances: Decodable { let coefficient: Double; let magnitudeDb: Double; let output: Double; let levelDb: Double; let slope: Double }
    struct Signal: Decodable {
        let seed: UInt32; let samples: Int; let shape: String; let shift: Int?; let quiet: [[Int]]?
    }
    private struct Input: Decodable { let impulse: Int?; let signal: Signal?; let window: [Int]? }
    private struct Expected: Decodable {
        let frameSize: Int?; let bins: [[Int]?]?
        let sections: [[Double]]?; let magnitudeDb: [[Double]]?
        let output: [Double]?
        let frames: Int?; let levelsDb: [Double?]?; let slopeDbPerOctave: Double?
        let tiltDbPerOctave: Double?; let sourceSlope: Double?; let takeSlope: Double?
    }
    private struct Case: Decodable {
        let kind: String; let name: String
        let sampleRate: Int?; let tiltDbPerOctave: Double?
        let input: Input?; let source: String?; let take: String?
        let expected: Expected
    }

    /// The generator's signals: integer LCG noise, exact in Float32.
    static func render(_ signal: Signal) -> [Float] {
        var state = signal.seed
        let scale = pow(2.0, -Double(signal.shift ?? 0))
        var base: [Double] = []
        for _ in 0..<(signal.samples + 3) {
            state = state &* 1_664_525 &+ 1_013_904_223
            base.append((Double(state >> 16) / 32_768 - 1) * scale)
        }
        var values: [Double]
        switch signal.shape {
        case "white": values = Array(base[3...])
        case "bright": values = (0..<signal.samples).map { (base[$0 + 3] - base[$0 + 2]) / 2 }
        case "warm": values = (0..<signal.samples).map { (base[$0 + 3] + base[$0 + 2] / 2) / 2 }
        case "dark": values = (0..<signal.samples).map { (base[$0] + base[$0 + 1] + base[$0 + 2] + base[$0 + 3]) / 4 }
        default: Issue.record("unknown shape \(signal.shape)"); values = []
        }
        for range in signal.quiet ?? [] { for index in range[0]..<range[1] { values[index] *= pow(2.0, -12) } }
        return values.map { Float($0) }
    }

    private func levels(_ bands: VoiceLabTilt.Bands) -> [Double?] {
        VoiceLabTilt.bandIndices.enumerated().map { band, index in
            guard let power = bands.power[band], power > 0, bands.frames > 0 else { return nil }
            let count = VoiceLabTilt.bins(band: index, sampleRate: bands.sampleRate, frameSize: bands.frameSize).count
            return 10 * log10(power / Double(count * bands.frames))
        }
    }
    private func close(_ actual: Double?, _ expected: Double?, _ tolerance: Double) -> Bool {
        switch (actual, expected) {
        case (nil, nil): true
        case let (actual?, expected?): abs(actual - expected) <= tolerance
        default: false
        }
    }

    @Test func replaysEveryToneMatchVector() throws {
        let document = try JSONDecoder().decode(Document.self, from: FixtureLoader.data("fixtures/voice-lab/tilt-cases.json"))
        #expect(document.schema == "voxclip-voice-lab-tilt/1" && document.caseCount == document.cases.count)
        let constants = document.constants, tolerance = document.tolerances
        #expect(constants.maximumDbPerOctave == VoiceLabTilt.maximumDbPerOctave && constants.stepDbPerOctave == VoiceLabTilt.stepDbPerOctave)
        #expect(constants.pivotHz == VoiceLabTilt.pivotHz && constants.shelfHz == VoiceLabTilt.shelfHz && constants.bandIndices == VoiceLabTilt.bandIndices)
        #expect(abs(pow(10, constants.voicedRmsDb / 20) - VoiceLabTilt.voicedRms) < 1e-15 && constants.minimumBands == VoiceLabTilt.minimumBands)
        #expect(constants.neighbourhoodSeconds == VoiceLabLoudness.loudnessNeighbourhoodSeconds)
        var measured: [String: VoiceLabTilt.Bands] = [:]
        var kinds: Set<String> = []
        for item in document.cases {
            kinds.insert(item.kind)
            switch item.kind {
            case "frameSize":
                let rate = try #require(item.sampleRate)
                let size = VoiceLabTilt.frameSize(sampleRate: rate)
                #expect(size == item.expected.frameSize, "\(item.name)")
                let bins = VoiceLabTilt.bandIndices.map { VoiceLabTilt.bins(band: $0, sampleRate: rate, frameSize: size) }
                    .map { $0.isEmpty ? nil : [$0.lowerBound, $0.upperBound] }
                #expect(bins == item.expected.bins, "\(item.name)")
            case "sections":
                let rate = try #require(item.sampleRate), tilt = try #require(item.tiltDbPerOctave)
                let sections = VoiceLabTilt.sections(tiltDbPerOctave: tilt, sampleRate: rate)
                let expected = try #require(item.expected.sections)
                #expect(sections.count == expected.count, "\(item.name)")
                for (section, values) in zip(sections, expected) {
                    #expect(close(section.b0, values[0], tolerance.coefficient) && close(section.b1, values[1], tolerance.coefficient)
                            && close(section.a1, values[2], tolerance.coefficient), "\(item.name)")
                }
                for pair in try #require(item.expected.magnitudeDb) {
                    let actual: Double = 20 * log10(VoiceLabTilt.magnitude(sections, hertz: pair[0], sampleRate: rate))
                    #expect(close(actual, pair[1], tolerance.magnitudeDb), "\(item.name) at \(pair[0]) Hz")
                }
            case "filter":
                let rate = try #require(item.sampleRate), tilt = try #require(item.tiltDbPerOctave)
                let input: [Float]
                if let impulse = item.input?.impulse { input = [1] + [Float](repeating: 0, count: impulse - 1) }
                else { input = Self.render(try #require(item.input?.signal)) }
                var filter = VoiceLabTilt.Filter(VoiceLabTilt.sections(tiltDbPerOctave: tilt, sampleRate: rate))
                let actual = input.map { filter.step(Double($0)) }
                let expected = try #require(item.expected.output)
                #expect(actual.count == expected.count && zip(actual, expected).allSatisfy { close($0, $1, tolerance.output) }, "\(item.name)")
                // The Float32 path rounds the same values once.
                #expect(VoiceLabTilt.apply(input, sections: filter.sections) == actual.map { Float($0) }, "\(item.name)")
            case "bands":
                let rate = try #require(item.sampleRate)
                let samples = Self.render(try #require(item.input?.signal))
                let bands = VoiceLabTilt.bands([samples[...]], sampleRate: rate)
                measured[item.name] = bands
                #expect(bands.frames == item.expected.frames, "\(item.name)")
                let expected = try #require(item.expected.levelsDb)
                #expect(zip(levels(bands), expected).allSatisfy { close($0, $1, tolerance.levelDb) }, "\(item.name)")
                #expect(close(VoiceLabTilt.slope(bands, commonWith: bands), item.expected.slopeDbPerOctave, tolerance.slope), "\(item.name)")
            case "match":
                let sourceName = try #require(item.source), takeName = try #require(item.take)
                let source = try #require(measured[sourceName]), take = try #require(measured[takeName])
                #expect(VoiceLabTilt.match(source: source, take: take) == item.expected.tiltDbPerOctave, "\(item.name)")
                #expect(close(VoiceLabTilt.slope(source, commonWith: take), item.expected.sourceSlope, tolerance.slope), "\(item.name)")
                #expect(close(VoiceLabTilt.slope(take, commonWith: source), item.expected.takeSlope, tolerance.slope), "\(item.name)")
            case "neighbourhood":
                let rate = try #require(item.sampleRate), window = try #require(item.input?.window)
                let samples = Self.render(try #require(item.input?.signal))
                let bands = try #require(VoiceLabTilt.neighbourhoodBands(VoiceLabSourceExcerpt(whole: samples), sampleRate: rate, window: window[0]..<window[1]))
                #expect(bands.frames == item.expected.frames, "\(item.name)")
                #expect(zip(levels(bands), try #require(item.expected.levelsDb)).allSatisfy { close($0, $1, tolerance.levelDb) }, "\(item.name)")
            default:
                Issue.record("unknown kind \(item.kind) in \(item.name)")
            }
        }
        #expect(kinds == ["frameSize", "sections", "filter", "bands", "match", "neighbourhood"])
    }

    @Test func theTiltIsGentleClampedAndPivotsAtOneKilohertz() {
        // ±2 dB/octave is the most either way; a larger request is clamped, not refused.
        #expect(VoiceLabTilt.sections(tiltDbPerOctave: 5, sampleRate: 24_000) == VoiceLabTilt.sections(tiltDbPerOctave: 2, sampleRate: 24_000))
        #expect(VoiceLabTilt.sections(tiltDbPerOctave: 0, sampleRate: 24_000).isEmpty && VoiceLabTilt.sections(tiltDbPerOctave: .nan, sampleRate: 24_000).isEmpty)
        for tilt in [-2.0, -0.5, 0.5, 2.0] {
            let sections = VoiceLabTilt.sections(tiltDbPerOctave: tilt, sampleRate: 24_000)
            let pivot: Double = 20 * log10(VoiceLabTilt.magnitude(sections, hertz: 1_000, sampleRate: 24_000))
            #expect(abs(pivot) < 1e-9)
            // About the tilt per octave across the speech band: within half of it from 250 Hz to 4 kHz (four octaves).
            let low: Double = 20 * log10(VoiceLabTilt.magnitude(sections, hertz: 250, sampleRate: 24_000))
            let high: Double = 20 * log10(VoiceLabTilt.magnitude(sections, hertz: 4_000, sampleRate: 24_000))
            let perOctave: Double = (high - low) / 4
            #expect(perOctave * tilt > 0 && abs(perOctave - tilt) <= abs(tilt) / 2, "tilt \(tilt): \(perOctave) dB/octave")
        }
        // Takes already like the speech beside them are left alone.
        let bands = VoiceLabTilt.bands([Self.render(.init(seed: 1, samples: 24_000, shape: "white", shift: 2, quiet: nil))[...]], sampleRate: 48_000)
        #expect(VoiceLabTilt.match(source: bands, take: bands) == nil)
    }
}
#endif
