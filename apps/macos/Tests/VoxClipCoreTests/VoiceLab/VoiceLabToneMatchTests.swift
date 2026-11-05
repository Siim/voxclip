#if DEBUG
import Foundation
import Testing
@testable import VoxClipCore

/// The tone match in take processing (voice-lab §8.7 item 2b): a generated take is tilted towards the speech beside it
/// before its gain is measured; the user's own recorded take is left as it is.
@Suite("Tone match in take processing", .offlineFixtures)
struct VoiceLabToneMatchTests {
    private static let rate = 24_000

    /// Two seconds of a darker take (the mean of four noise samples) at 24 kHz, timed as "Hello there" from 0.3 to 0.8 s.
    private func take() -> VoiceLabAudioResult {
        let samples = VoiceLabTiltReplayTests.render(.init(seed: 11, samples: Self.rate * 2, shape: "dark", shift: 2, quiet: nil))
        var pcm = Data()
        for sample in samples {
            var value = Int16((sample * 32_767).rounded()).littleEndian
            withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
        }
        let receipt = VoiceLabReceipt(provider: "elevenlabs", region: .default, endpoint: "fixture", modelID: "eleven_v3",
            voiceID: nil, requestID: UUID(), providerRequestID: nil, spendWarning: nil)
        return VoiceLabAudioResult(pcm: pcm, sampleRate: Self.rate, alignment: [
            .init(character: "Hello", start: 0.3, end: 0.5), .init(character: " ", start: 0.5, end: 0.6),
            .init(character: "there", start: 0.6, end: 0.8)], receipt: receipt)
    }
    private func input() -> VoiceLabTakeInput {
        let window = VoiceLabWindow(firstWordId: "a", lastWordId: "b", leftBridgeWordIds: [], rightBridgeWordIds: [],
            start: 1, end: 2.5, startSample: 24_000, endSample: 60_000,
            leftSeam: .init(kind: .gap, time: 1, sample: 24_000, fadeSamples: 288),
            rightSeam: .init(kind: .gap, time: 2.5, sample: 60_000, fadeSamples: 288))
        return VoiceLabTakeInput(text: "Hello there", modelID: "eleven_v3", recordID: "fixture", language: "en", seed: 1,
            contentKey: "fixture", source: [Float](repeating: 0.1, count: Self.rate * 4), sourceSampleRate: Self.rate, items: [], window: window,
            incomingSilence: 1, outgoingSilence: 1, cleanAudioOn: true, providerConsent: true, hardJoinSmoothing: false, audioTags: [])
    }
    /// The brighter original speech beside the window: white noise on both sides.
    private func preflight() -> VoiceLabTakePreflight {
        let source = VoiceLabTiltReplayTests.render(.init(seed: 12, samples: Self.rate * 4, shape: "white", shift: 2, quiet: nil))
        let bands = VoiceLabTilt.neighbourhoodBands(VoiceLabSourceExcerpt(whole: source), sampleRate: Self.rate, window: 24_000..<60_000)
        return VoiceLabTakePreflight(sourceLevel: -20, roomTone: nil, sourceTone: bands)
    }

    @Test func aGeneratedTakeIsTiltedBeforeItsGainIsMeasured() throws {
        let plain = try VoiceLabTakeProcessing.process(take(), input: input(), preflight: preflight())
        let matched = try VoiceLabTakeProcessing.process(take(), input: input(), preflight: preflight(), matchTone: true)
        #expect(plain.tiltDbPerOctave == nil, "a recorded take (and every caller that doesn't ask) is left as it is")
        // The take is about 2 dB/octave darker than the speech beside it: the tilt is the clamp's most.
        #expect(matched.tiltDbPerOctave == 2)
        #expect(matched.trimmed.count == plain.trimmed.count && matched.trimmed != plain.trimmed)
        // The cascade ran from the asset's first frame, then the trim was taken.
        let samples: [Float] = take().pcm.withUnsafeBytes { bytes in
            (0..<(bytes.count / 2)).map { Float(Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self))) / 32_768 }
        }
        let start = try #require(samples.indices.first { Array(samples[$0..<min(samples.count, $0 + plain.trimmed.count)]) == plain.trimmed })
        let tilted = VoiceLabTilt.apply(samples, sections: VoiceLabTilt.sections(tiltDbPerOctave: 2, sampleRate: Self.rate))
        #expect(Array(tilted[start..<(start + matched.trimmed.count)]) == matched.trimmed)
        // The level is measured on the tilted take, so the gain still meets the speech beside it.
        let gain = try VoiceLabLoudness.levelGainDb(sourceVoicedRmsDb: -20,
            candidateVoicedRmsDb: VoiceLabLoudness.voicedRmsDb(matched.trimmed, sampleRate: Self.rate),
            candidateTruePeakDbtp: VoiceLabLoudness.truePeakDbtp(matched.trimmed, sampleRate: Self.rate))
        #expect(matched.gainDb == gain && matched.gainDb != plain.gainDb)
    }

    @Test func withoutTheSpeechBesideItNothingIsTilted() throws {
        let unmeasured = VoiceLabTakePreflight(sourceLevel: -20, roomTone: nil)
        let matched = try VoiceLabTakeProcessing.process(take(), input: input(), preflight: unmeasured, matchTone: true)
        #expect(matched.tiltDbPerOctave == nil)
        let silent = VoiceLabTakePreflight(sourceLevel: -20, roomTone: nil,
            sourceTone: VoiceLabTilt.neighbourhoodBands(VoiceLabSourceExcerpt(whole: [Float](repeating: 0, count: Self.rate * 4)),
                                                         sampleRate: Self.rate, window: 24_000..<60_000))
        #expect(try VoiceLabTakeProcessing.process(take(), input: input(), preflight: silent, matchTone: true).tiltDbPerOctave == nil)
    }

    @Test func aStoredTiltIsValidatedWhereverTheSegmentIsRead() throws {
        for (value, valid) in [(nil, true), (0.1, true), (-2.0, true), (0.0, false), (2.1, false), (Double.nan, false)] as [(Double?, Bool)] {
            let audio = VoiceLabAudio(assetId: "a", trimStart: 0, trimEnd: 1, tiltDbPerOctave: value)
            #expect(audio.tiltIsValid == valid, "\(String(describing: value))")
        }
        // Absent, the wire and the fingerprint are unchanged; present, it is one more key.
        let plain = try JSONSerialization.jsonObject(with: JSONEncoder().encode(VoiceLabAudio(assetId: "a", trimStart: 0, trimEnd: 1))) as? [String: Any]
        #expect(plain?["tiltDbPerOctave"] == nil && plain?.count == 5)
        let tilted = try JSONSerialization.jsonObject(with: JSONEncoder().encode(VoiceLabAudio(assetId: "a", trimStart: 0, trimEnd: 1, tiltDbPerOctave: 1.2))) as? [String: Any]
        #expect(tilted?["tiltDbPerOctave"] as? Double == 1.2)
    }
}
#endif
