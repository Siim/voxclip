import Foundation

/// A word the user said in their own microphone take, timed from the start of the recording (on-device recognition).
public struct VoiceLabSpokenWord: Sendable, Equatable {
    public let text: String
    public let start: Double
    public let end: Double
    public init(text: String, start: Double, end: Double) { self.text = text; self.start = start; self.end = end }
}

/// The user's own microphone take of a Rewrite phrase (voice-lab.md §8.13, design.md §6.3 "Say it myself"). It is real
/// speech in the user's own live voice, so it needs no clone and no voice consent: its recipe names no voice reference
/// and no consent record, its provenance says it was recorded on this Mac, and it costs nothing. Its words are what the
/// on-device recognizer heard, never synthetic. It is stored as a `recorded` segment and rendered like any other
/// accepted take; only its lip sync, if the user chose one, is disclosed as AI.
public enum VoiceLabRecordedTake {
    public static let provider = "microphone"
    public static let endpoint = "local"
    public static let voiceID = "own-microphone"
    public static let region = "local"

    public static func isRecorded(_ provenance: VoiceLabProvenance) -> Bool {
        provenance.provider == provider && provenance.endpoint == endpoint && provenance.voiceId == voiceID &&
            provenance.consentRecordId == nil && provenance.region == region && provenance.pace == nil
    }

    /// The recognized words as the character timing a provider's alignment has: each word's characters share its span
    /// evenly and one space joins two words, so the fit planner reads a recording as it reads a generated take.
    public static func alignment(_ words: [VoiceLabSpokenWord]) -> [VoiceLabCharacterTiming] {
        var timing: [VoiceLabCharacterTiming] = []
        for (index, word) in words.enumerated() {
            let characters = Array(word.text)
            guard !characters.isEmpty, word.end > word.start else { continue }
            if index > 0, let last = timing.last {
                timing.append(VoiceLabCharacterTiming(character: " ", start: last.end, end: max(last.end, word.start)))
            }
            let step = (word.end - word.start) / Double(characters.count)
            for (offset, character) in characters.enumerated() {
                timing.append(VoiceLabCharacterTiming(character: String(character), start: word.start + step * Double(offset),
                    end: offset == characters.count - 1 ? word.end : word.start + step * Double(offset + 1)))
            }
        }
        return timing
    }

    /// The take's accepted candidate. `model` names the on-device recognizer that heard its words.
    public static func candidate(row: VoiceLabTakeRow, input: VoiceLabTakeInput, published: VoiceLabPublishedTake,
                                 model: String, createdAt: Date, videoChoice: VoiceLabVideoMode?) throws -> VoiceLabCandidate {
        guard row.selectable, !row.requiresJoinAdvisoryAcceptance, row.receipt == nil, row.quote == nil, row.generated == nil,
              let take = row.audio, let checked = row.qa, checked.verdict != .failed,
              let jump = checked.values.lufsJumpLu, let peak = checked.values.peakDbfs, let match = checked.values.transcriptMatch,
              checked.values.speakerScore == nil, !model.isEmpty, published.words == take.words,
              published.audio.stretch == 1, published.outDuration.isFinite, published.outDuration > 0,
              let asset = published.assets.first(where: { $0.id == published.audio.assetId }) else { throw VoiceLabProjectError.qaRejected }
        if let advisory = row.acceptedJoinAdvisory {
            guard advisory.seams == checked.joinSeams, advisory.validates(jump: jump, createdAt: createdAt) else { throw VoiceLabProjectError.qaRejected }
        }
        let tokens = VoiceLabTakeQuality.tokens(input.text).count
        let qa = VoiceLabRenderQA(transcriptTokens: tokens, transcriptExact: tokens <= 5 ? match == 1 : nil,
            transcriptMatch: match, lufsJumpLu: jump, peakDbfs: peak, speakerScore: nil, speakerThreshold: nil,
            speakerModel: nil, speakerPassed: nil, joinAdvisory: row.acceptedJoinAdvisory)
        let request = row.id.uuidString.lowercased()
        var provenance = VoiceLabProvenance(provider: provider, endpoint: endpoint, model: model, voiceId: voiceID,
            consentRecordId: nil, requestId: request, seed: row.seed, createdAt: createdAt)
        provenance.region = region
        let words = published.words.map { VoiceLabWord(text: $0.text, start: $0.start, end: $0.end, synthetic: false) }
        return try VoiceLabRecipeBuilder.assemble(row: row, take: take, input: input, published: published, asset: asset,
            videoChoice: videoChoice, words: words, qa: qa, provenance: provenance, cost: VoiceLabCost(quoteId: request, usd: 0),
            voiceRefId: nil, consentVerifiedAt: nil)
    }

    public static func segment(id: String, candidate: VoiceLabCandidate, input: VoiceLabTakeInput,
                               plan: VoiceLabFitPlan) throws -> VoiceLabSegment {
        try VoiceLabRecipeBuilder.segment(id: id, candidates: [candidate], selected: 0, input: input, plan: plan, kind: .recorded)
    }

    /// The v3 rules a recorded recipe keeps beyond every recipe's (VoiceLabRenderValidation): recorded provenance, no voice
    /// reference or consent, no speaker score, free, and recognized words that pass the word check.
    static func validate(_ recipe: VoiceLabRenderRecipe, sampleRate rate: Double, outputSamples out: Int64) throws {
        guard isRecorded(recipe.provenance), recipe.voiceSource == .own, recipe.voiceRefId == nil, recipe.consentVerifiedAt == nil,
              recipe.qa.shortSpeech == nil, recipe.qa.speakerScore == nil, recipe.qa.speakerPassed == nil,
              recipe.cost.usd == 0 else { throw VoiceLabProjectError.invalidSegment }
        guard let words = recipe.words, !words.isEmpty else { throw VoiceLabProjectError.alignmentUnavailable }
        func samples(_ seconds: Double) -> Int64 { Int64(EditingPrimitives.jsRound(seconds * rate)) }
        var cursor = 0.0
        for word in words {
            guard !word.text.isEmpty, !word.synthetic, word.start.isFinite, word.end.isFinite,
                  word.start >= cursor, word.end > word.start, word.end <= recipe.outDuration,
                  samples(word.end) > samples(word.start), samples(word.end) <= out else { throw VoiceLabProjectError.alignmentUnavailable }
            cursor = word.end
        }
        let qa = recipe.qa
        guard let count = qa.transcriptTokens, count > 0,
              let match = qa.transcriptMatch, match.isFinite, (0...1).contains(match),
              (count <= 5 ? qa.transcriptExact == true : match >= 0.9) else { throw VoiceLabProjectError.qaRejected }
    }
}

extension VoiceLabSegment {
    /// Its speech is generated: every segment but the user's own recorded take.
    public var hasAISpeech: Bool { kind != .recorded }
    /// It changes the video with AI: generated speech, or lip sync on the user's own take (the export label's rule).
    public var isAIModified: Bool {
        hasAISpeech || (candidates.indices.contains(selectedCandidateIndex) && candidates[selectedCandidateIndex].recipe?.video.mode == .lipsync)
    }
}
