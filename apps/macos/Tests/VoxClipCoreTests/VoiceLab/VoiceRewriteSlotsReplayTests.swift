#if DEBUG
import Foundation
import Testing
@testable import VoxClipCore

/// Replays shared/fixtures/voice-lab/rewrite-slot-cases.json (ai.md §12.9, ADR-R42), which the Windows Core replays too: each
/// selection's speaking rate, its spans, their seconds and word budgets, and the block the request renders from them.
@Suite("Rewrite slot vectors", .offlineFixtures)
struct VoiceRewriteSlotsReplayTests {
    private struct Document: Decodable {
        let schema: String
        let caseCount: Int
        let sources: [String: String]
        let constants: Constants
        let cases: [Case]
    }
    private struct Constants: Decodable {
        let pauseSeconds: Double
        let maximumSlots: Int
        let closing: String
        let onsetSeconds: Double
        let providerSpeechRateMultiplier: Double
        let priorSpread: Double
    }
    private struct Word: Decodable {
        let id: String
        let text: String
        let start: Double
        let end: Double
    }
    private struct Case: Decodable {
        let id: String
        let words: [Word]
        let multiplier: Double
        let spread: Double
        let wordsPerSecond: Double
        let slots: [VoiceRewriteSlot]?
        let slotsBlock: String?
    }

    private func document() throws -> Document {
        try JSONDecoder().decode(Document.self, from: FixtureLoader.data("fixtures/voice-lab/rewrite-slot-cases.json"))
    }

    @Test func theVectorsHaveTheirShapeAndTheCoresConstants() throws {
        let data = try FixtureLoader.data("fixtures/voice-lab/rewrite-slot-cases.json")
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["schema", "caseCount", "sources", "constants", "cases"])
        let document = try document()
        #expect(document.schema == "voxclip-rewrite-slots/1")
        #expect(document.cases.count == document.caseCount)
        #expect(document.sources.keys.sorted() == ["shared/prompts/voice-rewrite.json"])
        #expect(document.constants.pauseSeconds == VoiceRewriteSlots.pauseSeconds)
        #expect(document.constants.maximumSlots == VoiceRewriteSlots.maximumSlots)
        #expect(document.constants.closing == ".,;:!?…—")
        #expect(document.constants.onsetSeconds == VoiceLabPhraseTiming.onsetSeconds)
        #expect(document.constants.providerSpeechRateMultiplier == VoiceLabPhraseTiming.providerSpeechRateMultiplier)
        #expect(document.constants.priorSpread == VoiceLabRateCalibration.priorSpread)
    }

    @Test func replaysEverySlotVector() throws {
        let document = try document()
        let prompt = try FixtureLoader.decode(JSONValue.self, at: "prompts/voice-rewrite.json")
        for item in document.cases {
            let words = item.words.map { TimedWord(id: $0.id, text: $0.text, start: $0.start, end: $0.end) }
            let rate = try VoiceRewriteSlots.wordsPerSecond(transcript: words)
            let rateError = abs(rate - item.wordsPerSecond)
            #expect(rateError < 1e-12, "\(item.id): \(rate)")
            let slots = try VoiceRewriteSlots.make(sourceWords: words, wordsPerSecond: rate, multiplier: item.multiplier, spread: item.spread)
            guard let expected = item.slots else {
                #expect(slots == nil, "\(item.id)")
                continue
            }
            let made = try #require(slots, "\(item.id)")
            #expect(made.count == expected.count, "\(item.id)")
            for (slot, want) in zip(made, expected) {
                #expect(slot.text == want.text, "\(item.id)")
                let secondsError = abs(slot.seconds - want.seconds)
                #expect(secondsError < 1e-12, "\(item.id): \(slot.seconds)")
                #expect(slot.maxWords == want.maxWords, "\(item.id): \(slot.text)")
            }
            var request = VoiceRewriteRequest(id: UUID(), scope: .passage, sourceWords: words, instruction: "", language: "en",
                                              targetSeconds: 9.5, minChars: 90, maxChars: 100)
            request.slots = made
            let instruction = try VoiceRewriteService.requestText(request, source: "x", prompt: prompt).instruction
            let block = try #require(item.slotsBlock, "\(item.id)")
            #expect(instruction.contains("\n\n" + block), "\(item.id)")
        }
    }
}
#endif
