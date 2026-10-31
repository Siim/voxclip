import Foundation
import VoxClipCore

/// A Rewrite's voice windows, each with its own `VoiceLabTakeRun`, prepared and approved as one `VoiceLabTakeBatch`;
/// voice-lab §8.6 with several hunks and design delta §6 T1. After `approve(_:)` the caller runs the windows one after
/// another in source order with `execute(_:window:progress:started:)`, which discards the rest of the batch itself when a
/// window ends it, and advances a `VoiceLabTakeBatchProgress` from each result. Stop calls `discard(from:)` with the
/// running window. Each run keeps its own window's takes, so a later window never retires an earlier window's takes.
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

    /// Runs window `index` of the approved `batch` with its run's `execute(_:approved:progress:started:)`, under the batch's
    /// one approval. When the window ends the batch (`fatal`, `cancelled` or `invalidated`) or its launch throws, this
    /// window's set and every later window's are discarded before this returns, so nothing more can be sent under the
    /// approval (§8.6: an early end discards the whole unsent remainder; a new run needs a new approval). A window that
    /// completes or stops early leaves the later windows approved. A batch that is not this run's is `consentRequired`.
    public func execute(_ batch: VoiceLabTakeBatch, window index: Int,
                        progress: @escaping @Sendable ([VoiceLabTakeRow]) async -> Void = { _ in },
                        started: @escaping @Sendable () async throws -> Void = {}) async throws -> VoiceLabTakeRunResult {
        guard batch.windows.count == runs.count, runs.indices.contains(index) else { throw VoiceLabError.consentRequired }
        let result: VoiceLabTakeRunResult
        do {
            result = try await runs[index].execute(batch.windows[index].quote, approved: true, progress: progress, started: started)
        } catch {
            await discard(from: index)
            throw error
        }
        switch result.end {
        case .completed, .earlyStop: break
        case .cancelled, .invalidated, .fatal: await discard(from: index)
        }
        return result
    }

    /// Discards the unsent sets of the windows from `index` on and keeps the takes they already made: on Stop, which also
    /// cancels the window that is running, and when a window ends the batch.
    public func discard(from index: Int) async {
        for run in runs.dropFirst(max(0, index)) { await run.cancel(keepingTakes: true) }
    }
}
