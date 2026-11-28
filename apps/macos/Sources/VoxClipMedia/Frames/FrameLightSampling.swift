import CoreGraphics
import Foundation
import ImageIO
import VoxClipCore

/// The small pictures the light facts and Auto read (looks spec §5.9, §9.3): a frame scaled so its long side is `edge`
/// (never up), drawn into 8-bit sRGB and read as RGB bytes, rows from the top, with the frame's face box.
public enum FrameLightSampling {
    /// `image` at `edge` pixels on the long side, with `face` (picture space, top-left origin); nil when it can't be drawn.
    public static func sample(_ image: CGImage, edge: Int, face: ClipEffect.Rect?) -> ClipFrameSample? {
        guard image.width > 0, image.height > 0, edge > 0 else { return nil }
        let longest = max(image.width, image.height)
        let scale = longest > edge ? Double(edge) / Double(longest) : 1
        let width = max(1, Int((Double(image.width) * scale).rounded())), height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        let bytes = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var rgb = [UInt8](repeating: 0, count: width * height * 3)
        // A bitmap context's memory holds the top row first.
        for pixel in 0..<(width * height) {
            rgb[pixel * 3] = bytes[pixel * 4]
            rgb[pixel * 3 + 1] = bytes[pixel * 4 + 1]
            rgb[pixel * 3 + 2] = bytes[pixel * 4 + 2]
        }
        return ClipFrameSample(width: width, height: height, rgb: rgb, face: face)
    }

    /// A sheet JPEG at `edge` pixels on the long side, with `face`; nil when the bytes are not an image.
    public static func sample(jpeg: Data, edge: Int, face: ClipEffect.Rect?) -> ClipFrameSample? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil), CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return sample(image, edge: edge, face: face)
    }

    /// The Fix Auto measures on a clip's sheet frames (`ClipColorFix.measure`): up to `Auto.frames` of them, spread evenly
    /// over the clip, each at `Auto.frameSize`. Nil when no frame could be read, so no measurement exists.
    public static func fix(_ frames: [FrameSheetFrame], measure: ClipColorMeasure) -> ClipColorFix? {
        let limit = max(1, measure.auto.frames)
        let chosen = frames.count <= limit ? frames : (0..<limit).map { frames[$0 * (frames.count - 1) / max(1, limit - 1)] }
        let samples = chosen.compactMap { sample(jpeg: $0.image.data, edge: measure.auto.frameSize, face: $0.observation.face?.rect) }
        return samples.isEmpty ? nil : ClipColorFix.measure(samples, constants: measure.auto)
    }
}
