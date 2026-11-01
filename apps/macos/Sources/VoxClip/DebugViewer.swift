#if DEBUG
import AppKit
import SwiftUI
import VoxClipCore
import ApplicationServices

/// The v2 viewer (impl-plan V4): the fixed 16:9 box of the column's width and the frame
/// fitted in it, the one tag, and the hover transport only with the timeline hidden.
/// Captures `v2-viewer-{aspect}-{appearance}` and `v2-viewer-transport-{appearance}`.
@MainActor enum DebugViewer {
    static func run(app: AppModel, fixture: Project, directory: URL) async throws -> [DebugUISuite.Result] {
        var results: [DebugUISuite.Result] = []
        func check(_ name: String, _ passed: Bool) { results.append(.init(name: name, passed: passed)) }
        let box = CGSize(width: 404, height: ViewerSection.boxHeight(forWidth: 404))
        check("the viewer box is 16:9 of the column's width: 404 × 227 at 1280 (notes.md §1)", box == CGSize(width: 404, height: 227))
        check("a 16:9 frame fills the box", ViewerSection.stageSize(ratio: 16 / 9, in: box) == box)
        check("a 9:16 frame is pillarboxed at 128 × 227 (f5)", ViewerSection.stageSize(ratio: 9 / 16, in: box) == CGSize(width: 128, height: 227))
        check("a 1:1 frame is pillarboxed at 227 × 227", ViewerSection.stageSize(ratio: 1, in: box) == CGSize(width: 227, height: 227))
        check("a box shorter than 16:9 pillarboxes a 16:9 frame", ViewerSection.stageSize(ratio: 16 / 9, in: CGSize(width: 404, height: 180)) == CGSize(width: 320, height: 180))
        check("the hover transport shows only with the timeline hidden",
              !ViewerSection.showsTransport(timelineVisible: true, hovering: true, focused: true, voiceOver: true)
              && ViewerSection.showsTransport(timelineVisible: false, hovering: true, focused: false, voiceOver: false)
              && ViewerSection.showsTransport(timelineVisible: false, hovering: false, focused: true, voiceOver: false)
              && ViewerSection.showsTransport(timelineVisible: false, hovering: false, focused: false, voiceOver: true)
              && !ViewerSection.showsTransport(timelineVisible: false, hovering: false, focused: false, voiceOver: false))

        let model = EditorModel(document: VoxClipDocument(project: fixture, demo: true), app: app, preview: DemoPreviewEngine())
        defer { model.close() }
        model.refresh()
        check("the demo stand-in shows its media chip as the one tag", ViewerSection.tag(for: model, standIn: true) == .media("Demo · no video"))
        check("a playing video shows no tag without AI speech", ViewerSection.tag(for: model, standIn: false) == nil)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for aspect in [AspectRatio.landscape, .portrait, .square] {
                model.setAspect(aspect)
                let view = NSHostingView(rootView: ViewerSection(model: model, columnWidth: 404).background(DesignValues.color("bg.window")))
                view.frame = CGRect(origin: .zero, size: box)
                view.appearance = NSAppearance(named: appearance)
                view.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(120))
                view.layoutSubtreeIfNeeded()
                let markers = DebugRightColumn.markers(in: view)
                let expected = ViewerSection.stageSize(ratio: ViewerSection.ratio(model.project), in: box)
                let stage = markers["viewer.stage"] ?? .zero
                check("\(name) \(aspect.rawValue): the box is 404 × 227 and the stage \(expected) is centred in it (\(stage))",
                      markers["viewer.box"].map { abs($0.width - 404) <= 0.5 && abs($0.height - 227) <= 0.5 } == true
                      && abs(stage.width - expected.width) <= 0.5 && abs(stage.height - expected.height) <= 0.5 && abs(stage.midX - 202) <= 0.5 && abs(stage.midY - 113.5) <= 0.5)
                check("\(name) \(aspect.rawValue): one tag at the stage's top-leading corner, no transport with the timeline showing",
                      markers["viewer.tag"].map { abs($0.minX - stage.minX - 10) <= 0.5 && abs($0.minY - stage.minY - 10) <= 0.5 } == true && markers["viewer.transport"] == nil)
                try capture(view, name: "v2-viewer-\(aspect.rawValue == "16:9" ? "16x9" : aspect.rawValue == "9:16" ? "9x16" : "1x1")-\(name)", directory: directory)
            }
        }

        // With the timeline hidden, the pointer over the viewer shows the transport at its
        // bottom edge, read by VoiceOver as one playback time, Play and Edited / Source.
        model.setAspect(.landscape)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let view = NSHostingView(rootView: ViewerSection(model: model, columnWidth: 404, timelineVisible: false, hovering: true))
            view.frame = CGRect(origin: .zero, size: box)
            let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = view; window.appearance = NSAppearance(named: appearance)
            window.setAccessibilityIdentifier("voxclip.debug.viewer.transport.\(name)")
            view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(180))
            window.orderBack(nil)
            try await Task.sleep(for: .milliseconds(100))
            view.layoutSubtreeIfNeeded()
            let transport = DebugRightColumn.markers(in: view)["viewer.transport"]
            check("\(name): the hover transport sits along the box's bottom edge, 8 in (\(transport.map { "\($0)" } ?? "missing"))",
                  transport.map { abs($0.minX) <= 0.5 && abs($0.maxX - 404) <= 0.5 && abs($0.maxY - 227) <= 0.5 && abs($0.height - 48) <= 0.5 } == true)
            let application = AXUIElementCreateApplication(getpid())
            let windows = attribute(application, kAXWindowsAttribute) as? [AXUIElement] ?? []
            let target = windows.first { (attribute($0, kAXIdentifierAttribute) as? String) == window.accessibilityIdentifier() }
            let elements = target.map { descendants($0, depth: 0) } ?? []
            let identifiers = elements.compactMap { attribute($0, kAXIdentifierAttribute) as? String }
            try JSONSerialization.data(withJSONObject: identifiers).write(to: directory.appendingPathComponent("v2-viewer-transport-\(name)-ax.json"))
            check("\(name): the hover transport has one accessible playback time, Play and Edited / Source",
                  identifiers.filter { $0 == "voxclip.viewer.time" }.count == 1 && identifiers.contains("voxclip.viewer.play") && identifiers.contains("voxclip.viewer.axis"))
            try capture(view, name: "v2-viewer-transport-\(name)", directory: directory)
            window.close()
        }
        return results
    }
    private static func capture(_ view: NSView, name: String, directory: URL) throws {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let data = bitmap.representation(using: .png, properties: [:]) { try data.write(to: directory.appendingPathComponent("\(name).png")) }
    }
    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
        return result
    }
    private static func descendants(_ element: AXUIElement, depth: Int) -> [AXUIElement] {
        guard depth < 32 else { return [] }
        let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
        let nextDepth: Int = depth + 1
        return [element] + children.flatMap { (child: AXUIElement) -> [AXUIElement] in descendants(child, depth: nextDepth) }
    }
}
#endif
