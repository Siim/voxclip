import Foundation

/// The unedited source's own pause levels at one seam (§8.11 item 3, `VoiceLabLoudness.sourcePausesLufs`).
public struct VoiceLabSourcePause: Sendable, Equatable {
    /// Quietest to loudest level of the source's pauses on both sides of the seam, in LUFS.
    public let range: ClosedRange<Double>
    /// Whether the source side, which the generated audio meets at the join, is in a pause; false when the join meets
    /// source speech and only the pause a take's pause stands in for is measured.
    public let besideJoin: Bool
    public init(range: ClosedRange<Double>, besideJoin: Bool) { self.range = range; self.besideJoin = besideJoin }
}

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

    /// The same level read from an excerpt of the source, which must hold the window and up to
    /// `LOUDNESS_NEIGHBOURHOOD` on each side of it, clamped to the track.
    public static func neighbourhoodVoicedRmsDb(_ source: VoiceLabSourceExcerpt, sampleRate: Int, window: Range<Int>) throws -> Double {
        guard sampleRate > 0, window.lowerBound >= 0, window.upperBound <= source.totalFrames else { throw VoiceLabAudioMathError.invalidInput }
        let reach = Int(min(EditingPrimitives.jsRound(loudnessNeighbourhoodSeconds * Double(sampleRate)), Double(source.totalFrames)))
        let lower = max(0, window.lowerBound - reach), upper = min(source.totalFrames, window.upperBound + reach)
        guard let samples = source.samples(lower..<upper) else { throw VoiceLabAudioMathError.invalidInput }
        return try neighbourhoodVoicedRmsDb(Array(samples), sampleRate: sampleRate, window: (window.lowerBound - lower)..<(window.upperBound - lower))
    }

    /// The background level at the window's seams (§8.7 item 3), in dBFS: the RMS pooled over the unvoiced 10 ms frames
    /// (at or below `VOICED_FRAME`) that touch each seam from outside the window, framed outward from the seam and
    /// stopping at the first voiced frame or after 0.4 s, the momentary window QA reads there. Nil with fewer than 10
    /// such frames, as at hard seams in connected speech. `source` must hold 0.4 s beside the window, clamped to the take.
    public static func seamBackgroundRmsDb(_ source: VoiceLabSourceExcerpt, sampleRate: Int, window: Range<Int>) throws -> Double? {
        let sides = try seamBackgroundPower(source, sampleRate: sampleRate, window: window)
        return level(power: sides.left.power + sides.right.power, frames: sides.left.frames + sides.right.frames, sampleRate: sampleRate)
    }

    /// The same background measured on each side of the window on its own (§8.7 item 3): before the incoming seam and
    /// after the outgoing one, each nil with fewer than 10 unvoiced frames there.
    public static func seamBackgroundSidesRmsDb(_ source: VoiceLabSourceExcerpt, sampleRate: Int,
                                                  window: Range<Int>) throws -> (left: Double?, right: Double?) {
        let sides = try seamBackgroundPower(source, sampleRate: sampleRate, window: window)
        return (level(power: sides.left.power, frames: sides.left.frames, sampleRate: sampleRate),
                level(power: sides.right.power, frames: sides.right.frames, sampleRate: sampleRate))
    }
    private static func level(power: Double, frames: Int, sampleRate: Int) -> Double? {
        guard frames >= 10, power > 0 else { return nil }
        return 10 * log10(power / Double(frames * sampleCount(VoiceLabPatchConstants.RMS_FRAME, sampleRate)))
    }
    private static func seamBackgroundPower(_ source: VoiceLabSourceExcerpt, sampleRate: Int,
                                            window: Range<Int>) throws -> (left: (power: Double, frames: Int), right: (power: Double, frames: Int)) {
        guard sampleRate > 0, window.lowerBound >= 0, window.upperBound <= source.totalFrames else { throw VoiceLabAudioMathError.invalidInput }
        let size = sampleCount(VoiceLabPatchConstants.RMS_FRAME, sampleRate), limit = sampleCount(momentarySeconds, sampleRate) / size
        let threshold = VoiceLabPatchConstants.VOICED_FRAME_LEVEL
        var sides: [(power: Double, frames: Int)] = []
        for outward in [-1, 1] {
            let span = outward < 0 ? max(0, window.lowerBound - limit * size)..<window.lowerBound
                                   : window.upperBound..<min(source.totalFrames, window.upperBound + limit * size)
            guard let held = source.samples(span) else { throw VoiceLabAudioMathError.invalidInput }
            let raw = Array(held)
            guard raw.allSatisfy(\.isFinite) else { throw VoiceLabAudioMathError.invalidInput }
            var total = 0.0, frames = 0
            for index in 0..<limit {
                let start = outward < 0 ? raw.count - (index + 1) * size : index * size
                guard start >= 0, start + size <= raw.count else { break }
                var sum = 0.0
                for offset in start..<(start + size) { sum += Double(raw[offset]) * Double(raw[offset]) }
                if (sum / Double(size)).squareRoot() > threshold { break }
                total += sum; frames += 1
            }
            sides.append((total, frames))
        }
        return (sides[0], sides[1])
    }

    /// The smallest background difference between the two sides, in dB, at which the room-tone bed ramps from one
    /// side's level to the other's instead of playing at their pooled level (§8.7 item 3).
    public static let roomToneRampMinimumDb = 1.0

    /// The room-tone loop's gain (§8.7 item 3): a background level (`seamBackgroundRmsDb`, or one side's from
    /// `seamBackgroundSidesRmsDb`) less the RMS of the selected run, clamped to `GAIN_CLAMP`; 0, its natural level, when
    /// there is no background to match.
    public static func roomToneGainDb(seamBackgroundRmsDb background: Double?, run: [Float]) throws -> Double {
        guard let background else { return 0 }
        guard background.isFinite, !run.isEmpty, run.allSatisfy(\.isFinite) else { throw VoiceLabAudioMathError.invalidInput }
        let power = run.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(run.count)
        guard power > 0 else { return 0 }
        return min(max(background - 10 * log10(power), -gainClampDb), gainClampDb)
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

    /// Every seam's signed momentary step, in order: `max(M_after, −70) − max(M_before, −70)` over the windows of
    /// `seamJumpLu`, whose value is this step's magnitude. One K-weighting pass over `samples`.
    public static func seamStepsLu(_ samples: [Float], sampleRate: Int, seamSamples: [Int]) throws -> [Double] {
        try seamSteps(samples, sampleRate: sampleRate, seamSamples: seamSamples)
    }

    /// The take QA's seam value (§8.11 item 3): how far each seam's signed step in the mixed audio lies outside the
    /// unedited source's own step at the same seam, and the largest of them, 0 without a seam. A seam sits in a pause or
    /// at a word edge, so one 400 ms side holds more speech than the other and the source itself steps there. A mixed
    /// step between 0 and the source's step, in the same direction, adds nothing; one beyond it adds the difference;
    /// one in the other direction adds its whole size, so a take far louder than the speech it replaces cannot pass by
    /// mirroring the source's step. Both lists come from `seamStepsLu`, seam by seam.
    public static func seamExcessLu(mixedSteps: [Double], sourceSteps: [Double]) throws -> Double {
        guard mixedSteps.count == sourceSteps.count, (mixedSteps + sourceSteps).allSatisfy(\.isFinite) else {
            throw VoiceLabAudioMathError.invalidInput
        }
        return zip(mixedSteps, sourceSteps).map { mixed, source in outside(mixed, source) }.max() ?? 0
    }

    /// The level of the pause on the generated side of each seam (§8.11 item 3), or nil when that side is not in a
    /// pause. The generated side is after the seam when `generatedAfter` says so (the incoming seam) and before it
    /// otherwise. It is framed in 10 ms frames outward from the seam, as `seamBackgroundRmsDb` frames it, and keeps the
    /// unvoiced frames (RMS at or below `VOICED_FRAME`) up to the first voiced frame or 0.4 s. A run that ends at the
    /// take's speech leaves out the take's own lead (`TTS_TRIM_LEAD`) before its first word at the incoming seam, or tail
    /// (`TTS_TRIM_TAIL`) after its last word at the outgoing one: its breath and onset or decay, not the pause. With at
    /// least 0.1 s kept, the level is the K-weighted loudness of just those frames, floored at −70 LUFS: the room tone,
    /// pad and pause the join brings, whatever lies further from the join.
    public static func generatedPauseLufs(_ samples: [Float], sampleRate: Int, seamSamples: [Int],
                                          generatedAfter: [Bool]) throws -> [Double?] {
        try pauseRuns(samples, sampleRate: sampleRate, seamSamples: seamSamples, generatedAfter: generatedAfter) { weighted, runs in
            runs.map { run in run.generated.map { max(loudness(weighted, from: $0.lowerBound, to: $0.upperBound), silenceGateLufs) } }
        }
    }

    /// The span next to a join whose level also bounds the source's pause there: the end of a decay or the start of a
    /// breath, which 0.1 s spans average away.
    static let pauseJoinSeconds = 0.03

    /// The unedited source's own pause levels at each seam (§8.11 item 3), or nil when the source is in no pause there.
    /// Each side's pause is framed as in `generatedPauseLufs` but read whole, up to the first voiced frame or the end of
    /// `samples`, and counts when it holds at least 0.1 s: the source side's (the side the generated audio does not
    /// replace) and the window side's (the pause a take's pause stands in for). The range runs from the quietest to the
    /// loudest K-weighted loudness, each floored at −70 LUFS, of the 0.1 s spans stepping frame by frame through those
    /// pauses and of each pause's `pauseJoinSeconds` next to the seam. So an inhale, a word's decay or the source's own
    /// step from its floor to a breath at the seam widens it, and the floor around them stays in it.
    public static func sourcePausesLufs(_ samples: [Float], sampleRate: Int, seamSamples: [Int],
                                        generatedAfter: [Bool]) throws -> [VoiceLabSourcePause?] {
        let size = sampleCount(VoiceLabPatchConstants.RMS_FRAME, sampleRate)
        let span = sampleCount(minimumSeamWindowSeconds, sampleRate) / size * size
        let join = max(1, sampleCount(pauseJoinSeconds, sampleRate) / size) * size
        return try pauseRuns(samples, sampleRate: sampleRate, seamSamples: seamSamples, generatedAfter: generatedAfter) { weighted, runs in
            zip(runs, generatedAfter).map { run, after -> VoiceLabSourcePause? in
                var lower = Double.infinity, upper = -Double.infinity
                func add(_ start: Int, _ end: Int) {
                    let level = max(loudness(weighted, from: start, to: end), silenceGateLufs)
                    lower = min(lower, level); upper = max(upper, level)
                }
                // The source side lies before the seam when the generated audio follows it, and after it otherwise.
                for (pause, before) in [(run.source, after), (run.window, !after)] {
                    guard let pause else { continue }
                    var start = pause.lowerBound
                    while start + span <= pause.upperBound { add(start, start + span); start += size }
                    if before { add(pause.upperBound - join, pause.upperBound) } else { add(pause.lowerBound, pause.lowerBound + join) }
                }
                guard lower <= upper else { return nil }
                return VoiceLabSourcePause(range: lower...upper, besideJoin: run.source != nil)
            }
        }
    }

    /// The take QA's seam value (§8.11 item 3). A seam whose generated side is in a pause (`generatedPauseLevels` not
    /// nil) and whose source has a pause there (`sourcePauses` not nil) is a pause join: its value is how far the
    /// generated pause level lies outside the range of the source's own pause levels, so room tone that stops, or sits
    /// louder or quieter than every part of the pauses it meets or stands in for, is a jump, and a longer take pause, a
    /// breath or a word's decay in the source is not. Where the generated pause meets source speech instead
    /// (`besideJoin` false), the speech onset or end is the join, so the seam also passes when its 400 ms step does. Every
    /// other seam keeps `seamExcessLu(mixedSteps:sourceSteps:)`. The largest value, 0 without a seam.
    public static func seamExcessLu(mixedSteps: [Double], sourceSteps: [Double], generatedPauseLevels: [Double?],
                                    sourcePauses: [VoiceLabSourcePause?]) throws -> Double {
        let count = mixedSteps.count
        let bounds = sourcePauses.compactMap { $0 }.flatMap { [$0.range.lowerBound, $0.range.upperBound] }
        guard sourceSteps.count == count, generatedPauseLevels.count == count, sourcePauses.count == count,
              (mixedSteps + sourceSteps + generatedPauseLevels.compactMap { $0 } + bounds).allSatisfy(\.isFinite) else {
            throw VoiceLabAudioMathError.invalidInput
        }
        return (0..<count).map { index in
            let plain = outside(mixedSteps[index], sourceSteps[index])
            guard let level = generatedPauseLevels[index], let pause = sourcePauses[index] else { return plain }
            let value = max(0, pause.range.lowerBound - level, level - pause.range.upperBound)
            return pause.besideJoin ? value : min(value, plain)
        }.max() ?? 0
    }

    /// The unvoiced runs beside each seam, as sample ranges kept only when at least 0.1 s long: on the generated side up
    /// to 0.4 s and short of the take's speech edge, and whole on the source side and on the generated side (the window
    /// side, on the unedited source). `body` reads the K-weighted audio.
    private static func pauseRuns<T>(_ samples: [Float], sampleRate: Int, seamSamples: [Int], generatedAfter: [Bool],
                                     _ body: (UnsafePointer<Double>, [(generated: Range<Int>?, source: Range<Int>?, window: Range<Int>?)]) -> [T]) throws -> [T] {
        try validate(samples, sampleRate: sampleRate)
        guard generatedAfter.count == seamSamples.count, seamSamples.allSatisfy({ $0 >= 0 && $0 <= samples.count }) else {
            throw VoiceLabAudioMathError.invalidInput
        }
        guard !seamSamples.isEmpty else { return [] }
        let size = sampleCount(VoiceLabPatchConstants.RMS_FRAME, sampleRate)
        let limit = sampleCount(momentarySeconds, sampleRate) / size, minimum = sampleCount(minimumSeamWindowSeconds, sampleRate) / size
        let threshold = VoiceLabPatchConstants.VOICED_FRAME_LEVEL
        func unvoiced(_ start: Int) -> Bool {
            var sum = 0.0
            for index in start..<(start + size) { sum += Double(samples[index]) * Double(samples[index]) }
            return (sum / Double(size)).squareRoot() <= threshold
        }
        let lead = sampleCount(VoiceLabPatchConstants.TTS_TRIM_LEAD, sampleRate) / size
        let tail = sampleCount(VoiceLabPatchConstants.TTS_TRIM_TAIL, sampleRate) / size
        func run(from seam: Int, after: Bool, limit: Int, edge: Int = 0) -> Range<Int>? {
            var frames = 0
            while frames < limit {
                let start = after ? seam + frames * size : seam - (frames + 1) * size
                guard start >= 0, start + size <= samples.count, unvoiced(start) else { break }
                frames += 1
            }
            // Stopped by a voiced frame: the frames just before it belong to that speech.
            let next = after ? seam + frames * size : seam - (frames + 1) * size
            if frames < limit, next >= 0, next + size <= samples.count { frames = max(0, frames - edge) }
            guard frames >= minimum else { return nil }
            return after ? seam..<(seam + frames * size) : (seam - frames * size)..<seam
        }
        let runs = zip(seamSamples, generatedAfter).map { seam, after in
            (generated: run(from: seam, after: after, limit: limit, edge: after ? lead : tail), source: run(from: seam, after: !after, limit: .max),
             window: run(from: seam, after: after, limit: .max))
        }
        let weighted = kWeighted(samples, count: samples.count, sampleRate: sampleRate)
        return weighted.withUnsafeBufferPointer { body($0.baseAddress!, runs) }
    }
    /// How far `mixed` lies outside the interval between 0 and `source`.
    private static func outside(_ mixed: Double, _ source: Double) -> Double { max(0, min(0, source) - mixed, mixed - max(0, source)) }

    /// A recipe's `qa.lufsJumpLu`: the largest jump over its seams that are not `none`, or 0 without such a seam.
    public static func lufsJumpLu(_ samples: [Float], sampleRate: Int, seamSamples: [Int]) throws -> Double {
        try seamJumps(samples, sampleRate: sampleRate, seamSamples: seamSamples).max() ?? 0
    }

    // Spec: voice-lab.md §8.11 item 3; each window is floored at −70 LUFS, the BS.1770 absolute gate (lead decision).
    static func seamJumps(_ samples: [Float], sampleRate: Int, seamSamples: [Int]) throws -> [Double] {
        try seamSteps(samples, sampleRate: sampleRate, seamSamples: seamSamples).map(abs)
    }
    static func seamSteps(_ samples: [Float], sampleRate: Int, seamSamples: [Int]) throws -> [Double] {
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
                return max(after, silenceGateLufs) - max(before, silenceGateLufs)
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
        let size = sampleCount(VoiceLabPatchConstants.RMS_FRAME, sampleRate)
        let threshold = VoiceLabPatchConstants.VOICED_FRAME_LEVEL
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
        guard sampleRate > 0, sampleCount(VoiceLabPatchConstants.RMS_FRAME, sampleRate) >= 1 else { throw VoiceLabAudioMathError.invalidInput }
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
