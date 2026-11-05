import Foundation
import Testing
@testable import VoxClipCore

/// ai.md §12.9: the rewrite request gives each span of the source its time in the video and a word budget, never more
/// words than the span had, and the shared prompt says why the length is fixed.
@Suite struct VoiceRewriteSlotsTests {
    /// MVP32 Clip 7's words around changes 2 and 3, with the speaker's own timings (about 2.6 words per second).
    static let words: [TimedWord] = {
        let texts = ["software", "is", "just", "a", "thing", "that", "is", "solved", "a", "bit", "better", "than", "before.",
                     "But", "of", "course,", "it", "doesn't", "mean", "that", "everything", "is", "quality", "software."]
        var at = 0.0
        return texts.enumerated().map { index, text in
            defer { at += 0.38 + (text.hasSuffix(".") ? 0.45 : 0) }
            return TimedWord(id: "w\(index)", text: text, start: at, end: at + 0.32)
        }
    }()

    @Test func everySpanHasABudgetNeverAboveItsOwnWords() throws {
        let rate = try VoiceRewriteSlots.wordsPerSecond(transcript: Self.words)
        let slots = try #require(try VoiceRewriteSlots.make(sourceWords: Self.words, wordsPerSecond: rate, multiplier: 1))
        #expect(slots.map(\.text) == ["software is just a thing that is solved a bit better than before.", "But of course,",
                                      "it doesn't mean that everything is quality software."])
        for slot in slots {
            let count = slot.text.split(separator: " ").count
            #expect(slot.seconds > 0 && slot.maxWords >= 1 && slot.maxWords <= count, "\(slot)")
        }
        // The measured takes ran 2.2× the estimate (the user's DJI project): the budgets tighten with them.
        let measured = try #require(try VoiceRewriteSlots.make(sourceWords: Self.words, wordsPerSecond: rate, multiplier: 2.2))
        #expect(zip(measured, slots).allSatisfy { $0.maxWords <= $1.maxWords })
        #expect(zip(measured, slots).contains { $0.maxWords < $1.maxWords })
    }

    @Test func aPauseClosesASpanAndTooManySpansSendNone() throws {
        let paused = [TimedWord(id: "a", text: "one", start: 0, end: 0.3), TimedWord(id: "b", text: "two", start: 1.0, end: 1.3)]
        let slots = try #require(try VoiceRewriteSlots.make(sourceWords: paused, wordsPerSecond: 3, multiplier: 1))
        #expect(slots.map(\.text) == ["one", "two"])
        let many = (0..<(VoiceRewriteSlots.maximumSlots + 1)).map { TimedWord(id: "w\($0)", text: "word.", start: Double($0), end: Double($0) + 0.4) }
        #expect(try VoiceRewriteSlots.make(sourceWords: many, wordsPerSecond: 3, multiplier: 1) == nil)
    }

    @Test func theRequestSaysWhyAndListsEachSlot() throws {
        let prompt = try FixtureLoader.decode(JSONValue.self, at: "prompts/voice-rewrite.json")
        #expect(prompt[ai: "promptVersion"].aiInt == 4)
        let system = try #require(prompt[ai: "system"].aiString)
        #expect(system.contains("picture keeps running") && system.contains("never pad"))
        var input = VoiceRewriteRequest(id: UUID(), scope: .passage, sourceWords: Self.words, instruction: "Viral YouTuber",
                                        language: "en", targetSeconds: 9.5, minChars: 90, maxChars: 100)
        let plain = try VoiceRewriteService.requestText(input, source: "x", prompt: prompt).instruction
        #expect(!plain.contains("TIME IN THE VIDEO") && plain.contains("no more time than that: at most 100"))
        input.slots = [VoiceRewriteSlot(text: "that is", seconds: 1.1, maxWords: 2),
                       VoiceRewriteSlot(text: "{index} of course, it doesn't mean that", seconds: 3.7, maxWords: 6)]
        let text = try VoiceRewriteService.requestText(input, source: "x", prompt: prompt).instruction
        #expect(text.contains("TIME IN THE VIDEO (the picture keeps running"))
        #expect(text.contains("1. “that is”: 1.1 s, at most 2 words"))
        #expect(text.contains("2. “{index} of course, it doesn't mean that”: 3.7 s, at most 6 words"))
    }

    @Test func theFitAndPatchPromptsSayWhyAndNeverAskForPadding() throws {
        let fit = try FixtureLoader.decode(JSONValue.self, at: "prompts/voice-rewrite-fit.json")
        #expect(fit[ai: "promptVersion"].aiInt == 2)
        #expect(fit[ai: "system"].aiString?.contains("picture keeps running") == true)
        #expect(fit[ai: "request"][ai: "longerPhraseLine"].aiString?.contains("Never add filler") == true)
        #expect(fit[ai: "request"][ai: "fitFeedbackBlock"].aiString?.contains("fewer words are fine") == true)
        let patch = try FixtureLoader.decode(JSONValue.self, at: "prompts/patch-rewrite.json")
        #expect(patch[ai: "system"].aiString?.contains("The video keeps running under the new words") == true)
        #expect(patch[ai: "request"][ai: "rangesLine"].aiString?.contains("same number of syllables") == false)
        let tones = try FixtureLoader.decode(JSONValue.self, at: "data/rewrite-tones.json")
        for tone in tones[ai: "tones"].aiArray {
            let instruction = try #require(tone[ai: "instruction"].aiString)
            #expect(instruction.contains("never pad") || instruction.contains("Never pad"), "\(tone[ai: "id"])")
            #expect(!instruction.contains("about as long as") && !instruction.contains("close to the length"), "\(tone[ai: "id"])")
        }
    }
}
