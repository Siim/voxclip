import Foundation
import AVFoundation
import CoreImage
import CoreVideo
import ImageIO
import Metal
import Synchronization
import VoxClipCore

/// Mutable render resources are confined to renderQueue; generation is protected by Mutex.
public final class FrameCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    private let renderQueue = DispatchQueue(label: "com.voxclip.frames", qos: .userInitiated)
    private let generation = Mutex<UInt64>(0)
    private let context: CIContext
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let videoColorSpace = CGColorSpace(name: CGColorSpace.itur_709)!
    private var pending: [UUID: (AVAsynchronousVideoCompositionRequest, Task<Void, Never>, CVPixelBuffer)] = [:]
    private var lastSource: (RenderInstruction, Double, CIImage)?

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
        renderQueue.async { self.lastSource = nil }
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
                request.finish(with: VoxClipError.decodeFailed("Cannot allocate video frame")); return
            }
            let size = request.renderContext.size
            var image: CIImage
            if let source = request.sourceFrame(byTrackID: instruction.sourceTrackID) {
                image = CIImage(cvPixelBuffer: source).oriented(instruction.orientation)
                lastSource = (instruction, request.compositionTime.seconds, image)
            } else if let previous = lastSource, previous.0 === instruction, previous.1 <= request.compositionTime.seconds {
                image = previous.2
            } else { image = CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: size)) }
            let crop = Self.centerCrop(source: image.extent, output: size)
            image = image.clampedToExtent().transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
            if instruction.request.forPreview {
                image = image.transformed(by: CGAffineTransform(scaleX: size.width / crop.width, y: size.height / crop.height))
            } else {
                image = image.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: size.height / crop.height,
                                                                                    kCIInputAspectRatioKey: (size.width / crop.width) / (size.height / crop.height)])
            }
            image = image.cropped(to: CGRect(origin: .zero, size: size))
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
        let time = request.compositionTime.seconds
        @Sendable func finishMarked(_ buffer: CVPixelBuffer) {
            guard generation.withLock({ $0 }) == current else { request.finishCancelledRequest(); return }
            do {
                try instruction.disclosure?.draw(into: buffer, at: time)
                request.finish(withComposedVideoFrame: buffer)
            } catch { request.finish(with: error) }
        }
        if let layout = instruction.request.captionLayout {
            do {
                guard let rasterizer = instruction.rasterizer else { throw VoxClipError.sharedResourcesMissing }
                try rasterizer.draw(layout, time: time, into: output,
                    previewWidth: instruction.request.forPreview ? CVPixelBufferGetWidth(output) : nil)
                finishMarked(output)
            } catch { request.finish(with: error) }
            return
        }
        guard let page = instruction.page(at: time), let style = instruction.request.style else {
            finishMarked(output)
            return
        }
        guard let rasterizer = instruction.legacyRasterizer ?? instruction.rasterizer else {
            request.finish(with: VoxClipError.sharedResourcesMissing); return
        }
        let width = CVPixelBufferGetWidth(output)
        let height = CVPixelBufferGetHeight(output)
        let complete: @Sendable (CaptionRaster, CVPixelBuffer) -> Void = { overlay, buffer in
            guard self.generation.withLock({ $0 }) == current else { request.finishCancelledRequest(); return }
            guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else {
                request.finish(with: VoxClipError.decodeFailed("Cannot lock caption frame")); return
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
                request.finish(with: VoxClipError.decodeFailed("Invalid caption raster")); return
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
                    guard self.pending.removeValue(forKey: id) != nil else { return }
                    if self.generation.withLock({ $0 }) != current || error is CancellationError { request.finishCancelledRequest() }
                    else { request.finish(with: error) }
                }
            }
        }
        pending[id] = (request, task, output)
    }

    static func centerCrop(source: CGRect, output: CGSize) -> CGRect {
        let crop = OutputSizing.centerCrop(
            source: PixelSize(width: Int(source.width.rounded()), height: Int(source.height.rounded())),
            output: PixelSize(width: Int(output.width.rounded()), height: Int(output.height.rounded())))
        return CGRect(x: source.minX + crop.x, y: source.minY + crop.y,
                      width: crop.width, height: crop.height)
    }
}

/// All instruction snapshots are immutable; no AVFoundation object graph is retained.
public final class RenderInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    public let timeRange: CMTimeRange
    public let sourceTrackID: CMPersistentTrackID
    public let request: RenderRequest
    public let enablePostProcessing = false
    public let containsTweening = true
    public var requiredSourceTrackIDs: [NSValue]? { [NSNumber(value: sourceTrackID)] }
    public let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
    let orientation: CGImagePropertyOrientation
    let rasterizer: CoreTextCaptionRasterizer?
    let legacyRasterizer: (any CaptionRasterizer)?
    let disclosure: VoiceLabDisclosureOverlay?

    public convenience init(timeRange: CMTimeRange, sourceTrackID: CMPersistentTrackID, request: RenderRequest) {
        self.init(timeRange: timeRange, sourceTrackID: sourceTrackID, request: request, orientation: .up, rasterizer: nil)
    }
    init(timeRange: CMTimeRange, sourceTrackID: CMPersistentTrackID, request: RenderRequest,
         orientation: CGImagePropertyOrientation, rasterizer: CoreTextCaptionRasterizer?,
         legacyRasterizer: (any CaptionRasterizer)? = nil, disclosure: VoiceLabDisclosureOverlay? = nil) {
        self.timeRange = timeRange; self.sourceTrackID = sourceTrackID; self.request = request
        self.orientation = orientation; self.rasterizer = rasterizer; self.legacyRasterizer = legacyRasterizer
        self.disclosure = disclosure; super.init()
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
