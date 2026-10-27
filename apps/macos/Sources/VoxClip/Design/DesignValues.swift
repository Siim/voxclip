import SwiftUI
import VoxClipCore

@MainActor enum DesignValues {
    private static var colors: [String: NSColor] = [:]
    private static let values: [String: Any] = {
        guard let shared = try? SharedResources.locate(),
              let data = try? Data(contentsOf: shared.root.appendingPathComponent("design/tokens.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }()

    static func value(_ path: String) -> Any? {
        var result: Any = values
        for part in path.split(separator: ".") {
            guard let object = result as? [String: Any], let next = object[String(part)] else { return nil }
            result = next
        }
        return (result as? [String: Any])?["$value"] ?? result
    }

    static func dimension(_ path: String, fallback: Double) -> Double { value(path) as? Double ?? fallback }

    static func nsColor(_ path: String) -> NSColor {
        if let cached = colors[path] { return cached }
        guard let modes = value("color.\(path)") as? [String: String] else { return .labelColor }
        let dark = parse(modes["dark"] ?? "")
        let light = parse(modes["light"] ?? "")
        let color = NSColor(name: NSColor.Name("voxclip.\(path)")) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
        colors[path] = color
        return color
    }

    static func color(_ path: String) -> Color { Color(nsColor: nsColor(path)) }

    private static let accentAsset = NSColor(named: "AccentColor")

    /// True while the accent is VoxClip's own Petrol: the AccentColor asset under the
    /// Multicolor system accent, or a DEBUG build run without the asset. False when the
    /// user picked a system accent colour, which every accent mark then follows (C14).
    static func ownsAccent(_ appearance: NSAppearance) -> Bool { ownsAccent(appearance, asset: accentAsset) }

    nonisolated private static func ownsAccent(_ appearance: NSAppearance, asset: NSColor?) -> Bool {
        guard let asset else {
            #if DEBUG
            return true
            #else
            return false
            #endif
        }
        var own = false
        appearance.performAsCurrentDrawingAppearance {
            guard let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB), let petrol = asset.usingColorSpace(.sRGB) else { return }
            own = abs(accent.redComponent - petrol.redComponent) < 0.01 && abs(accent.greenComponent - petrol.greenComponent) < 0.01 && abs(accent.blueComponent - petrol.blueComponent) < 0.01
        }
        return own
    }

    /// The accent fill: accent.default while the accent is Petrol, else the system
    /// accent. The playing word, the clip band and the Export capsule use it.
    static let accentFill: NSColor = {
        let petrol = nsColor("accent.default"), asset = accentAsset
        return NSColor(name: NSColor.Name("voxclip.accentFill")) { appearance in ownsAccent(appearance, asset: asset) ? petrol : .controlAccentColor }
    }()

    /// Accent marks and links: the accent.text token while the accent is Petrol (it lifts
    /// Petrol to #63BDB6 on dark surfaces); otherwise the system accent mixed toward
    /// text.primary in 5% steps until it reads at 4.5:1 on bg.surface.
    static let accentText: Color = {
        let token = nsColor("accent.text"), text = nsColor("text.primary"), surface = nsColor("bg.surface"), asset = accentAsset
        return Color(nsColor: NSColor(name: NSColor.Name("voxclip.accentText")) { appearance in
            ownsAccent(appearance, asset: asset) ? token : readable(.controlAccentColor, toward: text, on: surface, in: appearance)
        })
    }()

    /// A soft accent fill: the accent.soft token while the accent is Petrol, otherwise
    /// the system accent at 14% over bg.surface.
    static let accentSoft: Color = {
        let token = nsColor("accent.soft"), surface = nsColor("bg.surface"), asset = accentAsset
        return Color(nsColor: NSColor(name: NSColor.Name("voxclip.accentSoft")) { appearance in
            guard !ownsAccent(appearance, asset: asset) else { return token }
            var soft = NSColor.controlAccentColor
            appearance.performAsCurrentDrawingAppearance {
                if let base = surface.usingColorSpace(.sRGB), let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) { soft = base.blended(withFraction: 0.14, of: accent) ?? accent }
            }
            return soft
        })
    }()

    /// `color` mixed toward `text` in 5% steps until it reaches 4.5:1 on `surface`.
    nonisolated static func readable(_ color: NSColor, toward text: NSColor, on surface: NSColor, in appearance: NSAppearance) -> NSColor {
        var result = color
        appearance.performAsCurrentDrawingAppearance {
            guard let base = color.usingColorSpace(.sRGB), let target = text.usingColorSpace(.sRGB), let ground = surface.usingColorSpace(.sRGB) else { return }
            result = (0...20).lazy.compactMap { base.blended(withFraction: Double($0) * 0.05, of: target) }.first { contrast($0, ground) >= 4.5 } ?? target
        }
        return result
    }

    /// The WCAG contrast ratio of two colours, ignoring alpha.
    nonisolated static func contrast(_ first: NSColor, _ second: NSColor) -> Double {
        func luminance(_ color: NSColor) -> Double {
            guard let rgb = color.usingColorSpace(.sRGB) else { return 0 }
            let linear = { (value: Double) in value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
        }
        let (a, b) = (luminance(first), luminance(second))
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    #if DEBUG
    /// accent.default for SwiftUI controls when the app runs without the AccentColor asset
    /// (`swift run`, the offscreen harness); a bundle from bundle.sh gets nil and uses the
    /// asset. Caveat: the tint reaches SwiftUI controls only. AppKit still draws focus rings,
    /// text selection and controlAccentColor in the system accent until the asset is
    /// bundled, and an explicit tint also colours labels the asset leaves neutral, such as
    /// borderless menus. Accent evidence for those must come from a bundled build.
    static let debugTint: Color? = NSColor(named: "AccentColor") == nil ? color("accent.default") : nil
    #endif

    static func parse(_ hex: String) -> NSColor {
        if hex == "system:selectedText" { return .selectedTextBackgroundColor }
        precondition(!hex.hasPrefix("system:"), "Unknown system colour token")
        let raw = String(hex.dropFirst())
        guard let number = UInt64(raw, radix: 16), raw.count == 6 || raw.count == 8 else { return .labelColor }
        let rgba = raw.count == 6 ? (number << 8) | 255 : number
        return NSColor(srgbRed: Double((rgba >> 24) & 255) / 255, green: Double((rgba >> 16) & 255) / 255, blue: Double((rgba >> 8) & 255) / 255, alpha: Double(rgba & 255) / 255)
    }

    /// UI text uses system fonts only (design C1). The bundled fonts appear only in
    /// rendered video, where VoxClipMedia loads them from their files.
    static func transcriptFont(size: Double) -> NSFont { .systemFont(ofSize: size) }
    static func monoFont(_ size: Double = 12, weight: NSFont.Weight = .regular) -> NSFont { .monospacedSystemFont(ofSize: size, weight: weight) }
    static func mono(_ size: Double = 12, weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight, design: .monospaced) }

    // Transcript type (design C4): 19/32 with an 18 paragraph gap; zoom keeps 32/19.
    static let transcriptTextSize = Double(VCTokens.typographyTranscriptFontSize)
    static let transcriptLineHeightRatio = Double(VCTokens.typographyTranscriptLineHeight / VCTokens.typographyTranscriptFontSize)
    static let transcriptParagraphGap = Double(VCTokens.spacingTranscriptParagraphGap)
    static let transcriptZoom = Double(VCTokens.typographyTranscriptZoomMin)...Double(VCTokens.typographyTranscriptZoomMax)
}

extension View {
    /// Apply at every SwiftUI hosting root: a DEBUG build without the asset tints its
    /// controls with DesignValues.debugTint, a bundled build uses the AccentColor asset.
    func sceneAccent() -> some View {
        #if DEBUG
        tint(DesignValues.debugTint)
        #else
        self
        #endif
    }
}

@MainActor struct InlineNotice: View {
    let text: String
    var body: some View {
        if !text.isEmpty { Label(text, systemImage: "info.circle")
            .font(.callout).foregroundStyle(DesignValues.color("text.muted"))
            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            .padding(12).accessibilityElement(children: .combine) }
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(range.upperBound, max(range.lowerBound, self)) }
}

/// `m:ss.d`, or `h:mm:ss.d` from one hour (design C4).
func timecode(_ seconds: Double) -> String {
    let seconds = seconds.isFinite ? max(0, seconds) : 0
    let tenths = Int(min(Double(Int.max / 10), seconds) * 10 + 0.5)
    let suffix = String(format: "%02d.%d", tenths / 10 % 60, tenths % 10)
    if tenths >= 36_000 { return String(format: "%d:%02d:", tenths / 36_000, tenths / 600 % 60) + suffix }
    return String(format: "%d:", tenths / 600) + suffix
}

func durationLabel(_ seconds: Double) -> String {
    let total = Int((seconds.isFinite ? max(0, min(seconds, Double(Int.max / 10))) : 0).rounded())
    return String(format: "%d:%02d", total / 60, total % 60)
}
