import Foundation
import Testing
@testable import VoxClipMedia

/// A camera's audio track can end a few ms after its container (a DJI recording: audio 348.224 s, container 348.198 s).
/// The project's duration is the audio track's end, the reader stops at the container's, so every Rewrite phrase failed
/// `rangeOutsideMedia` on that file (MVP25, 2026-11-05). The missing tail is read as silence, up to 100 ms.
@Suite("Voice Lab source: a camera's short container")
struct VoiceLabContainerTailTests {
    let rate = 48_000

    @Test func aRangeInsideTheContainerIsUntouched() {
        let tail = VoiceLabSourceAudio.containerTail(range: 0..<1_000_000, readableFrames: 2_000_000, trackFrames: 2_000_000, sampleRate: rate)
        #expect(tail.decoded == 0..<1_000_000 && tail.missing == 0)
    }

    @Test func theDJITailIsDecodedToTheContainerEndAndPaddedWithSilence() {
        let audioEnd: Int64 = 16_714_752, containerEnd: Int64 = 16_713_504  // 348.224 s and 348.198 s at 48 kHz
        let tail = VoiceLabSourceAudio.containerTail(range: 0..<audioEnd, readableFrames: containerEnd, trackFrames: audioEnd, sampleRate: rate)
        #expect(tail.decoded == 0..<containerEnd)
        #expect(tail.missing == audioEnd - containerEnd && tail.missing == 1_248)
    }

    @Test func aGapLongerThan100msIsLeftToTheRangeCheck() {
        let tail = VoiceLabSourceAudio.containerTail(range: 0..<1_010_000, readableFrames: 1_000_000, trackFrames: 1_010_000, sampleRate: rate)
        #expect(tail.decoded == 0..<1_010_000 && tail.missing == 0)
    }

    @Test func aRangePastTheAudioTracksOwnEndIsNotPadded() {
        // The caller asked for more than the audio track has: that's a wrong range, not a camera's rounding.
        let tail = VoiceLabSourceAudio.containerTail(range: 0..<481_000, readableFrames: 480_240, trackFrames: 480_240, sampleRate: rate)
        #expect(tail.decoded == 0..<481_000 && tail.missing == 0)
    }

    @Test func aSliverBeforeTheContainerEndIsSilenceToo() {
        // 5 ms readable, 20 ms missing: the readable part is under the 20 ms chunk minimum.
        let tail = VoiceLabSourceAudio.containerTail(range: 1_000_000..<1_001_200, readableFrames: 1_000_240, trackFrames: 1_001_200, sampleRate: rate)
        #expect(tail.decoded.isEmpty && tail.missing == 1_200)
    }
}
