import Foundation
import Testing
import VoxClipCore
@testable import VoxClipMedia

/// Local measurement, never run in CI: the set "Rebuild from my videos" (voice-lab §6.12, ADR-R44) would send for the
/// user's voice, built from the user's own projects with the production speaker model. Every input is read only; the
/// record and its reference sample are copied into a temporary store that is deleted afterwards. Nothing is sent to
/// ElevenLabs: the "after" comparison needs the user's own click on Rebuild.
///
/// VOXCLIP_REBUILD_MEASURE_RECORD    the voice's consent folder (record.json and reference.wav or statement.wav)
/// VOXCLIP_REBUILD_MEASURE_PROJECTS  .voxclip files, separated by commas
/// VOXCLIP_SPEAKER_MODEL_DIR         the verified local speaker model and VAD
extension HeavyMediaTests {
@Suite("Rebuild set measurement (local only)", .serialized)
struct VoiceRebuildMeasureTests {
    static var environment: [String: String] { ProcessInfo.processInfo.environment }
    static var enabled: Bool {
        ["VOXCLIP_REBUILD_MEASURE_RECORD", "VOXCLIP_REBUILD_MEASURE_PROJECTS", "VOXCLIP_SPEAKER_MODEL_DIR"].allSatisfy { environment[$0]?.isEmpty == false }
    }
    static func format(_ value: Double) -> String { String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value) }

    @Test(.enabled(if: enabled, "Local measurement: set VOXCLIP_REBUILD_MEASURE_* and the model path, read only."))
    func measuresThePlannedRebuildSet() async throws {
        let env = Self.environment
        let folder = URL(fileURLWithPath: env["VOXCLIP_REBUILD_MEASURE_RECORD"]!)
        let record = try JSONDecoder().decode(VoiceConsentRecord.self, from: Data(contentsOf: folder.appendingPathComponent("record.json")))
        let referenceWAV = try Data(contentsOf: folder.appendingPathComponent(record.referenceAudioFile))
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("rebuild-measure-\(UUID())")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let store = VoiceConsentStore(locations: DataLocations(environment: ["VOXCLIP_DATA_DIR": temporary.path]))
        if record.projectConsent != nil { try await store.saveReferenceAudio(referenceWAV, recordID: record.id) }
        else { try await store.saveStatement(referenceWAV, recordID: record.id) }
        try await store.save(record)

        let model = try SpeakerModelCatalog(shared: SharedResources.locate()).entry
        let embedder = try ONNXSpeakerEmbedder(model: model, directory: URL(fileURLWithPath: env["VOXCLIP_SPEAKER_MODEL_DIR"]!))
        let check = try await embedder.speakerCheck(language: record.language)
        let owner = try #require(VoiceConsentRecord.decodeEmbedding(record.speaker.embedding))
        let referenceScore = try VoiceSpeakerCheck.cosine(owner, await check.embedding(VoiceConsentAudio.pcm16k(referenceWAV)))
        print("rebuild-measure voice=\(record.voiceName) created=\(record.createdAt) samples=\(record.samples.count) "
              + "(\(Self.format(record.samples.reduce(0) { $0 + $1.seconds })) s) τ=\(record.speaker.threshold) model=\(record.speaker.model)")
        print("rebuild-measure reference=\(record.referenceAudioFile) score=\(Self.format(referenceScore)) (the consent embedding is this sample's own)")

        let finder = VoiceRebuildFinder(store: store, check: check)
        var sources: [VoiceRebuildFinder.Source] = []
        var all: [VoiceRebuild.Candidate] = []
        for path in env["VOXCLIP_REBUILD_MEASURE_PROJECTS"]!.split(separator: ",").map(String.init) {
            let url = URL(fileURLWithPath: path)
            let project = try JSONProjectStore.decode(Data(contentsOf: url))
            let absolute = URL(fileURLWithPath: project.media.source.absolutePath)
            let relative = project.media.source.relativePath.map { url.deletingLastPathComponent().appendingPathComponent($0).standardizedFileURL }
            guard let media = [absolute, relative].compactMap({ $0 }).first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
                print("rebuild-measure project=\(url.lastPathComponent) media missing: skipped, as the app skips an unreadable video")
                continue
            }
            let source = VoiceRebuildFinder.Source(project: project, media: media)
            sources.append(source)
            let levels = try await VoiceTrainingAudio.levels(source: media)
            let inputs = VoiceTrainingSpans.inputs(project: project)
            let selection = try VoiceTrainingSpans.select(items: inputs.items, excluded: inputs.excluded, frameDb: levels.frameDb, duration: levels.duration)
            let reasons = Dictionary(grouping: selection.rejected, by: { "\($0.reason)" }).map { "\($0.key) \($0.value.count)" }.sorted()
            let snrs = selection.rejected.compactMap(\.snrDb).sorted()
            print("rebuild-measure   §6.5.1 spans: qualifying=\(selection.qualifying.count) (\(selection.availableMs / 1_000) s) rejected=\(reasons) "
                  + "rejected snr median=\(snrs.isEmpty ? "n/a" : Self.format(snrs[snrs.count / 2])) max=\(snrs.last.map(Self.format) ?? "n/a")")
            // Diagnostics only, never used: how the stretches under the clean-speech floor would score one hop.
            for rejected in selection.rejected where rejected.reason == .lowSnr && (5_000...30_000).contains(rejected.endMs - rejected.startMs) {
                let span = VoiceTrainingSpan(startMs: rejected.startMs, endMs: rejected.endMs, snrDb: rejected.snrDb ?? 0)
                guard let sample = try await VoiceTrainingAudio.projectSamples(source: media, sampleRate: levels.sampleRate, spans: [span]).first,
                      let parts = try? await check.partEmbeddings(VoiceConsentAudio.pcm16k(sample.wav)) else { continue }
                let score = try parts.parts.reduce(VoiceSpeakerCheck.cosine(owner, parts.whole)) { try min($0, VoiceSpeakerCheck.cosine(owner, $1)) }
                print("rebuild-measure   below floor \(Self.format(Double(span.startMs) / 1_000))–\(Self.format(Double(span.endMs) / 1_000)) s "
                      + "snr=\(Self.format(span.snrDb)) dB statement(lowest part)=\(Self.format(score)) whole=\(Self.format(try VoiceSpeakerCheck.cosine(owner, parts.whole)))")
            }
            let found = try await finder.videoCandidates(source, owner: owner)
            all += found.candidates
            let video = project.media.source.contentKey.prefix(8)
            print("rebuild-measure project=\(url.lastPathComponent) video=\(video) duration=\(Self.format(project.media.source.durationSeconds)) s "
                  + "rate=\(found.rate) candidates=\(found.candidates.count) (the \(VoiceRebuild.candidatesPerVideo) cleanest qualifying §6.5.1 spans) noisy=\(found.noisy)")
            for candidate in found.candidates {
                let passes = candidate.score >= record.speaker.threshold
                print("rebuild-measure   piece \(Self.format(Double(candidate.startMs) / 1_000))–\(Self.format(Double(candidate.endMs) / 1_000)) s "
                      + "len=\(Self.format(Double(candidate.durationMs) / 1_000)) s snr=\(Self.format(candidate.snrDb)) dB "
                      + "statement(lowest part)=\(Self.format(candidate.score)) \(passes ? "passes" : "fails one hop")")
            }
        }
        let format = try ElevenLabsVoiceLab.validateWAV(referenceWAV, maxBytes: 16 * 1_024 * 1_024)
        let keptSeconds: Double = Double(format.frames) / Double(format.rate)
        let keptMs: Int? = record.projectConsent == nil ? nil : Int((keptSeconds * 1_000 + 0.5).rounded(.down))
        let plan = VoiceRebuild.pick(all, threshold: record.speaker.threshold, keptMs: keptMs)
        let scores = plan.pieces.map(\.score).sorted()
        var pairs: [Double] = []
        for (index, left) in plan.pieces.enumerated() {
            for right in plan.pieces[(index + 1)...] { pairs.append(try VoiceSpeakerCheck.cosine(left.embedding, right.embedding)) }
        }
        pairs.sort()
        print("rebuild-measure plan: \(VoiceRebuild.summary(plan)) · \(plan.fileCount) files · \(Self.format(Double(plan.totalMs) / 1_000)) s · enough=\(plan.enough) · rejected=\(plan.rejected.map { "\($0.key.rawValue) \($0.value)" }.sorted())")
        if let low = scores.first, let high = scores.last {
            print("rebuild-measure statement scores: min=\(Self.format(low)) median=\(Self.format(scores[scores.count / 2])) max=\(Self.format(high))")
        }
        if let low = pairs.first, let high = pairs.last {
            print("rebuild-measure diversity (cosine between pieces, lower is more varied): min=\(Self.format(low)) median=\(Self.format(pairs[pairs.count / 2])) max=\(Self.format(high))")
        }
        let perVideo = Dictionary(grouping: plan.pieces, by: \.video).map { "\($0.key.prefix(8)): \($0.value.count) pieces, \(Self.format(Double($0.value.reduce(0) { $0 + $1.durationMs }) / 1_000)) s" }.sorted()
        print("rebuild-measure per video: \(perVideo.joined(separator: " · "))")
        print("rebuild-measure after: needs the user's click on Rebuild · $0; no ElevenLabs request was made")
        // The finder agrees with the per-video measurement above.
        if plan.enough {
            let found = try await finder.find(recordID: record.id, sources: sources)
            #expect(found.plan == plan)
            print("rebuild-measure finder: \(found.samples.count) WAVs, \(found.samples.reduce(0) { $0 + $1.wav.count }) bytes, largest \(found.samples.map(\.wav.count).max() ?? 0) bytes")
        }
    }
}
}
