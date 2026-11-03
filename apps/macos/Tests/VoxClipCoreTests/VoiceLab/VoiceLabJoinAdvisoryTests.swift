import Foundation
import Testing
@testable import VoxClipCore

@Suite("Join loudness advisories", .offlineFixtures)
struct VoiceLabJoinAdvisoryTests {
    static func row(failures: [VoiceLabTakeQAFailure], index: Int = 0, score: Double = 1) -> VoiceLabTakeRow {
        let audio = VoiceLabTakeAudio(sampleRate: 24_000, trimmed: [], mixed: [], patchRange: 0..<0,
            seams: [], gainDb: 0, roomTone: nil, fit: VoiceLabTakeQualityTests.fit(window: 1, residual: 0))
        let qa = VoiceLabTakeQAResult(values: .init(transcriptMatch: 1, lufsJumpLu: failures.contains(.loudness) ? 4 : 0,
            peakDbfs: -10, speakerScore: 0.9), failures: failures,
            joinSeams: failures.contains(.loudness) ? [.init(side: .left, excessLu: 4)] : [])
        return VoiceLabTakeRow(id: UUID(), index: index, seed: 1, audio: audio, qa: qa, score: score)
    }

    @Test func joinOnlyIsSelectableButWordsAndVoiceStayHard() {
        #expect(Self.row(failures: [.loudness]).selectable)
        for failure: VoiceLabTakeQAFailure in [.transcript, .clipping, .speaker, .insufficientGeneratedSpeech] {
            #expect(!Self.row(failures: [.loudness, failure]).selectable)
        }
    }

    @Test func cleanPassRanksAheadOfHigherScoringAdvisory() {
        let advisory = Self.row(failures: [.loudness], index: 0, score: 1)
        let clean = Self.row(failures: [], index: 1, score: 0.8)
        let failed = Self.row(failures: [.transcript], index: 2)
        let result = VoiceLabTakeRunResult(rows: [advisory, failed, clean], end: .completed)
        #expect(result.ranked.map(\.id) == [clean.id, advisory.id])
        #expect(result.bestAutomatic?.id == clean.id)
        #expect(VoiceLabTakeRunResult(rows: [advisory], end: .completed).bestAutomatic == nil)
    }

    @Test func advisoryNeedsExplicitAcceptanceAndKeepsTheMeasuredSeams() throws {
        let row = Self.row(failures: [.loudness])
        #expect(row.qa?.verdict == .passedWithAdvisory && row.requiresJoinAdvisoryAcceptance)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let accepted = try row.acceptingJoinAdvisory(at: date)
        #expect(!accepted.requiresJoinAdvisoryAcceptance && !accepted.automaticallySelectable)
        #expect(accepted.acceptedJoinAdvisory == .init(seams: [.init(side: .left, excessLu: 4)], acceptedAt: date))
        #expect(throws: VoiceLabProjectError.qaRejected) { try Self.row(failures: [.speaker, .loudness]).acceptingJoinAdvisory(at: date) }
        #expect(throws: VoiceLabProjectError.qaRejected) { try Self.row(failures: []).acceptingJoinAdvisory(at: date) }
    }

    @Test func actualJoinMeasurementNamesBothSidesAndPreservesHardFailures() throws {
        let rate = 16_000
        let samples = (0..<(rate * 2)).map { index -> Float in
            let amplitude = index < 8_000 ? 0.02 : index < 24_000 ? 0.2 : 0.04
            return Float(amplitude * sin(2 * Double.pi * 220 * Double(index) / Double(rate)))
        }
        let result = try VoiceLabTakeQuality.evaluate(expected: "hello", recognized: ["hello"], mixed: samples, sampleRate: rate,
            seams: [8_000, 24_000], generatedAfter: [true, false], speakerScore: 0.9, threshold: 0.45)
        #expect(result.verdict == .passedWithAdvisory && result.hardFailures.isEmpty)
        #expect(result.joinSeams.map(\.side) == [.left, .right])
        #expect(result.joinSeams.map(\.excessLu).max() == result.values.lufsJumpLu)
        let failed = try VoiceLabTakeQuality.evaluate(expected: "hello", recognized: ["wrong"], mixed: samples, sampleRate: rate,
            seams: [8_000], speakerScore: 0, threshold: 0.45)
        #expect(failed.verdict == .failed && failed.hardFailures == [.transcript, .speaker])
    }
}
