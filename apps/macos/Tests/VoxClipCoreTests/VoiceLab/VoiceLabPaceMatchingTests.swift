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
                let quietSpan: [Double]
                let videoCut: Bool
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
        #expect(fixture.schema == "voxclip-pace-matching/2" && fixture.caseCount == 6 && fixture.cases.count == 6)
        for row in fixture.cases {
            let source = window(row.windowSeconds, kind: fixture.seamKind)
            let blocks = Int(ceil(source.end * 100))
            let envelope = AudioEnvelope(sampleRate: 48_000, levels: (0..<blocks).map { block in
                let local = Double(block) / 100 - source.start
                return local >= row.quietSpan[0] && local + 0.01 <= row.quietSpan[1] ? 0.001 : 1
            })
            let timing = try VoiceLabPaceMatching.match(seconds: row.measuredSeconds, window: source,
                incomingSilence: fixture.incomingSilence, outgoingSilence: fixture.outgoingSilence, sourceSampleRate: fixture.sourceSampleRate,
                hardJoinSmoothing: false, sourceEnvelope: envelope)
            #expect(timing.pace == row.pace, "\(row.id)")
            #expect(timing.fits == row.fits, "\(row.id)")
            let fit = try VoiceLabPhraseTiming.preview(seconds: timing.estimateSeconds, window: source,
                incomingSilence: 0.05, outgoingSilence: 0.05, sourceSampleRate: 48_000, hardJoinSmoothing: false)
            let gate = VoiceLabVideoDurationOptions(fit: fit, sourceSampleRate: 48_000, assetSampleRate: 48_000)
            #expect(gate.allows(.source) == row.keepsSource)
            #expect(fit.plan.incoming.padFrames + fit.plan.outgoing.padFrames <= 28_800)
            #expect(timing.fitsWithVideoCut == row.videoCut)
            #expect(!timing.copy.contains("pace"))
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
                    let grid = try (90...110).map { try gate(Double($0) / 100) }
                    let chosen = try gate(timing.pace)
                    #expect((0.9...1.1).contains(timing.pace))
                    #expect(timing.fits == (chosen.allows(.source) || chosen.allows(.retimed)))
                    if grid.contains(where: { $0.allows(.source) }) {
                        #expect(chosen.allows(.source), "\(kind) \(duration) \(fraction), chose \(timing.pace)")
                    }
                    else { #expect(timing.pace == 1) }
                }
            }
        }
    }

    @Test func hardSeamsFallBackToMatchVideoAndRetriesUseMeasuredPace() throws {
        let source = window(5.120, kind: .hard)
        let timing = try VoiceLabPaceMatching.match(seconds: 3.390, window: source,
            incomingSilence: nil, outgoingSilence: nil, sourceSampleRate: 48_000, hardJoinSmoothing: false)
        #expect(timing.pace == 1 && !timing.fits)
        let fit = try VoiceLabPhraseTiming.preview(seconds: timing.estimateSeconds, window: source,
            incomingSilence: nil, outgoingSilence: nil, sourceSampleRate: 48_000, hardJoinSmoothing: false)
        let gate = VoiceLabVideoDurationOptions(fit: fit, sourceSampleRate: 48_000, assetSampleRate: 48_000)
        #expect(!gate.allows(.source) && !gate.allows(.retimed))
        let retry = try VoiceLabPaceMatching.match(seconds: 5.8, oldPace: 0.7, window: source,
            incomingSilence: nil, outgoingSilence: nil, sourceSampleRate: 48_000, hardJoinSmoothing: false)
        #expect(retry.pace == 1 && retry.fits)
        #expect(abs(retry.estimateSeconds - 4.06) < 0.00001)
    }

    @Test func tooShortAndDialogueKeepTruthfulRecovery() throws {
        let source = window(5.120, kind: .hard)
        let short = try VoiceLabPaceMatching.match(seconds: 1, window: source,
            incomingSilence: nil, outgoingSilence: nil, sourceSampleRate: 48_000, hardJoinSmoothing: false)
        #expect(short.pace == 1 && !short.fits && !short.tooLong)
        let dialogue = try VoiceLabPaceMatching.match(seconds: 3.390, window: source,
            incomingSilence: nil, outgoingSilence: nil, sourceSampleRate: 48_000, supportsPace: false, hardJoinSmoothing: false)
        #expect(dialogue.pace == 1 && !dialogue.fits)
        #expect(!dialogue.copy.contains("pace"))
    }
}
