import Foundation
import VoxClipCore

enum VoiceLabTakeWAV {
    static func encode(_ samples: [Float], rate: Int) throws -> Data {
        guard (8_000...96_000).contains(rate), !samples.isEmpty, samples.count <= rate * 290,
              samples.allSatisfy({ $0.isFinite && abs($0) <= 1 }) else { throw VoiceLabError.invalidAudio }
        var result = Data("RIFF".utf8)
        func append(_ value: Int, bytes: Int) {
            for offset in 0..<bytes { result.append(UInt8(truncatingIfNeeded: value >> (offset * 8))) }
        }
        append(36 + samples.count * 2, bytes: 4); result.append(Data("WAVEfmt ".utf8))
        append(16, bytes: 4); append(1, bytes: 2); append(1, bytes: 2)
        append(rate, bytes: 4); append(rate * 2, bytes: 4); append(2, bytes: 2); append(16, bytes: 2)
        result.append(Data("data".utf8)); append(samples.count * 2, bytes: 4)
        for sample in samples { append(Int((Double(sample) * 32_767).rounded()), bytes: 2) }
        return result
    }
}
