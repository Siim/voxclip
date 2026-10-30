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
        let passes: Int
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
                // The ring marker is the stroke's path, outset 2 points; a 2-point stroke paints 1 more.
                let ring = markers["caption.ring.\(style.id)"]?.insetBy(dx: -1, dy: -1)
                let target = markers["caption.target.\(style.id)"]
                let includesRing = ring.flatMap { ring in target.map { ring.minY >= $0.minY - 0.5 && ring.maxY <= $0.maxY + 0.5 && ring.minX >= $0.minX - 3.5 && ring.maxX <= $0.maxX + 3.5 } } ?? false
                results.append(.init(name: "gallery \(row) selection at \(width): the scroll target includes the ring's real top", passed: includesRing))
            }
            let undo = UndoManager(); undo.groupsByEvent = false; model.undoManager = undo
            for (row, style) in outsideRows(model, to: first.id) {
                changeOutside(row, to: style, model: model, undo: undo)
                let receipt = await settle(host: host, identifier: identifier, style: style,
                    name: "\(row)-\(Int(width))", width: width, height: height)
                measurements.append(receipt)
                results.append(.init(name: "gallery \(row) style change at \(width) reveals its complete tile", passed: receipt.settled && model.project.captions.styleId == style))
            }
            command(identifier, ["beginReveal": true])
            let pending = snapshot(identifier)
            command(identifier, ["userScroll": true])
            let cancelled = snapshot(identifier)
            for _ in 0..<12 { host.layoutSubtreeIfNeeded(); await Task.yield() }
            let after = snapshot(identifier)
            // Hosted CI keeps no evidence, so the names carry the snapshot values.
            func state(_ snapshot: CaptionGalleryAudit.Snapshot?) -> String {
                snapshot.map { "pending \($0.pending), interrupted \($0.interrupted), commands \($0.commands), consumed \($0.consumed), request \($0.requestStyle ?? "none") at \($0.requestHeight ?? -1), size \($0.size.width)x\($0.size.height), visible y \($0.visible.minY)" } ?? "no snapshot"
            }
            results.append(.init(name: "gallery user scroll at \(width) interrupts a pending reveal (\(state(pending)); then \(state(cancelled)))", passed: pending?.pending == true && cancelled?.pending == false && cancelled?.interrupted == true))
            results.append(.init(name: "gallery user scroll at \(width) stays cancelled through layout (\(state(cancelled)); then \(state(after)))", passed: after?.interrupted == true && after?.pending == false && after?.commands == cancelled?.commands))
        }
        results += DebugCaptionsSection.revealPolicyChecks()
        results += try await regressionChecks(app: app, fixture: fixture, ordered: ordered, directory: directory)
        results.append(.init(name: "gallery interaction audit opens no windows", passed: NSApp.windows.count == windowsBefore))
        try JSONEncoder().encode(measurements).write(to: directory.appendingPathComponent("caption-gallery-interactions.json"), options: .atomic)
        return results
    }
    private static func regressionChecks(app: AppModel, fixture: Project, ordered: [CaptionStyle], directory: URL) async throws -> [DebugUISuite.Result] {
        guard ordered.count >= 4, let first = ordered.first, let last = ordered.last, let clip = fixture.edits.clips.first else { throw CocoaError(.coderInvalidValue) }
        let model = EditorModel(document: VoxClipDocument(project: fixture, demo: true), app: app, preview: DemoPreviewEngine())
        defer { model.close() }
        model.activate(nil)
        model.setStyle(first.id)
        let controller = NSHostingController(rootView: CaptionsSection(model: model))
        controller.sizingOptions = []
        let host = controller.view
        host.frame = CGRect(x: 0, y: 0, width: 360, height: 4096)
        let identifier = try await galleryID(in: host)
        defer { CaptionGalleryAudit.snapshots.removeValue(forKey: identifier) }
        _ = await settle(host: host, identifier: identifier, style: first.id, name: "regression-materialize", width: 360, height: 4096)
        let firstReceipt = await settle(host: host, identifier: identifier, style: first.id, name: "regression-first", width: 360, height: 4096)
        let markers = DebugRightColumn.markers(in: host)
        let rowGap = markers["caption.name.\(first.id)"].flatMap { name in markers["caption.image.\(ordered[2].id)"].map { $0.minY - name.maxY } }
        var results: [DebugUISuite.Result] = [
            .init(name: "gallery visible row gap excludes the 3-point ring reserve (\(rowGap ?? -1))", passed: firstReceipt.settled && rowGap.map { abs($0 - 10) <= 0.5 } == true)
        ]
        model.setStyle(last.id)
        let lastReceipt = await settle(host: host, identifier: identifier, style: last.id, name: "regression-last", width: 360, height: 4096)
        let beforeRaw = snapshot(identifier)
        var snapshots: [String: CaptionGalleryAudit.Snapshot] = [:]
        snapshots["before-raw"] = beforeRaw
        func targets(in view: NSView) -> [CaptionGalleryTarget] {
            let own = (view as? ColumnLayoutMarker)?.scrollTarget.map { [$0] } ?? []
            return own + view.subviews.flatMap { targets(in: $0) }
        }
        let registered = Set(targets(in: host))
        results.append(.init(name: "every real gallery tile registers its typed scroll target, not a Picker style ID", passed:
            lastReceipt.settled && ordered.allSatisfy { registered.contains(.tile($0.id)) }))
        let clicked = ordered[1].id
        let beforeClick = snapshot(identifier)
        command(identifier, ["clickStyle": clicked])
        await layoutTurns(host)
        let afterClick = snapshot(identifier)
        snapshots["after-click"] = afterClick
        results.append(.init(name: "visible tile clicks select without issuing or resuming a reveal", passed:
            model.project.captions.styleId == clicked && afterClick?.consumed == true && afterClick?.pending == false
                && afterClick?.interrupted == true && afterClick?.commands == beforeClick?.commands && afterClick?.visible.origin == beforeClick?.visible.origin))
        command(identifier, ["fineTune": true])
        await layoutTurns(host)
        model.activate(clip)
        let scopeReceipt = await settle(host: host, identifier: identifier, style: clicked, name: "expanded-scope", width: 360, height: 4096)
        snapshots["scope"] = scopeReceipt.snapshot
        results.append(.init(name: "scope change with Fine Tune open reveals the selected tile without collapsing it", passed:
            scopeReceipt.settled && scopeReceipt.snapshot?.fineTune == true && model.activeClip?.id == clip.id))
        await model.waitForPendingPreviewForAudit()
        model.captionError = "These caption settings could not be applied. Your media and edits are safe."
        let errorReceipt = await settle(host: host, identifier: identifier, style: clicked, name: "caption-error", width: 360, height: 4096)
        snapshots["error"] = errorReceipt.snapshot
        func errorVisible() -> Bool {
            guard let error = DebugRightColumn.markers(in: host)["caption.error"], let scroll = DebugRightColumn.scrollViews(in: host).first else { return false }
            let viewport = scroll.convert(scroll.bounds, to: host)
            return host.bounds.insetBy(dx: -0.5, dy: -0.5).contains(error) && error.maxY <= viewport.minY - 11.5
        }
        results.append(.init(name: "automatic reveal cannot hide a caption error above the gallery", passed: errorReceipt.settled && errorVisible()))
        command(identifier, ["end": true])
        await layoutTurns(host)
        results.append(.init(name: "manual gallery scrolling also keeps the caption error visible", passed: errorVisible()))
        try JSONEncoder().encode(snapshots).write(to: directory.appendingPathComponent("caption-gallery-regressions.json"), options: .atomic)
        return results
    }
    private static func layoutTurns(_ host: NSView) async {
        for _ in 0..<24 { host.layoutSubtreeIfNeeded(); await Task.yield() }
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
        for (row, style) in [("first", first), ("middle", middle), ("last", last)] {
            try chooseFromGallery(style)
            let receipt = await settle(host: host, identifier: identifier, style: style.id,
                name: row, width: host.frame.width, height: host.frame.height)
            measurements.append(receipt)
            results.append(.init(name: "\(name) \(row) selection reveals its complete paint", passed: receipt.settled))
            if receipt.settled { try await assertSelection(style.id, "\(name)-\(row)") }
        }
        let documentUndo = model.undoManager
        let undo = UndoManager(); undo.groupsByEvent = false; model.undoManager = undo
        for (row, style) in outsideRows(model, to: first.id) {
            changeOutside(row, to: style, model: model, undo: undo)
            let receipt = await settle(host: host, identifier: identifier, style: style,
                name: row, width: host.frame.width, height: host.frame.height)
            measurements.append(receipt)
            results.append(.init(name: "\(name) \(row) style change reveals its complete paint", passed: receipt.settled))
            if receipt.settled { try await assertSelection(style, "\(name)-\(row)") }
        }
        model.undoManager = documentUndo
        command(identifier, ["beginReveal": true])
        let pending = snapshot(identifier)
        command(identifier, ["userScroll": true])
        let cancelled = snapshot(identifier)
        for _ in 0..<12 { host.layoutSubtreeIfNeeded(); await Task.yield() }
        let after = snapshot(identifier)
        results.append(.init(name: "\(name) user scroll cancels a pending reveal", passed: pending?.pending == true && cancelled?.interrupted == true && cancelled?.pending == false))
        results.append(.init(name: "\(name) cancelled reveal stays cancelled through layout", passed: after?.interrupted == true && after?.pending == false && after?.commands == cancelled?.commands))
        guard let originalStyle = model.app.styles.first(where: { $0.id == original }) else { throw CocoaError(.coderInvalidValue) }
        try chooseFromGallery(originalStyle)
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
        let tall: CGFloat = 600
        let controller = NSHostingController(rootView: CaptionsSection(model: model))
        controller.sizingOptions = []
        let host = controller.view
        host.frame = CGRect(x: 0, y: 0, width: width, height: tall)
        content.addSubview(host)
        defer { host.removeFromSuperview() }
        let identifier = try await galleryID(in: host)
        defer { CaptionGalleryAudit.snapshots.removeValue(forKey: identifier) }
        var measurements: [Measurement] = []
        var results: [DebugUISuite.Result] = []
        for style in [first, last] {
            model.setStyle(style.id)
            // The chrome above the gallery depends on the style: a longer summary takes the
            // two-row header. Measure it in a tall host, then leave a 40-point viewport, shorter
            // than any tile, so every style gets a gallery to reveal into.
            host.frame.size.height = tall
            let started = ProcessInfo.processInfo.systemUptime
            var viewport: CGFloat = 0
            repeat {
                host.layoutSubtreeIfNeeded(); await Task.yield()
                viewport = snapshot(identifier)?.size.height ?? 0
            } while viewport <= 0 && ProcessInfo.processInfo.systemUptime - started < 2
            let height = tall - viewport + 40
            host.frame.size.height = height
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
    /// Style changes that start outside the gallery, which must still reveal the selected tile: the
    /// editor's own undoable action, then Undo of it. Each row names the style it leaves selected.
    private static func outsideRows(_ model: EditorModel, to style: String) -> [(String, String)] {
        [("external", style), ("undo", model.project.captions.styleId)]
    }
    private static func changeOutside(_ row: String, to style: String, model: EditorModel, undo: UndoManager) {
        if row == "undo" { undo.undo() } else { undo.beginUndoGrouping(); model.setStyle(style); undo.endUndoGrouping() }
    }
    /// Presses a gallery choice through the app's own accessibility tree. In-process AX calls are
    /// answered synchronously by SwiftUI, which syncs with the main thread: from any other thread
    /// they deadlock, so this stays on the main actor.
    private static func chooseFromGallery(_ style: CaptionStyle) throws {
        guard pressAccessibility(role: kAXRadioButtonRole, label: "\(style.name): \(style.description)") else {
            throw VoxClipError.exportFailed("The native caption style choice could not be pressed.")
        }
    }
    private static func pressAccessibility(role: String, label: String) -> Bool {
        func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
        }
        func find(_ element: AXUIElement, depth: Int) -> AXUIElement? {
            guard depth < 32 else { return nil }
            if attribute(element, kAXRoleAttribute) as? String == role,
               [kAXTitleAttribute, kAXDescriptionAttribute].contains(where: { attribute(element, $0) as? String == label }) { return element }
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
        var previous: CaptionGalleryAudit.Snapshot?
        var settled = false
        var passes = 0
        repeat {
            host.layoutSubtreeIfNeeded()
            current = snapshot(identifier)
            passes += 1
            var ready = false
            // Cached frames and the model's style are right the moment a change is made, before SwiftUI
            // has delivered it; only a consumed request shows the gallery has acted on the change.
            if let current, let paint = current.paint, current.consumed, current.selectedStyle == style, current.paintStyle == style, !current.pending,
               current.visible.height > 0, abs(current.visible.width - current.size.width) <= 0.5 {
                if short {
                    ready = paint.height > current.visible.height && abs(paint.minY - current.visible.minY) <= 0.5
                } else {
                    let visible = current.visible.insetBy(dx: -0.5, dy: -0.5)
                    ready = visible.contains(paint)
                    if let header = current.header, header.union(paint).height + 24 <= current.visible.height {
                        ready = ready && visible.contains(header)
                    }
                }
                // An unattached host has no display cycle: its measured viewport must match the gallery's real frame.
                if ready, host.window == nil {
                    ready = DebugRightColumn.markers(in: host)["caption.gallery.\(identifier)"].map { abs($0.height - current.size.height) <= 0.5 } ?? false
                }
            }
            // Settled once the state holds across a turn, so nothing owed is still on its way.
            if ready, let previous, previous == current { settled = true; break }
            previous = ready ? current : nil
            await Task.yield()
        } while ProcessInfo.processInfo.systemUptime - started < 2
        return Measurement(name: name, width: width, height: height, style: style, snapshot: current,
            elapsed: ProcessInfo.processInfo.systemUptime - started, settled: settled, passes: passes)
    }
}
#endif
