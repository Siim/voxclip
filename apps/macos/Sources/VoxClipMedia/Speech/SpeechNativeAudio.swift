import AVFoundation
import Foundation
import VoxClipCore

enum SpeechNativeAudio {
    static func samples(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: false)
        guard file.processingFormat.sampleRate == 16000, file.processingFormat.channelCount == 1,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 65536) else { throw VoxClipError.decodeFailed("Expected a mono 16 kHz PCM WAV") }
        var samples: [Float] = []; samples.reserveCapacity(Int(file.length))
        while file.framePosition < file.length {
            try Task.checkCancellation()
            try file.read(into: buffer)
            guard let channel = buffer.int16ChannelData?[0] else { throw VoxClipError.decodeFailed("Invalid PCM") }
            samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)).map { Float($0) / 32768 })
        }
        return samples
    }
    static func normalized(_ samples: [Float]) throws -> [Float] {
        var power = 0.0, activeCount = 0
        for start in stride(from: 0, to: samples.count, by: 160) {
            try Task.checkCancellation()
            let frame = samples[start..<min(start + 160, samples.count)]
            let sum = frame.reduce(0.0) { $0 + Double($1) * Double($1) }
            if sum / Double(frame.count) > 0.000001 { power += sum; activeCount += frame.count }
        }
        let db = activeCount == 0 ? 0 : min(30, max(-20, -20 - 10 * log10(power / Double(activeCount))))
        let gain = Float(pow(10, db / 20))
        var result = samples
        for index in result.indices {
            if index % 65536 == 0 { try Task.checkCancellation() }
            result[index] = min(1, max(-1, result[index] * gain))
        }
        return result
    }
}

public struct WhisperTokenPiece: Sendable {
    public let bytes: Data
    public let start: Double
    public let end: Double
    public let confidence: Double
    public init(bytes: Data, start: Double, end: Double, confidence: Double) { self.bytes = bytes; self.start = start; self.end = end; self.confidence = confidence }
}

public enum WhisperTokenMapper {
    public static func tokens(_ pieces: [WhisperTokenPiece], group: Int, offset: Double, duration: Double) -> [RawToken] {
        var pending = Data(), pendingStart: Double?
        var first = true
        var result: [RawToken] = []
        for piece in pieces {
            pending.append(piece.bytes)
            pendingStart = pendingStart ?? piece.start
            guard endsWithCompleteUTF8(pending) else { continue }
            let text = String(decoding: pending, as: UTF8.self)
            if text.hasPrefix("[_") && text.hasSuffix("]") || text.hasPrefix("<|") && text.hasSuffix("|>") {
                pending.removeAll(keepingCapacity: true)
                pendingStart = nil
                continue
            }
            let startsWord = first || text.hasPrefix(" ")
            let start = min(duration, max(0, pendingStart ?? piece.start)) + offset
            let end = min(duration, max(0, piece.end)) + offset
            result.append(RawToken(text: String(text.drop(while: { $0 == " " })), joinsPrevious: !startsWord, start: start, end: end, conf: piece.confidence, group: group))
            pending.removeAll(keepingCapacity: true); pendingStart = nil; first = false
        }
        return result
    }
    private static func endsWithCompleteUTF8(_ bytes: Data) -> Bool {
        var continuationCount = 0
        for byte in bytes.reversed() {
            if byte & 0xc0 == 0x80 { continuationCount += 1; continue }
            let required: Int
            switch byte {
            case 0xc2...0xdf: required = 1
            case 0xe0...0xef: required = 2
            case 0xf0...0xf4: required = 3
            default: return true
            }
            return continuationCount >= required
        }
        return true
    }
}
