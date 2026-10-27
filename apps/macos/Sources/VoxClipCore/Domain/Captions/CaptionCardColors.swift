import Foundation

/// Pure sidebar card colour rules; design §5.4.3.
public enum CaptionCardColors {
    /// Keep a box colour at 4.5:1 contrast, otherwise mix it once 45% toward white in sRGB, half-up.
    public static func sidebarKeyText(box: (r: UInt8, g: UInt8, b: UInt8), background: (r: UInt8, g: UInt8, b: UInt8)) -> (r: UInt8, g: UInt8, b: UInt8) {
        func linear(_ channel: UInt8) -> Double {
            let value = Double(channel) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        func luminance(_ color: (r: UInt8, g: UInt8, b: UInt8)) -> Double {
            let red: Double = 0.2126 * linear(color.r)
            let green: Double = 0.7152 * linear(color.g)
            let blue: Double = 0.0722 * linear(color.b)
            return red + green + blue
        }
        let foreground = luminance(box), behind = luminance(background)
        let lighter: Double = max(foreground, behind) + 0.05
        let darker: Double = min(foreground, behind) + 0.05
        if lighter / darker >= 4.5 { return box }
        // Hosted Xcode 26 cannot type-check the one-line integer mix in time, so each step is typed.
        func mix(_ channel: UInt8) -> UInt8 {
            let kept: Int = Int(channel) * 55
            let white: Int = 255 * 45
            return UInt8((kept + white + 50) / 100)
        }
        return (mix(box.r), mix(box.g), mix(box.b))
    }
}
