import Foundation
import AVFoundation
import MediaToolbox
import Synchronization
import VoxClipCore

public actor AVAudioExtractor: AudioExtractor {
    public init() {}

    public func extract(_ request: AudioExtractionRequest, progress: @escaping @Sendable (Double) -> Void) async throws -> AudioExtractionResult {
        let asset = AVURLAsset(url: request.sourceURL)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        var selected = request.audioTrackIndex
        if selected == 0 {
            for (index, track) in tracks.enumerated() where try await track.load(.isEnabled) { selected = index; break }
        }
        guard let track = try await MediaSupport.audioTrack(in: asset, index: selected),
              let format = try await track.load(.formatDescriptions).first,
              let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else { throw VoxClipError.noAudioTrack }
        let rate = description.mSampleRate
        let channels = Int(description.mChannelsPerFrame)
        let duration = request.durationSeconds > 0 ? request.durationSeconds : try await asset.load(.duration).seconds
        guard rate.isFinite, rate > 0, channels > 0, duration.isFinite, duration > 0, duration <= 86400,
              let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else { throw VoxClipError.decodeFailed("Unsupported audio format") }
        converter.downmix = true
        converter.primeMethod = .normal
        try FileManager.default.createDirectory(at: request.cacheDirectory, withIntermediateDirectories: true)
        let destination = request.cacheDirectory.appendingPathComponent("audio-16k.wav")
        let temporary = request.cacheDirectory.appendingPathComponent("audio-16k-\(UUID().uuidString).partial")
        let wav = try PCMFile(url: temporary, rate: 16000, channels: 1, float: false)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: MediaSupport.pcm(rate: rate, channels: channels))
        output.alwaysCopiesSampleData = false
        let provider = reader.outputProvider(for: output)
        let frameSize = max(1, Int((rate * 0.01).rounded()))
        var window = [Float](repeating: 0, count: frameSize * channels)
        var windowCount = 0
        var levels: [Float] = []
        levels.reserveCapacity(Int(duration / 0.01))
        var lastProgress = ContinuousClock.now

        func convert(_ input: AVAudioPCMBuffer?) throws {
            guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 16384) else { throw VoxClipError.decodeFailed("Cannot allocate audio converter output") }
            var supplied = false
            while true {
                var error: NSError?
                let status = converter.convert(to: converted, error: &error) { _, inputStatus in
                    if let input, !supplied { supplied = true; inputStatus.pointee = .haveData; return input }
                    inputStatus.pointee = input == nil ? .endOfStream : .noDataNow
                    return nil
                }
                if let error { throw VoxClipError.decodeFailed(error.localizedDescription) }
                if converted.frameLength > 0, let pointer = converted.floatChannelData?[0] {
                    let samples = UnsafeBufferPointer(start: pointer, count: Int(converted.frameLength)).map { value in
                        Int16((Double(value.isFinite ? max(-1, min(1, value)) : 0) * 32767).rounded(.toNearestOrAwayFromZero)).littleEndian
                    }
                    try samples.withUnsafeBytes { try wav.append(Data($0)) }
                }
                if status == .endOfStream || status == .inputRanDry { break }
                if status == .error { throw VoxClipError.decodeFailed("Audio conversion failed") }
            }
        }

        do {
            guard reader.startReading() else { throw VoxClipError.decodeFailed(reader.error?.localizedDescription ?? "Cannot read audio") }
            progress(0)
            while let ready = try await MediaSupport.nextSample(provider) {
                try Task.checkCancellation()
                let input = try ready.withUnsafeSampleBuffer { sample in
                    let count = CMSampleBufferGetNumSamples(sample)
                    guard let block = CMSampleBufferGetDataBuffer(sample),
                          let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: UInt32(count)),
                          let planes = input.floatChannelData else { throw VoxClipError.decodeFailed("Missing audio PCM") }
                    input.frameLength = UInt32(count)
                    var values = [Float](repeating: 0, count: count * channels)
                    let status = values.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
                    guard status == noErr else { throw VoxClipError.decodeFailed("Cannot copy audio PCM") }
                    for frame in 0..<count {
                        var mixed = 0.0
                        for channel in 0..<channels {
                            let value = values[frame * channels + channel]
                            mixed += Double(value)
                            window[channel * frameSize + windowCount] = value
                        }
                        planes[0][frame] = Float(mixed / Double(channels))
                        windowCount += 1
                        if windowCount == frameSize {
                            var sum = 0.0
                            for value in window { sum += Double(value) * Double(value) }
                            levels.append(Float((sum / Double(frameSize * channels)).squareRoot()))
                            windowCount = 0
                        }
                    }
                    return input
                }
                try convert(input)
                if lastProgress.duration(to: .now) >= .milliseconds(100) {
                    progress(min(0.99, ready.presentationTimeStamp.seconds / duration)); lastProgress = .now
                }
            }
            try Task.checkCancellation()
            guard reader.status == .completed else { throw VoxClipError.decodeFailed(reader.error?.localizedDescription ?? "Audio decoding did not finish") }
            try convert(nil)
            let samples = Int64((duration * 16000).rounded())
            try wav.finish(expectedFrames: samples)
            var envelopeData = Data()
            levels.withUnsafeBytes { envelopeData.append(contentsOf: $0) }
            try envelopeData.write(to: request.cacheDirectory.appendingPathComponent("envelope-10ms.f32"), options: .atomic)
            if FileManager.default.fileExists(atPath: destination.path) { _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary) }
            else { try FileManager.default.moveItem(at: temporary, to: destination) }
            let remaining = Duration.milliseconds(100) - lastProgress.duration(to: .now)
            if remaining > .zero { try await Task.sleep(for: remaining) }
            progress(1)
            return AudioExtractionResult(audio: ExtractedAudio(wav16k: destination, sampleCount: samples, durationSeconds: Double(samples) / 16000, audioTrackIndex: selected),
                                         envelope: AudioEnvelope(sampleRate: rate, frameSeconds: Double(frameSize) / rate, levels: levels))
        } catch {
            reader.cancelReading()
            try? wav.handle.close()
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }
}

/// The plan is immutable; prepared state belongs exclusively to one tap lifecycle.
public final class FadeContext: @unchecked Sendable {
    public let plan: EditPlan
    private var rate: Double
    private var joins: ContiguousArray<Join>
    private var floatPCM = true
    private let captureCapacity: Int
    private let capturePositions: UnsafeMutablePointer<Int64>?
    private let captureValues: UnsafeMutablePointer<Float>?
    private let capturedCount = Atomic<Int>(0)
    private let capturedRate = Atomic<UInt64>(0)
    var capturedSampleRate: Double { Double(bitPattern: capturedRate.load(ordering: .acquiring)) }
    public convenience init(plan: EditPlan) { self.init(plan: plan, captureCapacity: 0) }
    init(plan: EditPlan, captureCapacity: Int) {
        self.plan = plan; rate = plan.sampleRate; joins = ContiguousArray(plan.joins)
        self.captureCapacity = max(0, captureCapacity)
        capturePositions = captureCapacity > 0 ? .allocate(capacity: captureCapacity) : nil
        captureValues = captureCapacity > 0 ? .allocate(capacity: captureCapacity) : nil
    }
    deinit { capturePositions?.deallocate(); captureValues?.deallocate() }
    public func gain(_ sample: Int64) -> Double { plan.joinGain(at: sample) }

    func capturedSamples() -> [(Int64, Float)] {
        let count = capturedCount.load(ordering: .acquiring)
        guard let capturePositions, let captureValues else { return [] }
        return (0..<count).map { (capturePositions[$0], captureValues[$0]) }
    }

    func prepare(_ format: AudioStreamBasicDescription) {
        rate = format.mSampleRate
        capturedRate.store(rate.bitPattern, ordering: .releasing)
        floatPCM = format.mFormatID == kAudioFormatLinearPCM && format.mFormatFlags & kAudioFormatFlagIsFloat != 0 && format.mBitsPerChannel == 32
        let scale = rate / plan.sampleRate
        joins = ContiguousArray(plan.joins.map { Join(outSample: Int64((Double($0.outSample) * scale).rounded()),
                                                    fadeOutLen: Int64((Double($0.fadeOutLen) * scale).rounded()),
                                                    fadeInLen: Int64((Double($0.fadeInLen) * scale).rounded())) })
    }

    func processingGain(_ sample: Int64) -> Float {
        Self.gain(sample, joins: joins)
    }

    private static func gain<Joins: RandomAccessCollection>(_ sample: Int64, joins: Joins) -> Float where Joins.Element == Join, Joins.Index == Int {
        var lower = 0
        var upper = joins.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if joins[middle].outSample <= sample { lower = middle + 1 } else { upper = middle }
        }
        var gain: Float = 1
        if lower > 0 {
            let join = joins[lower - 1]
            let distance = sample - join.outSample
            if distance >= 0, distance < join.fadeInLen { gain = Float(distance) / Float(join.fadeInLen) }
        }
        if lower < joins.count {
            let join = joins[lower]
            let distance = join.outSample - 1 - sample
            if distance >= 0, distance < join.fadeOutLen { gain = min(gain, Float(distance) / Float(join.fadeOutLen)) }
        }
        return gain
    }

    fileprivate func process(_ buffers: UnsafeMutablePointer<AudioBufferList>, frames: Int, timeRange: CMTimeRange) {
        guard floatPCM, timeRange.start.isNumeric, frames > 0 else { return }
        let first = Int64((timeRange.start.seconds * rate).rounded())
        let durationSamples = timeRange.duration.seconds * rate
        let stride = durationSamples.isFinite && durationSamples > 0 ? durationSamples / Double(frames) : 1
        for (bufferIndex, buffer) in UnsafeMutableAudioBufferListPointer(buffers).enumerated() {
            guard let values = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let channels = Int(buffer.mNumberChannels)
            for frame in 0..<frames {
                let position = first + Int64((Double(frame) * stride).rounded())
                let gain = processingGain(position)
                for channel in 0..<channels { values[frame * channels + channel] *= gain }
                if bufferIndex == 0, let capturePositions, let captureValues {
                    let index = capturedCount.load(ordering: .relaxed)
                    if index < captureCapacity {
                        capturePositions[index] = position
                        captureValues[index] = values[frame * channels]
                        capturedCount.store(index + 1, ordering: .releasing)
                    }
                }
            }
        }
    }
}

public struct FadeTap: Sendable {
    public init() {}
    public func prepare(plan: EditPlan) throws -> FadeContext {
        guard plan.sampleRate.isFinite, plan.sampleRate > 0 else { throw VoxClipError.exportFailed("Invalid audio sample rate") }
        return FadeContext(plan: plan)
    }

    static func make(plan: EditPlan) throws -> MTAudioProcessingTap {
        let context = try FadeTap().prepare(plan: plan)
        return try make(context: context)
    }

    static func make(context: FadeContext) throws -> MTAudioProcessingTap {
        let pointer = Unmanaged.passRetained(context).toOpaque()
        var callbacks = MTAudioProcessingTapCallbacks(version: kMTAudioProcessingTapCallbacksVersion_0, clientInfo: pointer,
            init: { _, info, storage in storage.pointee = info },
            finalize: { tap in Unmanaged<FadeContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release() },
            prepare: { tap, _, format in Unmanaged<FadeContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue().prepare(format.pointee) },
            unprepare: nil,
            process: { tap, frames, _, buffers, framesOut, flagsOut in
                var timeRange = CMTimeRange.zero
                let status = MTAudioProcessingTapGetSourceAudio(tap, frames, buffers, flagsOut, &timeRange, framesOut)
                guard status == noErr else { framesOut.pointee = 0; return }
                Unmanaged<FadeContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                    .process(buffers, frames: Int(framesOut.pointee), timeRange: timeRange)
            })
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
        guard status == noErr, let tap else { Unmanaged<FadeContext>.fromOpaque(pointer).release(); throw VoxClipError.exportFailed("Cannot create audio fade tap (\(status))") }
        return tap
    }
}
