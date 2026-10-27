#if DEBUG
import AppKit
import SwiftUI
import VoxClipCore

@MainActor enum DebugSelectionBar {
    static func run(app: AppModel, fixture: Project, directory: URL) async throws -> [DebugUISuite.Result] {
        var results: [DebugUISuite.Result] = []
        let visible = CGRect(x: 0, y: 60, width: 700, height: 400)
        let size = CGSize(width: 360, height: 36)
        let cases: [(String, [CGRect], CGRect, CGFloat, Bool)] = [
            ("normal", [CGRect(x: 200, y: 200, width: 240, height: 32)], visible, 60, true),
            ("toolbar flip", [CGRect(x: 200, y: 65, width: 240, height: 32)], visible, 60, true),
            ("right clamp", [CGRect(x: 650, y: 200, width: 40, height: 32)], visible, 60, true),
            ("left clamp", [CGRect(x: 0, y: 200, width: 40, height: 32)], visible, 60, true),
            ("no safe position", [CGRect(x: 200, y: 60, width: 240, height: 400)], visible, 60, false)
        ]
        for (name, lines, viewport, inset, fits) in cases {
            let frame = selectionBarFrame(lineRects: lines, visibleRect: viewport, barSize: size, toolbarInset: inset)
            let safe = frame.isEmpty || viewport.contains(frame) && !lines.contains { $0.intersects(frame) }
            results.append(.init(name: "selection bar geometry: \(name)", passed: safe && frame.isEmpty != fits))
        }
        let model = EditorModel(document: VoxClipDocument(project: fixture, demo: true), app: app, preview: DemoPreviewEngine())
        defer { model.close() }
        let coordinator = TranscriptTextView.Coordinator(model: model)
        let text = TranscriptNSTextView(usingTextLayoutManager: true)
        text.frame = CGRect(x: 0, y: 0, width: 720, height: 500)
        text.textContainerInset = CGSize(width: 84, height: 8)
        text.textContainer?.containerSize = CGSize(width: 600, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = false
        text.model = model; text.delegate = coordinator; text.textLayoutManager?.delegate = coordinator
        coordinator.text = text; coordinator.renderer.text = text
        coordinator.renderer.rebuild(model: model)
        text.textLayoutManager?.ensureLayout(for: text.textLayoutManager!.documentRange)
        let textWindow = NSWindow(contentRect: text.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        textWindow.isReleasedWhenClosed = false; textWindow.contentView = text
        defer { textWindow.close() }
        let words = Array(model.words.prefix(3))
        model.selectedWordIDs = Set(words.map(\.id))
        text.selectedRanges = words.compactMap { text.map.span(id: $0.id).map { NSValue(range: $0.range) } }
        if let tab = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: textWindow.windowNumber, context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48) { text.keyDown(with: tab) }
        results.append(.init(name: "keyboard Tab reveals the selection bar without a pointer", passed: text.selectionBarVisible))
        if let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: textWindow.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 53) { text.keyDown(with: escape) }
        results.append(.init(name: "keyboard Escape dismisses the selection bar", passed: !text.selectionBarVisible))
        model.findVisible = true; text.showSelectionBar()
        results.append(.init(name: "Find suppresses the selection bar", passed: !text.selectionBarVisible))
        model.findVisible = false
        let original = model.project
        let selected = Set(words.map(\.id))
        text.selectedRanges = words.compactMap { text.map.span(id: $0.id).map { NSValue(range: $0.range) } }
        model.selectedWordIDs = selected
        model.cutSelection()
        model.cutSelection()
        results.append(.init(name: "the selection bar's named Cut always cuts an already-cut selection", passed: selected.isSubset(of: model.cutWordIDs)))
        let accessibleCut = text.accessibleCut()
        results.append(.init(name: "VoiceOver Cut never restores an already-cut selection", passed: accessibleCut && model.selectedWordIDs.isSubset(of: model.cutWordIDs)))
        if let delete = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: textWindow.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 51) { text.keyDown(with: delete) }
        results.append(.init(name: "only the Delete key toggles an already-cut selection to restored", passed: model.selectedWordIDs.isDisjoint(with: model.cutWordIDs)))
        model.cutSelection()
        _ = text.accessibleRestore()
        results.append(.init(name: "VoiceOver Restore remains a separate unconditional restore action", passed: model.selectedWordIDs.isDisjoint(with: model.cutWordIDs)))
        model.document.replaceProject(original)
        model.refresh()
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            textWindow.appearance = NSAppearance(named: appearance)
            text.showSelectionBar()
            if let bitmap = text.bitmapImageRepForCachingDisplay(in: text.bounds) {
                text.cacheDisplay(in: text.bounds, to: bitmap)
                if let data = bitmap.representation(using: .png, properties: [:]) { try data.write(to: directory.appendingPathComponent("selection-page-\(name).png")) }
            }
            for opaque in [false, true] {
                let view = NSHostingView(rootView: SelectionBar(model: model, forceOpaque: opaque, dismiss: {}))
                view.frame = CGRect(x: 0, y: 0, width: view.fittingSize.width, height: 36)
                let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.contentView = view
                window.appearance = NSAppearance(named: appearance)
                view.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(170))
                if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    if let data = bitmap.representation(using: .png, properties: [:]) {
                        try data.write(to: directory.appendingPathComponent("live-selection-bar-\(name)\(opaque ? "-opaque" : "").png"))
                        results.append(.init(name: "\(name) selection bar \(opaque ? "opaque" : "glass") capture", passed: bitmap.pixelsHigh > 0))
                    }
                }
                window.close()
            }
        }
        return results
    }
}
#endif
