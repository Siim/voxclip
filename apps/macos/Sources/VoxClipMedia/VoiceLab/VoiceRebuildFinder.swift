import Foundation
import VoxClipCore

/// "Rebuild from my videos" (voice-lab §6.12, ADR-R44), on this Mac and free: reads each of the owner's projects, scores
/// its cleanest transcribed stretches against the voice's own consent embedding (one hop, part by part), picks the set
/// with `VoiceRebuild.pick` and cuts it into the training WAVs the attested creation route sends. Nothing is sent here.
public actor VoiceRebuildFinder {
    /// A project and its readable source media.
    public struct Source: Sendable {
        public let project: Project
        public let media: URL
        public init(project: Project, media: URL) { self.project = project; self.media = media }
    }

    public struct Found: Sendable {
        public let plan: VoiceRebuild.Plan
        /// The WAVs in send order: the kept reference sample first when there is one, then `plan.pieces`.
        public let samples: [VoiceTrainingSample]
        /// Videos read; those labelled AI modified, untranscribed, in another language or unreadable are skipped.
        public let videosChecked: Int
        public let videosSkipped: Int
    }

    public enum Failure: Error, Equatable {
        /// The voice, its speaker model or its language isn't available on this Mac.
        case unavailable
        /// Less than 30 s of verified speech across every video; `noisy` stretches were under the clean-speech floor.
        case notEnough(milliseconds: Int, noisy: Int)
    }

    private let store: VoiceConsentStore
    private let check: VoiceSpeakerCheck
    public init(store: VoiceConsentStore, check: VoiceSpeakerCheck) { self.store = store; self.check = check }

    /// What a set must meet. `rebuild` is §6.12's: the clean-speech floor, six candidates per video, 30 s in all with the
    /// kept clip. `perVideo` is §6.13's (ADR-R45): one video, a lower floor because creation asks ElevenLabs to remove
    /// the background noise, more candidates from that one video, and at least `minimumOwnMs` of the video's own speech
    /// besides the kept clip. Identity is one hop at τ in both.
    public struct Rules: Sendable, Equatable {
        public let minimumSnrDb: Double
        public let candidatesPerVideo: Int
        /// The pieces' own speech, the kept clip not counted; 0 for a rebuild.
        public let minimumOwnMs: Int
        public init(minimumSnrDb: Double, candidatesPerVideo: Int, minimumOwnMs: Int) {
            self.minimumSnrDb = minimumSnrDb; self.candidatesPerVideo = candidatesPerVideo; self.minimumOwnMs = minimumOwnMs
        }
        public static let rebuild = Rules(minimumSnrDb: VoiceRebuild.minimumSnrDb, candidatesPerVideo: VoiceRebuild.candidatesPerVideo, minimumOwnMs: 0)
        public static let perVideo = Rules(minimumSnrDb: VoicePerVideo.minimumSnrDb, candidatesPerVideo: VoiceRebuild.maximumFiles,
                                           minimumOwnMs: VoicePerVideo.minimumVideoMs)
    }

    /// Finds the rebuild set for the voice `recordID` across `sources`. `progress(i, n)` reports the video being read.
    /// A `perVideo` set below `minimumOwnMs` throws `notEnough` with the video's own milliseconds.
    public func find(recordID: String, sources: [Source], rules: Rules = .rebuild,
                     progress: @Sendable (Int, Int) async -> Void = { _, _ in }) async throws -> Found {
        guard let record = try? await store.load(recordID), record.status == .active,
              check.supports(language: record.language), let model = check.embedder?.modelID, model == record.speaker.model,
              let threshold = check.threshold, threshold == record.speaker.threshold,
              let owner = VoiceConsentRecord.decodeEmbedding(record.speaker.embedding),
              (try? await check.embedder?.validateAvailability()) != nil else { throw Failure.unavailable }
        // The attested route's reference sample is the consent embedding itself: sending it first keeps the statement
        // the same, so the new voice's embedding equals the old one's and the learned references still apply.
        let kept = record.projectConsent == nil ? nil : try? await keptSample(recordID: recordID)
        var candidates: [VoiceRebuild.Candidate] = []
        var places: [String: (media: URL, rate: Int)] = [:]
        var checked = 0, skipped = 0, noisy = 0
        for (index, source) in sources.enumerated() {
            try Task.checkCancellation()
            await progress(index + 1, sources.count)
            let key = source.project.media.source.contentKey
            guard !key.isEmpty, places[key] == nil, source.project.transcript != nil,
                  source.project.transcript?.language.map({ $0 == record.language }) ?? true,
                  !VoiceLabDisclosureWriter.isLabelled(source.media),
                  let found = try? await videoCandidates(source, owner: owner, rules: rules) else { skipped += 1; continue }
            checked += 1
            places[key] = (source.media, found.rate)
            candidates += found.candidates
            noisy += found.noisy
        }
        let keptMs = kept.map { Int(($0.seconds * 1_000 + 0.5).rounded(.down)) }
        let plan = VoiceRebuild.pick(candidates, threshold: threshold, keptMs: keptMs, minimumSnrDb: rules.minimumSnrDb)
        let own = plan.totalMs - (keptMs ?? 0)
        guard plan.enough, own >= rules.minimumOwnMs else {
            throw Failure.notEnough(milliseconds: rules.minimumOwnMs > 0 ? own : plan.totalMs, noisy: noisy)
        }
        var samples: [VoiceTrainingSample] = kept.map { [$0] } ?? []
        for piece in plan.pieces {
            try Task.checkCancellation()
            guard let place = places[piece.video] else { throw Failure.unavailable }
            let span = VoiceTrainingSpan(startMs: piece.startMs, endMs: piece.endMs, snrDb: piece.snrDb)
            samples += try await VoiceTrainingAudio.projectSamples(source: place.media, sampleRate: place.rate, spans: [span])
        }
        guard samples.allSatisfy({ $0.wav.count <= VoiceRebuild.maximumBytes }) else { throw Failure.unavailable }
        return Found(plan: plan, samples: samples, videosChecked: checked, videosSkipped: skipped)
    }

    /// The cleanest §6.5.1 spans of one video at the rules' floor, each scored as its lowest part against the owner.
    /// Below the §6.5.1 floor the spans are the pieces it rejected only as `lowSnr` (already split to 5–30 s within one
    /// speaker's run, ended by any event such as music), never a short or unsplittable one.
    func videoCandidates(_ source: Source, owner: [Float], rules: Rules = .rebuild) async throws
        -> (rate: Int, candidates: [VoiceRebuild.Candidate], noisy: Int) {
        let levels = try await VoiceTrainingAudio.levels(source: source.media)
        let inputs = VoiceTrainingSpans.inputs(project: source.project)
        let selection = try VoiceTrainingSpans.select(items: inputs.items, excluded: inputs.excluded, frameDb: levels.frameDb, duration: levels.duration)
        let relaxed = Self.relaxedSpans(selection, minimumSnrDb: rules.minimumSnrDb)
        let spans = (selection.qualifying + relaxed).sorted { $0.snrDb != $1.snrDb ? $0.snrDb > $1.snrDb : $0.startMs < $1.startMs }
            .prefix(rules.candidatesPerVideo)
        var result: [VoiceRebuild.Candidate] = []
        for span in spans {
            try Task.checkCancellation()
            guard let sample = try await VoiceTrainingAudio.projectSamples(source: source.media, sampleRate: levels.sampleRate, spans: [span]).first,
                  let pcm = try? VoiceConsentAudio.pcm16k(sample.wav),
                  let embedded = try? await check.partEmbeddings(pcm) else { continue }
            let score = try embedded.parts.reduce(VoiceSpeakerCheck.cosine(owner, embedded.whole)) { try min($0, VoiceSpeakerCheck.cosine(owner, $1)) }
            result.append(.init(video: source.project.media.source.contentKey, startMs: span.startMs, endMs: span.endMs,
                                snrDb: span.snrDb, score: score, embedding: embedded.whole))
        }
        let noisy = selection.rejected.filter { $0.reason == .lowSnr && !(($0.snrDb ?? -.infinity) >= rules.minimumSnrDb) }.count
        return (levels.sampleRate, result, noisy)
    }

    /// The pieces §6.5.1 rejected only for their SNR that reach `minimumSnrDb`, as spans; none at or above its own floor.
    static func relaxedSpans(_ selection: VoiceTrainingSpanSelection, minimumSnrDb: Double) -> [VoiceTrainingSpan] {
        guard minimumSnrDb < VoiceRebuild.minimumSnrDb else { return [] }
        return selection.rejected.compactMap { piece in
            guard piece.reason == .lowSnr, let snr = piece.snrDb, snr.isFinite, snr >= minimumSnrDb,
                  (VoiceRebuild.minimumPieceMs...VoiceRebuild.maximumPieceMs).contains(piece.endMs - piece.startMs) else { return nil }
            return VoiceTrainingSpan(startMs: piece.startMs, endMs: piece.endMs, snrDb: snr)
        }
    }

    /// The voice's stored reference sample as a training sample.
    private func keptSample(recordID: String) async throws -> VoiceTrainingSample {
        let wav = try await store.referenceAudio(recordID: recordID)
        let format = try ElevenLabsVoiceLab.validateWAV(wav, maxBytes: VoiceRebuild.maximumBytes)
        let seconds = Double(format.frames) / Double(format.rate)
        guard (5...30).contains(seconds) else { throw VoiceLabError.invalidAudio }
        let snr = try VoiceTrainingAudio.snrDb(VoiceConsentAudio.pcm16k(wav), rate: 16_000)
        return VoiceTrainingSample(wav: wav, speech16k: [], seconds: seconds, source: "project", snrDb: snr)
    }
}
