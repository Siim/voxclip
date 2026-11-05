import Foundation
import VoxClipCore

/// "Learn from my videos" (voice-lab §6.9, ADR-R41): a project's clean speech, verified one hop against the voice's own
/// consent embedding, becomes that project's reference. On this Mac, free; nothing is sent anywhere.
public actor VoiceReferenceLearner {
    public enum Outcome: Sendable, Equatable {
        /// This project's reference was added or replaced with a better one.
        case learned(score: Double)
        /// Its speech passes, and the project's reference already scores at least as well.
        case kept
        /// None of its speech passes against the voice's own consent embedding: nothing is stored.
        case notTheOwner
        /// Too little transcribed speech, an untranscribed project, or media that can't be read.
        case noSpeech
        /// The media is labelled AI modified: it never teaches the voice.
        case generated
        /// The speaker check, the voice or its language isn't available here.
        case unavailable
    }

    /// Candidate stretches of speech per project.
    public static let candidates = 6
    /// The least speech a candidate holds, so the embedding has enough voiced windows.
    public static let minimumSeconds = 6.0

    private let store: VoiceConsentStore
    private let check: VoiceSpeakerCheck
    public init(store: VoiceConsentStore, check: VoiceSpeakerCheck) { self.store = store; self.check = check }

    /// Up to `count` guard selections spread evenly through the transcript, each the words nearest one centre word, in
    /// that word's speaker's turns only, up to 10 s. Selections shorter than `minimumSeconds` are skipped.
    public static func selections(words: [TimedWord], sampleRate: Int, totalFrames: Int, count: Int = candidates) -> [VoiceLabGuardSpeech] {
        let spoken = words.filter { $0.kind == .word && $0.end > $0.start }
        guard !spoken.isEmpty, count > 0, sampleRate > 0 else { return [] }
        let minimum = Int(minimumSeconds * Double(sampleRate))
        var chosen: [VoiceLabGuardSpeech] = []
        for slot in 0..<count {
            let index = min(spoken.count - 1, Int((Double(slot) + 0.5) * Double(spoken.count) / Double(count)))
            let selection = VoiceLabGuardSpeech.select(items: words, start: spoken[index].start, end: spoken[index].end,
                                                       sampleRate: sampleRate, totalFrames: totalFrames)
            if selection.frames >= minimum, !chosen.contains(selection) { chosen.append(selection) }
        }
        return chosen
    }

    /// Learns `project`'s reference for the voice `recordID` from its source `media`.
    public func learn(project: Project, media: URL, recordID: String) async -> Outcome {
        guard let words = project.transcript?.words, let audio = project.media.source.audio, !project.media.source.contentKey.isEmpty
        else { return .noSpeech }
        guard !VoiceLabDisclosureWriter.isLabelled(media) else { return .generated }
        guard let record = try? await store.load(recordID), record.status == .active,
              project.transcript?.language.map({ $0 == record.language }) ?? true,
              check.supports(language: record.language), let model = check.embedder?.modelID, model == record.speaker.model,
              check.threshold == record.speaker.threshold,
              let owner = VoiceConsentRecord.decodeEmbedding(record.speaker.embedding),
              (try? await check.embedder?.validateAvailability()) != nil else { return .unavailable }
        let frames = Int64(EditingPrimitives.jsRound(project.media.source.durationSeconds * Double(audio.sampleRate)))
        var best: (score: Double, embedding: [Float])?
        var embedded = false
        for selection in Self.selections(words: words, sampleRate: audio.sampleRate, totalFrames: Int(frames)) {
            if Task.isCancelled { return .unavailable }
            guard let speech = try? await VoiceLabSourceAudio.guardSpeech(source: media, frames: frames, sampleRate: audio.sampleRate, selection: selection),
                  let embedding = try? await check.embedding(Array(speech.prefix(160_000))),
                  let score = try? VoiceSpeakerCheck.cosine(owner, embedding) else { continue }
            embedded = true
            if score >= record.speaker.threshold, score > (best?.score ?? -1) { best = (score, embedding) }
        }
        guard let best else { return embedded ? .notTheOwner : .noSpeech }
        do {
            try await store.learnReference(recordID: recordID, embedding: best.embedding, contentKey: project.media.source.contentKey, model: model)
            return .learned(score: best.score)
        } catch VoiceSpeakerReferences.Refusal.notBetter {
            return .kept
        } catch { return .unavailable }
    }
}
