import AVFoundation
import CoreImage
import CoreVideo
import Foundation
import Metal
import VoxClipCore

/// One frame for `FrameCompositor` to draw: AVFoundation's request in preview and export, or a still's captured frames.
protocol CompositorFrame: AnyObject, Sendable {
    var compositionTime: CMTime { get }
    var renderSize: CGSize { get }
    func newPixelBuffer() -> CVPixelBuffer?
    func sourceFrame(byTrackID trackID: CMPersistentTrackID) -> CVPixelBuffer?
    func finish(withComposedVideoFrame composedVideoFrame: CVPixelBuffer)
    func finish(with error: any Error)
    func finishCancelledRequest()
}

extension AVAsynchronousVideoCompositionRequest: CompositorFrame {
    var renderSize: CGSize { renderContext.size }
    func newPixelBuffer() -> CVPixelBuffer? { renderContext.newPixelBuffer() }
}

/// A paused frame of a render, decoded once, for the looks' tiles and the viewer's previews (looks spec 2026-11-28, section
/// 7). `capture` asks AVFoundation for the frames the compositor gets at one rendered time, through the render's own
/// composition, and keeps them; every still is then drawn from them by the same compose as preview and export:
/// - `stillBeforeGrade()` is the framed picture `o` the grade starts from (crop and fill, flip and turns, lip-sync layers,
///   context demo, illustration), for the tiles;
/// - `still(colorOf:)` is the whole frame with other colour controls over the render's framing, captions included, for
///   hover, Compare and drags;
/// - `tile(controls:center:pixels:)` is one look's square tile of `o`, graded by the real kernels.
/// Stills render at the export's output size, so grain and the vignette sit where the export puts them.
public final class ClipStillFrame: @unchecked Sendable {
    let instruction: RenderInstruction
    let frames: [CMPersistentTrackID: CVPixelBuffer]
    /// The frame's rendered time, on the render's frame grid: its grain is the export's at this frame.
    public let renderedTime: CMTime
    /// The export's output size.
    public let size: CGSize

    /// Draws every still, with the same Core Image setup as the export's compositor.
    static let compositor = FrameCompositor()
    static let context: CIContext = {
        let options: [CIContextOption: Any] = [.cacheIntermediates: false, .workingColorSpace: NSNull()]
        return MTLCreateSystemDefaultDevice().map { CIContext(mtlDevice: $0, options: options) } ?? CIContext(options: options)
    }()
    static var colorSpace: CGColorSpace { CGColorSpace(name: CGColorSpace.itur_709)! }

    init(instruction: RenderInstruction, frames: [CMPersistentTrackID: CVPixelBuffer], renderedTime: CMTime, size: CGSize) {
        self.instruction = instruction; self.frames = frames; self.renderedTime = renderedTime; self.size = size
    }

    /// The frame of `graph` at `renderedSeconds` from its start, snapped to the frame grid.
    public static func capture(_ graph: RenderGraph, renderedSeconds: Double) async throws -> ClipStillFrame {
        try await capture(graph.composition, videoComposition: graph.videoComposition, renderedSeconds: renderedSeconds)
    }

    /// The frame of a render's composition (an export graph's, or the preview item's asset and video composition) at
    /// `renderedSeconds`, snapped to the frame grid and kept inside the composition.
    public static func capture(_ asset: AVAsset, videoComposition: AVVideoComposition, renderedSeconds: Double) async throws -> ClipStillFrame {
        let capture = ClipStillCapture()
        var instructions: [RenderInstruction] = []
        for item in videoComposition.instructions {
            guard let instruction = item as? RenderInstruction else { throw VoxClipError.decodeFailed("A still needs the shared frame compositor") }
            instructions.append(instruction.forStill(capture: capture))
        }
        guard let fps = instructions.first?.request.output.fps, fps > 0 else { throw VoxClipError.decodeFailed("A still needs a frame rate") }
        let frameDuration = videoComposition.frameDuration
        let duration = try await asset.load(.duration)
        let last = max(0, Int64((duration.seconds / frameDuration.seconds - 1e-6).rounded(.up)) - 1)
        let index = min(last, Int64(ClipGrain.frameIndex(renderedSeconds: max(0, renderedSeconds), fps: fps)))
        let config = AVVideoComposition.Configuration(colorPrimaries: AVVideoColorPrimaries_ITU_R_709_2,
            colorTransferFunction: AVVideoTransferFunction_ITU_R_709_2, colorYCbCrMatrix: AVVideoYCbCrMatrix_ITU_R_709_2,
            customVideoCompositorClass: FrameCompositor.self, frameDuration: frameDuration, instructions: instructions,
            renderSize: videoComposition.renderSize)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.videoComposition = AVVideoComposition(configuration: config)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        _ = try await generator.image(at: CMTimeMultiply(frameDuration, multiplier: Int32(clamping: index)))
        guard let captured = capture.taken else { throw VoxClipError.decodeFailed("Cannot read the still's frame") }
        return ClipStillFrame(instruction: captured.instruction, frames: captured.frames, renderedTime: captured.time, size: captured.size)
    }

    /// The framed picture `o` just before the grade, at the export's output size (Core Image coordinates from the origin).
    public func stillBeforeGrade() throws -> CIImage {
        do { return try FrameCompositor.framedPicture(request(), instruction: instruction).image }
        catch let failure as FrameCompositor.FrameFailure { throw failure.error }
    }

    /// The whole frame as preview and export draw it at this time, with the colour state of `colorOf` (its look, adjustments
    /// and grade) in place of the clip's: byte for byte the export's frame with that colour, captions and titles included.
    /// The framing stays the render's own (shape, flip, quarter turns, reframe), whatever `colorOf` holds; nil removes the
    /// colour state, for Compare's As filmed.
    public func still(colorOf controls: ProjectClipControls?) async throws -> CGImage {
        var render = instruction.request
        render.clipControls = Self.colour(of: controls, over: render.clipControls)
        let buffer = try await request().rendered(by: Self.compositor, instruction: instruction.forStill(request: render))
        return try Self.image(buffer)
    }

    /// `framing` with the look, adjustments and grade of `colour` (none when nil); nil when nothing is left to render.
    static func colour(of colour: ProjectClipControls?, over framing: ProjectClipControls?) -> ProjectClipControls? {
        var merged = framing ?? ProjectClipControls(clipId: colour?.clipId ?? "")
        merged.look = colour?.look ?? .original
        merged.colorAdjustments = colour?.colorAdjustments
        merged.colorGrade = colour?.colorGrade
        return merged.isDefault ? nil : merged
    }

    /// One look's tile: `o` graded with `controls` (P, L, A, T and the mix) as the export grades it, then the square centred
    /// on `center` (the face anchor in the output frame, normalised from the top left; nil for the middle) and kept inside
    /// it, scaled to `pixels` × `pixels` by the compositor's scaler, then the vignette at the tile's own size. Grading before
    /// scaling keeps the tile the export's frame scaled down (the grade isn't linear, so scaling first would differ at
    /// edges); the colour kernels only run where the scaler reads. Grain is left out: its cells vanish at tile size.
    public func tile(controls: ProjectClipControls, center: (x: Double, y: Double)?, pixels: Int) throws -> CGImage {
        let side = min(size.width, size.height), output = CGSize(width: pixels, height: pixels)
        let square = CompositionFrameGeometry.centered(CGRect(x: 0, y: 0, width: side, height: side), in: CGRect(origin: .zero, size: size),
                                                       x: center?.x ?? 0.5, y: center?.y ?? 0.5)
        let recipe = ClipGradeRecipe(controls: controls)
        let graded = try ClipPicture.grade(try stillBeforeGrade(), recipe: recipe)
        let scaled = CompositionFrameGeometry.fill(graded, crop: square, output: output)
        let finished = try ClipPicture.finish(scaled, recipe: recipe, width: pixels, height: pixels, frameIndex: 0, hole: nil, grain: false)
        return try Self.image(finished, size: output)
    }

    private func request() -> StillFrameRequest {
        StillFrameRequest(compositionTime: renderedTime, renderSize: size, frames: frames)
    }

    /// A compositor frame as an image, its bytes as drawn (BGRA, tagged Rec. 709 like the frame).
    static func image(_ buffer: CVPixelBuffer) throws -> CGImage {
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { throw VoxClipError.decodeFailed("Cannot read the still") }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer), stride = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw VoxClipError.decodeFailed("Cannot read the still") }
        var data = Data(count: 4 * width * height)
        data.withUnsafeMutableBytes { target in
            for row in 0..<height {
                memcpy(target.baseAddress! + 4 * width * row, base + stride * row, 4 * width)
            }
        }
        return try image(data, width: width, height: height,
                         info: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    }

    /// A Core Image picture as a BGRA image through the stills' context, unmanaged like the compositor's.
    static func image(_ picture: CIImage, size: CGSize) throws -> CGImage {
        let width = Int(size.width), height = Int(size.height)
        var data = Data(count: 4 * width * height)
        data.withUnsafeMutableBytes { target in
            context.render(picture, toBitmap: target.baseAddress!, rowBytes: 4 * width, bounds: CGRect(origin: .zero, size: size),
                           format: .BGRA8, colorSpace: nil)
        }
        return try image(data, width: width, height: height,
                         info: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    }

    private static func image(_ data: Data, width: Int, height: Int, info: UInt32) throws -> CGImage {
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4 * width,
                                  space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider, decode: nil,
                                  shouldInterpolate: true, intent: .defaultIntent) else {
            throw VoxClipError.decodeFailed("Cannot make the still's image")
        }
        return image
    }
}

/// Keeps the frames the compositor was given for a still's capture.
final class ClipStillCapture: @unchecked Sendable {
    struct Captured {
        let instruction: RenderInstruction
        let frames: [CMPersistentTrackID: CVPixelBuffer]
        let time: CMTime
        let size: CGSize
    }

    private let lock = NSLock()
    private var captured: Captured?

    func keep(_ request: any CompositorFrame, instruction: RenderInstruction) {
        var frames: [CMPersistentTrackID: CVPixelBuffer] = [:]
        for value in instruction.requiredSourceTrackIDs ?? [] {
            guard let id = (value as? NSNumber)?.int32Value, let frame = request.sourceFrame(byTrackID: id) else { continue }
            frames[id] = frame
        }
        let kept = Captured(instruction: instruction.forStill(), frames: frames, time: request.compositionTime, size: request.renderSize)
        lock.withLock { captured = kept }
    }

    var taken: Captured? { lock.withLock { captured } }
}

/// A still's frame for the compositor: the captured source frames, and the drawn frame handed back.
final class StillFrameRequest: CompositorFrame, @unchecked Sendable {
    let compositionTime: CMTime
    let renderSize: CGSize
    private let frames: [CMPersistentTrackID: CVPixelBuffer]
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Drawn, any Error>?

    struct Drawn: @unchecked Sendable { let buffer: CVPixelBuffer }

    init(compositionTime: CMTime, renderSize: CGSize, frames: [CMPersistentTrackID: CVPixelBuffer]) {
        self.compositionTime = compositionTime; self.renderSize = renderSize; self.frames = frames
    }

    func rendered(by compositor: FrameCompositor, instruction: RenderInstruction) async throws -> CVPixelBuffer {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Drawn, any Error>) in
            lock.withLock { self.continuation = continuation }
            compositor.renderStill(self, instruction: instruction)
        }.buffer
    }

    func newPixelBuffer() -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [kCVPixelBufferMetalCompatibilityKey as String: true, kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()]
        CVPixelBufferCreate(kCFAllocatorDefault, Int(renderSize.width), Int(renderSize.height), kCVPixelFormatType_32BGRA,
                            attributes as CFDictionary, &buffer)
        return buffer
    }

    func sourceFrame(byTrackID trackID: CMPersistentTrackID) -> CVPixelBuffer? { frames[trackID] }

    func finish(withComposedVideoFrame composedVideoFrame: CVPixelBuffer) { resume(.success(Drawn(buffer: composedVideoFrame))) }

    func finish(with error: any Error) { resume(.failure(error)) }

    func finishCancelledRequest() { resume(.failure(CancellationError())) }

    private func resume(_ result: Result<Drawn, any Error>) {
        let waiting = lock.withLock { () -> CheckedContinuation<Drawn, any Error>? in
            defer { continuation = nil }
            return continuation
        }
        waiting?.resume(with: result)
    }
}
