import Foundation
import AVFoundation
import CoreVideo
import VoxClipCore

/// Sole per-frame composition path; architecture §5.4.
/// Sendability invariant: skeleton is stateless; future render work must stay on one serial queue with immutable snapshots.
public final class FrameCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    public var sourcePixelBufferAttributes: [String: any Sendable]? { [kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_32BGRA], kCVPixelBufferMetalCompatibilityKey as String: true] }
    public var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] { [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferMetalCompatibilityKey as String: true] }
    public override init() { super.init() }
    /// Placeholder: no render resources are allocated.
    public func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        // TODO(mac-media)
    }
    public func startRequest(_ request: AVAsynchronousVideoCompositionRequest) { request.finish(with: VoxClipError.notImplemented("mac-media")) }
    /// Placeholder: startRequest finishes synchronously, so no queued requests exist.
    public func cancelAllPendingVideoCompositionRequests() {
        // TODO(mac-media)
    }
}

/// Immutable instruction snapshot; architecture §5.4.
/// Sendability invariant: all stored values are immutable and no AVFoundation graph is retained.
public final class RenderInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    public let timeRange: CMTimeRange
    public let sourceTrackID: CMPersistentTrackID
    public let request: RenderRequest
    public let enablePostProcessing = false
    public let containsTweening = true
    public var requiredSourceTrackIDs: [NSValue]? { [NSNumber(value: sourceTrackID)] }
    public let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
    public init(timeRange: CMTimeRange, sourceTrackID: CMPersistentTrackID, request: RenderRequest) { self.timeRange = timeRange; self.sourceTrackID = sourceTrackID; self.request = request; super.init() }
}
