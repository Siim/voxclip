import Foundation
import Testing
@testable import VoxClipCore
@testable import VoxClipMedia

@Suite("Own take recognition")
struct MicrophoneTakeTranscriberTests {
    @Test func tokensJoinIntoTimedWords() {
        let tokens = [RawToken(text: " Hello", joinsPrevious: false, start: 0.3, end: 0.6, conf: 0.9, speaker: nil),
                      RawToken(text: ",", joinsPrevious: true, start: 0.6, end: 0.62, conf: 0.9, speaker: nil),
                      RawToken(text: " wor", joinsPrevious: false, start: 0.7, end: 0.9, conf: 0.9, speaker: nil),
                      RawToken(text: "ld", joinsPrevious: true, start: 0.9, end: 1.1, conf: 0.9, speaker: nil),
                      RawToken(text: "  ", joinsPrevious: false, start: 1.1, end: 1.2, conf: 0.9, speaker: nil)]
        #expect(OnDeviceTakeTranscriber.words(tokens) == [VoiceLabSpokenWord(text: "Hello,", start: 0.3, end: 0.62),
                                                          VoiceLabSpokenWord(text: "world", start: 0.7, end: 1.1)])
    }
}
