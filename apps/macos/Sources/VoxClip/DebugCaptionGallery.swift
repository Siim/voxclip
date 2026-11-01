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
        let transitions: [CaptionGalleryAudit.Snapshot]
    }
    static func run(app: AppModel, directory: URL) async throws -> [DebugUISuite.Result] {
        guard let root = app.shared?.root else { throw VoxClipError.sharedResourcesMissing }
        let fixture = try DemoEditing.loadFixture(root.appendingPathComponent("fixtures/projects/five-questions.voxclip"))
        let ordered = CaptionsSection.galleryOrder(app.styles)
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
            let controller = NSHostingController(rootView: PanelHost(model: model, shell: WorkspaceShell(app: app), width: width, height: height))
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
                results.append(selectionResult(name: "gallery \(row) selection at \(width): full ring and name fit", receipt: receipt, actualStyle: model.project.captions.styleId))
                results.append(.init(name: "gallery \(row) selection at \(width): selection uses the editor's real style action", passed: model.project.captions.styleId == style.id))
                let markers = DebugRightColumn.markers(in: host)
                // The ring marker is the outer ring's whole frame, 1 point outside the tile.
                let ring = markers["caption.ring.\(style.id)"]
                let target = markers["caption.target.\(style.id)"]
                let reserve = CaptionsPanelMetrics.ringReserve + 0.5
                let includesRing = ring.flatMap { ring in target.map { ring.minY >= $0.minY - 0.5 && ring.maxY <= $0.maxY + 0.5 && ring.minX >= $0.minX - reserve && ring.maxX <= $0.maxX + reserve } } ?? false
                results.append(.init(name: "gallery \(row) selection at \(width): the scroll target includes the ring's real top", passed: includesRing))
            }
            let undo = UndoManager(); undo.groupsByEvent = false; model.undoManager = undo
            for (row, style) in outsideRows(model, to: first.id) {
                changeOutside(row, to: style, model: model, undo: undo)
                let receipt = await settle(host: host, identifier: identifier, style: style,
                    name: "\(row)-\(Int(width))", width: width, height: height)
                measurements.append(receipt)
                results.append(selectionResult(name: "gallery \(row) style change at \(width) reveals its complete tile", receipt: receipt, actualStyle: model.project.captions.styleId))
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
        results += try await captures(app: app, fixture: fixture, directory: directory)
        results.append(.init(name: "gallery interaction audit opens no windows", passed: NSApp.windows.count == windowsBefore))
        results += try await scrollerFit(app: app, fixture: fixture)
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
        // Three columns: the next row starts at the fourth style.
        let rowGap = markers["caption.name.\(first.id)"].flatMap { name in markers["caption.image.\(ordered[CaptionsPanelMetrics.columns].id)"].map { $0.minY - name.maxY } }
        var results: [DebugUISuite.Result] = [
            .init(name: "gallery visible row gap is 6 with the ring reserve inside it (\(rowGap ?? -1))", passed: firstReceipt.settled && rowGap.map { abs($0 - CaptionsPanelMetrics.rowGap) <= 0.5 } == true)
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
            // The notice sits on the gallery's top edge; its own 12 pt padding is the gap.
            return host.bounds.insetBy(dx: -0.5, dy: -0.5).contains(error) && error.maxY <= viewport.minY + 0.5
        }
        results.append(.init(name: "automatic reveal cannot hide a caption error above the gallery", passed: errorReceipt.settled && errorVisible()))
        command(identifier, ["end": true])
        await layoutTurns(host)
        results.append(.init(name: "manual gallery scrolling also keeps the caption error visible", passed: errorVisible()))
        try JSONEncoder().encode(snapshots).write(to: directory.appendingPathComponent("caption-gallery-regressions.json"), options: .atomic)
        return results
    }
    /// The Captions job at 1280 × 800 (404 × 522) in a borderless window that is never shown,
    /// where its scroll views are laid out as on screen: the gallery's scroll view stays inside
    /// the column's padding less the ring reserve, the tiles fill the width it gives them, and
    /// the last style is revealed in it. `MacUIIntegrationTests` runs this audit again with
    /// `-AppleShowScrollBars Always`, where a legacy scroller takes its width from the tiles.
    private static func scrollerFit(app: AppModel, fixture: Project) async throws -> [DebugUISuite.Result] {
        guard let last = CaptionsSection.galleryOrder(app.styles).last else { throw CocoaError(.coderInvalidValue) }
        let row = CaptionsSection.galleryOrder(app.styles).prefix(CaptionsPanelMetrics.columns).map(\.id)
        let model = EditorModel(document: VoxClipDocument(project: fixture, demo: true), app: app, preview: DemoPreviewEngine())
        defer { model.close() }
        model.setAspect(.landscape)
        let (width, height): (CGFloat, CGFloat) = (404, 522)
        let controller = NSHostingController(rootView: PanelHost(model: model, shell: WorkspaceShell(app: app), width: width, height: height))
        controller.sizingOptions = []
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        defer { window.close() }
        let host = controller.view
        host.frame = CGRect(x: 0, y: 0, width: width, height: height)
        let identifier = try await galleryID(in: host)
        defer { CaptionGalleryAudit.snapshots.removeValue(forKey: identifier) }
        command(identifier, ["selectStyle": last.id])
        let receipt = await settle(host: host, identifier: identifier, style: last.id, name: "scroller-fit", width: width, height: height)
        let markers = DebugRightColumn.markers(in: host)
        let gallery = markers["caption.gallery.\(identifier)"]
        let scroll = DebugRightColumn.scrollViews(in: host).first { scroll in gallery.map { abs(scroll.convert(scroll.bounds, to: host).minY - $0.minY) <= 0.5 } == true }
        let frame = scroll.map { $0.convert($0.bounds, to: host) } ?? .zero
        let clip = scroll.map { $0.contentView.convert($0.contentView.bounds, to: host) } ?? .zero
        let style = scroll.map { $0.scrollerStyle == .legacy ? "legacy" : "overlay" } ?? "no"
        let reserve = CaptionsPanelMetrics.ringReserve, edge = CaptionsPanelMetrics.inset - reserve
        let inside = scroll != nil && frame.minX >= edge - 0.5 && frame.maxX <= width - edge + 0.5
        // An offscreen host lays views on whole points, so a column of tiles may be 1 off.
        let filled = markers["caption.image.\(row[0])"].map { abs($0.minX - reserve - clip.minX) <= 1 } == true
            && markers["caption.image.\(row[2])"].map { abs($0.maxX + reserve - clip.maxX) <= 1 } == true
        return [
            .init(name: "gallery at 404 with \(style) scrollers stays inside the column (\(frame)) and its tiles fill what it gives them (\(clip))", passed: inside && filled),
            .init(name: "gallery at 404 with \(style) scrollers reveals the last style", passed: receipt.settled && model.project.captions.styleId == last.id)
        ]
    }
    /// The right column on the Captions job, offscreen, at 1280 × 800 (404 × 522) to set beside
    /// f1's and at the 960 × 600 minimum (324 × 322): `v2-captions-{1280,960}-{dark,light}.png`,
    /// once every tile in view has drawn or after 3 seconds.
    private static func captures(app: AppModel, fixture: Project, directory: URL) async throws -> [DebugUISuite.Result] {
        var results: [DebugUISuite.Result] = []
        for (window, width, height, rows) in [(1280, CGFloat(404), CGFloat(522), 2), (960, 324, 322, 1)] {
        for (name, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            let model = EditorModel(document: VoxClipDocument(project: fixture, demo: true), app: app, preview: DemoPreviewEngine())
            defer { model.close() }
            model.setAspect(.landscape)
            model.setStyle("box-highlight")
            let controller = NSHostingController(rootView: PanelHost(model: model, shell: WorkspaceShell(app: app), width: width, height: height))
            controller.sizingOptions = []
            let host = controller.view
            host.frame = CGRect(x: 0, y: 0, width: width, height: height)
            host.appearance = NSAppearance(named: appearance)
            // The rows in view; each tile has drawn when its stage is no longer plain black.
            let shown = CaptionsSection.galleryOrder(app.styles).prefix(rows * CaptionsPanelMetrics.columns).map(\.id)
            let started = ProcessInfo.processInfo.systemUptime
            var drawn = 0
            repeat {
                await layoutTurns(host)
                guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { break }
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let markers = DebugRightColumn.markers(in: host)
                drawn = shown.filter { id in
                    guard let image = markers["caption.image.\(id)"] else { return false }
                    return inked(bitmap, in: image.insetBy(dx: 8, dy: 6), host: host)
                }.count
                if drawn == shown.count {
                    if let data = bitmap.representation(using: .png, properties: [:]) { try data.write(to: directory.appendingPathComponent("v2-captions-\(window)-\(name).png")) }
                    break
                }
            } while ProcessInfo.processInfo.systemUptime - started < 3
            results.append(.init(name: "v2-captions-\(window)-\(name): the tiles in view drew their phrase (\(drawn) of \(shown.count))", passed: drawn == shown.count))
        }
        }
        return results
    }
    /// Whether `rect` (host points) holds a pixel brighter than the stage in `bitmap`.
    private static func inked(_ bitmap: NSBitmapImageRep, in rect: CGRect, host: NSView) -> Bool {
        let scale = CGFloat(bitmap.pixelsWide) / max(1, host.bounds.width)
        let flipped = host.isFlipped ? rect : CGRect(x: rect.minX, y: host.bounds.height - rect.maxY, width: rect.width, height: rect.height)
        for y in stride(from: Int(flipped.minY * scale), to: Int(flipped.maxY * scale), by: 2) {
            for x in stride(from: Int(flipped.minX * scale), to: Int(flipped.maxX * scale), by: 2) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if max(color.redComponent, color.greenComponent, color.blueComponent) > 0.5 { return true }
            }
        }
        return false
    }
    private static func layoutTurns(_ host: NSView) async {
        for _ in 0..<24 { host.layoutSubtreeIfNeeded(); await Task.yield() }
    }
    static func runNative(in host: NSView, model: EditorModel, window: NSWindow, name: String, directory: URL,
                          assertSelection: @MainActor (String, String) async throws -> Void) async throws {
        let original = model.project.captions.styleId
        let ordered = CaptionsSection.galleryOrder(model.app.styles)
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
        let ordered = CaptionsSection.galleryOrder(app.styles)
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
            // Leave the gallery a 40-point viewport, shorter than any tile, so every style gets a
            // gallery to reveal into: the body is then too short for the property rows.
            host.frame.size.height = tall
            let started = ProcessInfo.processInfo.systemUptime
            var galleryTop: CGFloat?
            repeat {
                host.layoutSubtreeIfNeeded(); await Task.yield()
                galleryTop = DebugRightColumn.markers(in: host)["caption.gallery.\(identifier)"].map { host.isFlipped ? $0.minY : tall - $0.maxY }
            } while galleryTop == nil && ProcessInfo.processInfo.systemUptime - started < 2
            let height = (galleryTop ?? CaptionsPanelMetrics.top) + 40
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
    static func selectionResult(name: String, receipt: Measurement, actualStyle: String) -> DebugUISuite.Result {
        let passed = receipt.settled && actualStyle == receipt.style
        guard !passed else { return .init(name: name, passed: true) }
        let measurement = (try? JSONEncoder().encode(receipt)).flatMap { String(data: $0, encoding: .utf8) } ?? "no measurement"
        return .init(name: "\(name); expected style \(receipt.style), actual style \(actualStyle); \(measurement)", passed: false)
    }
    static func layoutTurn() async {
        await withCheckedContinuation { continuation in
            let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, false, CFIndex.max) { _, _ in
                continuation.resume()
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
    }
    private static func settle(host: NSView, identifier: String, style: String, name: String,
                               width: CGFloat, height: CGFloat, short: Bool = false) async -> Measurement {
        let started = ProcessInfo.processInfo.systemUptime
        var current: CaptionGalleryAudit.Snapshot?
        var previous: CaptionGalleryAudit.Snapshot?
        var settled = false
        var passes = 0
        var stablePasses = 0
        var previousPaint: CGRect?
        var transitions: [CaptionGalleryAudit.Snapshot] = []
        repeat {
            host.needsLayout = true
            host.layoutSubtreeIfNeeded()
            current = snapshot(identifier)
            if let current, transitions.last != current { transitions.append(current) }
            passes += 1
            var ready = false
            let markers = DebugRightColumn.markers(in: host)
            let actualPaint = markers["caption.target.\(style)"]?.insetBy(dx: -CaptionsPanelMetrics.ringReserve, dy: 0)
            // Cached frames and the model's style are right the moment a change is made, before SwiftUI
            // has delivered it; only a consumed request shows the gallery has acted on the change.
            if let current, let paint = current.paint, current.consumed, current.selectedStyle == style, current.paintStyle == style, !current.pending,
               current.visible.height > 0, abs(current.visible.width - current.size.width) <= 0.5 {
                if short {
                    ready = paint.height > current.visible.height && abs(paint.minY - current.visible.minY) <= 0.5
                } else {
                    ready = current.visible.insetBy(dx: -0.5, dy: -0.5).contains(paint)
                }
                // An unattached host has no display cycle: its measured viewport must match the gallery's real frame.
                if ready, host.window == nil {
                    ready = markers["caption.gallery.\(identifier)"].map { abs($0.height - current.size.height) <= 0.5 } ?? false
                }
                if ready, let viewport = markers["caption.gallery.\(identifier)"]?.insetBy(dx: -CaptionsPanelMetrics.ringReserve, dy: 0), let actualPaint {
                    if short {
                        ready = abs(actualPaint.minY - viewport.minY) <= 0.5
                    } else {
                        ready = viewport.insetBy(dx: -0.5, dy: -0.5).contains(actualPaint)
                    }
                } else {
                    ready = false
                }
            }
            stablePasses = ready && previous == current && previousPaint == actualPaint ? stablePasses + 1 : (ready ? 1 : 0)
            if stablePasses >= 3 { settled = true; break }
            previous = ready ? current : nil
            previousPaint = ready ? actualPaint : nil
            if !ready { await layoutTurn() }
        } while ProcessInfo.processInfo.systemUptime - started < 2
        return Measurement(name: name, width: width, height: height, style: style, snapshot: current,
            elapsed: ProcessInfo.processInfo.systemUptime - started, settled: settled, passes: passes, transitions: transitions)
    }
}
#endif
