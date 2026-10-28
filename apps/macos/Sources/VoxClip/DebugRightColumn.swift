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
    static func run(app: AppModel, directory: URL) async throws -> [DebugUISuite.Result] {
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
            let content = RightColumnContents(model: model, columnHeight: height, fineTune: variant == "fine-tune")
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
        results.append(.init(name: "300-point Frame choices use a stacked full-width picker", passed: measurements.first { $0.width == 300 && $0.variant == "source" }?.markers["frame.stacked"] != nil))
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
        var failures: [String] = []
        func visit(_ view: NSView) {
            guard !view.isHidden else { return }
            let rect = view.convert(view.bounds, to: host)
            if rect.width > 0, !host.bounds.insetBy(dx: -0.5, dy: -0.5).contains(rect) {
                failures.append("\(type(of: view)): \(rect)")
            }
            view.subviews.forEach(visit)
        }
        host.subviews.forEach(visit)
        return failures
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
