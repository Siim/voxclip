import Foundation

/// One span of the words a rewrite is asked about, how long they take in the video, and the most words its place can
/// hold (ai.md §12.9). The video keeps running under the new words, so a rewrite never gets more time than the words it
/// replaces: the budget is the estimator's word target for the span's seconds, and never more than the span's own words.
public struct VoiceRewriteSlot: Codable, Sendable, Equatable {
    public let text: String
    public let seconds: Double
    public let maxWords: Int
    public init(text: String, seconds: Double, maxWords: Int) {
        self.text = text; self.seconds = seconds; self.maxWords = maxWords
    }
}

public enum VoiceRewriteSlots {
    /// A silence this long between two words ends a span, as punctuation does.
    public static let pauseSeconds = 0.3
    /// A request lists at most this many spans; a longer selection is sent with its length line alone.
    public static let maximumSlots = 60

    /// The speaker's words per second over `transcript`: the estimator's speaking rate (letters and digits per second)
    /// over the letters per word, as the wording fit computes it.
    public static func wordsPerSecond(transcript: [TimedWord]) throws -> Double {
        let words = transcript.filter { $0.kind == .word }
        let characters = words.reduce(0) { $0 + VoiceLabTextLength.length($1.text) }
        guard characters > 0 else { throw VoiceLabLengthBudgetError.rateUnavailable }
        let rate = try VoiceLabPhraseTiming.speakingRate(transcript: transcript)
        return rate * Double(words.count) / Double(characters)
    }

    /// `sourceWords` in spans, each closed after a word ending in punctuation or before a pause of `pauseSeconds`, with
    /// its budget from `VoiceLabWordingFit.wordTarget` at `multiplier` (the voice's and project's measured takes) and `spread`
    /// (four takes in five fit), after each take's fixed start (`VoiceLabPhraseTiming.onsetSeconds`), capped at the span's word
    /// count. Nil when the words make no span or more than `maximumSlots`.
    public static func make(sourceWords: [TimedWord], wordsPerSecond: Double, multiplier: Double,
                            spread: Double = VoiceLabRateCalibration.priorSpread) throws -> [VoiceRewriteSlot]? {
        let words = sourceWords.filter { $0.kind == .word && $0.start.isFinite && $0.end.isFinite && $0.end >= $0.start }
        var spans: [[TimedWord]] = []
        var current: [TimedWord] = []
        for word in words {
            if let last = current.last, word.start - last.end >= pauseSeconds {
                spans.append(current); current = []
            }
            current.append(word)
            if let end = word.text.last, ".,;:!?…—".contains(end) { spans.append(current); current = [] }
        }
        if !current.isEmpty { spans.append(current) }
        guard !spans.isEmpty, spans.count <= maximumSlots else { return nil }
        return try spans.compactMap { span -> VoiceRewriteSlot? in
            guard let first = span.first, let last = span.last else { return nil }
            let seconds = last.end - first.start
            guard seconds > 0 else { return nil }
            let target = try VoiceLabWordingFit.wordTarget(wordsPerSecond: wordsPerSecond, multiplier: multiplier,
                minimumSeconds: 0, maximumSeconds: seconds, overheadSeconds: min(VoiceLabPhraseTiming.onsetSeconds, seconds), spread: spread)
            return VoiceRewriteSlot(text: span.map(\.text).joined(separator: " "), seconds: seconds,
                                    maxWords: max(1, min(target.maximum, span.count)))
        }
    }
}
