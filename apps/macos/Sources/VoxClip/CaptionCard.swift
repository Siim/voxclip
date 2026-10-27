import CoreGraphics
import Foundation
import VoxClipCore

/// Where a card is drawn (design §5.4.3 "Fit"), in pixels: the surface, which sets the
/// line limit and whether plates draw, the card, its text box (top-left origin) and the
/// font size range.
struct CardFit: Sendable, Hashable {
    var surface: CaptionCardSurface
    var width: Int
    var height: Int
    var boxX: Double, boxY: Double, boxWidth: Double, boxHeight: Double
    var fontMin: Int
    var fontMax: Int

    /// A Home tile: 225×126 with a centred 175×70 text box, 24 → 13 pt.
    static func home(scale: Double = 2) -> CardFit {
        CardFit(surface: .homeTile, width: Int(225 * scale), height: Int(126 * scale), boxX: 25 * scale, boxY: 28 * scale, boxWidth: 175 * scale, boxHeight: 70 * scale,
                fontMin: Int(13 * scale), fontMax: Int(24 * scale))
    }
    /// Full Take and Recent rows: 36×20 inset 2, 11 → 4 pt.
    static func row(scale: Double = 2) -> CardFit {
        CardFit(surface: .sidebar, width: Int(36 * scale), height: Int(20 * scale), boxX: 2 * scale, boxY: 2 * scale, boxWidth: 32 * scale, boxHeight: 16 * scale,
                fontMin: Int(4 * scale), fontMax: Int(11 * scale))
    }
    /// Clip rows: 26×46, a 22×15 box centred on the style's 9:16 caption height
    /// clamped to 0.60–0.78, 9 → 4 pt.
    static func clip(captionY: Double, scale: Double = 2) -> CardFit {
        let centre = captionY.clamped(to: 0.6...0.78) * 46
        return CardFit(surface: .clipRow, width: Int(26 * scale), height: Int(46 * scale), boxX: 2 * scale, boxY: (centre - 7.5) * scale, boxWidth: 22 * scale, boxHeight: 15 * scale,
                       fontMin: Int(4 * scale), fontMax: Int(9 * scale))
    }
}

/// One card to draw: VoxClipCore's `CaptionCardText` for a scope, in the library style it
/// was made with, fitted to a surface.
struct CaptionCardInput: Sendable, Equatable {
    let text: CaptionCardText
    let style: CaptionStyle
    /// The style file's own preview.background: decoding fills in a default, which
    /// the backdrop rule must not mistake for a declared one.
    let previewBackground: String?
    let overrides: [String: JSONValue]
    let language: String?
    let fit: CardFit
}

/// The card's look around the export renderer (design §5.4.3): the backdrop, plates
/// only where the surface draws them, and no near-black strokes or shadows on stage
/// black. The words, their emphasis, the line limit, the drop order and the drawn
/// moment are VoxClipCore's `CaptionCardText`.
enum CaptionCardLook {
    /// The style's card backdrop colour, or nil for stage black. A dark declared preview
    /// background is used; a near-black plate with no preview background sits on #3A3C45.
    static func backdrop(_ style: CaptionStyle, previewBackground: String?) -> String? {
        if let background = previewBackground, let value = luminance(background), value < 0.10 { return background }
        if let box = style.box, let value = luminance(resolved(box.color, style.accent)), value < 0.012 { return "#3A3C45" }
        return nil
    }

    /// Sets a resolved style in the card's text box. `lines` is the card's limit on the
    /// surface; the synthetic word clock must never break the page.
    static func adapt(_ style: inout CaptionStyle, fit: CardFit, lines: Int, stageBlack: Bool) {
        let centreX = (fit.boxX + fit.boxWidth / 2) / Double(fit.width), centreY = (fit.boxY + fit.boxHeight / 2) / Double(fit.height)
        style.position.x = centreX
        style.position.y = centreY
        style.position.anchorX = .center
        style.position.anchorY = .center
        style.aspects = nil
        style.font.sizeRef = .shortEdge
        style.font.sizeScale = 1
        style.layout.maxLines = lines
        style.layout.maxLineWidthW = fit.boxWidth / Double(fit.width)
        style.layout.breakOnSentence = false
        style.layout.breakOnGapSec = nil
        style.layout.maxPageSec = nil
        let accent = style.accent
        if stageBlack {
            if let stroke = style.stroke, nearBlack(resolved(stroke.color, accent)) { style.stroke = nil }
            style.shadows.removeAll { nearBlack(resolved($0.color, accent)) }
        }
        guard !fit.surface.drawsPlates else { return }
        // At sidebar sizes a boxed word reads as a tag: it takes the style's own box
        // colour instead (design §5.4.3), and dark text that sat on a plate turns white.
        if let box = style.words?.active?.box {
            style.words?.active?.box = nil
            style.words?.active?.fill = .solid(color: resolved(box.color, accent))
        }
        if style.box != nil {
            style.box = nil
            if case .solid(let color) = style.fill, let value = luminance(resolved(color, accent)), value < 0.2 { style.fill = .solid(color: "#FFFFFF") }
        }
    }

    static func fits(_ layout: CaptionLayoutResult, fit: CardFit, count: Int, lines: Int) -> Bool {
        guard layout.dropped.isEmpty, layout.pages.count == 1, let page = layout.pages.first?.page,
              page.words.count == count, page.lines.count <= lines else { return false }
        let bounds = page.wordRects.reduce(CGRect.null) { $0.union(CGRect(x: $1.x, y: $1.y, width: $1.width, height: $1.height)) }
        return bounds.width <= fit.boxWidth + 1 && bounds.height <= fit.boxHeight + 1
    }

    /// The rasterised caption over the card backdrop: stage black, or the backdrop
    /// colour as a 78%×92% radial vignetted to stage black. With no raster this is the
    /// backdrop alone, as a card without words draws (§5.4.1).
    static func compose(_ raster: CaptionRaster?, backdrop: String?, width: Int, height: Int) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let stage = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        context.setFillColor(stage)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if let backdrop, let rgb = components(backdrop),
           let gradient = CGGradient(colorsSpace: space, colors: [CGColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1),
                                                                  CGColor(srgbRed: rgb.0 / 2, green: rgb.1 / 2, blue: rgb.2 / 2, alpha: 1), stage] as CFArray,
                                     locations: [0, 0.42, 1]) {
            context.saveGState()
            context.translateBy(x: Double(width) * 0.5, y: Double(height) * 0.54)
            context.scaleBy(x: Double(width) * 0.78, y: Double(height) * 0.92)
            context.drawRadialGradient(gradient, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 1, options: [.drawsAfterEndLocation])
            context.restoreGState()
        }
        if let raster {
            guard let provider = CGDataProvider(data: raster.rgba as CFData),
                  let overlay = CGImage(width: raster.width, height: raster.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: raster.bytesPerRow, space: space,
                                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
                                        decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
            context.draw(overlay, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return context.makeImage()
    }

    private static func resolved(_ color: String, _ accent: String?) -> String { color == "$accent" ? accent ?? "#FFFFFF" : color }
    private static func nearBlack(_ color: String) -> Bool { luminance(color).map { $0 < 0.012 } ?? false }
    private static func components(_ hex: String) -> (Double, Double, Double)? {
        let raw = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard raw.count == 6 || raw.count == 8, let number = UInt32(raw.prefix(6), radix: 16) else { return nil }
        return (Double(number >> 16 & 255) / 255, Double(number >> 8 & 255) / 255, Double(number & 255) / 255)
    }
    /// WCAG relative luminance of the colour, ignoring alpha.
    static func luminance(_ hex: String) -> Double? {
        guard let rgb = components(hex) else { return nil }
        let linear = { (value: Double) in value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(rgb.0) + 0.7152 * linear(rgb.1) + 0.0722 * linear(rgb.2)
    }
}
