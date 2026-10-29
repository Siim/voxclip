import Foundation
import Testing
@testable import VoxClipCore

@Suite("Speaker preprocessing and catalogue")
struct SpeakerAudioTests {
    @Test func windowsUseThreeSecondsAndHalfOverlap() throws {
        let samples = (0..<96_000).map { Float($0) }
        let windows = try SpeakerAudio.windows(samples)
        #expect(windows.count == 3)
        #expect(windows[0].count == 48_000)
        #expect(windows[1].first == 24_000)
        #expect(windows[2].last == 95_999)
        #expect(try SpeakerAudio.windows(Array(samples.prefix(71_999))).count == 1)
        #expect(throws: VoiceConsentError.speakerMismatch) { try SpeakerAudio.windows([Float](repeating: 0, count: 47_999)) }
    }
    @Test func selectsOnlyOrderedVoicedRanges() throws {
        let samples: [Float] = [0, 1, 2, 3, 4, 5]
        #expect(try SpeakerAudio.select(samples, ranges: [1..<3, 4..<6]) == [1, 2, 4, 5])
        #expect(throws: VoiceConsentError.speakerMismatch) { try SpeakerAudio.select(samples, ranges: [1..<4, 3..<5]) }
        #expect(throws: VoiceConsentError.speakerMismatch) { try SpeakerAudio.select(samples, ranges: [5..<7]) }
        #expect(throws: VoiceConsentError.speakerMismatch) { try SpeakerAudio.select([.nan], ranges: []) }
    }
    @Test func energyFallbackIsBoundedToTestFrames() throws {
        let silence = [Float](repeating: 0, count: 160)
        let voice = [Float](repeating: 0.1, count: 48_000)
        #expect(try SpeakerAudio.energySpeech(silence + voice + silence) == voice)
    }
    @Test func normalizationAndCosineRejectInvalidVectors() throws {
        let unit = try SpeakerAudio.normalized([3, 4])
        #expect(abs(unit[0] - 0.6) < 0.00001)
        #expect(abs(unit[1] - 0.8) < 0.00001)
        #expect(abs(try VoiceSpeakerCheck.cosine([3, 4], [6, 8]) - 1) < 0.000001)
        #expect(abs(try VoiceSpeakerCheck.cosine([1, 0], [0, 2])) < 0.000001)
        #expect(try VoiceSpeakerCheck.cosine([1, 0], [-1, 0]) == -1)
        #expect(throws: VoiceConsentError.speakerMismatch) { try SpeakerAudio.normalized([0, 0]) }
        #expect(throws: VoiceConsentError.speakerMismatch) { try VoiceSpeakerCheck.cosine([.infinity], [1]) }
    }
    @Test func fbankHasExpectedShapeAndPerBandZeroMean() throws {
        let pcm = (0..<48_000).map { Float(sin(Double($0) * 0.071) * 0.2) }
        let features = try SpeakerAudio.features(pcm)
        #expect(features.count == 298 * 80)
        let finite = features.allSatisfy { $0.isFinite }
        #expect(finite)
        for band in 0..<80 {
            let mean = (0..<298).reduce(0.0) { $0 + Double(features[$1 * 80 + band]) } / 298
            #expect(abs(mean) < 0.00001)
        }
        #expect(throws: VoiceConsentError.speakerMismatch) { try SpeakerAudio.features([Float](repeating: 0, count: 100)) }
    }
    @Test func fbankMatchesIndependentPythonVector() throws {
        struct Vector: Decodable { let first: [Float]; let last: [Float] }
        let vector = try JSONDecoder().decode(Vector.self, from: FixtureLoader.data("fixtures/voice-lab/speaker/features.json"))
        let pcm = (0..<48_000).map { Float(sin(Double($0) * 0.071) * 0.2) }
        let features = try SpeakerAudio.features(pcm)
        for band in 0..<80 {
            #expect(abs(features[band] - vector.first[band]) < 0.0002)
            #expect(abs(features[297 * 80 + band] - vector.last[band]) < 0.0002)
        }
    }
    @Test func catalogueRequiresCalibratedLanguageAndExactAssets() throws {
        let catalog = try SpeakerModelCatalog(shared: SharedResources(root: FixtureLoader.sharedRoot()))
        let entry = catalog.entry
        #expect(entry.dimension == 256)
        #expect(entry.files.map(\.role) == ["speaker", "vad"])
        #expect(entry.totalBytes == 27_415_407)
        #expect((entry.calibratedThreshold(language: "en") != nil) == (entry.threshold != nil))
        #expect(entry.calibratedThreshold(language: "et") == nil)
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
        var missing = object; missing["threshold"] = NSNull()
        let uncalibrated = try JSONDecoder().decode(SpeakerModel.self, from: JSONSerialization.data(withJSONObject: missing))
        #expect(uncalibrated.calibratedThreshold() == nil)
        var wrong = object
        var metadata = try #require(wrong["calibration"] as? [String: Any]); metadata["modelSha256"] = String(repeating: "0", count: 64); wrong["calibration"] = metadata
        let changed = try JSONDecoder().decode(SpeakerModel.self, from: JSONSerialization.data(withJSONObject: wrong))
        #expect(changed.calibratedThreshold() == nil)
        #expect(throws: (any Error).self) { try entry.verifiedFiles(at: URL(fileURLWithPath: "/voxclip-missing-speaker-model")) }
    }
    @Test(arguments: ["missing-margin", "small-margin", "threshold", "outcome", "speaker-count", "pooled-far", "condition-far", "condition-own", "sample-rate"])
    func catalogueRefusesMissingOrUnsafeMarginEvidence(mutation: String) throws {
        let entry = try SpeakerModelCatalog(shared: SharedResources(root: FixtureLoader.sharedRoot())).entry
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
        var calibration = try #require(object["calibration"] as? [String: Any])
        var margin = try #require(calibration["margin"] as? [String: Any])
        let maximum = try #require(margin["maximumCalibrationImpostorScore"] as? Double)
        object["threshold"] = maximum + 0.002
        margin["candidateThreshold"] = maximum + 0.002
        calibration["outcome"] = "passed"
        var languages = try #require(calibration["languages"] as? [[String: Any]])
        languages[0]["falseAcceptRate"] = 0.0; languages[0]["sameSpeakerPassRate"] = 1.0
        var conditions = try #require(languages[0]["conditions"] as? [[String: Any]])
        for index in conditions.indices { conditions[index]["falseAcceptRate"] = 0.0; conditions[index]["sameSpeakerPassRate"] = 1.0 }
        languages[0]["conditions"] = conditions; calibration["languages"] = languages; calibration["margin"] = margin; object["calibration"] = calibration
        let baseline = try JSONDecoder().decode(SpeakerModel.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(baseline.calibratedThreshold() != nil)
        switch mutation {
        case "missing-margin": calibration.removeValue(forKey: "margin")
        case "small-margin": margin["absoluteFloor"] = 0.0000001; calibration["margin"] = margin
        case "threshold": object["threshold"] = maximum + 0.001; margin["candidateThreshold"] = maximum + 0.001; calibration["margin"] = margin
        case "outcome": calibration["outcome"] = "withheld"
        case "speaker-count": languages[0]["calibrationSpeakers"] = 79
        case "pooled-far": languages[0]["falseAcceptRate"] = 0.006
        case "condition-far": conditions[0]["falseAcceptRate"] = 0.006
        case "condition-own": conditions[0]["sameSpeakerPassRate"] = 0.94
        default: for index in conditions.indices { conditions[index]["sampleRate"] = 48_000 }
        }
        languages[0]["conditions"] = conditions; calibration["languages"] = languages; object["calibration"] = calibration
        let changed = try JSONDecoder().decode(SpeakerModel.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(changed.calibratedThreshold() == nil)
    }
}
