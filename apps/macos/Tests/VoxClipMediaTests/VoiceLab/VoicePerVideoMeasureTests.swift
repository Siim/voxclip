import Foundation
import Testing
import VoxClipCore
@testable import VoxClipMedia

/// Local measurement, never run in CI: how much of one video's own speech a per-video voice (voice-lab §6.13, ADR-R45)
/// could be made from at each SNR floor, with the production speaker model and the one-hop check against the consent
/// voice. Every input is read only; the record and its reference sample are copied into a temporary store that is
/// deleted afterwards. Nothing is sent to ElevenLabs.
///
/// VOXCLIP_PER_VIDEO_MEASURE_RECORD   the anchor voice's consent folder (record.json and reference.wav)
/// VOXCLIP_PER_VIDEO_MEASURE_PROJECT  one .voxclip file
/// VOXCLIP_SPEAKER_MODEL_DIR          the verified local speaker model and VAD
extension HeavyMediaTests {
@Suite("Per-video voice measurement (local only)", .serialized)
struct VoicePerVideoMeasureTests {
    static var environment: [String: String] { ProcessInfo.processInfo.environment }
    static var enabled: Bool {
        ["VOXCLIP_PER_VIDEO_MEASURE_RECORD", "VOXCLIP_PER_VIDEO_MEASURE_PROJECT", "VOXCLIP_SPEAKER_MODEL_DIR"].allSatisfy { environment[$0]?.isEmpty == false }
    }
    static func format(_ value: Double) -> String { String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value) }

    @Test(.enabled(if: enabled, "Local measurement: set VOXCLIP_PER_VIDEO_MEASURE_* and the model path, read only."))
    func measuresOneVideoAtEachFloor() async throws {
        let env = Self.environment
        let folder = URL(fileURLWithPath: env["VOXCLIP_PER_VIDEO_MEASURE_RECORD"]!)
        let record = try JSONDecoder().decode(VoiceConsentRecord.self, from: Data(contentsOf: folder.appendingPathComponent("record.json")))
        let referenceWAV = try Data(contentsOf: folder.appendingPathComponent(record.referenceAudioFile))
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("per-video-measure-\(UUID())")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let store = VoiceConsentStore(locations: DataLocations(environment: ["VOXCLIP_DATA_DIR": temporary.path]))
        if record.projectConsent != nil { try await store.saveReferenceAudio(referenceWAV, recordID: record.id) }
        else { try await store.saveStatement(referenceWAV, recordID: record.id) }
        try await store.save(record)
        let model = try SpeakerModelCatalog(shared: SharedResources.locate()).entry
        let embedder = try ONNXSpeakerEmbedder(model: model, directory: URL(fileURLWithPath: env["VOXCLIP_SPEAKER_MODEL_DIR"]!))
        let check = try await embedder.speakerCheck(language: record.language)
        let owner = try #require(VoiceConsentRecord.decodeEmbedding(record.speaker.embedding))
        let threshold = record.speaker.threshold

        let url = URL(fileURLWithPath: env["VOXCLIP_PER_VIDEO_MEASURE_PROJECT"]!)
        let project = try JSONProjectStore.decode(Data(contentsOf: url))
        let absolute = URL(fileURLWithPath: project.media.source.absolutePath)
        let relative = project.media.source.relativePath.map { url.deletingLastPathComponent().appendingPathComponent($0).standardizedFileURL }
        let media = try #require([absolute, relative].compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) })
        let levels = try await VoiceTrainingAudio.levels(source: media)
        let inputs = VoiceTrainingSpans.inputs(project: project)
        let selection = try VoiceTrainingSpans.select(items: inputs.items, excluded: inputs.excluded, frameDb: levels.frameDb, duration: levels.duration)
        let pieces = (selection.qualifying + VoiceRebuildFinder.relaxedSpans(selection, minimumSnrDb: -.infinity))
            .sorted { $0.startMs < $1.startMs }
        let reasons = Dictionary(grouping: selection.rejected, by: { "\($0.reason)" }).map { "\($0.key) \($0.value.count)" }.sorted()
        print("per-video-measure video=\(url.lastPathComponent) duration=\(Self.format(project.media.source.durationSeconds)) s rate=\(levels.sampleRate) "
              + "§6.5.1 pieces 5–30 s=\(pieces.count) rejected=\(reasons) τ=\(threshold)")
        var scored: [(span: VoiceTrainingSpan, score: Double, whole: [Float])] = []
        for span in pieces {
            guard let sample = try await VoiceTrainingAudio.projectSamples(source: media, sampleRate: levels.sampleRate, spans: [span]).first,
                  let parts = try? await check.partEmbeddings(VoiceConsentAudio.pcm16k(sample.wav)) else {
                print("per-video-measure   piece \(Self.format(Double(span.startMs) / 1_000))–\(Self.format(Double(span.endMs) / 1_000)) s too little voiced speech to embed")
                continue
            }
            let score = try parts.parts.reduce(VoiceSpeakerCheck.cosine(owner, parts.whole)) { try min($0, VoiceSpeakerCheck.cosine(owner, $1)) }
            scored.append((span, score, parts.whole))
            print("per-video-measure   piece \(Self.format(Double(span.startMs) / 1_000))–\(Self.format(Double(span.endMs) / 1_000)) s "
                  + "len=\(Self.format(Double(span.durationMs) / 1_000)) snr=\(Self.format(span.snrDb)) dB lowest part=\(Self.format(score)) "
                  + (score >= threshold ? "passes one hop" : "fails one hop"))
        }
        let format = try ElevenLabsVoiceLab.validateWAV(referenceWAV, maxBytes: 16 * 1_024 * 1_024)
        let keptMs = Int((Double(format.frames) / Double(format.rate) * 1_000 + 0.5).rounded(.down))
        let key = project.media.source.contentKey
        for floor in [20.0, 12.0, 8.0, 6.0] {
            let clean = scored.filter { $0.span.snrDb >= floor }
            let owners = clean.filter { $0.score >= threshold }
            let candidates = clean.map { VoiceRebuild.Candidate(video: key, startMs: $0.span.startMs, endMs: $0.span.endMs, snrDb: $0.span.snrDb, score: $0.score, embedding: $0.whole) }
            let plan = VoiceRebuild.pick(candidates, threshold: threshold, keptMs: keptMs, minimumSnrDb: floor)
            let videoMs = VoicePerVideo.videoMs(plan)
            print("per-video-measure floor=\(Int(floor)) dB: pieces=\(clean.count) (\(Self.format(Double(clean.reduce(0) { $0 + $1.span.durationMs }) / 1_000)) s) "
                  + "one hop=\(owners.count) (\(Self.format(Double(owners.reduce(0) { $0 + $1.span.durationMs }) / 1_000)) s) "
                  + "plan video=\(Self.format(Double(videoMs) / 1_000)) s + clip \(Self.format(Double(keptMs) / 1_000)) s, \(plan.fileCount) files, "
                  + "enough=\(videoMs >= VoicePerVideo.minimumVideoMs && plan.enough) noise removal=\(VoicePerVideo.removesBackgroundNoise(plan))")
        }
        // The production finder at the chosen floor agrees with the table above.
        let finder = VoiceRebuildFinder(store: store, check: check)
        do {
            let found = try await finder.find(recordID: record.id, sources: [.init(project: project, media: media)], rules: .perVideo)
            print("per-video-measure finder floor=\(Int(VoicePerVideo.minimumSnrDb)) dB: \(VoiceRebuild.summary(found.plan)), \(found.samples.count) WAVs")
        } catch VoiceRebuildFinder.Failure.notEnough(let milliseconds, let noisy) {
            print("per-video-measure finder floor=\(Int(VoicePerVideo.minimumSnrDb)) dB: not enough, \(Self.format(Double(milliseconds) / 1_000)) s of the video's own verified speech, \(noisy) too noisy → anchor")
        }
    }
}
}
