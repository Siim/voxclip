#if DEBUG
import AppKit

@MainActor enum DebugToolbarPixels {
    struct Metrics: Codable { let name: String; let labelPixels: Int; let contrast: Double }
    static func measure(window: NSWindow, name: String, directory: URL, active: Bool) throws -> [DebugUISuite.Result] {
        func buttons(_ view: NSView) -> [NSButton] {
            (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons)
        }
        guard let root = window.contentView?.superview, let button = buttons(root).first(where: { $0.isEnabled && $0.title.contains("Export") }), let surface = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return [.init(name: "\(name) Export contrast", passed: false)] }
        root.cacheDisplay(in: root.bounds, to: surface)
        let rect = button.convert(button.bounds, to: root)
        let scale = Double(surface.pixelsWide) / root.bounds.width
        let top = root.isFlipped ? rect.minY : root.bounds.height - rect.maxY
        let region = CGRect(x: rect.minX * scale, y: top * scale, width: rect.width * scale, height: rect.height * scale).integral
        guard let image = surface.cgImage?.cropping(to: region) else { throw CocoaError(.coderInvalidValue) }
        let bitmap = NSBitmapImageRep(cgImage: image)
        var count = 0, contrast = 0.0
        button.effectiveAppearance.performAsCurrentDrawingAppearance {
            guard let label = DesignValues.nsColor(active ? "accent.on" : "text.primary").usingColorSpace(.deviceRGB) else { return }
            let expected = [label.redComponent, label.greenComponent, label.blueComponent]
            for row in 0..<bitmap.pixelsHigh {
                for column in 0..<bitmap.pixelsWide {
                    guard let pixel = bitmap.colorAt(x: column, y: row)?.usingColorSpace(.deviceRGB) else { continue }
                    if zip([pixel.redComponent, pixel.greenComponent, pixel.blueComponent], expected).allSatisfy({ abs($0 - $1) < 0.08 }) { count += 1 }
                }
            }
            let row = max(0, bitmap.pixelsHigh - max(4, bitmap.pixelsHigh / 5))
            let samples = (bitmap.pixelsWide / 4..<bitmap.pixelsWide * 3 / 4).compactMap { bitmap.colorAt(x: $0, y: row)?.usingColorSpace(.deviceRGB) }
            let luminances = samples.map(luminance).sorted()
            if let background = luminances.dropFirst(luminances.count / 2).first {
                let foreground = luminance(label)
                contrast = (max(background, foreground) + 0.05) / (min(background, foreground) + 0.05)
            }
        }
        let metrics = Metrics(name: name, labelPixels: count, contrast: contrast)
        try JSONEncoder().encode(metrics).write(to: directory.appendingPathComponent("\(name)-contrast.json"))
        if let image = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) { try image.write(to: directory.appendingPathComponent("\(name)-export-control.jpg")) }
        return [.init(name: "\(name) Export label-to-bezel pixel contrast", passed: count > 8 && contrast >= 4.5)]
    }
    private static func luminance(_ color: NSColor) -> Double {
        let linear = [color.redComponent, color.greenComponent, color.blueComponent].map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722
    }
}
#endif
