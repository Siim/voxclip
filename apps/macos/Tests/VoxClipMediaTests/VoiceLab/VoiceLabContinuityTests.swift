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
            if row.expected.error == "unreadable" {
                #expect(throws: VoiceLabSourceAudioError.unreadable, Comment(rawValue: row.name)) {
                    try VoiceLabSourceAudio.bufferFirstSample(presentationTime: time, rate: row.rate, previousEnd: row.previousEnd)
                }
                continue
            }
            let first = try VoiceLabSourceAudio.bufferFirstSample(presentationTime: time, rate: row.rate, previousEnd: row.previousEnd)
            #expect(first == row.expected.firstSample, Comment(rawValue: row.name))
            if row.expected.error == "rangeOutsideMedia" {
                #expect(first > row.nextSample, Comment(rawValue: row.name))
            } else {
                #expect(first <= row.nextSample, Comment(rawValue: row.name))
                let skip: Int64 = min(row.sampleCount, row.nextSample - first)
                #expect(skip == row.expected.skipCount, Comment(rawValue: row.name))
            }
        }
    }
}
