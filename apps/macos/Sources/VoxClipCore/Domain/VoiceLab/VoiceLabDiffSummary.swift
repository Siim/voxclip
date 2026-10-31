import Foundation

public struct VoiceLabDiffSummaryResult: Sendable, Equatable {
    public let cutCount: Int
    public let revoicedPhrases: Int
    public let estimateSeconds: Double
    public let costEstimate: CostEstimate?
    public let copy: String
}

public enum VoiceLabDiffSummary {
    /// §8.2 header over a review's hunks after every merge: a passage's `VoiceLabWordDiff` hunks, or a clip or Full take's
    /// `ScopeRewriteDiff` hunks.
    public static func make(hunks: [VoiceLabDiffHunk], meters: [VoiceLabFitMeterResult], catalog: VoiceLabPriceCatalog? = nil,
                            model: String? = nil, candidates: Int = 1, characterMultiplier: Double? = nil,
                            patchTexts: [String?]? = nil) throws -> VoiceLabDiffSummaryResult {
        let voice: [VoiceLabDiffHunk] = hunks.filter { $0.kind == .voice }
        guard meters.count == voice.count, patchTexts == nil || patchTexts?.count == voice.count else {
            throw VoiceLabLengthBudgetError.invalidInput
        }
        var cutIds: Set<String> = []
        for hunk in hunks where hunk.kind == .cut { cutIds.formUnion(hunk.sourceWordIds) }
        var seconds: Double = 0
        for meter in meters {
            guard meter.estimateSeconds.isFinite, meter.estimateSeconds >= 0 else { throw VoiceLabLengthBudgetError.invalidInput }
            seconds += meter.estimateSeconds
        }
        guard seconds.isFinite else { throw VoiceLabLengthBudgetError.invalidInput }
        var cost: CostEstimate?
        if let catalog, !voice.isEmpty, let patchTexts, patchTexts.allSatisfy({ $0 != nil }) {
            let texts: [String] = patchTexts.compactMap { $0 }
            let characters: Int = texts.reduce(0) { (total: Int, text: String) -> Int in
                total + text.unicodeScalars.count
            }
            let units: Double = Double(characters)
            cost = try VoiceLabPricing.estimate(operation: .elevenLabsTextToSpeech, model: model, units: units,
                                                candidates: candidates, characterMultiplier: characterMultiplier, catalog: catalog)
        }
        let cuts: String = cutIds.count == 1 ? "1 cut" : "\(cutIds.count) cuts"
        let phrases: String = voice.count == 1 ? "1 re-voiced phrase" : "\(voice.count) re-voiced phrases"
        var copy: String = "\(cuts) · \(phrases) (\(toFixed1(seconds)) s of AI voice)"
        if let usd = cost?.usd { copy += " · " + VoiceLabCostPresentation.format(usd) }
        return VoiceLabDiffSummaryResult(cutCount: cutIds.count, revoicedPhrases: voice.count, estimateSeconds: seconds,
                                         costEstimate: cost, copy: copy)
    }
}
