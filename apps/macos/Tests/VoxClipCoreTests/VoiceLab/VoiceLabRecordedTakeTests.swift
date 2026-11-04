import Foundation
import Testing
@testable import VoxClipCore

@Suite("Recorded own takes")
struct VoiceLabRecordedTakeTests {
    @Test func spokenWordsTimeTheirCharactersAsAnAlignmentDoes() throws {
        let spoken = [VoiceLabSpokenWord(text: "Hello,", start: 0.3, end: 0.7), VoiceLabSpokenWord(text: "world", start: 0.8, end: 1.2)]
        let timing = VoiceLabRecordedTake.alignment(spoken)
        #expect(timing.map(\.character).joined() == "Hello, world")
        #expect(timing.first?.start == 0.3 && timing.last?.end == 1.2)
        #expect(zip(timing, timing.dropFirst()).allSatisfy { $0.end <= $1.start + 1e-12 })
        let words = try VoiceLabAlignment.words(characters: timing.map(\.character), starts: timing.map(\.start),
            ends: timing.map(\.end), expectedText: "Hello, world")
        #expect(words.map(\.text) == ["Hello,", "world"] && words.map(\.start) == [0.3, 0.8] && words.map(\.end) == [0.7, 1.2])
    }

    @Test func recordedProvenanceNamesNoVoiceOrConsent() {
        var provenance = VoiceLabProvenance(provider: VoiceLabRecordedTake.provider, endpoint: VoiceLabRecordedTake.endpoint,
            model: "apple-speech", voiceId: VoiceLabRecordedTake.voiceID, consentRecordId: nil, requestId: "take", seed: 0, createdAt: Date())
        provenance.region = VoiceLabRecordedTake.region
        #expect(VoiceLabRecordedTake.isRecorded(provenance))
        var consented = provenance; consented.consentRecordId = "record"
        var cloned = provenance; cloned.provider = "elevenlabs"
        var paced = provenance; paced.pace = 1.1
        #expect(![consented, cloned, paced].contains(where: VoiceLabRecordedTake.isRecorded))
    }

    @Test func recordedSegmentsDecodeAndStayDistinct() throws {
        let data = try JSONEncoder().encode([VoiceLabSegmentKind.recorded, .tts, .voiceChanger])
        #expect(String(decoding: data, as: UTF8.self) == #"["recorded","tts","voiceChanger"]"#)
        #expect(try JSONDecoder().decode([VoiceLabSegmentKind].self, from: data) == [.recorded, .tts, .voiceChanger])
    }
}
