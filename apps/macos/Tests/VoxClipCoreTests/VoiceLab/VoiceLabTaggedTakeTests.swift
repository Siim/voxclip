import Foundation
import Testing
@testable import VoxClipCore

@Suite("Tagged take processing", .offlineFixtures)
struct VoiceLabTaggedTakeTests {
    private func process(tags: [VoiceLabAudioTag], burst: Bool = false, hard: Bool = true) throws -> VoiceLabTakeAnalysis {
        let rate = 24_000
        let samples = (0..<(rate * 2)).map { index -> Float in
            let active = (7_200..<19_200).contains(index) || (burst && (24_000..<28_800).contains(index))
            return active ? Float(0.1 * sin(2 * Double.pi * 200 * Double(index) / Double(rate))) : 0
        }
        var pcm = Data()
        for sample in samples {
            var value = Int16((sample * 32_768).rounded()).littleEndian
            withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
        }
        let kind: VoiceLabSeamKind = hard ? .hard : .gap
        let window = VoiceLabWindow(firstWordId: "a", lastWordId: "b", leftBridgeWordIds: [], rightBridgeWordIds: [],
            start: 1, end: 2.5, startSample: 24_000, endSample: 60_000,
            leftSeam: .init(kind: kind, time: 1, sample: 24_000, fadeSamples: 288),
            rightSeam: .init(kind: kind, time: 2.5, sample: 60_000, fadeSamples: 288))
        let input = VoiceLabTakeInput(text: "Hello there", modelID: "eleven_v3", recordID: "fixture", language: "en", seed: 1,
            contentKey: "fixture", source: [Float](repeating: 0.1, count: rate * 4), sourceSampleRate: rate, items: [], window: window,
            incomingSilence: hard ? nil : 1, outgoingSilence: hard ? nil : 1, cleanAudioOn: true, providerConsent: true, audioTags: tags)
        let receipt = VoiceLabReceipt(provider: "elevenlabs", region: .default, endpoint: "fixture", modelID: input.modelID,
            voiceID: nil, requestID: UUID(), providerRequestID: nil, spendWarning: nil)
        let result = VoiceLabAudioResult(pcm: pcm, sampleRate: rate, alignment: [
            .init(character: "Hello", start: 0.3, end: 0.5), .init(character: " ", start: 0.5, end: 0.6),
            .init(character: "there", start: 0.6, end: 0.8)], receipt: receipt)
        return try VoiceLabTakeProcessing.process(result, input: input, preflight: .init(sourceLevel: -20, roomTone: nil))
    }

    @Test(arguments: [false, true]) func midPhraseTagsKeepNormalTrim(hard: Bool) throws {
        let plain = try process(tags: [], hard: hard)
        let tagged = try process(tags: [.init(beforeToken: 1, tag: "short pause")], hard: hard)
        #expect(tagged.trimmed == plain.trimmed)
        #expect(tagged.fit.plan == plain.fit.plan)
    }

    @Test func trailingLaughSurvivesTrimAndPrecedesMicroPause() throws {
        let plain = try process(tags: [])
        let tagged = try process(tags: [.init(beforeToken: 2, tag: "laughs")], burst: true)
        #expect(tagged.trimmed.count == plain.trimmed.count + 9_600)
        #expect(tagged.trimmed.suffix(2_400).contains { abs($0) > 0.05 })
        let duration = Double(tagged.fit.plan.outputFrames) / 24_000
        let pause = try #require(VoiceLabHardJoin.pause(words: tagged.fit.plan.words, duration: duration, incoming: false))
        #expect(abs(pause.wordEndSeconds + VoiceLabPatchConstants.TTS_TRIM_TAIL) < 1e-9)
        #expect(tagged.fit.plan.words.last!.end - tagged.fit.plan.words.first!.start > 0.89)
    }

    @Test(arguments: [
        ("Hello there [laughs]", ["Hello", "Haha.", "there"], true),
        ("Ha, got you [laughs]", ["Ha,", "got", "you"], true),
        ("Ha ha [laughs]", ["Ha", "ha", "ha"], true),
        ("Ha, got you", ["Ha,", "got", "you"], true),
        ("Hello there", ["Hello", "haha", "there"], false)
    ]) func eventFilteringPreservesTypedOccurrences(expected: String, recognized: [String], passes: Bool) throws {
        let result = try VoiceLabTakeQuality.evaluate(expected: expected, recognized: recognized,
            mixed: [Float](repeating: 0.1, count: 480), sampleRate: 24_000, seams: [], speakerScore: nil, threshold: 0.5)
        #expect(!result.failures.contains(.transcript) == passes)
    }
}
