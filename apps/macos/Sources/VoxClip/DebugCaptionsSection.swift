#if DEBUG
import AppKit
import ApplicationServices
import SwiftUI
import Vision
import VoxClipCore

@MainActor private final class CaptionRaceGate {
    var waiting = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0; waiting = true } }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor enum DebugCaptionsSection {
    /// The least glyph height, in 1x pixels, a gallery tile `width` points wide keeps: the old
    /// gallery's 8 from the 1280 column's 118.67 pt tile up, and 6 in the narrowest column's
    /// 84 pt tile, where an uppercase style sets "AND ONE COOL" at the 8 pt floor
    /// (`CardFit.galleryTile`). DebugRound4, `run` and the App tests share it.
    static func minimumTileGlyph(width: CGFloat) -> Int { width >= 118 ? 8 : 6 }
    static func run(app: AppModel, fixture: Project, directory: URL) async throws -> [DebugUISuite.Result] {
        var results: [DebugUISuite.Result] = []
        func check(_ name: String, _ passed: Bool) { results.append(.init(name: name, passed: passed)) }
        var reveal = CaptionGalleryReveal()
        let size = CGSize(width: 294, height: 272)
        let firstRequest = CaptionGalleryRequest(selection: "full/vox-highlight", size: size, fineTune: false)
        reveal.begin(firstRequest); reveal.complete(); reveal.begin(firstRequest)
        check("recreating a selected tile does not steal the user's scroll position", !reveal.pending)
        check("gallery geometry markers never intercept a tile click", ColumnLayoutMarker().hitTest(.zero) == nil)
        reveal.begin(CaptionGalleryRequest(selection: "clip/vox-highlight", size: size, fineTune: false))
        check("a scope change requests selected-tile visibility again", reveal.pending)
        reveal.complete(); reveal.begin(CaptionGalleryRequest(selection: "clip/editorial", size: size, fineTune: false))
        check("a style change requests selected-tile visibility again", reveal.pending)
        results += revealPolicyChecks()
        let document = VoxClipDocument(project: fixture, demo: true)
        let model = EditorModel(document: document, app: app, preview: DemoPreviewEngine())
        defer { model.close() }
        model.refresh(); model.setStyle("box-highlight"); model.setAspect(.landscape)
        var project = model.project
        project.captions.overrides = ["accent": .string("#F3F0E7"), "layout": .object(["maxWords": .number(3)]), "text": .object(["transform": .string("none")])]
        model.replace(project, name: "Gallery fixture")
        check("Box highlight Edited resolves Paper, As said and three words", model.captionsEdited && model.captionSummary == "Paper · As said · 3 words")
        model.setCaptionsEnabled(false); model.setCaptionsEnabled(true)
        check("Captions off then on restores Box highlight", model.project.captions.styleId == "box-highlight")
        guard let boxed = app.styles.first(where: { $0.id == "box-highlight" }), let other = app.styles.first(where: { $0.id != boxed.id }) else { throw CocoaError(.fileReadCorruptFile) }
        let width = CaptionsPanelMetrics.tileWidth(panelWidth: 404)
        let input = model.captionTileInput(boxed, width: width)
        check("only the selected gallery tile receives project overrides", input.overrides == project.captions.overrides && model.captionTileInput(other, width: width).overrides.isEmpty)
        check("every gallery tile shows \"and one cool\", drawn in \"cool\", in a 40-point tile that draws plates", app.styles.allSatisfy { style in
            let tile = model.captionTileInput(style, width: width)
            return tile.text.words.map(\.text) == ["and", "one", "cool"] && tile.text.keyIndex == 2 && tile.language == "en"
                && tile.fit.height == 80 && tile.fit.width == 236 && tile.fit.surface.drawsPlates && tile.fit.surface.lineLimit == 1
        })
        let resting = model.captionTileInput(other, width: width)
        let visible = app.bool("general.showPlaceholderWords", fallback: true)
        model.playhead = 4.2
        app.set("general.showPlaceholderWords", .bool(!visible))
        check("a gallery tile follows neither the playhead nor Settings' placeholder words", model.captionTileInput(other, width: width) == resting)
        app.set("general.showPlaceholderWords", .bool(visible))
        model.playhead = 0
        let state = CaptionTileState()
        let gate = CaptionRaceGate()
        let older = Task { await state.load(input) { _ in await gate.wait(); return nil } }
        while !gate.waiting { await Task.yield() }
        let newest = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        await state.load(input) { _ in newest }
        older.cancel(); gate.release(); await older.value
        check("a cancelled older gallery request finishing last never overwrites the new image", newest != nil && state.image === newest)
        for captionStyle in CaptionsSection.galleryOrder(app.styles) {
            let tileInput = model.captionTileInput(captionStyle, width: width)
            guard let image = await app.captions.card(tileInput),
                  let bitmap = tileBitmap(image, width: tileInput.fit.width / 2, height: tileInput.fit.height / 2) else {
                check("\(captionStyle.id) gallery tile raster exists", false)
                continue
            }
            let height = glyphPixelHeight(bitmap), minimum = minimumTileGlyph(width: width)
            check("\(captionStyle.id) gallery tile text is at least \(minimum) px at 1x (\(height))", height >= minimum)
            check("\(captionStyle.id) gallery tile has no clipped edge glyph", !edgeHasGlyph(bitmap))
            if let data = bitmap.representation(using: .png, properties: [:]) {
                try data.write(to: directory.appendingPathComponent("tile-\(captionStyle.id)-1x.png"))
            }
        }
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            // The panel body at 1280 × 800 (404 × 265) and in the narrowest column.
            for panelWidth in [404, 300] {
                let frame = CGRect(x: 0, y: 0, width: panelWidth, height: 265)
                let view = NSHostingView(rootView: CaptionsSection(model: model, width: frame.width).frame(width: frame.width, height: frame.height).background(DesignValues.color("bg.window")))
                view.frame = frame
                let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.contentView = view; window.appearance = NSAppearance(named: appearance)
                view.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(650)); view.layoutSubtreeIfNeeded()
                if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    let rendered = try recognizedText(bitmap.cgImage)
                    check("\(panelWidth) \(name) rendered panel shows STYLE, the property rows and Box highlight's values without truncation (\(rendered))",
                          rendered.contains("STYLE") && rendered.contains("Words per caption") && rendered.contains("Up to 3") && rendered.contains("As said")
                            && rendered.contains("Position") && rendered.contains("Box highlight") && !rendered.contains("Captions") && !rendered.contains("…"))
                    if let data = bitmap.representation(using: .png, properties: [:]) { try data.write(to: directory.appendingPathComponent("captions-\(panelWidth)-\(name).png")) }
                }
                window.close()
            }
            model.setCaptionsEnabled(false)
            let offView = NSHostingView(rootView: CaptionsSection(model: model, width: 404).frame(width: 404, height: 265).background(DesignValues.color("bg.window")))
            offView.frame = CGRect(x: 0, y: 0, width: 404, height: 265)
            let offWindow = NSWindow(contentRect: offView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            offWindow.isReleasedWhenClosed = false; offWindow.contentView = offView; offWindow.appearance = NSAppearance(named: appearance)
            offView.layoutSubtreeIfNeeded()
            if let bitmap = offView.bitmapImageRepForCachingDisplay(in: offView.bounds) {
                offView.cacheDisplay(in: offView.bounds, to: bitmap)
                let rendered = try recognizedText(bitmap.cgImage)
                let rings = DebugRightColumn.markers(in: offView).keys.filter { $0.hasPrefix("caption.ring.") }
                check("\(name) with captions off the switch reads Off and no tile is selected", rendered.contains("Off") && rings.isEmpty
                      && DebugRightColumn.texts(in: offView)["header.captions.switch"] == "Off")
                if let data = bitmap.representation(using: .png, properties: [:]) { try data.write(to: directory.appendingPathComponent("captions-off-\(name).png")) }
            }
            offWindow.close()
            model.setCaptionsEnabled(true)
            let fineView = NSHostingView(rootView: CaptionsSection(model: model, fineTune: true, width: 404).frame(width: 404, height: 530).background(DesignValues.color("bg.window")))
            fineView.frame = CGRect(x: 0, y: 0, width: 404, height: 530)
            let fineWindow = NSWindow(contentRect: fineView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            fineWindow.isReleasedWhenClosed = false; fineWindow.contentView = fineView; fineWindow.appearance = NSAppearance(named: appearance)
            fineWindow.setAccessibilityIdentifier("caption-fine-tune-\(name)")
            fineWindow.setFrameOrigin(NSPoint(x: -10000, y: -10000))
            fineWindow.orderBack(nil)
            try await Task.sleep(for: .milliseconds(150))
            fineView.layoutSubtreeIfNeeded()
            if let bitmap = fineView.bitmapImageRepForCachingDisplay(in: fineView.bounds) {
                fineView.cacheDisplay(in: fineView.bounds, to: bitmap)
                check("\(name) Reset to Style is rendered with exact capitalization", try recognizedText(bitmap.cgImage).contains("Reset to Style"))
                let application = AXUIElementCreateApplication(getpid())
                let windows = accessibilityAttribute(application, kAXWindowsAttribute) as? [AXUIElement] ?? []
                let nativeWindow = windows.first { (element: AXUIElement) -> Bool in
                    accessibilityAttribute(element, kAXIdentifierAttribute) as? String == fineWindow.accessibilityIdentifier()
                }
                let labels = nativeWindow.map { (element: AXUIElement) -> [String] in accessibilityLabels(element) } ?? []
                check("\(name) Reset to Style is the accessible action label", labels.contains("Reset to Style"))
                check("\(name) the property menus are named by their rows", ["Words per caption", "Case", "Position", "Size"].allSatisfy(labels.contains))
                try JSONEncoder().encode(labels).write(to: directory.appendingPathComponent("captions-fine-tune-\(name)-ax.json"))
                if let data = bitmap.representation(using: .png, properties: [:]) { try data.write(to: directory.appendingPathComponent("captions-fine-tune-\(name).png")) }
            }
            fineWindow.close()
        }
        try JSONEncoder().encode(results).write(to: directory.appendingPathComponent("caption-results.json"), options: .atomic)
        return results
    }
    static func revealPolicyChecks() -> [DebugUISuite.Result] {
        let size = CGSize(width: 294, height: 272)
        var reveal = CaptionGalleryReveal()
        reveal.begin(CaptionGalleryRequest(selection: "full/vox-highlight", size: size, fineTune: true))
        reveal.begin(CaptionGalleryRequest(selection: "clip/vox-highlight", size: size, fineTune: true))
        reveal.resumeForLayout()
        let expandedScope = reveal.pending && !reveal.interrupted
        reveal.cancelForUserScroll()
        reveal.begin(CaptionGalleryRequest(selection: "clip/vox-highlight", size: CGSize(width: 300, height: 250), fineTune: true))
        reveal.resumeForLayout()
        let resized = reveal.interrupted && !reveal.pending
        reveal.selectVisibleTile("clip/editorial")
        reveal.begin(CaptionGalleryRequest(selection: "clip/editorial", size: size, fineTune: false))
        reveal.resumeForLayout()
        let clicked = reveal.interrupted && !reveal.pending
        reveal.begin(CaptionGalleryRequest(selection: "next/editorial", size: size, fineTune: true))
        let nextScope = reveal.pending && !reveal.interrupted
        let scroll = CaptionGalleryScrollState()
        let first = scroll.record(CaptionGalleryViewport(visible: CGRect(origin: .zero, size: size), size: size))
        let frameUpdates = (1...120).filter { offset in
            scroll.record(CaptionGalleryViewport(visible: CGRect(origin: CGPoint(x: 0, y: CGFloat(offset)), size: size), size: size))
        }
        let sizeUpdate = scroll.record(CaptionGalleryViewport(visible: .zero, size: CGSize(width: 320, height: 272)))
        var delayed = CaptionGalleryReveal()
        delayed.begin(CaptionGalleryRequest(selection: "full/editorial", size: size, fineTune: false))
        let corrections = (0..<16).map { offset in
            delayed.shouldScroll(to: .tile("editorial"), geometry: [CGFloat(offset)])
        }
        let duplicate = delayed.shouldScroll(to: .tile("editorial"), geometry: [15])
        return [
            .init(name: "changed viewport geometry can reveal again without duplicate commands", passed: corrections.allSatisfy { $0 } && !duplicate),
            .init(name: "scope changes reveal the selected tile with Fine Tune expanded", passed: expandedScope && nextScope),
            .init(name: "viewport resizing cannot resume a user-interrupted reveal", passed: resized),
            .init(name: "clicking a visible tile does not request a reveal", passed: clicked),
            .init(name: "120 scroll frames update non-observed geometry without publishing gallery size", passed: first && frameUpdates.isEmpty && sizeUpdate)
        ]
    }
    static func tileBitmap(_ image: CGImage, width: Int, height: Int) -> NSBitmapImageRep? {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage().map { NSBitmapImageRep(cgImage: $0) }
    }
    private static func recognizedText(_ image: CGImage?) throws -> String {
        guard let image else { return "" }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { (observation: VNRecognizedTextObservation) -> String? in
            observation.topCandidates(1).first?.string
        }.joined(separator: " ")
    }
    private static func accessibilityAttribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
    private static func accessibilityLabels(_ element: AXUIElement, depth: Int = 0) -> [String] {
        guard depth < 32 else { return [] }
        let labels: [String] = [kAXDescriptionAttribute, kAXTitleAttribute].compactMap { (name: String) -> String? in
            accessibilityAttribute(element, name) as? String
        }
        let children = accessibilityAttribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
        let nextDepth: Int = depth + 1
        return labels + children.flatMap { (child: AXUIElement) -> [String] in accessibilityLabels(child, depth: nextDepth) }
    }
    static func edgeHasGlyph(_ bitmap: NSBitmapImageRep) -> Bool {
        func hasGlyph(column: Int, row: Int) -> Bool {
            guard let pixel = bitmap.colorAt(x: column, y: row)?.usingColorSpace(.sRGB) else { return false }
            let maximum: CGFloat = max(pixel.redComponent, pixel.greenComponent, pixel.blueComponent)
            let minimum: CGFloat = min(pixel.redComponent, pixel.greenComponent, pixel.blueComponent)
            return maximum - minimum > 0.15 || maximum > 0.8
        }
        for column in [0, 1, bitmap.pixelsWide - 2, bitmap.pixelsWide - 1] {
            for row in 1..<(bitmap.pixelsHigh - 1) {
                if hasGlyph(column: column, row: row) { return true }
            }
        }
        for row in [0, 1, bitmap.pixelsHigh - 2, bitmap.pixelsHigh - 1] {
            for column in 1..<(bitmap.pixelsWide - 1) {
                if hasGlyph(column: column, row: row) { return true }
            }
        }
        return false
    }
    static func glyphPixelHeight(_ bitmap: NSBitmapImageRep) -> Int {
        var longest = 0, run = 0
        for row in 1..<(bitmap.pixelsHigh - 1) {
            var transitions = 0
            for column in 1..<(bitmap.pixelsWide - 1) {
                guard let before = bitmap.colorAt(x: column - 1, y: row)?.usingColorSpace(.sRGB),
                      let after = bitmap.colorAt(x: column, y: row)?.usingColorSpace(.sRGB) else { continue }
                let red: Double = abs(before.redComponent - after.redComponent)
                let green: Double = abs(before.greenComponent - after.greenComponent)
                let blue: Double = abs(before.blueComponent - after.blueComponent)
                if max(red, green, blue) >= 0.18 { transitions += 1 }
            }
            run = transitions >= 4 ? run + 1 : 0
            longest = max(longest, run)
        }
        return longest
    }
}
#endif
