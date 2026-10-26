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
