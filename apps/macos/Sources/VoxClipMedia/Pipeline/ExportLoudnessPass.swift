import AVFoundation
import Foundation
import VoxClipCore

/// Social loudness at export (ADR-R47). The export measures the mix it is about to write with a pre-pass: the same
/// composition, mixed tracks, audio mix and time range read as 48 kHz Float32 stereo, cut to the export's sample count
/// and padded with silence to it, exactly as the audio pump feeds the AAC encoder. That is offline and much faster
/// than real time, needs no second encode, and the pump then multiplies every buffer by the one static gain.
/// Measuring the written MP4 instead would decode AAC, encode the audio a second time (one more lossy generation)
/// and remux the whole file.
enum ExportLoudnessPass {
    typealias Sample = CMReadySampleBuffer<CMSampleBuffer.DynamicContent>

    /// Adds the first `frames` frames of an export audio buffer (48 kHz interleaved Float32 stereo) to `meter`.
    static func append(_ sample: Sample, frames: Int, to meter: inout SocialLoudnessMeter, scratch: inout [Float]) throws {
        try copy(sample, frames: frames, into: &scratch)
        try scratch.withUnsafeBufferPointer { try meter.append(UnsafeBufferPointer(rebasing: $0[0..<(2 * frames)])) }
    }

    /// Adds the silence the pump pads a short mix with, from `frames` to `sampleLimit`: it is part of what is written.
    static func pad(_ meter: inout SocialLoudnessMeter, from frames: Int64, to sampleLimit: Int64) throws {
        let silence = [Float](repeating: 0, count: 2 * 8192)
        var position = frames
        while position < sampleLimit {
            try Task.checkCancellation()
            let count = Int(min(8192, sampleLimit - position))
            try silence.withUnsafeBufferPointer { try meter.append(UnsafeBufferPointer(rebasing: $0[0..<(2 * count)])) }
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

    /// A copy of an export audio buffer (48 kHz interleaved Float32 stereo) with every sample multiplied by `gain`, at
    /// the same presentation time.
    static func scaled(_ sample: Sample, gain: Float) throws -> Sample {
        let frames = sample.sampleCount
        var values: [Float] = []
        try copy(sample, frames: frames, into: &values)
        let (start, timescale) = sample.withUnsafeSampleBuffer { raw in
            let time = CMSampleBufferGetPresentationTimeStamp(raw)
            return (time.value, time.timescale)
        }
        let count = 2 * frames, bytes = count * MemoryLayout<Float>.size
        for index in 0..<count { values[index] *= gain }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes,
                blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: 0,
                blockBufferOut: &block) == noErr, let block,
              values.withUnsafeBytes({ CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes) }) == noErr,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: true) else {
            throw VoxClipError.exportFailed("Cannot allocate export audio")
        }
        let timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48000),
            presentationTimeStamp: CMTime(value: start, timescale: timescale), decodeTimeStamp: .invalid)
        return CMReadySampleBuffer(unsafeBuffer: try CMSampleBuffer(dataBuffer: block, formatDescription: format.formatDescription,
            numSamples: frames, sampleTimings: [timing], sampleSizes: [2 * MemoryLayout<Float>.size]))
    }
}

extension PCMFile {
    /// Multiplies every sample of a finished Float32 WAV in place: the `--audio-out` sidecar carries the export's gain.
    static func applyGain(_ gain: Float, toFloatWAV url: URL) throws {
        guard gain != 1 else { return }
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        guard let header = try handle.read(upToCount: 12), header.count == 12,
              header.prefix(4) == Data("RIFF".utf8), header.suffix(4) == Data("WAVE".utf8) else {
            throw VoxClipError.exportFailed("The edited WAV is not RIFF WAVE")
        }
        var offset: UInt64 = 12, isFloat = false
        while true {
            try handle.seek(toOffset: offset)
            guard let chunk = try handle.read(upToCount: 8), chunk.count == 8 else { throw VoxClipError.exportFailed("The edited WAV has no data") }
            let id = String(decoding: chunk.prefix(4), as: UTF8.self)
            let size = UInt64(chunk.suffix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
            if id == "fmt " {
                guard let format = try handle.read(upToCount: 16), format.count == 16 else { throw VoxClipError.exportFailed("The edited WAV has no format") }
                let tag = format.prefix(2).withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }.littleEndian
                let bits = format.dropFirst(14).prefix(2).withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }.littleEndian
                isFloat = tag == 3 && bits == 32
            } else if id == "data" {
                guard isFloat else { throw VoxClipError.exportFailed("The edited WAV is not Float32") }
                try scale(handle, from: offset + 8, bytes: size, gain: gain)
                try handle.synchronize()
                return
            }
            offset += 8 + size + size % 2
        }
    }

    private static func scale(_ handle: FileHandle, from start: UInt64, bytes: UInt64, gain: Float) throws {
        let chunk: UInt64 = 1 << 20
        var position: UInt64 = 0
        while position < bytes {
            try Task.checkCancellation()
            let length = Int(min(chunk, bytes - position))
            try handle.seek(toOffset: start + position)
            guard var data = try handle.read(upToCount: length), data.count == length else {
                throw VoxClipError.exportFailed("The edited WAV ended early")
            }
            data.withUnsafeMutableBytes { raw in
                let count = raw.count / MemoryLayout<Float>.size
                for index in 0..<count {
                    let pointer = raw.baseAddress! + index * MemoryLayout<Float>.size
                    let value = Float(bitPattern: UInt32(littleEndian: pointer.loadUnaligned(as: UInt32.self))) * gain
                    pointer.storeBytes(of: value.bitPattern.littleEndian, as: UInt32.self)
                }
            }
            try handle.seek(toOffset: start + position)
            try handle.write(contentsOf: data)
            position += UInt64(length)
        }
    }
}
