import Foundation
import VoxClipCore

/// Word timing for a take's own PCM from an on-device transcriber: the free fallback of voice-lab §8.5 "Timing
/// recovery" when neither the provider's timing nor the take's Scribe word check gives usable word times.
/// Arguments: mono samples, their rate, the take's language. Throws when no on-device engine is ready.
public typealias VoiceLabLocalTiming = @Sendable ([Float], Int, String) async throws -> [VoiceLabWord]

public enum VoiceLabLocalTimingSource {
    /// Apple Speech when its assets for the language are installed, else an installed Whisper model. Never downloads
    /// a model or system asset and never prompts. The 16 kHz WAV lives in `scratch` only while it is transcribed.
    public static func onDevice(locations: DataLocations, scratch: URL) -> VoiceLabLocalTiming {
        { samples, rate, language in
            guard rate > 0, !samples.isEmpty else { throw VoiceLabError.invalidAudio }
            let resampled = resample(samples, from: rate, to: 16_000)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            let url = scratch.appendingPathComponent("timing-\(UUID().uuidString.lowercased()).wav")
            defer { try? FileManager.default.removeItem(at: url) }
            try VoiceLabTakeWAV.encode(resampled, rate: 16_000).write(to: url, options: .atomic)
            let audio = ExtractedAudio(wav16k: url, sampleCount: Int64(resampled.count), durationSeconds: Double(resampled.count) / 16_000)
            let choice = LanguageChoice.forced(language)
            let apple = AppleSpeechTranscriber(locations: locations)
            let applePlan = TranscriptionPlan(engine: .appleSpeech, language: choice)
            if case .ready = await apple.readiness(for: applePlan) {
                return words(try await apple.transcribe(TranscriptionRequest(plan: applePlan, audio: audio, contentKey: "voice-lab-timing"), progress: { _ in }))
            }
            if let shared = try? SharedResources.locate() {
                let catalog = BundledModelCatalog(shared: shared)
                let whisper = WhisperCppTranscriber(catalog: catalog, locations: locations)
                for model in (try? await ModelStore(catalog: catalog, locations: locations).installedModels()) ?? [] {
                    let plan = TranscriptionPlan(engine: .whispercpp, model: model, language: choice)
                    guard case .ready = await whisper.readiness(for: plan) else { continue }
                    return words(try await whisper.transcribe(TranscriptionRequest(plan: plan, audio: audio, contentKey: "voice-lab-timing"), progress: { _ in }))
                }
            }
            throw VoiceLabError.invalidAlignment
        }
    }

    static func words(_ raw: RawTranscript) -> [VoiceLabWord] {
        var result: [VoiceLabWord] = []
        for token in raw.tokens where token.kind != .event {
            guard let start = token.start, let end = token.end, start.isFinite, end.isFinite, end >= start else { continue }
            let text = token.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if token.joinsPrevious, let last = result.last {
                result[result.count - 1] = VoiceLabWord(text: last.text + text, start: last.start, end: max(last.end, end), synthetic: true)
            } else {
                result.append(VoiceLabWord(text: text, start: start, end: end, synthetic: true))
            }
        }
        return result
    }

    /// Linear interpolation, enough for word timing.
    static func resample(_ samples: [Float], from rate: Int, to target: Int) -> [Float] {
        guard rate != target else { return samples }
        let count = Int((Double(samples.count) * Double(target) / Double(rate)).rounded(.down))
        let ratio = Double(rate) / Double(target)
        return (0..<count).map { index in
            let position = Double(index) * ratio
            let lower = min(samples.count - 1, Int(position))
            let upper = min(samples.count - 1, lower + 1)
            let fraction = Float(position - Double(lower))
            return samples[lower] + (samples[upper] - samples[lower]) * fraction
        }
    }
}
