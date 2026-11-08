import Foundation

/// How an export sets its level (ADR-R47, amended 2026-11-08). `social`, the default for every export, gains the
/// exported mix to −14 LUFS and holds its true peak at −1 dBTP with a transparent true-peak limiter; `off` writes the
/// mix as composed.
public enum ExportLoudness: String, Codable, Sendable, CaseIterable {
    case social
    case off
}

/// Why the social gain is what it is.
public enum SocialLoudnessLimit: String, Codable, Sendable, Equatable {
    /// The gain takes the clip to −14 LUFS.
    case none
    /// The gain wanted more than +12 dB or less than −20 dB and stopped there.
    case gainLimit
    /// The limiter would have reduced more than 9 dB, so the gain stopped where it reduces exactly 9 dB and the clip
    /// lands quieter than −14 LUFS rather than squashed.
    case reductionCap
    /// The gated loudness is undefined (digital silence, everything below −70 LUFS, or shorter than one 400 ms
    /// block), so the gain is 0 dB and nothing is limited.
    case silent
}

/// The gain the rule chose, why, and whether the limiter has work: the true peak after the gain is over −1 dBTP.
public struct SocialLoudnessDecision: Sendable, Equatable {
    public let gainDb: Double
    public let limit: SocialLoudnessLimit
    public let limiting: Bool
    /// The reduction cap set the gain; it is the only reason a clip is reported capped.
    public var capped: Bool { limit == .reductionCap }
    public init(gainDb: Double, limit: SocialLoudnessLimit, limiting: Bool = false) {
        self.gainDb = gainDb; self.limit = limit; self.limiting = limiting
    }
}

/// The next step of landing on target: simulate a gain offline, or export at the settled decision.
public enum SocialLoudnessLanding: Sendable, Equatable {
    case simulate(gainDb: Double)
    case settled(SocialLoudnessDecision)
}

/// What an export reports about its loudness (the export JSON's `loudness`, ADR-R47). `measuredLufs` is the composed
/// mix's, before the gain; `outputLufs` and `truePeakDbtp` are the exported PCM's, after the gain and the limiter.
/// `limiterMaxReductionDb` is the limiter's largest reduction and `limitedPercent` the share of frames under any
/// reduction, both 0 when the gain alone keeps the true peak under −1 dBTP. A silent mix has no loudness and no gain;
/// digital silence has no true peak either.
public struct SocialLoudnessReport: Codable, Sendable, Equatable {
    public var measuredLufs: Double?
    public var gainDb: Double
    public var outputLufs: Double?
    public var truePeakDbtp: Double?
    public var capped: Bool
    public var limiterMaxReductionDb: Double
    public var limitedPercent: Double

    public init(measuredLufs: Double?, gainDb: Double, outputLufs: Double?, truePeakDbtp: Double?, capped: Bool,
                limiterMaxReductionDb: Double = 0, limitedPercent: Double = 0) {
        self.measuredLufs = measuredLufs; self.gainDb = gainDb; self.outputLufs = outputLufs
        self.truePeakDbtp = truePeakDbtp; self.capped = capped
        self.limiterMaxReductionDb = limiterMaxReductionDb; self.limitedPercent = limitedPercent
    }

    private enum CodingKeys: String, CodingKey {
        case measuredLufs, gainDb, outputLufs, truePeakDbtp, capped, limiterMaxReductionDb, limitedPercent
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        measuredLufs = try values.decodeIfPresent(Double.self, forKey: .measuredLufs)
        gainDb = try values.decode(Double.self, forKey: .gainDb)
        outputLufs = try values.decodeIfPresent(Double.self, forKey: .outputLufs)
        truePeakDbtp = try values.decodeIfPresent(Double.self, forKey: .truePeakDbtp)
        capped = try values.decode(Bool.self, forKey: .capped)
        limiterMaxReductionDb = try values.decodeIfPresent(Double.self, forKey: .limiterMaxReductionDb) ?? 0
        limitedPercent = try values.decodeIfPresent(Double.self, forKey: .limitedPercent) ?? 0
    }

    /// Every key is written, a missing value as null.
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(measuredLufs, forKey: .measuredLufs)
        try values.encode(gainDb, forKey: .gainDb)
        try values.encode(outputLufs, forKey: .outputLufs)
        try values.encode(truePeakDbtp, forKey: .truePeakDbtp)
        try values.encode(capped, forKey: .capped)
        try values.encode(limiterMaxReductionDb, forKey: .limiterMaxReductionDb)
        try values.encode(limitedPercent, forKey: .limitedPercent)
    }

    /// The app log's line: numbers only, no paths or names.
    public var logLine: String {
        func number(_ value: Double?) -> String { value.map { String(format: "%.2f", $0) } ?? "none" }
        let head = "loudness measured=\(number(measuredLufs)) gain=\(number(gainDb)) output=\(number(outputLufs))"
        return head + " truePeak=\(number(truePeakDbtp)) capped=\(capped) maxReduction=\(number(limiterMaxReductionDb)) limited=\(number(limitedPercent))"
    }
}

/// Social loudness (ADR-R47, amended 2026-11-08): the exported mix lands at −14 LUFS integrated (ITU-R BS.1770-4 with
/// EBU R128 gating) by one gain, within −20…+12 dB, and a transparent true-peak limiter (`SocialLimiter`) holds the true
/// peak at −1.0 dBTP. The limiter's largest reduction is exactly the true peak after the gain minus the ceiling, so the
/// gain is lowered until that is at most 9 dB. Offline pre-passes simulate the gain and the limiter, and a limited,
/// uncapped gain is corrected by what the limiter took (`landing`). Shared vectors: shared/fixtures/loudness/
/// social-loudness-cases.json and social-limiter-cases.json.
public enum SocialLoudness {
    public static let targetLufs = -14.0
    public static let ceilingDbtp = -1.0
    public static let maximumBoostDb = 12.0
    public static let maximumCutDb = -20.0
    public static let maximumReductionDb = 9.0
    /// A first simulation within this of the target lands with one correction; beyond it, a second one is run.
    public static let landingToleranceLu = 0.5
    static let absoluteGateLufs = -70.0
    static let relativeGateLu = -10.0
    static let stepSeconds = 0.1
    static let blockSteps = 4

    /// The plan from the measured mix alone. A nil loudness (silent) gets 0 dB and no limiting.
    public static func decide(measuredLufs: Double?, truePeakDbtp: Double?) -> SocialLoudnessDecision {
        guard let measured = measuredLufs, measured.isFinite else { return SocialLoudnessDecision(gainDb: 0, limit: .silent) }
        let wanted = targetLufs - measured
        var gain = min(max(wanted, maximumCutDb), maximumBoostDb)
        var limit: SocialLoudnessLimit = gain == wanted ? .none : .gainLimit
        guard let peak = truePeakDbtp, peak.isFinite else { return SocialLoudnessDecision(gainDb: gain, limit: limit) }
        let cap = ceilingDbtp + maximumReductionDb - peak
        if gain > cap { gain = cap; limit = .reductionCap }
        return SocialLoudnessDecision(gainDb: gain, limit: limit, limiting: peak + gain > ceilingDbtp)
    }

    /// Landing on target from offline pre-passes that simulate the gain and the limiter. `trials` are the
    /// (gain, simulated output LUFS) pairs so far; the answer is the next gain to simulate or the settled decision.
    /// Only an uncapped, limited plan moves: one simulation and one correction by target minus what it measured; when
    /// the limiter took more than 0.5 LU, the corrected gain is simulated too and a secant step through the two lands
    /// it. Every gain stays within −20…+12 dB and the 9 dB reduction cap.
    public static func landing(_ plan: SocialLoudnessDecision, truePeakDbtp: Double?,
                               trials: [(gainDb: Double, lufs: Double?)]) -> SocialLoudnessLanding {
        func settled(_ gain: Double, _ limit: SocialLoudnessLimit) -> SocialLoudnessLanding {
            .settled(SocialLoudnessDecision(gainDb: gain, limit: limit, limiting: (truePeakDbtp ?? -.infinity) + gain > ceilingDbtp))
        }
        guard plan.limiting, plan.limit == .none, let peak = truePeakDbtp else { return .settled(plan) }
        guard let first = trials.first else { return .simulate(gainDb: plan.gainDb) }
        guard let firstLufs = first.lufs else { return .settled(plan) }
        let corrected = bounded(first.gainDb + targetLufs - firstLufs, truePeakDbtp: peak)
        guard trials.count > 1 else {
            if abs(targetLufs - firstLufs) <= landingToleranceLu || corrected.gainDb == first.gainDb {
                return settled(corrected.gainDb, corrected.limit)
            }
            return .simulate(gainDb: corrected.gainDb)
        }
        let second = trials[1]
        guard let secondLufs = second.lufs else { return settled(second.gainDb, corrected.limit) }
        let slope = (secondLufs - firstLufs) / (second.gainDb - first.gainDb)
        let step = slope > 0.05 ? (targetLufs - secondLufs) / slope : targetLufs - secondLufs
        let landed = bounded(second.gainDb + step, truePeakDbtp: peak)
        return settled(landed.gainDb, landed.limit)
    }

    /// A gain kept within −20 dB, +12 dB and the 9 dB reduction cap, and what stopped it.
    static func bounded(_ gainDb: Double, truePeakDbtp: Double) -> (gainDb: Double, limit: SocialLoudnessLimit) {
        let cap = ceilingDbtp + maximumReductionDb - truePeakDbtp
        let bound = min(maximumBoostDb, cap)
        if gainDb > bound { return (bound, cap <= maximumBoostDb ? .reductionCap : .gainLimit) }
        return (max(gainDb, maximumCutDb), .none)
    }

    /// The report of an export at `decision`. Gain alone (not limiting): the input measurement scaled by the gain.
    /// Limited: `output`, the meter of the exported PCM, and the limiter's own counts.
    public static func report(measurement: SocialLoudnessMeasurement, decision: SocialLoudnessDecision,
                              limiter: SocialLimiter, output: SocialLoudnessMeasurement?) -> SocialLoudnessReport {
        let measured = measurement.integratedLufs()
        guard decision.limiting, let output else {
            return SocialLoudnessReport(measuredLufs: measured, gainDb: decision.gainDb,
                outputLufs: measurement.integratedLufs(gainDb: decision.gainDb),
                truePeakDbtp: measurement.truePeakDbtp.map { $0 + decision.gainDb }, capped: decision.capped)
        }
        return SocialLoudnessReport(measuredLufs: measured, gainDb: decision.gainDb, outputLufs: output.integratedLufs(),
            truePeakDbtp: output.truePeakDbtp, capped: decision.capped,
            limiterMaxReductionDb: limiter.maximumReductionDb, limitedPercent: limiter.limitedPercent)
    }

    /// The linear sample factor of a gain in dB.
    public static func linearGain(_ gainDb: Double) -> Float { Float(pow(10, gainDb / 20)) }
}

/// A measured mix: the K-weighted energy of every whole 100 ms step, summed over the channels, and the true peak.
public struct SocialLoudnessMeasurement: Sendable, Equatable {
    /// Σ over channels and the step's frames of the K-weighted sample squared; a trailing partial step is dropped.
    public let stepEnergies: [Double]
    /// Frames in one step: round(0.1 s × rate).
    public let stepFrames: Int
    /// The largest of the sample peak and the Annex 2 interpolated peak over every channel, linear.
    public let truePeak: Double

    /// The true peak in dBTP, or nil for digital silence.
    public var truePeakDbtp: Double? { truePeak > 0 ? 20 * log10(truePeak) : nil }

    /// BS.1770-4 integrated loudness of the mix scaled by `gainDb`: 400 ms blocks every 100 ms, the −70 LUFS absolute
    /// gate, then the gate 10 LU below the absolute-gated loudness. Nil when no block passes the absolute gate.
    public func integratedLufs(gainDb: Double = 0) -> Double? {
        let steps = SocialLoudness.blockSteps
        guard stepEnergies.count >= steps, stepFrames > 0 else { return nil }
        let scale = pow(10, gainDb / 10) / Double(steps * stepFrames)
        var blocks: [Double] = []
        blocks.reserveCapacity(stepEnergies.count - steps + 1)
        for index in 0...(stepEnergies.count - steps) {
            var sum = 0.0
            for step in index..<(index + steps) { sum += stepEnergies[step] }
            blocks.append(sum * scale)
        }
        func lufs(_ meanSquare: Double) -> Double { meanSquare > 0 ? -0.691 + 10 * log10(meanSquare) : -.infinity }
        let absolute = blocks.filter { lufs($0) > SocialLoudness.absoluteGateLufs }
        guard !absolute.isEmpty else { return nil }
        let relative = lufs(absolute.reduce(0, +) / Double(absolute.count)) + SocialLoudness.relativeGateLu
        let gated = absolute.filter { lufs($0) > relative }
        return lufs(gated.reduce(0, +) / Double(gated.count))
    }
}

/// Streams interleaved Float32 frames into a `SocialLoudnessMeasurement` in O(steps) memory. Each channel runs the
/// BS.1770 K-weighting (VoiceLabLoudness's shelf and RLB high-pass) from zero state and the Annex 2 4× true-peak filter
/// with silence before the first sample and after the last, so the measurement equals VoiceLabLoudness's whole-buffer
/// definitions. Below 96 kHz only; exports measure at 48 kHz.
public struct SocialLoudnessMeter: Sendable {
    public let sampleRate: Int
    public let channels: Int
    private let shelf: VoiceLabBiquad
    private let highPass: VoiceLabBiquad
    private let stepFrames: Int
    /// Per channel: x1, x2, m1, m2, y1, y2.
    private var filter: [Double]
    /// Per channel: the last 11 inputs, oldest first.
    private var history: [Double]
    private var steps: [Double] = []
    private var stepSum = 0.0
    private var stepFilled = 0
    private var peak = 0.0
    private var squares: [Double] = []
    private var lane: [Double] = []
    /// The largest Σ|tap| of a phase: no interpolated value exceeds it times the largest input it reads.
    private static let phaseGain: Double = (0..<4).map { phase in
        (0..<12).reduce(0.0) { $0 + abs(VoiceLabLoudness.truePeakTaps[phase * 12 + $1]) }
    }.max()!

    public init(sampleRate: Int, channels: Int) throws {
        guard sampleRate > 0, sampleRate < 96_000, (1...8).contains(channels) else { throw VoiceLabAudioMathError.invalidInput }
        self.sampleRate = sampleRate; self.channels = channels
        (shelf, highPass) = VoiceLabLoudness.kWeighting(sampleRate: sampleRate)
        stepFrames = Int(EditingPrimitives.jsRound(SocialLoudness.stepSeconds * Double(sampleRate)))
        filter = [Double](repeating: 0, count: 6 * channels)
        history = [Double](repeating: 0, count: 11 * channels)
    }

    /// Adds `samples.count / channels` whole frames. A non-finite sample is invalid input.
    public mutating func append(_ samples: UnsafeBufferPointer<Float>) throws {
        let frames = samples.count / channels
        guard frames > 0, let base = samples.baseAddress else { return }
        if squares.count < frames { squares = [Double](repeating: 0, count: frames) }
        if lane.count < frames + 11 { lane = [Double](repeating: 0, count: frames + 11) }
        var energy = squares, buffer = lane
        squares = []; lane = []
        defer { squares = energy; lane = buffer }
        for index in 0..<frames { energy[index] = 0 }
        for channel in 0..<channels {
            try weigh(base + channel, stride: channels, frames: frames, channel: channel, into: &energy)
            interpolate(base + channel, stride: channels, frames: frames, channel: channel, lane: &buffer)
        }
        var index = 0, sum = stepSum, filled = stepFilled
        while index < frames {
            let take = min(stepFrames - filled, frames - index)
            for frame in index..<(index + take) { sum += energy[frame] }
            filled += take; index += take
            if filled == stepFrames { steps.append(sum); sum = 0; filled = 0 }
        }
        stepSum = sum; stepFilled = filled
    }

    public mutating func append(_ samples: [Float]) throws {
        try samples.withUnsafeBufferPointer { try append($0) }
    }

    /// The measurement, after the filter's ringing past the last sample (eleven silent inputs per channel).
    public mutating func finish() -> SocialLoudnessMeasurement {
        let zeros = [Float](repeating: 0, count: 11)
        var buffer = [Double](repeating: 0, count: 22)
        zeros.withUnsafeBufferPointer { tail in
            for channel in 0..<channels {
                interpolate(tail.baseAddress!, stride: 1, frames: 11, channel: channel, lane: &buffer)
            }
        }
        return SocialLoudnessMeasurement(stepEnergies: steps, stepFrames: stepFrames, truePeak: peak)
    }

    /// One channel through the shelf and the high-pass; adds y² to `energy`.
    private mutating func weigh(_ input: UnsafePointer<Float>, stride: Int, frames: Int, channel: Int,
                                into energy: inout [Double]) throws {
        let s = shelf, h = highPass, offset = 6 * channel
        var x1 = filter[offset], x2 = filter[offset + 1], m1 = filter[offset + 2]
        var m2 = filter[offset + 3], y1 = filter[offset + 4], y2 = filter[offset + 5]
        var finite = true
        energy.withUnsafeMutableBufferPointer { target in
            var source = input
            for frame in 0..<frames {
                let value = source.pointee
                if !value.isFinite { finite = false; break }
                let x = Double(value)
                let m = s.b0 * x + s.b1 * x1 + s.b2 * x2 - s.a1 * m1 - s.a2 * m2
                let y = h.b0 * m + h.b1 * m1 + h.b2 * m2 - h.a1 * y1 - h.a2 * y2
                x2 = x1; x1 = x; m2 = m1; m1 = m; y2 = y1; y1 = y
                target[frame] += y * y
                source += stride
            }
        }
        guard finite else { throw VoiceLabAudioMathError.invalidInput }
        filter[offset] = x1; filter[offset + 1] = x2; filter[offset + 2] = m1
        filter[offset + 3] = m2; filter[offset + 4] = y1; filter[offset + 5] = y2
    }

    /// One channel's sample peak and Annex 2 interpolated peak. The filter runs only where its bound (the largest
    /// input it reads times `phaseGain`) could beat the peak so far, which leaves the maximum unchanged.
    private mutating func interpolate(_ input: UnsafePointer<Float>, stride: Int, frames: Int, channel: Int,
                                      lane: inout [Double]) {
        let offset = 11 * channel
        var largest = 0.0, current = peak
        for index in 0..<11 {
            lane[index] = history[offset + index]
            largest = max(largest, abs(lane[index]))
        }
        var source = input
        for index in 0..<frames {
            let value = Double(source.pointee)
            lane[11 + index] = value
            let magnitude = abs(value)
            if magnitude > largest { largest = magnitude }
            if magnitude > current { current = magnitude }
            source += stride
        }
        if largest * Self.phaseGain > current {
            current = Self.filteredPeak(lane, frames: frames, above: current)
        }
        for index in 0..<11 { history[offset + index] = lane[frames + index] }
        peak = current
    }

    /// The largest |output| of the four Annex 2 phases over `lane[11...]`, each reading the 11 inputs before it.
    private static func filteredPeak(_ lane: [Double], frames: Int, above floor: Double) -> Double {
        var current = floor
        lane.withUnsafeBufferPointer { buffer in
            VoiceLabLoudness.truePeakTaps.withUnsafeBufferPointer { taps in
                for phase in 0..<4 {
                    let c = taps.baseAddress! + 12 * phase
                    let c0 = c[0], c1 = c[1], c2 = c[2], c3 = c[3], c4 = c[4], c5 = c[5]
                    let c6 = c[6], c7 = c[7], c8 = c[8], c9 = c[9], c10 = c[10], c11 = c[11]
                    var x = buffer.baseAddress! + 11
                    let end = x + frames
                    while x < end {
                        let sum = c0 * x[0] + c1 * x[-1] + c2 * x[-2] + c3 * x[-3] + c4 * x[-4] + c5 * x[-5]
                            + c6 * x[-6] + c7 * x[-7] + c8 * x[-8] + c9 * x[-9] + c10 * x[-10] + c11 * x[-11]
                        if sum > current { current = sum } else if -sum > current { current = -sum }
                        x += 1
                    }
                }
            }
        }
        return current
    }
}
