import Foundation
import VoxClipCore

struct RewriteHunkReview {
    let hunk: VoiceLabDiffHunk
    let window: VoiceLabWindow?
    let patchText: String?
    let meter: VoiceLabFitMeterResult?
    let refusal: String?
}
/// A proposal's voice review (impl-plan V13): the patch budget over its changes, each voice change placed in the take
/// with its fit, and their summary. Free changes need no review.
struct RewriteReview {
    let hunks: [VoiceLabDiffHunk]
    let budget: VoiceLabPatchBudgetResult
    let voiceHunks: [RewriteHunkReview]
    let summary: VoiceLabDiffSummaryResult?

    @MainActor static func build(_ session: RewriteSession) throws -> RewriteReview {
        let hunks = session.changes.map(\.hunk)
        let budget = VoiceLabPatchBudget.evaluate(hunks: hunks, transcript: session.transcript)
        let voice = hunks.filter { (hunk: VoiceLabDiffHunk) -> Bool in hunk.kind == .voice }
        let texts = Dictionary(session.transcript.map { ($0.id, $0.text) }, uniquingKeysWith: { first, _ in first })
        var reviews: [RewriteHunkReview] = []
        for hunk in voice {
            do {
                guard let envelope = session.envelope else { throw VoiceLabGeometryError.invalidInput() }
                guard let first = hunk.sourceWordIds.first, let last = hunk.sourceWordIds.last else { throw VoiceLabGeometryError.insertionUnsupported }
                let window = try VoiceLabWindowPlanner.place(project: session.project, scope: session.scope, envelope: envelope, firstWordId: first, lastWordId: last)
                let silence = try VoiceLabWindowPlanner.lendableSilence(project: session.project, scope: session.scope, window: window)
                let newWords: String = hunk.newTokens.joined(separator: " ")
                let patchWords: [String] = window.leftBridgeWordIds.map { texts[$0] ?? "" } + [newWords] + window.rightBridgeWordIds.map { texts[$0] ?? "" }
                let patch: String = patchWords.joined(separator: " ")
                let rate = try VoiceLabLengthBudget.rate(transcript: session.transcript).charactersPerSecond
                let meter = try VoiceLabFitMeter.measure(text: patch, window: window, incomingSilence: silence.incoming,
                    outgoingSilence: silence.outgoing, rate: rate, newWords: newWords, multipleHunks: voice.count > 1)
                reviews.append(RewriteHunkReview(hunk: hunk, window: window, patchText: patch, meter: meter, refusal: nil))
            } catch {
                reviews.append(RewriteHunkReview(hunk: hunk, window: nil, patchText: nil, meter: nil, refusal: RewriteSession.refusal(error)))
            }
        }
        let complete: Bool = reviews.allSatisfy { $0.meter != nil }
        let summary = complete ? try VoiceLabDiffSummary.make(hunks: hunks, meters: reviews.compactMap(\.meter),
            catalog: session.prices, model: session.synthesisModel, patchTexts: reviews.map(\.patchText)) : nil
        return RewriteReview(hunks: hunks, budget: budget, voiceHunks: reviews, summary: summary)
    }
}
