import Foundation
import Testing
@testable import VoxClipCore
@testable import VoxClipMedia

/// The one-time seed of a voice's calibration from the takes the app already has (ADR-R43): on device, read only, once,
/// and only for the one active voice. The word check is a stub; nothing is sent.
@Suite(.offlineFixtures) struct VoiceLabRateCalibrationSeederTests {
    struct Fixture {
        let root: URL
        let paidRoot: URL
        let consent: VoiceConsentStore
        let store: VoiceLabRateCalibrationStore
        let recordID: String
    }

    /// One active voice whose reference speaks 8 letters a second, and two takes of one project: 1.0 s and 2.0 s of voice.
    func fixture(voices: Bool = true) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-seed-\(UUID().uuidString)", isDirectory: true)
        let locations = DataLocations(environment: ["VOXCLIP_DATA_DIR": root.path], home: root)
        let paidRoot = root.appendingPathComponent("VoiceLab", isDirectory: true)
        try FileManager.default.createDirectory(at: paidRoot, withIntermediateDirectories: true)
        let consent = VoiceConsentStore(locations: locations)
        var recordID = ""
        if voices {
            let wav = try VoiceTrainingAudio.wav([Float](repeating: 0.1, count: 80_000), rate: 16_000)
            var object = try #require(JSONSerialization.jsonObject(with: FixtureLoader.data("fixtures/voice-lab/consent-record.json")) as? [String: Any])
            var statement = try #require(object["statement"] as? [String: Any])
            statement["audioSha256"] = VoiceLabFingerprint.bytes(wav); object["statement"] = statement
            let record = try JSONDecoder().decode(VoiceConsentRecord.self, from: JSONSerialization.data(withJSONObject: object))
            try await consent.saveStatement(wav, recordID: record.id); try await consent.save(record)
            recordID = record.id
        }
        let project = UUID().uuidString.lowercased()
        for seconds in [1.0, 2.0] {
            let voiced = Int(seconds * 24_000), quiet = 2_400
            let samples = [Float](repeating: 0, count: quiet) + (0..<voiced).map { Float(0.2 * sin(Double($0) / 8)) } + [Float](repeating: 0, count: quiet)
            let pcm = samples.reduce(into: Data()) { data, sample in
                withUnsafeBytes(of: Int16(sample * 32_767).littleEndian) { data.append(contentsOf: $0) }
            }
            _ = try VoiceLabAssetStore.write(pcm16: pcm, sampleRate: 24_000, projectId: project, assetId: UUID().uuidString.lowercased(),
                                             paidRoot: paidRoot, createdAt: Date())
        }
        return Fixture(root: root, paidRoot: paidRoot, consent: consent, store: VoiceLabRateCalibrationStore(locations: locations), recordID: recordID)
    }

    /// The stub word check: the reference (16 kHz) as eight-letter words, one a second; a take as two four-letter words.
    static let timing: VoiceLabLocalTiming = { samples, rate, _ in
        let seconds = Double(samples.count) / Double(rate)
        if rate == 16_000 {
            return (0..<Int(seconds)).map { VoiceLabWord(text: "abcdefgh", start: Double($0), end: Double($0) + 1, synthetic: true) }
        }
        return [VoiceLabWord(text: "abcd", start: 0.1, end: seconds / 2, synthetic: true),
                VoiceLabWord(text: "efgh", start: seconds / 2, end: seconds - 0.1, synthetic: true)]
    }

    @Test func seedsTheOneVoiceOnceFromItsTakes() async throws {
        let fixture = try await fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let seeder = VoiceLabRateCalibrationSeeder(paidRoot: fixture.paidRoot, consent: fixture.consent, store: fixture.store, timing: Self.timing)
        let outcome = await seeder.run()
        #expect(outcome == .init(measured: 2, skipped: 0, reason: "done"))
        let calibration = await fixture.store.load(fixture.recordID)
        #expect(calibration.seeded)
        let samples = calibration.samples(VoiceLabWordingFit.modelID)
        #expect(samples.count == 2 && samples.allSatisfy { $0.id.hasPrefix("seed-") })
        // Each ratio is the take's voiced span (widened by the trim) over the estimate of its words at the reference's rate.
        let estimate = try VoiceLabPhraseTiming.estimate(text: "abcd efgh", rate: 8)
        let expected = [2.0, 1.0].map { ($0 + VoiceLabPatchConstants.TTS_TRIM_LEAD + VoiceLabPatchConstants.TTS_TRIM_TAIL) / estimate }
        for (sample, ratio) in zip(samples, expected) { #expect(abs(sample.ratio - ratio) < 0.02, "\(sample)") }
        // Once seeded, it never runs again, and the takes are untouched.
        #expect(await seeder.run() == .init(measured: 0, skipped: 0, reason: "seeded"))
        #expect(await fixture.store.load(fixture.recordID) == calibration)
    }

    @Test func noVoiceOrNoReferenceLeavesNothingSeeded() async throws {
        let none = try await fixture(voices: false); defer { try? FileManager.default.removeItem(at: none.root) }
        let without = VoiceLabRateCalibrationSeeder(paidRoot: none.paidRoot, consent: none.consent, store: none.store, timing: Self.timing)
        #expect(await without.run().reason == "voices")
        #expect(await none.store.all().isEmpty)
        let fixture = try await fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let deaf: VoiceLabLocalTiming = { _, _, _ in throw VoiceLabError.invalidAlignment }
        let failing = VoiceLabRateCalibrationSeeder(paidRoot: fixture.paidRoot, consent: fixture.consent, store: fixture.store, timing: deaf)
        #expect(await failing.run().reason == "reference")
        #expect(await !fixture.store.load(fixture.recordID).seeded)
        // The next launch tries again and seeds.
        let seeder = VoiceLabRateCalibrationSeeder(paidRoot: fixture.paidRoot, consent: fixture.consent, store: fixture.store, timing: Self.timing)
        #expect(await seeder.run().reason == "done")
    }

    @Test func readsOnlyTheNewestTakesOfProjectFolders() async throws {
        let fixture = try await fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        // A WAV outside a project folder is not a take.
        let consent = fixture.paidRoot.appendingPathComponent("consent", isDirectory: true)
        try FileManager.default.createDirectory(at: consent, withIntermediateDirectories: true)
        try Data("RIFF".utf8).write(to: consent.appendingPathComponent("reference.wav"))
        let all = VoiceLabRateCalibrationSeeder.takes(paidRoot: fixture.paidRoot, since: .distantPast, limit: 30)
        #expect(all.count == 2 && all.allSatisfy { $0.pathExtension == "wav" && !$0.path.contains("/consent/") })
        #expect(VoiceLabRateCalibrationSeeder.takes(paidRoot: fixture.paidRoot, since: .distantPast, limit: 1).count == 1)
        #expect(VoiceLabRateCalibrationSeeder.takes(paidRoot: fixture.paidRoot, since: .distantFuture, limit: 30).isEmpty)
    }
}
