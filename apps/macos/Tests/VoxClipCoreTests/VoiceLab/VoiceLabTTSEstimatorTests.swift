import Foundation
import Testing
@testable import VoxClipCore

/// The text-to-voice length estimator (ADR-R43): the calibrated prior, the calibration's robust median and spread, the
/// cross-project voice store and the p80 word budget, replayed from `tts-estimator-cases.json`.
@Suite("Text-to-voice length estimator", .offlineFixtures)
struct VoiceLabTTSEstimatorTests {
    struct Vectors: Decodable {
        struct Prior: Decodable {
            let version: Int; let providerSpeechRateMultiplier: Double; let onsetSeconds: Double; let sentencePauseSeconds: Double
            let clausePauseSeconds: Double; let trimLeadSeconds: Double; let trimTailSeconds: Double; let priorSpread: Double
            let ratioBounds: [Double]; let spreadBounds: [Double]; let voiceSampleLimit: Int; let projectSampleLimit: Int; let voiceWeight: Int
        }
        struct Estimate: Decodable { let id: String; let text: String; let rate: Double; let letters: Int; let pauseSeconds: Double; let expectedSeconds: Double }
        struct Real: Decodable { let id: String; let text: String; let rate: Double; let observedSeconds: Double; let oldEstimateSeconds: Double; let expectedSeconds: Double }
        struct Calibration: Decodable {
            let id: String; let project: [Double]; let voice: [Double]; let robustProject: [Double]; let merged: [Double]
            let multiplier: Double; let spread: Double
        }
        struct Target: Decodable {
            let id: String; let wordsPerSecond: Double; let multiplier: Double; let minimumSeconds: Double; let maximumSeconds: Double
            let overheadSeconds: Double; let bridgeWords: Int; let spread: Double; let expected: VoiceLabWordTarget
        }
        let schema: String; let caseCount: Int; let prior: Prior
        let estimates: [Estimate]; let real: [Real]; let calibration: [Calibration]; let wordTargets: [Target]
    }

    static func vectors() throws -> Vectors {
        try JSONDecoder().decode(Vectors.self, from: FixtureLoader.data("fixtures/voice-lab/tts-estimator-cases.json"))
    }
    static func samples(_ ratios: [Double], prefix: String) -> [VoiceLabRateSample] {
        ratios.enumerated().map { VoiceLabRateSample(id: "\(prefix)\($0.offset)", ratio: $0.element) }
    }

    @Test func thePriorMatchesTheSharedConstants() throws {
        let vectors = try Self.vectors()
        #expect(vectors.schema == "voxclip-tts-estimator/1")
        #expect(vectors.caseCount == vectors.estimates.count + vectors.real.count + vectors.calibration.count + vectors.wordTargets.count)
        let prior = vectors.prior
        #expect(prior.version == VoiceLabPhraseTiming.priorVersion)
        #expect(prior.providerSpeechRateMultiplier == VoiceLabPhraseTiming.providerSpeechRateMultiplier)
        #expect(prior.onsetSeconds == VoiceLabPhraseTiming.onsetSeconds)
        #expect(prior.sentencePauseSeconds == VoiceLabPhraseTiming.sentencePauseSeconds)
        #expect(prior.clausePauseSeconds == VoiceLabPhraseTiming.clausePauseSeconds)
        #expect(prior.trimLeadSeconds == VoiceLabPatchConstants.TTS_TRIM_LEAD && prior.trimTailSeconds == VoiceLabPatchConstants.TTS_TRIM_TAIL)
        #expect(prior.priorSpread == VoiceLabRateCalibration.priorSpread)
        #expect(prior.ratioBounds == [VoiceLabRateCalibration.ratioBounds.lowerBound, VoiceLabRateCalibration.ratioBounds.upperBound])
        #expect(prior.spreadBounds == [VoiceLabRateCalibration.spreadBounds.lowerBound, VoiceLabRateCalibration.spreadBounds.upperBound])
        #expect(prior.voiceSampleLimit == VoiceLabRateCalibration.voiceSampleLimit)
        #expect(prior.projectSampleLimit == VoiceLabWordingFit.projectSampleLimit)
        #expect(prior.voiceWeight == VoiceLabRateCalibration.voiceWeight)
    }

    @Test func estimatesAndPausesReplayTheSharedVectors() throws {
        for row in try Self.vectors().estimates {
            #expect(VoiceLabTextLength.length(row.text) == row.letters, "\(row.id)")
            #expect(abs(VoiceLabPhraseTiming.pauseSeconds(row.text) - row.pauseSeconds) < 1e-12, "\(row.id)")
            let estimate = try VoiceLabPhraseTiming.estimate(text: row.text, rate: row.rate)
            #expect(abs(estimate - row.expectedSeconds) < 1e-12, "\(row.id)")
        }
    }

    /// The regression the user hit: the 1.8 prior planned real Eleven v4 takes at about half their length. On the bin
    /// medians of measured takes it misses by more than 40%; the calibrated prior is within 15%.
    @Test func theOldPriorMissesRealTakesAndTheNewOneFits() throws {
        let rows = try Self.vectors().real
        #expect(rows.count == 4)
        for row in rows {
            #expect(row.observedSeconds / row.oldEstimateSeconds - 1 > 0.4, "\(row.id)")
            let estimate = try VoiceLabPhraseTiming.estimate(text: row.text, rate: row.rate)
            #expect(abs(estimate - row.expectedSeconds) < 1e-12, "\(row.id)")
            #expect(abs(estimate / row.observedSeconds - 1) <= 0.15, "\(row.id)")
        }
    }

    @Test func calibrationIsRobustBoundedAndStartsFromTheVoice() throws {
        for row in try Self.vectors().calibration {
            let project = Self.samples(row.project, prefix: "p"), voice = Self.samples(row.voice, prefix: "v")
            let robust = VoiceLabRateCalibration.robustRatios(project, limit: VoiceLabWordingFit.projectSampleLimit)
            #expect(robust == row.robustProject, "\(row.id)")
            let merged = VoiceLabRateCalibration.samples(project: project, voice: voice)
            #expect(merged.map(\.ratio) == row.merged, "\(row.id)")
            #expect(abs(VoiceLabWordingFit.multiplier(merged) - row.multiplier) < 1e-12, "\(row.id)")
            #expect(abs(VoiceLabRateCalibration.spread(project: project, voice: voice) - row.spread) < 1e-12, "\(row.id)")
        }
    }

    @Test func wordTargetsAimAtTheP80() throws {
        for row in try Self.vectors().wordTargets {
            let target = try VoiceLabWordingFit.wordTarget(wordsPerSecond: row.wordsPerSecond, multiplier: row.multiplier,
                minimumSeconds: row.minimumSeconds, maximumSeconds: row.maximumSeconds, overheadSeconds: row.overheadSeconds,
                bridgeWords: row.bridgeWords, spread: row.spread)
            #expect(target == row.expected, "\(row.id)")
        }
        // The default budget is the prior's p80: fewer words than a median budget, and a phrase at its maximum is
        // estimated at or under the slot divided by the spread.
        let median = try VoiceLabWordingFit.wordTarget(wordsPerSecond: 2.5, multiplier: 1, minimumSeconds: 2, maximumSeconds: 6,
            overheadSeconds: 0.49, spread: 1)
        let p80 = try VoiceLabWordingFit.wordTarget(wordsPerSecond: 2.5, multiplier: 1, minimumSeconds: 2, maximumSeconds: 6, overheadSeconds: 0.49)
        #expect(p80.maximum < median.maximum)
        let speechPerWord = 1 / (2.5 * VoiceLabPhraseTiming.providerSpeechRateMultiplier)
        let p80Seconds = VoiceLabRateCalibration.p80(seconds: Double(p80.maximum) * speechPerWord + 0.49)
        #expect(p80Seconds <= 6)
        #expect(VoiceLabRateCalibration.p80(seconds: Double(median.maximum) * speechPerWord + 0.49) > 6)
        #expect(throws: VoiceLabLengthBudgetError.invalidInput) {
            _ = try VoiceLabWordingFit.wordTarget(wordsPerSecond: 2, multiplier: 1, minimumSeconds: 1, maximumSeconds: 2, overheadSeconds: 0, spread: 0.9)
        }
    }

    /// The 3 November phrases are another speaker and an older model. The prior, fitted on the user's own voice,
    /// overshoots them; two measured takes of that voice bring the third within 15%, which is why calibration is per voice.
    @Test func anotherVoiceIsCorrectedByItsOwnTakes() throws {
        struct Document: Decodable {
            struct Row: Decodable { let id: String; let text: String; let rate: Double; let measuredVoicedSeconds: [Double] }
            let schema: String; let caseCount: Int; let cases: [Row]
        }
        let document = try FixtureLoader.decode(Document.self, at: "fixtures/voice-lab/phrase-timing-cases.json")
        #expect(document.schema == "voxclip-phrase-timing/1" && document.caseCount == 3)
        var voice = VoiceLabVoiceCalibration(recordId: "other-voice")
        for row in document.cases.prefix(2) {
            let estimate = try VoiceLabPhraseTiming.estimate(text: row.text, rate: row.rate)
            #expect(estimate > row.measuredVoicedSeconds.max() ?? 0)
            let measured = row.measuredVoicedSeconds.reduce(0, +) / Double(row.measuredVoicedSeconds.count)
            voice = voice.recording("eleven_multilingual_v2", id: row.id, measured: measured, estimated: estimate)
        }
        let third = try #require(document.cases.last)
        let samples = VoiceLabRateCalibration.samples(project: [], voice: voice.samples("eleven_multilingual_v2"))
        let calibrated = try VoiceLabPhraseTiming.estimate(text: third.text, rate: third.rate) * VoiceLabWordingFit.multiplier(samples)
        #expect(abs(calibrated / third.measuredVoicedSeconds[0] - 1) <= 0.15)
    }

    @Test func voiceCalibrationWireBoundsAndModels() throws {
        var calibration = VoiceLabVoiceCalibration(recordId: "73fcf5fb-5e39-463e-9268-104cecb231f2")
        calibration = calibration.recording("eleven_v4", id: "a", measured: 2, estimated: 2)
        calibration = calibration.recording("eleven_v4", id: "a", measured: 3, estimated: 2)
        calibration = calibration.recording("eleven_v4", id: "far", measured: 9, estimated: 2)
        calibration = calibration.recording("eleven_v4", id: "nan", measured: .nan, estimated: 2)
        calibration = calibration.recording("", id: "b", measured: 2, estimated: 2)
        calibration = calibration.recording("eleven_v3", id: "b", measured: 3, estimated: 2)
        #expect(calibration.samples("eleven_v4") == [VoiceLabRateSample(id: "a", ratio: 1)])
        #expect(calibration.samples("eleven_v3") == [VoiceLabRateSample(id: "b", ratio: 1.5)])
        for index in 0..<40 { calibration = calibration.recording("eleven_v4", id: "t\(index)", measured: 1 + Double(index) / 100, estimated: 1) }
        #expect(calibration.samples("eleven_v4").count == 30 && calibration.samples("eleven_v4").first?.id == "t10")
        // The wire: schema, record, prior and per-model samples, sorted keys.
        let data = try calibration.encoded()
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["schema", "recordId", "prior", "models", "seeded"])
        #expect(object["schema"] as? String == "voxclip-voice-rate-calibration/1" && object["prior"] as? Int == 2)
        #expect(try VoiceLabVoiceCalibration.decode(data, recordId: calibration.recordId) == calibration)
        #expect(throws: VoiceLabLengthBudgetError.invalidInput) { _ = try VoiceLabVoiceCalibration.decode(data, recordId: "someone-else") }
        // Ratios against another prior are dropped, out-of-bounds ratios too.
        var old = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        old["prior"] = 1
        let stale = try VoiceLabVoiceCalibration.decode(JSONSerialization.data(withJSONObject: old), recordId: calibration.recordId)
        #expect(stale.models.isEmpty && !stale.seeded)
        var edited = old
        edited["prior"] = 2
        edited["models"] = ["eleven_v4": [["id": "x", "ratio": 9.0], ["id": "y", "ratio": 1.1]], "": [["id": "z", "ratio": 1.0]]]
        let cleaned = try VoiceLabVoiceCalibration.decode(JSONSerialization.data(withJSONObject: edited), recordId: calibration.recordId)
        #expect(cleaned.models == ["eleven_v4": [VoiceLabRateSample(id: "y", ratio: 1.1)]])
    }

    @Test func storeKeepsEachVoiceBesideTheConsentRecords() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-rate-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let locations = DataLocations(environment: ["VOXCLIP_DATA_DIR": root.path])
        let store = VoiceLabRateCalibrationStore(locations: locations)
        #expect(store.root == root.appendingPathComponent("VoiceLab/calibration", isDirectory: true))
        #expect(await store.load("voice-a") == VoiceLabVoiceCalibration(recordId: "voice-a"))
        try await store.record("voice-a", model: "eleven_v4", take: "t1", measured: 2.2, estimated: 2)
        try await store.record("voice-a", model: "eleven_v4", take: "t2", measured: 1.8, estimated: 2)
        try await store.record("voice-b", model: "eleven_v4", take: "t1", measured: 3, estimated: 2)
        let all = await store.all()
        #expect(Set(all.keys) == ["voice-a", "voice-b"])
        #expect(all["voice-a"]?.samples("eleven_v4").map(\.id) == ["t1", "t2"])
        #expect(VoiceLabRateCalibrationStore.isValid(recordId: "73fcf5fb-5e39-463e-9268-104cecb231f2"))
        for bad in ["", "../x", "a/b", "a.json", String(repeating: "a", count: 129)] {
            #expect(!VoiceLabRateCalibrationStore.isValid(recordId: bad))
        }
        await #expect(throws: VoiceLabLengthBudgetError.invalidInput) { try await store.save(VoiceLabVoiceCalibration(recordId: "../escape")) }
        // A corrupt file reads as empty and the next take writes a clean one.
        try Data("{".utf8).write(to: store.root.appendingPathComponent("voice-a.json"))
        #expect(await store.load("voice-a").models.isEmpty)
        try await store.record("voice-a", model: "eleven_v4", take: "t3", measured: 2, estimated: 2)
        #expect(await store.load("voice-a").samples("eleven_v4").map(\.id) == ["t3"])
    }

    /// A new project starts from its voice's calibration: its first estimate already carries the voice's ratio.
    @Test func aNewProjectsEstimateUsesTheStoredVoiceCalibration() throws {
        var voice = VoiceLabVoiceCalibration(recordId: "voice")
        for (index, ratio) in [1.3, 1.25, 1.35, 1.28, 1.32].enumerated() {
            voice = voice.recording("eleven_v4", id: "take\(index)", measured: ratio * 2, estimated: 2)
        }
        var fresh = try ProjectJSON.decode(FixtureLoader.data("fixtures/music/music-project.voxclip"))
        fresh.voiceLab.speakingRateSamples = nil
        let samples = VoiceLabRateCalibration.samples(project: fresh, model: "eleven_v4", voice: voice)
        #expect(abs(VoiceLabWordingFit.multiplier(samples) - 1.3) < 1e-12)
        #expect(VoiceLabWordingFit.multiplier(VoiceLabRateCalibration.samples(project: fresh, model: "eleven_v4", voice: nil)) == 1)
        #expect(VoiceLabWordingFit.multiplier(VoiceLabRateCalibration.samples(project: fresh, model: "eleven_v3", voice: voice)) == 1)
        // Samples under the bare model ID are the 1.8 prior's and are not read; the current prior's key is.
        var old = fresh
        old.voiceLab.speakingRateSamples = ["eleven_v4": Self.samples([2.59, 1.75, 2.17, 2.38, 1.69], prefix: "old")]
        #expect(abs(VoiceLabWordingFit.multiplier(VoiceLabRateCalibration.samples(project: old, model: "eleven_v4", voice: voice)) - 1.3) < 1e-12)
        old.voiceLab.speakingRateSamples?[VoiceLabRateCalibration.projectKey("eleven_v4")] = Self.samples([1.0, 1.02, 0.98, 1.01], prefix: "new")
        #expect(VoiceLabRateCalibration.projectKey("eleven_v4") == "eleven_v4@prior2")
        // Four consistent takes of this project outweigh the voice: its entries are trimmed as outliers.
        let refined = VoiceLabWordingFit.multiplier(VoiceLabRateCalibration.samples(project: old, model: "eleven_v4", voice: voice))
        #expect(abs(refined - 1.005) < 1e-12)
        // The estimate the plan shows: the median, times the calibration; its p80 by the spread.
        let rate = 11.5, text = "Then we ride on the coast"
        let base = try VoiceLabPhraseTiming.estimate(text: text, rate: rate)
        let timing = try VoiceLabPaceMatching.measure(text: text, rate: rate, window: Self.window(4), incomingSilence: nil,
            outgoingSilence: nil, sourceSampleRate: 48_000, supportsPace: false, hardJoinSmoothing: false,
            rateMultiplier: VoiceLabWordingFit.multiplier(samples))
        #expect(abs(timing.estimateSeconds - base * 1.3) < 1e-9)
        let spread = VoiceLabRateCalibration.spread(project: fresh, model: "eleven_v4", voice: voice)
        #expect(spread >= VoiceLabRateCalibration.spreadBounds.lowerBound && spread <= VoiceLabRateCalibration.spreadBounds.upperBound)
    }

    static func window(_ duration: Double) -> VoiceLabWindow {
        let start = 10.0, end = 10.0 + duration
        let first = Int64(EditingPrimitives.jsRound(start * 48_000)), last = Int64(EditingPrimitives.jsRound(end * 48_000))
        return VoiceLabWindow(firstWordId: "w0", lastWordId: "w0", leftBridgeWordIds: [], rightBridgeWordIds: [],
            start: start, end: end, startSample: first, endSample: last,
            leftSeam: .init(kind: .hard, time: start, sample: first, fadeSamples: 240),
            rightSeam: .init(kind: .hard, time: end, sample: last, fadeSamples: 240))
    }
}
