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
            0.2126 * linear(color.r) + 0.7152 * linear(color.g) + 0.0722 * linear(color.b)
        }
        let foreground = luminance(box), behind = luminance(background)
        if (max(foreground, behind) + 0.05) / (min(foreground, behind) + 0.05) >= 4.5 { return box }
        func mix(_ channel: UInt8) -> UInt8 { UInt8((Int(channel) * 55 + 255 * 45 + 50) / 100) }
        return (mix(box.r), mix(box.g), mix(box.b))
    }
}
