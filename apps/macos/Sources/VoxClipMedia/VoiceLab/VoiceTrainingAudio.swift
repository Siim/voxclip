import AVFoundation
import Foundation
import VoxClipCore

/// A source take's §6.5.1 frame levels.
public struct VoiceTrainingLevels: Sendable, Equatable {
    public let sampleRate: Int
    public let frameDb: [Double]
    /// The take's duration floored to whole milliseconds, so every span the selection returns can be cut from it.
    public let duration: Double
    public init(sampleRate: Int, frameDb: [Double], duration: Double) { self.sampleRate = sampleRate; self.frameDb = frameDb; self.duration = duration }
}

/// §6.5.1 frame levels of a mono stream: frame `i` covers samples `floor(i × rate / 100)` up to `floor((i + 1) × rate / 100)`,
/// a take of `n` samples has `floor(n × 100 / rate)` frames, and each level is `20 × log10(max(rms, 1e-9))` in binary64.
struct VoiceTrainingMeter {
    let rate: Int64
    private(set) var samples: Int64 = 0
    private var frame: Int64 = 0
    private var end: Int64
    private var sum = 0.0
    private var levels: [Double] = []
    init(rate: Int) { self.rate = Int64(rate); end = Int64(rate) / 100 }
    mutating func add(_ value: Float) {
        let sample = Double(value)
        sum += sample * sample; samples += 1
        guard samples == end else { return }
        let start = frame * rate / 100
        levels.append(20 * log10(max((sum / Double(end - start)).squareRoot(), 1e-9)))
        frame += 1; end = (frame + 1) * rate / 100; sum = 0
    }
    var frameDb: [Double] { Array(levels.prefix(Int(samples * 100 / rate))) }
}

public enum VoiceTrainingAudio {
    /// The §6.5.1 levels of the source's first (enabled) audio track, the one the renderer reads, mixed to mono by the
    /// mean of its channels at the source rate. The take is decoded once and streamed, never held in memory. A rate
    /// outside 8–96 kHz is `unsupportedRate`; missing media or a decode failure is `unreadable`.
    public static func levels(source: URL) async throws -> VoiceTrainingLevels {
        do {
            let asset = AVURLAsset(url: source)
            guard let track = try await MediaSupport.audioTrack(in: asset) else { throw VoiceLabSourceAudioError.noAudioTrack }
            guard let format = try await track.load(.formatDescriptions).first,
                  let native = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
                  native.mChannelsPerFrame > 0 else { throw VoiceLabSourceAudioError.unsupportedFormat }
            guard native.mSampleRate.isFinite, native.mSampleRate.rounded() == native.mSampleRate,
                  (8_000...96_000).contains(native.mSampleRate) else { throw VoiceLabSourceAudioError.unsupportedRate }
            let rate = Int(native.mSampleRate), channels = Int(native.mChannelsPerFrame)
            let length = try await asset.load(.duration)
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: MediaSupport.pcm(rate: Double(rate), channels: channels))
            output.alwaysCopiesSampleData = false
            let provider = reader.outputProvider(for: output)
            guard reader.startReading() else { throw VoiceLabSourceAudioError.unreadable }
            var meter = VoiceTrainingMeter(rate: rate)
            var values: [Float] = []
            do {
                while let sample = try await MediaSupport.nextSample(provider) {
                    try Task.checkCancellation()
                    let count = Int(sample.sampleCount)
                    guard count > 0 else { continue }
                    let bytes = count * channels * MemoryLayout<Float>.size
                    if values.count < count * channels { values = [Float](repeating: 0, count: count * channels) }
                    try sample.withUnsafeSampleBuffer { (raw: CMSampleBuffer) in
                        guard let description = CMSampleBufferGetFormatDescription(raw),
                              let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
                              basic.mFormatID == kAudioFormatLinearPCM, basic.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                              basic.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0, basic.mBitsPerChannel == 32,
                              basic.mSampleRate == Double(rate), Int(basic.mChannelsPerFrame) == channels,
                              let data = CMSampleBufferGetDataBuffer(raw), CMBlockBufferGetDataLength(data) == bytes else {
                            throw VoiceLabSourceAudioError.unsupportedFormat
                        }
                        let status = values.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(data, atOffset: 0, dataLength: bytes, destination: $0.baseAddress!) }
                        guard status == noErr else { throw VoiceLabSourceAudioError.unreadable }
                    }
                    for index in 0..<count {
                        var sum = 0.0
                        for channel in 0..<channels { sum += Double(values[index * channels + channel]) }
                        let mono = Float(sum / Double(channels))
                        guard mono.isFinite else { throw VoiceLabSourceAudioError.invalidAudio }
                        meter.add(mono)
                    }
                }
            } catch {
                reader.cancelReading()
                throw error
            }
            guard reader.status == .completed, meter.samples > 0 else { throw VoiceLabSourceAudioError.unreadable }
            var milliseconds = meter.samples * 1_000 / Int64(rate)
            if length.isNumeric, length.timescale > 0 {
                milliseconds = min(milliseconds, CMTimeConvertScale(length, timescale: 1_000, method: .roundTowardNegativeInfinity).value)
            }
            return VoiceTrainingLevels(sampleRate: rate, frameDb: meter.frameDb, duration: Double(milliseconds) / 1_000)
        } catch {
            if error is VoiceLabSourceAudioError || error is CancellationError { throw error }
            throw VoiceLabSourceAudioError.unreadable
        }
    }
    /// The §6.5.1 cut of each selected span, in the caller's (source) order: mono samples `floor((startMs × rate + 500) / 1000)`
    /// up to `floor((endMs × rate + 500) / 1000)` from the same mix as `levels`, normalised by `wav`. Each sample is
    /// a "project" sample that keeps the selection's SNR and lasts its sample count over the rate.
    public static func projectSamples(source: URL, sampleRate: Int, spans: [VoiceTrainingSpan]) async throws -> [VoiceTrainingSample] {
        var result: [VoiceTrainingSample] = []
        for span in spans {
            try Task.checkCancellation()
            guard span.startMs >= 0, span.endMs > span.startMs else { throw VoiceLabSourceAudioError.rangeOutsideMedia }
            let rate = Int64(sampleRate)
            let first = (Int64(span.startMs) * rate + 500) / 1_000, last = (Int64(span.endMs) * rate + 500) / 1_000
            let pcm = try await VoiceLabSourceAudio.conversionInput(source: source, startSample: first, endSample: last, sourceSampleRate: Double(sampleRate))
            let samples = stride(from: 44, to: pcm.count - 1, by: 2).map { offset in
                Float(Int16(bitPattern: UInt16(pcm[offset]) | UInt16(pcm[offset + 1]) << 8)) / 32_768
            }
            result.append(.init(wav: try wav(samples, rate: sampleRate), speech16k: [], seconds: Double(samples.count) / Double(sampleRate),
                                source: "project", snrDb: span.snrDb))
        }
        return result
    }
    public static func wav(_ samples: [Float], rate: Int = 48_000) throws -> Data {
        guard (8_000...96_000).contains(rate), !samples.isEmpty, samples.count <= rate * 120, samples.allSatisfy(\.isFinite),
              let level = try VoiceLabLoudness.voicedRmsDb(samples, sampleRate: rate) else { throw VoiceLabError.invalidAudio }
        let peak = try VoiceLabLoudness.truePeakDbtp(samples, sampleRate: rate)
        let gainDb = min(-20 - level, -3 - peak)
        let gain = pow(10.0, gainDb / 20.0)
        var data = Data("RIFF".utf8)
        func little(_ value: Int, width: Int) { for shift in 0..<width { data.append(UInt8(truncatingIfNeeded: value >> (shift * 8))) } }
        little(36 + samples.count * 2, width: 4); data.append(Data("WAVEfmt ".utf8)); little(16, width: 4)
        little(1, width: 2); little(1, width: 2); little(rate, width: 4); little(rate * 2, width: 4); little(2, width: 2); little(16, width: 2)
        data.append(Data("data".utf8)); little(samples.count * 2, width: 4)
        for sample in samples { little(Int((min(1, max(-1, Double(sample) * gain)) * 32_767).rounded()), width: 2) }
        return data
    }
    public static func speech16k(_ samples48k: [Float]) -> [Float] {
        guard samples48k.count >= 3 else { return [] }
        return stride(from: 0, through: samples48k.count - 3, by: 3).map { index in
            (samples48k[index] + samples48k[index + 1] + samples48k[index + 2]) / 3
        }
    }
    public static func training(_ samples: [Float]) throws -> [VoiceTrainingSample] {
        let rate = 48_000
        guard (60 * rate...120 * rate).contains(samples.count), samples.allSatisfy(\.isFinite) else { throw VoiceLabError.invalidAudio }
        var result: [VoiceTrainingSample] = []
        var start = 0
        while start < samples.count {
            let remaining = samples.count - start
            var length = min(15 * rate, remaining)
            if remaining > 18 * rate {
                var best = Double.infinity
                let lastCandidate = min(18 * rate, remaining - 480)
                for offset in stride(from: 12 * rate, through: lastCandidate, by: 480) {
                    let energy = samples[(start + offset)..<(start + offset + 480)].reduce(0.0) { $0 + Double($1) * Double($1) }
                    if energy < best { best = energy; length = offset }
                }
            } else { length = remaining }
            if samples.count - start - length < 5 * rate { length = remaining }
            let chunk = Array(samples[start..<(start + length)])
            let wav = try wav(chunk)
            let snr = try snrDb(chunk, rate: rate)
            result.append(.init(wav: wav, speech16k: speech16k(chunk), seconds: Double(length) / Double(rate), source: "readAloud", snrDb: snr))
            start += length
        }
        return result
    }
    public static func snrDb(_ samples: [Float], rate: Int) throws -> Double {
        let frame = rate / 100
        guard frame > 0, samples.count >= frame else { throw VoiceLabError.invalidAudio }
        var levels: [Double] = []
        for start in stride(from: 0, through: samples.count - frame, by: frame) {
            let power = samples[start..<(start + frame)].reduce(0.0) { $0 + Double($1) * Double($1) }
            levels.append(sqrt(power / Double(frame)))
        }
        levels.sort()
        let speech = levels.filter { $0 > pow(10, -45.0 / 20.0) }
        guard !speech.isEmpty else { throw VoiceLabError.invalidAudio }
        return 20 * log10(max(speech[speech.count / 2], 1e-9) / max(levels[levels.count / 10], 1e-9))
    }
}
