import Foundation
import Testing
@testable import VoxClipCore

@Suite("Hard join smoothing", .offlineFixtures)
struct VoiceLabHardJoinTests {
    private struct Fixture: Decodable {
        struct Fade: Decodable { let id: String; let curve: String; let seconds: Double; let expected: Double }
        struct Gain: Decodable { let seconds: Double; let expectedDb: Double }
        struct Validation: Decodable { let id: String; let kind: VoiceLabSeamKind; let microPause: VoiceLabMicroPause?; let gainDb: Double?; let valid: Bool }
        struct Reserve: Decodable { let windowSeconds: Double; let speechSeconds: Double; let legacyOutputSeconds: Double; let outputSeconds: Double; let padSeconds: Double; let pace: Double; let fits: Bool }
        struct RoomTone: Decodable { let runAmplitude: Double; let pauseAmplitude: Double; let gainDb: Double; let toleranceLu: Double }
        struct JoinCheck: Decodable { let pauseSeconds: [Double]; let speechStepDb: Double; let excessLu: Double }
        struct Acoustic: Decodable { let alignedStart: Double; let alignedEnd: Double; let audioStart: Double; let audioEnd: Double; let searchLimitSeconds: Double }
        let schema: String
        let caseCount: Int
        let rates: [Int]
        let durationSeconds: Double
        let incoming: VoiceLabMicroPause
        let outgoing: VoiceLabMicroPause
        let fades: [Fade]
        let gains: [Gain]
        let validation: [Validation]
        let reserve: Reserve
        let roomTone: RoomTone
        let joinCheck: JoinCheck
        let acoustic: Acoustic
    }
    private func fixture() throws -> Fixture { try FixtureLoader.decode(Fixture.self, at: "fixtures/voice-lab/hard-join-cases.json") }
    private func window(_ rate: Int, duration: Double = 1) -> VoiceLabWindow {
        let start = Int64(rate * 2), end = start + Int64(EditingPrimitives.jsRound(duration * Double(rate)))
        return .init(firstWordId: "w", lastWordId: "w", leftBridgeWordIds: [], rightBridgeWordIds: [], start: 2, end: 2 + duration,
                     startSample: start, endSample: end, leftSeam: .init(kind: .hard, time: 2, sample: start, fadeSamples: Int64(Double(rate) * 0.012)),
                     rightSeam: .init(kind: .hard, time: 2 + duration, sample: end, fadeSamples: Int64(Double(rate) * 0.012)))
    }

    @Test func sharedFadeAndGainCurvesReplayOnBothGrids() throws {
        let fixture = try fixture()
        #expect(fixture.schema == "voxclip-hard-join/1" && fixture.caseCount == 42)
        let gain = VoiceLabEdgeGain(in: .init(gainDb: 6, wordSeconds: fixture.incoming), out: .init(gainDb: 6, wordSeconds: fixture.outgoing))
        for rate in fixture.rates {
            for row in fixture.fades {
                let seconds = EditingPrimitives.jsRound(row.seconds * Double(rate)) / Double(rate)
                let measured: Double
                if row.curve == "generated" {
                    measured = VoiceLabHardJoin.generatedWeight(seconds: seconds, duration: fixture.durationSeconds, incoming: fixture.incoming, outgoing: fixture.outgoing)
                } else { measured = VoiceLabHardJoin.sourceWeight(secondsFromJoin: seconds, incoming: row.curve == "source-in") }
                #expect(abs(measured - row.expected) < 1e-10, "\(row.id) at \(rate)")
            }
            for row in fixture.gains {
                let seconds = EditingPrimitives.jsRound(row.seconds * Double(rate)) / Double(rate)
                #expect(abs(VoiceLabHardJoin.edgeGainDb(seconds: seconds, duration: 2, edgeGain: gain) - row.expectedDb) < 1e-10)
            }
        }
    }

    @Test func sharedValidationAndOptionalFieldRoundTrips() throws {
        for row in try fixture().validation {
            let seam = VoiceLabSeam(kind: row.kind, fadeSamples: 576, sourceHandleSamples: 288, assetHandleFrames: 144, microPause: row.microPause)
            let gain = row.gainDb.map { VoiceLabEdgeGain(out: .init(gainDb: $0, wordSeconds: row.microPause ?? .init(wordStartSeconds: -0.44, wordEndSeconds: -0.14))) }
            let seams = VoiceLabSeams(in: .init(kind: .none, fadeSamples: 0, sourceHandleSamples: 0, assetHandleFrames: 0), out: seam)
            if row.valid { try VoiceLabHardJoin.validate(seams: seams, edgeGain: gain, duration: 2) }
            else { #expect(throws: VoiceLabProjectError.invalidFadeHandles) { try VoiceLabHardJoin.validate(seams: seams, edgeGain: gain, duration: 2) } }
            let encoded = try JSONEncoder().encode(seam)
            #expect(try JSONDecoder().decode(VoiceLabSeam.self, from: encoded) == seam)
            let object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
            #expect((object["microPause"] != nil) == (row.microPause != nil))
        }
    }

    @Test func sharedReserveCountsBeforePaceAndLeavesLegacyUnchanged() throws {
        let fixture = try fixture(), row = fixture.reserve
        for rate in fixture.rates {
            let window = window(rate)
            let legacy = try VoiceLabPhraseTiming.preview(seconds: row.speechSeconds, window: window, incomingSilence: nil, outgoingSilence: nil, sourceSampleRate: rate)
            let fit = try VoiceLabPhraseTiming.preview(seconds: row.speechSeconds, window: window, incomingSilence: nil, outgoingSilence: nil, sourceSampleRate: rate, hardJoinSmoothing: true)
            #expect(abs(Double(legacy.plan.outputFrames) / Double(rate) - row.legacyOutputSeconds) < 1e-9)
            #expect(abs(Double(fit.plan.outputFrames) / Double(rate) - row.outputSeconds) < 1e-9)
            #expect(fit.plan.incoming.padFrames == Int64(row.padSeconds * Double(rate)))
            #expect(fit.plan.outgoing.padFrames == Int64(row.padSeconds * Double(rate)))
            #expect(fit.plan.windowStartSample == window.startSample && fit.plan.windowEndSample == window.endSample)
            let timing = try VoiceLabPaceMatching.match(seconds: row.speechSeconds, window: window, incomingSilence: nil, outgoingSilence: nil, sourceSampleRate: rate)
            #expect(timing.pace == row.pace && timing.fits == row.fits)
        }
    }

    @Test func speechCheckExcludesThePauseAndGainKeepsItsPeakCap() throws {
        let rate = 24_000
        let check = try fixture().joinCheck
        for pause in check.pauseSeconds {
            let seam = rate
            let edge = VoiceLabMicroPause(wordStartSeconds: -pause - 0.3, wordEndSeconds: -pause)
            let samples = (0..<(rate * 2)).map { index -> Float in
                let seconds = Double(index) / Double(rate)
                let silent = seconds >= 1 - pause && seconds < 1
                return silent ? 0 : Float(0.1 * sin(2 * Double.pi * 1_000 * seconds))
            }
            #expect(abs(try VoiceLabHardJoin.speechStep(samples, sampleRate: rate, seam: seam, pause: edge, incoming: false) - check.speechStepDb) < 1e-4)
        }
        let quiet = (0..<rate).map { Float(0.1 * sin(2 * Double.pi * 1_000 * Double($0) / Double(rate))) }
        let loud = quiet.map { $0 * 5 }
        #expect(try VoiceLabHardJoin.matchingGain(edge: quiet, source: loud, sampleRate: rate) == 6)
        let nearPeak = quiet.map { $0 * 9 }
        #expect(try VoiceLabHardJoin.matchingGain(edge: nearPeak, source: nearPeak.map { $0 * 2 }, sampleRate: rate) == 0)
        #expect(VoiceLabHardJoin.bedWeight(seconds: 1, duration: 2, words: [.init(text: "speech", start: 0.14, end: 1.86, synthetic: true)], incoming: .init(wordStartSeconds: 0.14, wordEndSeconds: 1.86), outgoing: .init(wordStartSeconds: -1.86, wordEndSeconds: -0.14)) == 1)
        let shared = VoiceLabEdgeGain(in: .init(gainDb: 6, wordSeconds: .init(wordStartSeconds: 0.14, wordEndSeconds: 0.86)), out: .init(gainDb: 6, wordSeconds: .init(wordStartSeconds: -0.86, wordEndSeconds: -0.14)))
        #expect(VoiceLabHardJoin.edgeGainDb(seconds: 0.5, duration: 1, edgeGain: shared) == 6)
    }

    @Test func acousticSearchKeepsDecayBeyondTheOldTrim() throws {
        let rate = 24_000
        let row = try fixture().acoustic
        let samples = (0..<rate).map { index -> Float in
            let seconds = Double(index) / Double(rate)
            return seconds >= row.audioStart && seconds < row.audioEnd ? Float(0.1 * sin(2 * Double.pi * 1_000 * seconds)) : 0
        }
        let words = VoiceLabHardJoin.refine(words: [.init(text: "word", start: row.alignedStart, end: row.alignedEnd, synthetic: true)], samples: samples, sampleRate: rate)
        #expect(abs(words[0].start - row.audioStart) < 0.005)
        #expect(abs(words[0].end - row.audioEnd) < 0.005)
        #expect(VoiceLabHardJoin.acousticSearchSeconds == row.searchLimitSeconds)
        #expect(try VoiceLabAlignment.trim(words: words, assetDuration: 1).end >= 0.85)
    }

    @Test func roomToneMatchesNeighbourPausesBeyondTheLegacyTwelveDbCap() throws {
        let rate = 24_000
        let row = try fixture().roomTone
        let source = (0..<(rate * 8)).map { index -> Float in
            let seconds = Double(index) / Double(rate)
            let amplitude = seconds < 0.5 ? row.runAmplitude : seconds >= 1 && seconds < 6 ? 0.1 : row.pauseAmplitude
            return Float(amplitude * sin(2 * Double.pi * 1_000 * seconds))
        }
        let input = VoiceLabTakeInput(text: "word", modelID: "fixture", recordID: "fixture", language: "en", seed: 1, contentKey: "fixture",
            source: source, sourceSampleRate: rate, items: [.init(id: "w", text: "speech", kind: .word, start: 1, end: 6)],
            window: window(rate), incomingSilence: nil, outgoingSilence: nil, providerConsent: true)
        let room = try VoiceLabHardJoin.matchedRoomTone(.init(sourceStartSample: 0, sourceEndSample: Int64(rate / 2), gainDb: 0), input: input, speechLevel: -23)
        #expect(abs(room.gainDb - row.gainDb) < 0.1)
        let filled = Array(source[0..<(rate / 2)]).map { $0 * Float(pow(10, room.gainDb / 20)) }
        let target = Array(source[(rate * 7)..<(rate * 7 + rate / 2)])
        let difference = try VoiceLabLoudness.momentaryLufs(filled, sampleRate: rate, windowStart: 0) - VoiceLabLoudness.momentaryLufs(target, sampleRate: rate, windowStart: 0)
        #expect(abs(difference) < row.toleranceLu)
    }

    @Test func seamRoundTripPreservesMicroPause() throws {
        let data = Data(#"{"kind":"hard","fadeSamples":576,"sourceHandleSamples":288,"assetHandleFrames":144,"microPause":{"wordStartSeconds":-0.44,"wordEndSeconds":-0.14}}"#.utf8)
        let seam = try JSONDecoder().decode(VoiceLabSeam.self, from: data)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(seam)) as! [String: Any]
        #expect(encoded["microPause"] != nil)
    }

    @Test func sharedReviewBedAndShortSourceFades() throws {
        struct Review: Decodable {
            struct Bed: Decodable { let seconds: Double; let expected: Double }
            struct Fade: Decodable { let rate: Double; let availableFrames: Int64; let fadeFrames: Int64 }
            let bedWeights: [Bed]
            let sourceFades: [Fade]
        }
        let review = try FixtureLoader.decode(Review.self, at: "fixtures/voice-lab/hard-join-review-cases.json")
        let words = [VoiceLabWord(text: "first", start: 0.14, end: 0.44, synthetic: true), .init(text: "second", start: 0.45, end: 1.86, synthetic: true)]
        for row in review.bedWeights {
            #expect(VoiceLabHardJoin.bedWeight(seconds: row.seconds, duration: 2, words: words,
                incoming: .init(wordStartSeconds: 0.14, wordEndSeconds: 0.44), outgoing: .init(wordStartSeconds: -1.55, wordEndSeconds: -0.14)) == row.expected)
        }
        for row in review.sourceFades {
            #expect(VoiceLabHardJoin.sourceFadeFrames(sampleRate: row.rate, availableSourceSamples: row.availableFrames) == row.fadeFrames)
            let weight = VoiceLabHardJoin.sourceWeight(secondsFromJoin: Double(row.fadeFrames) / row.rate / 2, incoming: false,
                fadeSeconds: Double(row.fadeFrames) / row.rate)
            #expect(abs(weight - sqrt(0.5)) < 1e-12)
        }
    }

    @Test(arguments: [0.0, 6.0]) func reservedPauseLevelIsAnAdvisoryIndependentOfSpeech(gainDb: Double) throws {
        let rate = 24_000
        let source = (0..<(rate * 5)).map { index -> Float in
            let amplitude = index >= rate && index < rate * 4 ? 0.1 : 0.001
            return Float(amplitude * sin(2 * Double.pi * 1_000 * Double(index) / Double(rate)))
        }
        let input = VoiceLabTakeInput(text: "word", modelID: "fixture", recordID: "fixture", language: "en", seed: 1, contentKey: "fixture",
            source: source, sourceSampleRate: rate, items: [.init(id: "w", text: "speech", kind: .word, start: 1, end: 4)],
            window: window(rate), incomingSilence: nil, outgoingSilence: nil, providerConsent: true)
        let mixed = (0..<(rate * 2)).map { Float(0.001 * pow(10, gainDb / 20) * sin(2 * Double.pi * 1_000 * Double($0) / Double(rate))) }
        let excess = try VoiceLabHardJoin.pauseExcess(mixed, sampleRate: rate, seam: rate / 2,
            pause: .init(wordStartSeconds: 0.14, wordEndSeconds: 0.44), incoming: true, input: input)
        #expect(abs(excess - gainDb) < 0.1)
        let qa = try VoiceLabTakeQuality.evaluate(expected: "word", recognized: ["word"], mixed: mixed, sampleRate: rate, seams: [rate / 2],
            sourceSeamSteps: [0], measuredSeamSteps: [0], measuredPauseExcesses: [excess], speakerScore: 1, threshold: 0.5)
        #expect(qa.hardFailures.isEmpty)
        #expect(qa.failures.contains(.loudness) == (gainDb > 2))
    }

    @Test func newRoomToneSelectionSkipsDigitalSilenceWithoutChangingLegacy() throws {
        let envelope = AudioEnvelope(sampleRate: 24_000, levels: [Float](repeating: 0, count: 50) + [Float](repeating: 0.001, count: 100))
        let legacy = try VoiceLabRoomToneSelection.select(items: [], envelope: envelope, sourceSampleRate: 24_000, totalSamples: 36_000)
        let matched = try VoiceLabRoomToneSelection.select(items: [], envelope: envelope, sourceSampleRate: 24_000, totalSamples: 36_000, excludeDigitalSilence: true)
        #expect(legacy.sourceStartSample == 0)
        #expect(matched.sourceStartSample == 12_000)
    }

    @Test(arguments: [0.0, 0.001]) func preflightKeepsDigitalSilenceOnlyForSilentNeighbours(background: Double) throws {
        let rate = 24_000
        let source = (0..<(rate * 8)).map { index -> Float in
            let seconds = Double(index) / Double(rate)
            let amplitude = seconds < 0.5 ? 0 : seconds >= 1 && seconds < 4 ? 0.1 : background
            return Float(amplitude * sin(2 * Double.pi * 1_000 * seconds))
        }
        let input = VoiceLabTakeInput(text: "word", modelID: "fixture", recordID: "fixture", language: "en", seed: 1,
            contentKey: "fixture", source: source, sourceSampleRate: rate,
            items: [.init(id: "w", text: "speech", kind: .word, start: 1, end: 4)], window: window(rate),
            incomingSilence: nil, outgoingSilence: nil, providerConsent: true)
        let room = try #require(VoiceLabTakeProcessing.preflight(input).roomTone)
        if background == 0 {
            #expect(room.sourceStartSample == 0 && room.gainDb == 0 && room.endGainDb == nil)
        } else { #expect(room.sourceStartSample >= rate / 2) }
    }
}
