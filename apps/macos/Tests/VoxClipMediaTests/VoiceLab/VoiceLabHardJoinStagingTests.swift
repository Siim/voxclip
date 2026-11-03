import Foundation
import Testing
@testable import VoxClipCore
@testable import VoxClipMedia

@Suite("Hard join QA staging", .serialized, .offlineFixtures)
struct VoiceLabHardJoinStagingTests {
    @Test func taggedLaughKeepsGeneratedWeightThroughStaging() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let rate = 24_000
        let samples = (0..<(rate * 2)).map { index -> Float in
            let active = (7_200..<19_200).contains(index) || (24_000..<28_800).contains(index)
            return active ? Float(0.1 * sin(2 * Double.pi * 200 * Double(index) / Double(rate))) : 0
        }
        var pcm = Data()
        for sample in samples {
            var value = Int16((sample * 32_768).rounded()).littleEndian
            withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
        }
        let window = VoiceLabWindow(firstWordId: "a", lastWordId: "b", leftBridgeWordIds: [], rightBridgeWordIds: [],
            start: 1, end: 2.5, startSample: 24_000, endSample: 60_000,
            leftSeam: .init(kind: .hard, time: 1, sample: 24_000, fadeSamples: 288),
            rightSeam: .init(kind: .hard, time: 2.5, sample: 60_000, fadeSamples: 288))
        let source = (0..<(rate * 4)).map { index -> Float in
            Float(0.1 * sin(2 * Double.pi * 200 * Double(index) / Double(rate)))
        }
        let input = VoiceLabTakeInput(text: "Hello there", modelID: "eleven_v3", recordID: "fixture", language: "en", seed: 1,
            contentKey: "fixture", source: source, sourceSampleRate: rate, items: [], window: window,
            incomingSilence: nil, outgoingSilence: nil, cleanAudioOn: true, providerConsent: true,
            audioTags: [.init(beforeToken: 2, tag: "laughs")])
        let receipt = VoiceLabReceipt(provider: "elevenlabs", region: .default, endpoint: "fixture", modelID: input.modelID,
            voiceID: nil, requestID: UUID(), providerRequestID: nil, spendWarning: nil)
        let result = VoiceLabAudioResult(pcm: pcm, sampleRate: rate, alignment: [
            .init(character: "Hello", start: 0.3, end: 0.5), .init(character: " ", start: 0.5, end: 0.6),
            .init(character: "there", start: 0.6, end: 0.8)], receipt: receipt)
        let analysis = try VoiceLabTakeProcessing.process(result, input: input, preflight: .init(sourceLevel: -20, roomTone: nil))
        let project = "5b7e0f7a-3c1d-4b8e-9a51-2f6d0c8e4a11"
        let paid = try VoiceLabAssetStore.writeWave(pcm: pcm, sampleRate: rate, channels: 1, bits: 16, floating: false,
            projectId: project, assetId: "tagged", paidRoot: root, createdAt: Date(timeIntervalSince1970: 0))
        let snapshot = try VoiceLabAssets.preparePaid(asset: paid, projectId: project, paidRoot: root, scratchRoot: root)
        let fitted = try VoiceLabSilenceFit.prepare(snapshot: snapshot, paidAsset: paid, fit: analysis.fit, window: window, sourceSampleRate: rate)
        let scratch = try VoiceLabAudioRenderer.stageTake(fitted: fitted, analysis: analysis, input: input,
            sourceAtAssetRate: .init(whole: source), scratchRoot: root)
        let audio = scratch.audio
        let wordStart = try #require(audio.fit.plan.words.first?.start)
        for assetFrame in stride(from: 24_030, to: 28_560, by: 120) {
            let seconds = wordStart + Double(assetFrame) / Double(rate) - 0.3
            #expect(VoiceLabHardJoin.generatedWeight(seconds: seconds, duration: fitted.outDuration,
                incoming: audio.microPauseIn, outgoing: audio.microPauseOut) > 0)
            let mixedFrame = audio.patchRange.lowerBound + Int((seconds * Double(rate)).rounded())
            #expect(abs(audio.mixed[mixedFrame]) > 0.01)
        }
    }
    private struct Fixture: Decodable {
        struct Gating: Decodable { let amplitude: Double; let gain: Bool; let advisory: Bool }
        let gating: [Gating]
    }
    @Test(arguments: [0.1, 0.07, 0.01]) func gainIsGatedAndNeverBaked(amplitude: Double) throws {
        let row = try #require(JSONDecoder().decode(Fixture.self, from: FixtureLoader.data("fixtures/voice-lab/hard-join-cases.json")).gating.first { $0.amplitude == amplitude })
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let rate = 24_000
        var window = VoiceLabWindow(firstWordId: "w", lastWordId: "w", leftBridgeWordIds: [], rightBridgeWordIds: [],
            start: 2, end: 3, startSample: 48_000, endSample: 72_000,
            leftSeam: .init(kind: .hard, time: 2, sample: 48_000, fadeSamples: 288),
            rightSeam: .init(kind: .hard, time: 3, sample: 72_000, fadeSamples: 288))
        if amplitude == 0.07 {
            window.end += 1.0 / 48_000; window.endSample += 1
            window.rightSeam.time = window.end; window.rightSeam.sample = window.endSample
        }
        let samples = (0..<rate).map { Float(amplitude * sin(2 * Double.pi * 1_000 * Double($0) / Double(rate))) }
        let source = (0..<(rate * 5)).map { Float(0.1 * sin(2 * Double.pi * 1_000 * Double($0) / Double(rate))) }
        let words = [VoiceLabWord(text: "new", start: 0.14, end: 0.4, synthetic: true), .init(text: "words", start: 0.6, end: 0.86, synthetic: true)]
        let take = VoiceLabFitTake(assetFrames: Int64(rate), assetSampleRate: rate, trimStart: 0, trimEnd: 1, words: words,
            envelope: VoiceLabTakeProcessing.envelope(samples, sampleRate: rate))
        let fit = try VoiceLabFitPlanner.plan(window: window, incomingSilence: nil, outgoingSilence: nil,
            take: take, tokens: ["new", "words"], sourceSampleRate: Double(rate), hardJoinSmoothing: true)
        let project = "5b7e0f7a-3c1d-4b8e-9a51-2f6d0c8e4a11"
        var pcm = Data()
        for sample in samples { withUnsafeBytes(of: sample.bitPattern.littleEndian) { pcm.append(contentsOf: $0) } }
        let paid = try VoiceLabAssetStore.writeWave(pcm: pcm, sampleRate: rate, channels: 1, bits: 32, floating: true,
            projectId: project, assetId: "paid", paidRoot: root, createdAt: Date(timeIntervalSince1970: 0))
        let snapshot = try VoiceLabAssets.preparePaid(asset: paid, projectId: project, paidRoot: root, scratchRoot: root)
        let fitted = try VoiceLabSilenceFit.prepare(snapshot: snapshot, paidAsset: paid, fit: fit, window: window, sourceSampleRate: rate)
        let before = fitted.wave.bytes
        let input = VoiceLabTakeInput(text: "new words", modelID: "fixture", recordID: "fixture", language: "en", seed: 1,
            contentKey: "fixture", source: source, sourceSampleRate: rate, items: [], window: window,
            incomingSilence: nil, outgoingSilence: nil, cleanAudioOn: true, providerConsent: true)
        let analysis = VoiceLabTakeAnalysis(sampleRate: rate, trimmed: samples, gainDb: 0, roomTone: nil, fit: fit)
        let scratch = try VoiceLabAudioRenderer.stageTake(fitted: fitted, analysis: analysis, input: input, sourceAtAssetRate: .init(whole: source), scratchRoot: root)
        #expect(fitted.wave.bytes == before)
        #expect(scratch.audio.microPauseIn != nil && scratch.audio.microPauseOut != nil)
        #expect(scratch.audio.microPauseOut == VoiceLabHardJoin.pause(words: fit.plan.words, duration: fitted.outDuration, incoming: false))
        #expect((scratch.audio.edgeGain != nil) == row.gain)
        if let gain = scratch.audio.edgeGain { #expect(gain.in!.gainDb <= 6 && gain.out!.gainDb <= 6) }
        let audio = scratch.audio
        let qa = try VoiceLabTakeQuality.evaluate(expected: "new words", recognized: ["new", "words"], mixed: audio.mixed,
            sampleRate: rate, seams: audio.seams, sourceSeamSteps: audio.sourceSeamSteps,
            sourceSeamPauses: audio.sourceSeamPauses, measuredSeamSteps: audio.measuredSeamSteps, speakerScore: 1, threshold: 0.5)
        #expect(qa.hardFailures.isEmpty)
        #expect(qa.failures.contains(.loudness) == row.advisory)
        let failed = try VoiceLabTakeQuality.evaluate(expected: "new words", recognized: ["wrong"], mixed: audio.mixed,
            sampleRate: rate, seams: audio.seams, sourceSeamSteps: audio.sourceSeamSteps,
            measuredSeamSteps: audio.measuredSeamSteps, speakerScore: 0, threshold: 0.5)
        #expect(!failed.hardFailures.isEmpty)
    }
}
