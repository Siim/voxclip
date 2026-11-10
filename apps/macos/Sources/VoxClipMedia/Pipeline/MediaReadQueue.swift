import AVFoundation
import Dispatch

/// Where every AVAssetReader pull runs. `copyNextSampleBuffer` is synchronous: it blocks its thread until the reader
/// hands a buffer back, and the reader's own work that delivers it needs a free Swift concurrency thread. The async
/// `outputProvider(for:)` `next()` calls `copyNextSampleBuffer` on whatever thread awaits it. So a pull from a task holds a
/// cooperative thread, and once every cooperative thread holds one (three on a 3-core CI runner) no reader gets its buffer
/// and the process stops for good.
/// - CI 42828823833 (2026-11-10): all three cooperative threads of the Media test process sat in `copyNextSampleBuffer`,
///   two from `MP4CoverEmbedTests.samples` and one from `FalShapedResult.writeAAC24k`'s `provider.next()`.
/// - Locally (14 cores), 13 readers on the pool finish and 14 never do; the same 14 through this queue take 0.3 s.
/// A one-thread pool (`LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`) does NOT reproduce it: a lone reader there finishes, since
/// the work it waits on runs at another QoS. Same family as `VisionQueue`.
/// `MediaReadQueueTests` fails when `copyNextSampleBuffer` or a provider's `next()` appears anywhere else.
package enum MediaReadQueue {
    package static let queue = DispatchQueue(label: "voxclip.media.read", qos: .userInitiated, attributes: .concurrent)

    /// A synchronous reader loop (`copyNext`) on `queue`, off the cooperative pool and the main thread. `work` gets everything it reads
    /// handed over (`sending`): the caller doesn't touch the reader, asset or track while it runs, and gets the result back
    /// on its own executor.
    package static func run<Result>(_ work: sending @escaping () throws -> sending Result) async throws -> sending Result {
        let job = Handoff(work)
        let done = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Handoff<Result>, any Error>) in
            queue.async { continuation.resume(with: Swift.Result { Handoff(try job.value()) }) }
        }
        return done.value
    }

    /// The next buffer of a synchronous reader loop; call it only inside `run`. A debug build (every test run) stops at once
    /// when it runs anywhere but `queue`, so a new loop fails its test instead of hanging the 3-core runner now and then.
    package static func copyNext(_ output: AVAssetReaderOutput) -> CMSampleBuffer? {
        #if DEBUG
        dispatchPrecondition(condition: .onQueue(queue))
        #endif
        return output.copyNextSampleBuffer()
    }

    /// One pull from an async output provider, with `queue` as the task's preferred executor, so the provider's
    /// synchronous `copyNextSampleBuffer` runs there instead of on the caller's cooperative thread.
    package static func next(_ provider: AVAssetReaderOutput.Provider<CMReadySampleBuffer<CMSampleBuffer.DynamicContent>>) async throws -> CMReadySampleBuffer<CMSampleBuffer.DynamicContent>? {
        try await withTaskExecutorPreference(queue) {
            try await provider.next()
        }
    }

    /// What crosses to `queue` and back; `run`'s `sending` contract is what makes it safe.
    private struct Handoff<Value>: @unchecked Sendable {
        let value: Value
        init(_ value: consuming Value) { self.value = value }
    }
}
