#if DEBUG
import Foundation
import Testing
@testable import VoxClipMedia

@Suite("Microphone take recovery") @MainActor
struct VoiceMicrophoneTests {
    @Test func stalledInputDiscardsEvenAnOtherwiseLongEnoughTake() {
        let recorder = VoiceMicrophoneRecorder()
        let start = ContinuousClock.now
        var teardownCount = 0
        recorder.simulateTake(samples: [Float](repeating: 0.1, count: 6 * 48_000), at: start) { teardownCount += 1 }
        recorder.checkInput(at: start.advanced(by: .seconds(2)))
        #expect(!recorder.recording && recorder.samples.isEmpty && recorder.seconds == 0)
        #expect(recorder.failure == .deviceLost)
        #expect(recorder.failure?.localizedDescription.contains("discarded") == true)
        #expect(teardownCount == 1)
        recorder.stop(); recorder.discard()
        #expect(teardownCount == 1)
        recorder.simulateTake(samples: [Float](repeating: 0.2, count: 48_000), at: start) { teardownCount += 1 }
        recorder.checkInput(at: start.advanced(by: .milliseconds(100)))
        #expect(recorder.recording && recorder.failure == nil)
        recorder.stop()
        #expect(recorder.samples.count == 48_000 && teardownCount == 2)
    }
    @Test func teardownRemovesTapOnNormalStopDiscardAndDeinit() {
        var teardownCount = 0
        var recorder: VoiceMicrophoneRecorder? = VoiceMicrophoneRecorder()
        recorder?.simulateTake(samples: [0.1], at: .now) { teardownCount += 1 }
        recorder?.discard()
        #expect(teardownCount == 1)
        recorder?.simulateTake(samples: [0.1], at: .now) { teardownCount += 1 }
        recorder = nil
        #expect(teardownCount == 2)
    }
}
#endif
