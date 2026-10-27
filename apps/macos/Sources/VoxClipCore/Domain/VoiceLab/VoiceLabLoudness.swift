import Foundation

/// Typed failures of the Voice Lab audio measurements; voice-lab.md §8.7 item 2 and §8.11 item 3.
public enum VoiceLabAudioMathError: Error, Equatable, Sendable {
    /// The source neighbourhood or the candidate has no 10 ms frame above `VOICED_FRAME`, so no level gain exists.
    case noVoicedAudio
    /// A seam window cut short by the buffer edge is below 0.1 s.
    case insufficientContext
    /// A sample rate, position, envelope or sample value the measurement cannot use.
    case invalidInput
}

/// Biquad coefficients normalised to a0 = 1: y = b0·x + b1·x₋₁ + b2·x₋₂ − a1·y₋₁ − a2·y₋₂.
struct VoiceLabBiquad: Equatable, Sendable {
    let b0, b1, b2, a1, a2: Double
}

/// Level, peak and loudness measurements on mono Float32 samples; callers downmix. voice-lab.md §8.6, §8.7 item 2
/// and §8.11 items 2 and 3. No I/O, media framework or global state, and allocations stay O(input). The per-sample
/// loops step raw pointers, so a minute of audio stays fast in unoptimised test builds too.
public enum VoiceLabLoudness {
    static let voicedFrameDbfs = -45.0
    static let loudnessNeighbourhoodSeconds = 3.0
    static let gainClampDb = 12.0
    static let truePeakLimitDbtp = -1.0
    static let momentarySeconds = 0.4
    static let minimumSeamWindowSeconds = 0.1
    static let silenceGateLufs = -70.0
    static let flatnessStepSeconds = 0.1
    static let flatnessStdevScale = 6.0

    /// The RMS over every voiced 10 ms frame, in dBFS, or nil when no frame is voiced. Frames are
    /// `round_half_up(rate × 0.01)` samples from sample 0, a trailing partial frame is ignored, and a frame is voiced
    /// when its RMS exceeds `VOICED_FRAME` (−45 dBFS).
    public static func voicedRmsDb(_ samples: [Float], sampleRate: Int) throws -> Double? {
        try validate(samples, sampleRate: sampleRate)
        return voicedLevel(samples, sides: [0..<samples.count], sampleRate: sampleRate)
    }

    /// The source level beside the window being replaced, in dBFS (§8.7 item 2). It takes the voiced frames within
    /// `LOUDNESS_NEIGHBOURHOOD` (3 s) before and after `window`, each side clamped to the take, and excludes the window
    /// itself. Each side is framed on its own grid from its first sample, a trailing partial frame is ignored, and the
    /// voiced frames of both sides pool into one mean square. Throws `noVoicedAudio` when neither side has one.
    // Spec: voice-lab.md §8.7 item 2 and §8.3 LOUDNESS_NEIGHBOURHOOD; the window is excluded because it is replaced.
    public static func neighbourhoodVoicedRmsDb(_ source: [Float], sampleRate: Int, window: Range<Int>) throws -> Double {
        try validate(source, sampleRate: sampleRate)
        guard window.lowerBound >= 0, window.upperBound <= source.count else { throw VoiceLabAudioMathError.invalidInput }
        // Clamped in Float64 first, so an absurd rate cannot overflow the conversion.
        let reach = Int(min(EditingPrimitives.jsRound(loudnessNeighbourhoodSeconds * Double(sampleRate)), Double(source.count)))
        let before = max(0, window.lowerBound - reach)..<window.lowerBound
        let after = window.upperBound..<min(source.count, window.upperBound + reach)
        guard let level = voicedLevel(source, sides: [before, after], sampleRate: sampleRate) else {
            throw VoiceLabAudioMathError.noVoicedAudio
        }
        return level
    }

    /// `audio.gainDb` for a candidate (§8.7 item 2): the voiced-RMS difference clamped to `GAIN_CLAMP`, then lowered
    /// until the candidate's true peak sits at −1 dBTP. A recipe stores one static gain, so this cap is the only form
    /// the limit can take; nothing limits dynamically and the voice itself is unaltered.
    public static func levelGainDb(sourceVoicedRmsDb: Double?, candidateVoicedRmsDb: Double?,
                                   candidateTruePeakDbtp: Double) throws -> Double {
        guard let source = sourceVoicedRmsDb, let candidate = candidateVoicedRmsDb else { throw VoiceLabAudioMathError.noVoicedAudio }
        guard source.isFinite, candidate.isFinite, candidateTruePeakDbtp.isFinite else { throw VoiceLabAudioMathError.invalidInput }
        let gain = min(max(source - candidate, -gainClampDb), gainClampDb)
        return min(gain, truePeakLimitDbtp - candidateTruePeakDbtp)
    }

    /// Measures the source beside `window` (`neighbourhoodVoicedRmsDb`) and the trimmed candidate, each at its own
    /// rate, then applies `levelGainDb(sourceVoicedRmsDb:candidateVoicedRmsDb:candidateTruePeakDbtp:)`. Both buffers
    /// are validated before either side can report `noVoicedAudio`.
    public static func levelGainDb(source: [Float], sourceSampleRate: Int, window: Range<Int>, candidate: [Float],
                                   candidateSampleRate: Int) throws -> Double {
        let candidateDb = try voicedRmsDb(candidate, sampleRate: candidateSampleRate)
        let sourceDb = try neighbourhoodVoicedRmsDb(source, sampleRate: sourceSampleRate, window: window)
        guard candidateDb != nil else { throw VoiceLabAudioMathError.noVoicedAudio }
        return try levelGainDb(sourceVoicedRmsDb: sourceDb, candidateVoicedRmsDb: candidateDb,
                               candidateTruePeakDbtp: truePeakDbtp(candidate, sampleRate: candidateSampleRate))
    }

    /// 20·log10(max |x|), or −∞ for silence. QA's `peakDbfs` is this value for the final mixed window after gain
    /// (§8.11 item 2).
    public static func samplePeakDbfs(_ samples: [Float]) throws -> Double {
        try requireFinite(samples)
        var peak: Float = 0
        samples.withUnsafeBufferPointer { buffer in
            guard var sample = buffer.baseAddress else { return }
            let end = sample + buffer.count
            while sample < end {
                if sample.pointee > peak { peak = sample.pointee } else if -sample.pointee > peak { peak = -sample.pointee }
                sample += 1
            }
        }
        return 20 * log10(Double(peak))
    }

    /// The ITU-R BS.1770-4 Annex 2 true peak in dBTP, or −∞ for silence: 4× oversampling below 96 kHz, 2× below
    /// 192 kHz, and the sample peak from 192 kHz. Annex 2 publishes only the 4× filter, so 2× uses its even phases, 0
    /// and 2. The buffer is silent outside its bounds, so every output of the full interpolation counts, including the
    /// ringing of an abrupt start or end. No phase lands on an input sample, and phases 1 and 2 pass DC at 0.973, so the
    /// filter alone can read below the samples; the true peak is the larger of the two (lead decision). Both choices are
    /// conservative: a higher true peak can only lower the gain cap.
    // Spec: voice-lab.md §8.7 item 2 (the −1 dBTP limit), measured as in ITU-R BS.1770-4 Annex 2.
    public static func truePeakDbtp(_ samples: [Float], sampleRate: Int) throws -> Double {
        try validate(samples, sampleRate: sampleRate)
        let factor = oversampling(sampleRate: sampleRate)
        guard factor > 1, !samples.isEmpty else { return try samplePeakDbfs(samples) }
        // Eleven zeros on each side: output n reads padded[n + 11] down to padded[n], tap 0 first.
        // The sample peak, taken while padding, is where the search for a larger interpolated value starts.
        var padded = [Double](repeating: 0, count: samples.count + 22), peak = 0.0
        padded.withUnsafeMutableBufferPointer { output in
            samples.withUnsafeBufferPointer { input in
                var source = input.baseAddress!, target = output.baseAddress! + 11
                let end = source + input.count
                while source < end {
                    let value = Double(source.pointee)
                    target.pointee = value
                    if value > peak { peak = value } else if -value > peak { peak = -value }
                    source += 1; target += 1
                }
            }
        }
        padded.withUnsafeBufferPointer { input in
            truePeakTaps.withUnsafeBufferPointer { taps in
                var phase = 0
                while phase < 4 {
                    let c = taps.baseAddress! + 12 * phase
                    let c0 = c[0], c1 = c[1], c2 = c[2], c3 = c[3], c4 = c[4], c5 = c[5]
                    let c6 = c[6], c7 = c[7], c8 = c[8], c9 = c[9], c10 = c[10], c11 = c[11]
                    var x = input.baseAddress! + 11
                    let end = x + samples.count + 11
                    while x < end {
                        let sum = c0 * x[0] + c1 * x[-1] + c2 * x[-2] + c3 * x[-3] + c4 * x[-4] + c5 * x[-5]
                            + c6 * x[-6] + c7 * x[-7] + c8 * x[-8] + c9 * x[-9] + c10 * x[-10] + c11 * x[-11]
                        if sum > peak { peak = sum } else if -sum > peak { peak = -sum }
                        x += 1
                    }
                    phase += 4 / factor
                }
            }
        }
        return 20 * log10(peak)
    }

    /// BS.1770-4 momentary loudness in LUFS of the 400 ms window that starts at `windowStart`, or −∞ for a silent
    /// window: −0.691 + 10·log10 of the K-weighted mean square, with channel weight 1. The K-weighting runs from sample 0
    /// with zero state, so the samples before the window are its context.
    public static func momentaryLufs(_ samples: [Float], sampleRate: Int, windowStart: Int) throws -> Double {
        try validate(samples, sampleRate: sampleRate)
        let window = sampleCount(momentarySeconds, sampleRate)
        guard windowStart >= 0, windowStart <= samples.count - window else { throw VoiceLabAudioMathError.invalidInput }
        return kWeighted(samples, count: windowStart + window, sampleRate: sampleRate).withUnsafeBufferPointer {
            loudness($0.baseAddress!, from: windowStart, to: windowStart + window)
        }
    }

    /// The momentary jump across one seam (§8.11 item 3): |M_after − M_before| over [seam − 0.4 s, seam) and
    /// [seam, seam + 0.4 s) of the mixed audio on its own sample grid. A window cut short by the buffer edge is
    /// shortened, and one below 0.1 s throws `insufficientContext`. Each window's loudness is floored at −70 LUFS, so
    /// the jump is always finite: two windows at the floor give 0, and a cut from room tone to digital silence gives the
    /// room tone's distance from −70 LUFS, which QA can catch.
    public static func seamJumpLu(_ samples: [Float], sampleRate: Int, seamSample: Int) throws -> Double {
        try seamJumps(samples, sampleRate: sampleRate, seamSamples: [seamSample])[0]
    }

    /// A recipe's `qa.lufsJumpLu`: the largest jump over its seams that are not `none`, or 0 without such a seam.
    public static func lufsJumpLu(_ samples: [Float], sampleRate: Int, seamSamples: [Int]) throws -> Double {
        try seamJumps(samples, sampleRate: sampleRate, seamSamples: seamSamples).max() ?? 0
    }

    // Spec: voice-lab.md §8.11 item 3; each window is floored at −70 LUFS, the BS.1770 absolute gate (lead decision).
    static func seamJumps(_ samples: [Float], sampleRate: Int, seamSamples: [Int]) throws -> [Double] {
        try validate(samples, sampleRate: sampleRate)
        let window = sampleCount(momentarySeconds, sampleRate), minimum = sampleCount(minimumSeamWindowSeconds, sampleRate)
        for seam in seamSamples {
            guard seam >= 0, seam <= samples.count else { throw VoiceLabAudioMathError.invalidInput }
            guard seam - max(0, seam - window) >= minimum, min(samples.count, seam + window) - seam >= minimum else {
                throw VoiceLabAudioMathError.insufficientContext
            }
        }
        guard !seamSamples.isEmpty else { return [] }
        return kWeighted(samples, count: samples.count, sampleRate: sampleRate).withUnsafeBufferPointer { buffer in
            seamSamples.map { seam in
                let before = loudness(buffer.baseAddress!, from: max(0, seam - window), to: seam)
                let after = loudness(buffer.baseAddress!, from: seam, to: min(samples.count, seam + window))
                return abs(max(after, silenceGateLufs) - max(before, silenceGateLufs))
            }
        }
    }

    /// The §8.6 flatness of a trimmed candidate: momentary loudness every 100 ms (400 ms windows from sample 0, whole
    /// windows only) without the windows below −70 LUFS, then 1 − min(1, population stdev ÷ 6). Fewer than two
    /// windows give 1.
    public static func flatness(_ samples: [Float], sampleRate: Int) throws -> Double {
        try flatnessMeasurement(samples, sampleRate: sampleRate).flatness
    }

    static func flatnessMeasurement(_ samples: [Float], sampleRate: Int) throws -> (windows: Int, stdev: Double, flatness: Double) {
        try validate(samples, sampleRate: sampleRate)
        let window = sampleCount(momentarySeconds, sampleRate), step = sampleCount(flatnessStepSeconds, sampleRate)
        let levels: [Double] = kWeighted(samples, count: samples.count, sampleRate: sampleRate).withUnsafeBufferPointer { buffer in
            var levels: [Double] = []
            var start = 0
            while start + window <= samples.count {
                let level = loudness(buffer.baseAddress!, from: start, to: start + window)
                if level >= silenceGateLufs { levels.append(level) }
                start += step
            }
            return levels
        }
        guard levels.count >= 2 else { return (levels.count, 0, 1) }
        var sum = 0.0, squares = 0.0
        for level in levels { sum += level }
        let mean = sum / Double(levels.count)
        for level in levels { squares += (level - mean) * (level - mean) }
        let stdev = (squares / Double(levels.count)).squareRoot()
        return (levels.count, stdev, 1 - min(1, stdev / flatnessStdevScale))
    }

    /// The RMS in dBFS over the voiced 10 ms frames of `sides`, in order, or nil when no frame is voiced. Each side is
    /// framed from its own first sample, and its trailing partial frame is ignored.
    private static func voicedLevel(_ samples: [Float], sides: [Range<Int>], sampleRate: Int) -> Double? {
        let size = sampleCount(0.01, sampleRate)
        let threshold = pow(10, voicedFrameDbfs / 20)
        var total = 0.0, voicedFrames = 0
        samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            for side in sides {
                var frame = base + side.lowerBound
                let end = base + side.upperBound
                while end - frame >= size {
                    var sum = 0.0, sample = frame
                    let frameEnd = frame + size
                    while sample < frameEnd {
                        let value = Double(sample.pointee)
                        sum += value * value
                        sample += 1
                    }
                    if (sum / Double(size)).squareRoot() > threshold { total += sum; voicedFrames += 1 }
                    frame += size
                }
            }
        }
        guard voicedFrames > 0 else { return nil }
        return 20 * log10((total / Double(voicedFrames * size)).squareRoot())
    }

    static func oversampling(sampleRate: Int) -> Int { sampleRate < 96_000 ? 4 : sampleRate < 192_000 ? 2 : 1 }

    /// The shelf's mid-band numerator term is Vh raised to this exponent rather than √Vh.
    static let shelfMidBandExponent = 0.4996667741545416
    /// The RLB high-pass numerator, left unnormalised by a0.
    static let highPassNumerator = (b0: 1.0, b1: -2.0, b2: 1.0)

    /// The BS.1770 pre-filter shelf and RLB high-pass for `sampleRate`, by bilinear transform of their analog
    /// prototypes, prewarped at each centre frequency. The analog values, `shelfMidBandExponent` and
    /// `highPassNumerator` follow libebur128's derivation (MIT; no code is copied), which reproduces the published
    /// 48 kHz coefficients.
    // Spec: voice-lab.md §8.11 item 3 (BS.1770); the published 48 kHz K-weighting coefficients are the normative anchor.
    static func kWeighting(sampleRate: Int) -> (shelf: VoiceLabBiquad, highPass: VoiceLabBiquad) {
        let rate = Double(sampleRate)
        var k = tan(Double.pi * 1681.974450955533 / rate)
        var q = 0.7071752369554196
        let vh = pow(10, 3.999843853973347 / 20)
        let vb = pow(vh, shelfMidBandExponent)
        var a0 = 1 + k / q + k * k
        let shelf = VoiceLabBiquad(b0: (vh + vb * k / q + k * k) / a0, b1: 2 * (k * k - vh) / a0, b2: (vh - vb * k / q + k * k) / a0,
                                   a1: 2 * (k * k - 1) / a0, a2: (1 - k / q + k * k) / a0)
        k = tan(Double.pi * 38.13547087602444 / rate)
        q = 0.5003270373238773
        a0 = 1 + k / q + k * k
        return (shelf, VoiceLabBiquad(b0: highPassNumerator.b0, b1: highPassNumerator.b1, b2: highPassNumerator.b2,
                                      a1: 2 * (k * k - 1) / a0, a2: (1 - k / q + k * k) / a0))
    }

    /// The first `count` samples through the shelf and then the RLB high-pass in Float64, each in direct form I from
    /// zero state.
    static func kWeighted(_ samples: [Float], count: Int, sampleRate: Int) -> [Double] {
        let (shelf, highPass) = kWeighting(sampleRate: sampleRate)
        var output = [Double](repeating: 0, count: count)
        output.withUnsafeMutableBufferPointer { buffer in
            samples.withUnsafeBufferPointer { input in
                guard var target = buffer.baseAddress, var source = input.baseAddress else { return }
                let end = target + count
                // The shelf's outputs m are also the high-pass inputs, so both stages share that history.
                var x1 = 0.0, x2 = 0.0, m1 = 0.0, m2 = 0.0, y1 = 0.0, y2 = 0.0
                while target < end {
                    let x = Double(source.pointee)
                    let m = shelf.b0 * x + shelf.b1 * x1 + shelf.b2 * x2 - shelf.a1 * m1 - shelf.a2 * m2
                    let y = highPass.b0 * m + highPass.b1 * m1 + highPass.b2 * m2 - highPass.a1 * y1 - highPass.a2 * y2
                    x2 = x1; x1 = x; m2 = m1; m1 = m; y2 = y1; y1 = y
                    target.pointee = y
                    target += 1; source += 1
                }
            }
        }
        return output
    }

    static func loudness(_ weighted: UnsafePointer<Double>, from start: Int, to end: Int) -> Double {
        var sum = 0.0, sample = weighted + start
        let stop = weighted + end
        while sample < stop {
            sum += sample.pointee * sample.pointee
            sample += 1
        }
        return -0.691 + 10 * log10(sum / Double(end - start))
    }

    /// ITU-R BS.1770-4 (10/2015), Annex 2: the 48-tap, 4-phase FIR interpolating filter, phase 0 to phase 3.
    private static let truePeakTaps: [Double] = [
        0.0017089843750, 0.0109863281250, -0.0196533203125, 0.0332031250000, -0.0594482421875, 0.1373291015625,
        0.9721679687500, -0.1022949218750, 0.0476074218750, -0.0266113281250, 0.0148925781250, -0.0083007812500,
        -0.0291748046875, 0.0292968750000, -0.0517578125000, 0.0891113281250, -0.1665039062500, 0.4650878906250,
        0.7797851562500, -0.2003173828125, 0.1015625000000, -0.0582275390625, 0.0330810546875, -0.0189208984375,
        -0.0189208984375, 0.0330810546875, -0.0582275390625, 0.1015625000000, -0.2003173828125, 0.7797851562500,
        0.4650878906250, -0.1665039062500, 0.0891113281250, -0.0517578125000, 0.0292968750000, -0.0291748046875,
        -0.0083007812500, 0.0148925781250, -0.0266113281250, 0.0476074218750, -0.1022949218750, 0.9721679687500,
        0.1373291015625, -0.0594482421875, 0.0332031250000, -0.0196533203125, 0.0109863281250, 0.0017089843750,
    ]

    static func sampleCount(_ seconds: Double, _ sampleRate: Int) -> Int {
        Int(EditingPrimitives.jsRound(seconds * Double(sampleRate)))
    }

    static func validate(_ samples: [Float], sampleRate: Int) throws {
        guard sampleRate > 0, sampleCount(0.01, sampleRate) >= 1 else { throw VoiceLabAudioMathError.invalidInput }
        try requireFinite(samples)
    }

    static func requireFinite(_ samples: [Float]) throws {
        let finite = samples.withUnsafeBufferPointer { buffer in
            guard var sample = buffer.baseAddress else { return true }
            let end = sample + buffer.count
            while sample < end {
                if !sample.pointee.isFinite { return false }
                sample += 1
            }
            return true
        }
        guard finite else { throw VoiceLabAudioMathError.invalidInput }
    }
}
