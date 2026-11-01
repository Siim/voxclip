import AppKit
import CoreText

/// The transcript gutter (notes.md §5), 80 pt left of the text, in points from its left edge:
/// the clip range bar at 8, paragraph timecodes right-aligned at 42, one glyph per line in the
/// 13 pt column at 49–63, and the 3 pt change-bar column at 66, which stays empty until
/// proposals draw hunks. The text has 44 pt of right padding.
enum TranscriptGutter {
    static let width = VCTokens.spacingTranscriptGutter
    static let trailing: CGFloat = 44
    static let rangeBarX: CGFloat = 8
    static let rangeBarWidth: CGFloat = 2
    /// The range bar runs from 3 pt below the first clip line's top to 3 pt above the last line's bottom.
    static let rangeBarInset: CGFloat = 3
    /// The band reaches 8 pt above the first clip line and 8 pt below the last.
    static let bandOverhang: CGFloat = 8
    static let timecodeRight: CGFloat = 42
    static let glyphX: CGFloat = 49
    static let glyphSize: CGFloat = 14
    static let glyphTop: CGFloat = 6

    /// A paragraph's take time, `m:ss` (notes.md §5), whole seconds rounded down.
    static func timecode(_ seconds: Double) -> String {
        let total = Int(seconds.isFinite ? max(0, min(seconds, Double(Int.max / 2))) : 0)
        return "\(total / 60):" + String(format: "%02d", total % 60)
    }

    /// The line's box with its glyphs centred in it, in the line's fragment coordinates.
    /// TextKit puts a fixed line height's extra leading above the glyphs; notes.md measures
    /// from a line box that centres them (CSS line-height), so the band, the range bar, the
    /// timecodes and the glyph column use this box, and their distance to the words matches.
    static func visualBox(of line: NSTextLineFragment, font: NSFont) -> CGRect {
        let bounds = line.typographicBounds
        let centre = bounds.minY + line.glyphOrigin.y - (font.ascender + font.descender) / 2
        return CGRect(x: bounds.minX, y: centre - bounds.height / 2, width: bounds.width, height: bounds.height)
    }

    /// Draws a timecode in SF Mono 11, right-aligned at `right` and centred in `box`.
    static func drawTimecode(_ value: String, color: NSColor, right: CGFloat, box: CGRect, in context: CGContext) {
        let font = VCType.small.nsMono()
        let colorKey = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: value, attributes: [.font: font, colorKey: color.cgColor]))
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        context.saveGState()
        context.translateBy(x: right - width, y: box.midY + (font.ascender + font.descender) / 2)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        context.textPosition = .zero
        CTLineDraw(line, context)
        context.restoreGState()
    }
}

/// The glyph column holds one glyph per line, by precedence (notes.md §5). Proposals add the
/// hunk kinds, which rank above the AI voice (V14); title and zoom cues rank below it.
@MainActor enum GutterGlyph {
    /// A line holding words spoken by your AI voice: the waveform in ai.tint.
    case aiVoice

    /// Draws the glyph centred in a 14 pt box: the mockup's 13 pt icon, round-capped bars
    /// on a 20-unit grid at a 1.5-unit stroke.
    func draw(in box: CGRect, context: CGContext) {
        let scale = 13.0 / 20, origin = CGPoint(x: box.midX - 6.5, y: box.midY - 6.5)
        let bars: [(x: CGFloat, top: CGFloat, bottom: CGFloat)] = [(3.5, 8.5, 11.5), (6.5, 6, 14), (9.5, 3.8, 16.2), (12.5, 6.5, 13.5), (15.5, 8, 12)]
        context.saveGState()
        context.setStrokeColor(DesignValues.nsColor("ai.tint").cgColor)
        context.setLineWidth(1.5 * scale)
        context.setLineCap(.round)
        context.setLineDash(phase: 0, lengths: [])
        for bar in bars {
            context.move(to: CGPoint(x: origin.x + bar.x * scale, y: origin.y + bar.top * scale))
            context.addLine(to: CGPoint(x: origin.x + bar.x * scale, y: origin.y + bar.bottom * scale))
        }
        context.strokePath()
        context.restoreGState()
    }
}

/// The open clip behind the transcript (notes.md §5): the editor.band fill from 8 pt above
/// the clip's first line to 8 pt below its last, across the whole width, and the 2 pt
/// clip.label range bar at x 8, dashed for a suggested clip. It spans paragraph gaps, so it is
/// a view behind the text rather than fragment drawing (impl-plan §3.1). It covers only the
/// visible part of the band and a margin, and the text view places it again after every
/// viewport layout, so a long clip never needs a tall backing store.
@MainActor final class TranscriptBackdropView: NSView {
    struct Band: Equatable {
        var top: CGFloat
        var bottom: CGFloat
        /// The bar's ends, nil where the clip runs past the laid-out viewport.
        var barTop: CGFloat?
        var barBottom: CGFloat?
        var suggested: Bool
    }
    static let margin: CGFloat = 64
    private(set) var band: Band?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }

    /// Shows `band`, clipped to `visible` and the margin, across `width`; nil hides it.
    func show(_ band: Band?, visible: CGRect, width: CGFloat) {
        guard let band, case let top = max(band.top, visible.minY - Self.margin), case let bottom = min(band.bottom, visible.maxY + Self.margin), bottom > top else {
            self.band = nil
            if !isHidden { isHidden = true }
            return
        }
        let frame = NSRect(x: 0, y: top, width: width, height: bottom - top)
        if self.frame != frame || self.band != band || isHidden { needsDisplay = true }
        self.band = band
        if self.frame != frame { self.frame = frame }
        if isHidden { isHidden = false }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let band, let context = NSGraphicsContext.current?.cgContext else { return }
        context.setFillColor(DesignValues.nsColor("editor.band").cgColor)
        context.fill(bounds)
        let lower = max(0, (band.barTop ?? frame.minY) - frame.minY), upper = min(bounds.height, (band.barBottom ?? frame.maxY) - frame.minY)
        guard upper > lower else { return }
        let clip = DesignValues.nsColor("clip.label").cgColor
        if band.suggested {
            // Dashes start at the bar's top, or at the document's top while that is off screen,
            // so they stay put as the view moves.
            context.setStrokeColor(clip.copy(alpha: 0.85) ?? clip)
            context.setLineWidth(TranscriptGutter.rangeBarWidth)
            context.setLineDash(phase: frame.minY + lower - (band.barTop ?? 0), lengths: [4, 4])
            context.move(to: CGPoint(x: TranscriptGutter.rangeBarX + TranscriptGutter.rangeBarWidth / 2, y: lower))
            context.addLine(to: CGPoint(x: TranscriptGutter.rangeBarX + TranscriptGutter.rangeBarWidth / 2, y: upper))
            context.strokePath()
        } else {
            context.setFillColor(clip)
            context.addPath(CGPath(roundedRect: CGRect(x: TranscriptGutter.rangeBarX, y: lower, width: TranscriptGutter.rangeBarWidth, height: upper - lower), cornerWidth: 1, cornerHeight: min(1, (upper - lower) / 2), transform: nil))
            context.fillPath()
        }
    }
}
