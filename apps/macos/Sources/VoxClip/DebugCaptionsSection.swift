#if DEBUG
import AppKit
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
    static func run(app: AppModel, fixture: Project, directory: URL) async throws -> [DebugUISuite.Result] {
        var results: [DebugUISuite.Result] = []
        func check(_ name: String, _ passed: Bool) { results.append(.init(name: name, passed: passed)) }
        check("bundled caption styles have no Other group", app.styles.allSatisfy { CaptionStyleGroup.group(for: $0) != .other })
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
        guard let boxed = app.styles.first(where: { $0.id == "box-highlight" }), let other = app.styles.first(where: { $0.id != boxed.id }), let resources = app.captionResources else { throw CocoaError(.fileReadCorruptFile) }
        let input = model.captionTileInput(boxed)
        check("only the selected gallery tile receives project overrides", input.overrides == project.captions.overrides && model.captionTileInput(other).overrides.isEmpty)
        let expected = CaptionGalleryPages(project: model.project, scope: .fullTake, style: boxed, wordsVisible: true, resources: resources).sample(at: model.playhead)
        check("gallery sample comes from the Core page at the edited playhead", input.sample == expected)
        let visible = app.bool("general.showPlaceholderWords", fallback: true)
        app.set("general.showPlaceholderWords", .bool(false))
        let preview = model.captionTileInput(boxed)
        check("hidden placeholder words use the style's English preview sample", preview.sample == CaptionGallerySample.preview(boxed) && preview.language == "en")
        app.set("general.showPlaceholderWords", .bool(visible))
        model.progress = "Transcribing"; model.progressStage = .transcribing
        let loading = model.captionTileInput(boxed)
        check("transcribing without a frame uses stage black and the style preview sample", loading.loading && loading.sample == CaptionGallerySample.preview(boxed))
        model.progress = nil; model.progressStage = nil
        let state = CaptionTileState()
        let gate = CaptionRaceGate()
        let older = Task { await state.load(input) { _ in await gate.wait(); return nil } }
        while !gate.waiting { await Task.yield() }
        let newest = NSImage(size: CGSize(width: 2, height: 2))
        await state.load(input) { _ in newest }
        older.cancel(); gate.release(); await older.value
        check("a cancelled older gallery request finishing last never overwrites the new image", state.image === newest)
        let white = CGContext(data: nil, width: 320, height: 180, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        white.setFillColor(NSColor.white.cgColor); white.fill(CGRect(x: 0, y: 0, width: 320, height: 180))
        let fallback = app.captions.tileBackdrop(input, still: white.makeImage())
        let pixel = fallback?.cgImage(forProposedRect: nil, context: nil, hints: nil).map { NSBitmapImageRep(cgImage: $0) }?.colorAt(x: 2, y: 2)?.usingColorSpace(.sRGB)
        let fallbackMatches: Bool = pixel.map { (color: NSColor) -> Bool in abs(color.redComponent - 0.65) < 0.02 && abs(color.greenComponent - 0.65) < 0.02 } ?? false
        check("gallery fallback draws the same 35-percent-dim frame band without text", fallbackMatches)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for captionStyle in app.styles {
                var tileInput = model.captionTileInput(captionStyle)
                tileInput.frameAvailable = false
                tileInput.backdrop = name == "light" ? "#4B4B4B" : "#181818"
                guard let image = await app.captions.tile(tileInput),
                      let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                      let bitmap = tileBitmap(source, width: 140, height: 63) else {
                    check("\(name) \(captionStyle.id) gallery text raster exists", false)
                    continue
                }
                let height = glyphPixelHeight(bitmap)
                check("\(name) \(captionStyle.id) gallery text is at least 8 px at 1x (\(height))", height >= 8)
                if let data = bitmap.representation(using: .png, properties: [:]) {
                    try data.write(to: directory.appendingPathComponent("tile-\(captionStyle.id)-\(name)-1x.png"))
                }
                tileInput.tileSize = PixelSize(width: 128, height: 72)
                tileInput.overrides = [:]
                if let chip = await app.captions.tile(tileInput),
                   let source = chip.cgImage(forProposedRect: nil, context: nil, hints: nil),
                   let bitmap = tileBitmap(source, width: 64, height: 36) {
                    let height = glyphPixelHeight(bitmap)
                    check("\(name) \(captionStyle.id) live chip text is at least 8 px at 1x (\(height))", height >= 8)
                    if let data = bitmap.representation(using: .png, properties: [:]) {
                        try data.write(to: directory.appendingPathComponent("chip-\(captionStyle.id)-\(name)-1x.png"))
                    }
                } else { check("\(name) \(captionStyle.id) live chip text raster exists", false) }
            }
            for width in [360, 320] {
                let view = NSHostingView(rootView: CaptionsSection(model: model).frame(width: CGFloat(width), height: 530).background(DesignValues.color("bg.surface")))
                view.frame = CGRect(x: 0, y: 0, width: width, height: 530)
                let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.contentView = view; window.appearance = NSAppearance(named: appearance)
                view.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(650))
                if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    let rendered = try recognizedText(bitmap.cgImage)
                    check("\(width) \(name) rendered summary includes Paper, As said and 3 words without truncation", rendered.contains("Paper") && rendered.contains("As said") && rendered.contains("3 words") && !rendered.contains("…"))
                    if let data = bitmap.representation(using: .png, properties: [:]) { try data.write(to: directory.appendingPathComponent("captions-\(width)-\(name).png")) }
                }
                window.close()
            }
        }
        try JSONEncoder().encode(results).write(to: directory.appendingPathComponent("caption-results.json"), options: .atomic)
        return results
    }
    private static func tileBitmap(_ image: CGImage, width: Int, height: Int) -> NSBitmapImageRep? {
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
    private static func glyphPixelHeight(_ bitmap: NSBitmapImageRep) -> Int {
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
