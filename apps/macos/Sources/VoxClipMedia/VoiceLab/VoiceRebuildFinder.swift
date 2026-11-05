import Foundation
import VoxClipCore

/// "Rebuild from my videos" (voice-lab §6.12, ADR-R42), on this Mac and free: reads each of the owner's projects, scores
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
        /// Less than 30 s of verified speech across every video.
        case notEnough(milliseconds: Int)
    }

    private let store: VoiceConsentStore
    private let check: VoiceSpeakerCheck
    public init(store: VoiceConsentStore, check: VoiceSpeakerCheck) { self.store = store; self.check = check }

    /// Finds the rebuild set for the voice `recordID` across `sources`. `progress(i, n)` reports the video being read.
    public func find(recordID: String, sources: [Source],
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
        var checked = 0, skipped = 0
        for (index, source) in sources.enumerated() {
            try Task.checkCancellation()
            await progress(index + 1, sources.count)
            let key = source.project.media.source.contentKey
            guard !key.isEmpty, places[key] == nil, source.project.transcript != nil,
                  source.project.transcript?.language.map({ $0 == record.language }) ?? true,
                  !VoiceLabDisclosureWriter.isLabelled(source.media),
                  let found = try? await videoCandidates(source, owner: owner) else { skipped += 1; continue }
            checked += 1
            places[key] = (source.media, found.rate)
            candidates += found.candidates
        }
        let keptMs = kept.map { Int(($0.seconds * 1_000 + 0.5).rounded(.down)) }
        let plan = VoiceRebuild.pick(candidates, threshold: threshold, keptMs: keptMs)
        guard plan.enough else { throw Failure.notEnough(milliseconds: plan.totalMs) }
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

    /// The cleanest qualifying §6.5.1 spans of one video, each scored as its lowest part against the owner.
    private func videoCandidates(_ source: Source, owner: [Float]) async throws -> (rate: Int, candidates: [VoiceRebuild.Candidate]) {
        let levels = try await VoiceTrainingAudio.levels(source: source.media)
        let inputs = VoiceTrainingSpans.inputs(project: source.project)
        let selection = try VoiceTrainingSpans.select(items: inputs.items, excluded: inputs.excluded, frameDb: levels.frameDb, duration: levels.duration)
        let spans = selection.qualifying.sorted { $0.snrDb != $1.snrDb ? $0.snrDb > $1.snrDb : $0.startMs < $1.startMs }
            .prefix(VoiceRebuild.candidatesPerVideo)
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
        return (levels.sampleRate, result)
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
