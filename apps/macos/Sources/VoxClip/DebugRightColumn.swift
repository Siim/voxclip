import SwiftUI
#if DEBUG
import AppKit
import VoxClipCore
import VoxClipMedia

@MainActor enum DebugRightColumn {
    struct Measurement: Encodable {
        let variant: String
        let width: CGFloat
        let minimumWidth: CGFloat
        let proposedWidth: CGFloat
        let stageWidth: CGFloat
        let markers: [String: CGRect]
        let frameChoices: [String]
        let accessibilityElements: Int
        let viewOverflow: [String]
        let accessibilityOverflow: [String]
    }
    struct HeightMeasurement: Encodable {
        let window: String
        let variant: String
        let width: CGFloat
        let height: CGFloat
        let stage: CGRect
        let scrollFrames: [CGRect]
        let scrollClipping: [Bool]
        let scrolledViews: [String]
        let viewOverflow: [String]
    }
    struct ResizeMeasurement: Encodable {
        let width: CGFloat
        let stage: CGRect
        let elapsed: Double
        let settled: Bool
        let viewOverflow: [String]
    }
    private static func measureResizes(app: AppModel, fixture: Project, directory: URL) async throws -> [DebugUISuite.Result] {
        let model = EditorModel(document: VoxClipDocument(project: fixture, demo: true), app: app, preview: DemoPreviewEngine())
        defer { model.close() }
        model.setAspect(.landscape)
        let controller = NSHostingController(rootView: GeometryReader { geometry in
            RightColumnContents(model: model, columnHeight: geometry.size.height, columnWidth: geometry.size.width)
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        })
        controller.sizingOptions = []
        let host = controller.view
        var measurements: [ResizeMeasurement] = []
        for width: CGFloat in [320, 300, 560] {
            host.frame = CGRect(x: 0, y: 0, width: width, height: 675)
            let started = ProcessInfo.processInfo.systemUptime
            var stage = CGRect.zero
            var settled = false
            repeat {
                host.layoutSubtreeIfNeeded()
                stage = markers(in: host)["viewer.stage"] ?? .zero
                settled = abs(stage.width - (width - 32)) <= 0.5 && abs(stage.minX - 16) <= 0.5
                if settled { break }
                await Task.yield()
            } while ProcessInfo.processInfo.systemUptime - started < 2
            measurements.append(ResizeMeasurement(width: width, stage: stage, elapsed: ProcessInfo.processInfo.systemUptime - started,
                settled: settled, viewOverflow: viewOverflow(host)))
        }
        try JSONEncoder().encode(measurements).write(to: directory.appendingPathComponent("right-column-resizes.json"), options: .atomic)
        return measurements.flatMap { measurement in [
            .init(name: "resized column \(measurement.width): stage follows without stale-width feedback", passed: measurement.settled),
            .init(name: "resized column \(measurement.width): visible descendants fit", passed: measurement.viewOverflow.isEmpty)
        ] }
    }
    static func measureHeights(app: AppModel, directory: URL) async throws -> [DebugUISuite.Result] {
        guard let root = app.shared?.root else { throw VoxClipError.sharedResourcesMissing }
        let fixture = try DemoEditing.loadFixture(root.appendingPathComponent("fixtures/projects/five-questions.voxclip"))
        var measurements: [HeightMeasurement] = []
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sizes: [(String, CGFloat, CGFloat)] = [("1440x900", 360, 775), ("1280x800", 320, 675),
            ("1280x700", 320, 575), ("960x600", 300, 475)]
        for (window, width, height) in sizes {
            let extra = width == 320 && height == 675 ? ["rewrite", "rewrite-budget", "fine-tune", "caption-error", "captions-off"] : []
            for variant in ["source", "9:16", "1:1", "16:9"] + extra {
                try Data("\(window) \(variant)".utf8).write(to: directory.appendingPathComponent("height-progress.txt"), options: .atomic)
                let model = EditorModel(document: VoxClipDocument(project: fixture, demo: true), app: app, preview: DemoPreviewEngine())
                defer { model.close() }
                model.setAspect(AspectRatio(rawValue: variant) ?? .source)
                model.setStyle("vox-highlight")
                if variant == "captions-off" { model.setCaptionsEnabled(false) }
                if variant == "caption-error" { model.captionError = "Captions couldn't be drawn. Your media and edits are safe. Choose another style or try again." }
                if variant.hasPrefix("rewrite") {
                    model.mediaResolved = true
                    let envelope = AudioEnvelope(sampleRate: 48_000, levels: Array(repeating: 0.01, count: 10_000))
                    let connector = RewriteConnector(connector: RewriteFixtureConnector(), model: "fixture-local", name: "Fixture", group: "local", plan: "")
                    let session = RewriteSession(editor: model, range: 12...25, envelope: envelope, connector: connector)
                    model.rewrite = session; model.rewriteRange = 12...25
                    session.edit(variant == "rewrite-budget" ? Array(repeating: "replacement", count: 180).joined(separator: " ") : "A clearer way to explain what happened in this passage.")
                }
                let controller = NSHostingController(rootView: RightColumnContents(model: model, columnHeight: height, columnWidth: width, fineTune: variant == "fine-tune"))
                controller.sizingOptions = []
                let host = controller.view
                host.frame = CGRect(x: 0, y: 0, width: width, height: height)
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(100))
                host.layoutSubtreeIfNeeded()
                let scrolls = scrollViews(in: host)
                let audit = viewAudit(host)
                measurements.append(HeightMeasurement(window: window, variant: variant, width: width, height: height,
                    stage: markers(in: host)["viewer.stage"] ?? .zero, scrollFrames: scrolls.map { $0.convert($0.bounds, to: host) },
                    scrollClipping: scrolls.map { $0.clipsToBounds && $0.contentView.clipsToBounds },
                    scrolledViews: audit.scrolled, viewOverflow: audit.overflow))
            }
        }
        try JSONEncoder().encode(measurements).write(to: directory.appendingPathComponent("right-column-heights.json"), options: .atomic)
        return measurements.flatMap { measurement -> [DebugUISuite.Result] in
            let rewriting = measurement.variant.hasPrefix("rewrite")
            let viewport = measurement.scrollFrames.first ?? .zero
            // The stage keeps its §5.1 frame size wherever 320 points remain for the panel below
            // (every aspect at 1280×800 and 1440×900); on shorter columns only its height yields.
            let stage = measurement.stage.size
            let ratio: Double = stage.height > 0 ? Double(stage.width / stage.height) : 1
            let inner: CGFloat = measurement.width - 32
            let specified = viewerStageSize(ratio: ratio, innerWidth: inner, columnHeight: 10_000, rewriting: false)
            let expected = viewerStageSize(ratio: ratio, innerWidth: inner, columnHeight: measurement.height, rewriting: false)
            let fullSize = measurement.height >= 675
            let stageMatches = abs(stage.width - expected.width) <= 0.5 && abs(stage.height - expected.height) <= 0.5
                && (!fullSize || (abs(stage.width - specified.width) <= 0.5 && abs(stage.height - specified.height) <= 0.5))
            return [
                .init(name: "right column height \(measurement.window) \(measurement.variant): stage \(stage) is \(fullSize ? "the specified frame" : "height-limited") \(expected)", passed: rewriting || (stage.height > 0 && stageMatches)),
                .init(name: "right column height \(measurement.window) \(measurement.variant): visible descendants fit", passed: measurement.viewOverflow.isEmpty && viewport.height > 0 && measurement.scrollClipping.allSatisfy { $0 }),
                .init(name: "right column height \(measurement.window) \(measurement.variant): gallery bottom \(viewport.maxY) <= \(measurement.height - 16)", passed: rewriting || viewport.maxY <= measurement.height - 15.5)
            ]
        }
    }
    static func scrollViews(in host: NSView) -> [NSScrollView] {
        (host as? NSScrollView).map { [$0] } ?? host.subviews.flatMap { scrollViews(in: $0) }
    }
    static func run(app: AppModel, directory: URL) async throws -> [DebugUISuite.Result] {
        if CommandLine.arguments.contains("-heightsOnly") { return try await measureHeights(app: app, directory: directory) }
        guard let root = app.shared?.root else { throw VoxClipError.sharedResourcesMissing }
        let fixture = try DemoEditing.loadFixture(root.appendingPathComponent("fixtures/projects/five-questions.voxclip"))
        let previousSettings = app.settings
        defer { app.settings = previousSettings }
        app.set("voiceLab.enabled", .bool(true))
        let height: CGFloat = 4096
        var measurements: [Measurement] = []
        for width: CGFloat in [300, 320, 340, 360, 440, 560] {
          for variant in ["source", "9:16", "1:1", "16:9", "ai-rate-hours", "captions-off", "fine-tune", "caption-error", "rewrite", "rewrite-budget"] {
            let model = EditorModel(document: VoxClipDocument(project: fixture, demo: true), app: app, preview: DemoPreviewEngine())
            defer { model.close() }
            model.setAspect(AspectRatio(rawValue: variant) ?? .source)
            model.setStyle(variant == "fine-tune" ? "box-highlight" : "vox-highlight")
            if variant == "captions-off" { model.setCaptionsEnabled(false) }
            if variant == "caption-error" { model.captionError = "Captions couldn't be drawn. Your media and edits are safe. Choose another style or try again." }
            if variant == "ai-rate-hours" {
                var voice = try JSONProjectStore.decode(Data(contentsOf: root.appendingPathComponent("fixtures/voice-lab/passage-project.voxclip")))
                voice.media.source.durationSeconds = 3730.1
                let first = try VoiceLabOutputPlanner.build(voice, scope: .full)
                voice.media.source.durationSeconds += 3730.1 - first.duration
                model.voiceLabPlan = try VoiceLabOutputPlanner.build(voice, scope: .full)
                model.playhead = 3730.1; model.playbackRate = 1.5
            }
            if variant.hasPrefix("rewrite") {
                model.mediaResolved = true
                let envelope = AudioEnvelope(sampleRate: 48_000, levels: Array(repeating: 0.01, count: 10_000))
                let fake = RewriteFixtureConnector()
                let connector = RewriteConnector(connector: fake, model: "fixture-local", name: "Fixture", group: "local", plan: "")
                let session = RewriteSession(editor: model, range: 12...25, envelope: envelope, connector: connector)
                model.rewrite = session; model.rewriteRange = 12...25
                session.edit(variant == "rewrite-budget" ? Array(repeating: "replacement", count: 180).joined(separator: " ") : "A clearer way to explain what happened in this passage.")
            }
            let content = RightColumnContents(model: model, columnHeight: height, columnWidth: width, fineTune: variant == "fine-tune")
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
            measurements.append(Measurement(variant: variant, width: width, minimumWidth: minimum.width,
                proposedWidth: proposed.width, stageWidth: markers["viewer.stage"]?.width ?? 0, markers: markers,
                frameChoices: frameChoices(host), accessibilityElements: accessibilityElements(host).filter { $0.isAccessibilityElement() }.count,
                viewOverflow: viewOverflow(host), accessibilityOverflow: accessibilityOverflow(host)))
          }
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(measurements).write(to: directory.appendingPathComponent("right-column-layout.json"), options: .atomic)
        var results: [DebugUISuite.Result] = measurements.flatMap { measurement in [
            .init(name: "right column \(measurement.variant) at \(measurement.width): minimum \(measurement.minimumWidth), proposed \(measurement.proposedWidth)", passed: measurement.minimumWidth <= measurement.width + 0.5 && measurement.proposedWidth <= measurement.width + 0.5),
            .init(name: "right column \(measurement.variant) at \(measurement.width): descendants fit", passed: measurement.viewOverflow.isEmpty && measurement.accessibilityOverflow.isEmpty),
            .init(name: "right column \(measurement.variant) at \(measurement.width): stage \(measurement.stageWidth) fits inner width", passed: measurement.stageWidth > 0 && measurement.stageWidth <= measurement.width - 32 + 0.5),
            // Offscreen hosts don't vend SwiftUI's virtual accessibility elements, so the descendant check
            // must be shown to have measured the real rows: the Frame control and one candidate per row.
            .init(name: "right column \(measurement.variant) at \(measurement.width): measured Frame choices \(measurement.frameChoices) and one candidate per row", passed: measurement.frameChoices == ["9:16", "1:1", "16:9", "Original"] && candidates("frame.", measurement) == 1 && candidates("transport.", measurement) == 1 && candidates("captions.", measurement) == (measurement.variant.hasPrefix("rewrite") ? 0 : 1))
        ] }
        results.append(.init(name: "360-point short Captions summary uses one row", passed: measurements.first { $0.width == 360 && $0.variant == "source" }?.markers["captions.inline"] != nil))
        results.append(.init(name: "300-point AI/rate/hour case uses metadata fallback", passed: measurements.first { $0.width == 300 && $0.variant == "ai-rate-hours" }?.markers["transport.stacked"] != nil))
        let stacked = measurements.first { $0.width == 300 && $0.variant == "source" }?.markers["frame.stacked"]
        results.append(.init(name: "300-point Frame choices use a stacked picker spanning the leading inner width (\(stacked.map { "\($0)" } ?? "none"))",
            passed: stacked.map { abs($0.minX - 16) <= 0.5 && abs($0.width - 268) <= 0.5 } ?? false))
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
            let first = reveal.shouldScroll(to: .tile("vox-highlight"), anchor: .top)
            let duplicate = reveal.shouldScroll(to: .tile("vox-highlight"), anchor: .top)
            results.append(.init(name: "gallery at \(viewport) coalesces repeated top-alignment commands", passed: first && !duplicate))
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
            let controller = NSHostingController(rootView: RightColumnContents(model: model, columnHeight: 4096, columnWidth: width))
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
    /// The labels of the visible four-segment Frame control, or none if it wasn't laid out.
    static func frameChoices(_ host: NSView) -> [String] {
        var found: [String] = []
        func visit(_ view: NSView) {
            guard found.isEmpty, !view.isHidden else { return }
            if let control = view as? NSSegmentedControl, control.segmentCount == 4, view.convert(view.bounds, to: host).width > 0 {
                let labels = (0..<control.segmentCount).map { control.label(forSegment: $0) ?? "" }
                if labels == ["9:16", "1:1", "16:9", "Original"] { found = labels; return }
            }
            view.subviews.forEach(visit)
        }
        visit(host)
        return found
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
            if rect.width > 0 {
                var visible = rect
                if let scroll = view.enclosingScrollView, scroll.clipsToBounds, scroll.contentView.clipsToBounds {
                    let viewport = scroll.convert(scroll.bounds, to: host)
                    if rect.minY < viewport.minY - 0.5 || rect.maxY > viewport.maxY + 0.5 { scrolled.append("\(type(of: view)): \(rect)") }
                    visible = rect.intersection(viewport)
                    if rect.minX < host.bounds.minX - 0.5 || rect.maxX > host.bounds.maxX + 0.5 { failures.append("Horizontal scroll content overflow: \(type(of: view)): \(rect)") }
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
            if rect.width > 0, !bounds.insetBy(dx: -0.5, dy: -0.5).contains(rect) {
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
    static func markers(in host: NSView) -> [String: CGRect] {
        var frames: [String: CGRect] = [:]
        func visit(_ view: NSView) {
            if let marker = view as? ColumnLayoutMarker { frames[marker.name] = marker.convert(marker.bounds, to: host) }
            view.subviews.forEach(visit)
        }
        visit(host)
        return frames
    }
}

@MainActor final class ColumnLayoutMarker: NSView {
    var name = ""
    override func isAccessibilityElement() -> Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
@MainActor struct ColumnLayoutProbe: NSViewRepresentable {
    let name: String
    func makeNSView(context: Context) -> ColumnLayoutMarker { let view = ColumnLayoutMarker(); view.name = name; return view }
    func updateNSView(_ view: ColumnLayoutMarker, context: Context) { view.name = name }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ColumnLayoutMarker, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
}
#endif

extension View {
    @ViewBuilder func columnLayoutEvidence(_ name: String) -> some View {
        #if DEBUG
        background(ColumnLayoutProbe(name: name))
        #else
        self
        #endif
    }
}
