import Foundation
import VoxClipCore

/// A Rewrite's voice windows, each with its own `VoiceLabTakeRun`, prepared and approved as one `VoiceLabTakeBatch`;
/// voice-lab §8.6 with several hunks and design delta §6 T1. After `approve(_:)` the caller runs the windows one after
/// another in source order, each with its run's `execute(_:approved:progress:started:)`, advances a
/// `VoiceLabTakeBatchProgress` from each result, and calls `discard(from:)` when the progress ends before the last window or
/// the user stops. Each run keeps its own window's takes, so a later window never retires an earlier window's takes.
public struct VoiceLabTakeBatchRun: Sendable {
    /// One run per window, in source order.
    public let runs: [VoiceLabTakeRun]

    public init(runs: [VoiceLabTakeRun]) { self.runs = runs }

    /// Prepares every window's bounded set, one window after another, before anything is shown or approved. `inputs` are
    /// in source order, one per run, and are checked with `VoiceLabTakeBatch.validate(_:)` before any quote. A failure
    /// discards every set this call prepared.
    public func prepare(_ inputs: [VoiceLabTakeInput], id: UUID = UUID()) async throws -> VoiceLabTakeBatch {
        guard inputs.count == runs.count else { throw VoiceLabError.invalidInput }
        try VoiceLabTakeBatch.validate(inputs)
        var windows: [VoiceLabTakeBatch.Window] = []
        do {
            for (run, input) in zip(runs, inputs) {
                let quote = try await run.prepare(input)
                windows.append(.init(input: input, quote: quote))
            }
            return try VoiceLabTakeBatch(id: id, windows: windows)
        } catch {
            for run in runs.prefix(windows.count) { await run.cancel(keepingTakes: true) }
            throw error
        }
    }

    /// The batch's one affirmative approval: pins every window's set (`VoiceLabTakeRun.approve(_:)`) so none expires while
    /// earlier windows run. All or nothing: when any set is no longer fresh, every window's set is discarded and the batch
    /// must be prepared again. Nothing is sent.
    public func approve(_ batch: VoiceLabTakeBatch) async throws {
        guard batch.windows.count == runs.count else { throw VoiceLabError.consentRequired }
        do {
            for (run, window) in zip(runs, batch.windows) { try await run.approve(window.quote) }
        } catch {
            await discard(from: 0)
            throw error
        }
    }

    /// Discards the unsent sets of the windows from `index` on and keeps the takes they already made: after a fatal,
    /// cancelled or invalidated window, and on Stop, which also cancels the window that is running.
    public func discard(from index: Int) async {
        for run in runs.dropFirst(max(0, index)) { await run.cancel(keepingTakes: true) }
    }
}
