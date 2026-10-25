import Foundation
import AVFoundation
import VoxClipCore

/// Native probe implementation point; architecture §5.1. No media is opened in the skeleton.
public actor AVMediaProbe: MediaProbe {
    public init() {}
    public func probe(_ source: URL) async throws -> MediaProbeResult { throw VoxClipError.notImplemented("mac-media") }
}

/// Actor-confined AVFoundation graph; architecture §5.1 and §7.1. Intentionally not Sendable.
public struct RenderGraph {
    public let composition: AVMutableComposition
    public let videoTrack: AVMutableCompositionTrack
    public let audioTrack: AVMutableCompositionTrack?
    public let videoComposition: AVVideoComposition
    public let audioMix: AVAudioMix?
    public let renderSize: CGSize
    public let frameDuration: CMTime
    public init(composition: AVMutableComposition, videoTrack: AVMutableCompositionTrack, audioTrack: AVMutableCompositionTrack?, videoComposition: AVVideoComposition, audioMix: AVAudioMix?, renderSize: CGSize, frameDuration: CMTime) {
        self.composition = composition; self.videoTrack = videoTrack; self.audioTrack = audioTrack; self.videoComposition = videoComposition; self.audioMix = audioMix; self.renderSize = renderSize; self.frameDuration = frameDuration
    }
}

/// Builds inside the caller's isolation domain; architecture §5.2 and §7.1. Export and preview each own a graph.
public struct CompositionBuilder: Sendable {
    public init() {}
    public func build(_ request: RenderRequest, isolation: isolated (any Actor)? = #isolation) async throws -> RenderGraph { throw VoxClipError.notImplemented("mac-media") }
}

/// Native export implementation point; architecture §5.6.
public actor AVExporter: Exporter {
    public init() {}
    public func export(_ job: ExportJob, progress: @escaping @Sendable (ExportProgress) -> Void) async throws -> ExportResult { throw VoxClipError.notImplemented("mac-media") }
}

/// Per-window serialized exports; architecture §7.1. Skeleton never creates partial output.
public actor ExportQueue: Exporter {
    public init(exporter: any Exporter = AVExporter()) {}
    public func export(_ job: ExportJob, progress: @escaping @Sendable (ExportProgress) -> Void) async throws -> ExportResult { throw VoxClipError.notImplemented("mac-media") }
    /// Placeholder completed progress stream.
    public func progress() -> AsyncStream<ExportProgress> {
        // TODO(mac-media)
        return AsyncStream { $0.finish() }
    }
}

/// Main-actor AVPlayer ownership; architecture §5.5 and §7.1.
@MainActor public final class PreviewPlayerController: PreviewEngine {
    public let player = AVPlayer()
    public let events: AsyncStream<PreviewEvent>
    public private(set) var isPlaying = false
    public private(set) var editedTime: Double = 0
    public init() { events = AsyncStream { $0.finish() } }
    public func load(_ request: RenderRequest) async throws { throw VoxClipError.notImplemented("mac-media") }
    public func update(_ request: RenderRequest) async throws { throw VoxClipError.notImplemented("mac-media") }
    public func seek(to editedTime: Double, exact: Bool) async throws { throw VoxClipError.notImplemented("mac-media") }
    /// Placeholder: remains stopped with no loaded graph.
    public func play() {
        // TODO(mac-media)
    }
    public func pause() { player.pause(); isPlaying = false }
    public func close() { player.pause(); player.replaceCurrentItem(with: nil); isPlaying = false }
}

/// Native thumbnail lookup; architecture §5.1.
public actor ThumbnailService {
    public init() {}
    public func thumbnail(source: URL, at time: Double, maxHeight: Int = 160) async throws -> Data { throw VoxClipError.notImplemented("mac-media") }
}
