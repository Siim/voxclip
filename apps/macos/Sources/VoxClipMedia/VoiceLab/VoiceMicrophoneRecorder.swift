import AVFoundation
import Foundation
import Observation
import Synchronization

final class VoiceMicrophoneSamples: Sendable {
    struct State: Sendable {
        var samples: [Float] = []
        var level: Float = 0
        var zeroFrames = 0
        var inputRate = 0.0
        var silent = false
    }
    let state = Mutex(State())
    let maximum: Int
    init(seconds: Int) { maximum = seconds * 48_000 }
    func observeInput(_ buffer: AVAudioPCMBuffer) {
        if let channels = buffer.floatChannelData { observeInput(channels, buffer: buffer) }
        else if let channels = buffer.int16ChannelData { observeInput(channels, buffer: buffer) }
        else if let channels = buffer.int32ChannelData { observeInput(channels, buffer: buffer) }
    }
    private func observeInput<Sample: Numeric>(_ channels: UnsafePointer<UnsafeMutablePointer<Sample>>, buffer: AVAudioPCMBuffer) {
        let rate = buffer.format.sampleRate
        let channelCount = Int(buffer.format.channelCount)
        let interleaved = buffer.format.isInterleaved
        let stride = interleaved ? channelCount : 1
        let requiredFrames: Double = 2 * rate
        guard rate.isFinite, rate > 0, channelCount > 0 else { return }
        state.withLock { value in
            guard !value.silent else { return }
            if value.inputRate != rate { value.zeroFrames = 0; value.inputRate = rate }
            for frame in 0..<Int(buffer.frameLength) {
                var zero = true
                for channel in 0..<channelCount {
                    let dataChannel = interleaved ? 0 : channel
                    let offset = frame * stride + (interleaved ? channel : 0)
                    if channels[dataChannel][offset] != .zero { zero = false; break }
                }
                value.zeroFrames = zero ? value.zeroFrames + 1 : 0
                if Double(value.zeroFrames) >= requiredFrames { value.silent = true; return }
            }
        }
    }
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
    public private(set) var failure: MicrophoneError?
    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var meter: Task<Void, Never>?
    @ObservationIgnored private var sink: VoiceMicrophoneSamples?
    @ObservationIgnored private var teardown: (@MainActor () -> Void)?
    @ObservationIgnored private var configurationObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var takeID: UUID?
    @ObservationIgnored private var lastCount = 0
    @ObservationIgnored private var lastProgress = ContinuousClock.now
    @ObservationIgnored private var deadline = ContinuousClock.now
    @ObservationIgnored private var maximumSamples = 0
    public init() {}
    isolated deinit {
        meter?.cancel()
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        teardown?()
    }
    public func start(maximumSeconds: Int) async throws {
        guard !recording, [30, 90].contains(maximumSeconds) else { return }
        failure = nil
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
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in sink.observeInput(buffer) }
        mixer.installTap(onBus: 0, bufferSize: 1_024, format: mono) { buffer, _ in sink.append(buffer) }
        engine.prepare()
        do { try engine.start() } catch { input.removeTap(onBus: 0); mixer.removeTap(onBus: 0); throw MicrophoneError.unavailable }
        self.engine = engine; self.sink = sink; samples = []; seconds = 0; level = 0; recording = true
        teardown = { input.removeTap(onBus: 0); mixer.removeTap(onBus: 0); engine.stop() }
        let id = UUID(); takeID = id
        lastCount = 0; lastProgress = .now
        deadline = lastProgress.advanced(by: .seconds(maximumSeconds)); maximumSamples = maximumSeconds * 48_000
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.takeID == id else { return }
                self.failInput()
            }
        }
        meter = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, let self else { return }
                self.checkInput(at: .now)
                if !self.recording { return }
            }
        }
    }
    public func stop() {
        guard recording else { releaseResources(); return }
        if sink?.state.withLock({ $0.silent }) == true { failInput(.silent); return }
        samples = sink?.state.withLock { $0.samples } ?? []
        seconds = Double(samples.count) / 48_000
        recording = false; releaseResources()
    }
    public func discard() { stop(); samples = []; seconds = 0 }
    func checkInput(at now: ContinuousClock.Instant) {
        guard recording, let sink else { return }
        let reading = sink.state.withLock { ($0.samples.count, $0.level, $0.silent) }
        if reading.2 { failInput(.silent); return }
        seconds = Double(reading.0) / 48_000
        level = min(1, Double(reading.1) * 5)
        if reading.0 != lastCount { lastCount = reading.0; lastProgress = now }
        if reading.0 >= maximumSamples { stop(); return }
        if lastProgress.duration(to: now) >= .milliseconds(1_500) { failInput(); return }
        if now >= deadline { stop() }
    }
    private func failInput(_ error: MicrophoneError = .deviceLost) {
        guard recording else { return }
        failure = error
        recording = false; samples = []; seconds = 0
        releaseResources()
    }
    private func releaseResources() {
        meter?.cancel(); meter = nil
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil; takeID = nil
        teardown?(); teardown = nil
        engine = nil; sink = nil; level = 0
    }
    #if DEBUG
    func simulateTake(samples: [Float], input: VoiceMicrophoneSamples? = nil, at now: ContinuousClock.Instant, teardown: @escaping @MainActor () -> Void) {
        discard(); failure = nil
        let sink = input ?? VoiceMicrophoneSamples(seconds: 30)
        sink.state.withLock { $0.samples = samples }
        self.sink = sink; self.teardown = teardown
        recording = true; lastCount = samples.count; lastProgress = now
        maximumSamples = 30 * 48_000; deadline = now.advanced(by: .seconds(30))
    }
    #endif
}

public enum MicrophoneError: LocalizedError, Equatable {
    case permission, unavailable, deviceLost, silent
    package static let privacySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
    public var errorDescription: String? {
        switch self {
        case .permission: "Microphone access is off. Allow VoxClip in System Settings → Privacy & Security → Microphone to record your consent."
        case .unavailable: "The microphone isn't available. Check your input device and try again."
        case .deviceLost: "The microphone stopped sending audio. This take was discarded. Check your input device and record again."
        case .silent: "The microphone sent only silence. Check that it isn't muted, and that System Settings → Privacy & Security → Microphone allows VoxClip."
        }
    }
}
