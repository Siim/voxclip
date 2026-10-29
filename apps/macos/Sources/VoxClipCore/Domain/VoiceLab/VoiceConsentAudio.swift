import Foundation

public enum VoiceConsentAudio {
    public static func pcm16k(_ wav: Data) throws -> [Float] {
        let format = try ElevenLabsVoiceLab.validateWAV(wav, maxBytes: 16 * 1_024 * 1_024)
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
