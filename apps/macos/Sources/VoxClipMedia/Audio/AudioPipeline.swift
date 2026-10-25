import Foundation
import VoxClipCore

/// Streaming native audio extractor; architecture §5.1. Skeleton never creates cache files.
public actor AVAudioExtractor: AudioExtractor {
    public init() {}
    public func extract(_ request: AudioExtractionRequest, progress: @escaping @Sendable (Double) -> Void) async throws -> AudioExtractionResult { throw VoxClipError.notImplemented("mac-media") }
}

/// Immutable sample-grid fade context; architecture §5.3. Gain arithmetic belongs to Core.
public final class FadeContext: Sendable {
    public let plan: EditPlan
    public init(plan: EditPlan) { self.plan = plan }
    public func gain(_ sample: Int64) -> Double { plan.joinGain(at: sample) }
}

/// Real-time tap construction point; architecture §5.3. Never allocate, lock or log inside a processing callback.
public struct FadeTap: Sendable {
    public init() {}
    public func prepare(plan: EditPlan) throws -> FadeContext { throw VoxClipError.notImplemented("mac-media") }
}
