import AVFoundation
import Foundation
import VoxClipCore

/// What social loudness decided for one export (ADR-R47): the composed mix's measurement and the gain, after the
/// offline pre-passes that simulated the limiter and landed the gain on target.
struct ExportLoudnessPlan: Sendable {
    let measurement: SocialLoudnessMeasurement
    let decision: SocialLoudnessDecision
}

/// Social loudness at export (ADR-R47, amended 2026-11-08). The export reads the mix it is about to write with a
/// pre-pass: the same composition, mixed tracks, audio mix and time range read as 48 kHz Float32 stereo, cut to the
/// export's sample count and padded with silence to it, exactly as the audio pump feeds the AAC encoder. The first
/// pass measures it; when the gain would put the true peak over −1 dBTP, one or two more passes run the gain and the
/// limiter offline, with no encode, and measure what they leave, so the gain lands on target. The pump then runs the
/// same gain and limiter (`ExportLoudnessStage`) on its way to the encoder. That is offline and much faster than real
/// time, needs no second encode, and never decodes AAC.
enum ExportLoudnessPass {
    typealias Sample = CMReadySampleBuffer<CMSampleBuffer.DynamicContent>

    /// The silence the pump pads a short mix with, from `frames` to `sampleLimit`, in chunks: it is part of what is
    /// written.
    static func pad(from frames: Int64, to sampleLimit: Int64, _ body: (UnsafeBufferPointer<Float>) throws -> Void) throws {
        let silence = [Float](repeating: 0, count: 2 * 8192)
        var position = frames
        while position < sampleLimit {
            try Task.checkCancellation()
            let count = Int(min(8192, sampleLimit - position))
            try silence.withUnsafeBufferPointer { try body(UnsafeBufferPointer(rebasing: $0[0..<(2 * count)])) }
            position += Int64(count)
        }
    }

    /// The first `frames` interleaved stereo frames of `sample`.
    static func copy(_ sample: Sample, frames: Int, into samples: inout [Float]) throws {
        let bytes = frames * 2 * MemoryLayout<Float>.size
        if samples.count < 2 * frames { samples = [Float](repeating: 0, count: 2 * frames) }
        try sample.withUnsafeSampleBuffer { raw in
            guard let block = CMSampleBufferGetDataBuffer(raw), CMBlockBufferGetDataLength(block) >= bytes else {
                throw VoxClipError.decodeFailed("Missing export PCM")
            }
            let status = samples.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes, destination: $0.baseAddress!) }
            guard status == noErr else { throw VoxClipError.decodeFailed("Cannot copy export PCM") }
        }
    }

    /// An export audio buffer (48 kHz interleaved Float32 stereo) of `values` at frame `start`.
    static func buffer(_ samples: UnsafeBufferPointer<Float>, start: Int64) throws -> Sample {
        // A copy of its own, so the buffer shares no region with the caller's memory.
        let values = Array(samples)
        let frames = values.count / 2
        let bytes = 2 * frames * MemoryLayout<Float>.size
        var block: CMBlockBuffer?
        guard frames > 0, CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes,
                blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: 0,
                blockBufferOut: &block) == noErr, let block,
              values.withUnsafeBytes({ CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes) }) == noErr,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: true) else {
            throw VoxClipError.exportFailed("Cannot allocate export audio")
        }
        let timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48000),
            presentationTimeStamp: CMTime(value: start, timescale: 48000), decodeTimeStamp: .invalid)
        return CMReadySampleBuffer(unsafeBuffer: try CMSampleBuffer(dataBuffer: block, formatDescription: format.formatDescription,
            numSamples: frames, sampleTimings: [timing], sampleSizes: [2 * MemoryLayout<Float>.size]))
    }
}

/// The export's gain and true-peak limiter over interleaved 48 kHz stereo PCM, metering what it writes when it limits;
/// the offline pre-pass and the audio pump run the same stage.
struct ExportLoudnessStage {
    private(set) var limiter: SocialLimiter
    private var meter: SocialLoudnessMeter?
    private var output: [Float] = []

    init(gainDb: Double, limiting: Bool) throws {
        limiter = try SocialLimiter(gainDb: gainDb, limiting: limiting, sampleRate: 48_000, channels: 2)
        meter = limiting ? try SocialLoudnessMeter(sampleRate: 48_000, channels: 2) : nil
    }

    /// Takes whole input frames; hands `body` the output frames now due (none while the lookahead fills).
    mutating func process(_ input: UnsafeBufferPointer<Float>, _ body: (UnsafeBufferPointer<Float>) throws -> Void) throws {
        if output.count < input.count { output = [Float](repeating: 0, count: input.count) }
        var scratch = output
        output = []
        defer { output = scratch }
        let written = scratch.withUnsafeMutableBufferPointer { limiter.process(input, into: $0) }
        try emit(scratch, frames: written, body)
    }

    /// The frames still inside the lookahead.
    mutating func finish(_ body: (UnsafeBufferPointer<Float>) throws -> Void) throws {
        var tail = [Float](repeating: 0, count: 2 * limiter.latency)
        let written = tail.withUnsafeMutableBufferPointer { limiter.finish(into: $0) }
        try emit(tail, frames: written, body)
    }

    /// The written PCM's loudness when the stage limited.
    mutating func measured() -> SocialLoudnessMeasurement? { meter?.finish() }

    private mutating func emit(_ values: [Float], frames: Int, _ body: (UnsafeBufferPointer<Float>) throws -> Void) throws {
        guard frames > 0 else { return }
        try values.withUnsafeBufferPointer { all in
            let slice = UnsafeBufferPointer(rebasing: all[0..<(2 * frames)])
            try meter?.append(slice)
            try body(slice)
        }
    }
}

extension PCMFile {
    /// Runs a finished Float32 WAV through the export's gain and limiter in place: the `--audio-out` sidecar carries
    /// the same gain and the same limiter as the export, run over its own samples (without music, the export's PCM).
    static func applyLoudness(_ decision: SocialLoudnessDecision, toFloatWAV url: URL) throws {
        guard decision.gainDb != 0 || decision.limiting else { return }
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        guard let header = try handle.read(upToCount: 12), header.count == 12,
              header.prefix(4) == Data("RIFF".utf8), header.suffix(4) == Data("WAVE".utf8) else {
            throw VoxClipError.exportFailed("The edited WAV is not RIFF WAVE")
        }
        var offset: UInt64 = 12, isFloat = false, channels = 0
        while true {
            try handle.seek(toOffset: offset)
            guard let chunk = try handle.read(upToCount: 8), chunk.count == 8 else { throw VoxClipError.exportFailed("The edited WAV has no data") }
            let id = String(decoding: chunk.prefix(4), as: UTF8.self)
            let size = UInt64(chunk.suffix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
            if id == "fmt " {
                guard let format = try handle.read(upToCount: 16), format.count == 16 else { throw VoxClipError.exportFailed("The edited WAV has no format") }
                let tag = format.prefix(2).withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }.littleEndian
                channels = Int(format.dropFirst(2).prefix(2).withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }.littleEndian)
                let bits = format.dropFirst(14).prefix(2).withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }.littleEndian
                isFloat = tag == 3 && bits == 32
            } else if id == "data" {
                guard isFloat, (1...8).contains(channels) else { throw VoxClipError.exportFailed("The edited WAV is not Float32") }
                var limiter = try SocialLimiter(gainDb: decision.gainDb, limiting: decision.limiting, sampleRate: 48_000, channels: channels)
                try process(handle, from: offset + 8, bytes: size, limiter: &limiter)
                try handle.synchronize()
                return
            }
            offset += 8 + size + size % 2
        }
    }

    /// Reads ahead of where it writes: output lags input by the limiter's latency, so nothing is overwritten unread.
    private static func process(_ handle: FileHandle, from start: UInt64, bytes: UInt64, limiter: inout SocialLimiter) throws {
        let frameBytes = UInt64(limiter.channels * MemoryLayout<Float>.size)
        let total = bytes - bytes % frameBytes
        let chunk: UInt64 = (1 << 20) - (1 << 20) % frameBytes
        var read: UInt64 = 0, written: UInt64 = 0
        var output = [Float](repeating: 0, count: Int(chunk) / MemoryLayout<Float>.size)
        func write(_ values: [Float], frames: Int) throws {
            guard frames > 0 else { return }
            let count = frames * limiter.channels
            var data = Data(count: count * MemoryLayout<Float>.size)
            data.withUnsafeMutableBytes { raw in
                for index in 0..<count {
                    raw.storeBytes(of: values[index].bitPattern.littleEndian, toByteOffset: index * 4, as: UInt32.self)
                }
            }
            try handle.seek(toOffset: start + written)
            try handle.write(contentsOf: data)
            written += UInt64(data.count)
        }
        while read < total {
            try Task.checkCancellation()
            let length = Int(min(chunk, total - read))
            try handle.seek(toOffset: start + read)
            guard let data = try handle.read(upToCount: length), data.count == length else {
                throw VoxClipError.exportFailed("The edited WAV ended early")
            }
            read += UInt64(length)
            let input = data.withUnsafeBytes { raw in
                (0..<(length / MemoryLayout<Float>.size)).map { index in
                    Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self)))
                }
            }
            let frames = input.withUnsafeBufferPointer { source in
                output.withUnsafeMutableBufferPointer { limiter.process(source, into: $0) }
            }
            try write(output, frames: frames)
        }
        let tail = limiter.finish()
        try write(tail, frames: tail.count / limiter.channels)
    }
}
