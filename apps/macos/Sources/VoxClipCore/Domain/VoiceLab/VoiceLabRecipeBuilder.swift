import Foundation

public struct VoiceLabPublishedTake: Sendable {
    public let assets: [VoiceLabAsset]
    public let audio: VoiceLabAudio
    public let outDuration: Double
    public let words: [VoiceLabWord]
    public let chunks: [VoiceLabChunk]
    public init(assets: [VoiceLabAsset], audio: VoiceLabAudio, outDuration: Double, words: [VoiceLabWord], chunks: [VoiceLabChunk]) {
        self.assets = assets; self.audio = audio; self.outDuration = outDuration; self.words = words; self.chunks = chunks
    }
}

public enum VoiceLabRecipeBuilder {
    public static func candidate(row: VoiceLabTakeRow, input: VoiceLabTakeInput, published: VoiceLabPublishedTake,
                                 record: VoiceConsentRecord, createdAt: Date, videoChoice: VoiceLabVideoMode?) throws -> VoiceLabCandidate {
        guard row.selectable, let take = row.audio, let checked = row.qa, checked.passed,
              let receipt = row.receipt, let quote = row.quote, let jump = checked.values.lufsJumpLu,
              let peak = checked.values.peakDbfs, let match = checked.values.transcriptMatch,
              let score = checked.values.speakerScore, score >= record.speaker.threshold,
              record.status == .active, record.id == input.recordID, receipt.voiceID == record.voiceId,
              receipt.modelID == input.modelID, published.words == take.words,
              published.audio.stretch == 1, published.outDuration.isFinite, published.outDuration > 0,
              let asset = published.assets.first(where: { $0.id == published.audio.assetId }),
              let verifiedAt = ISO8601DateFormatter().date(from: record.attestations.acceptedAt),
              verifiedAt <= createdAt else { throw VoiceLabProjectError.qaRejected }
        let plan = take.fit.plan
        let mode: VoiceLabVideoMode
        if row.fits { mode = .source }
        else {
            guard videoChoice == .retimed else { throw VoiceLabProjectError.videoModeUnsupported }
            mode = .zoomCover
        }
        let rate = Double(input.sourceSampleRate)
        let roundedSamples = EditingPrimitives.jsRound(published.outDuration * rate)
        guard input.sourceSampleRate > 0, asset.sampleRate > 0,
              roundedSamples.isFinite, roundedSamples > 0, roundedSamples < Double(Int64.max),
              plan.windowStartSample >= 0, plan.windowEndSample > plan.windowStartSample else { throw VoiceLabProjectError.invalidRange }
        let outputSamples = Int64(roundedSamples)
        let factor = Double(plan.windowEndSample - plan.windowStartSample) / Double(outputSamples)
        guard mode != .zoomCover || (0.80...1.25).contains(factor) else { throw VoiceLabProjectError.videoModeUnsupported }
        func seam(_ edge: VoiceLabSeamPlacement, incoming: Bool) throws -> VoiceLabSeam {
            guard edge.fadeSamples >= 0 else { throw VoiceLabProjectError.invalidFadeHandles }
            let inner = incoming ? edge.fadeSamples / 2 : edge.fadeSamples - edge.fadeSamples / 2
            let assetRate = Double(asset.sampleRate)
            let raw = Double(inner) * assetRate / rate
            let rounded = abs(raw - raw.rounded()) <= 4 * raw.ulp ? raw.rounded() : ceil(raw)
            guard rounded.isFinite, rounded >= 0, rounded < Double(Int64.max) else { throw VoiceLabProjectError.invalidFadeHandles }
            let frames = Int64(rounded)
            return VoiceLabSeam(kind: edge.kind, fadeSamples: edge.fadeSamples,
                sourceHandleSamples: edge.fadeSamples - inner, assetHandleFrames: frames)
        }
        let tokens = VoiceLabTakeQuality.tokens(input.text).count
        let qa = VoiceLabRenderQA(transcriptTokens: tokens, transcriptExact: tokens <= 5 ? match == 1 : nil,
            transcriptMatch: match, lufsJumpLu: jump, peakDbfs: peak, speakerScore: score,
            speakerThreshold: record.speaker.threshold, speakerModel: record.speaker.model, speakerPassed: true)
        var provenance = VoiceLabProvenance(provider: receipt.provider, endpoint: receipt.endpoint, model: input.modelID,
            voiceId: record.voiceId, consentRecordId: record.id, requestId: receipt.requestID.uuidString,
            seed: row.seed, createdAt: createdAt)
        provenance.region = receipt.region.rawValue
        let video = VoiceLabVideoRecipe(mode: mode, sourceStartSample: plan.windowStartSample, sourceEndSample: plan.windowEndSample,
            outputSamples: outputSamples, retimeFactor: mode == .zoomCover ? factor : nil,
            zoom: mode == .zoomCover ? 1.12 : nil, faceX: mode == .zoomCover ? 0.5 : nil, faceY: mode == .zoomCover ? 0.5 : nil, assetId: nil, provider: nil, model: nil, requestId: nil,
            windowStartSample: nil, windowEndSample: nil, syncMode: nil)
        let usd: Double?
        if let synthesis = quote.synthesis.estimate.usd, let qa = quote.qa.estimate.usd { usd = NSDecimalNumber(decimal: synthesis + qa).doubleValue }
        else { usd = nil }
        let cost = VoiceLabCost(quoteId: quote.synthesis.id.uuidString, usd: usd)
        let seams = try VoiceLabSeams(in: seam(input.window.leftSeam, incoming: true), out: seam(input.window.rightSeam, incoming: false))
        let recipe = VoiceLabRenderRecipe(audio: published.audio, words: published.words, outDuration: published.outDuration,
            seed: row.seed, chunks: published.chunks, roomTone: take.roomTone,
            seams: seams, video: video, qa: qa, provenance: provenance, cost: cost, voiceSource: .own, voiceRefId: record.id,
            consentVerifiedAt: verifiedAt)
        var candidate = VoiceLabCandidate(assetId: published.audio.assetId, score: row.score)
        candidate.recipe = recipe
        return candidate
    }

    public static func segment(id: String, candidates: [VoiceLabCandidate], selected: Int, input: VoiceLabTakeInput,
                               plan: VoiceLabFitPlan) throws -> VoiceLabSegment {
        guard candidates.indices.contains(selected), let recipe = candidates[selected].recipe,
              candidates[selected].rejected == nil else { throw VoiceLabProjectError.invalidCandidate }
        let original = input.items.filter { $0.kind == .word && $0.end > plan.windowStart && $0.start < plan.windowEnd }.map(\.text).joined(separator: " ")
        var segment = VoiceLabSegment(id: id, kind: .tts, enabled: true,
            replace: VoiceLabReplacement(start: plan.windowStart, end: plan.windowEnd,
                firstWordId: input.window.firstWordId, lastWordId: input.window.lastWordId),
            outDuration: recipe.outDuration, audio: recipe.audio, text: VoiceLabText(original: original, new: input.text),
            words: recipe.words, provenance: recipe.provenance,
            qa: VoiceLabQA(transcriptMatch: recipe.qa.transcriptMatch, lufsJumpLu: recipe.qa.lufsJumpLu,
                peakDbfs: recipe.qa.peakDbfs, speakerScore: recipe.qa.speakerScore), candidates: candidates, selectedCandidateIndex: selected)
        segment.scope = .passage
        return segment
    }
}
