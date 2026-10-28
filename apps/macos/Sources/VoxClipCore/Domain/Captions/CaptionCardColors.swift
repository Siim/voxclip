import Foundation

/// Pure sidebar card colour rules; design §5.4.3.
public enum CaptionCardColors {
    /// Keep a box colour at 4.5:1 contrast, otherwise mix it once 45% toward white in sRGB, half-up.
    public static func sidebarKeyText(box: (r: UInt8, g: UInt8, b: UInt8), background: (r: UInt8, g: UInt8, b: UInt8)) -> (r: UInt8, g: UInt8, b: UInt8) {
        if CaptionContrast.ratio(box, background) >= 4.5 { return box }
        // Hosted Xcode 26 cannot type-check the one-line integer mix in time, so each step is typed.
        func mix(_ channel: UInt8) -> UInt8 {
            let kept: Int = Int(channel) * 55
            let white: Int = 255 * 45
            return UInt8((kept + white + 50) / 100)
        }
        return (mix(box.r), mix(box.g), mix(box.b))
    }
}

enum CaptionContrast {
    static func ratio(_ foreground: (r: UInt8, g: UInt8, b: UInt8), _ background: (r: UInt8, g: UInt8, b: UInt8)) -> Double {
        func linear(_ channel: UInt8) -> Double {
            let value: Double = Double(channel) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        func luminance(_ color: (r: UInt8, g: UInt8, b: UInt8)) -> Double {
            let red: Double = 0.2126 * linear(color.r)
            let green: Double = 0.7152 * linear(color.g)
            let blue: Double = 0.0722 * linear(color.b)
            return red + green + blue
        }
        let front: Double = luminance(foreground)
        let back: Double = luminance(background)
        let lighter: Double = max(front, back) + 0.05
        let darker: Double = min(front, back) + 0.05
        return lighter / darker
    }

    static func text(_ paint: CaptionPaint, box: String, accent: String?) -> CaptionPaint {
        guard case .solid(let text) = paint else { return paint }
        func rgb(_ value: String) -> (r: UInt8, g: UInt8, b: UInt8) {
            let resolved = value.hasPrefix("$accent") ? accent! : value
            let channels = UInt32(resolved.dropFirst().prefix(6), radix: 16)!
            let redShift: UInt32 = channels >> 16
            let greenShift: UInt32 = channels >> 8
            let red: UInt32 = redShift & 255
            let green: UInt32 = greenShift & 255
            let blue: UInt32 = channels & 255
            return (UInt8(red), UInt8(green), UInt8(blue))
        }
        let background = rgb(box)
        if ratio(rgb(text), background) >= 4.5 { return paint }
        let black: (r: UInt8, g: UInt8, b: UInt8) = (0, 0, 0)
        let white: (r: UInt8, g: UInt8, b: UInt8) = (255, 255, 255)
        return .solid(color: ratio(black, background) >= ratio(white, background) ? "#000000" : "#FFFFFF")
    }

    static func resolve(_ original: CaptionStyle) -> CaptionStyle {
        var style = original
        func adjusted(_ paint: CaptionPaint, box: String?) -> CaptionPaint {
            guard let box else { return paint }
            return text(paint, box: box, accent: original.accent)
        }
        let fill = adjusted(original.fill, box: original.box?.color)
        style.fill = fill
        func state(_ appearance: CaptionWordState?) -> CaptionWordState? {
            guard var appearance else { return nil }
            let paint = appearance.fill ?? original.fill
            let resolved = adjusted(paint, box: appearance.box?.color ?? original.box?.color)
            if appearance.fill != nil || resolved != fill { appearance.fill = resolved }
            return appearance
        }
        style.words?.past = state(original.words?.past)
        style.words?.active = state(original.words?.active)
        style.words?.future = state(original.words?.future)
        return style
    }
}
