import Foundation
import VoxClipCore

/// Seeds a voice's speaking-rate calibration once from the paid takes the app already has (ADR-R41), on device and
/// read only. Takes carry no text, voice or model, so the seed is bounded:
/// - it runs only when exactly one active voice exists, and reads only takes written after that voice was created;
/// - it measures the newest 30 of them, the most a calibration keeps, under the Rewrite model (`VoiceLabWordingFit.modelID`);
/// - each take's words come from the on-device word check (`VoiceLabLocalTiming`), its length from its voiced span,
///   and the speaker's rate from the voice's own reference recording.
/// Nothing is sent anywhere, and the log gets counts only.
public struct VoiceLabRateCalibrationSeeder: Sendable {
    public struct Outcome: Sendable, Equatable {
        public let measured: Int
        public let skipped: Int
        public let reason: String
    }

    let paidRoot: URL
    let consent: VoiceConsentStore
    let store: VoiceLabRateCalibrationStore
    let timing: VoiceLabLocalTiming
    let limit: Int

    public init(paidRoot: URL, consent: VoiceConsentStore, store: VoiceLabRateCalibrationStore, timing: @escaping VoiceLabLocalTiming,
                limit: Int = VoiceLabRateCalibration.voiceSampleLimit) {
        self.paidRoot = paidRoot; self.consent = consent; self.store = store; self.timing = timing; self.limit = limit
    }

    /// Seeds when the one active voice has no seed yet. A failure leaves the voice unseeded, so the next launch tries again.
    public func run() async -> Outcome {
        guard let voices = try? await consent.activeVoices(), voices.count == 1, let voice = voices.first else {
            return Outcome(measured: 0, skipped: 0, reason: "voices")
        }
        let current = await store.load(voice.id)
        guard !current.seeded else { return Outcome(measured: 0, skipped: 0, reason: "seeded") }
        let language = voice.projectConsent?.language ?? voice.statement?.language ?? "en"
        let rate: Double
        do {
            let reference = try VoiceConsentAudio.pcm16k(try await consent.referenceAudio(recordID: voice.id))
            rate = try VoiceLabPhraseTiming.speakingRate(transcript: Self.timed(try await timing(reference, 16_000, language)))
        } catch { return Outcome(measured: 0, skipped: 0, reason: "reference") }
        let created = ISO8601DateFormatter().date(from: voice.createdAt) ?? .distantPast
        var calibration = current
        var measured = 0, skipped = 0
        for take in Self.takes(paidRoot: paidRoot, since: created, limit: limit) {
            if Task.isCancelled { return Outcome(measured: measured, skipped: skipped, reason: "cancelled") }
            guard let seconds = try? Self.voicedSeconds(take), let words = try? await timing(Self.samples(take), 24_000, language),
                  words.count >= 2 else { skipped += 1; continue }
            let text = words.map(\.text).joined(separator: " ")
            guard VoiceLabTextLength.length(text) >= 6, let estimate = try? VoiceLabPhraseTiming.estimate(text: text, rate: rate) else {
                skipped += 1; continue
            }
            let next = calibration.recording(VoiceLabWordingFit.modelID, id: "seed-" + take.deletingPathExtension().lastPathComponent,
                                             measured: seconds, estimated: estimate)
            if next == calibration { skipped += 1 } else { measured += 1 }
            calibration = next
        }
        calibration.seeded = true
        do { try await store.save(calibration) } catch { return Outcome(measured: measured, skipped: skipped, reason: "write") }
        return Outcome(measured: measured, skipped: skipped, reason: "done")
    }

    /// The newest `limit` take WAVs written at or after `since`, across the project folders of the paid root.
    static func takes(paidRoot: URL, since: Date, limit: Int) -> [URL] {
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey, .isDirectoryKey]
        let folders = (try? manager.contentsOfDirectory(at: paidRoot, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        var found: [(url: URL, date: Date)] = []
        for folder in folders where UUID(uuidString: folder.lastPathComponent) != nil {
            let files = (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
            for file in files where file.pathExtension == "wav" {
                guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                      let date = values.contentModificationDate, date >= since else { continue }
                found.append((file, date))
            }
        }
        return found.sorted { $0.date > $1.date }.prefix(max(0, limit)).map(\.url)
    }

    static func samples(_ take: URL) throws -> [Float] {
        try VoiceLabSourceAudio.decodeAsset(url: take, targetSampleRate: 24_000)
    }

    /// The take's trimmed length as a Rewrite measures it without alignment: its first to last voiced 10 ms frame,
    /// widened by the trim lead and tail (`VoiceLabAlignment.trim(envelope:)`).
    static func voicedSeconds(_ take: URL) throws -> Double {
        let samples = try samples(take)
        let duration = Double(samples.count) / 24_000
        let trim = try VoiceLabAlignment.trim(envelope: VoiceLabTakeProcessing.envelope(samples, sampleRate: 24_000), assetDuration: duration)
        return trim.end - trim.start
    }

    static func timed(_ words: [VoiceLabWord]) -> [TimedWord] {
        words.enumerated().map { TimedWord(id: "w\($0.offset)", text: $0.element.text, start: $0.element.start, end: $0.element.end) }
    }
}
