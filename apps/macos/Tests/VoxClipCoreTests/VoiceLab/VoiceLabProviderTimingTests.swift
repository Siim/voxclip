import Foundation
import Testing
@testable import VoxClipCore

/// voice-lab §8.5 "Timing recovery": a take's word check (or the on-device transcriber) gives its word times.
@Suite("Recovered take timing")
struct VoiceLabProviderTimingTests {
    private func words(_ timing: [VoiceLabCharacterTiming], _ typed: String) throws -> [VoiceLabWord] {
        try VoiceLabAlignment.words(characters: timing.map(\.character), starts: timing.map(\.start), ends: timing.map(\.end), expectedText: typed)
    }

    @Test func heardWordsKeepTheirTimesAndMapToTheTypedSpelling() throws {
        let typed = "Claude, that is, when you are using your Claude's"
        let heard = ["claude", "that", "is", "when", "you", "are", "using", "your", "claudes"].enumerated().map { index, text in
            VoiceLabWord(text: text, start: 0.1 + Double(index) * 0.3, end: 0.35 + Double(index) * 0.3, synthetic: true)
        }
        let result = try words(VoiceLabProviderTiming.recovered(heard, typedText: typed), typed)
        #expect(result.map(\.text) == typed.split(separator: " ").map(String.init))
        #expect(result.map(\.start) == heard.map(\.start) && result.map(\.end) == heard.map(\.end))
    }

    @Test func misheardAndMissedWordsShareTheirNeighboursSpan() throws {
        let typed = "I use a similar method as"
        // Scribe hears "simmer" for "similar" and misses "a": the take is still timed; the word check decides.
        let heard = [("I", 0.1, 0.2), ("use", 0.2, 0.4), ("simmer", 0.5, 0.9), ("method", 0.9, 1.3), ("as", 1.3, 1.5)].map {
            VoiceLabWord(text: $0.0, start: $0.1, end: $0.2, synthetic: true)
        }
        let result = try words(VoiceLabProviderTiming.recovered(heard, typedText: typed), typed)
        #expect(result.map(\.text) == ["I", "use", "a", "similar", "method", "as"])
        #expect(result[2].start == 0.5 && result[3].end == 0.9)
        #expect(zip(result, result.dropFirst()).allSatisfy { $0.end <= $1.start })
    }

    @Test func nothingHeardIsNotTiming() {
        #expect(throws: VoiceLabTimingFailure(check: "recovery_no_words")) {
            _ = try VoiceLabProviderTiming.recovered([], typedText: "Hello there")
        }
    }

    @Test func historyKeysIgnoreCasePunctuationAndTags() {
        #expect(VoiceLabFitTried.key("Use a SIMILAR method,  as") == VoiceLabFitTried.key("use a similar method as"))
        #expect(VoiceLabFitTried.key("[laughs] Claude’s way") == VoiceLabFitTried.key("claudes way"))
        #expect(VoiceLabFitTried.key("a similar method") != VoiceLabFitTried.key("a similar approach"))
    }
}
