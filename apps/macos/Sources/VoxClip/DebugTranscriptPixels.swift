#if DEBUG
import AppKit
import VoxClipCore

@MainActor enum DebugTranscriptPixels {
    struct Probe: Codable {
        let name: String
        let row: Double
        let width: Double
        let matchingColumns: Int
    }
    static func run(app: AppModel, fixture: Project, directory: URL) throws -> [DebugUISuite.Result] {
        var project = fixture
        project.transcript?.words = [
            TimedWord(id: "pixel-cut", text: "stricken", start: 0, end: 0.4),
            TimedWord(id: "pixel-filler", text: "um", start: 0.5, end: 0.8),
            TimedWord(id: "pixel-low", text: "uncertain", start: 0.9, end: 1.2, conf: 0.2),
            TimedWord(id: "pixel-playing", text: "playing", start: 1.3, end: 1.6),
            TimedWord(id: "pixel-next", text: "next", start: 3.2, end: 3.5)
        ]
        project.edits = ProjectEdits(cutWordIds: ["pixel-cut"])
        let model = EditorModel(document: VoxClipDocument(project: project), app: app, preview: DemoPreviewEngine())
        defer { model.close() }
        model.textSize = 24; model.mediaResolved = true; model.refresh()
        let coordinator = TranscriptTextView.Coordinator(model: model)
        let text = TranscriptNSTextView(usingTextLayoutManager: true)
        text.frame = NSRect(x: 0, y: 0, width: 640, height: 160)
        text.textContainer?.containerSize = NSSize(width: 640, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = true
        text.textContainerInset = NSSize(width: 8, height: 8)
        text.isEditable = false; text.isSelectable = false; text.drawsBackground = true
        text.textLayoutManager?.delegate = coordinator
        coordinator.text = text; coordinator.renderer.text = text
        let renderer = coordinator.renderer
        text.textLayoutManager?.renderingAttributesValidator = { [weak renderer] _, fragment in MainActor.assumeIsolated { renderer?.validate(fragment) } }
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 640, height: 160), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = text
        defer { window.close() }
        renderer.rebuild(model: model)
        let revision = renderer.storageRevision
        renderer.update(TranscriptAppearance(cutWords: ["pixel-cut"], fillers: ["pixel-filler"], playing: "pixel-playing", lowConfidence: true))
        guard let manager = text.textLayoutManager else { throw CocoaError(.coderInvalidValue) }
        manager.ensureLayout(for: manager.documentRange)
        manager.textViewportLayoutController.layoutViewport()
        guard let fragment = manager.textLayoutFragment(for: manager.documentRange.location), let line = fragment.textLineFragments.first else { throw CocoaError(.coderInvalidValue) }
        let font = DesignValues.transcriptFont(size: model.textSize)
        let baseline = text.textContainerOrigin.y + fragment.layoutFragmentFrame.minY + line.typographicBounds.minY + line.glyphOrigin.y
        var results: [DebugUISuite.Result] = []
        var probes: [Probe] = []
        for mode: NSAppearance.Name in [.aqua, .darkAqua] {
            let name = mode == .aqua ? "light" : "dark"
            let appearance = NSAppearance(named: mode)!
            window.appearance = appearance
            var captured: NSBitmapImageRep?
            appearance.performAsCurrentDrawingAppearance {
                text.backgroundColor = DesignValues.nsColor("bg.window")
                text.needsDisplay = true
                if let bitmap = text.bitmapImageRepForCachingDisplay(in: text.bounds) { text.cacheDisplay(in: text.bounds, to: bitmap); captured = bitmap }
            }
            guard let bitmap = captured, let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else { throw CocoaError(.fileWriteUnknown) }
            try jpeg.write(to: directory.appendingPathComponent("transcript-decorations-\(name).jpg"))
            appearance.performAsCurrentDrawingAppearance {
                for (id, token, strike) in [("pixel-cut", "cut.stroke", true), ("pixel-filler", "word.filler", false), ("pixel-low", "word.lowConfidence", false)] {
                    guard let span = text.map.span(id: id) else { results.append(.init(name: "\(name) \(id) pixels", passed: false)); continue }
                    let lower = line.locationForCharacter(at: span.range.location).x + text.textContainerOrigin.x + fragment.layoutFragmentFrame.minX + line.typographicBounds.minX
                    let upper = line.locationForCharacter(at: NSMaxRange(span.range)).x + text.textContainerOrigin.x + fragment.layoutFragmentFrame.minX + line.typographicBounds.minX
                    let row = strike ? baseline - font.xHeight / 2 : baseline - font.underlinePosition + 1
                    let count = matchingColumns(bitmap, lower: lower, upper: upper, row: row, size: text.bounds.size, color: DesignValues.nsColor(token), background: text.backgroundColor)
                    probes.append(Probe(name: "\(name)-\(id)", row: row, width: upper - lower, matchingColumns: count))
                    let minimum = strike ? (upper - lower) * 0.45 : (upper - lower) * 0.15
                    results.append(.init(name: "\(name) \(id) decoration pixels at the expected row", passed: Double(count) >= minimum))
                }
            }
        }
        results.append(.init(name: "transcript decorations never relayout storage", passed: renderer.storageRevision == revision))
        try JSONEncoder().encode(probes).write(to: directory.appendingPathComponent("transcript-decoration-pixels.json"))
        return results
    }
    private static func matchingColumns(_ bitmap: NSBitmapImageRep, lower: Double, upper: Double, row: Double, size: NSSize, color: NSColor, background: NSColor) -> Int {
        guard let color = color.usingColorSpace(.deviceRGB), let background = background.usingColorSpace(.deviceRGB) else { return 0 }
        let alpha = color.alphaComponent
        let paper = [background.redComponent, background.greenComponent, background.blueComponent]
        let ink = [color.redComponent, color.greenComponent, color.blueComponent]
        let direction = zip(ink, paper).map { ($0 - $1) * alpha }
        let magnitude = direction.reduce(0) { $0 + $1 * $1 }
        guard magnitude > 0 else { return 0 }
        let scale = Double(bitmap.pixelsWide) / size.width
        let columns = max(0, Int(lower * scale))..<min(bitmap.pixelsWide, Int(upper * scale))
        let rows = max(0, Int((row - 1.5) * scale))...min(bitmap.pixelsHigh - 1, Int((row + 1.5) * scale))
        return columns.filter { column in
            rows.contains { row in
                guard let pixel = bitmap.colorAt(x: column, y: row)?.usingColorSpace(.deviceRGB) else { return false }
                let components = [pixel.redComponent, pixel.greenComponent, pixel.blueComponent]
                let difference = zip(components, paper).map(-)
                let coverage = zip(difference, direction).reduce(0) { $0 + $1.0 * $1.1 } / magnitude
                guard coverage >= 0.25, coverage <= 1.15 else { return false }
                return zip(difference, direction).allSatisfy { abs($0 - $1 * coverage) < 0.08 }
            }
        }.count
    }
}
#endif
