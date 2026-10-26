import CoreGraphics
import CoreText
import CoreVideo
import Foundation
import VoxClipCore

/// Caption bounds are in output pixels with a top-left origin. Build these from the existing caption layout.
public struct VoiceLabDisclosureCaptionBlock: Sendable {
    public let start: Double
    public let end: Double
    public let bounds: CGRect
    public init(start: Double, end: Double, bounds: CGRect) {
        self.start = start; self.end = end; self.bounds = bounds
    }
}

/// A reusable, premultiplied sRGB chip for the existing preview/export compositor.
public final class VoiceLabDisclosureOverlay: @unchecked Sendable {
    private let plan: VoiceLabDisclosurePlan
    private let width: Int
    private let height: Int
    private let chipWidth: Int
    private let chipHeight: Int
    private let stride: Int
    private let pixels: [UInt8]
    private let origins: [(Int, Int)]

    public init(plan: VoiceLabDisclosurePlan, width: Int, height: Int, fontURL: URL,
                captionBlocks: [VoiceLabDisclosureCaptionBlock]) throws {
        guard width > 0, height > 0, width <= 16384, height <= 16384 else { throw VoiceLabDisclosureError.invalidFrame }
        guard captionBlocks.allSatisfy({ block in
            block.start.isFinite && block.end.isFinite && block.start >= 0 && block.end > block.start &&
            block.bounds.origin.x.isFinite && block.bounds.origin.y.isFinite &&
            block.bounds.width.isFinite && block.bounds.height.isFinite &&
            block.bounds.width >= 0 && block.bounds.height >= 0
        }) else { throw VoiceLabDisclosureError.invalidFrame }
        self.plan = plan; self.width = width; self.height = height
        guard fontURL.lastPathComponent == "DMSans-Bold.ttf",
              let provider = CGDataProvider(url: fontURL as CFURL), let graphicsFont = CGFont(provider) else {
            throw VoiceLabDisclosureError.invalidFont
        }
        let size = CGFloat(height) * 0.024
        let font = CTFontCreateWithGraphicsFont(graphicsFont, size, nil, nil)
        let text = NSAttributedString(string: "AI MODIFIED", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTKernAttributeName as String): size * 0.06,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1)
        ])
        let line = CTLineCreateWithAttributedString(text)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let advance = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        let horizontal = size * 0.6, vertical = size * 0.35
        let chipWidth = Int(ceil(CGFloat(advance) + 2 * horizontal))
        let chipHeight = Int(ceil(ascent + descent + 2 * vertical))
        let left = Int((Double(width) * 0.05).rounded())
        let right = width - left - chipWidth
        let top = Int((Double(height) * 0.05).rounded())
        let bottom = height - top - chipHeight
        guard chipWidth > 0, chipHeight > 0, left >= 0, top >= 0,
              right >= left, bottom >= top,
              right + chipWidth <= width, bottom + chipHeight <= height else {
            throw VoiceLabDisclosureError.invalidFrame
        }
        let stride = chipWidth * 4
        var bitmap = [UInt8](repeating: 0, count: stride * chipHeight)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let made = bitmap.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: chipWidth, height: chipHeight,
                                          bitsPerComponent: 8, bytesPerRow: stride, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.7))
            context.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: chipWidth, height: chipHeight),
                                   cornerWidth: size * 0.3, cornerHeight: size * 0.3, transform: nil))
            context.fillPath()
            context.textPosition = CGPoint(x: horizontal, y: vertical + descent)
            CTLineDraw(line, context)
            return true
        }
        guard made else { throw VoiceLabDisclosureError.invalidFrame }
        let origins = plan.intervals.map { interval in
            let preferred: (Int, Int) = switch plan.position {
            case .topLeft: (left, top)
            case .topRight: (right, top)
            case .bottomLeft: (left, bottom)
            case .bottomRight: (right, bottom)
            }
            let rect = CGRect(x: preferred.0, y: preferred.1, width: chipWidth, height: chipHeight)
            let collision = captionBlocks.contains { $0.start < interval.end && $0.end > interval.start && rect.intersects($0.bounds) }
            if collision { return plan.position == .topLeft || plan.position == .bottomLeft ? (right, top) : (left, top) }
            return preferred
        }
        guard origins.allSatisfy({ $0.0 >= 0 && $0.1 >= 0 &&
                                  $0.0 <= width - chipWidth && $0.1 <= height - chipHeight }) else {
            throw VoiceLabDisclosureError.invalidFrame
        }
        self.chipWidth = chipWidth; self.chipHeight = chipHeight; self.stride = stride
        self.pixels = bitmap; self.origins = origins
    }

    public func opacity(at time: Double) -> Double {
        guard plan.required, time.isFinite else { return 0 }
        for interval in plan.intervals where time >= interval.start && time < interval.end {
            let fade = plan.fadeSeconds
            return fade > 0 ? max(0, min(1, (time - interval.start) / fade, (interval.end - time) / fade)) : 1
        }
        return 0
    }

    /// Call after captions on the existing BGRA output. No per-frame font or image allocation.
    public func draw(into buffer: CVPixelBuffer, at time: Double) throws {
        guard let index = plan.intervals.firstIndex(where: { time >= $0.start && time < $0.end }) else { return }
        let opacity = self.opacity(at: time)
        guard opacity > 0 else { return }
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
              CVPixelBufferGetWidth(buffer) == width, CVPixelBufferGetHeight(buffer) == height else {
            throw VoiceLabDisclosureError.invalidFrame
        }
        guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else {
            throw VoiceLabDisclosureError.invalidFrame
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw VoiceLabDisclosureError.invalidFrame }
        let destination = base.assumingMemoryBound(to: UInt8.self)
        let rowStride = CVPixelBufferGetBytesPerRow(buffer)
        let origin = origins[index]
        guard rowStride >= width * 4, origin.0 >= 0, origin.1 >= 0,
              origin.0 <= width - chipWidth, origin.1 <= height - chipHeight else {
            throw VoiceLabDisclosureError.invalidFrame
        }
        for y in 0..<chipHeight {
            let target = destination.advanced(by: (origin.1 + y) * rowStride + origin.0 * 4)
            let source = y * stride
            for x in 0..<chipWidth {
                let offset = source + x * 4, pixel = x * 4
                let alpha = Double(pixels[offset + 3]) / 255 * opacity
                if alpha == 0 { continue }
                let inverse = 1 - alpha
                for channel in 0..<3 {
                    let value = Double(pixels[offset + 2 - channel]) * opacity + Double(target[pixel + channel]) * inverse
                    target[pixel + channel] = UInt8(min(255, max(0, Int(value.rounded()))))
                }
                target[pixel + 3] = 255
            }
        }
    }
}

public enum VoiceLabDisclosureError: Error, Equatable { case invalidFrame, invalidFont, invalidMP4, existingXMP, destinationExists }
