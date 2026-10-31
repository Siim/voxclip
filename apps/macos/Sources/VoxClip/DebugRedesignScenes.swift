#if DEBUG
import AppKit
import ApplicationServices
import SwiftUI
import VoxClipCore
import VoxClipMedia

@MainActor enum DebugRedesignScenes {
    static let names = ["live-home", "live-home-empty", "live-dragover", "live-editor-full", "live-editor-clip",
                        "live-editor-1280", "live-editor-1280-blue", "live-editor-1180", "live-editor-300", "live-editor-560", "live-editor-960", "live-compact", "live-selection-bar", "live-suggested", "live-finding",
                        "live-export-clip", "live-rewrite"]
    static func checks(app: AppModel) throws -> [DebugUISuite.Result] {
        guard let root = app.shared?.root else { throw VoxClipError.sharedResourcesMissing }
        let project = try DemoEditing.loadFixture(root.appendingPathComponent("fixtures/projects/five-questions.voxclip"))
        let expected: Set<String> = ["live-home", "live-home-empty", "live-dragover", "live-editor-full", "live-editor-clip", "live-editor-1280", "live-editor-1280-blue", "live-editor-1180", "live-editor-300", "live-editor-560", "live-editor-960", "live-compact", "live-selection-bar", "live-suggested", "live-finding", "live-export-clip", "live-rewrite"]
        return [
            .init(name: "step 18 scene set contains every required name once", passed: Set(names) == expected && names.count == expected.count),
            .init(name: "Five questions has four kept clips and one suggestion", passed: project.edits.clips.filter(\.selected).count == 4 && project.edits.clips.filter { !$0.selected && $0.origin == .ai }.count == 1),
            .init(name: "Five questions has eight cuts and four source fillers", passed: project.edits.cutWordIds.count == 8 && project.transcript?.words.filter { (try? isFillerText($0.text)) == true }.count == 4)
        ]
    }
    static func capture(app: AppModel, directory: URL) async throws -> [DebugUISuite.Result] {
        guard !DebugUISuite.sessionLocked else { throw CocoaError(.userCancelled) }
        guard let root = app.shared?.root else { throw VoxClipError.sharedResourcesMissing }
        let url = root.appendingPathComponent("fixtures/projects/five-questions.voxclip")
        let project = try DemoEditing.loadFixture(url)
        let savedSettings = app.settings, savedRecent = app.recent, savedOverride = app.connectorOverride
        defer { app.settings = savedSettings; app.recent = savedRecent; app.connectorOverride = savedOverride }
        let fake = ConsentFixtureConnector(id: .ollama)
        app.connectorOverride = { _ in fake }
        app.set("llm.connector", .string("ollama")); app.set("llm.model.ollama", .string("fixture-local"))
        app.set("voiceLab.enabled", .bool(true))
        for key in [WorkspaceLayout.explorerWidthKey, WorkspaceLayout.rightWidthKey, WorkspaceLayout.timelineHeightKey] { app.settings.values.removeValue(forKey: key) }
        app.recent = [url]; app.recentProjects.refresh([url])
        let shell = WorkspaceShell(app: app)
        var results: [DebugUISuite.Result] = []
        func scene(_ name: String, size: NSSize = NSSize(width: 1440, height: 900), appearance: NSAppearance.Name = .darkAqua,
                   prepare: (@MainActor (NSWindow) async throws -> NSWindow?)? = nil) async throws {
            guard !DebugUISuite.sessionLocked else { throw CocoaError(.userCancelled) }
            shell.windowWidth = size.width
            try await DebugUISuite.snapshot(WorkspaceView(shell: shell).environment(app), name: name, size: size,
                appearance: appearance, directory: directory, active: true, mainWindow: true, native: true, beforeCapture: { window in
                    let target = try await prepare?(window) ?? window
                    if ["live-editor-full", "live-editor-1280", "live-editor-clip", "live-editor-300", "live-editor-560"].contains(name), let editor = shell.editor {
                        try await assertSelectedGallery(in: window, styleID: editor.project.captions.styleId, app: app, name: name, directory: directory)
                        if name != "live-editor-clip", let right = DebugColumnBounds.split(in: window.contentView)?.arrangedSubviews.last {
                            try await DebugCaptionGallery.runNative(in: right, model: editor, window: window, name: name, directory: directory) { style, capture in
                                try await assertSelectedGallery(in: window, styleID: style, app: app, name: capture, directory: directory)
                            }
                        }
                    }
                    return target
                })
            results.append(.init(name: "native scene \(name)", passed: true))
        }
        try await scene("live-home")
        app.recent = []
        try await scene("live-home-empty", appearance: .aqua)
        app.recent = [url]; shell.dropTargeted = true
        try await scene("live-dragover")
        shell.dropTargeted = false
        await shell.attachForTesting(VoxClipDocument(project: project, demo: true))
        guard let editor = shell.editor else { throw CocoaError(.coderInvalidValue) }
        defer { editor.close() }
        editor.mediaResolved = true; editor.refresh()
        editor.waveform = WaveformData(fine: Array(repeating: 0.01, count: 300_000))
        try await scene("live-editor-full")
        guard editor.keptClips.count == 4, let second = editor.keptClips.dropFirst().first else { throw CocoaError(.coderInvalidValue) }
        shell.selection = .clip(second.id); editor.setAspect(.portrait)
        try await scene("live-editor-clip", appearance: .aqua)
        shell.selection = .fullTake; editor.setAspect(.landscape)
        try await scene("live-editor-1280", size: NSSize(width: 1280, height: 800)) { window in
            guard let right = DebugColumnBounds.split(in: window.contentView)?.arrangedSubviews.last, abs(right.frame.width - 404) <= 1 else {
                throw VoxClipError.exportFailed("The 1280 scene must have a 404-point right column.")
            }
            try await assertSelectedGallery(in: window, styleID: editor.project.captions.styleId, app: app, name: "live-editor-1280-initial", directory: directory)
            try await auditGalleryScroll(in: right, window: window, app: app, directory: directory)
            return nil
        }
        try await scene("live-editor-1180", size: NSSize(width: 1180, height: 800))
        try await scene("live-editor-300", size: NSSize(width: 1280, height: 800)) { window in
            try await dragColumn(in: window, to: 300, shell: shell, directory: directory)
            return nil
        }
        app.settings.values.removeValue(forKey: WorkspaceLayout.rightWidthKey)
        try await scene("live-editor-560") { window in
            try await dragColumn(in: window, to: 560, shell: shell, directory: directory)
            return nil
        }
        app.settings.values.removeValue(forKey: WorkspaceLayout.rightWidthKey)
        try await scene("live-editor-960", size: NSSize(width: 960, height: 600)) { window in
            if !shell.layout.rightVisible { shell.toggleViewer() }
            await DebugConnectorRequests.wait {
                guard let split = DebugColumnBounds.split(in: window.contentView), let right = split.arrangedSubviews.last else { return false }
                return !split.isSubviewCollapsed(right)
            }
            guard shell.layout.rightVisible, !shell.layout.explorerVisible else { throw VoxClipError.exportFailed("Show Viewer at 960 must hide the sidebar.") }
            return nil
        }
        shell.windowWidth = 1440
        if Bundle.main.bundleURL.pathExtension == "app" && UserDefaults.standard.integer(forKey: "AppleAccentColor") == 4 {
            try await scene("live-editor-1280-blue", size: NSSize(width: 1280, height: 800), appearance: .aqua)
        } else {
            results.append(.init(name: "native scene live-editor-1280-blue", passed: false,
                skipped: "Owed: launch a bundled app with the blue system accent (-AppleAccentColor 4)."))
        }
        try await scene("live-compact", size: NSSize(width: 1024, height: 700))
        let selected = Array(editor.words[12...15])
        editor.selectedWordIDs = Set(selected.map(\.id))
        try await scene("live-selection-bar") { window in
            editor.window = window
            guard let text = transcript(in: window.contentView) else { throw CocoaError(.coderInvalidValue) }
            text.selectedRanges = selected.compactMap { word in text.map.span(id: word.id).map { NSValue(range: $0.range) } }
            text.showSelectionBar(focus: !EditorAccessibilityPolicy.reducedEffectsAudit)
            guard text.selectionBarVisible else { throw CocoaError(.coderInvalidValue) }
            if EditorAccessibilityPolicy.reducedEffectsAudit {
                try await reducedEffects(window: window, text: text, directory: directory)
            }
            return nil
        }
        editor.selectedWordIDs = []
        if let suggested = editor.suggestedClips.first { shell.selection = .clip(suggested.id) }
        try await scene("live-suggested")
        shell.selection = .fullTake; editor.finding = true
        try await scene("live-finding")
        editor.finding = false; shell.selection = .clip(second.id)
        try await scene("live-export-clip", appearance: .aqua) { window in
            editor.window = window
            guard !editor.mediaExportable else { throw CocoaError(.coderInvalidValue) }
            editor.exportClipIDs = [second.id]
            editor.showExport = true
            await DebugConnectorRequests.wait { window.attachedSheet != nil }
            guard let sheet = window.attachedSheet else { throw VoxClipError.exportFailed("The staged export sheet did not appear.") }
            return sheet
        }
        editor.showExport = false
        shell.selection = .fullTake
        editor.selectedWordIDs = Set(editor.words[12...15].map(\.id))
        editor.beginRewrite()
        await DebugConnectorRequests.wait { editor.rewrite != nil }
        guard let session = editor.rewrite else { throw CocoaError(.coderInvalidValue) }
        session.setInstruction("Make this clearer")
        await session.detectConnector(); await session.prepare()
        if let quote = session.quote { session.markEstimateShown(quote.id) }
        try await scene("live-rewrite")
        editor.closeRewrite(returnFocus: false)
        try ProjectJSON.encoder().encode(results).write(to: directory.appendingPathComponent("redesign-scenes.json"), options: .atomic)
        return results
    }
    private static func auditGalleryScroll(in right: NSView, window: NSWindow, app: AppModel, directory: URL) async throws {
        guard let scroll = DebugRightColumn.scrollViews(in: right).first, let document = scroll.documentView,
              let last = CaptionStyleGroup.allCases.flatMap({ group in
                  app.styles.filter { CaptionStyleGroup.group(for: $0) == group }.sorted { $0.order < $1.order }
              }).last else { throw CocoaError(.coderInvalidValue) }
        defer { try? galleryCommand(in: right, end: false) }
        var lastFrame: CGRect?
        let started = ProcessInfo.processInfo.systemUptime
        let originalDocument = document.bounds
        repeat {
            try galleryCommand(in: right, end: true)
            await Task.yield()
            right.layoutSubtreeIfNeeded()
            lastFrame = DebugRightColumn.markers(in: right)["caption.name.\(last.id)"]
            let viewport = scroll.convert(scroll.bounds, to: right)
            if let lastFrame {
                let inside = viewport.insetBy(dx: -0.5, dy: -0.5).contains(lastFrame)
                let clearsFade: Bool
                if right.isFlipped { clearsFade = lastFrame.maxY <= viewport.maxY - 23.5 }
                else { clearsFade = lastFrame.minY >= viewport.minY + 23.5 }
                if inside && clearsFade { break }
            }
        } while ProcessInfo.processInfo.systemUptime - started < 2
        let viewport = scroll.convert(scroll.bounds, to: right)
        struct ScrollEvidence: Encodable { let style: String; let viewport: CGRect; let lastName: CGRect?; let document: CGRect; let content: CGRect; let insets: [CGFloat]; let originalDocument: CGRect; let elapsed: Double }
        let insets = scroll.contentInsets
        try JSONEncoder().encode(ScrollEvidence(style: last.id, viewport: viewport, lastName: lastFrame, document: document.bounds,
            content: scroll.contentView.bounds, insets: [insets.top, insets.left, insets.bottom, insets.right], originalDocument: originalDocument,
            elapsed: ProcessInfo.processInfo.systemUptime - started))
            .write(to: directory.appendingPathComponent("gallery-scroll.json"), options: .atomic)
        let clearsFade = lastFrame.map { right.isFlipped ? $0.maxY <= viewport.maxY - 23.5 : $0.minY >= viewport.minY + 23.5 } ?? false
        guard let lastFrame, viewport.insetBy(dx: -0.5, dy: -0.5).contains(lastFrame), clearsFade else {
            throw VoxClipError.exportFailed("The final caption style must scroll fully into view above the gallery fade.")
        }
        try DebugColumnBounds.assertBounds(window: window, name: "live-editor-1280-scrolled", directory: directory)
        let bounds = try JSONDecoder().decode(DebugColumnBounds.Evidence.self,
            from: Data(contentsOf: directory.appendingPathComponent("live-editor-1280-scrolled-bounds.json")))
        let labels = Set(bounds.elements.filter { $0.role == kAXRadioButtonRole }.map(\.label))
        guard app.styles.allSatisfy({ labels.contains("\($0.name): \($0.description)") }) else {
            throw VoxClipError.exportFailed("Every caption style must remain available to accessibility while scrolled.")
        }
    }
    private static func galleryCommand(in right: NSView, end: Bool) throws {
        let prefix = "caption.gallery."
        guard let key = DebugRightColumn.markers(in: right).keys.first(where: { $0.hasPrefix(prefix) }) else { throw CocoaError(.coderInvalidValue) }
        let identifier = String(key.dropFirst(prefix.count))
        NotificationCenter.default.post(name: CaptionGalleryAudit.notification, object: identifier, userInfo: ["end": end])
    }
    private static func assertSelectedGallery(in window: NSWindow, styleID: String, app: AppModel, name: String, directory: URL) async throws {
        guard let right = DebugColumnBounds.split(in: window.contentView)?.arrangedSubviews.last,
              let style = app.styles.first(where: { $0.id == styleID }) else { throw CocoaError(.coderInvalidValue) }
        let started = ProcessInfo.processInfo.systemUptime
        var paint: CGRect?, viewport: CGRect?, header: CGRect?, ring: CGRect?, choice: DebugColumnBounds.Element?
        var initialPaint: CGRect?, initialViewport: CGRect?
        var visible = false
        repeat {
            window.contentView?.layoutSubtreeIfNeeded()
            let markers = DebugRightColumn.markers(in: right)
            if let local = markers["caption.tile.\(styleID)"], let scroll = DebugRightColumn.scrollViews(in: right).first {
                let screen = window.convertToScreen(right.convert(local, to: nil))
                let top = NSScreen.screens.first?.frame.maxY ?? 0
                paint = CGRect(x: screen.minX, y: top - screen.maxY, width: screen.width, height: screen.height)
                viewport = DebugColumnBounds.screenFrame(scroll, window: window)
                if initialPaint == nil { initialPaint = paint; initialViewport = viewport }
                // The ring marker is the stroke's path, outset 2 points; a 2-point stroke paints 1 more.
                if let localRing = markers["caption.ring.\(styleID)"] {
                    let screenRing = window.convertToScreen(right.convert(localRing, to: nil))
                    ring = CGRect(x: screenRing.minX - 1, y: top - screenRing.maxY - 1, width: screenRing.width + 2, height: screenRing.height + 2)
                }
                if let localHeader = markers["caption.group.\(CaptionStyleGroup.group(for: style).rawValue)"] {
                    let screenHeader = window.convertToScreen(right.convert(localHeader, to: nil))
                    header = CGRect(x: screenHeader.minX, y: top - screenHeader.maxY, width: screenHeader.width, height: screenHeader.height)
                }
            }
            choice = DebugColumnBounds.galleryChoice(in: window, label: "\(style.name): \(style.description)")
            if let paint, let viewport, let choice {
                visible = viewport.insetBy(dx: -0.5, dy: -0.5).contains(paint) && choice.selected
                    && ring.map { viewport.insetBy(dx: -0.5, dy: -0.5).contains($0) } == true
                if let header, header.union(paint).height + 24 <= viewport.height {
                    visible = visible && viewport.insetBy(dx: -0.5, dy: -0.5).contains(header)
                }
            }
            if visible { break }
            await Task.yield()
        } while ProcessInfo.processInfo.systemUptime - started < 2
        struct SelectionEvidence: Encodable {
            let style: String; let visible: Bool; let paint: CGRect?; let viewport: CGRect?; let ring: CGRect?; let choice: DebugColumnBounds.Element?
            let initialPaint: CGRect?; let initialViewport: CGRect?; let header: CGRect?; let elapsed: Double
            let swiftUI: CaptionGalleryAudit.Snapshot?
        }
        let prefix = "caption.gallery."
        let key = DebugRightColumn.markers(in: right).keys.first { $0.hasPrefix(prefix) }
        let identifier = key.map { String($0.dropFirst(prefix.count)) }
        if let identifier { NotificationCenter.default.post(name: CaptionGalleryAudit.notification, object: identifier, userInfo: ["snapshot": true]) }
        let snapshot = identifier.flatMap { CaptionGalleryAudit.snapshots[$0] }
        try JSONEncoder().encode(SelectionEvidence(style: styleID, visible: visible, paint: paint, viewport: viewport, ring: ring, choice: choice,
            initialPaint: initialPaint, initialViewport: initialViewport, header: header, elapsed: ProcessInfo.processInfo.systemUptime - started, swiftUI: snapshot))
            .write(to: directory.appendingPathComponent("\(name)-selected-gallery.json"), options: .atomic)
        guard visible else { throw VoxClipError.exportFailed("The selected caption tile, ring and checkmark must fit the gallery, and its AX choice must be selected, in \(name).") }
    }
    private static func dragColumn(in window: NSWindow, to width: CGFloat, shell: WorkspaceShell, directory: URL) async throws {
        guard let split = DebugColumnBounds.split(in: window.contentView), split.arrangedSubviews.count == 2 else { throw CocoaError(.coderInvalidValue) }
        let dividerX = split.arrangedSubviews[0].frame.maxX + split.dividerThickness / 2
        let targetX = split.bounds.width - width - split.dividerThickness / 2
        let start = split.convert(NSPoint(x: dividerX, y: split.bounds.midY), to: nil)
        let end = split.convert(NSPoint(x: targetX, y: split.bounds.midY), to: nil)
        func event(_ type: NSEvent.EventType, point: NSPoint) throws -> NSEvent {
            guard let value = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) else { throw CocoaError(.coderInvalidValue) }
            return value
        }
        let down = try event(.leftMouseDown, point: start)
        let dragged = try event(.leftMouseDragged, point: end)
        let up = try event(.leftMouseUp, point: end)
        let mouseDowns = (split as? ShellSplitView)?.dividerMouseDowns ?? 0
        NSApp.postEvent(dragged, atStart: false)
        NSApp.postEvent(up, atStart: false)
        split.mouseDown(with: down)
        try await settleColumn(in: window, name: "drag-\(Int(width))", directory: directory)
        let delivered = ((split as? ShellSplitView)?.dividerMouseDowns ?? 0) - mouseDowns
        struct DragEvidence: Encodable { let requested: CGFloat; let actual: CGFloat; let remembered: Double; let mouseDowns: Int }
        try JSONEncoder().encode(DragEvidence(requested: width, actual: split.arrangedSubviews[1].frame.width, remembered: shell.rightWidth, mouseDowns: delivered))
            .write(to: directory.appendingPathComponent("divider-drag-\(Int(width)).json"), options: .atomic)
        guard delivered == 1, abs(split.arrangedSubviews[1].frame.width - width) <= 1, abs(shell.rightWidth - width) <= 1 else {
            throw VoxClipError.exportFailed("Divider drag requested \(width), laid out \(split.arrangedSubviews[1].frame.width), remembered \(shell.rightWidth), mouseDowns \(delivered).")
        }
        let originalSize = window.contentView?.bounds.size ?? window.frame.size
        for extra: CGFloat in [64, 0] {
            window.setContentSize(NSSize(width: originalSize.width + extra, height: originalSize.height))
            try await settleColumn(in: window, name: "drag-\(Int(width))-resize-\(Int(extra))", directory: directory)
            guard abs(split.arrangedSubviews[1].frame.width - width) <= 1, abs(shell.rightWidth - width) <= 1 else {
                throw VoxClipError.exportFailed("A window resize changed the dragged right-column width.")
            }
        }
    }
    private static func settleColumn(in window: NSWindow, name: String, directory: URL) async throws {
        guard let right = DebugColumnBounds.split(in: window.contentView)?.arrangedSubviews.last else { throw CocoaError(.coderInvalidValue) }
        let started = ProcessInfo.processInfo.systemUptime
        var stage: CGRect?, root: CGRect?, column: CGRect?
        var settled = false
        repeat {
            window.contentView?.layoutSubtreeIfNeeded()
            stage = DebugRightColumn.markers(in: right)["viewer.stage"]
            root = DebugColumnBounds.rightFrame(in: window)
            column = DebugColumnBounds.columnFrame(in: window)
            if let stage, let root, let column {
                settled = abs(stage.width - (column.width - 32)) <= 0.5 && abs(root.minX - column.minX) <= 0.5 && abs(root.width - column.width) <= 0.5
            }
            if settled { break }
            await Task.yield()
        } while ProcessInfo.processInfo.systemUptime - started < 2
        struct Settlement: Encodable {
            let elapsed: Double; let settled: Bool; let stage: CGRect?; let root: CGRect?; let column: CGRect?; let liveResize: Bool
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        try JSONEncoder().encode(Settlement(elapsed: elapsed, settled: settled, stage: stage, root: root, column: column, liveResize: right.inLiveResize))
            .write(to: directory.appendingPathComponent("\(name)-settlement.json"), options: .atomic)
        guard settled else { throw VoxClipError.exportFailed("The right-column layout did not settle after \(name) within two seconds.") }
    }
    private static func transcript(in view: NSView?) -> TranscriptNSTextView? {
        guard let view else { return nil }
        if let text = view as? TranscriptNSTextView { return text }
        return view.subviews.lazy.compactMap { transcript(in: $0) }.first
    }
    private struct ReducedEffectsResult: Encodable {
        let reduceMotion: Bool
        let reduceTransparency: Bool
        let opaqueBackgroundPixels: Int
        let differingPixels: Int
        let frameIntervalSeconds: Double
        let width: Int
        let height: Int
        let appearance: String
        let expectedBackgroundRGB: [Double]
        let sampledBackgroundRGB: [Double]
        let immediateAlpha: Double
    }
    private static func reducedEffects(window: NSWindow, text: TranscriptNSTextView, directory: URL) async throws {
        guard let bar = text.selectionBarAuditView else { throw CocoaError(.coderInvalidValue) }
        let immediateAlpha: Double = bar.alphaValue
        guard immediateAlpha == 1, EditorAccessibilityPolicy.system.crossfadeDuration == 0 else {
            throw VoxClipError.exportFailed("Reduced-effects bar animated immediately after selection.")
        }
        await Task.yield()
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let barRect = bar.convert(bar.bounds, to: nil)
        let first = try nativeBar(window: window, rect: barRect, name: "reduced-effects-before", directory: directory)
        let firstTime = Date()
        try await Task.sleep(for: .milliseconds(200))
        let second = try nativeBar(window: window, rect: barRect, name: "reduced-effects-after", directory: directory)
        let interval = Date().timeIntervalSince(firstTime)
        let firstPixels = try pixels(first), secondPixels = try pixels(second)
        guard first.width == second.width, first.height == second.height else { throw CocoaError(.coderInvalidValue) }
        var differing = 0
        for offset in stride(from: 0, to: firstPixels.count, by: 4) {
            if firstPixels[offset..<offset + 4] != secondPixels[offset..<offset + 4] { differing += 1 }
        }
        let scale: CGFloat = CGFloat(second.height) / bar.bounds.height
        let backgroundInset: CGFloat = 4
        let scaledRow: CGFloat = backgroundInset * scale
        let sampleRow = Int(scaledRow)
        var opaque = 0
        var sampledRGB: [Double] = []
        let mode = bar.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? "dark" : "light"
        guard let colors = DesignValues.value("color.bg.elevated") as? [String: String], let hex = colors[mode],
              let expected = DesignValues.parse(hex).usingColorSpace(.sRGB) else { throw CocoaError(.coderInvalidValue) }
        let expectedRGB: [Double] = [expected.redComponent, expected.greenComponent, expected.blueComponent]
        let byteMaximum: Double = 255
        for column in (second.width / 3)..<(second.width * 2 / 3) {
            let offset = (sampleRow * second.width + column) * 4
            let rawChannels: [Double] = secondPixels[offset..<offset + 3].map { Double($0) }
            let actual: [Double] = rawChannels.map { $0 / byteMaximum }
            if sampledRGB.isEmpty { sampledRGB = actual }
            let error = max(abs(actual[0] - expected.redComponent),
                max(abs(actual[1] - expected.greenComponent), abs(actual[2] - expected.blueComponent)))
            if error <= 0.025 { opaque += 1 }
        }
        let policy = EditorAccessibilityPolicy.system
        let result = ReducedEffectsResult(reduceMotion: policy.reduceMotion, reduceTransparency: policy.reduceTransparency,
            opaqueBackgroundPixels: opaque, differingPixels: differing, frameIntervalSeconds: interval,
            width: first.width, height: first.height, appearance: bar.effectiveAppearance.name.rawValue,
            expectedBackgroundRGB: expectedRGB, sampledBackgroundRGB: sampledRGB, immediateAlpha: immediateAlpha)
        try ProjectJSON.encoder().encode(result).write(to: directory.appendingPathComponent("reduced-effects.json"), options: .atomic)
        guard policy.reduceMotion, policy.reduceTransparency, bar.alphaValue == 1, opaque >= 10, differing == 0 else {
            throw VoxClipError.exportFailed("Reduced-effects native pixels failed; see reduced-effects.json.")
        }
    }
    private static func nativeBar(window: NSWindow, rect: CGRect, name: String, directory: URL) throws -> CGImage {
        let url = directory.appendingPathComponent(name).appendingPathExtension("png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(window.windowNumber), url.path]
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0,
              let image = NSBitmapImageRep(data: try Data(contentsOf: url))?.cgImage else { throw CocoaError(.fileReadCorruptFile) }
        let scale = CGFloat(image.width) / window.frame.width
        let top = window.frame.height - rect.maxY
        let crop = CGRect(x: rect.minX * scale, y: top * scale, width: rect.width * scale, height: rect.height * scale).integral
        guard let cropped = image.cropping(to: crop),
              let png = NSBitmapImageRep(cgImage: cropped).representation(using: .png, properties: [:]) else { throw CocoaError(.fileReadCorruptFile) }
        try png.write(to: url, options: .atomic)
        return cropped
    }
    private static func pixels(_ image: CGImage) throws -> [UInt8] {
        let rowBytes = image.width * 4
        var bytes = [UInt8](repeating: 0, count: rowBytes * image.height)
        let rendered = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: rowBytes, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard rendered else { throw CocoaError(.fileReadCorruptFile) }
        return bytes
    }
}
#endif
