import SwiftUI
#if DEBUG
import AppKit
import VoxClipCore
import VoxClipMedia

/// The right column under its title row (impl-plan V4): `PanelHost` at the v2 widths and
/// heights, without a window. The viewer is the column's width and 16:9 of it high, the
/// panel header 30 below it, and nothing runs past the column.
@MainActor enum DebugRightColumn {
    struct Measurement: Encodable {
        let variant: String
        let width: CGFloat
        let minimumWidth: CGFloat
        let proposedWidth: CGFloat
        let box: CGRect
        let stage: CGRect
        let header: CGRect
        let markers: [String: CGRect]
        /// The switcher's jobs, in order.
        let jobs: [String]
        let accessibilityElements: Int
        let viewOverflow: [String]
        let accessibilityOverflow: [String]
    }
    struct HeightMeasurement: Encodable {
        let window: String
        let variant: String
        let width: CGFloat
        let height: CGFloat
        let box: CGRect
        let stage: CGRect
        let header: CGRect
        let scrollFrames: [CGRect]
        let scrollClipping: [Bool]
        let scrolledViews: [String]
        let viewOverflow: [String]
    }
    struct ResizeMeasurement: Encodable {
        let width: CGFloat
        let box: CGRect
        let elapsed: Double
        let settled: Bool
        let viewOverflow: [String]
    }
    /// The column's frame width ÷ height for `variant`.
    private static func ratio(_ variant: String, fixture: Project) -> Double {
        switch variant {
        case "9:16": return 9.0 / 16
        case "1:1": return 1
        case "16:9": return 16.0 / 9
        default:
            let source = fixture.media.source.video.map(OutputSizing.orientedSize) ?? PixelSize(width: 16, height: 9)
            return Double(source.width) / Double(max(1, source.height))
        }
    }
    /// A Rewrite session on the fixture's words 12–25, as the Rewrite variants show it.
    private static func openRewrite(_ variant: String, in model: EditorModel) throws {
        model.mediaResolved = true
        let envelope = AudioEnvelope(sampleRate: 48_000, levels: Array(repeating: 0.01, count: 10_000))
        let connector = RewriteConnector(connector: RewriteFixtureConnector(), model: "fixture-local", name: "Fixture", group: "local", plan: "")
        let session = RewriteSession(editor: model, range: 12...25, envelope: envelope, connector: connector)
        model.rewrite = session; model.rewriteRange = 12...25
        session.edit(variant == "rewrite-budget" ? Array(repeating: "replacement", count: 180).joined(separator: " ") : "A clearer way to explain what happened in this passage.")
        if variant.hasPrefix("rewrite-takes-") { try DebugRewriteGeneration.install(String(variant.dropFirst(14)), in: session) }
    }
    private static func measureResizes(app: AppModel, fixture: Project, directory: URL) async throws -> [DebugUISuite.Result] {
        let model = EditorModel(document: VoxClipDocument(project: fixture, demo: true), app: app, preview: DemoPreviewEngine())
        defer { model.close() }
        model.setAspect(.landscape)
        let shell = WorkspaceShell(app: app)
        let controller = NSHostingController(rootView: GeometryReader { geometry in
            PanelHost(model: model, shell: shell, width: geometry.size.width, height: geometry.size.height)
        })
        controller.sizingOptions = []
        let host = controller.view
        var measurements: [ResizeMeasurement] = []
        for width: CGFloat in [320, 300, 560] {
            host.frame = CGRect(x: 0, y: 0, width: width, height: 675)
            let started = ProcessInfo.processInfo.systemUptime
            var box = CGRect.zero
            var settled = false
            repeat {
                host.layoutSubtreeIfNeeded()
                box = markers(in: host)["viewer.box"] ?? .zero
                settled = abs(box.width - width) <= 0.5 && abs(box.minX) <= 0.5 && abs(box.height - ViewerSection.boxHeight(forWidth: width)) <= 0.5
                if settled { break }
                await Task.yield()
            } while ProcessInfo.processInfo.systemUptime - started < 2
            measurements.append(ResizeMeasurement(width: width, box: box, elapsed: ProcessInfo.processInfo.systemUptime - started,
                settled: settled, viewOverflow: viewOverflow(host)))
        }
        try JSONEncoder().encode(measurements).write(to: directory.appendingPathComponent("right-column-resizes.json"), options: .atomic)
        return measurements.flatMap { measurement in [
            .init(name: "resized column \(measurement.width): the viewer follows at the column's width and 16:9 of it", passed: measurement.settled),
            .init(name: "resized column \(measurement.width): visible descendants fit", passed: measurement.viewOverflow.isEmpty)
        ] }
    }
    /// The least scroll height the panel's job keeps in every state at every size: one 24 pt
    /// row, so its gallery or its fields can still be scrolled into view. Captions and a
    /// resting Rewrite keep 54 or more; Rewrite's provider error, whose notice sits in its
    /// fixed footer, keeps 30 at 960 × 600 and 35 at 1280 × 700 (V15 replaces that footer).
    static let minimumViewport: CGFloat = 24
    /// The column under the title row at the v2 widths (impl-plan item 18) and heights: the
    /// work area above the 216 pt timeline, less the 38 pt title row. Each size's box height
    /// is written out: 16:9 of the width down to 1280 × 700, and at the 960 × 600 minimum the
    /// box gives way so the body keeps `PanelHost.bodyMinimum`.
    static func measureHeights(app: AppModel, directory: URL) async throws -> [DebugUISuite.Result] {
        guard let root = app.shared?.root else { throw VoxClipError.sharedResourcesMissing }
        let fixture = try DemoEditing.loadFixture(root.appendingPathComponent("fixtures/projects/five-questions.voxclip"))
        var measurements: [HeightMeasurement] = []
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sizes: [(String, CGFloat, CGFloat)] = [("1440x900", 444, 622), ("1280x800", 404, 522),
            ("1280x700", 404, 422), ("960x600", 324, 322)]
        let boxHeights: [String: CGFloat] = ["1440x900": 250, "1280x800": 227, "1280x700": 227, "960x600": 132]
        let shell = WorkspaceShell(app: app)
        for (window, width, height) in sizes {
            // Every job's state at the sizes where the body is shortest, as well as at 1280 × 800.
            let extra = window == "1440x900" ? [] : ["rewrite", "rewrite-budget", "fine-tune", "caption-error", "captions-off"] + DebugRewriteGeneration.variants
            for variant in ["source", "9:16", "1:1", "16:9"] + extra {
                try Data("\(window) \(variant)".utf8).write(to: directory.appendingPathComponent("height-progress.txt"), options: .atomic)
                let model = EditorModel(document: VoxClipDocument(project: fixture, demo: true), app: app, preview: DemoPreviewEngine())
                defer { model.close() }
                model.setAspect(AspectRatio(rawValue: variant) ?? .source)
                model.setStyle("vox-highlight")
                if variant == "captions-off" { model.setCaptionsEnabled(false) }
                if variant == "caption-error" { model.captionError = "Captions couldn't be drawn. Your media and edits are safe. Choose another style or try again." }
                if variant.hasPrefix("rewrite") { try openRewrite(variant, in: model) }
                let controller = NSHostingController(rootView: PanelHost(model: model, shell: shell, width: width, height: height, fineTune: variant == "fine-tune"))
                controller.sizingOptions = []
                let host = controller.view
                host.frame = CGRect(x: 0, y: 0, width: width, height: height)
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(100))
                host.layoutSubtreeIfNeeded()
                let scrolls = scrollViews(in: host)
                let audit = viewAudit(host)
                let found = markers(in: host)
                measurements.append(HeightMeasurement(window: window, variant: variant, width: width, height: height,
                    box: found["viewer.box"] ?? .zero, stage: found["viewer.stage"] ?? .zero, header: found["panel.header"] ?? .zero,
                    scrollFrames: scrolls.map { $0.convert($0.bounds, to: host) },
                    scrollClipping: scrolls.map { $0.clipsToBounds && $0.contentView.clipsToBounds },
                    scrolledViews: audit.scrolled, viewOverflow: audit.overflow))
            }
        }
        try JSONEncoder().encode(measurements).write(to: directory.appendingPathComponent("right-column-heights.json"), options: .atomic)
        return measurements.flatMap { measurement -> [DebugUISuite.Result] in
            let rewriting = measurement.variant.hasPrefix("rewrite")
            let viewport = measurement.scrollFrames.first ?? .zero
            // The frame is fitted in the box, with no Rewrite compaction: every job gets the same box.
            let boxHeight = boxHeights[measurement.window] ?? .nan
            let expected = ViewerSection.stageSize(ratio: ratio(measurement.variant, fixture: fixture), in: CGSize(width: measurement.width, height: boxHeight))
            let boxMatches = abs(measurement.box.width - measurement.width) <= 0.5 && abs(measurement.box.height - boxHeight) <= 0.5
                && abs(PanelHost.viewerHeight(width: measurement.width, height: measurement.height) - boxHeight) <= 0.5
            let stageMatches = abs(measurement.stage.width - expected.width) <= 0.5 && abs(measurement.stage.height - expected.height) <= 0.5
            let headerMatches = abs(measurement.header.minY - measurement.box.maxY) <= 0.5 && abs(measurement.header.height - PanelHost.headerHeight) <= 0.5
            let body = measurement.height - measurement.header.maxY
            let name = "right column \(measurement.window) \(measurement.variant)"
            return [
                .init(name: "\(name): viewer \(measurement.box.size) is \(boxHeight) high, stage \(measurement.stage.size) is \(expected), header 30 under it", passed: boxMatches && stageMatches && headerMatches),
                .init(name: "\(name): the panel body (\(body)) keeps at least \(PanelHost.bodyMinimum)", passed: body >= PanelHost.bodyMinimum - 0.5),
                .init(name: "\(name): visible descendants fit", passed: measurement.viewOverflow.isEmpty && measurement.scrollClipping.allSatisfy { $0 }),
                .init(name: "\(name): the panel's scroll (\(viewport.height)) keeps at least \(minimumViewport)", passed: viewport.height >= minimumViewport - 0.5),
                .init(name: "\(name): the panel scrolls inside its body (\(viewport.minY)–\(viewport.maxY))", passed: viewport.minY >= measurement.header.maxY - 0.5 && (rewriting || viewport.maxY <= measurement.height - 15.5))
            ]
        }
    }
    static func scrollViews(in host: NSView) -> [NSScrollView] {
        (host as? NSScrollView).map { [$0] } ?? host.subviews.flatMap { scrollViews(in: $0) }
    }
    static func run(app: AppModel, directory: URL) async throws -> [DebugUISuite.Result] {
        let previous = app.settings
        defer { app.settings = previous }
        app.settings.values["voiceLab.enabled"] = .bool(true)
        app.settings.values["voiceLab.betaNoticeAccepted"] = .bool(true)
        app.settings.values["voiceLab.providerConsent.elevenlabs"] = .bool(true)
        if CommandLine.arguments.contains("-heightsOnly") { return try await measureHeights(app: app, directory: directory) }
        guard let root = app.shared?.root else { throw VoxClipError.sharedResourcesMissing }
        let fixture = try DemoEditing.loadFixture(root.appendingPathComponent("fixtures/projects/five-questions.voxclip"))
        let previousSettings = app.settings
        defer { app.settings = previousSettings }
        app.set("voiceLab.enabled", .bool(true))
        let height: CGFloat = 4096
        var measurements: [Measurement] = []
        for width: CGFloat in [300, 320, 340, 360, 440, 560] {
          for variant in ["source", "9:16", "1:1", "16:9", "ai-rate-hours", "captions-off", "fine-tune", "caption-error", "rewrite", "rewrite-budget"] + DebugRewriteGeneration.variants {
            let model = EditorModel(document: VoxClipDocument(project: fixture, demo: true), app: app, preview: DemoPreviewEngine())
            defer { model.close() }
            let shell = WorkspaceShell(app: app)
            model.setAspect(AspectRatio(rawValue: variant) ?? .source)
            model.setStyle(variant == "fine-tune" ? "box-highlight" : "vox-highlight")
            if variant == "captions-off" { model.setCaptionsEnabled(false) }
            if variant == "caption-error" { model.captionError = "Captions couldn't be drawn. Your media and edits are safe. Choose another style or try again." }
            if variant == "ai-rate-hours" {
                // An hour-long take at 1.5× in the hover transport, with the timeline hidden.
                var voice = try JSONProjectStore.decode(Data(contentsOf: root.appendingPathComponent("fixtures/voice-lab/passage-project.voxclip")))
                voice.media.source.durationSeconds = 3730.1
                let first = try VoiceLabOutputPlanner.build(voice, scope: .full)
                voice.media.source.durationSeconds += 3730.1 - first.duration
                model.voiceLabPlan = try VoiceLabOutputPlanner.build(voice, scope: .full)
                model.playhead = 3730.1; model.playbackRate = 1.5
                shell.layout.timelineVisible = false
            }
            if variant.hasPrefix("rewrite") { try openRewrite(variant, in: model) }
            let content = PanelHost(model: model, shell: shell, width: width, height: height, fineTune: variant == "fine-tune", hovering: variant == "ai-rate-hours")
            let controller = NSHostingController(rootView: content)
            controller.sizingOptions = []
            let host = controller.view
            host.frame = CGRect(x: 0, y: 0, width: width, height: height)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(60))
            host.layoutSubtreeIfNeeded()
            let minimum = controller.sizeThatFits(in: CGSize(width: 0, height: height))
            let proposed = controller.sizeThatFits(in: CGSize(width: width, height: height))
            let markers = markers(in: host)
            let jobs = markers.filter { $0.key.hasPrefix("panel.job.") }.sorted { $0.value.minX < $1.value.minX }.map { String($0.key.dropFirst(10)) }
            measurements.append(Measurement(variant: variant, width: width, minimumWidth: minimum.width, proposedWidth: proposed.width,
                box: markers["viewer.box"] ?? .zero, stage: markers["viewer.stage"] ?? .zero, header: markers["panel.header"] ?? .zero, markers: markers,
                jobs: jobs, accessibilityElements: accessibilityElements(host).filter { $0.isAccessibilityElement() }.count,
                viewOverflow: viewOverflow(host), accessibilityOverflow: accessibilityOverflow(host)))
          }
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let captures = try DebugRewriteGeneration.captures(app: app, directory: directory)
        try JSONEncoder().encode(captures).write(to: directory.appendingPathComponent("rewrite-captures.json"), options: .atomic)
        try JSONEncoder().encode(measurements).write(to: directory.appendingPathComponent("right-column-layout.json"), options: .atomic)
        var results: [DebugUISuite.Result] = measurements.flatMap { measurement -> [DebugUISuite.Result] in
            let name = "right column \(measurement.variant) at \(measurement.width)"
            let rewriting = measurement.variant.hasPrefix("rewrite")
            let expected = ViewerSection.stageSize(ratio: ratio(measurement.variant, fixture: fixture), in: CGSize(width: measurement.width, height: ViewerSection.boxHeight(forWidth: measurement.width)))
            return [
                .init(name: "\(name): minimum \(measurement.minimumWidth), proposed \(measurement.proposedWidth)", passed: measurement.minimumWidth <= measurement.width + 0.5 && measurement.proposedWidth <= measurement.width + 0.5),
                .init(name: "\(name): descendants fit", passed: measurement.viewOverflow.isEmpty && measurement.accessibilityOverflow.isEmpty),
                .init(name: "\(name): viewer \(measurement.box.size) spans the column at 16:9 and the stage \(measurement.stage.size) is \(expected) in it",
                      passed: abs(measurement.box.minX) <= 0.5 && abs(measurement.box.minY) <= 0.5 && abs(measurement.box.width - measurement.width) <= 0.5
                        && abs(measurement.box.height - ViewerSection.boxHeight(forWidth: measurement.width)) <= 0.5
                        && abs(measurement.stage.width - expected.width) <= 0.5 && abs(measurement.stage.height - expected.height) <= 0.5),
                .init(name: "\(name): the 30 pt panel header sits under the viewer", passed: abs(measurement.header.minY - measurement.box.maxY) <= 0.5 && abs(measurement.header.height - PanelHost.headerHeight) <= 0.5 && abs(measurement.header.width - measurement.width) <= 0.5),
                // Offscreen hosts don't vend SwiftUI's virtual accessibility elements, so the descendant check
                // must be shown to have measured the real rows: the switcher's jobs and one Captions candidate.
                .init(name: "\(name): the switcher shows \(measurement.jobs) and one Captions candidate", passed: measurement.jobs == (rewriting ? ["captions", "rewrite"] : ["captions"]) && candidates("captions.", measurement) == (rewriting ? 0 : 1))
            ]
        }
        let hours = measurements.filter { $0.variant == "ai-rate-hours" }
        results.append(.init(name: "the hour-long 1.5× time fits the hover transport inside the viewer at every width",
            passed: hours.count == 6 && hours.allSatisfy { measurement in measurement.markers["viewer.transport"].map { measurement.box.insetBy(dx: -0.5, dy: -0.5).contains($0) } == true }))
        results.append(.init(name: "360-point short Captions summary uses one row", passed: measurements.first { $0.width == 360 && $0.variant == "source" }?.markers["captions.inline"] != nil))
        for measurement in measurements {
            guard let heading = measurement.markers["header.captions.heading"], let toggle = measurement.markers["header.captions.switch"] else { continue }
            results.append(.init(name: "Captions switch at \(measurement.width) (\(measurement.variant)) is centred on the heading inside the inner width",
                passed: abs(heading.midY - toggle.midY) <= 0.5 && toggle.maxX <= measurement.width - 16 + 0.5))
        }
        results += try await captionsSwitchIdentity(app: app, fixture: fixture)
        // Window-free only: the native divider drag runs in the UI self-test (DebugSidebar).
        results += try await measureHeights(app: app, directory: directory)
        results += try await measureResizes(app: app, fixture: fixture, directory: directory)
        for viewport: CGFloat in [399.5, 272, 264] {
            var reveal = CaptionGalleryReveal()
            reveal.begin(CaptionGalleryRequest(selection: "ring-probe", size: CGSize(width: 320, height: viewport), fineTune: false))
            let first = reveal.shouldScroll(to: .tile("vox-highlight"))
            let duplicate = reveal.shouldScroll(to: .tile("vox-highlight"))
            results.append(.init(name: "gallery at \(viewport) coalesces repeated top-alignment commands", passed: first && !duplicate))
            let renewed = reveal.shouldScroll(to: .tile("outline"))
            reveal.complete()
            results.append(.init(name: "gallery at \(viewport) accepts a new target and issues nothing once complete",
                passed: renewed && !reveal.shouldScroll(to: .tile("outline"), geometry: [999])))
            var landing = CaptionGalleryReveal()
            landing.begin(CaptionGalleryRequest(selection: "resized-layout", size: CGSize(width: 320, height: viewport), fineTune: false))
            let issued = landing.shouldScroll(to: .tile("editorial"), geometry: [0])
            let unmoved = landing.shouldScroll(to: .tile("editorial"), geometry: [0])
            let reissued = (1...3).map { landing.shouldScroll(to: .tile("editorial"), geometry: [CGFloat($0) * 100]) }
            let delayed = landing.shouldScroll(to: .tile("editorial"), geometry: [400])
            results.append(.init(name: "gallery at \(viewport) revalidates changed layout without repeating unchanged commands",
                passed: issued && !unmoved && reissued == [true, true, true] && delayed))
        }
        return results
    }
    /// Turning captions off can change which header form fits. The switch the user pressed must
    /// survive that (same AppKit control), or keyboard and VoiceOver focus is lost on every press.
    private static func captionsSwitchIdentity(app: AppModel, fixture: Project) async throws -> [DebugUISuite.Result] {
        func switches(in view: NSView) -> [NSSwitch] { ((view as? NSSwitch).map { [$0] } ?? []) + view.subviews.flatMap { switches(in: $0) } }
        var results: [DebugUISuite.Result] = []
        var formChanged = false
        for width: CGFloat in [300, 320, 340] {
            let model = EditorModel(document: VoxClipDocument(project: fixture, demo: true), app: app, preview: DemoPreviewEngine())
            defer { model.close() }
            model.setStyle("vox-highlight")
            let controller = NSHostingController(rootView: PanelHost(model: model, shell: WorkspaceShell(app: app), width: width, height: 4096))
            controller.sizingOptions = []
            let host = controller.view
            host.frame = CGRect(x: 0, y: 0, width: width, height: 4096)
            host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(60)); host.layoutSubtreeIfNeeded()
            let before = switches(in: host), formBefore = markers(in: host).keys.filter { $0.hasPrefix("captions.") }.sorted()
            model.setCaptionsEnabled(false)
            host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(60)); host.layoutSubtreeIfNeeded()
            let after = switches(in: host), formAfter = markers(in: host).keys.filter { $0.hasPrefix("captions.") }.sorted()
            formChanged = formChanged || formBefore != formAfter
            results.append(.init(name: "Captions switch at \(width) keeps its control when captions turn off (\(formBefore) to \(formAfter), \(before.count)/\(after.count) switches)",
                passed: before.count == 1 && after.count == 1 && before[0] === after[0] && after[0].state == .off))
        }
        results.append(.init(name: "Captions switch identity check exercised a header form change", passed: formChanged))
        return results
    }
    private static func candidates(_ prefix: String, _ measurement: Measurement) -> Int {
        measurement.markers.keys.filter { $0.hasPrefix(prefix) }.count
    }
    static func viewOverflow(_ host: NSView) -> [String] {
        viewAudit(host).overflow
    }
    static func viewAudit(_ host: NSView) -> (overflow: [String], scrolled: [String]) {
        var failures: [String] = []
        var scrolled: [String] = []
        func visit(_ view: NSView) {
            guard !view.isHidden else { return }
            let rect = view.convert(view.bounds, to: host)
            if rect.width > 0, rect.height > 0 {
                var visible = rect
                if let scroll = view.enclosingScrollView, scroll.clipsToBounds, scroll.contentView.clipsToBounds {
                    let viewport = scroll.convert(scroll.bounds, to: host)
                    if rect.minY < viewport.minY - 0.5 || rect.maxY > viewport.maxY + 0.5 { scrolled.append("\(type(of: view)): \(rect)") }
                    visible = rect.intersection(viewport)
                    if rect.minX < host.bounds.minX - 0.5 || rect.maxX > host.bounds.maxX + 0.5 { failures.append("Horizontal scroll content overflow: \(type(of: view)): \(rect)") }
                }
                var ancestor = view.superview
                while let parent = ancestor, parent !== host {
                    if let clip = parent as? NSClipView, clip.clipsToBounds {
                        visible = visible.intersection(clip.convert(clip.bounds, to: host))
                    }
                    ancestor = parent.superview
                }
                if !visible.isNull && !host.bounds.insetBy(dx: -0.5, dy: -0.5).contains(visible) { failures.append("\(type(of: view)): \(rect)") }
            }
            view.subviews.forEach(visit)
        }
        host.subviews.forEach(visit)
        return (failures, scrolled)
    }
    static func accessibilityOverflow(_ host: NSView) -> [String] {
        var failures: [String] = []
        let bounds = host.bounds
        let screen = host.accessibilityFrame()
        func localFrame(_ element: any NSAccessibilityProtocol, depth: Int) -> CGRect {
            if let view = element as? NSView, view.window == nil { return view.convert(view.bounds, to: host) }
            if let cell = element as? NSCell, let view = cell.controlView, view.window == nil { return view.convert(cell.accessibilityFrame(), to: host) }
            if depth < 40, let virtual = element as? NSAccessibilityElement,
               let parent = element.accessibilityParent() as? any NSAccessibilityProtocol {
                let parentFrame = localFrame(parent, depth: depth + 1)
                return virtual.accessibilityFrameInParentSpace().offsetBy(dx: parentFrame.minX, dy: parentFrame.minY)
            }
            return element.accessibilityFrame().offsetBy(dx: -screen.minX, dy: -screen.minY)
        }
        for element in accessibilityElements(host) where element.isAccessibilityElement() {
            let rect = localFrame(element, depth: 0)
            if rect.width > 0, rect.height > 0, !bounds.insetBy(dx: -0.5, dy: -0.5).contains(rect) {
                failures.append("\(type(of: element)) \(element.accessibilityLabel() ?? "unlabelled"): \(rect)")
            }
        }
        return failures
    }
    static func accessibilityElements(_ host: NSView) -> [any NSAccessibilityProtocol] {
        var elements: [any NSAccessibilityProtocol] = []
        var seen: Set<ObjectIdentifier> = []
        func visit(_ element: any NSAccessibilityProtocol, depth: Int) {
            guard depth < 40, seen.insert(ObjectIdentifier(element as AnyObject)).inserted else { return }
            elements.append(element)
            for child in element.accessibilityChildren() ?? [] {
                if let accessible = child as? any NSAccessibilityProtocol { visit(accessible, depth: depth + 1) }
            }
            if let view = element as? NSView { for child in view.subviews { visit(child, depth: depth + 1) } }
        }
        visit(host, depth: 0)
        return elements
    }
    /// The text the layout markers given one carry (`columnLayoutEvidence(_:text:)`): what a
    /// view drew, for checks that cannot read SwiftUI's accessibility offscreen.
    static func texts(in host: NSView) -> [String: String] {
        var texts: [String: String] = [:]
        func visit(_ view: NSView) {
            if let marker = view as? ColumnLayoutMarker, let text = marker.text { texts[marker.name] = text }
            view.subviews.forEach(visit)
        }
        visit(host)
        return texts
    }
    static func markers(in host: NSView) -> [String: CGRect] {
        var frames: [String: CGRect] = [:]
        func visit(_ view: NSView) {
            if let marker = view as? ColumnLayoutMarker {
                var frame = marker.convert(marker.bounds, to: host)
                if marker.name == "viewer.stage", let size = marker.logicalSize { frame.size = size }
                frames[marker.name] = frame
            }
            view.subviews.forEach(visit)
        }
        visit(host)
        return frames
    }
}

@MainActor final class ColumnLayoutMarker: NSView {
    var name = ""
    var text: String?
    var logicalSize: CGSize?
    var scrollTarget: CaptionGalleryTarget?
    override func isAccessibilityElement() -> Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
@MainActor struct ColumnLayoutProbe: NSViewRepresentable {
    let name: String
    var text: String? = nil
    var scrollTarget: CaptionGalleryTarget? = nil
    func makeNSView(context: Context) -> ColumnLayoutMarker { let view = ColumnLayoutMarker(); updateNSView(view, context: context); return view }
    func updateNSView(_ view: ColumnLayoutMarker, context: Context) { view.name = name; view.text = text; view.scrollTarget = scrollTarget }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ColumnLayoutMarker, context: Context) -> CGSize? {
        let size = CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
        if size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite { nsView.logicalSize = size }
        return size
    }
}
#endif

extension View {
    /// A DEBUG marker of this view's frame, and of the text it shows when given one.
    @ViewBuilder func columnLayoutEvidence(_ name: String, text: String? = nil) -> some View {
        #if DEBUG
        background(ColumnLayoutProbe(name: name, text: text))
        #else
        self
        #endif
    }
}
