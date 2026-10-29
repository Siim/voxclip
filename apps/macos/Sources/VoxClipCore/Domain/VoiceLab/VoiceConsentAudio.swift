import Foundation

public enum VoiceConsentAudio {
    private static func wavLE16(_ bytes: UnsafeRawBufferPointer, _ at: Int) -> Int {
        Int(bytes[at]) | Int(bytes[at + 1]) << 8
    }
    private static func wavLE32(_ bytes: UnsafeRawBufferPointer, _ at: Int) -> Int {
        Int(bytes[at]) | Int(bytes[at + 1]) << 8 | Int(bytes[at + 2]) << 16 | Int(bytes[at + 3]) << 24
    }
    private static func wavTag(_ bytes: UnsafeRawBufferPointer, _ at: Int, _ tag: String) -> Bool {
        bytes[at..<(at + 4)].elementsEqual(tag.utf8)
    }
    @discardableResult
    package static func validateWAV(_ bytes: Data, maxBytes: Int) throws -> (rate: Int, frames: Int) {
        guard bytes.count >= 44, bytes.count <= maxBytes else { throw VoiceLabError.unsupportedFormat }
        return try bytes.withUnsafeBytes { raw in
            guard wavTag(raw, 0, "RIFF"), wavTag(raw, 8, "WAVE"),
                  wavLE32(raw, 4) == raw.count - 8 else { throw VoiceLabError.unsupportedFormat }
            var offset = 12
            var rate: Int?
            var samples: Int?
            while offset < raw.count {
                guard raw.count - offset >= 8 else { throw VoiceLabError.unsupportedFormat }
                let size = wavLE32(raw, offset + 4)
                let start = offset + 8
                let available = raw.count - start
                guard size <= available, (size & 1) <= available - size else { throw VoiceLabError.unsupportedFormat }
                if wavTag(raw, offset, "fmt ") {
                    guard rate == nil, size == 16 || size == 18,
                          wavLE16(raw, start) == 1, wavLE16(raw, start + 2) == 1,
                          wavLE16(raw, start + 14) == 16,
                          size == 16 || wavLE16(raw, start + 16) == 0 else { throw VoiceLabError.unsupportedFormat }
                    let parsedRate = wavLE32(raw, start + 4)
                    guard (8_000...96_000).contains(parsedRate),
                          wavLE32(raw, start + 8) == parsedRate * 2,
                          wavLE16(raw, start + 12) == 2 else { throw VoiceLabError.unsupportedFormat }
                    rate = parsedRate
                } else if wavTag(raw, offset, "data") {
                    guard samples == nil, size > 0, size.isMultiple(of: 2) else { throw VoiceLabError.unsupportedFormat }
                    samples = size / 2
                }
                offset = start + size + (size & 1)
            }
            guard let rate, let samples,
                  samples >= (rate + 49) / 50, samples <= rate * 290 else { throw VoiceLabError.unsupportedFormat }
            return (rate, samples)
        }
    }

    public static func pcm16k(_ wav: Data) throws -> [Float] {
        let format = try validateWAV(wav, maxBytes: 16 * 1_024 * 1_024)
        func size(_ offset: Int) -> Int {
            Int(wav.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) })
        }
        var offset = 12
        while offset + 8 <= wav.count {
            let count = size(offset + 4)
            let start = offset + 8
            if wav[offset..<(offset + 4)] == Data("data".utf8) {
                let samples: [Float] = wav.withUnsafeBytes { raw in
                    (0..<format.frames).map { frame in
                        let sample = raw.loadUnaligned(fromByteOffset: start + frame * 2, as: Int16.self)
                        return Float(Int16(littleEndian: sample)) / 32_768
                    }
                }
                return resample(samples, rate: format.rate)
            }
            offset = start + count + count % 2
        }
        throw VoiceLabError.invalidAudio
    }
    static func resample(_ samples: [Float], rate: Int) -> [Float] {
        guard rate != 16_000 else { return samples }
        let cutoff = 0.94 * min(1, 16_000 / Double(rate))
        let radius = Int(ceil(32 / cutoff))
        var divisor = rate
        var remainder = 16_000
        while remainder != 0 { (divisor, remainder) = (remainder, divisor % remainder) }
        let phases = 16_000 / divisor
        let kernels: [[Double]] = (0..<phases).map { phase in
            let fraction = Double((phase * rate) % 16_000) / 16_000
            var weights = (-radius...radius).map { tap -> Double in
                let distance = Double(tap) - fraction
                guard abs(distance) <= Double(radius) else { return 0 }
                let position = cutoff * distance
                let sinc = abs(position) < 1e-12 ? 1 : sin(.pi * position) / (.pi * position)
                let window = 0.42 + 0.5 * cos(.pi * distance / Double(radius)) + 0.08 * cos(2 * .pi * distance / Double(radius))
                return cutoff * sinc * window
            }
            let sum = weights.reduce(0, +)
            for index in weights.indices { weights[index] /= sum }
            return weights
        }
        let count = samples.count * 16_000 / rate
        return (0..<count).map { index in
            let source = index * rate / 16_000
            let weights = kernels[index % phases]
            var sum = 0.0
            for tap in max(-radius, -source)...min(radius, samples.count - 1 - source) {
                sum += Double(samples[source + tap]) * weights[tap + radius]
            }
            return Float(sum)
        }
    }
}
