#if DEBUG
import AppKit
import SwiftUI
import VoxClipCore
import ApplicationServices

/// The v2 viewer (impl-plan V4): the fixed 16:9 box of the column's width and the frame
/// fitted in it, the one tag, the hover transport only with the timeline hidden, and a low
/// caption still draggable under it. Captures `v2-viewer-{aspect}-{appearance}` and
/// `v2-viewer-transport-{appearance}`; the drag's evidence is `v2-viewer-caption-drag.json`.
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
        check("focus on the box, Play or Edited / Source keeps the transport; a caption drag hides it",
              ViewerSection.showsTransport(timelineVisible: false, hovering: false, focused: false, focusInside: true, voiceOver: false)
              && !ViewerSection.showsTransport(timelineVisible: false, hovering: true, focused: true, voiceOver: true, captionDragging: true))

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
        results += try await captionDrag(app: app, fixture: fixture, box: box, directory: directory)
        return results
    }
    /// impl-plan V4's named risk: a caption placed low (Clean Subtitle, y 0.9) sits under the
    /// hover transport. A press on the bar outside Play and Edited / Source reaches the
    /// caption, the bar steps aside while it moves, and the move is one undo step. The
    /// document is never saved and harness sessions do not autosave it.
    private static func captionDrag(app: AppModel, fixture: Project, box: CGSize, directory: URL) async throws -> [DebugUISuite.Result] {
        var project = fixture
        project.captions.styleId = "clean-subtitle"
        project.export.aspect = .landscape
        let model = EditorModel(document: VoxClipDocument(project: project, demo: false), app: app, preview: DemoPreviewEngine())
        defer { model.close() }
        model.mediaResolved = true
        model.refresh()
        let view = NSHostingView(rootView: ViewerSection(model: model, columnWidth: box.width, timelineVisible: false, hovering: true))
        view.frame = CGRect(origin: .zero, size: box)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        defer { window.close() }
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(180))
        window.orderBack(nil)
        try await Task.sleep(for: .milliseconds(100))
        view.layoutSubtreeIfNeeded()
        let before = DebugRightColumn.markers(in: view)
        guard let handle = before["caption.handle"], let bar = before["viewer.transport"], let play = before["viewer.play"], let axis = before["viewer.axis"] else {
            return [.init(name: "a Clean Subtitle caption has a drag handle under the hover transport (\(before.keys.sorted()))", passed: false)]
        }
        // The bar is 8 in from the box (48 with its margin); the press is on the bar, on the caption, clear of its controls.
        let inner = bar.insetBy(dx: 8, dy: 8)
        let press = CGPoint(x: (max(play.maxX, handle.minX) + min(axis.minX, handle.maxX)) / 2, y: (max(inner.minY, handle.minY) + min(inner.maxY, handle.maxY)) / 2)
        let onBar = inner.contains(press) && handle.contains(press) && !play.contains(press) && !axis.contains(press)
        let steps = model.undoSteps, start = model.project.captions
        func send(_ type: NSEvent.EventType, _ point: CGPoint) {
            let location = CGPoint(x: point.x, y: box.height - point.y)
            if let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) { window.sendEvent(event) }
        }
        send(.leftMouseDown, press)
        for step in 1...6 {
            send(.leftMouseDragged, CGPoint(x: press.x, y: press.y - CGFloat(step) * 12))
            try await Task.sleep(for: .milliseconds(16))
        }
        view.layoutSubtreeIfNeeded()
        let during = DebugRightColumn.markers(in: view)
        send(.leftMouseUp, CGPoint(x: press.x, y: press.y - 72))
        try await Task.sleep(for: .milliseconds(100))
        view.layoutSubtreeIfNeeded()
        let after = DebugRightColumn.markers(in: view)
        struct Evidence: Encodable {
            let press: CGPoint; let before: [String: CGRect]; let during: [String: CGRect]; let after: [String: CGRect]
            let moved: Bool; let undoSteps: Int
        }
        let moved = model.project.captions != start
        try JSONEncoder().encode(Evidence(press: press, before: before, during: during, after: after, moved: moved, undoSteps: model.undoSteps - steps))
            .write(to: directory.appendingPathComponent("v2-viewer-caption-drag.json"), options: .atomic)
        return [
            .init(name: "the press \(press) is on the bar and the caption, clear of Play and Edited / Source", passed: onBar),
            .init(name: "pressing the caption through the bar starts its drag, and the bar steps aside meanwhile",
                  passed: during["caption.guides"] != nil && during["viewer.transport"] == nil),
            .init(name: "the drag moves the caption up as one undo step", passed: moved && model.undoSteps == steps + 1),
            .init(name: "the bar comes back when the drag ends", passed: after["caption.guides"] == nil && after["viewer.transport"] != nil)
        ]
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
