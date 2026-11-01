import Foundation
import VoxClipCore

struct RewriteHunkReview: Sendable {
    let hunk: VoiceLabDiffHunk
    let window: VoiceLabWindow?
    let patchText: String?
    let meter: VoiceLabFitMeterResult?
    let refusal: String?
}
/// A proposal's voice review (impl-plan V13): the patch budget over its changes, each voice change placed in the take
/// with its fit, and their summary. Free changes need no review. Placing a change reads the whole take, so a run and an
/// edit outside the scope build it off the main actor (impl-plan §3.1).
struct RewriteReview: Sendable {
    /// What a review reads: the session's take, project, render scope, envelope and prices, as one value.
    struct Inputs: Sendable {
        let transcript: [TimedWord]
        let project: Project
        let scope: VoiceLabOutputScope
        let envelope: AudioEnvelope?
        let prices: VoiceLabPriceCatalog?
        let synthesisModel: String?
    }
    let hunks: [VoiceLabDiffHunk]
    let budget: VoiceLabPatchBudgetResult
    let voiceHunks: [RewriteHunkReview]
    let summary: VoiceLabDiffSummaryResult?

    /// Takes are made from each voice change's window and patch text, so takes made for `other` fit this review too.
    func makesTheSameTakes(as other: RewriteReview) -> Bool {
        voiceHunks.map(\.window) == other.voiceHunks.map(\.window) && voiceHunks.map(\.patchText) == other.voiceHunks.map(\.patchText)
    }

    static func build(_ hunks: [VoiceLabDiffHunk], _ inputs: Inputs) throws -> RewriteReview {
        let budget = VoiceLabPatchBudget.evaluate(hunks: hunks, transcript: inputs.transcript)
        let voice = hunks.filter { (hunk: VoiceLabDiffHunk) -> Bool in hunk.kind == .voice }
        let texts = Dictionary(inputs.transcript.map { ($0.id, $0.text) }, uniquingKeysWith: { first, _ in first })
        var reviews: [RewriteHunkReview] = []
        for hunk in voice {
            do {
                guard let envelope = inputs.envelope else { throw RewriteSessionError.noSourceAudio }
                guard let first = hunk.sourceWordIds.first, let last = hunk.sourceWordIds.last else { throw VoiceLabGeometryError.insertionUnsupported }
                let window = try VoiceLabWindowPlanner.place(project: inputs.project, scope: inputs.scope, envelope: envelope, firstWordId: first, lastWordId: last)
                let silence = try VoiceLabWindowPlanner.lendableSilence(project: inputs.project, scope: inputs.scope, window: window)
                let newWords: String = hunk.newTokens.joined(separator: " ")
                let patchWords: [String] = window.leftBridgeWordIds.map { texts[$0] ?? "" } + [newWords] + window.rightBridgeWordIds.map { texts[$0] ?? "" }
                let patch: String = patchWords.joined(separator: " ")
                let rate = try VoiceLabLengthBudget.rate(transcript: inputs.transcript).charactersPerSecond
                let meter = try VoiceLabFitMeter.measure(text: patch, window: window, incomingSilence: silence.incoming,
                    outgoingSilence: silence.outgoing, rate: rate, newWords: newWords, multipleHunks: voice.count > 1)
                reviews.append(RewriteHunkReview(hunk: hunk, window: window, patchText: patch, meter: meter, refusal: nil))
            } catch {
                reviews.append(RewriteHunkReview(hunk: hunk, window: nil, patchText: nil, meter: nil, refusal: RewriteSession.refusal(error)))
            }
        }
        let complete: Bool = reviews.allSatisfy { $0.meter != nil }
        let summary = complete ? try VoiceLabDiffSummary.make(hunks: hunks, meters: reviews.compactMap(\.meter),
            catalog: inputs.prices, model: inputs.synthesisModel, patchTexts: reviews.map(\.patchText)) : nil
        return RewriteReview(hunks: hunks, budget: budget, voiceHunks: reviews, summary: summary)
    }
}
