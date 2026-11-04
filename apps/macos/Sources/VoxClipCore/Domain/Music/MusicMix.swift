import Foundation

/// Pure arithmetic for the music bed under the voice; doc/spec/music.md §4. Media decodes and writes audio, this decides
/// every gain: speech activity from the final voice audio, ducking, fades, loudness match and crossfaded loops.
public enum MusicMix {
    /// Analysis frames are 10 ms long.
    public static let frameSeconds = 0.01
    /// The dip under speech.
    public static let duckDb = -12.0
    public static let attackSeconds = 0.15
    public static let releaseSeconds = 0.4
    /// Loops overlap by up to one second, equal-power.
    public static let loopCrossfadeSeconds = 1.0
    /// The speech level assumed when a clip has no measurable speech, in dBFS RMS.
    public static let fallbackSpeechDb = -20.0
    public static let silenceFloorDb = -120.0
    /// The bed never gains more than this, so a near-silent track is not pushed into noise.
    public static let maximumBoostDb = 12.0
    public static let minimumBedDb = -60.0
    /// Speech gaps shorter than this stay ducked; blips shorter than `minimumSpeechSeconds` are not speech.
    public static let bridgeGapSeconds = 0.25
    public static let minimumSpeechSeconds = 0.05

    /// RMS level in dBFS of each whole or trailing partial frame of mono samples.
    public static func frameLevels(_ mono: [Float], sampleRate: Double) -> [Double] {
        let size = max(1, Int((sampleRate * frameSeconds).rounded()))
        var accumulator = LevelAccumulator(frameSize: size)
        accumulator.append(mono)
        return accumulator.finish()
    }

    /// Streams mono samples into 10 ms RMS levels without keeping the audio.
    public struct LevelAccumulator: Sendable {
        public let frameSize: Int
        private var sum = 0.0
        private var count = 0
        public private(set) var levels: [Double] = []

        public init(frameSize: Int) { self.frameSize = max(1, frameSize) }

        public mutating func append(_ samples: some Collection<Float>) {
            for sample in samples {
                let value = Double(sample.isFinite ? sample : 0)
                sum += value * value
                count += 1
                if count == frameSize { flush() }
            }
        }

        private mutating func flush() {
            let mean = sum / Double(count)
            levels.append(mean > 0 ? max(MusicMix.silenceFloorDb, 10 * log10(mean)) : MusicMix.silenceFloorDb)
            sum = 0; count = 0
        }

        public mutating func finish() -> [Double] {
            if count > 0 { flush() }
            return levels
        }
    }

    /// Which frames hold speech. The threshold follows the clip's own loud frames (90th percentile − 25 dB, never below
    /// −50 dBFS), short blips are dropped and short pauses between words are bridged.
    public static func speechActivity(levels: [Double]) -> [Bool] {
        let audible = levels.filter { $0 > -80 }.sorted()
        guard !audible.isEmpty else { return Array(repeating: false, count: levels.count) }
        let index = min(audible.count - 1, Int((Double(audible.count - 1) * 0.9).rounded()))
        let threshold = max(-50.0, audible[index] - 25)
        var active = levels.map { $0 >= threshold }
        let minimumRun = Int((minimumSpeechSeconds / frameSeconds).rounded())
        let bridge = Int((bridgeGapSeconds / frameSeconds).rounded())
        replaceRuns(&active, value: true, shorterThan: minimumRun, with: false, interiorOnly: false)
        replaceRuns(&active, value: false, shorterThan: bridge, with: true, interiorOnly: true)
        return active
    }

    private static func replaceRuns(_ flags: inout [Bool], value: Bool, shorterThan limit: Int, with replacement: Bool, interiorOnly: Bool) {
        var start = 0
        while start < flags.count {
            var end = start
            while end < flags.count, flags[end] == flags[start] { end += 1 }
            let interior = start > 0 && end < flags.count
            if flags[start] == value, end - start < limit, interior || !interiorOnly {
                for index in start..<end { flags[index] = replacement }
            }
            start = end
        }
    }

    /// The power mean of `levels` where `include` is true, in dB; nil when nothing is included.
    public static func powerMeanDb(_ levels: [Double], where include: [Bool]) -> Double? {
        var sum = 0.0, count = 0
        for (level, included) in zip(levels, include) where included {
            sum += pow(10, level / 10); count += 1
        }
        guard count > 0, sum > 0 else { return nil }
        return 10 * log10(sum / Double(count))
    }

    /// The speech loudness of the final voice audio, or nil without speech.
    public static func speechLevelDb(levels: [Double], activity: [Bool]) -> Double? { powerMeanDb(levels, where: activity) }

    /// The track's own level over its audible frames.
    public static func musicLevelDb(levels: [Double]) -> Double? { powerMeanDb(levels, where: levels.map { $0 > -70 }) }

    /// The static gain that puts the bed `gainDb` below (or above) the speech: speech + gain − music, bounded.
    public static func bedGainDb(speechDb: Double?, musicDb: Double?, gainDb: Double) -> Double {
        let speech = speechDb ?? fallbackSpeechDb
        let music = musicDb ?? speech
        return min(maximumBoostDb, max(minimumBedDb, speech + gainDb - music))
    }

    /// Per-frame ducking in dB, linear in dB: it reaches `duckDb` by each speech onset (the attack starts 150 ms early,
    /// since the whole clip is known) and recovers over 400 ms after speech ends. All zeros without ducking.
    public static func duckingGainsDb(activity: [Bool], ducking: Bool = true) -> [Double] {
        guard ducking, activity.contains(true) else { return Array(repeating: 0, count: activity.count) }
        let attack = max(1.0, attackSeconds / frameSeconds)
        let release = max(1.0, releaseSeconds / frameSeconds)
        let count = activity.count
        var untilNext = Array(repeating: Double.infinity, count: count)
        var sinceLast = Array(repeating: Double.infinity, count: count)
        var next = Double.infinity
        for index in stride(from: count - 1, through: 0, by: -1) {
            next = activity[index] ? 0 : next + 1
            untilNext[index] = next
        }
        var last = Double.infinity
        for index in 0..<count {
            last = activity[index] ? 0 : last + 1
            sinceLast[index] = last
        }
        return (0..<count).map { index in
            let before = duckDb * max(0, 1 - untilNext[index] / attack)
            let after = duckDb * max(0, 1 - sinceLast[index] / release)
            return min(before, after)
        }
    }

    /// The ducking gain at `seconds`, interpolated between frame centres, as a linear factor.
    public static func duckFactor(_ gainsDb: [Double], at seconds: Double) -> Double {
        guard !gainsDb.isEmpty else { return 1 }
        let position = seconds / frameSeconds - 0.5
        let lower = max(0, min(gainsDb.count - 1, Int(position.rounded(.down))))
        let upper = min(gainsDb.count - 1, lower + 1)
        let fraction = max(0, min(1, position - Double(lower)))
        let db = gainsDb[lower] + (gainsDb[upper] - gainsDb[lower]) * fraction
        return pow(10, db / 20)
    }

    /// Linear fade-in from silence and fade-out to silence over a bed of `duration` seconds.
    public static func fadeFactor(at seconds: Double, duration: Double, fadeIn: Double, fadeOut: Double) -> Double {
        var factor = 1.0
        if fadeIn > 0 { factor = min(factor, max(0, seconds / fadeIn)) }
        if fadeOut > 0 { factor = min(factor, max(0, (duration - seconds) / fadeOut)) }
        return min(1, factor)
    }

    /// One stretch of the source track placed in the bed. Neighbours overlap by `fadeIn`/`fadeOut` frames.
    public struct LoopPiece: Sendable, Equatable {
        public let sourceStart: Int
        public let outputStart: Int
        public let count: Int
        public var fadeIn: Int
        public var fadeOut: Int
        public init(sourceStart: Int, outputStart: Int, count: Int, fadeIn: Int = 0, fadeOut: Int = 0) {
            self.sourceStart = sourceStart; self.outputStart = outputStart; self.count = count; self.fadeIn = fadeIn; self.fadeOut = fadeOut
        }
    }

    /// How a track of `trackFrames` fills `outputFrames` starting `offsetFrames` in: trimmed when long enough, otherwise
    /// looped from the track's start with equal-power crossfades of up to `crossfadeFrames` (a quarter of a short track).
    public static func loopPieces(trackFrames: Int, offsetFrames: Int, outputFrames: Int, crossfadeFrames: Int) -> [LoopPiece] {
        guard trackFrames >= 4, outputFrames > 0, offsetFrames >= 0, offsetFrames < trackFrames else { return [] }
        var pieces = [LoopPiece(sourceStart: offsetFrames, outputStart: 0, count: min(trackFrames - offsetFrames, outputFrames))]
        var end = pieces[0].count
        let crossfade = max(1, min(crossfadeFrames, trackFrames / 4))
        while end < outputFrames {
            let overlap = min(crossfade, pieces[pieces.count - 1].count / 2)
            let start = end - overlap
            let count = min(trackFrames, outputFrames - start)
            pieces[pieces.count - 1].fadeOut = overlap
            pieces.append(LoopPiece(sourceStart: 0, outputStart: start, count: count, fadeIn: overlap))
            end = start + count
        }
        return pieces
    }

    /// Equal-power crossfade weight of a piece at `index` frames into it.
    public static func pieceWeight(_ piece: LoopPiece, at index: Int) -> Double {
        var weight = 1.0
        if piece.fadeIn > 0, index < piece.fadeIn {
            weight *= sin(Double.pi / 2 * (Double(index) + 0.5) / Double(piece.fadeIn))
        }
        let tail = piece.count - index
        if piece.fadeOut > 0, tail <= piece.fadeOut {
            weight *= sin(Double.pi / 2 * (Double(tail) - 0.5) / Double(piece.fadeOut))
        }
        return weight
    }
}
