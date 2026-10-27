#if DEBUG
import AppKit
import SwiftUI
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
        check("gallery fallback draws the same 35-percent-dim frame band without text", pixel.map { abs($0.redComponent - 0.65) < 0.02 && abs($0.greenComponent - 0.65) < 0.02 } ?? false)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for width in [360, 320] {
                let view = NSHostingView(rootView: CaptionsSection(model: model).frame(width: CGFloat(width), height: 530).background(DesignValues.color("bg.surface")))
                view.frame = CGRect(x: 0, y: 0, width: width, height: 530)
                let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.contentView = view; window.appearance = NSAppearance(named: appearance)
                view.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(650))
                if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    if let data = bitmap.representation(using: .png, properties: [:]) { try data.write(to: directory.appendingPathComponent("captions-\(width)-\(name).png")) }
                }
                window.close()
            }
        }
        return results
    }
}
#endif
