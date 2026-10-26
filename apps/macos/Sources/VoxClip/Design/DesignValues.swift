import SwiftUI
import CoreText
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

    /// Petrol for marks, links, the playhead and clip badges. While the system accent is
    /// the AccentColor asset this is the accent.text token, which lifts Petrol to #63BDB6
    /// on dark surfaces; when the user picked a system accent colour it is controlAccentColor.
    static let accentText: Color = {
        let modes = value("color.accent.text") as? [String: String] ?? [:]
        let dark = parse(modes["dark"] ?? ""), light = parse(modes["light"] ?? "")
        let asset = NSColor(named: "AccentColor")
        #if DEBUG
        let tinted = asset == nil
        #else
        let tinted = false
        #endif
        return Color(nsColor: NSColor(name: NSColor.Name("voxclip.accentText")) { appearance in
            var own = tinted
            if let asset {
                appearance.performAsCurrentDrawingAppearance {
                    guard let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB), let petrol = asset.usingColorSpace(.sRGB) else { return }
                    own = abs(accent.redComponent - petrol.redComponent) < 0.01 && abs(accent.greenComponent - petrol.greenComponent) < 0.01 && abs(accent.blueComponent - petrol.blueComponent) < 0.01
                }
            }
            guard own else { return .controlAccentColor }
            return appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }()

    #if DEBUG
    /// accent.default for SwiftUI controls when the app runs without the AccentColor asset
    /// (`swift run`, the offscreen harness); a bundle from bundle.sh gets nil and uses the
    /// asset. Caveat: the tint reaches SwiftUI controls only. AppKit still draws focus rings,
    /// text selection and controlAccentColor in the system accent until the asset is
    /// bundled, so accent evidence for those must come from a bundled build.
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

    static func registerFonts() {
        guard let shared = try? SharedResources.locate(), let families = values["fontFiles"] as? [String: Any] else { return }
        for family in families.values {
            guard let token = family as? [String: Any], let extensions = token["$extensions"] as? [String: Any],
                  let details = extensions["com.voxconvo.voxclip"] as? [String: Any], let files = details["files"] as? [String: [String: Any]] else { continue }
            for (file, metadata) in files where metadata["present"] as? Bool == true {
                let url = shared.root.appendingPathComponent("fonts/\(file)")
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }
    }

    static func transcriptFont(size: Double) -> NSFont {
        NSFont(name: "DMSans-Regular", size: size) ?? .systemFont(ofSize: size)
    }

    static func monoFont(_ size: Double = 12) -> NSFont { NSFont(name: "GeistMono-Regular", size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular) }
    static func mono(_ size: Double = 12) -> Font { Font(monoFont(size)) }
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

func timecode(_ seconds: Double) -> String {
    let seconds = seconds.isFinite ? max(0, seconds) : 0
    let tenths = Int(min(Double(Int.max / 10), seconds) * 10 + 0.5)
    let suffix = String(format: "%02d.%d", tenths / 10 % 60, tenths % 10)
    if tenths >= 36_000 { return String(format: "%02d:%02d:", tenths / 36_000, tenths / 600 % 60) + suffix }
    return String(format: "%02d:", tenths / 600) + suffix
}

func durationLabel(_ seconds: Double) -> String {
    let total = Int((seconds.isFinite ? max(0, min(seconds, Double(Int.max / 10))) : 0).rounded())
    return String(format: "%d:%02d", total / 60, total % 60)
}
