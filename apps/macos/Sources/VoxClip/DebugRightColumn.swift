#if DEBUG
import AppKit
import SwiftUI
import VoxClipCore

@MainActor enum DebugRightColumn {
    struct Measurement: Encodable {
        let variant: String
        let width: CGFloat
        let minimumWidth: CGFloat
        let proposedWidth: CGFloat
        let viewOverflow: [String]
        let accessibilityOverflow: [String]
    }
    static func run(app: AppModel, directory: URL) async throws -> [DebugUISuite.Result] {
        guard let root = app.shared?.root else { throw VoxClipError.sharedResourcesMissing }
        let fixture = try DemoEditing.loadFixture(root.appendingPathComponent("fixtures/projects/interview-take.voxclip"))
        let model = EditorModel(document: VoxClipDocument(project: fixture, demo: true), app: app, preview: DemoPreviewEngine())
        defer { model.close() }
        model.setAspect(.source)
        var measurements: [Measurement] = []
        for width: CGFloat in [300, 320, 340, 360, 440, 560] {
            let content = VStack(spacing: 0) {
                ViewerSection(model: model)
                Divider()
                CaptionsSection(model: model)
                    .frame(maxHeight: .infinity, alignment: .topLeading).controlSize(.small)
            }
            let controller = NSHostingController(rootView: content)
            let minimum = controller.sizeThatFits(in: CGSize(width: 0, height: 1000))
            let proposed = controller.sizeThatFits(in: CGSize(width: width, height: 1000))
            let host = NSHostingView(rootView: content)
            host.sizingOptions = []
            host.frame = CGRect(x: 0, y: 0, width: width, height: 1000)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(60))
            host.layoutSubtreeIfNeeded()
            measurements.append(Measurement(variant: "original", width: width, minimumWidth: minimum.width,
                proposedWidth: proposed.width, viewOverflow: viewOverflow(host), accessibilityOverflow: accessibilityOverflow(host)))
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(measurements).write(to: directory.appendingPathComponent("right-column-layout.json"), options: .atomic)
        return measurements.flatMap { measurement in [
            .init(name: "right column \(measurement.variant) at \(measurement.width): minimum \(measurement.minimumWidth), proposed \(measurement.proposedWidth)", passed: measurement.minimumWidth <= measurement.width + 0.5 && measurement.proposedWidth <= measurement.width + 0.5),
            .init(name: "right column \(measurement.variant) at \(measurement.width): descendants fit", passed: measurement.viewOverflow.isEmpty && measurement.accessibilityOverflow.isEmpty)
        ] }
    }
    static func viewOverflow(_ host: NSView) -> [String] {
        var failures: [String] = []
        func visit(_ view: NSView) {
            guard !view.isHidden else { return }
            let rect = view.convert(view.bounds, to: host)
            if rect.width > 0, rect.minX < -0.5 || rect.maxX > host.bounds.width + 0.5 {
                failures.append("\(type(of: view)): \(rect)")
            }
            view.subviews.forEach(visit)
        }
        host.subviews.forEach(visit)
        return failures
    }
    static func accessibilityOverflow(_ host: NSView) -> [String] {
        var failures: [String] = []
        let bounds = host.accessibilityFrame()
        func visit(_ element: any NSAccessibilityProtocol, depth: Int) {
            guard depth < 40 else { return }
            let rect = element.accessibilityFrame()
            if rect.width > 0, rect.minX < bounds.minX - 0.5 || rect.maxX > bounds.maxX + 0.5 {
                failures.append("\(element.accessibilityLabel() ?? "unlabelled"): \(rect)")
            }
            for child in element.accessibilityChildren() ?? [] {
                if let accessible = child as? any NSAccessibilityProtocol { visit(accessible, depth: depth + 1) }
            }
        }
        visit(host, depth: 0)
        return failures
    }
}
#endif
