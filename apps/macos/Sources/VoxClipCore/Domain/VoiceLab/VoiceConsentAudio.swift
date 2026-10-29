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
                let outputCount = format.frames * 16_000 / format.rate
                return wav.withUnsafeBytes { raw in
                    (0..<outputCount).map { index in
                        let source = index * format.rate / 16_000
                        let next = min(format.frames, max(source + 1, (index + 1) * format.rate / 16_000))
                        var sum = 0.0
                        for frame in source..<next {
                            let sample = raw.loadUnaligned(fromByteOffset: start + frame * 2, as: Int16.self)
                            sum += Double(Int16(littleEndian: sample)) / 32_768
                        }
                        return Float(sum / Double(next - source))
                    }
                }
            }
            offset = start + count + count % 2
        }
        throw VoiceLabError.invalidAudio
    }
}
