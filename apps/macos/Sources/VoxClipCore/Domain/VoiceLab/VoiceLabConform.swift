import Foundation

/// How to conform provider audio whose length differs from its input; voice-lab.md §4.4 and §7.3. Sample counts and
/// lags are on the input rate's grid.
public enum VoiceLabConformDecision: Equatable, Sendable {
    /// The lengths differ by at most 20 ms: trim `delta` samples from the end when positive, or zero-pad `−delta`
    /// samples there when negative.
    case trimOrPad(delta: Int)
    /// The output is `lag` samples late (early when negative): drop its first `lag` samples, or pad `−lag` zeros
    /// before it, then trim or pad the end to the input length. `peak` is the envelope correlation at that lag.
    case shift(lag: Int, peak: Double)
    /// The output cannot be aligned with its input and is not applied. The provider cost was already spent, so the
    /// UI must say so (§4.4 step 4).
    case outOfSync(peak: Double, lag: Int)
}

/// The duration-conform decision for a Clean audio or voice-changer chunk; voice-lab.md §4.4 and §7.3. Pure: no I/O,
/// media framework or global state.
public enum VoiceLabConform {
    /// The voice changer's lag search (§7.3).
    public static let voiceChangerSearchSeconds = 0.3
    /// Clean audio's lag search (§4.4 step 3).
    public static let cleanAudioSearchSeconds = 0.5
    static let toleranceSeconds = 0.020
    static let correlationFloor = 0.5

    /// Decides how to conform `outputSamples` of provider audio, already resampled to the input rate, to
    /// `inputSamples`. Both envelopes are the 10 ms RMS of their audio at `sampleRate`: frames of
    /// `round_half_up(rate × 0.01)` samples from sample 0, without the partial final frame.
    ///
    /// When |Δ| ≤ 20 ms the result is `trimOrPad`. Otherwise the lag L, in whole frames within ±`searchSeconds`, is the
    /// one whose overlapping frames correlate best: the Pearson correlation, with both means taken over the overlap,
    /// at most 1, and 0 for a constant overlap or one shorter than half the shorter envelope. Ties go to the smallest
    /// |L|, then to the negative lag. A peak below 0.5, or |Δ − L| above 20 ms, is `outOfSync`; otherwise the result is
    /// `shift`.
    // Spec: voice-lab.md §4.4 step 3 "normalised cross-correlation", read as Pearson over each lag's overlap (lead decision).
    public static func decide(inputEnvelope: AudioEnvelope, outputEnvelope: AudioEnvelope, inputSamples: Int, outputSamples: Int,
                              sampleRate: Int, searchSeconds: Double) throws -> VoiceLabConformDecision {
        let frame = sampleRate > 0 ? VoiceLabLoudness.sampleCount(VoiceLabPatchConstants.RMS_FRAME, sampleRate) : 0
        guard frame >= 1, inputSamples >= 0, outputSamples >= 0,
              searchSeconds.isFinite, searchSeconds >= 0, searchSeconds * Double(sampleRate) < 0x1p53,
              matches(inputEnvelope, frames: inputSamples / frame, frame: frame, sampleRate: sampleRate),
              matches(outputEnvelope, frames: outputSamples / frame, frame: frame, sampleRate: sampleRate)
        else { throw VoiceLabAudioMathError.invalidInput }
        let tolerance = VoiceLabLoudness.sampleCount(toleranceSeconds, sampleRate)
        let delta = outputSamples - inputSamples
        guard abs(delta) > tolerance else { return .trimOrPad(delta: delta) }
        let input = inputEnvelope.levels.map(Double.init), output = outputEnvelope.levels.map(Double.init)
        let reach = VoiceLabLoudness.sampleCount(searchSeconds, sampleRate) / frame
        var bestLag = 0, best = correlation(input, output, lag: 0)
        var distance = 1
        while distance <= reach {
            for lag in [-distance, distance] {
                let value = correlation(input, output, lag: lag)
                if value > best { bestLag = lag; best = value }
            }
            distance += 1
        }
        let lag = bestLag * frame
        return best < correlationFloor || abs(delta - lag) > tolerance ? .outOfSync(peak: best, lag: lag) : .shift(lag: lag, peak: best)
    }

    private static func matches(_ envelope: AudioEnvelope, frames: Int, frame: Int, sampleRate: Int) -> Bool {
        envelope.sampleRate == Double(sampleRate) && envelope.levels.count == frames
            && EditingPrimitives.jsRound(envelope.frameSeconds * Double(sampleRate)) == Double(frame)
            && envelope.levels.allSatisfy { $0.isFinite }
    }

    /// The Pearson correlation of `a[i]` and `b[i + lag]` over their overlap, at most 1. It is 0 when the overlap is
    /// constant or shorter than `ceil(min(a.count, b.count) / 2)` frames: two frames correlate ±1 by construction, so a
    /// short overlap at the edge of the search would beat the true lag of a short chunk (lead decision).
    static func correlation(_ a: [Double], _ b: [Double], lag: Int) -> Double {
        let start = max(0, -lag), end = min(a.count, b.count - lag)
        guard end > start, end - start >= (min(a.count, b.count) + 1) / 2 else { return 0 }
        return a.withUnsafeBufferPointer { left in
            b.withUnsafeBufferPointer { right in
                // b is read at index + lag, which stays inside it; no pointer is formed before its first element.
                let x = left.baseAddress!, y = right.baseAddress!
                var sumX = 0.0, sumY = 0.0, index = start
                while index < end { sumX += x[index]; sumY += y[index + lag]; index += 1 }
                let meanX = sumX / Double(end - start), meanY = sumY / Double(end - start)
                var cross = 0.0, energyX = 0.0, energyY = 0.0
                index = start
                while index < end {
                    let dx = x[index] - meanX, dy = y[index + lag] - meanY
                    cross += dx * dy; energyX += dx * dx; energyY += dy * dy
                    index += 1
                }
                return energyX > 0 && energyY > 0 ? min(1, cross / (energyX * energyY).squareRoot()) : 0
            }
        }
    }
}
