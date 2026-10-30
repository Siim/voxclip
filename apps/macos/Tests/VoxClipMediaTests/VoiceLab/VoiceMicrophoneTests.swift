#if DEBUG
import AVFoundation
import Foundation
import Testing
@testable import VoxClipMedia

@Suite("Microphone take recovery") @MainActor
struct VoiceMicrophoneTests {
    @Test func stopDetectsSilenceBeforeTheNextMeterTick() throws {
        let recorder = VoiceMicrophoneRecorder(), sink = VoiceMicrophoneSamples(seconds: 30)
        recorder.simulateTake(samples: [0.1], input: sink, at: .now) {}
        let zeros = [Float](repeating: 0, count: 96_000)
        sink.observeInput(try input([zeros, zeros], rate: 48_000))
        recorder.stop()
        #expect(!recorder.recording && recorder.failure == .silent && recorder.samples.isEmpty)
    }
    @Test func stopClosesTheSinkSoLateSilenceCannotChangeAnAcceptedTake() throws {
        let recorder = VoiceMicrophoneRecorder(), sink = VoiceMicrophoneSamples(seconds: 30)
        recorder.simulateTake(samples: [0.1, 0.2], input: sink, at: .now) {}
        recorder.stop()
        #expect(!recorder.recording && recorder.failure == nil && recorder.samples == [0.1, 0.2])
        // Input and mixer callbacks can still arrive until their taps are gone.
        let zeros = [Float](repeating: 0, count: 96_000)
        sink.observeInput(try input([zeros, zeros], rate: 48_000))
        sink.append(try input([[0.3]], rate: 48_000))
        let state = sink.state.withLock { ($0.silent, $0.samples, $0.closed) }
        #expect(!state.0 && state.1 == [0.1, 0.2] && state.2)
        #expect(recorder.failure == nil && recorder.samples == [0.1, 0.2])
    }
    @Test(arguments: [16_000.0, 44_100.0, 48_000.0], [false, true])
    func silenceStopsAtExactlyTwoSecondsBeforeMixing(rate: Double, interleaved: Bool) throws {
        let recorder = VoiceMicrophoneRecorder(), sink = VoiceMicrophoneSamples(seconds: 30)
        let start = ContinuousClock.now
        var stops = 0
        recorder.simulateTake(samples: [], input: sink, at: start) { stops += 1 }
        let rateFrames: Int = Int(rate)
        let targetFrames: Int = rateFrames * 2
        let zeros = [Float](repeating: 0, count: targetFrames - 1)
        sink.observeInput(try input([zeros, zeros], rate: rate, interleaved: interleaved))
        sink.append(try input([[0]], rate: 48_000))
        recorder.checkInput(at: start)
        #expect(recorder.recording && recorder.failure == nil)
        sink.observeInput(try input([[-0.0], [0.0]], rate: rate, interleaved: interleaved))
        sink.append(try input([[0]], rate: 48_000))
        recorder.checkInput(at: start.advanced(by: .seconds(2)))
        #expect(!recorder.recording && recorder.samples.isEmpty && recorder.seconds == 0)
        #expect(recorder.failure == .silent && stops == 1)
        #expect(recorder.failure?.localizedDescription == "The microphone sent only silence. Check that it isn't muted, and that System Settings → Privacy & Security → Microphone allows VoxClip.")
        recorder.stop(); recorder.discard()
        #expect(stops == 1)
        #expect(MicrophoneError.privacySettingsURL.absoluteString == "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }
    @Test(arguments: [false, true])
    func opposingChannelsAndTinyNonzeroSamplesAreNotSilence(interleaved: Bool) throws {
        for amplitude: Float in [0.25, .leastNonzeroMagnitude] {
            let recorder = VoiceMicrophoneRecorder(), sink = VoiceMicrophoneSamples(seconds: 30)
            let start = ContinuousClock.now
            recorder.simulateTake(samples: [], input: sink, at: start) {}
            let positive = [Float](repeating: amplitude, count: 3 * 48_000)
            let negative = [Float](repeating: -amplitude, count: positive.count)
            sink.observeInput(try input([positive, negative], rate: 48_000, interleaved: interleaved))
            sink.append(try input([[Float](repeating: 0, count: positive.count)], rate: 48_000))
            recorder.checkInput(at: start.advanced(by: .seconds(3)))
            #expect(recorder.recording && recorder.failure == nil)
            recorder.stop()
            #expect(recorder.samples.count == positive.count && recorder.samples.allSatisfy { $0 == 0 })
        }
    }
    @Test func aNonzeroSampleOnAnyChannelRestartsTheSilentInterval() throws {
        let recorder = VoiceMicrophoneRecorder(), sink = VoiceMicrophoneSamples(seconds: 30)
        let start = ContinuousClock.now
        recorder.simulateTake(samples: [], input: sink, at: start) {}
        let zeros = [Float](repeating: 0, count: 95_999)
        sink.observeInput(try input([zeros, zeros], rate: 48_000))
        sink.observeInput(try input([[0], [0.1]], rate: 48_000))
        sink.observeInput(try input([zeros, zeros], rate: 48_000))
        sink.append(try input([[0]], rate: 48_000))
        recorder.checkInput(at: start)
        #expect(recorder.recording && recorder.failure == nil)
        sink.observeInput(try input([[0], [0]], rate: 48_000))
        recorder.checkInput(at: start)
        #expect(!recorder.recording && recorder.failure == .silent)
        recorder.simulateTake(samples: [0.1], at: start) {}
        #expect(recorder.recording && recorder.failure == nil)
        recorder.discard()
    }
    @Test(arguments: [false, true], ["int16", "int32"])
    func integerInputAlsoChecksEveryChannel(interleaved: Bool, kind: String) throws {
        let common: AVAudioCommonFormat = kind == "int16" ? .pcmFormatInt16 : .pcmFormatInt32
        let format = try #require(AVAudioFormat(commonFormat: common, sampleRate: 16_000, channels: 2, interleaved: interleaved))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32_000))
        buffer.frameLength = 32_000
        let buffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        for audio in buffers { memset(try #require(audio.mData), 0, Int(audio.mDataByteSize)) }
        let sink = VoiceMicrophoneSamples(seconds: 30)
        sink.observeInput(buffer)
        #expect(sink.state.withLock { $0.silent })
        let nonzero = VoiceMicrophoneSamples(seconds: 30)
        let dataChannel = interleaved ? 0 : 1
        let offset = interleaved ? 1 : 0
        if kind == "int16" { buffer.int16ChannelData?[dataChannel][offset] = 1 }
        else { buffer.int32ChannelData?[dataChannel][offset] = 1 }
        nonzero.observeInput(buffer)
        #expect(!nonzero.state.withLock { $0.silent })
    }
    private func input(_ channels: [[Float]], rate: Double, interleaved: Bool = false) throws -> AVAudioPCMBuffer {
        let count = try #require(channels.first?.count)
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: AVAudioChannelCount(channels.count), interleaved: interleaved))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
        buffer.frameLength = AVAudioFrameCount(count)
        let data = try #require(buffer.floatChannelData)
        for channel in channels.indices {
            let dataChannel = interleaved ? 0 : channel
            for frame in 0..<count {
                let offset = interleaved ? frame * channels.count + channel : frame
                data[dataChannel][offset] = channels[channel][frame]
            }
        }
        return buffer
    }
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
