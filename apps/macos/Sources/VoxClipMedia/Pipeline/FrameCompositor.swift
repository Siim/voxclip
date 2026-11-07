import Foundation
import AVFoundation
import CoreImage
import CoreVideo
import ImageIO
import Metal
import Synchronization
import VoxClipCore

/// A preview item's compositor failures (design.md §5.4.4 g): the compositor reports each failed or degraded preview frame
/// with its fixed reason, and the item's owner hears about the first one only. Exports never get one.
public final class PreviewFrameFailures: Sendable {
    private let reported = Mutex<[PreviewFailureReason]>([])
    private let onFirst: @Sendable (PreviewFailureReason) -> Void
    public init(onFirst: @escaping @Sendable (PreviewFailureReason) -> Void) { self.onFirst = onFirst }

    /// The reasons reported so far, first first; each reason once.
    public var reasons: [PreviewFailureReason] { reported.withLock { $0 } }

    func report(_ reason: PreviewFailureReason) {
        let first = reported.withLock { reasons -> Bool in
            guard !reasons.contains(reason) else { return false }
            reasons.append(reason)
            return reasons.count == 1
        }
        if first { onFirst(reason) }
    }
}

/// Mutable render resources are confined to renderQueue; generation is protected by Mutex.
public final class FrameCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    private let renderQueue = DispatchQueue(label: "com.voxclip.frames", qos: .userInitiated)
    private let generation = Mutex<UInt64>(0)
    private let context: CIContext
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let videoColorSpace = CGColorSpace(name: CGColorSpace.itur_709)!
    private var pending: [UUID: (AVAsynchronousVideoCompositionRequest, Task<Void, Never>, CVPixelBuffer)] = [:]

    public var sourcePixelBufferAttributes: [String: any Sendable]? {
        [kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_32BGRA],
         kCVPixelBufferMetalCompatibilityKey as String: true]
    }
    public var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferMetalCompatibilityKey as String: true]
    }
    public override init() {
        let options: [CIContextOption: Any] = [.cacheIntermediates: false, .workingColorSpace: NSNull()]
        if let device = MTLCreateSystemDefaultDevice() { context = CIContext(mtlDevice: device, options: options) }
        else { context = CIContext(options: options) }
        super.init()
    }
    public func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        renderQueue.async { self.context.clearCaches() }
    }

    public func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        let current = generation.withLock { $0 }
        renderQueue.async {
            guard self.generation.withLock({ $0 }) == current else { request.finishCancelledRequest(); return }
            guard let instruction = request.videoCompositionInstruction as? RenderInstruction else {
                request.finish(with: VoxClipError.decodeFailed("Missing render instruction")); return
            }
            self.render(request, instruction: instruction, generation: current)
        }
    }

    public func cancelAllPendingVideoCompositionRequests() {
        generation.withLock { $0 &+= 1 }
        renderQueue.async {
            for (request, task, _) in self.pending.values {
                task.cancel()
                request.finishCancelledRequest()
            }
            self.pending.removeAll()
        }
    }

    private func render(_ request: AVAsynchronousVideoCompositionRequest, instruction: RenderInstruction,
                        generation current: UInt64) {
        autoreleasepool {
            guard generation.withLock({ $0 }) == current else { request.finishCancelledRequest(); return }
            guard let output = request.renderContext.newPixelBuffer() else {
                fail(request, instruction, .frameBuffer, VoxClipError.decodeFailed("Cannot allocate video frame")); return
            }
            let size = request.renderContext.size
            guard let source = request.sourceFrame(byTrackID: instruction.sourceTrackID) else {
                fail(request, instruction, .sourceFrame, VoxClipError.decodeFailed("Missing source video frame")); return
            }
            let controls = instruction.request.clipControls
            // Captions, motion, effects and Voice Lab layers keep edited times; a clip's speed scales the rendered clock.
            let editedTime = instruction.request.speedTiming.edited(request.compositionTime.seconds)
            var image = ClipPicture.orient(CIImage(cvPixelBuffer: source).oriented(instruction.orientation), controls: controls)
            let sourceExtent = image.extent
            let aspectCrop = Self.aspectCrop(source: image.extent, output: size, controls: controls)
            var crop = aspectCrop
            if instruction.videoZoom > 1 {
                let anchor = controls?.mapAnchor(x: instruction.videoAnchorX, y: instruction.videoAnchorY)
                    ?? (x: instruction.videoAnchorX, y: instruction.videoAnchorY)
                crop = CompositionFrameGeometry.faceCrop(in: image.extent, aspectCrop: crop, scale: instruction.videoZoom,
                    faceX: anchor.x, faceY: anchor.y)
            }
            image = CompositionFrameGeometry.fill(image, crop: crop, output: size)
            if let correction = instruction.colorCorrection {
                image = image.applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: correction.scale, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: correction.scale, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: correction.scale, w: 0),
                    "inputBiasVector": CIVector(x: correction.bias, y: correction.bias, z: correction.bias, w: 0)])
            }
            for layers in Dictionary(grouping: instruction.lipsyncLayers, by: \.trackID).values {
                let time = editedTime
                let weighted = layers.map { layer in
                    (layer, LipsyncFrameBlend.weight(time: time, start: layer.output.start.seconds,
                        end: layer.output.end.seconds, fps: instruction.request.output.fps))
                }
                guard let (layer, weight) = weighted.max(by: { $0.1 < $1.1 }), weight > 0 else { continue }
                guard let frame = request.sourceFrame(byTrackID: layer.trackID) else {
                    fail(request, instruction, .lipsyncFrame, LipsyncError.invalidMedia); return
                }
                let captured = ClipPicture.orient(CIImage(cvPixelBuffer: frame).oriented(layer.orientation), controls: controls)
                let replacement = CompositionFrameGeometry.fill(captured,
                    crop: Self.aspectCrop(source: captured.extent, output: size, controls: controls), output: size)
                image = replacement.applyingFilter("CIDissolveTransition", parameters: [
                    kCIInputTargetImageKey: image, kCIInputTimeKey: 1 - weight])
            }
            if let layer = instruction.demoLayer {
                // A context demo (a screen recording) keeps its own orientation: the clip's flip and quarter turns correct
                // the camera's picture, and a mirrored or sideways screen would be unreadable (design.md §6.9). It fills the
                // clip's frame, turned or not, like any other shape.
                guard let demo = request.sourceFrame(byTrackID: layer.trackID) else {
                    fail(request, instruction, .demoFrame, VoxClipError.decodeFailed("Missing context-demo video frame")); return
                }
                let captured = CIImage(cvPixelBuffer: demo).oriented(layer.orientation)
                image = CompositionFrameGeometry.fill(captured,
                    crop: Self.centerCrop(source: captured.extent, output: size), output: size)
            }
            let sourceTime = instruction.request.timeline.sourceTime(editedTime)
            // The look grades the picture before any Ask Claude effect: censors cover graded pixels, and pointers, titles
            // and stickers keep their own colours. A colour transform per pixel, so it commutes with the motion crop.
            if let look = controls?.look, look != .original { image = ClipPicture.look(image, look) }
            if let effects = instruction.effects {
                image = effects.picture(image, source: sourceExtent, crop: crop, output: size, time: effects.input.pictureTime(sourceTime),
                                        controls: controls)
            }
            let motion = MotionCue.transform(atSourceTime: sourceTime,
                clipID: instruction.request.motionClipID, cues: instruction.request.motionCues,
                reduceMotion: instruction.request.forPreview && instruction.request.reduceMotion)
            if motion != .identity {
                let motionCrop = CompositionFrameGeometry.crop(in: CGRect(origin: .zero, size: size),
                    scale: motion.scale, anchorX: motion.anchorX, anchorY: motion.anchorY)
                image = CompositionFrameGeometry.fill(image, crop: motionCrop, output: size)
            }
            if let effects = instruction.effects {
                let timeline = instruction.request.timeline
                // A title, lower third or sticker that can't be drawn is left out of the frame; preview says so.
                image = effects.frame(image, output: size, time: sourceTime, outputTime: editedTime, mapTime: { timeline.mapTime($0) },
                                      overlayFailed: { instruction.previewFailures?.report(.title) })
            }
            context.render(image, to: output, bounds: CGRect(origin: .zero, size: size), colorSpace: nil)
            CVBufferSetAttachment(output, kCVImageBufferCGColorSpaceKey, videoColorSpace, .shouldPropagate)
            CVBufferSetAttachment(output, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(output, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(output, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
            drawCaptions(request, instruction: instruction, into: output, generation: current)
        }
    }

    private func drawCaptions(_ request: AVAsynchronousVideoCompositionRequest, instruction: RenderInstruction,
                              into output: CVPixelBuffer, generation current: UInt64) {
        let time = instruction.request.speedTiming.edited(request.compositionTime.seconds)
        // The disclosure is never left out: a frame that can't carry it fails, in preview with a message.
        @Sendable func finishMarked(_ buffer: CVPixelBuffer) {
            guard generation.withLock({ $0 }) == current else { request.finishCancelledRequest(); return }
            do {
                try instruction.disclosure?.draw(into: buffer, at: time)
                request.finish(withComposedVideoFrame: buffer)
            } catch { fail(request, instruction, .disclosure, error) }
        }
        // A caption that can't be drawn fails an export; preview shows the frame without it and reports why.
        @Sendable func captionFailed(_ reason: PreviewFailureReason, _ error: any Error, frame buffer: CVPixelBuffer) {
            if instruction.request.forPreview, let failures = instruction.previewFailures {
                failures.report(reason)
                finishMarked(buffer)
            } else { request.finish(with: error) }
        }
        if let layout = instruction.request.captionLayout {
            do {
                guard let rasterizer = instruction.rasterizer else {
                    captionFailed(.resources, VoxClipError.sharedResourcesMissing, frame: output); return
                }
                try (instruction.captionDrawHook ?? Self.drawLayout)(rasterizer, layout, time, output,
                    instruction.request.forPreview ? CVPixelBufferGetWidth(output) : nil)
                finishMarked(output)
            } catch { captionFailed(.captionLayout, error, frame: output) }
            return
        }
        guard let page = instruction.page(at: time), let style = instruction.request.style else {
            finishMarked(output)
            return
        }
        guard let rasterizer = instruction.legacyRasterizer ?? instruction.rasterizer else {
            captionFailed(.resources, VoxClipError.sharedResourcesMissing, frame: output); return
        }
        let width = CVPixelBufferGetWidth(output)
        let height = CVPixelBufferGetHeight(output)
        let complete: @Sendable (CaptionRaster, CVPixelBuffer) -> Void = { overlay, buffer in
            guard self.generation.withLock({ $0 }) == current else { request.finishCancelledRequest(); return }
            guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else {
                captionFailed(.captionRaster, VoxClipError.decodeFailed("Cannot lock caption frame"), frame: buffer); return
            }
            guard overlay.width > 0, overlay.height > 0, overlay.bytesPerRow >= overlay.width * 4,
                  overlay.rgba.count >= overlay.bytesPerRow * overlay.height,
                  let provider = CGDataProvider(data: overlay.rgba as CFData),
                  let caption = CGImage(width: overlay.width, height: overlay.height, bitsPerComponent: 8, bitsPerPixel: 32,
                      bytesPerRow: overlay.bytesPerRow, space: self.colorSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
                  let graphics = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                      bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: self.colorSpace,
                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
                CVPixelBufferUnlockBaseAddress(buffer, [])
                captionFailed(.captionRaster, VoxClipError.decodeFailed("Invalid caption raster"), frame: buffer); return
            }
            graphics.draw(caption, in: CGRect(x: 0, y: 0, width: width, height: height))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            finishMarked(buffer)
        }
        let id = UUID()
        let task = Task {
            do {
                let overlay = try await rasterizer.rasterize(CaptionRasterRequest(page: page, style: style, time: time, width: width, height: height))
                try Task.checkCancellation()
                self.renderQueue.async {
                    guard let (_, _, buffer) = self.pending.removeValue(forKey: id) else { return }
                    complete(overlay, buffer)
                }
            } catch {
                self.renderQueue.async {
                    guard let (_, _, buffer) = self.pending.removeValue(forKey: id) else { return }
                    if self.generation.withLock({ $0 }) != current || error is CancellationError { request.finishCancelledRequest() }
                    else { captionFailed(.captionRaster, error, frame: buffer) }
                }
            }
        }
        pending[id] = (request, task, output)
    }

    /// Fails the frame; a preview frame also reports `reason` to its item (design.md §5.4.4 g). Exports only fail.
    private func fail(_ request: AVAsynchronousVideoCompositionRequest, _ instruction: RenderInstruction,
                      _ reason: PreviewFailureReason, _ error: any Error) {
        if instruction.request.forPreview { instruction.previewFailures?.report(reason) }
        request.finish(with: error)
    }

    /// The shared rasterizer's caption band over `output`; the preview passes its own width.
    static let drawLayout: CaptionLayoutDraw = { rasterizer, layout, time, output, previewWidth in
        try rasterizer.draw(layout, time: time, into: output, previewWidth: previewWidth)
    }

    /// The output frame's crop of the source: centred, or for a portrait or square frame of a clip that follows the face
    /// (`ProjectClipControls.reframe`, ADR-R48), centred on the measured face, kept inside the picture. The centre is
    /// measured on the picture as filmed, so the clip's flip and quarter turns move it with the picture.
    static func aspectCrop(source: CGRect, output: CGSize, controls: ProjectClipControls?) -> CGRect {
        let crop = centerCrop(source: source, output: output)
        guard output.height > 0, let center = controls?.cropCenter(outputAspect: Double(output.width / output.height)) else { return crop }
        let mapped = controls?.mapAnchor(x: center.x, y: center.y) ?? center
        return CompositionFrameGeometry.centered(crop, in: source, x: mapped.x, y: mapped.y)
    }

    static func centerCrop(source: CGRect, output: CGSize) -> CGRect {
        let crop = OutputSizing.centerCrop(
            source: PixelSize(width: Int(source.width.rounded()), height: Int(source.height.rounded())),
            output: PixelSize(width: Int(output.width.rounded()), height: Int(output.height.rounded())))
        return CGRect(x: source.minX + crop.x, y: source.minY + crop.y,
                      width: crop.width, height: crop.height)
    }
}

/// Draws a caption layout's band into a frame: (rasterizer, layout, edited time, frame, preview width).
typealias CaptionLayoutDraw = @Sendable (CoreTextCaptionRasterizer, CaptionLayoutResult, Double, CVPixelBuffer, Int?) throws -> Void

/// All instruction snapshots are immutable; no AVFoundation object graph is retained.
public final class RenderInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    public let timeRange: CMTimeRange
    public let sourceTrackID: CMPersistentTrackID
    public let request: RenderRequest
    public let enablePostProcessing = false
    public let containsTweening = true
    public var requiredSourceTrackIDs: [NSValue]? {
        Array(Set([sourceTrackID] + (demoLayer.map { [$0.trackID] } ?? []) + lipsyncLayers.map(\.trackID))).map { NSNumber(value: $0) }
    }
    public let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
    let orientation: CGImagePropertyOrientation
    let rasterizer: CoreTextCaptionRasterizer?
    let legacyRasterizer: (any CaptionRasterizer)?
    let disclosure: VoiceLabDisclosureOverlay?
    let demoLayer: CompositionDemoLayer?
    let lipsyncLayers: [LipsyncVideoLayer]
    let colorCorrection: (scale: Double, bias: Double)?
    let contextDemoLease: ContextDemoCompositionLease?
    let videoZoom: Double
    let videoAnchorX: Double
    let videoAnchorY: Double
    /// The render's picture effects (ai.md §18.5), shared by every instruction of one composition; nil without effects.
    let effects: EffectFrames?
    /// Where a preview item hears about failed or degraded frames; nil for exports.
    let previewFailures: PreviewFrameFailures?
    /// Tests only: replaces the caption layout's draw, to force a failure.
    let captionDrawHook: CaptionLayoutDraw?

    public convenience init(timeRange: CMTimeRange, sourceTrackID: CMPersistentTrackID, request: RenderRequest) {
        self.init(timeRange: timeRange, sourceTrackID: sourceTrackID, request: request, orientation: .up, rasterizer: nil)
    }
    init(timeRange: CMTimeRange, sourceTrackID: CMPersistentTrackID, request: RenderRequest,
         orientation: CGImagePropertyOrientation, rasterizer: CoreTextCaptionRasterizer?,
         legacyRasterizer: (any CaptionRasterizer)? = nil, disclosure: VoiceLabDisclosureOverlay? = nil,
         demoLayer: CompositionDemoLayer? = nil, contextDemoLease: ContextDemoCompositionLease? = nil,
         videoZoom: Double = 1, videoAnchorX: Double = 0.5, videoAnchorY: Double = 0.5,
         lipsyncLayers: [LipsyncVideoLayer] = [], colorCorrection: (scale: Double, bias: Double)? = nil, effects: EffectFrames? = nil,
         previewFailures: PreviewFrameFailures? = nil, captionDrawHook: CaptionLayoutDraw? = nil) {
        self.timeRange = timeRange; self.sourceTrackID = sourceTrackID; self.request = request
        self.orientation = orientation; self.rasterizer = rasterizer; self.legacyRasterizer = legacyRasterizer
        self.disclosure = disclosure; self.demoLayer = demoLayer; self.contextDemoLease = contextDemoLease
        self.videoZoom = videoZoom; self.videoAnchorX = videoAnchorX; self.videoAnchorY = videoAnchorY
        self.lipsyncLayers = lipsyncLayers
        self.colorCorrection = colorCorrection
        self.effects = effects
        self.previewFailures = previewFailures
        self.captionDrawHook = captionDrawHook
        super.init()
    }

    func page(at time: Double) -> CaptionPage? {
        if let layout = request.captionLayout { return layout.page(at: time) }
        let pages = request.captions.pages
        var lower = 0
        var upper = pages.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if pages[middle].end <= time { lower = middle + 1 } else { upper = middle }
        }
        guard lower < pages.count, pages[lower].start <= time, time < pages[lower].end else { return nil }
        return pages[lower]
    }
}
