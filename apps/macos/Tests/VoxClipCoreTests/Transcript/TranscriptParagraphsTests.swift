import Foundation
import Testing
@testable import VoxClipCore

/// The display paragraph rule (impl-plan item 22): speaker changes, the 1.5 s gap after a
/// sentence end, the sentence end after 80 words, and the forced break by 150 words before
/// the word after the widest gap among words 120–150, the later gap on a tie.
@Suite struct TranscriptParagraphsTests {
    /// `count` words 0.25 s long, 0.25 s apart, by one speaker, none ending a sentence. Times
    /// are multiples of 1/8 s, exact in binary, so equal gaps tie exactly.
    private func monologue(_ count: Int, speaker: String? = "a") -> [TimedWord] {
        (0..<count).map { TimedWord(id: "w\($0)", text: "word", start: Double($0) * 0.5, end: Double($0) * 0.5 + 0.25, speaker: speaker) }
    }
    /// Moves word `index` and every word after it `seconds` later, widening the gap before it.
    private func widen(_ words: inout [TimedWord], before index: Int, by seconds: Double) {
        for position in index..<words.count { words[position].start += seconds; words[position].end += seconds }
    }
    private func lengths(_ words: [TimedWord]) -> [Int] { TranscriptParagraphs.split(words: words).map(\.count) }

    @Test func noWordsHaveNoParagraphsAndOneWordHasOne() {
        #expect(TranscriptParagraphs.split(words: []).isEmpty)
        #expect(TranscriptParagraphs.split(words: monologue(1)) == [0..<1])
    }

    @Test func aSpeakerChangeStartsAParagraph() {
        var words = monologue(6)
        for index in 3..<6 { words[index].speaker = "b" }
        #expect(TranscriptParagraphs.split(words: words) == [0..<3, 3..<6])
        words[5].speaker = nil
        #expect(TranscriptParagraphs.split(words: words) == [0..<3, 3..<5, 5..<6])
    }

    @Test func aGapOfOnePointFiveSecondsAfterASentenceEndStartsAParagraph() {
        var words = monologue(6)
        words[2].text = "end."
        widen(&words, before: 3, by: 1.25)
        #expect(words[3].start - words[2].end == 1.5)
        #expect(TranscriptParagraphs.split(words: words) == [0..<3, 3..<6])
        words[2].text = "end"
        #expect(TranscriptParagraphs.split(words: words) == [0..<6], "a long gap without a sentence end keeps the paragraph")
        words[2].text = "end?"
        widen(&words, before: 3, by: -0.125)
        #expect(TranscriptParagraphs.split(words: words) == [0..<6], "a sentence end before a gap under 1.5 s keeps the paragraph")
        for ending in ["end!", "end…", "end?"] {
            words[2].text = ending
            widen(&words, before: 3, by: 0.125)
            #expect(TranscriptParagraphs.split(words: words) == [0..<3, 3..<6], "\(ending)")
            widen(&words, before: 3, by: -0.125)
        }
    }

    @Test func theFirstSentenceEndAfterEightyWordsStartsAParagraph() {
        var words = monologue(200)
        words[78].text = "seventy-nine."
        words[99].text = "hundred."
        // Word 79 ends a sentence before the paragraph holds 80 words; word 100 is the first after.
        #expect(lengths(words) == [100, 100])
        words[79].text = "eighty."
        #expect(lengths(words) == [80, 120], "a sentence end on word 80 breaks; the next paragraph counts from its own start, so word 100's does not")
    }

    @Test func aParagraphWithoutABreakEndsAfterTheWidestGapAmongWords120To150() {
        var words = monologue(400)
        widen(&words, before: 130, by: 0.5)
        widen(&words, before: 140, by: 0.25)
        // The widest gap among words 120–150 follows word 130 (index 129).
        let paragraphs = TranscriptParagraphs.split(words: words)
        #expect(paragraphs.first == 0..<130)
        #expect(paragraphs.allSatisfy { $0.count <= TranscriptParagraphs.maximumWords })
        #expect(paragraphs.dropLast().allSatisfy { $0.count >= TranscriptParagraphs.forcedWindow.lowerBound })
        // A widest gap before word 120 or after word 151 does not count.
        var outside = monologue(300)
        widen(&outside, before: 100, by: 2)
        widen(&outside, before: 160, by: 2)
        #expect(lengths(outside).first == 150, "equal gaps inside the window: the later one, after word 150")
    }

    @Test func aTieBetweenTheWidestGapsTakesTheLaterOne() {
        var words = monologue(300)
        widen(&words, before: 125, by: 0.5)
        widen(&words, before: 145, by: 0.5)
        #expect(lengths(words).first == 145)
        widen(&words, before: 120, by: 0.5)
        #expect(lengths(words).first == 145, "the gap after word 120 ties too and is earlier")
        widen(&words, before: 120, by: 0.125)
        #expect(lengths(words).first == 120, "a wider gap after word 120 wins")
    }

    @Test func theSplitCoversEveryWordInOrderAndNeverExceeds150Words() {
        // Every 37th word ends a sentence, speakers change every 500 words, gaps vary.
        let words: [TimedWord] = (0..<10_000).map { index in
            let start = Double(index) * 0.4 + Double(index % 7) * 0.05
            return TimedWord(id: "w\(index)", text: index % 37 == 36 ? "word." : "word", start: start, end: start + 0.3, speaker: "s\(index / 500)")
        }
        let paragraphs = TranscriptParagraphs.split(words: words)
        #expect(paragraphs.first?.lowerBound == 0 && paragraphs.last?.upperBound == words.count)
        #expect(zip(paragraphs, paragraphs.dropFirst()).allSatisfy { $0.upperBound == $1.lowerBound })
        #expect(paragraphs.allSatisfy { !$0.isEmpty && $0.count <= 150 })
        #expect(TranscriptParagraphs.split(words: words) == paragraphs, "deterministic")
        // Equal gaps everywhere: every forced break takes the latest gap, after word 150.
        let single = TranscriptParagraphs.split(words: monologue(10_000))
        #expect(single.count == 67 && single.dropLast().allSatisfy { $0.count == 150 } && single.last?.count == 100)
    }

    @Test func theParagraphHoldingAWordIsFoundByBinarySearch() {
        let paragraphs = [0..<3, 3..<10, 10..<11]
        #expect(TranscriptParagraphs.paragraph(containing: 0, in: paragraphs) == 0)
        #expect(TranscriptParagraphs.paragraph(containing: 2, in: paragraphs) == 0)
        #expect(TranscriptParagraphs.paragraph(containing: 3, in: paragraphs) == 1)
        #expect(TranscriptParagraphs.paragraph(containing: 10, in: paragraphs) == 2)
        #expect(TranscriptParagraphs.paragraph(containing: 11, in: paragraphs) == nil)
        #expect(TranscriptParagraphs.paragraph(containing: -1, in: paragraphs) == nil)
        #expect(TranscriptParagraphs.paragraph(containing: 0, in: []) == nil)
    }
}
