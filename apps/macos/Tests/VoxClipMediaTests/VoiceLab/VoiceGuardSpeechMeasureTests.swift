import Foundation
import Testing
import VoxClipCore
@testable import VoxClipMedia

/// A local measurement, never run in CI: the use-time guard's cosine for each phrase of a real project, with the old raw
/// 10 s window and with the speech the guard now reads (voice-lab §6.9). Every input is named by an environment variable
/// and read only; nothing is written beside them, and the numbers go to the test's output.
///
/// VOXCLIP_GUARD_MEASURE_PROJECT  a .voxclip file
/// VOXCLIP_GUARD_MEASURE_MEDIA    its source media
/// VOXCLIP_GUARD_MEASURE_RECORD   the voice's consent record.json
/// VOXCLIP_SPEAKER_MODEL_DIR      the verified local speaker model and VAD
/// VOXCLIP_GUARD_MEASURE_PHRASES  phrases as first-last word ids, separated by commas (for example w10-w12,w20-w20)
extension HeavyMediaTests {
@Suite("Guard speech measurement (local only)", .serialized)
struct VoiceGuardSpeechMeasureTests {
    static var environment: [String: String] { ProcessInfo.processInfo.environment }
    static var enabled: Bool {
        ["VOXCLIP_GUARD_MEASURE_PROJECT", "VOXCLIP_GUARD_MEASURE_MEDIA", "VOXCLIP_GUARD_MEASURE_RECORD",
         "VOXCLIP_SPEAKER_MODEL_DIR", "VOXCLIP_GUARD_MEASURE_PHRASES"].allSatisfy { environment[$0]?.isEmpty == false }
    }

    @Test(.enabled(if: enabled, "Local measurement: set the VOXCLIP_GUARD_MEASURE_* paths, read only."))
    func measuresOldAndNewGuardSpeech() async throws {
        let env = Self.environment
        let project = try ProjectJSON.decode(Data(contentsOf: URL(fileURLWithPath: env["VOXCLIP_GUARD_MEASURE_PROJECT"]!)))
        let media = URL(fileURLWithPath: env["VOXCLIP_GUARD_MEASURE_MEDIA"]!)
        let record = try JSONDecoder().decode(VoiceConsentRecord.self, from: Data(contentsOf: URL(fileURLWithPath: env["VOXCLIP_GUARD_MEASURE_RECORD"]!)))
        let owner = try #require(VoiceConsentRecord.decodeEmbedding(record.speaker.embedding))
        let model = try SpeakerModelCatalog(shared: SharedResources.locate()).entry
        let directory = URL(fileURLWithPath: env["VOXCLIP_SPEAKER_MODEL_DIR"]!)
        let embedder = try ONNXSpeakerEmbedder(model: model, directory: directory)
        let check = try await embedder.speakerCheck(language: record.language)
        #expect(check.threshold == record.speaker.threshold)
        let words = try #require(project.transcript?.words)
        let audio = try #require(project.media.source.audio)
        let rate = audio.sampleRate
        let frames = Int64(EditingPrimitives.jsRound(project.media.source.durationSeconds * Double(rate)))
        let envelope = try await VoiceLabSourceAudio.rewriteEnvelope(source: media, frames: frames, sampleRate: rate)
        print("guard-measure threshold=\(record.speaker.threshold) model=\(record.speaker.model)")
        for (number, spec) in env["VOXCLIP_GUARD_MEASURE_PHRASES"]!.split(separator: ",").enumerated() {
            let ids = spec.split(separator: "-").map(String.init)
            let first = try #require(words.first { $0.id == ids.first })
            let last = try #require(words.first { $0.id == ids.last })
            let startSample = Int64(EditingPrimitives.jsRound(first.start * Double(rate)))
            let endSample = Int64(EditingPrimitives.jsRound(last.end * Double(rate)))
            let fade = Int64(rate / 50)
            let window = VoiceLabWindow(firstWordId: first.id, lastWordId: last.id, leftBridgeWordIds: [], rightBridgeWordIds: [],
                start: first.start, end: last.end, startSample: startSample, endSample: endSample,
                leftSeam: .init(kind: .hard, time: first.start, sample: startSample, fadeSamples: fade),
                rightSeam: .init(kind: .hard, time: last.end, sample: endSample, fadeSamples: fade))
            let source = try await VoiceLabSourceAudio.rewriteSource(source: media, frames: frames, sampleRate: rate, window: window,
                incomingSilence: nil, outgoingSilence: nil, items: words, envelope: envelope)
            let input = VoiceLabTakeInput(text: "measure", modelID: "eleven_v3", recordID: record.id, language: record.language, seed: 1,
                contentKey: project.media.source.contentKey, source: source.excerpt, sourceEnvelope: source.envelope,
                sourceSampleRate: rate, items: words, window: window, incomingSilence: nil, outgoingSilence: nil, providerConsent: true)
            let center = Int((startSample + endSample) / 2)
            let rawStart = max(0, center - 5 * rate), rawEnd = min(source.excerpt.totalFrames, rawStart + 10 * rate)
            let raw = VoiceConsentAudio.resample(Array(try #require(source.excerpt.samples(rawStart..<rawEnd))), rate: rate)
            let speech = try VoiceLabTakeRun.guardSpeech(input)
            func score(_ pcm: [Float]) async -> String {
                do {
                    let voiced = try await embedder.voicedSamples(Array(pcm.prefix(160_000)))
                    let vector = try await check.embedding(Array(pcm.prefix(160_000)))
                    let cosine = try VoiceSpeakerCheck.cosine(owner, vector)
                    return String(format: "cos=%.4f voiced=%.2fs", locale: Locale(identifier: "en_US_POSIX"), cosine, Double(voiced.count) / 16_000)
                } catch { return "error=\(error)" }
            }
            let old = await score(raw), new = await score(speech)
            let selection = VoiceLabGuardSpeech.select(items: words, start: window.start, end: window.end, sampleRate: rate, totalFrames: Int(frames))
            print("guard-measure phrase=\(number + 1) span=\(String(format: "%.2f-%.2f", first.start, last.end)) " +
                  "old[raw 10 s: \(old)] new[\(selection.ranges.count) word spans, \(String(format: "%.2f", Double(speech.count) / 16_000)) s: \(new)]")
        }
    }
}
}
