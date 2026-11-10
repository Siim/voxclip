import CoreGraphics
import Dispatch

/// Where every Vision `perform` runs. `perform` is synchronous, and text recognition waits inside it on work that needs a
/// free Swift concurrency thread. Called from a task, it holds a cooperative thread while it waits for another one, so
/// once the pool is full (three threads on a 3-core CI runner) the process stops for good.
/// - 2026-11-08: the frame analyzer's lanes did this (lead).
/// - `ClipEffectVision` did it from the Media suite's Vision test (CI 42770795464 on 2026-11-10, most likely 42580229744 too).
/// A one-thread pool (`LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`) reproduces it. On the main actor (the editor's
/// Ask Claude) the same call froze the window for the whole look instead.
enum VisionQueue {
    static let queue = DispatchQueue(label: "voxclip.frames.vision", qos: .userInitiated, attributes: .concurrent)

    /// `work` on the Vision queue, off the cooperative pool and the main thread.
    static func run<Result: Sendable>(_ image: CGImage, _ work: @escaping @Sendable (CGImage) throws -> Result) async throws -> Result {
        let frame = UncheckedImage(image)
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Swift.Result { try work(frame.image) }) }
        }
    }

    /// Stops a debug build (every test run) when synchronous Vision runs anywhere but `queue`, so a new caller fails its
    /// test at once instead of hanging the 3-core runner now and then.
    static func assertOnQueue() {
        #if DEBUG
        dispatchPrecondition(condition: .onQueue(queue))
        #endif
    }

    /// A decoded frame handed to the Vision queue; the caller never touches it again while Vision reads it.
    private struct UncheckedImage: @unchecked Sendable {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }
}
