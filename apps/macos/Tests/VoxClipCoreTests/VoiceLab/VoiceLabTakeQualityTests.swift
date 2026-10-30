import Foundation
import Testing
@testable import VoxClipCore

@Suite("Take ranking and QA vectors")
struct VoiceLabTakeQualityTests {
    private struct Cases: Decodable {
        struct Rank: Decodable { let id: String; let window: Double; let residual: Double; let match: Double; let flatness: Double; let score: Double }
        struct QA: Decodable { let id: String; let expected: String; let recognized: [String]; let amplitude: Double; let afterAmplitude: Double?; let speaker: Double; let failures: [VoiceLabTakeQAFailure] }
        let schema: String
        let ranking: [Rank]
        let qa: [QA]
    }
    static func fit(window: Double, residual: Double) -> VoiceLabFitResult {
        let rate = 24_000.0
        let plan = VoiceLabFitPlan(edits: [], incoming: .init(padFrames: 0, borrowedSamples: 0), outgoing: .init(padFrames: 0, borrowedSamples: 0),
            trimStartFrame: 0, trimEndFrame: Int64((window + residual) * rate), windowStart: 0, windowEnd: window,
            windowStartSample: 0, windowEndSample: Int64(window * rate), outputFrames: Int64((window + residual) * rate), words: [])
        return residual == 0 ? .exact(plan) : .changedDuration(plan, naturalOut: window + residual, residualSeconds: residual)
    }
    @Test func rankingReplaysSharedFormula() throws {
        let cases = try JSONDecoder().decode(Cases.self, from: FixtureLoader.data("fixtures/voice-lab/take-run-cases.json"))
        #expect(cases.schema == "voxclip-take-run-cases/1")
        for row in cases.ranking {
            let score = try VoiceLabTakeQuality.rank(fit: Self.fit(window: row.window, residual: row.residual), windowSeconds: row.window,
                                                    matchRatio: row.match, flatness: row.flatness)
            #expect(abs(score - row.score) < 1e-12, "\(row.id)")
        }
    }
    @Test func qaCompositionReplaysSharedFailures() throws {
        let cases = try JSONDecoder().decode(Cases.self, from: FixtureLoader.data("fixtures/voice-lab/take-run-cases.json"))
        for row in cases.qa {
            let samples: [Float] = (0..<16_000).map { index in
                let amplitude = index >= 8_000 ? row.afterAmplitude ?? row.amplitude : row.amplitude
                return Float(amplitude * sin(2 * Double.pi * 220 * Double(index) / 16_000))
            }
            let result = try VoiceLabTakeQuality.evaluate(expected: row.expected, recognized: row.recognized, mixed: samples, sampleRate: 16_000,
                seams: row.afterAmplitude == nil ? [] : [8_000], speakerScore: row.speaker, threshold: 0.45)
            #expect(result.failures == row.failures, "\(row.id)")
            #expect(result.passed == row.failures.isEmpty)
        }
    }
    @Test func quoteSetCostIncludesEveryQACapAndWrapsSeeds() throws {
        let speech = CostEstimate(provider: "elevenlabs", operation: "textToSpeech", units: 5, unit: "character", usd: Decimal(string: "0.1"), basis: "fixture")
        let qa = CostEstimate(provider: "elevenlabs", operation: "speechToText", units: 290, unit: "second", usd: Decimal(string: "0.1"), basis: "fixture")
        let takes = (0..<3).map { index in
            VoiceLabTakeQuote(index: index, seed: UInt32.max &+ UInt32(index),
                synthesis: VoiceLabQuote(id: UUID(), operation: .textToSpeech, requestID: UUID(), estimate: speech, region: .default, endpoint: "tts", languageMode: nil, fingerprint: "fixture"),
                qa: VoiceLabQuote(id: UUID(), operation: .speechToText, requestID: UUID(), estimate: qa, region: .default, endpoint: "qa", languageMode: nil, fingerprint: "fixture"))
        }
        let quote = VoiceLabTakeRunQuote(id: UUID(), takes: takes, preparedAt: Date(timeIntervalSince1970: 1_000))
        #expect(quote.estimate.usd == Decimal(string: "0.6"))
        #expect(quote.takes.map(\.seed) == [UInt32.max, 0, 1])
        #expect(quote.expiresAt.timeIntervalSince(quote.preparedAt) == 300)
        if case .confirm = VoiceLabCostPresentation.kind(quote.estimate, isLipSync: false, providerName: "ElevenLabs") {} else { Issue.record("The total requires confirmation") }
        let unknownEstimate = CostEstimate(provider: "elevenlabs", operation: "speechToText", units: 290, unit: "second", basis: "unknown")
        let unknownQA = VoiceLabQuote(id: UUID(), operation: .speechToText, requestID: UUID(), estimate: unknownEstimate, region: .default, endpoint: "qa", languageMode: nil, fingerprint: "fixture")
        let unknown = VoiceLabTakeRunQuote(id: UUID(), takes: [.init(index: 0, seed: 1, synthesis: takes[0].synthesis, qa: unknownQA)], preparedAt: Date())
        #expect(unknown.estimate.usd == nil)
        if case .confirm = VoiceLabCostPresentation.kind(unknown.estimate, isLipSync: false, providerName: "ElevenLabs") {} else { Issue.record("Unknown QA pricing requires run confirmation") }
    }
}
