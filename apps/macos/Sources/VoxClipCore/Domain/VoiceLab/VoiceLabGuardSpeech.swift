import Foundation

/// The speech a Rewrite patch's use-time guard embeds (voice-lab.md §6.9): the transcript words' own audio nearest the
/// patch, from the original source, joined, up to `maximumSeconds`. Silence, road noise and music between words are not
/// part of it, so a noisy recording is judged on the speaker, as the enrollment statement is.
///
/// Where the transcript knows speakers, only the patch speaker's words count: first that speaker's turn around the patch,
/// widened outward word by word, then the same speaker's other turns nearest the patch. Another speaker's words are never
/// taken, so a phrase spoken by someone else is judged on that person's speech and stays blocked.
public struct VoiceLabGuardSpeech: Sendable, Equatable {
    /// Speech the guard reads for a patch, in seconds of word spans.
    public static let maximumSeconds = 10.0
    /// The most of one word's span that counts, the part nearest the patch: a word whose timing swallowed a pause brings
    /// no more than this.
    public static let maximumWordSeconds = 2.0
    /// Word spans closer than this are read as one range.
    static let joinSeconds = 0.01

    /// Source frames at the source rate, in order, not overlapping.
    public let ranges: [Range<Int>]
    /// The patch speaker's transcript label; nil when the transcript has no speakers.
    public let speaker: String?
    public var frames: Int { ranges.reduce(0) { $0 + $1.count } }

    public init(ranges: [Range<Int>], speaker: String?) { self.ranges = ranges; self.speaker = speaker }

    /// The guard's word spans for the patch `start..<end` (source seconds) of a source of `totalFrames` frames at
    /// `sampleRate`. Every transcript word counts, cut or kept: the guard asks whose voice the recording is.
    public static func select(items: [TimedWord], start: Double, end: Double, sampleRate: Int, totalFrames: Int,
                              maximumSeconds: Double = maximumSeconds) -> VoiceLabGuardSpeech {
        guard sampleRate > 0, totalFrames > 0 else { return VoiceLabGuardSpeech(ranges: [], speaker: nil) }
        let duration: Double = Double(totalFrames) / Double(sampleRate)
        func usable(_ word: TimedWord) -> Bool {
            guard word.kind == .word, word.start.isFinite, word.end.isFinite, word.end > word.start else { return false }
            return word.start < duration && word.end > 0
        }
        let words: [TimedWord] = items.filter(usable).sorted { $0.start < $1.start }
        guard !words.isEmpty else { return VoiceLabGuardSpeech(ranges: [], speaker: nil) }
        func distance(_ index: Int) -> Double {
            let word = words[index]
            let before: Double = start - word.end
            let after: Double = word.start - end
            return max(0, before, after)
        }
        let labeled = words.contains { $0.speaker != nil }
        let speaker: String? = labeled ? patchSpeaker(words, distance: distance) : nil
        // The turn around the patch: the contiguous words that carry the patch speaker's label.
        var turn = Set<Int>(words.indices)
        if labeled {
            let labelled: [Int] = words.indices.filter { words[$0].speaker == speaker }
            let inside: Int? = labelled.first { distance($0) == 0 }
            let closest: Int? = labelled.min { distance($0) < distance($1) }
            turn = []
            if let anchor = inside ?? closest {
                var low = anchor, high = anchor
                while low > 0, words[low - 1].speaker == speaker { low -= 1 }
                while high + 1 < words.count, words[high + 1].speaker == speaker { high += 1 }
                turn = Set(low...high)
            }
        }
        let eligible: [Int] = words.indices.filter { !labeled || words[$0].speaker == speaker }
        func precedes(_ left: Int, _ right: Int) -> Bool {
            let leftTurn: Bool = turn.contains(left), rightTurn: Bool = turn.contains(right)
            if leftTurn != rightTurn { return leftTurn }
            let a: Double = distance(left), b: Double = distance(right)
            if a != b { return a < b }
            return left < right
        }
        let ordered: [Int] = eligible.sorted(by: precedes)
        var chosen: [Range<Int>] = []
        var total = 0.0
        let rate = Double(sampleRate)
        for index in ordered {
            guard total < maximumSeconds else { break }
            let word = words[index]
            let budget: Double = min(maximumWordSeconds, maximumSeconds - total)
            let span = nearestPart(of: word, start: start, end: end, seconds: budget)
            let wordStart: Double = max(0, span.lowerBound)
            let wordEnd: Double = min(duration, span.upperBound)
            let lower: Int = max(0, min(totalFrames, Int((wordStart * rate).rounded(.down))))
            let upper: Int = max(lower, min(totalFrames, Int((wordEnd * rate).rounded(.up))))
            guard upper > lower else { continue }
            chosen.append(lower..<upper)
            total += Double(upper - lower) / rate
        }
        let join = Int((joinSeconds * rate).rounded())
        var merged: [Range<Int>] = []
        for range in chosen.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last, range.lowerBound <= last.upperBound + join {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else { merged.append(range) }
        }
        return VoiceLabGuardSpeech(ranges: merged, speaker: speaker)
    }

    /// The `seconds` of `word` nearest the patch: a word before it gives its end, one after it its start, and one over it
    /// the part around the patch. A word whose timing swallowed a long pause brings no more than this.
    private static func nearestPart(of word: TimedWord, start: Double, end: Double, seconds: Double) -> ClosedRange<Double> {
        if word.end - word.start <= seconds { return word.start...word.end }
        if word.end <= start { return (word.end - seconds)...word.end }
        if word.start >= end { return word.start...(word.start + seconds) }
        let middle: Double = (max(word.start, start) + min(word.end, end)) / 2
        let upper: Double = min(word.end, max(word.start, middle - seconds / 2) + seconds)
        return max(word.start, upper - seconds)...upper
    }

    /// The label most of the patch's own words carry, else the nearest labeled word's.
    private static func patchSpeaker(_ words: [TimedWord], distance: (Int) -> Double) -> String? {
        var counts: [String: Int] = [:]
        for index in words.indices where distance(index) == 0 {
            if let label = words[index].speaker { counts[label, default: 0] += 1 }
        }
        let ranked: [(key: String, value: Int)] = counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
        if let best = ranked.first { return best.key }
        let labelled: [Int] = words.indices.filter { words[$0].speaker != nil }
        let closest: Int? = labelled.min { distance($0) < distance($1) }
        return closest.flatMap { words[$0].speaker }
    }

    /// The source spans to decode for these ranges: neighbouring ranges less than `gap` frames apart share one span, so a
    /// patch's words are read in a few passes, not one per word.
    public func covers(joiningWithin gap: Int) -> [Range<Int>] {
        var result: [Range<Int>] = []
        for range in ranges {
            if let last = result.last, range.lowerBound - last.upperBound < gap {
                result[result.count - 1] = last.lowerBound..<range.upperBound
            } else { result.append(range) }
        }
        return result
    }

    /// The ranges' samples joined in source order, or nil when the excerpt does not hold one of them.
    public func samples(from source: VoiceLabSourceExcerpt) -> [Float]? {
        var joined: [Float] = []
        joined.reserveCapacity(frames)
        for range in ranges {
            guard let slice = source.samples(range) else { return nil }
            joined.append(contentsOf: slice)
        }
        return joined
    }
}
