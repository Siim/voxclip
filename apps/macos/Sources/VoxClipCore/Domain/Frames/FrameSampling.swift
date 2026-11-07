import Foundation

/// A clip's words as the frame analyzer reads them: the clip's transcript range, which of its words are kept, and where
/// it starts (ADR-R48).
public struct FrameClip: Sendable, Equatable {
    public let words: [TimedWord]
    /// Transcript positions of the clip's first and last item.
    public let first: Int
    public let last: Int
    /// Positions of the clip's spoken words that are not cut, in order.
    public let kept: [Int]

    /// Nil when either end word is missing, the range is reversed or no word in it is kept.
    public init?(transcript: Transcript, clip: ClipRange, cutWordIds: Set<String>) {
        guard let first = transcript.words.firstIndex(where: { $0.id == clip.startWordId }),
              let last = transcript.words.firstIndex(where: { $0.id == clip.endWordId }), first <= last else { return nil }
        self.init(words: transcript.words, first: first, last: last, cutWordIds: cutWordIds)
    }

    public init?(words: [TimedWord], first: Int, last: Int, cutWordIds: Set<String>) {
        guard first >= 0, last < words.count, first <= last else { return nil }
        let kept = (first...last).filter { words[$0].kind == .word && !cutWordIds.contains(words[$0].id) }
        guard !kept.isEmpty else { return nil }
        self.words = words
        self.first = first
        self.last = last
        self.kept = kept
    }

    /// The source second the clip's first kept word starts.
    public var start: Double { words[kept[0]].start }
    /// The source second the clip's last kept word ends.
    public var end: Double { words[kept[kept.count - 1]].end }

    /// The end of the last transcript item, of any kind, that ends at or before the clip's start; 0 when none does. A
    /// shift of the start never goes before it, so no earlier word is heard (`OpeningFrame`).
    public var leadInFloor: Double {
        let startIndex = kept[0]
        guard startIndex > 0 else { return 0 }
        return words[..<startIndex].map(\.end).filter { $0 <= start + 1e-9 }.max() ?? 0
    }
}

/// One sentence's frame: its source time and the kept words it stands for.
public struct FrameSample: Codable, Sendable, Equatable {
    public var time: Double
    public var firstWord: Int
    public var lastWord: Int
    public init(time: Double, firstWord: Int, lastWord: Int) { self.time = time; self.firstWord = firstWord; self.lastWord = lastWord }
}

/// Which source times the analyzer looks at (ADR-R48).
public enum FrameSampling {
    /// At most this many sentence frames per clip: the frame sheet's limit.
    public static let maximumSentences = 24
    /// A sentence longer than this many kept words is split, so a run-on transcript still gets frames.
    public static let maximumSentenceWords = 40
    /// The opening scan: every 0.1 s from `openingSpan` before the clip's start to `openingSpan` after it.
    public static let openingStep = 0.1
    public static let openingSpan = 0.6

    /// One sample per sentence of kept words, at the middle of its middle word. With more sentences than `limit`, evenly
    /// spaced sentences are kept, the first and last always among them.
    public static func sentenceSamples(_ clip: FrameClip, limit: Int = maximumSentences) -> [FrameSample] {
        guard limit > 0 else { return [] }
        var sentences: [[Int]] = []
        var current: [Int] = []
        for index in clip.kept {
            current.append(index)
            if TranscriptParagraphs.endsSentence(clip.words[index].text) || current.count >= maximumSentenceWords {
                sentences.append(current)
                current = []
            }
        }
        if !current.isEmpty { sentences.append(current) }
        let chosen: [[Int]]
        if sentences.count <= limit { chosen = sentences }
        else if limit == 1 { chosen = [sentences[0]] }
        else {
            let span = Double(sentences.count - 1), steps = Double(limit - 1)
            chosen = (0..<limit).map { step in
                let position = (Double(step) * span / steps).rounded()
                return sentences[Int(position)]
            }
        }
        return chosen.map { sentence in
            let middle = clip.words[sentence[sentence.count / 2]]
            let time = (middle.start + middle.end) / 2
            return FrameSample(time: time, firstWord: sentence[0], lastWord: sentence[sentence.count - 1])
        }
    }

    /// The opening scan's times around `start`, never before 0, in order.
    public static func openingTimes(start: Double) -> [Double] {
        let steps = Int((openingSpan / openingStep).rounded())
        return (-steps...steps).compactMap { step in
            let time = start + Double(step) * openingStep
            return time >= 0 ? (time * 1000).rounded() / 1000 : nil
        }
    }
}
