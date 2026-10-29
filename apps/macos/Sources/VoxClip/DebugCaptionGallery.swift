#if DEBUG
import AppKit
import ApplicationServices
import SwiftUI
import VoxClipCore

@MainActor enum DebugCaptionGallery {
    struct Measurement: Codable {
        let name: String
        let width: CGFloat
        let height: CGFloat
        let style: String
        let snapshot: CaptionGalleryAudit.Snapshot?
        let elapsed: Double
        let settled: Bool
    }
    static func run(app: AppModel, directory: URL) async throws -> [DebugUISuite.Result] {
        guard let root = app.shared?.root else { throw VoxClipError.sharedResourcesMissing }
        let fixture = try DemoEditing.loadFixture(root.appendingPathComponent("fixtures/projects/five-questions.voxclip"))
        let ordered = CaptionStyleGroup.allCases.flatMap { group in
            app.styles.filter { CaptionStyleGroup.group(for: $0) == group }.sorted { $0.order < $1.order }
        }
        guard let first = ordered.first, let last = ordered.last, ordered.count > 2 else { throw CocoaError(.coderInvalidValue) }
        let middle = ordered[ordered.count / 2]
        var results: [DebugUISuite.Result] = []
        var measurements: [Measurement] = []
        let windowsBefore = NSApp.windows.count
        let sizes: [(CGFloat, CGFloat)] = [(360, 4096), (320, 4096), (300, 4096), (560, 4096)]
        for (width, height) in sizes {
            let model = EditorModel(document: VoxClipDocument(project: fixture, demo: true), app: app, preview: DemoPreviewEngine())
            defer { model.close() }
            model.setAspect(.landscape)
            let controller = NSHostingController(rootView: RightColumnContents(model: model, columnHeight: height, columnWidth: width))
            controller.sizingOptions = []
            let host = controller.view
            host.frame = CGRect(x: 0, y: 0, width: width, height: height)
            let identifier = try await galleryID(in: host)
            defer { CaptionGalleryAudit.snapshots.removeValue(forKey: identifier) }
            for (row, style) in [("first", first), ("middle", middle), ("last", last)] {
                command(identifier, ["selectStyle": style.id])
                let receipt = await settle(host: host, identifier: identifier, style: style.id,
                    name: "\(row)-\(Int(width))", width: width, height: height)
                measurements.append(receipt)
                results.append(.init(name: "gallery \(row) selection at \(width): full ring, checkmark and name fit", passed: receipt.settled))
                results.append(.init(name: "gallery \(row) selection at \(width): selection uses the editor's real style action", passed: model.project.captions.styleId == style.id))
                let markers = DebugRightColumn.markers(in: host)
                let paint = markers["caption.tile.\(style.id)"]
                let target = markers["caption.target.\(style.id)"]
                let includesRing = paint.flatMap { envelope in target.map { abs(envelope.minY - $0.minY) <= 0.5 && abs(envelope.height - $0.height) <= 0.5 } } ?? false
                results.append(.init(name: "gallery \(row) selection at \(width): the scroll target includes the ring's real top", passed: includesRing))
            }
            command(identifier, ["chipStyle": first.id])
            let chip = await settle(host: host, identifier: identifier, style: first.id,
                name: "chip-\(Int(width))", width: width, height: height)
            measurements.append(chip)
            results.append(.init(name: "gallery chip selection at \(width) reveals its complete tile", passed: chip.settled && model.project.captions.styleId == first.id))
            command(identifier, ["beginReveal": true])
            let pending = snapshot(identifier)
            command(identifier, ["userScroll": true])
            let cancelled = snapshot(identifier)
            for _ in 0..<12 { host.layoutSubtreeIfNeeded(); await Task.yield() }
            let after = snapshot(identifier)
            results.append(.init(name: "gallery user scroll at \(width) interrupts a pending reveal", passed: pending?.pending == true && cancelled?.pending == false && cancelled?.interrupted == true))
            results.append(.init(name: "gallery user scroll at \(width) stays cancelled through layout", passed: after?.interrupted == true && after?.pending == false && after?.commands == cancelled?.commands))
        }
        results.append(.init(name: "gallery interaction audit opens no windows", passed: NSApp.windows.count == windowsBefore))
        try JSONEncoder().encode(measurements).write(to: directory.appendingPathComponent("caption-gallery-interactions.json"), options: .atomic)
        return results
    }
    static func runNative(in host: NSView, model: EditorModel, window: NSWindow, name: String, directory: URL,
                          assertSelection: @MainActor (String, String) async throws -> Void) async throws {
        let original = model.project.captions.styleId
        let ordered = CaptionStyleGroup.allCases.flatMap { group in
            model.app.styles.filter { CaptionStyleGroup.group(for: $0) == group }.sorted { $0.order < $1.order }
        }
        guard let first = ordered.first, let last = ordered.last, ordered.count > 2 else { throw CocoaError(.coderInvalidValue) }
        let middle = ordered[ordered.count / 2]
        let identifier = try await galleryID(in: host)
        var measurements: [Measurement] = []
        var results: [DebugUISuite.Result] = []
        for (row, style) in [("first", first), ("middle", middle), ("last", last), ("chip", first)] {
            if row == "chip" { try await chooseFromChip(style) }
            else { try await chooseFromGallery(style) }
            let receipt = await settle(host: host, identifier: identifier, style: style.id,
                name: row, width: host.frame.width, height: host.frame.height)
            measurements.append(receipt)
            results.append(.init(name: "\(name) \(row) selection reveals its complete paint", passed: receipt.settled))
            if receipt.settled { try await assertSelection(style.id, "\(name)-\(row)") }
        }
        command(identifier, ["beginReveal": true])
        let pending = snapshot(identifier)
        command(identifier, ["userScroll": true])
        let cancelled = snapshot(identifier)
        for _ in 0..<12 { host.layoutSubtreeIfNeeded(); await Task.yield() }
        let after = snapshot(identifier)
        results.append(.init(name: "\(name) user scroll cancels a pending reveal", passed: pending?.pending == true && cancelled?.interrupted == true && cancelled?.pending == false))
        results.append(.init(name: "\(name) cancelled reveal stays cancelled through layout", passed: after?.interrupted == true && after?.pending == false && after?.commands == cancelled?.commands))
        guard let originalStyle = model.app.styles.first(where: { $0.id == original }) else { throw CocoaError(.coderInvalidValue) }
        try await chooseFromGallery(originalStyle)
        let restored = await settle(host: host, identifier: identifier, style: original,
            name: "restore", width: host.frame.width, height: host.frame.height)
        measurements.append(restored)
        results.append(.init(name: "\(name) restores the scene selection", passed: restored.settled))
        if name == "live-editor-full" {
            results += try await shortViewport(app: model.app, window: window, directory: directory)
        }
        try JSONEncoder().encode(measurements).write(to: directory.appendingPathComponent("\(name)-gallery-interactions.json"), options: .atomic)
        try JSONEncoder().encode(results).write(to: directory.appendingPathComponent("\(name)-gallery-interaction-results.json"), options: .atomic)
        guard results.allSatisfy(\.passed) else { throw VoxClipError.exportFailed("Caption gallery reveal interactions failed in \(name).") }
    }
    private static func shortViewport(app: AppModel, window: NSWindow, directory: URL) async throws -> [DebugUISuite.Result] {
        guard let root = app.shared?.root, let content = window.contentView else { throw CocoaError(.coderInvalidValue) }
        let fixture = try DemoEditing.loadFixture(root.appendingPathComponent("fixtures/projects/five-questions.voxclip"))
        let ordered = CaptionStyleGroup.allCases.flatMap { group in
            app.styles.filter { CaptionStyleGroup.group(for: $0) == group }.sorted { $0.order < $1.order }
        }
        guard let first = ordered.first, let last = ordered.last else { throw CocoaError(.coderInvalidValue) }
        let model = EditorModel(document: VoxClipDocument(project: fixture, demo: true), app: app, preview: DemoPreviewEngine())
        defer { model.close() }
        let width: CGFloat = 360
        let height: CGFloat = 140
        let controller = NSHostingController(rootView: CaptionsSection(model: model))
        controller.sizingOptions = []
        let host = controller.view
        host.frame = CGRect(x: 0, y: 0, width: width, height: height)
        content.addSubview(host)
        defer { host.removeFromSuperview() }
        let identifier = try await galleryID(in: host)
        defer { CaptionGalleryAudit.snapshots.removeValue(forKey: identifier) }
        var measurements: [Measurement] = []
        var results: [DebugUISuite.Result] = []
        for style in [first, last] {
            command(identifier, ["chipStyle": style.id])
            let receipt = await settle(host: host, identifier: identifier, style: style.id,
                name: "short-\(style.id)", width: width, height: height, short: true)
            measurements.append(receipt)
            let before = receipt.snapshot
            for _ in 0..<24 { host.layoutSubtreeIfNeeded(); await Task.yield() }
            let after = snapshot(identifier)
            results.append(.init(name: "short gallery \(style.id) exposes the ring top at the best attainable position", passed: receipt.settled))
            results.append(.init(name: "short gallery \(style.id) stops issuing scroll commands", passed: before != nil && after?.pending == false && after?.commands == before?.commands && after?.visible == before?.visible))
        }
        try JSONEncoder().encode(measurements).write(to: directory.appendingPathComponent("caption-gallery-short.json"), options: .atomic)
        return results
    }
    private static func galleryID(in host: NSView) async throws -> String {
        let started = ProcessInfo.processInfo.systemUptime
        let prefix = "caption.gallery."
        repeat {
            host.layoutSubtreeIfNeeded()
            if let key = DebugRightColumn.markers(in: host).keys.first(where: { $0.hasPrefix(prefix) }) {
                return String(key.dropFirst(prefix.count))
            }
            await Task.yield()
        } while ProcessInfo.processInfo.systemUptime - started < 2
        throw VoxClipError.exportFailed("The hosted caption gallery did not expose its audit target.")
    }
    private static func command(_ identifier: String, _ info: [String: Any]) {
        NotificationCenter.default.post(name: CaptionGalleryAudit.notification, object: identifier, userInfo: info)
    }
    private static func chooseFromGallery(_ style: CaptionStyle) async throws {
        let label = "\(style.name): \(style.description)"
        let pressed = await Task.detached { pressAccessibility(role: kAXRadioButtonRole, label: label) }.value
        guard pressed else { throw VoxClipError.exportFailed("The native caption style choice could not be pressed.") }
    }
    private static func chooseFromChip(_ style: CaptionStyle) async throws {
        let opening = Task.detached { pressAccessibility(identifier: "voxclip.captions.styleChip") }
        let label = style.name
        let selected = await Task.detached {
            let started = ProcessInfo.processInfo.systemUptime
            repeat {
                if pressAccessibility(role: kAXMenuItemRole, label: label) { return true }
                await Task.yield()
            } while ProcessInfo.processInfo.systemUptime - started < 2
            return false
        }.value
        guard selected else { throw VoxClipError.exportFailed("The native caption chip menu did not offer the requested style.") }
        guard await opening.value else { throw VoxClipError.exportFailed("The native caption chip menu could not be opened.") }
    }
    private nonisolated static func pressAccessibility(identifier: String? = nil, role: String? = nil, label: String? = nil) -> Bool {
        func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
        }
        func find(_ element: AXUIElement, depth: Int) -> AXUIElement? {
            guard depth < 32 else { return nil }
            let matchesID = identifier.map { attribute(element, kAXIdentifierAttribute) as? String == $0 } ?? true
            let matchesRole = role.map { attribute(element, kAXRoleAttribute) as? String == $0 } ?? true
            let matchesLabel = label.map { expected in
                [kAXTitleAttribute, kAXDescriptionAttribute].contains { attribute(element, $0) as? String == expected }
            } ?? true
            if matchesID && matchesRole && matchesLabel { return element }
            let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
            for child in children { if let found = find(child, depth: depth + 1) { return found } }
            return nil
        }
        guard let target = find(AXUIElementCreateApplication(getpid()), depth: 0) else { return false }
        return AXUIElementPerformAction(target, kAXPressAction as CFString) == .success
    }
    private static func snapshot(_ identifier: String) -> CaptionGalleryAudit.Snapshot? {
        command(identifier, ["snapshot": true])
        return CaptionGalleryAudit.snapshots[identifier]
    }
    private static func settle(host: NSView, identifier: String, style: String, name: String,
                               width: CGFloat, height: CGFloat, short: Bool = false) async -> Measurement {
        let started = ProcessInfo.processInfo.systemUptime
        var current: CaptionGalleryAudit.Snapshot?
        var settled = false
        repeat {
            host.layoutSubtreeIfNeeded()
            current = snapshot(identifier)
            if let current, let paint = current.paint, current.selectedStyle == style, current.paintStyle == style, !current.pending,
               current.visible.height > 0, abs(current.visible.width - current.size.width) <= 0.5 {
                if short {
                    settled = paint.height > current.visible.height && abs(paint.minY - current.visible.minY) <= 0.5
                } else {
                    let visible = current.visible.insetBy(dx: -0.5, dy: -0.5)
                    settled = visible.contains(paint)
                    if let header = current.header, header.union(paint).height + 24 <= current.visible.height {
                        settled = settled && visible.contains(header)
                    }
                }
                if settled { break }
            }
            await Task.yield()
        } while ProcessInfo.processInfo.systemUptime - started < 2
        return Measurement(name: name, width: width, height: height, style: style, snapshot: current,
            elapsed: ProcessInfo.processInfo.systemUptime - started, settled: settled)
    }
}
#endif
