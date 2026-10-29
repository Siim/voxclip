import AVFoundation
import Foundation
import Observation
import Synchronization

private final class VoiceMicrophoneSamples: Sendable {
    struct State: Sendable { var samples: [Float] = []; var level: Float = 0 }
    let state = Mutex(State())
    let maximum: Int
    init(seconds: Int) { maximum = seconds * 48_000 }
    func append(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        state.withLock { value in
            let count = min(Int(buffer.frameLength), maximum - value.samples.count)
            guard count > 0 else { return }
            let incoming = UnsafeBufferPointer(start: channel, count: count)
            value.samples.append(contentsOf: incoming)
            value.level = sqrt(incoming.reduce(Float(0)) { $0 + $1 * $1 } / Float(count))
        }
    }
}

@MainActor @Observable public final class VoiceMicrophoneRecorder {
    public private(set) var recording = false
    public private(set) var seconds = 0.0
    public private(set) var level = 0.0
    public private(set) var samples: [Float] = []
    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var meter: Task<Void, Never>?
    @ObservationIgnored private var sink: VoiceMicrophoneSamples?
    public init() {}
    public func start(maximumSeconds: Int) async throws {
        guard !recording, [30, 90].contains(maximumSeconds) else { return }
        guard await AVCaptureDevice.requestAccess(for: .audio) else { throw MicrophoneError.permission }
        try Task.checkCancellation()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0, let mono = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1) else { throw MicrophoneError.unavailable }
        let mixer = AVAudioMixerNode()
        engine.attach(mixer)
        engine.connect(input, to: mixer, format: format)
        engine.connect(mixer, to: engine.mainMixerNode, format: mono)
        engine.mainMixerNode.outputVolume = 0
        let sink = VoiceMicrophoneSamples(seconds: maximumSeconds)
        mixer.installTap(onBus: 0, bufferSize: 1_024, format: mono) { buffer, _ in sink.append(buffer) }
        engine.prepare()
        do { try engine.start() } catch { mixer.removeTap(onBus: 0); throw MicrophoneError.unavailable }
        self.engine = engine; self.sink = sink; samples = []; seconds = 0; level = 0; recording = true
        let deadline = ContinuousClock.now.advanced(by: .seconds(maximumSeconds))
        meter = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, let self else { return }
                let reading = sink.state.withLock { ($0.samples.count, $0.level) }
                self.seconds = Double(reading.0) / 48_000
                self.level = min(1, Double(reading.1) * 5)
                if reading.0 >= maximumSeconds * 48_000 || ContinuousClock.now >= deadline { self.stop(); return }
            }
        }
    }
    public func stop() {
        guard recording else { return }
        engine?.stop()
        meter?.cancel(); meter = nil
        samples = sink?.state.withLock { $0.samples } ?? []
        seconds = Double(samples.count) / 48_000
        recording = false; level = 0; engine = nil; sink = nil
    }
    public func discard() { stop(); samples = []; seconds = 0 }
}

public enum MicrophoneError: LocalizedError {
    case permission, unavailable
    public var errorDescription: String? {
        switch self {
        case .permission: "Microphone access is off. Allow VoxClip in System Settings → Privacy & Security → Microphone to record your consent."
        case .unavailable: "The microphone isn't available. Check your input device and try again."
        }
    }
}
