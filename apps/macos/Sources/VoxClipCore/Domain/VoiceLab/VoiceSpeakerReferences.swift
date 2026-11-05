import Foundation

/// "Let a video teach your voice" (voice-lab §6.9, ADR-R41). The use-time guard accepts a phrase whose speech matches the
/// consent record's own embedding, or matches a reference learned from the owner's own videos. Every reference passed
/// against the record's own embedding when it was learned and still does: one hop, never a chain. τ never changes.
public enum VoiceSpeakerReferences {
    /// At most this many references per voice; one per project `contentKey`.
    public static let bound = 16
    /// The longest `contentKey` a reference keeps (a SHA-256 hex is 64).
    static let maximumContentKey = 128

    /// How a phrase's speech matched the owner.
    public enum Match: Sendable, Equatable {
        /// Against the consent record's own embedding (the statement, or the attested reference sample).
        case statement(score: Double)
        /// Against a reference learned from the project with this `contentKey`.
        case reference(score: Double, contentKey: String)
        public var score: Double {
            switch self {
            case .statement(let score), .reference(let score, _): score
            }
        }
        public var viaReference: Bool { if case .reference = self { true } else { false } }
    }

    /// The structure `VoiceConsentRecord.validate()` requires of the references. A reference from another speaker model
    /// is well-formed and kept on disk until the next learning drops it; it is never used.
    static func validate(_ speaker: VoiceConsentRecord.Speaker) throws {
        guard let references = speaker.references else { return }
        guard !references.isEmpty, references.count <= bound,
              Set(references.map(\.contentKey)).count == references.count,
              let owner = VoiceConsentRecord.decodeEmbedding(speaker.embedding) else { throw VoiceConsentError.invalidRecord }
        for reference in references {
            guard !reference.contentKey.isEmpty, reference.contentKey.count <= maximumContentKey,
                  reference.contentKey.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }),
                  !reference.model.isEmpty, ISO8601DateFormatter().date(from: reference.addedAt) != nil,
                  reference.statementScore.isFinite, reference.statementScore <= 1.00001,
                  let embedding = VoiceConsentRecord.decodeEmbedding(reference.embedding),
                  reference.model != speaker.model || embedding.count == owner.count else { throw VoiceConsentError.invalidRecord }
        }
    }

    /// The references the guard may use: from the record's own speaker model, and passing against the record's own
    /// embedding when re-checked now. The stored score is not trusted on its own.
    public static func usable(_ speaker: VoiceConsentRecord.Speaker) -> [(contentKey: String, embedding: [Float])] {
        guard let owner = VoiceConsentRecord.decodeEmbedding(speaker.embedding) else { return [] }
        return (speaker.references ?? []).compactMap { reference in
            guard reference.model == speaker.model, reference.statementScore >= speaker.threshold,
                  let embedding = VoiceConsentRecord.decodeEmbedding(reference.embedding), embedding.count == owner.count,
                  let hop = try? SpeakerAudio.cosine(owner, embedding), hop >= speaker.threshold else { return nil }
            return (reference.contentKey, embedding)
        }
    }

    /// The guard's rule: `candidate` matches the record's own embedding, or any usable reference, at the record's τ.
    /// Nil when nothing matches. The statement is tried first, so a phrase that passes on its own is said to.
    public static func match(_ candidate: [Float], speaker: VoiceConsentRecord.Speaker) throws -> Match? {
        guard let owner = VoiceConsentRecord.decodeEmbedding(speaker.embedding) else { throw VoiceConsentError.speakerUnavailable }
        let statement = try SpeakerAudio.cosine(owner, candidate)
        if statement >= speaker.threshold { return .statement(score: statement) }
        var best: Match?
        for reference in usable(speaker) {
            let score = try SpeakerAudio.cosine(reference.embedding, candidate)
            if score >= speaker.threshold, score > (best?.score ?? -1) { best = .reference(score: score, contentKey: reference.contentKey) }
        }
        return best
    }

    /// Why a learning step changed nothing.
    public enum Refusal: Error, Equatable {
        /// The speech doesn't pass against the record's own embedding: it is never stored (one hop).
        case notTheOwner
        /// Another speaker model made it.
        case otherModel
        /// This project already has a reference that scores at least as well.
        case notBetter
    }

    /// The speaker block after learning `embedding` from the project `contentKey`, or the refusal.
    /// - It must pass against the record's own embedding at τ; a reference is never checked against another reference.
    /// - References from another speaker model are dropped (a model change drops them all).
    /// - One per project: the better-scoring of the old and new is kept.
    /// - Over the bound, the most redundant reference goes: the one closest to another (diversity), then the lower score.
    public static func learning(_ embedding: [Float], contentKey: String, model: String, at date: Date,
                                into speaker: VoiceConsentRecord.Speaker) throws -> VoiceConsentRecord.Speaker {
        guard model == speaker.model else { throw Refusal.otherModel }
        guard !contentKey.isEmpty, contentKey.count <= maximumContentKey,
              contentKey.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { throw VoiceLabError.invalidInput }
        guard let owner = VoiceConsentRecord.decodeEmbedding(speaker.embedding), embedding.count == owner.count else { throw VoiceConsentError.speakerUnavailable }
        let normalized = try SpeakerAudio.normalized(embedding)
        let score = try SpeakerAudio.cosine(owner, normalized)
        guard score >= speaker.threshold else { throw Refusal.notTheOwner }
        var kept = (speaker.references ?? []).filter { $0.model == speaker.model }
        if let existing = kept.first(where: { $0.contentKey == contentKey }) {
            guard score > existing.statementScore else { throw Refusal.notBetter }
            kept.removeAll { $0.contentKey == contentKey }
        }
        kept.append(.init(embedding: VoiceConsentRecord.encodeEmbedding(normalized), contentKey: contentKey,
                          addedAt: VoiceConsentRecord.timestamp(date), statementScore: score, model: model))
        while kept.count > bound { kept.remove(at: try mostRedundant(kept)) }
        return speaker.replacingReferences(kept)
    }

    /// The reference closest to any other (ties: the lower statement score, then the oldest).
    static func mostRedundant(_ references: [VoiceConsentRecord.Speaker.Reference]) throws -> Int {
        let vectors = references.map { VoiceConsentRecord.decodeEmbedding($0.embedding) ?? [] }
        var worst = 0, worstKey = (closeness: -Double.infinity, score: Double.infinity, added: "")
        for index in vectors.indices {
            var closest = -Double.infinity
            for other in vectors.indices where other != index {
                closest = max(closest, try SpeakerAudio.cosine(vectors[index], vectors[other]))
            }
            let key = (closeness: closest, score: references[index].statementScore, added: references[index].addedAt)
            let worse = key.closeness != worstKey.closeness ? key.closeness > worstKey.closeness
                : key.score != worstKey.score ? key.score < worstKey.score : key.added < worstKey.added
            if worse { worst = index; worstKey = key }
        }
        return worst
    }

    /// The number of the owner's videos the guard has learned from (usable references only).
    public static func learnedCount(_ speaker: VoiceConsentRecord.Speaker) -> Int { usable(speaker).count }
}
