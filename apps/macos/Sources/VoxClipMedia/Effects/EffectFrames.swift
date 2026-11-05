import CoreGraphics
import CoreImage
import CoreText
import Foundation
import ImageIO
import Synchronization
import VoxClipCore

/// Draws a render's picture effects (ai.md §18.5) on the frame the compositor builds, so preview and export show the same
/// pixels. Censors and pointers sit in picture space and go through the same crop as the video; titles, lower thirds,
/// stickers and the progress bar sit in the output frame. Overlays are rasterized once per composition and reused.
public final class EffectFrames: Sendable {
    public let input: ClipEffectsRenderInput
    private let shared: SharedResources?
    private let cache = Mutex<[String: CIImage]>([:])

    public init(input: ClipEffectsRenderInput, shared: SharedResources? = try? SharedResources.locate()) {
        self.input = input; self.shared = shared
    }

    /// The accent of pointers and the progress bar: VoxClip yellow.
    static let accent = CGColor(srgbRed: 1, green: 0.82, blue: 0.04, alpha: 1)

    // MARK: Picture space

    /// Blurs, pixelates and points at regions of `image`, the output-sized frame filled from `crop` of the source picture
    /// `source` (the oriented source extent), at source time `time` (a freeze's start while it holds).
    public func picture(_ image: CIImage, source: CGRect, crop: CGRect, output: CGSize, time: Double) -> CIImage {
        var result = image
        let active = input.picture.filter { $0.kind.usesRect && time >= $0.start && time < $0.end }
        guard !active.isEmpty, crop.width > 0, crop.height > 0 else { return image }
        let scaleX = output.width / crop.width, scaleY = output.height / crop.height
        func mapped(_ rect: ClipEffect.Rect) -> CGRect {
            // Picture space is top-left normalized; Core Image is bottom-left in pixels.
            let picture = CGRect(x: source.minX + rect.x * source.width, y: source.minY + (1 - rect.y - rect.height) * source.height,
                                 width: rect.width * source.width, height: rect.height * source.height)
            return CGRect(x: (picture.minX - crop.minX) * scaleX, y: (picture.minY - crop.minY) * scaleY,
                          width: picture.width * scaleX, height: picture.height * scaleY).integral
        }
        let frame = CGRect(origin: .zero, size: output)
        for effect in active where effect.kind == .blur || effect.kind == .pixelate {
            guard let rect = effect.rect(at: time) else { continue }
            let region = mapped(rect).intersection(frame)
            guard !region.isNull, region.width >= 1, region.height >= 1 else { continue }
            result = Self.censor(result, region: region, pixelate: effect.kind == .pixelate)
        }
        for effect in active where effect.kind == .arrow || effect.kind == .circle {
            guard let rect = effect.rect(at: time) else { continue }
            let region = mapped(rect)
            let opacity = effect.opacity(at: time)
            guard opacity > 0, let overlay = pointer(effect.kind, region: region, output: output) else { continue }
            result = Self.faded(overlay, opacity).composited(over: result)
        }
        return result
    }

    /// A strong blur, or large square pixels, over `region` of `image`. Both scale with the region, so a small face and a
    /// whole screen are equally unreadable.
    static func censor(_ image: CIImage, region: CGRect, pixelate: Bool) -> CIImage {
        let side = min(region.width, region.height)
        let covered: CIImage
        if pixelate {
            let scale = max(8, (side / 8).rounded())
            // Pre-blurred by half a block, so each block shows its area's average rather than one sampled pixel.
            covered = image.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: scale / 2]).applyingFilter("CIPixellate", parameters: [
                kCIInputScaleKey: scale, kCIInputCenterKey: CIVector(x: region.minX, y: region.minY)])
        } else {
            let radius = min(80, max(10, side * 0.2))
            covered = image.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
        }
        return covered.cropped(to: region).composited(over: image)
    }

    /// A ring around `region`, or an arrow whose tip touches it, from the side facing the frame's centre.
    func pointer(_ kind: ClipEffect.Kind, region: CGRect, output: CGSize) -> CIImage? {
        let key = "pointer|\(kind.rawValue)|\(region.debugDescription)|\(output.width)x\(output.height)"
        if let cached = cache.withLock({ $0[key] }) { return cached }
        let line = max(4, min(output.width, output.height) * 0.012)
        let drawn: CIImage?
        if kind == .circle {
            let ring = region.insetBy(dx: -region.width * 0.12 - line, dy: -region.height * 0.12 - line)
            drawn = Self.raster(bounds: ring.insetBy(dx: -line * 2, dy: -line * 2), output: output) { context in
                let path = CGPath(ellipseIn: ring, transform: nil)
                context.setLineWidth(line * 1.8); context.setStrokeColor(CGColor(gray: 0, alpha: 0.45)); context.addPath(path); context.strokePath()
                context.setLineWidth(line); context.setStrokeColor(Self.accent); context.addPath(path); context.strokePath()
            }
        } else {
            let target = CGPoint(x: region.midX, y: region.midY)
            let centre = CGPoint(x: output.width / 2, y: output.height / 2)
            var dx = centre.x - target.x, dy = centre.y - target.y
            if hypot(dx, dy) < min(output.width, output.height) * 0.1 { dx = -1; dy = -1 }
            let length = hypot(dx, dy)
            let unit = CGPoint(x: dx / length, y: dy / length)
            // The tip stops at the region's edge along the direction to the centre.
            let reachX = unit.x == 0 ? CGFloat.infinity : region.width / 2 / abs(unit.x)
            let reachY = unit.y == 0 ? CGFloat.infinity : region.height / 2 / abs(unit.y)
            let edge = min(reachX, reachY)
            let tip = CGPoint(x: target.x + unit.x * (edge + line), y: target.y + unit.y * (edge + line))
            let arrowLength = min(output.width, output.height) * 0.22
            let tail = CGPoint(x: tip.x + unit.x * arrowLength, y: tip.y + unit.y * arrowLength)
            let head = line * 4.5
            let normal = CGPoint(x: -unit.y, y: unit.x)
            let base = CGPoint(x: tip.x + unit.x * head, y: tip.y + unit.y * head)
            let path = CGMutablePath()
            path.move(to: tail); path.addLine(to: base)
            let headPath = CGMutablePath()
            headPath.move(to: tip)
            headPath.addLine(to: CGPoint(x: base.x + normal.x * head * 0.6, y: base.y + normal.y * head * 0.6))
            headPath.addLine(to: CGPoint(x: base.x - normal.x * head * 0.6, y: base.y - normal.y * head * 0.6))
            headPath.closeSubpath()
            let bounds = path.boundingBoxOfPath.union(headPath.boundingBoxOfPath).insetBy(dx: -line * 3, dy: -line * 3)
            drawn = Self.raster(bounds: bounds, output: output) { context in
                context.setLineCap(.round)
                context.setLineWidth(line * 1.9); context.setStrokeColor(CGColor(gray: 0, alpha: 0.45)); context.addPath(path); context.strokePath()
                context.addPath(headPath); context.setLineWidth(line * 0.9); context.setStrokeColor(CGColor(gray: 0, alpha: 0.45)); context.strokePath()
                context.setLineWidth(line); context.setStrokeColor(Self.accent); context.addPath(path); context.strokePath()
                context.addPath(headPath); context.setFillColor(Self.accent); context.fillPath()
            }
        }
        if let drawn { cache.withLock { $0[key] = drawn } }
        return drawn
    }

    // MARK: Output frame

    /// Titles, lower thirds, stickers and the progress bar over the finished frame at source time `time` and output time
    /// `outputTime`; `mapTime` maps source to output seconds for the progress bar.
    public func frame(_ image: CIImage, output: CGSize, time: Double, outputTime: Double, mapTime: (Double) -> Double) -> CIImage {
        var result = image
        for effect in input.picture where effect.kind.usesPosition && time >= effect.start && time < effect.end {
            let opacity = effect.opacity(at: time)
            guard opacity > 0 else { continue }
            if effect.kind == .progress {
                let start = mapTime(effect.start), end = mapTime(effect.end)
                let fraction = end > start ? min(1, max(0, (outputTime - start) / (end - start))) : 1
                result = Self.faded(Self.progress(fraction: fraction, position: effect.position ?? .bottom, output: output), opacity).composited(over: result)
            } else if let overlay = overlay(effect, output: output) {
                result = Self.faded(overlay, opacity).composited(over: result)
            }
        }
        return result
    }

    static func progress(fraction: Double, position: ClipEffect.Position, output: CGSize) -> CIImage {
        let height = max(6, (output.height * 0.008).rounded())
        let y = position == .top ? output.height - height : 0
        let track = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 0.25)).cropped(to: CGRect(x: 0, y: y, width: output.width, height: height))
        let filled = CIImage(color: CIColor(cgColor: accent)).cropped(to: CGRect(x: 0, y: y, width: (output.width * fraction).rounded(), height: height))
        return filled.composited(over: track)
    }

    func overlay(_ effect: ClipEffect, output: CGSize) -> CIImage? {
        let key = "overlay|\(effect.kind.rawValue)|\(effect.text ?? "")|\(effect.position?.rawValue ?? "")|\(effect.scale ?? 1)|\(output.width)x\(output.height)"
        if let cached = cache.withLock({ $0[key] }) { return cached }
        let drawn: CIImage?
        switch effect.kind {
        case .title: drawn = title(effect.text ?? "", position: effect.position ?? .top, output: output)
        case .lowerThird: drawn = lowerThird(effect.text ?? "", position: effect.position ?? .bottomLeft, output: output)
        case .sticker: drawn = sticker(effect.text ?? "", position: effect.position ?? .topRight, scale: effect.scale ?? 1, output: output)
        default: drawn = nil
        }
        if let drawn { cache.withLock { $0[key] = drawn } }
        return drawn
    }

    private func font(_ path: String, size: CGFloat) -> CTFont {
        if let shared, let descriptors = CTFontManagerCreateFontDescriptorsFromURL(shared.root.appendingPathComponent(path) as CFURL) as? [CTFontDescriptor],
           let first = descriptors.first {
            return CTFontCreateWithFontDescriptor(first, size, nil)
        }
        return CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
    }

    /// Big centred text on a dark rounded box: top, centre or bottom of the frame.
    func title(_ text: String, position: ClipEffect.Position, output: CGSize) -> CIImage? {
        let short = min(output.width, output.height)
        let size = (short * 0.075).rounded()
        let line = Self.line(text, font: font("fonts/roboto/Roboto-Black.ttf", size: size), color: CGColor(gray: 1, alpha: 1))
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        let padX = size * 0.45, padY = size * 0.28
        let width = min(output.width * 0.92, bounds.width + padX * 2), height = size * 1.25 + padY * 2
        let centreY: CGFloat = switch position { case .center: output.height / 2; case .bottom: output.height * 0.24; default: output.height * 0.86 }
        let box = CGRect(x: (output.width - width) / 2, y: centreY - height / 2, width: width, height: height).integral
        return Self.raster(bounds: box, output: output, flipped: false) { context in
            context.setFillColor(CGColor(gray: 0, alpha: 0.62))
            context.addPath(CGPath(roundedRect: box, cornerWidth: height * 0.22, cornerHeight: height * 0.22, transform: nil)); context.fillPath()
            context.saveGState(); context.clip(to: box.insetBy(dx: padX * 0.5, dy: 0))
            context.textPosition = CGPoint(x: box.midX - bounds.width / 2 - bounds.minX, y: box.midY - (bounds.height / 2 + bounds.minY))
            CTLineDraw(line, context)
            context.restoreGState()
        }
    }

    /// A name strip near the bottom: an accent bar and white text on a dark box, left or right.
    func lowerThird(_ text: String, position: ClipEffect.Position, output: CGSize) -> CIImage? {
        let short = min(output.width, output.height)
        let size = (short * 0.045).rounded()
        let line = Self.line(text, font: font("fonts/dm-sans/DMSans-Bold.ttf", size: size), color: CGColor(gray: 1, alpha: 1))
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        let bar = max(4, size * 0.18), pad = size * 0.5
        let width = min(output.width * 0.86, bounds.width + pad * 2 + bar), height = size * 1.2 + pad * 1.2
        let margin = short * 0.05
        let x = position == .bottomRight ? output.width - margin - width : margin
        let box = CGRect(x: x, y: output.height * 0.16, width: width, height: height).integral
        return Self.raster(bounds: box, output: output, flipped: false) { context in
            context.setFillColor(CGColor(gray: 0.07, alpha: 0.82)); context.fill(box)
            context.setFillColor(Self.accent); context.fill(CGRect(x: box.minX, y: box.minY, width: bar, height: box.height))
            context.saveGState(); context.clip(to: box.insetBy(dx: bar, dy: 0))
            context.textPosition = CGPoint(x: box.minX + bar + pad - bounds.minX, y: box.midY - (bounds.height / 2 + bounds.minY))
            CTLineDraw(line, context)
            context.restoreGState()
        }
    }

    /// One bundled Noto emoji (shared/fonts/noto-emoji/png128) in a corner or the centre.
    func sticker(_ text: String, position: ClipEffect.Position, scale: Double, output: CGSize) -> CIImage? {
        let code = text.unicodeScalars.filter { $0.value != 0xFE0F && $0.value != 0xFE0E }.map { String($0.value, radix: 16) }.joined(separator: "_")
        guard let shared, code.range(of: "^[0-9a-f]+(_[0-9a-f]+)*$", options: .regularExpression) != nil,
              let source = CGImageSourceCreateWithURL(shared.root.appendingPathComponent("fonts/noto-emoji/png128/emoji_u\(code).png") as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let short = min(output.width, output.height)
        let side = (short * 0.16 * scale).rounded()
        let margin = short * 0.06
        let x: CGFloat = switch position { case .topLeft, .bottomLeft: margin; case .center, .top, .bottom: (output.width - side) / 2; default: output.width - margin - side }
        let y: CGFloat = switch position { case .bottomLeft, .bottomRight: output.height * 0.2; case .center: (output.height - side) / 2; default: output.height - margin - side }
        let box = CGRect(x: x, y: y, width: side, height: side).integral
        return Self.raster(bounds: box, output: output, flipped: false) { context in
            context.interpolationQuality = .high
            context.draw(image, in: box)
        }
    }

    // MARK: Drawing

    static func line(_ text: String, font: CTFont, color: CGColor) -> CTLine {
        let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font,
                                                         NSAttributedString.Key(kCTForegroundColorAttributeName as String): color]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    }

    /// Draws into a premultiplied sRGB bitmap covering `bounds` (output pixels, bottom-left origin, like Core Image) and
    /// returns it placed at `bounds`. `draw` works in output coordinates.
    static func raster(bounds: CGRect, output: CGSize, flipped: Bool = false, draw: (CGContext) -> Void) -> CIImage? {
        let box = bounds.integral.intersection(CGRect(origin: .zero, size: output))
        guard !box.isNull, box.width >= 1, box.height >= 1,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: Int(box.width), height: Int(box.height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setShouldAntialias(true)
        context.translateBy(x: -box.minX, y: -box.minY)
        draw(context)
        guard let image = context.makeImage() else { return nil }
        return CIImage(cgImage: image).transformed(by: CGAffineTransform(translationX: box.minX, y: box.minY))
    }

    /// `image` at `opacity` (premultiplied, so every channel scales).
    static func faded(_ image: CIImage, _ opacity: Double) -> CIImage {
        guard opacity < 1 else { return image }
        let value = CGFloat(max(0, opacity))
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: value, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: value, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: value, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: value)])
    }
}
