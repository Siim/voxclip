#if DEBUG
import AppKit
import ApplicationServices
import VoxClipCore

@MainActor enum DebugColumnBounds {
    struct Element: Codable {
        let label: String
        let identifier: String
        let role: String
        let frame: CGRect
    }
    struct Evidence: Codable {
        let editor: Bool
        let column: CGRect
        let content: CGRect
        let collapsed: Bool
        let elements: [Element]
        /// Right-column descendants without a position or size, as "role label identifier".
        let unmeasured: [String]
        let failures: [String]
        let markers: [String: CGRect]
    }
    static func split(in view: NSView?) -> NSSplitView? {
        guard let view else { return nil }
        if let split = view as? NSSplitView, split.identifier?.rawValue == "voxclip.editor.split" { return split }
        return view.subviews.lazy.compactMap { split(in: $0) }.first
    }
    static func assertBounds(window: NSWindow, name: String, directory: URL) throws {
        let editorWindow = window.sheetParent ?? window
        guard let contentView = editorWindow.contentView else { return }
        let content = screenFrame(contentView, window: editorWindow)
        guard let split = split(in: contentView), let right = split.arrangedSubviews.last else {
            // Home and other non-editor captures have no split. An editor without one would skip every check.
            let failures = containsTranscript(contentView) ? ["The editor is showing but its split view is missing"] : []
            let evidence = Evidence(editor: false, column: .zero, content: content, collapsed: false, elements: [], unmeasured: [], failures: failures, markers: [:])
            try JSONEncoder().encode(evidence).write(to: directory.appendingPathComponent("\(name)-bounds.json"), options: .atomic)
            guard failures.isEmpty else { throw VoxClipError.exportFailed("Right-column bounds failed in \(name): \(failures.joined(separator: "; "))") }
            return
        }
        let column = screenFrame(right, window: editorWindow)
        let collapsed = split.isSubviewCollapsed(right)
        var failures: [String] = []
        var elements: [Element] = []
        var unmeasured: [String] = []
        if !collapsed {
            let application = AXUIElementCreateApplication(getpid())
            let windows = attribute(application, kAXWindowsAttribute) as? [AXUIElement] ?? []
            let all = windows.flatMap { descendants($0, depth: 0) }
            try JSONEncoder().encode(all.compactMap(element)).write(to: directory.appendingPathComponent("\(name)-ax-tree.json"), options: .atomic)
            if let root = all.first(where: {
                guard (attribute($0, kAXIdentifierAttribute) as? String) == "voxclip.editor.right", let frame = element($0)?.frame else { return false }
                return abs(frame.minX - column.minX) <= 0.5 && abs(frame.width - column.width) <= 0.5
            }) {
                for item in descendants(root, depth: 0) {
                    if let measured = element(item) { elements.append(measured); continue }
                    let role = attribute(item, kAXRoleAttribute) as? String ?? ""
                    let label = [kAXDescriptionAttribute, kAXTitleAttribute].compactMap { attribute(item, $0) as? String }.first { !$0.isEmpty } ?? ""
                    let identifier = attribute(item, kAXIdentifierAttribute) as? String ?? ""
                    unmeasured.append("\(role) \(label) \(identifier)")
                    // A named control without a frame can't be bounds-checked, so it fails rather than being dropped.
                    if [kAXButtonRole, kAXRadioButtonRole, kAXCheckBoxRole].contains(role), !(label + identifier).isEmpty {
                        failures.append("Unmeasurable control: \(role) \(label) \(identifier)")
                    }
                }
            } else { failures.append("Right-column accessibility root is missing") }
            for item in elements where item.frame.width > 0 && item.frame.height > 0 {
                if !column.insetBy(dx: -0.5, dy: -0.5).contains(item.frame) { failures.append("Column overflow: \(item.label) \(item.identifier) \(item.frame)") }
                if !content.insetBy(dx: -0.5, dy: -0.5).contains(item.frame) { failures.append("Window overflow: \(item.label) \(item.identifier) \(item.frame)") }
            }
            let identifiers = Set(elements.map(\.identifier))
            let labels = Set(elements.map(\.label))
            for required in ["voxclip.viewer.stage", "voxclip.viewer.time"] where !identifiers.contains(required) { failures.append("Missing \(required)") }
            for required in ["Back 3 seconds", "Forward 3 seconds"] where !labels.contains(required) { failures.append("Missing \(required)") }
            if !labels.contains("Play") && !labels.contains("Pause") { failures.append("Missing Play/Pause") }
            for required in ["9:16", "1:1", "16:9", "Original"] where !labels.contains(required) { failures.append("Missing Frame choice \(required)") }
            if !identifiers.contains("voxclip.rewrite") {
                for required in ["voxclip.captions.switch", "voxclip.captions.summary", "voxclip.captions.gallery"] where !identifiers.contains(required) { failures.append("Missing \(required)") }
                if !elements.contains(where: { $0.role == kAXRadioButtonRole && $0.label.contains(": ") }) { failures.append("Missing caption gallery choices") }
            }
        }
        let evidence = Evidence(editor: true, column: column, content: content, collapsed: collapsed, elements: elements,
            unmeasured: unmeasured, failures: failures, markers: DebugRightColumn.markers(in: right))
        try JSONEncoder().encode(evidence).write(to: directory.appendingPathComponent("\(name)-bounds.json"), options: .atomic)
        guard failures.isEmpty else { throw VoxClipError.exportFailed("Right-column bounds failed in \(name): \(failures.joined(separator: "; "))") }
    }
    private static func containsTranscript(_ view: NSView) -> Bool {
        view is TranscriptNSTextView || view.subviews.contains { containsTranscript($0) }
    }
    private static func screenFrame(_ view: NSView, window: NSWindow) -> CGRect {
        let rect = window.convertToScreen(view.convert(view.bounds, to: nil))
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        return CGRect(x: rect.minX, y: top - rect.maxY, width: rect.width, height: rect.height)
    }
    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
        return result
    }
    private static func descendants(_ element: AXUIElement, depth: Int) -> [AXUIElement] {
        var seen: Set<AXUIElement> = []
        func visit(_ current: AXUIElement, level: Int) -> [AXUIElement] {
            guard level < 48, seen.insert(current).inserted else { return [] }
            let children = attribute(current, kAXChildrenAttribute) as? [AXUIElement] ?? []
            return [current] + children.flatMap { visit($0, level: level + 1) }
        }
        return visit(element, level: depth)
    }
    private static func element(_ element: AXUIElement) -> Element? {
        guard let position = attribute(element, kAXPositionAttribute), let size = attribute(element, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &dimensions) else { return nil }
        let label = [kAXDescriptionAttribute, kAXTitleAttribute, kAXValueAttribute].compactMap { attribute(element, $0) as? String }.first { !$0.isEmpty } ?? ""
        return Element(label: label, identifier: attribute(element, kAXIdentifierAttribute) as? String ?? "",
            role: attribute(element, kAXRoleAttribute) as? String ?? "", frame: CGRect(origin: point, size: dimensions))
    }
}
#endif
