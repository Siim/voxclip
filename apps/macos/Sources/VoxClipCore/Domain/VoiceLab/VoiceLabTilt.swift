import Foundation

/// Tone match at render (voice-lab §8.7 item 2b, ADR-R42): a generated take is tilted towards the spectral slope of the
/// original speech beside it. Measured once when the take is processed, stored on the segment as
/// `audio.tiltDbPerOctave`, and applied before the static gain wherever the take is heard (the take's own mix, the
/// preview and the export), so they all match. Loudness and room tone are unchanged.
///
/// Pure binary64 arithmetic in a fixed order; the vectors are `shared/fixtures/voice-lab/tilt-cases.json`
/// (`tools/fixtures/voice-lab/generate_tilt.py`). They use libm (cos, sin, tan, pow, log10), so check_drift compares
/// them within its float tolerance.
public enum VoiceLabTilt {
    /// The largest tilt applied either way, in dB per octave.
    public static let maximumDbPerOctave = 2.0
    /// Tilts are stored in steps of this size; a measured difference that rounds to 0 applies nothing.
    public static let stepDbPerOctave = 0.1
    /// The frequency the tilt pivots on: its gain there is 0 dB.
    public static let pivotHz = 1_000.0
    /// The cascade: one first-order high shelf per two octaves, each with twice the tilt as its gain.
    public static let shelfHz: [Double] = [250, 1_000, 4_000]
    /// One-third-octave band centres, 1 kHz × 2^(b/3) for b = −10…9: 100 Hz to 7.94 kHz.
    public static let bandIndices = Array(-10...9)
    /// A frame is voiced when its RMS is above −45 dBFS, the `VOICED_FRAME` of the level match.
    public static let voicedRms = pow(10, -45.0 / 20)
    /// The fewest bands both measurements must have for a slope.
    public static let minimumBands = 4

    // MARK: Measurement

    /// The power spectrum of a signal's voiced frames, summed per one-third-octave band.
    public struct Bands: Sendable, Equatable {
        public let sampleRate: Int
        public let frameSize: Int
        /// Per band in `bandIndices` order: the sum over voiced frames and bins of |X[k]|², or nil when the band has
        /// no bin below Nyquist at this rate.
        public var power: [Double?]
        public var frames: Int
    }

    /// The FFT size for a rate: the smallest power of two at least 40 ms long.
    public static func frameSize(sampleRate: Int) -> Int {
        var size = 1
        while Double(size) < Double(sampleRate) * 0.04 { size *= 2 }
        return size
    }

    /// The bins of band `index` at this rate and size: centre `fc = 1000 × 2^(index/3)`, bins `k` in 1…N/2−1 with
    /// `fc × 2^(−1/6) ≤ k × rate / N < fc × 2^(1/6)`. Empty when the band's upper edge passes Nyquist.
    static func bins(band index: Int, sampleRate: Int, frameSize: Int) -> Range<Int> {
        let centre = pivotHz * pow(2, Double(index) / 3)
        let lower = centre * pow(2, -1.0 / 6), upper = centre * pow(2, 1.0 / 6)
        guard upper <= Double(sampleRate) / 2 else { return 0..<0 }
        let spacing = Double(sampleRate) / Double(frameSize)
        var first = 1
        while first < frameSize / 2 && Double(first) * spacing < lower { first += 1 }
        var end = first
        while end < frameSize / 2 && Double(end) * spacing < upper { end += 1 }
        return first..<end
    }

    /// The bands of `sides`, each framed on its own grid from its first sample: Hann-windowed (periodic) frames of
    /// `frameSize` samples every `frameSize / 2`, whole frames only; a frame counts when its own RMS, before the
    /// window, is above `voicedRms`.
    public static func bands(_ sides: [ArraySlice<Float>], sampleRate: Int) -> Bands {
        let size = frameSize(sampleRate: sampleRate)
        let ranges = bandIndices.map { bins(band: $0, sampleRate: sampleRate, frameSize: size) }
        var power: [Double?] = ranges.map { $0.isEmpty ? nil : 0 }
        var frames = 0
        let window = (0..<size).map { 0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(size)) }
        var real = [Double](repeating: 0, count: size), imaginary = [Double](repeating: 0, count: size)
        for side in sides {
            var start = side.startIndex
            while side.endIndex - start >= size {
                var energy = 0.0
                for index in 0..<size { let value = Double(side[start + index]); energy += value * value }
                if (energy / Double(size)).squareRoot() > voicedRms {
                    for index in 0..<size { real[index] = Double(side[start + index]) * window[index]; imaginary[index] = 0 }
                    fft(&real, &imaginary)
                    for (band, range) in ranges.enumerated() where !range.isEmpty {
                        var sum = 0.0
                        for bin in range { sum += real[bin] * real[bin] + imaginary[bin] * imaginary[bin] }
                        power[band]! += sum
                    }
                    frames += 1
                }
                start += size / 2
            }
        }
        return Bands(sampleRate: sampleRate, frameSize: size, power: power, frames: frames)
    }

    /// The bands of the speech beside a window, from the same sides as the level match (§8.7 item 2): up to
    /// `LOUDNESS_NEIGHBOURHOOD` before and after it, each clamped to the take; the window itself is excluded.
    public static func neighbourhoodBands(_ source: VoiceLabSourceExcerpt, sampleRate: Int, window: Range<Int>) -> Bands? {
        guard sampleRate > 0, window.lowerBound >= 0, window.upperBound <= source.totalFrames else { return nil }
        let reach = Int(min(EditingPrimitives.jsRound(VoiceLabLoudness.loudnessNeighbourhoodSeconds * Double(sampleRate)), Double(source.totalFrames)))
        guard let before = source.samples(max(0, window.lowerBound - reach)..<window.lowerBound),
              let after = source.samples(window.upperBound..<min(source.totalFrames, window.upperBound + reach)) else { return nil }
        return bands([before, after], sampleRate: sampleRate)
    }

    /// The least-squares slope, in dB per octave, of `10 × log10(power / (bins × frames))` against `index / 3`, over
    /// the bands present in `bands` and in `other`. Nil without a voiced frame or with fewer than `minimumBands`.
    public static func slope(_ bands: Bands, commonWith other: Bands) -> Double? {
        guard bands.frames > 0 else { return nil }
        var points: [(x: Double, y: Double)] = []
        for (band, index) in bandIndices.enumerated() {
            guard let power = bands.power[band], let theirs = other.power[band], power > 0, theirs > 0 else { continue }
            let count = bins(band: index, sampleRate: bands.sampleRate, frameSize: bands.frameSize).count
            points.append((Double(index) / 3, 10 * log10(power / Double(count * bands.frames))))
        }
        guard points.count >= minimumBands else { return nil }
        let meanX = points.reduce(0.0) { $0 + $1.x } / Double(points.count)
        let meanY = points.reduce(0.0) { $0 + $1.y } / Double(points.count)
        var covariance = 0.0, variance = 0.0
        for point in points {
            covariance += (point.x - meanX) * (point.y - meanY)
            variance += (point.x - meanX) * (point.x - meanX)
        }
        return variance > 0 ? covariance / variance : nil
    }

    /// The tilt that brings a take's slope to the speech beside it: the difference of the two slopes over their common
    /// bands, clamped to ±`maximumDbPerOctave` and rounded to `stepDbPerOctave` (half away from zero). Nil when either
    /// can't be measured or the step rounds to 0: the take is left as it is.
    public static func match(source: Bands, take: Bands) -> Double? {
        guard let target = slope(source, commonWith: take), let current = slope(take, commonWith: source) else { return nil }
        let clamped = min(max(target - current, -maximumDbPerOctave), maximumDbPerOctave)
        let stepped = (clamped / stepDbPerOctave).rounded(.toNearestOrAwayFromZero) * stepDbPerOctave
        let value = (stepped * 10).rounded() / 10
        return value == 0 ? nil : value
    }

    // MARK: The filter

    /// A first-order section: `y[n] = b0 × x[n] + b1 × x[n−1] − a1 × y[n−1]`.
    public struct Section: Sendable, Equatable {
        public let b0: Double
        public let b1: Double
        public let a1: Double
    }

    /// The tilt's cascade at a rate: a bilinear first-order high shelf per `shelfHz` below 0.45 × rate, prewarped at
    /// its frequency, with gain `2 × tilt` dB (low frequencies 0 dB, half the gain at the shelf frequency). The first
    /// section is scaled so the cascade's gain at `pivotHz` is exactly 0 dB. Empty for a 0 or non-finite tilt.
    public static func sections(tiltDbPerOctave tilt: Double, sampleRate: Int) -> [Section] {
        guard tilt.isFinite, tilt != 0, sampleRate > 0 else { return [] }
        let clamped = min(max(tilt, -maximumDbPerOctave), maximumDbPerOctave)
        var sections: [Section] = []
        for frequency in shelfHz where frequency < 0.45 * Double(sampleRate) {
            let gain = pow(10, 2 * clamped / 20), root = gain.squareRoot()
            let k = tan(Double.pi * frequency / Double(sampleRate))
            let a0 = 1 + k * root
            sections.append(Section(b0: gain * (1 + k / root) / a0, b1: gain * (k / root - 1) / a0, a1: (k * root - 1) / a0))
        }
        guard let first = sections.first else { return [] }
        let pivot = magnitude(sections, hertz: pivotHz, sampleRate: sampleRate)
        sections[0] = Section(b0: first.b0 / pivot, b1: first.b1 / pivot, a1: first.a1)
        return sections
    }

    /// The cascade's linear magnitude at `hertz`.
    public static func magnitude(_ sections: [Section], hertz: Double, sampleRate: Int) -> Double {
        let omega = 2 * Double.pi * hertz / Double(sampleRate), c = cos(omega)
        var result = 1.0
        for section in sections {
            let numerator = section.b0 * section.b0 + section.b1 * section.b1 + 2 * section.b0 * section.b1 * c
            let denominator = 1 + section.a1 * section.a1 + 2 * section.a1 * c
            result *= (numerator / denominator).squareRoot()
        }
        return result
    }

    /// The cascade run sample by sample from zero state, in binary64, for one channel. The take's mix, the preview and
    /// the export all run it from the asset's first frame, so every reader of a frame hears the same sample.
    public struct Filter: Sendable {
        public let sections: [Section]
        private var input: [Double]
        private var output: [Double]
        public init(_ sections: [Section]) {
            self.sections = sections; input = Array(repeating: 0, count: sections.count); output = Array(repeating: 0, count: sections.count)
        }
        public mutating func process(_ sample: Float) -> Float { Float(step(Double(sample))) }
        /// One sample through every section, in binary64; `process` rounds it to Float32 once.
        mutating func step(_ sample: Double) -> Double {
            var value = sample
            for index in sections.indices {
                let section = sections[index]
                let result = section.b0 * value + section.b1 * input[index] - section.a1 * output[index]
                input[index] = value; output[index] = result
                value = result
            }
            return value
        }
    }

    /// `samples` through the cascade from zero state at their first sample. Unchanged without sections.
    public static func apply(_ samples: [Float], sections: [Section]) -> [Float] {
        guard !sections.isEmpty else { return samples }
        var filter = Filter(sections)
        return samples.map { filter.process($0) }
    }

    // MARK: FFT

    /// In-place iterative radix-2 FFT (decimation in time, bit-reversed input order), `real.count` a power of two.
    /// The twiddle for stage length `m` and offset `j` is `cos(−2πj/m) + i sin(−2πj/m)`, computed directly.
    static func fft(_ real: inout [Double], _ imaginary: inout [Double]) {
        let count = real.count
        guard count > 1 else { return }
        var j = 0
        for i in 1..<count {
            var bit = count >> 1
            while j & bit != 0 { j ^= bit; bit >>= 1 }
            j |= bit
            if i < j { real.swapAt(i, j); imaginary.swapAt(i, j) }
        }
        var length = 2
        while length <= count {
            let half = length / 2
            for offset in 0..<half {
                let angle = -2 * Double.pi * Double(offset) / Double(length)
                let wr = cos(angle), wi = sin(angle)
                var start = 0
                while start < count {
                    let a = start + offset, b = a + half
                    let tr = wr * real[b] - wi * imaginary[b], ti = wr * imaginary[b] + wi * real[b]
                    real[b] = real[a] - tr; imaginary[b] = imaginary[a] - ti
                    real[a] = real[a] + tr; imaginary[a] = imaginary[a] + ti
                    start += length
                }
            }
            length *= 2
        }
    }
}
