import AVFoundation
import CryptoKit
import Darwin
import Foundation
import VoxClipCore

/// Errors from Voice Lab source extraction and stored-asset decoding. No case substitutes other audio.
public enum VoiceLabSourceAudioError: Error, LocalizedError, Sendable, Equatable {
    case unsupportedRate, rateMismatch, rangeOutsideMedia, tooShort, tooLong, tooLarge
    case noAudioTrack, unreadable, unsupportedFormat, invalidAudio
    /// A decoded asset's bytes differ from its expected SHA-256, or changed while they were copied.
    case altered

    public var errorDescription: String? {
        switch self {
        case .unsupportedRate: "This audio's sample rate is outside the range Voice Lab supports."
        case .rateMismatch: "The source audio's sample rate differs from the project. Reopen the original source."
        case .rangeOutsideMedia: "The selected range is not inside the source audio."
        case .tooShort: "Select at least 20 ms of audio to convert."
        case .tooLong: "A voice changer request holds at most 290 seconds of audio."
        case .tooLarge: "This audio exceeds the size Voice Lab can upload or decode."
        case .noAudioTrack: "The source has no audio track."
        case .unreadable: "The audio cannot be read. Check that the file is still available."
        case .unsupportedFormat: "This build cannot decode this audio format."
        case .invalidAudio: "The audio contains samples Voice Lab cannot use."
        case .altered: "The generated Voice Lab audio has changed. Restore the original paid file."
        }
    }
}

/// Source audio for the voice changer (voice-lab.md §7.2–7.3), and stored paid audio at the source rate for the
/// conform, loudness and QA steps (§4.4). Conform and loudness themselves are Core functions.
public enum VoiceLabSourceAudio {
    /// ElevenLabs takes a voice-changer upload smaller than 50 MB (§7.2).
    static let uploadLimit = 50_000_000
    /// The voice changer converts at most 290 s per request (§7.2).
    static let maximumSeconds = 290

    /// The complete mono PCM16 WAV of source frames `[startSample, endSample)` that §7.3 uploads, at the source rate
    /// with no resampling. The track the renderer uses is decoded as Float32 at its native rate, which must equal
    /// `sourceSampleRate`, then downmixed by the arithmetic mean of its channels and written with the paid-asset
    /// writer's float rule and header. Rate and length limits are refused before the source is opened.
    public static func conversionInput(source: URL, startSample: Int64, endSample: Int64,
                                       sourceSampleRate: Double) async throws -> Data {
        let (rate, frames) = try conversionChunk(startSample: startSample, endSample: endSample,
                                                 sourceSampleRate: sourceSampleRate)
        do {
            let asset = AVURLAsset(url: source)
            guard let track = try await MediaSupport.audioTrack(in: asset) else { throw VoiceLabSourceAudioError.noAudioTrack }
            guard let format = try await track.load(.formatDescriptions).first,
                  let native = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
                  native.mChannelsPerFrame > 0 else { throw VoiceLabSourceAudioError.unsupportedFormat }
            guard native.mSampleRate == Double(rate) else { throw VoiceLabSourceAudioError.rateMismatch }
            // The reader reads no further than the asset duration; samples missing before it fail the coverage check.
            let duration = try await asset.load(.duration)
            guard duration.isNumeric, CMTime(value: endSample, timescale: CMTimeScale(rate)) <= duration else {
                throw VoiceLabSourceAudioError.rangeOutsideMedia
            }
            return try await decode(asset: asset, track: track, rate: rate, channels: Int(native.mChannelsPerFrame),
                                    startSample: startSample, endSample: endSample, frames: frames)
        } catch {
            if error is VoiceLabSourceAudioError || error is CancellationError { throw error }
            throw VoiceLabSourceAudioError.unreadable
        }
    }

    /// Checks a chunk before the source is opened and returns its whole rate and frame count. Core's conversion-input
    /// contract takes 8–96 kHz and from ceil(rate / 50) frames (20 ms) to 290 s. The WAV must also stay under the
    /// 50,000,000-byte upload limit, so a chunk holds at most §7.2 `maxFrames` = min(290 × rate,
    /// floor((50,000,000 − 1 − 44) / 2)) frames.
    static func conversionChunk(startSample: Int64, endSample: Int64,
                                sourceSampleRate: Double) throws -> (rate: Int, frames: Int) {
        guard sourceSampleRate.isFinite, sourceSampleRate.rounded() == sourceSampleRate,
              sourceSampleRate >= 8_000, sourceSampleRate <= 96_000 else { throw VoiceLabSourceAudioError.unsupportedRate }
        let rate = Int(sourceSampleRate)
        guard startSample >= 0, endSample > startSample else { throw VoiceLabSourceAudioError.rangeOutsideMedia }
        let frames = endSample - startSample
        guard frames >= Int64((rate + 49) / 50) else { throw VoiceLabSourceAudioError.tooShort }
        guard frames <= Int64(maximumSeconds * rate) else { throw VoiceLabSourceAudioError.tooLong }
        guard 44 + 2 * frames < Int64(uploadLimit) else { throw VoiceLabSourceAudioError.tooLarge }
        return (rate, Int(frames))
    }

    /// A stored paid WAV (or FLAC) as mono Float32 at `targetSampleRate`, the source rate: decoded, downmixed by the
    /// mean of its channels and resampled by AVAudioConverter at mastering quality, primed so sample 0 stays aligned.
    /// An asset already at that rate is returned as decoded. The §10.4 limits apply; the result is held in memory.
    ///
    /// As in `VoiceLabAssets.prepare`, only the bytes that were checked are decoded. The path is opened once, without
    /// blocking and without following a link at its last component, and a nonregular file is `unreadable`. That
    /// descriptor is copied into a private 0600 snapshot while it is hashed, AVAudioFile decodes the snapshot, and the
    /// snapshot is removed before returning. Earlier path components are followed, so pass `expectedSha256` to tie
    /// the bytes to the asset record; any other hash is `altered`.
    public static func decodeAsset(url: URL, targetSampleRate: Double, expectedSha256: String? = nil) throws -> [Float] {
        try decodeAsset(url: url, targetSampleRate: targetSampleRate, expectedSha256: expectedSha256, afterCheck: nil)
    }

    /// `afterCheck` runs once the path's descriptor is checked and the empty snapshot exists, so tests can swap the path.
    static func decodeAsset(url: URL, targetSampleRate: Double, expectedSha256: String?,
                            afterCheck: ((_ snapshot: URL) -> Void)?) throws -> [Float] {
        guard targetSampleRate.isFinite, targetSampleRate.rounded() == targetSampleRate,
              targetSampleRate >= 8_000, targetSampleRate <= 192_000 else { throw VoiceLabSourceAudioError.unsupportedRate }
        guard url.pathExtension == "wav" || url.pathExtension == "flac" else { throw VoiceLabSourceAudioError.unsupportedFormat }
        let fd = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw VoiceLabSourceAudioError.unreadable }
        let source = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG), info.st_size > 0 else {
            throw VoiceLabSourceAudioError.unreadable
        }
        guard Int64(info.st_size) <= VoiceLabAssets.maxBytes else { throw VoiceLabSourceAudioError.tooLarge }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-voice-decode-\(UUID().uuidString)",
                                                                                    isDirectory: true)
        guard Darwin.mkdir(scratch.path, 0o700) == 0 else { throw VoiceLabSourceAudioError.unreadable }
        defer { try? FileManager.default.removeItem(at: scratch) }
        let snapshot = scratch.appendingPathComponent("asset." + url.pathExtension)
        let copyFD = Darwin.open(snapshot.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard copyFD >= 0 else { throw VoiceLabSourceAudioError.unreadable }
        let copy = FileHandle(fileDescriptor: copyFD, closeOnDealloc: true)
        afterCheck?(snapshot)
        do {
            var hash = SHA256()
            var copied: Int64 = 0
            while true {
                try Task.checkCancellation()
                let bytes = try source.read(upToCount: 1024 * 1024) ?? Data()
                if bytes.isEmpty { break }
                copied += Int64(bytes.count)
                guard copied <= Int64(info.st_size) else { throw VoiceLabSourceAudioError.altered }
                hash.update(data: bytes)
                try copy.write(contentsOf: bytes)
            }
            try copy.close()
            guard copied == Int64(info.st_size) else { throw VoiceLabSourceAudioError.altered }
            if let expectedSha256, hash.finalize().map({ String(format: "%02x", $0) }).joined() != expectedSha256 {
                throw VoiceLabSourceAudioError.altered
            }
        } catch {
            if error is VoiceLabSourceAudioError || error is CancellationError { throw error }
            throw VoiceLabSourceAudioError.unreadable
        }
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: snapshot, commonFormat: .pcmFormatFloat32, interleaved: false) }
        catch { throw VoiceLabSourceAudioError.unsupportedFormat }
        let rate = file.processingFormat.sampleRate, channels = Int(file.processingFormat.channelCount)
        guard rate.isFinite, rate.rounded() == rate, rate >= 8_000, rate <= 192_000 else { throw VoiceLabSourceAudioError.unsupportedRate }
        guard channels >= 1, channels <= 8 else { throw VoiceLabSourceAudioError.unsupportedFormat }
        guard file.length > 0 else { throw VoiceLabSourceAudioError.invalidAudio }
        guard file.length <= VoiceLabAssets.maxFrames else { throw VoiceLabSourceAudioError.tooLarge }
        let mono = try downmix(file, channels: channels)
        return rate == targetSampleRate ? mono : try resample(mono, from: rate, to: targetSampleRate)
    }

    /// The 10 ms RMS envelope that Core's conform step reads (§4.4 step 3): frames of round_half_up(rate × 0.01)
    /// samples from sample 0, the partial final frame omitted, each RMS computed in Float64 and stored as Float32, with
    /// `frameSeconds` 0.01, as Windows `AudioEnvelopeBuilder` records it.
    public static func envelope(samples: [Float], sampleRate: Int) -> AudioEnvelope {
        let frame = max(1, Int(EditingPrimitives.jsRound(Double(sampleRate) * 0.01)))
        var levels: [Float] = []
        levels.reserveCapacity(samples.count / frame)
        samples.withUnsafeBufferPointer { values in
            var start = 0
            while values.count - start >= frame {
                var sum = 0.0
                for index in start..<(start + frame) {
                    let value = Double(values[index])
                    sum += value * value
                }
                levels.append(Float((sum / Double(frame)).squareRoot()))
                start += frame
            }
        }
        return AudioEnvelope(sampleRate: Double(sampleRate), levels: levels)
    }

    private static func downmix(_ file: AVAudioFile, channels: Int) throws -> [Float] {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 65_536) else {
            throw VoiceLabSourceAudioError.unreadable
        }
        var mono: [Float] = []
        // A declared length is not trusted for allocation: a short file may claim far more frames than it holds.
        mono.reserveCapacity(Int(min(file.length, 1 << 24)))
        while Int64(mono.count) < file.length {
            try Task.checkCancellation()
            let requested = AVAudioFrameCount(min(Int64(buffer.frameCapacity), file.length - Int64(mono.count)))
            do { try file.read(into: buffer, frameCount: requested) } catch { throw VoiceLabSourceAudioError.unreadable }
            guard buffer.frameLength > 0 else { break }
            guard let planes = buffer.floatChannelData else { throw VoiceLabSourceAudioError.unreadable }
            for index in 0..<Int(buffer.frameLength) {
                var sum = 0.0
                for channel in 0..<channels { sum += Double(planes[channel][index]) }
                let value = Float(sum / Double(channels))
                guard value.isFinite else { throw VoiceLabSourceAudioError.invalidAudio }
                mono.append(value)
            }
        }
        // As in VoiceLabAssets.prepare, the decoded count may differ from the declared length by one native sample.
        guard abs(Int64(mono.count) - file.length) <= 1 else { throw VoiceLabSourceAudioError.unreadable }
        return mono
    }

    package static func resample(_ samples: [Float], from rate: Double, to target: Double) throws -> [Float] {
        if rate == target { return samples }
        guard let input = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: target, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: input, to: output),
              let converted = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: 16_384) else {
            throw VoiceLabSourceAudioError.unsupportedFormat
        }
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        converter.primeMethod = .normal
        var result: [Float] = []
        result.reserveCapacity(Int((Double(samples.count) * target / rate).rounded(.up)) + 1)
        let feed = VoiceLabResampleInput(samples: samples, format: input)
        var idle = 0
        while true {
            try Task.checkCancellation()
            var error: NSError?
            let status = converter.convert(to: converted, error: &error) { packets, inputStatus in
                feed.next(packets: packets, status: inputStatus)
            }
            if feed.failed || error != nil || status == .error { throw VoiceLabSourceAudioError.unreadable }
            if converted.frameLength > 0, let plane = converted.floatChannelData?[0] {
                result.append(contentsOf: UnsafeBufferPointer(start: plane, count: Int(converted.frameLength)))
            }
            if status == .endOfStream { break }
            idle = converted.frameLength == 0 ? idle + 1 : 0
            if idle > 3 { throw VoiceLabSourceAudioError.unreadable }
        }
        return result
    }

    private static func decode(asset: AVURLAsset, track: AVAssetTrack, rate: Int, channels: Int,
                               startSample: Int64, endSample: Int64, frames: Int) async throws -> Data {
        let reader = try AVAssetReader(asset: asset)
        let scale = CMTimeScale(rate)
        reader.timeRange = CMTimeRange(start: CMTime(value: startSample, timescale: scale),
                                       end: CMTime(value: endSample, timescale: scale))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: MediaSupport.pcm(rate: Double(rate), channels: channels))
        output.alwaysCopiesSampleData = false
        let provider = reader.outputProvider(for: output)
        guard reader.startReading() else { throw VoiceLabSourceAudioError.unreadable }
        var accumulator = ConversionAccumulator(rate: rate, channels: channels, startSample: startSample,
                                              endSample: endSample, frames: frames, origin: 0.0)
        do {
            while !accumulator.isComplete, let sample = try await MediaSupport.nextSample(provider) {
                try Task.checkCancellation()
                try accumulator.append(sample)
            }
            guard accumulator.isComplete else {
                throw reader.status == .failed ? VoiceLabSourceAudioError.unreadable : VoiceLabSourceAudioError.rangeOutsideMedia
            }
        } catch {
            reader.cancelReading()
            throw error
        }
        if reader.status == .reading { reader.cancelReading() }
        return accumulator.wav
    }

    struct ConversionAccumulator {
        private let rate: Int
        private let channels: Int
        private let startSample: Int64
        private let endSample: Int64
        private let origin: Double
        private var previousEnd: Int64?
        private var values: [Float] = []
        private(set) var next: Int64
        private(set) var wav: Data
        var isComplete: Bool { next == endSample }

        init(rate: Int, channels: Int, startSample: Int64, endSample: Int64, frames: Int, origin: Double = 0.0) {
            self.rate = rate
            self.channels = channels
            self.startSample = startSample
            self.endSample = endSample
            self.origin = origin
            next = startSample
            wav = VoiceLabAssetStore.wavHeader(frames: frames, sampleRate: rate)
            wav.append(Data(count: 2 * frames))
        }

        mutating func append(_ sample: CMReadySampleBuffer<CMSampleBuffer.DynamicContent>) throws {
            guard !isComplete else { return }
            let count: Int = Int(sample.sampleCount)
            guard count > 0 else { return }
            let first = try VoiceLabSourceAudio.bufferFirstSample(presentationTime: sample.presentationTimeStamp,
                                                                 rate: rate, previousEnd: previousEnd, origin: origin)
            let decodedEnd: Int64 = first + Int64(count)
            previousEnd = decodedEnd
            guard first <= next else { throw VoiceLabSourceAudioError.rangeOutsideMedia }
            guard decodedEnd > next else { return }
            let overlap: Int64 = next - first
            let remaining: Int64 = endSample - next
            let skip: Int = Int(overlap)
            let take: Int = min(count - skip, Int(remaining))
            let rate: Int = self.rate
            let channels: Int = self.channels
            let bytes: Int = count * channels * MemoryLayout<Float>.size
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
                let status: OSStatus = values.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) -> OSStatus in
                    CMBlockBufferCopyDataBytes(data, atOffset: 0, dataLength: bytes, destination: buffer.baseAddress!)
                }
                guard status == noErr else { throw VoiceLabSourceAudioError.unreadable }
            }
            let written: Int64 = next - startSample
            let writtenFrames: Int = Int(written)
            let offset: Int = 44 + 2 * writtenFrames
            let channelCount: Double = Double(channels)
            try wav.withUnsafeMutableBytes { [values, channels] (pcm: UnsafeMutableRawBufferPointer) in
                for index in 0..<take {
                    var sum: Double = 0.0
                    for channel in 0..<channels { sum += Double(values[(skip + index) * channels + channel]) }
                    let mean: Double = sum / channelCount
                    let mono: Float = Float(mean)
                    guard mono.isFinite else { throw VoiceLabSourceAudioError.invalidAudio }
                    pcm.storeBytes(of: VoiceLabAssetStore.pcm16(mono).littleEndian, toByteOffset: offset + 2 * index, as: Int16.self)
                }
            }
            next += Int64(take)
        }
    }

    static func bufferFirstSample(presentationTime: CMTime, rate: Int, previousEnd: Int64?, origin: Double = 0.0) throws -> Int64 {
        guard presentationTime.isValid else {
            if let previousEnd { return previousEnd }
            throw VoiceLabSourceAudioError.unreadable
        }
        guard presentationTime.isNumeric, presentationTime.timescale > 0 else { throw VoiceLabSourceAudioError.unreadable }
        let scale: Double = Double(presentationTime.timescale)
        let timeBase: Double = 1.0 / scale
        let seconds: Double = Double(presentationTime.value) * timeBase
        let relativeSeconds: Double = seconds - origin
        let sampleRate: Double = Double(rate)
        let position: Double = relativeSeconds * sampleRate
        guard position.isFinite, position >= -0x1p62, position < 0x1p62 else { throw VoiceLabSourceAudioError.unreadable }
        let tickNumerator: Double = sampleRate * 1.0
        let tickSamples: Double = tickNumerator / scale
        let tolerance: Double = max(1.0, tickSamples)
        if let previousEnd {
            let previousPosition: Double = Double(previousEnd)
            let difference: Double = position - previousPosition
            let distance: Double = abs(difference)
            if distance < tolerance { return previousEnd }
        }
        let halfUpPosition: Double = position + 0.5
        let roundedPosition: Double = floor(halfUpPosition)
        return Int64(roundedPosition)
    }
}

/// Feeds `resample` from the converter's input block, which some SDKs mark `@Sendable`.
private final class VoiceLabResampleInput: @unchecked Sendable {
    private let lock = NSLock()
    private let samples: [Float]
    private let format: AVAudioFormat
    private var offset = 0
    private var failure = false
    init(samples: [Float], format: AVAudioFormat) { self.samples = samples; self.format = format }
    var failed: Bool { lock.lock(); defer { lock.unlock() }; return failure }
    func next(packets: AVAudioPacketCount, status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        lock.lock(); defer { lock.unlock() }
        guard offset < samples.count else { status.pointee = .endOfStream; return nil }
        let count = min(Int(packets), samples.count - offset)
        guard count > 0, let block = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
              let plane = block.floatChannelData?[0] else {
            failure = true; status.pointee = .endOfStream; return nil
        }
        samples.withUnsafeBufferPointer { plane.update(from: $0.baseAddress! + offset, count: count) }
        block.frameLength = AVAudioFrameCount(count)
        offset += count
        status.pointee = .haveData
        return block
    }
}
