import Foundation
import Testing
import VoxClipCore
@testable import VoxClipMedia

@Suite("Hard join QA staging", .serialized, .offlineFixtures)
struct VoiceLabHardJoinStagingTests {
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
