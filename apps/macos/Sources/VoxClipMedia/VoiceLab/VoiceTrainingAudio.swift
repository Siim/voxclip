import Foundation
import VoxClipCore

public enum VoiceTrainingAudio {
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
