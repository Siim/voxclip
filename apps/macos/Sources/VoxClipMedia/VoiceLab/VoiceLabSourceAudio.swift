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

    /// The source a Rewrite take run reads (voice-lab.md §8.7–8.9) from a track of `frames` frames at its native
    /// `sampleRate`: the whole track's 10 ms envelope (`VoiceLabTakeProcessing.envelope`), which the room-tone search
    /// reads, and only the frames around the window and around the room-tone run that search picks. The envelope pass
    /// decodes the track in 280 s chunks and keeps no samples, so memory stays bounded however long the recording is.
    /// `incomingSilence` and `outgoingSilence` are the window's §8.9.2 outside silences, as the take run's fit reads them
    /// (`VoiceLabWindowPlanner.lendableSilence`).
    public static func rewriteSource(source: URL, frames: Int64, sampleRate: Int, window: VoiceLabWindow,
                                     incomingSilence: Double?, outgoingSilence: Double?,
                                     items: [TimedWord]) async throws -> (excerpt: VoiceLabSourceExcerpt, envelope: AudioEnvelope) {
        guard (8_000...96_000).contains(sampleRate) else { throw VoiceLabSourceAudioError.unsupportedRate }
        guard frames > 0 else { throw VoiceLabSourceAudioError.rangeOutsideMedia }
        var levels = EnvelopeAccumulator(sampleRate: sampleRate)
        try await decodeMono(source: source, range: 0..<frames, sampleRate: sampleRate) { levels.append($0) }
        let envelope = levels.envelope, total = Int(frames)
        var ranges = [nearWindow(window, incomingSilence: incomingSilence, outgoingSilence: outgoingSilence, total: total, rate: sampleRate)]
        // A search that finds no run leaves the refusal to the take run's own preflight, which repeats it.
        if let tone = try? VoiceLabRoomToneSelection.select(items: items, envelope: envelope, sourceSampleRate: Double(sampleRate), totalSamples: frames) {
            ranges.append(aligned(Int(tone.sourceStartSample) - sampleRate, Int(tone.sourceEndSample) + sampleRate, total: total, rate: sampleRate))
        }
        var regions: [VoiceLabSourceExcerpt.Region] = []
        for range in merged(ranges) where !range.isEmpty {
            var samples: [Float] = []
            samples.reserveCapacity(range.count)
            try await decodeMono(source: source, range: Int64(range.lowerBound)..<Int64(range.upperBound), sampleRate: sampleRate) { samples.append(contentsOf: $0) }
            regions.append(.init(start: range.lowerBound, samples: samples))
        }
        return (VoiceLabSourceExcerpt(totalFrames: total, regions: regions), envelope)
    }

    /// The take run resamples the source to the generated audio's rate for staging (§8.9).
    static let takeAssetRate = 24_000

    /// The frames around a window that a take run reads. The silence fit can widen the window into the silence a gap seam
    /// lends (§8.9.2), which has no limit of its own, and staging reads the lead, tail and seam handles around the widened
    /// window. So each side reaches past everything its seam can borrow, up to the 290 s a staged take holds, by 6 s more,
    /// which holds the 3 s loudness neighbourhood, the half-second staging lead and tail and the seam handles with room to
    /// spare for the resampler. The range also holds the 10 s speaker-check span, which starts 5 s before the window's centre.
    static func nearWindow(_ window: VoiceLabWindow, incomingSilence: Double?, outgoingSilence: Double?, total: Int, rate: Int) -> Range<Int> {
        let start = Int(clamping: window.startSample), end = Int(clamping: window.endSample)
        func lendable(_ seam: VoiceLabSeamPlacement, _ silence: Double?) -> Int {
            guard seam.kind == .gap, let silence, silence.isFinite, silence > 0 else { return 0 }
            let seconds: Double = min(silence, VoiceLabTakeProcessing.maximumQASeconds)
            let samples: Double = (seconds * Double(rate)).rounded(.up)
            return Int(samples)
        }
        let before: Int = 6 * rate + lendable(window.leftSeam, incomingSilence)
        let after: Int = 6 * rate + lendable(window.rightSeam, outgoingSilence)
        let speakerStart = max(0, (start + end) / 2 - 5 * rate), speakerEnd = min(total, speakerStart + 10 * rate)
        return aligned(min(start - before, speakerStart), max(end + after, speakerEnd), total: total, rate: rate)
    }

    /// Clamped to the track, with the start moved back to a frame on the 24 kHz grid, so a region resampled on its own
    /// lands on the whole track's 24 kHz frames.
    static func aligned(_ lower: Int, _ upper: Int, total: Int, rate: Int) -> Range<Int> {
        var a = rate, b = takeAssetRate
        while b != 0 { (a, b) = (b, a % b) }
        let step = rate / a
        let start = min(max(0, lower), total) / step * step
        return start..<max(start, min(max(0, upper), total))
    }

    /// Ranges sorted, with overlapping and touching ones joined.
    static func merged(_ ranges: [Range<Int>]) -> [Range<Int>] {
        var result: [Range<Int>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = result.last, range.lowerBound <= last.upperBound {
                result[result.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else { result.append(range) }
        }
        return result
    }

    /// Source frames `range` as mono Float32, decoded in chunks of `decodeChunkFrames` through `conversionInput` and
    /// handed to `body` one chunk at a time. A remainder shorter than 20 ms joins the chunk before it.
    private static func decodeMono(source: URL, range: Range<Int64>, sampleRate: Int, _ body: ([Float]) -> Void) async throws {
        let chunkSamples: Int = decodeChunkFrames(sampleRate: sampleRate)
        let chunkFrames: Int64 = Int64(chunkSamples)
        let trailingSamples: Int = (sampleRate + 49) / 50
        let trailingFrames: Int64 = Int64(trailingSamples)
        let pcmScale: Float = 32_768
        var start = range.lowerBound
        while start < range.upperBound {
            try Task.checkCancellation()
            var end = min(range.upperBound, start + chunkFrames)
            if range.upperBound - end < trailingFrames { end = range.upperBound }
            let wav = try await conversionInput(source: source, startSample: start, endSample: end, sourceSampleRate: Double(sampleRate))
            var chunk: [Float] = []
            chunk.reserveCapacity(max(0, (wav.count - 44) / 2))
            for offset in stride(from: 44, to: wav.count, by: 2) {
                let bits = UInt16(wav[offset]) | UInt16(wav[offset + 1]) << 8
                let signed: Int16 = Int16(bitPattern: bits)
                let sample: Float = Float(signed)
                chunk.append(sample / pcmScale)
            }
            body(chunk)
            start = end
        }
    }

    /// 280 s of frames, or fewer where that much PCM16 would reach the 50,000,000-byte limit `conversionChunk` enforces
    /// (above about 89 kHz), less the 20 ms remainder a chunk can absorb, so every chunk at every supported rate decodes.
    static func decodeChunkFrames(sampleRate: Int) -> Int {
        let largest: Int = (uploadLimit - 1 - 44) / 2
        let trailing: Int = (sampleRate + 49) / 50
        return min(280 * sampleRate, largest - trailing)
    }

    /// `VoiceLabTakeProcessing.envelope` computed chunk by chunk: the same frames, summed in the same order.
    struct EnvelopeAccumulator {
        let sampleRate: Int
        let frame: Int
        private var power = 0.0
        private var filled = 0
        private var levels: [Float] = []
        init(sampleRate: Int) {
            self.sampleRate = sampleRate
            let rate: Double = Double(sampleRate)
            let rounded: Double = EditingPrimitives.jsRound(rate * 0.01)
            frame = max(1, Int(rounded))
        }
        mutating func append(_ samples: [Float]) {
            let size: Double = Double(frame)
            for sample in samples {
                let value: Double = Double(sample)
                power += value * value
                filled += 1
                guard filled == frame else { continue }
                let level: Double = sqrt(power / size)
                levels.append(Float(level))
                power = 0; filled = 0
            }
        }
        var envelope: AudioEnvelope { AudioEnvelope(sampleRate: Double(sampleRate), levels: levels) }
    }

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
        let operation: VoiceLabAssetRecovery.Operation
        do { operation = try VoiceLabAssetRecovery.Operation.create(in: FileManager.default.temporaryDirectory) }
        catch { throw VoiceLabSourceAudioError.unreadable }
        defer { operation.discard() }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(operation.name, isDirectory: true)
        let snapshot = scratch.appendingPathComponent("asset." + url.pathExtension)
        let copyFD = Darwin.openat(operation.descriptor, snapshot.lastPathComponent, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
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

    /// An excerpt resampled region by region. Each region must start on a frame of the target grid, as `rewriteSource`
    /// aligns them. The track's target length is what the last region gives when it reaches the end of the track, as
    /// resampling the whole track gives; otherwise it is the rounded ratio.
    package static func resample(_ excerpt: VoiceLabSourceExcerpt, from rate: Double, to target: Double) throws -> VoiceLabSourceExcerpt {
        if rate == target { return excerpt }
        guard rate.isFinite, target.isFinite, rate.rounded() == rate, target.rounded() == target, rate >= 1, target >= 1 else {
            throw VoiceLabSourceAudioError.unsupportedRate
        }
        let from = Int(rate), to = Int(target)
        var total = Int((Double(excerpt.totalFrames) * target / rate).rounded())
        var regions: [VoiceLabSourceExcerpt.Region] = []
        for region in excerpt.regions {
            guard (region.start * to).isMultiple(of: from) else { throw VoiceLabSourceAudioError.invalidAudio }
            let start = region.start * to / from
            let samples = try resample(region.samples, from: rate, to: target)
            regions.append(.init(start: start, samples: samples))
            if region.end == excerpt.totalFrames { total = start + samples.count }
        }
        return VoiceLabSourceExcerpt(totalFrames: total, regions: regions)
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
