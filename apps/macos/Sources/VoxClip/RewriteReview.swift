import Foundation
import VoxClipCore

enum RewriteDiffKind { case equal, removed, inserted, bridge }
struct RewriteDiffRun {
    let text: String
    let kind: RewriteDiffKind
    let sourceID: String?
}
struct RewriteHunkReview {
    let hunk: VoiceLabDiffHunk
    let window: VoiceLabWindow?
    let patchText: String?
    let meter: VoiceLabFitMeterResult?
    let refusal: String?
}
struct RewriteReview {
    let diff: VoiceLabWordDiffResult
    let budget: VoiceLabPatchBudgetResult
    let runs: [RewriteDiffRun]
    let voiceHunks: [RewriteHunkReview]
    let summary: VoiceLabDiffSummaryResult?
    let changeSummary: String
    var accessibleDescription: String {
        runs.map { (run: RewriteDiffRun) -> String in
            switch run.kind {
            case .removed: return run.text + " removed"
            case .inserted: return "insert " + run.text
            case .bridge: return run.text + " bridge"
            case .equal: return run.text
            }
        }.joined(separator: ", ")
    }

    @MainActor static func build(_ session: RewriteSession) throws -> RewriteReview {
        let diff = try VoiceLabWordDiff.diff(source: session.source, newText: session.newWords)
        let budget = VoiceLabPatchBudget.evaluate(diff: diff, transcript: session.transcript)
        let voice = diff.hunks.filter { (hunk: VoiceLabDiffHunk) -> Bool in hunk.kind == .voice }
        var reviews: [RewriteHunkReview] = []
        for hunk in voice {
            do {
                guard let envelope = session.envelope else { throw VoiceLabGeometryError.invalidInput() }
                guard let first = hunk.sourceWordIds.first, let last = hunk.sourceWordIds.last else { throw VoiceLabGeometryError.insertionUnsupported }
                let window = try VoiceLabWindowPlanner.place(project: session.project, scope: session.scope, envelope: envelope, firstWordId: first, lastWordId: last)
                let silence = try VoiceLabWindowPlanner.lendableSilence(project: session.project, scope: session.scope, window: window)
                let newWords: String = hunk.newTokens.joined(separator: " ")
                func text(_ id: String) -> String { session.transcript.first { $0.id == id }?.text ?? "" }
                let patchWords: [String] = window.leftBridgeWordIds.map(text) + [newWords] + window.rightBridgeWordIds.map(text)
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
        let summary = complete ? try VoiceLabDiffSummary.make(diff: diff, meters: reviews.compactMap(\.meter),
            catalog: session.prices, model: session.synthesisModel, patchTexts: reviews.map(\.patchText)) : nil
        let inserted: Int = diff.ops.filter { $0.kind == .insert }.count
        let removed: Int = diff.ops.filter { $0.kind == .delete }.count
        let suffix: String = summary.map { " · about \(toFixed1($0.estimateSeconds)) s" } ?? ""
        return RewriteReview(diff: diff, budget: budget, runs: diffRuns(diff, source: session.source, transcript: session.transcript, reviews: reviews),
            voiceHunks: reviews, summary: summary, changeSummary: "\(inserted) new, \(removed) removed" + suffix)
    }

    private static func diffRuns(_ diff: VoiceLabWordDiffResult, source: [TimedWord], transcript: [TimedWord], reviews: [RewriteHunkReview]) -> [RewriteDiffRun] {
        var bridges = Set(diff.hunks.flatMap(\.bridgeWordIds))
        for review in reviews {
            if let window = review.window { bridges.formUnion(window.leftBridgeWordIds + window.rightBridgeWordIds) }
        }
        let absorbed = Set(diff.hunks.flatMap(\.absorbedItemIds))
        let positions = Dictionary(uniqueKeysWithValues: source.enumerated().map { ($0.element.id, $0.offset) })
        var remaining: [TimedWord] = source.filter { absorbed.contains($0.id) }
        var runs: [RewriteDiffRun] = []
        let sourceIDs = Set(source.map(\.id))
        for word in transcript where bridges.contains(word.id) && !sourceIDs.contains(word.id) && word.start < (source.first?.start ?? 0) {
            runs.append(RewriteDiffRun(text: word.text, kind: .bridge, sourceID: word.id))
        }
        for operation in diff.ops {
            if let id = operation.sourceWordId {
                while let first = remaining.first, (positions[first.id] ?? 0) < (positions[id] ?? 0) {
                    runs.append(RewriteDiffRun(text: first.text, kind: .removed, sourceID: first.id))
                    remaining.removeFirst()
                }
            }
            switch operation.kind {
            case .delete: runs.append(RewriteDiffRun(text: operation.sourceToken ?? "", kind: .removed, sourceID: operation.sourceWordId))
            case .insert: runs.append(RewriteDiffRun(text: operation.newToken ?? "", kind: .inserted, sourceID: nil))
            case .equal:
                if operation.sourceToken != operation.newToken {
                    runs.append(RewriteDiffRun(text: operation.sourceToken ?? "", kind: .removed, sourceID: operation.sourceWordId))
                    runs.append(RewriteDiffRun(text: operation.newToken ?? "", kind: .inserted, sourceID: operation.sourceWordId))
                } else {
                    let kind: RewriteDiffKind = bridges.contains(operation.sourceWordId ?? "") ? .bridge : .equal
                    runs.append(RewriteDiffRun(text: operation.newToken ?? "", kind: kind, sourceID: operation.sourceWordId))
                }
            }
        }
        for word in remaining { runs.append(RewriteDiffRun(text: word.text, kind: .removed, sourceID: word.id)) }
        for word in transcript where bridges.contains(word.id) && !sourceIDs.contains(word.id) && word.start >= (source.last?.end ?? 0) {
            runs.append(RewriteDiffRun(text: word.text, kind: .bridge, sourceID: word.id))
        }
        return runs
    }
}
