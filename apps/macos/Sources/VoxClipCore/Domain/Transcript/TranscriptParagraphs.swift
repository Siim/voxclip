import Foundation

/// The transcript's display paragraphs (impl-plan item 22). Paragraphs belong to the take:
/// they come from the words alone, never from a clip, a cut or a correction, so they never
/// reflow when a clip opens. Display only; nothing is saved.
///
/// A new paragraph starts before a word when
/// - the speaker changes, or
/// - the gap before it is at least `gapSeconds` and the word before ends a sentence, or
/// - the paragraph so far holds at least `sentenceWords` words and the word before ends a sentence.
///
/// A paragraph never holds more than `maximumWords` words. When it reaches that many with
/// another word after it and none of the rules above broke it, it ends before the word after
/// the largest gap among its words `forcedWindow` (1-based, the gap after word 150 being the one
/// before the next paragraph's first word); on a tie the later gap wins. So a 60-minute
/// monologue lays out as paragraphs of 80 to 150 words, and a fold edit lays out one of them.
public enum TranscriptParagraphs {
    public static let gapSeconds = 1.5
    public static let sentenceWords = 80
    public static let maximumWords = 150
    /// The words whose following gap may end a paragraph that reached `maximumWords`.
    public static let forcedWindow = 120...150

    /// The paragraphs as ranges of word indices: contiguous, in order, covering every word.
    public static func split(words: [TimedWord]) -> [Range<Int>] {
        guard !words.isEmpty else { return [] }
        var paragraphs: [Range<Int>] = []
        var start = 0
        for index in 1..<words.count {
            let count = index - start
            let previous = words[index - 1], word = words[index]
            let sentence = endsSentence(previous.text)
            if word.speaker != previous.speaker || sentence && word.start - previous.end >= gapSeconds || sentence && count >= sentenceWords {
                paragraphs.append(start..<index)
                start = index
            } else if count == maximumWords {
                // Words 1...150 of the paragraph: the break goes after word `length`.
                var length = forcedWindow.lowerBound, widest = -Double.infinity
                for candidate in forcedWindow {
                    let gap = words[start + candidate].start - words[start + candidate - 1].end
                    if gap >= widest { widest = gap; length = candidate }
                }
                paragraphs.append(start..<(start + length))
                start += length
            }
        }
        paragraphs.append(start..<words.count)
        return paragraphs
    }

    /// True when `text` ends with `.`, `?`, `!` or `…`.
    public static func endsSentence(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return last == "." || last == "?" || last == "!" || last == "…"
    }
}
