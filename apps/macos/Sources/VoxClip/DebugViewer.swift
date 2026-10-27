#if DEBUG
import AppKit
import SwiftUI
import VoxClipCore
import ApplicationServices

@MainActor enum DebugViewer {
    static func run(app: AppModel, fixture: Project, directory: URL) async throws -> [DebugUISuite.Result] {
        var results: [DebugUISuite.Result] = []
        let landscape = viewerStageSize(ratio: 16 / 9, innerWidth: 328, columnHeight: 800, rewriting: false)
        let portrait = viewerStageSize(ratio: 9 / 16, innerWidth: 328, columnHeight: 800, rewriting: false)
        let compact = viewerStageSize(ratio: 16 / 9, innerWidth: 328, columnHeight: 700, rewriting: true)
        results.append(.init(name: "viewer landscape fills 328 points at 16:9", passed: landscape.width == 328 && abs(landscape.height - 184.5) < 0.1))
        results.append(.init(name: "viewer portrait is centered at 180 by 320", passed: portrait == CGSize(width: 180, height: 320)))
        results.append(.init(name: "viewer shrinks to 124 high while Rewrite is open in a short column", passed: compact.height == 124))
        let model = EditorModel(document: VoxClipDocument(project: fixture, demo: true), app: app, preview: DemoPreviewEngine())
        defer { model.close() }
        model.refresh()
        model.setAspect(.source)
        results.append(.init(name: "Original still persists source aspect", passed: model.project.export.aspect == .source && model.project.export.aspect.rawValue == "source"))
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for aspect in [AspectRatio.landscape, .portrait, .square] {
                model.setAspect(aspect)
                let view = NSHostingView(rootView: ViewerSection(model: model).frame(width: 360).background(DesignValues.color("bg.surface")))
                view.frame = CGRect(x: 0, y: 0, width: 360, height: aspect == .landscape ? 294.5 : 430)
                let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.contentView = view; window.appearance = NSAppearance(named: appearance)
                window.setAccessibilityIdentifier("voxclip.debug.viewer.\(name).\(aspect.rawValue)")
                view.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(180))
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                try await Task.sleep(for: .milliseconds(100))
                if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    if let data = bitmap.representation(using: .png, properties: [:]) { try data.write(to: directory.appendingPathComponent("viewer-\(aspect.rawValue)-\(name).png")) }
                }
                let application = AXUIElementCreateApplication(getpid())
                let windows = attribute(application, kAXWindowsAttribute) as? [AXUIElement] ?? []
                let target = windows.first { (attribute($0, kAXIdentifierAttribute) as? String) == window.accessibilityIdentifier() }
                let elements = target.map { descendants($0, depth: 0) } ?? []
                let labels = elements.compactMap { attribute($0, kAXDescriptionAttribute) as? String }
                let times = elements.filter { (attribute($0, kAXIdentifierAttribute) as? String) == "voxclip.viewer.time" }
                try JSONSerialization.data(withJSONObject: labels).write(to: directory.appendingPathComponent("viewer-\(aspect.rawValue)-\(name)-ax.json"))
                results.append(.init(name: "\(name) \(aspect.rawValue) viewer has one accessible playback time (\(times.count))", passed: times.count == 1))
                window.close()
            }
        }
        return results
    }
    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
        return result
    }
    private static func descendants(_ element: AXUIElement, depth: Int) -> [AXUIElement] {
        guard depth < 32 else { return [] }
        let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
        return [element] + children.flatMap { descendants($0, depth: depth + 1) }
    }
}
#endif
