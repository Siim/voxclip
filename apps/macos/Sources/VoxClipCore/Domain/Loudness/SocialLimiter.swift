import Foundation

/// The social-loudness gain and transparent true-peak limiter (ADR-R47, amended 2026-11-08; doc/publishing.md
/// "Loudness"), streamed over interleaved Float32 frames. Windows Core SocialLimiter is the same definition; shared
/// vectors: shared/fixtures/loudness/social-limiter-cases.json.
///
/// Each frame is gained, z = Double(x) × 10^(gain/20). Not limiting, the output is Float(z), at once. Limiting:
/// 1. Detection point n (n = 0 … frames + 10; silence outside the mix) reads frames n−11 … n: p(n) is the largest over
///    the channels of |z(n)| and the four BS.1770-4 Annex 2 phase outputs over those 12 frames. Its overshoot is
///    R(n) = 20·log10 p(n) + 1 dB when p(n) > 10^(−1/20), else 0.
/// 2. Hold: frame m needs H(m) = max R(m … m+11), every point that reads it.
/// 3. Attack over the lookahead L = round(0.005 s × rate) frames: A(m) = max over j = 0…L of H(m+j)·(½ + ½·cos(πj/L)),
///    so the reduction rises as a raised cosine and reaches H at the frame itself.
/// 4. Release, stereo-linked: E(m) = max(A(m), d), d = E(m−1)·e^(−1/(0.08 s × rate)), with d = 0 once it is below
///    0.01 dB. E(−1) = 0.
/// 5. Output: Float(z × 10^(−E/20)) for every channel; Float(z) where E = 0, so samples that are far from any overshoot
///    pass with the gain alone. No makeup gain, no knee.
/// The largest E is the largest R, exactly the true peak after the gain minus the ceiling. Output lags input by
/// L + 11 frames; `finish` flushes them.
public struct SocialLimiter: Sendable {
    public static let lookaheadSeconds = 0.005
    public static let releaseSeconds = 0.08
    public static let releaseFloorDb = 0.01
    /// Inputs one detection point reads.
    static let detectionTaps = 12

    public let gainDb: Double
    public let limiting: Bool
    public let channels: Int
    /// Frames the output lags the input: 0 for gain alone.
    public let latency: Int
    /// The largest reduction so far, dB.
    public private(set) var maximumReductionDb = 0.0
    /// Output frames under any reduction.
    public private(set) var limitedFrames = 0
    /// Output frames so far.
    public private(set) var frames = 0
    /// The share of output frames under any reduction, percent.
    public var limitedPercent: Double { frames > 0 ? 100 * Double(limitedFrames) / Double(frames) : 0 }

    private let gain: Double
    private let lookahead: Int
    private let threshold: Double
    private let releaseFactor: Double
    private let shape: [Double]
    /// Gained frames, slot i % (latency + 1).
    private var gained: [Double]
    /// Per frame, the largest |z| over the channels, slot i % 12.
    private var magnitudes: [Double]
    /// Overshoot R, slot n % 12.
    private var overshoots: [Double]
    /// Pending attack A, slot m % (lookahead + 1).
    private var attack: [Double]
    private var inputs = 0
    private var lastOvershoot = Int.min / 2
    private var reduction = 0.0
    /// The largest Σ|tap| of a phase: no phase output exceeds it times the largest input it reads.
    private static let phaseGain: Double = (0..<4).map { phase in
        (0..<12).reduce(0.0) { $0 + abs(VoiceLabLoudness.truePeakTaps[phase * 12 + $1]) }
    }.max()!

    public init(gainDb: Double, limiting: Bool, sampleRate: Int, channels: Int) throws {
        guard gainDb.isFinite, sampleRate > 0, sampleRate < 96_000, (1...8).contains(channels) else {
            throw VoiceLabAudioMathError.invalidInput
        }
        self.gainDb = gainDb; self.limiting = limiting; self.channels = channels
        gain = pow(10, gainDb / 20)
        lookahead = Int(EditingPrimitives.jsRound(Self.lookaheadSeconds * Double(sampleRate)))
        latency = limiting ? lookahead + Self.detectionTaps - 1 : 0
        threshold = pow(10, SocialLoudness.ceilingDbtp / 20)
        releaseFactor = exp(-1 / (Self.releaseSeconds * Double(sampleRate)))
        let span = Double(lookahead)
        shape = (0...lookahead).map { 0.5 + 0.5 * cos(Double.pi * Double($0) / span) }
        gained = [Double](repeating: 0, count: limiting ? (latency + 1) * channels : 0)
        magnitudes = [Double](repeating: 0, count: Self.detectionTaps)
        overshoots = [Double](repeating: 0, count: Self.detectionTaps)
        attack = [Double](repeating: 0, count: lookahead + 1)
    }

    /// Takes `input.count / channels` whole frames and writes the frames now due to `output`, which has room for as
    /// many; returns how many it wrote.
    @discardableResult
    public mutating func process(_ input: UnsafeBufferPointer<Float>, into output: UnsafeMutableBufferPointer<Float>) -> Int {
        let count = input.count / channels
        guard count > 0, let source = input.baseAddress, let target = output.baseAddress else { return 0 }
        precondition(output.count >= count * channels)
        guard limiting else {
            for index in 0..<(count * channels) { target[index] = Float(Double(source[index]) * gain) }
            frames += count
            return count
        }
        var written = 0
        for frame in 0..<count {
            if push(source + frame * channels, into: target + written * channels) { written += 1 }
        }
        return written
    }

    /// The last `latency` frames (fewer when fewer came in), written to `output`, which has room for them.
    @discardableResult
    public mutating func finish(into output: UnsafeMutableBufferPointer<Float>) -> Int {
        guard limiting, let target = output.baseAddress else { return 0 }
        let silence = [Float](repeating: 0, count: channels)
        var written = 0
        silence.withUnsafeBufferPointer { zeros in
            for _ in 0..<latency {
                if push(zeros.baseAddress!, into: target + written * channels) { written += 1 }
            }
        }
        return written
    }

    public mutating func process(_ input: [Float]) -> [Float] {
        var output = [Float](repeating: 0, count: input.count - input.count % channels)
        let written = input.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { process(source, into: $0) }
        }
        return Array(output.prefix(written * channels))
    }

    public mutating func finish() -> [Float] {
        var output = [Float](repeating: 0, count: latency * channels)
        let written = output.withUnsafeMutableBufferPointer { finish(into: $0) }
        return Array(output.prefix(written * channels))
    }

    /// One input frame in; true when it completed an output frame at `target`.
    private mutating func push(_ frame: UnsafePointer<Float>, into target: UnsafeMutablePointer<Float>) -> Bool {
        let index = inputs
        inputs += 1
        let taps = Self.detectionTaps
        let slot = index % (latency + 1)
        var largest = 0.0
        for channel in 0..<channels {
            let value = Double(frame[channel]) * gain
            gained[slot * channels + channel] = value
            largest = max(largest, abs(value))
        }
        magnitudes[index % taps] = largest
        // Detection point `index` reads frames index-11 ... index.
        var bound = 0.0
        for value in magnitudes where value > bound { bound = value }
        var peak = largest
        if bound * Self.phaseGain > threshold { peak = max(peak, interpolatedPeak(at: index)) }
        let over = peak > threshold ? 20 * log10(peak) - SocialLoudness.ceilingDbtp : 0
        overshoots[index % taps] = over
        if over > 0 { lastOvershoot = index }
        // Frame k = index - 11 now has every point that reads it.
        let held = index - taps + 1
        guard held >= 0 else { return false }
        var hold = 0.0
        if index - lastOvershoot < taps { for value in overshoots where value > hold { hold = value } }
        let span = lookahead + 1
        attack[held % span] = hold
        if hold > 0 {
            var step = 1
            while step <= lookahead, held - step >= 0 {
                let candidate = shape[step] * hold
                let position = (held - step) % span
                if candidate > attack[position] { attack[position] = candidate }
                step += 1
            }
        }
        let out = held - lookahead
        guard out >= 0 else { return false }
        var released = reduction * releaseFactor
        if released < Self.releaseFloorDb { released = 0 }
        let current = attack[out % span]
        reduction = current > released ? current : released
        let factor = reduction > 0 ? pow(10, -reduction / 20) : 1
        let source = (out % (latency + 1)) * channels
        for channel in 0..<channels { target[channel] = Float(gained[source + channel] * factor) }
        frames += 1
        if reduction > 0 { limitedFrames += 1; if reduction > maximumReductionDb { maximumReductionDb = reduction } }
        return true
    }

    /// The largest |output| over the channels of the four Annex 2 phases at detection point `index`, which reads the
    /// gained frames index-11 ... index (silence before the first).
    private func interpolatedPeak(at index: Int) -> Double {
        var peak = 0.0
        let ring = latency + 1
        let reach = min(Self.detectionTaps, index + 1)
        VoiceLabLoudness.truePeakTaps.withUnsafeBufferPointer { taps in
            gained.withUnsafeBufferPointer { frames in
                for channel in 0..<channels {
                    for phase in 0..<4 {
                        // In tap order from zero, as the generator sums.
                        var sum = 0.0
                        for tap in 0..<reach {
                            sum += taps[12 * phase + tap] * frames[((index - tap) % ring) * channels + channel]
                        }
                        if abs(sum) > peak { peak = abs(sum) }
                    }
                }
            }
        }
        return peak
    }
}
