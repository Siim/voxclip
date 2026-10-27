import CoreMedia
import Foundation
import Testing
@testable import VoxClipMedia

private struct ContinuityDocument: Decodable {
    let caseCount: Int
    let cases: [ContinuityCase]
}

private struct ContinuityCase: Decodable {
    struct Timestamp: Decodable {
        let value: Int64
        let numerator: Int64
        let denominator: Int32
    }
    struct Expected: Decodable {
        let firstSample: Int64?
        let skipCount: Int64?
        let error: String?
    }
    let name: String
    let rate: Int
    let timestamp: Timestamp?
    let previousEnd: Int64?
    let nextSample: Int64
    let sampleCount: Int64
    let expected: Expected
}

@Suite struct VoiceLabContinuityTests {
    @Test func sharedContinuityVectorsUseProductionPlacement() throws {
        let data = try FixtureLoader.data("fixtures/voice-lab/continuity-cases.json")
        let document = try JSONDecoder().decode(ContinuityDocument.self, from: data)
        #expect(document.caseCount == 38)
        #expect(document.cases.count == document.caseCount)
        for row in document.cases {
            let time: CMTime
            if let timestamp = row.timestamp {
                #expect(timestamp.numerator == 1)
                time = CMTime(value: timestamp.value, timescale: timestamp.denominator)
            } else { time = .invalid }
            let count: Int = Int(row.sampleCount)
            let end: Int64 = row.nextSample + row.sampleCount
            var accumulator = VoiceLabSourceAudio.ConversionAccumulator(rate: row.rate, channels: 1,
                startSample: row.nextSample, endSample: end, frames: count)
            let content: [Float] = (0..<count).map { (index: Int) -> Float in
                let value: Float = Float(index)
                return (value + 1.0) / 2_048.0
            }
            if let previousEnd = row.previousEnd {
                let start: Int64 = previousEnd - row.sampleCount
                let timestamp = CMTime(value: start, timescale: CMTimeScale(row.rate))
                try accumulator.append(VoiceLabSourceAudioTests.floatBuffer(content, rate: row.rate, time: timestamp))
                #expect(accumulator.next == row.nextSample, Comment(rawValue: row.name))
            }
            let buffer = try VoiceLabSourceAudioTests.floatBuffer(content, rate: row.rate, time: time)
            if row.expected.error == "unreadable" {
                #expect(throws: VoiceLabSourceAudioError.unreadable, Comment(rawValue: row.name)) {
                    try VoiceLabSourceAudio.bufferFirstSample(presentationTime: time, rate: row.rate, previousEnd: row.previousEnd)
                }
                #expect(throws: VoiceLabSourceAudioError.unreadable, Comment(rawValue: row.name)) {
                    try accumulator.append(buffer)
                }
                continue
            }
            let first = try VoiceLabSourceAudio.bufferFirstSample(presentationTime: time, rate: row.rate, previousEnd: row.previousEnd)
            #expect(first == row.expected.firstSample, Comment(rawValue: row.name))
            if row.expected.error == "rangeOutsideMedia" {
                #expect(first > row.nextSample, Comment(rawValue: row.name))
                #expect(throws: VoiceLabSourceAudioError.rangeOutsideMedia, Comment(rawValue: row.name)) {
                    try accumulator.append(buffer)
                }
            } else {
                #expect(first <= row.nextSample, Comment(rawValue: row.name))
                let skip: Int64 = min(row.sampleCount, row.nextSample - first)
                #expect(skip == row.expected.skipCount, Comment(rawValue: row.name))
                try accumulator.append(buffer)
                let written: Int64 = row.sampleCount - skip
                #expect(accumulator.next == row.nextSample + written, Comment(rawValue: row.name))
                let skipped: Int = Int(skip)
                let writtenPCM: [Int16] = content.dropFirst(skipped).map { (sample: Float) -> Int16 in
                    VoiceLabAssetStore.pcm16(sample)
                }
                let padding: [Int16] = [Int16](repeating: 0, count: skipped)
                let expected: [Int16] = writtenPCM + padding
                let actual: [Int16] = accumulator.wav.dropFirst(44).withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [Int16] in
                    (0..<count).map { (index: Int) -> Int16 in
                        Int16(littleEndian: raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self))
                    }
                }
                #expect(actual == expected, Comment(rawValue: row.name))
            }
        }
    }
}
