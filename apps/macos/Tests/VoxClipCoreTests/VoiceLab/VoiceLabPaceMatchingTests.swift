import Foundation
import Testing
@testable import VoxClipCore

@Suite struct VoiceLabPaceMatchingTests {
    private func window(_ seconds: Double, kind: VoiceLabSeamKind = .gap) -> VoiceLabWindow {
        let start: Int64 = kind == .none ? 0 : 480_000
        let startTime = Double(start) / 48_000
        let end = start + Int64(EditingPrimitives.jsRound(seconds * 48_000))
        return VoiceLabWindow(firstWordId: "w", lastWordId: "w", leftBridgeWordIds: [], rightBridgeWordIds: [],
            start: startTime, end: Double(end) / 48_000, startSample: start, endSample: end,
            leftSeam: .init(kind: kind, time: startTime, sample: start, fadeSamples: 240),
            rightSeam: .init(kind: kind, time: Double(end) / 48_000, sample: end, fadeSamples: 240))
    }

    @Test func sampleExactPaidPhrasesPreferKeepingSource() throws {
        struct Document: Decodable {
            struct Row: Decodable {
                let id: String
                let windowSeconds: Double
                let measuredSeconds: Double
                let pace: Double
                let fits: Bool
                let keepsSource: Bool
            }
            let schema: String
            let sourceSampleRate: Int
            let seamKind: VoiceLabSeamKind
            let incomingSilence: Double
            let outgoingSilence: Double
            let caseCount: Int
            let cases: [Row]
        }
        let fixture = try FixtureLoader.decode(Document.self, at: "fixtures/voice-lab/pace-matching-cases.json")
        #expect(fixture.schema == "voxclip-pace-matching/1" && fixture.caseCount == 3 && fixture.cases.count == 3)
        for row in fixture.cases {
            let source = window(row.windowSeconds, kind: fixture.seamKind)
            let timing = try VoiceLabPaceMatching.match(seconds: row.measuredSeconds, window: source,
                incomingSilence: fixture.incomingSilence, outgoingSilence: fixture.outgoingSilence, sourceSampleRate: fixture.sourceSampleRate, hardJoinSmoothing: false)
            #expect(timing.pace == row.pace, "\(row.id)")
            #expect(timing.fits == row.fits, "\(row.id)")
            let fit = try VoiceLabPhraseTiming.preview(seconds: timing.estimateSeconds, window: source,
                incomingSilence: 0.05, outgoingSilence: 0.05, sourceSampleRate: 48_000)
            let gate = VoiceLabVideoDurationOptions(fit: fit, sourceSampleRate: 48_000, assetSampleRate: 48_000)
            #expect(gate.allows(.source) == row.keepsSource)
            #expect(fit.plan.incoming.padFrames + fit.plan.outgoing.padFrames <= 28_800)
            #expect(timing.copy.contains("at ≈\(String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), row.pace))× pace"))
            if !row.fits { #expect(timing.tooLong) }
        }
    }

    @Test(arguments: [false, true]) func pacePreferenceMatchesExhaustiveProviderGrid(hardJoinSmoothing: Bool) throws {
        for kind in [VoiceLabSeamKind.hard, .gap, .none] {
            for duration in [0.3, 1.145, 5.12, 19.4] {
                for fraction in [0.3, 0.7, 1.0, 1.4, 2.0] {
                    let source = window(duration, kind: kind)
                    let silence: Double? = kind == .hard ? nil : 0.05
                    let natural = duration * fraction
                    func gate(_ pace: Double) throws -> VoiceLabVideoDurationOptions {
                        let fit = try VoiceLabPhraseTiming.preview(seconds: natural / pace, window: source,
                            incomingSilence: silence, outgoingSilence: silence, sourceSampleRate: 48_000, hardJoinSmoothing: hardJoinSmoothing)
                        return VoiceLabVideoDurationOptions(fit: fit, sourceSampleRate: 48_000, assetSampleRate: 48_000)
                    }
                    let timing = try VoiceLabPaceMatching.match(seconds: natural, window: source,
                        incomingSilence: silence, outgoingSilence: silence, sourceSampleRate: 48_000, hardJoinSmoothing: hardJoinSmoothing)
                    let grid = try (70...120).map { try gate(Double($0) / 100) }
                    let chosen = try gate(timing.pace)
                    #expect(timing.fits == grid.contains { $0.allows(.source) || $0.allows(.retimed) })
                    if grid.contains(where: { $0.allows(.source) }) {
                        #expect(chosen.allows(.source), "\(kind) \(duration) \(fraction), chose \(timing.pace)")
                    }
                }
            }
        }
    }

    @Test func hardSeamsFallBackToMatchVideoAndRetriesUseMeasuredPace() throws {
        let source = window(5.120, kind: .hard)
        let timing = try VoiceLabPaceMatching.match(seconds: 3.390, window: source,
            incomingSilence: nil, outgoingSilence: nil, sourceSampleRate: 48_000, hardJoinSmoothing: false)
        #expect(timing.pace == 0.7 && timing.fits)
        let fit = try VoiceLabPhraseTiming.preview(seconds: timing.estimateSeconds, window: source,
            incomingSilence: nil, outgoingSilence: nil, sourceSampleRate: 48_000)
        let gate = VoiceLabVideoDurationOptions(fit: fit, sourceSampleRate: 48_000, assetSampleRate: 48_000)
        #expect(!gate.allows(.source) && gate.allows(.retimed))
        let retry = try VoiceLabPaceMatching.match(seconds: 5.8, oldPace: 0.7, window: source,
            incomingSilence: nil, outgoingSilence: nil, sourceSampleRate: 48_000, hardJoinSmoothing: false)
        #expect(retry.pace == 0.8 && retry.fits)
        #expect(abs(retry.estimateSeconds - 5.075) < 0.00001)
    }

    @Test func tooShortAndDialogueKeepTruthfulRecovery() throws {
        let source = window(5.120, kind: .hard)
        let short = try VoiceLabPaceMatching.match(seconds: 1, window: source,
            incomingSilence: nil, outgoingSilence: nil, sourceSampleRate: 48_000, hardJoinSmoothing: false)
        #expect(short.pace == 0.7 && !short.fits && !short.tooLong)
        let dialogue = try VoiceLabPaceMatching.match(seconds: 3.390, window: source,
            incomingSilence: nil, outgoingSilence: nil, sourceSampleRate: 48_000, supportsPace: false, hardJoinSmoothing: false)
        #expect(dialogue.pace == 1 && !dialogue.fits)
        #expect(!dialogue.copy.contains("pace"))
    }
}
