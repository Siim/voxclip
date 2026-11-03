import Foundation
import Testing
@testable import VoxClipCore

/// A take run reads only regions of a long source (voice-lab.md §8.7); the preflight must read the same level and
/// room tone from them as from the whole track.
@Suite(.offlineFixtures) struct VoiceLabSourceExcerptTests {
    private let rate = 8_000
    /// 30 s of tone with a quiet stretch at 24.9–26 s; the words leave a gap only at 25.0–25.8 s.
    private func source() -> [Float] {
        (0..<(30 * rate)).map { index in
            let seconds = Double(index) / Double(rate)
            return (24.9..<26).contains(seconds) ? 0.001 : Float(0.1 * sin(2 * Double.pi * 100 * seconds))
        }
    }
    private func input(_ source: VoiceLabSourceExcerpt, envelope: AudioEnvelope) -> VoiceLabTakeInput {
        let items = [TimedWord(id: "before", text: "before", kind: .word, start: 0, end: 12),
                     TimedWord(id: "old", text: "old", kind: .word, start: 12, end: 13),
                     TimedWord(id: "after", text: "after", kind: .word, start: 13, end: 25),
                     TimedWord(id: "last", text: "last", kind: .word, start: 25.8, end: 30)]
        let window = VoiceLabWindow(firstWordId: "old", lastWordId: "old", leftBridgeWordIds: [], rightBridgeWordIds: [], start: 12, end: 13,
            startSample: 96_000, endSample: 104_000, leftSeam: .init(kind: .hard, time: 12, sample: 96_000, fadeSamples: 96),
            rightSeam: .init(kind: .hard, time: 13, sample: 104_000, fadeSamples: 96))
        return VoiceLabTakeInput(text: "Hello", modelID: "eleven_v3", recordID: "record", language: "en", seed: 1, contentKey: "synthetic-source",
            source: source, sourceEnvelope: envelope, sourceSampleRate: rate, items: items, window: window,
            incomingSilence: nil, outgoingSilence: nil, providerConsent: true)
    }

    @Test func preflightReadsTheSameLevelAndRoomToneFromRegions() throws {
        let whole = source()
        let envelope = VoiceLabTakeProcessing.envelope(whole, sampleRate: rate)
        let expected = try VoiceLabTakeProcessing.preflight(input(VoiceLabSourceExcerpt(whole: whole), envelope: envelope))
        let regions = VoiceLabSourceExcerpt(totalFrames: whole.count, regions: [
            .init(start: 8 * rate, samples: Array(whole[(8 * rate)..<(17 * rate)])),
            .init(start: 24 * rate, samples: Array(whole[(24 * rate)..<(27 * rate)])),
        ])
        let actual = try VoiceLabTakeProcessing.preflight(input(regions, envelope: envelope))
        #expect(actual.sourceLevel == expected.sourceLevel)
        #expect(actual.roomTone == expected.roomTone && actual.roomTone?.sourceStartSample == 200_000)
    }

    /// Live 2026-11-03 (car vlog): the take's quietest half second sat 8 to 14 dB under the noise in the pauses beside the
    /// windows, so pads and pauses under the patch dipped. The loop plays at the background measured at the seams.
    @Test func roomToneLoopsAtTheBackgroundBesideTheSeams() throws {
        let floor: Float = 0.003
        let whole: [Float] = (0..<(30 * rate)).map { index in
            let seconds = Double(index) / Double(rate)
            if (24.9..<26).contains(seconds) { return 0.001 }
            if (11.5..<12).contains(seconds) || (13..<13.5).contains(seconds) { return index.isMultiple(of: 2) ? floor : -floor }
            return Float(0.1 * sin(2 * Double.pi * 100 * seconds))
        }
        let items = [TimedWord(id: "before", text: "before", kind: .word, start: 0, end: 11.5),
                     TimedWord(id: "old", text: "old", kind: .word, start: 12, end: 13),
                     TimedWord(id: "after", text: "after", kind: .word, start: 13.5, end: 25),
                     TimedWord(id: "last", text: "last", kind: .word, start: 25.8, end: 30)]
        let window = VoiceLabWindow(firstWordId: "old", lastWordId: "old", leftBridgeWordIds: [], rightBridgeWordIds: [], start: 12, end: 13,
            startSample: 96_000, endSample: 104_000, leftSeam: .init(kind: .gap, time: 12, sample: 96_000, fadeSamples: 160),
            rightSeam: .init(kind: .gap, time: 13, sample: 104_000, fadeSamples: 160))
        let input = VoiceLabTakeInput(text: "Hello", modelID: "eleven_multilingual_v2", recordID: "record", language: "en", seed: 1,
            contentKey: "synthetic-source", source: whole, sourceSampleRate: rate, items: items, window: window,
            incomingSilence: 0.5, outgoingSilence: 0.5, providerConsent: true)
        let tone = try #require(try VoiceLabTakeProcessing.preflight(input).roomTone)
        #expect(tone.sourceStartSample == 200_000)
        #expect(abs(tone.gainDb - 20 * log10(3.0)) < 1e-3)
        // A seam in speech has no background to match: the loop keeps its natural level.
        #expect(try VoiceLabTakeProcessing.preflight(self.input(VoiceLabSourceExcerpt(whole: source()),
            envelope: VoiceLabTakeProcessing.envelope(source(), sampleRate: rate))).roomTone?.gainDb == 0)
        #expect(try VoiceLabLoudness.roomToneGainDb(seamBackgroundRmsDb: 0, run: [0.001]) == 12)
        #expect(try VoiceLabLoudness.roomToneGainDb(seamBackgroundRmsDb: nil, run: [0.001]) == 0)
    }

    @Test func preflightRefusesRegionsWithoutTheLoudnessNeighbourhood() throws {
        let whole = source()
        let envelope = VoiceLabTakeProcessing.envelope(whole, sampleRate: rate)
        let short = VoiceLabSourceExcerpt(totalFrames: whole.count, regions: [.init(start: 11 * rate, samples: Array(whole[(11 * rate)..<(14 * rate)]))])
        #expect(throws: VoiceLabAudioMathError.invalidInput) { try VoiceLabTakeProcessing.preflight(input(short, envelope: envelope)) }
    }

    @Test func samplesAreReadAtAbsoluteFrames() {
        let excerpt = VoiceLabSourceExcerpt(totalFrames: 100, regions: [.init(start: 60, samples: [6, 7, 8]), .init(start: 10, samples: [1, 2, 3, 4])])
        #expect(excerpt.regions.map(\.start) == [10, 60])
        #expect(excerpt.samples(11..<13).map(Array.init) == [2, 3])
        #expect(excerpt.samples(14..<14).map(Array.init) == [])
        #expect(excerpt.samples(12..<15) == nil && excerpt.samples(0..<1) == nil && excerpt.samples(62..<101) == nil)
        #expect(VoiceLabSourceExcerpt(whole: [1, 2]).samples(0..<2).map(Array.init) == [1, 2])
    }
}
