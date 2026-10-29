import Foundation

public enum SpeakerAudio {
    public static let version = "silero-6.2.0-strict-kaldi80-v1"
    public static let windowSize = 48_000
    public static let hopSize = 24_000

    public static func windows(_ speech: [Float]) throws -> [[Float]] {
        guard speech.count >= windowSize, speech.allSatisfy(\.isFinite) else { throw VoiceConsentError.speakerMismatch }
        return stride(from: 0, through: speech.count - windowSize, by: hopSize).map { Array(speech[$0..<($0 + windowSize)]) }
    }

    public static func normalized(_ vector: [Float]) throws -> [Float] {
        guard !vector.isEmpty, vector.allSatisfy(\.isFinite) else { throw VoiceConsentError.speakerMismatch }
        let norm = sqrt(vector.reduce(0.0) { $0 + Double($1) * Double($1) })
        guard norm > 0, norm.isFinite else { throw VoiceConsentError.speakerMismatch }
        return vector.map { Float(Double($0) / norm) }
    }

    public static func select(_ pcm: [Float], ranges: [Range<Int>]) throws -> [Float] {
        guard pcm.allSatisfy(\.isFinite) else { throw VoiceConsentError.speakerMismatch }
        var result: [Float] = []
        var end = 0
        for range in ranges {
            guard range.lowerBound >= end, range.upperBound <= pcm.count, !range.isEmpty else { throw VoiceConsentError.speakerMismatch }
            result.append(contentsOf: pcm[range]); end = range.upperBound
        }
        return result
    }

    public static func energySpeech(_ pcm: [Float]) throws -> [Float] {
        guard pcm.count >= windowSize, pcm.allSatisfy(\.isFinite) else { throw VoiceConsentError.speakerMismatch }
        let gate = pow(10.0, -45.0 / 20.0)
        let ranges = stride(from: 0, through: pcm.count - 160, by: 160).compactMap { start -> Range<Int>? in
            let range = start..<(start + 160)
            let rms = sqrt(pcm[range].reduce(0.0) { $0 + Double($1) * Double($1) } / 160)
            return rms > gate ? range : nil
        }
        return try select(pcm, ranges: ranges)
    }

    public static func features(_ pcm: [Float]) throws -> [Float] {
        guard pcm.count == windowSize, pcm.allSatisfy(\.isFinite) else { throw VoiceConsentError.speakerMismatch }
        let frameCount = 1 + (pcm.count - 400) / 160
        let bank = melBank()
        var output = [Double](repeating: 0, count: frameCount * 80)
        for frame in 0..<frameCount {
            var values = (0..<400).map { Double(pcm[frame * 160 + $0]) * 32_768 }
            let average = values.reduce(0, +) / 400
            values = values.map { $0 - average }
            for index in stride(from: 399, through: 1, by: -1) { values[index] -= 0.97 * values[index - 1] }
            values[0] *= 0.03
            for index in 0..<400 { values[index] *= 0.54 - 0.46 * cos(2 * .pi * Double(index) / 399) }
            let spectrum = power(values)
            for band in 0..<80 {
                var energy = 0.0
                for (index, weight) in bank[band] { energy += spectrum[index] * weight }
                output[frame * 80 + band] = log(max(Double(Float.ulpOfOne), energy))
            }
        }
        for band in 0..<80 {
            var mean = 0.0
            for frame in 0..<frameCount { mean += output[frame * 80 + band] }
            mean /= Double(frameCount)
            for frame in 0..<frameCount { output[frame * 80 + band] -= mean }
        }
        return output.map(Float.init)
    }

    private static func melBank() -> [[(Int, Double)]] {
        let low = 1127 * log(1 + 20.0 / 700)
        let high = 1127 * log(1 + 8000.0 / 700)
        let step = (high - low) / 81
        return (0..<80).map { band in
            let left = low + Double(band) * step
            return (0..<256).compactMap { index in
                let mel = 1127 * log(1 + (Double(index) * 16000 / 512) / 700)
                let weight = max(0, min((mel - left) / step, (left + 2 * step - mel) / step))
                return weight > 0 ? (index, weight) : nil
            }
        }
    }

    private static func power(_ samples: [Double]) -> [Double] {
        var real = samples + [Double](repeating: 0, count: 512 - samples.count)
        var imaginary = [Double](repeating: 0, count: 512)
        var reversed = 0
        for index in 1..<512 {
            var bit = 256
            while reversed & bit != 0 { reversed ^= bit; bit >>= 1 }
            reversed ^= bit
            if index < reversed { real.swapAt(index, reversed) }
        }
        var length = 2
        while length <= 512 {
            for start in stride(from: 0, to: 512, by: length) {
                for offset in 0..<(length / 2) {
                    let angle = -2 * Double.pi * Double(offset) / Double(length)
                    let other = start + offset + length / 2
                    let current = start + offset
                    let realPart = real[other] * cos(angle) - imaginary[other] * sin(angle)
                    let imaginaryPart = real[other] * sin(angle) + imaginary[other] * cos(angle)
                    real[other] = real[current] - realPart; imaginary[other] = imaginary[current] - imaginaryPart
                    real[current] += realPart; imaginary[current] += imaginaryPart
                }
            }
            length *= 2
        }
        return (0...256).map { real[$0] * real[$0] + imaginary[$0] * imaginary[$0] }
    }
}
