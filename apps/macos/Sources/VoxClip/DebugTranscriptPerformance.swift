#if DEBUG
import AppKit
import VoxClipCore

@MainActor enum DebugTranscriptPerformance {
    struct Metrics: Codable {
        let wordCount: Int
        let cutMedianMS: Double
        let cutP95MS: Double
        let cutMaximumMS: Double
        let scrollMedianMS: Double
        let scrollP95MS: Double
        let storageRebuildsDuringCuts: Int
        let changedSpansPerCut: Int
        let scope: String
    }
    static func run(app: AppModel, fixture: Project, directory: URL) throws -> [DebugUISuite.Result] {
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical], reason: "Measure interactive edits while the app stays offscreen")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        var project = fixture
        let words = (0..<10_000).map { index in
            TimedWord(id: "benchmark-\(index)", text: index % 20 == 19 ? "word." : "word", start: Double(index) * 0.4, end: Double(index) * 0.4 + 0.3, speaker: "speaker-\(index / 20 % 2)")
        }
        project.transcript?.words = words
        project.transcript?.durationSeconds = 4000
        project.media.source.durationSeconds = 4000
        project.edits = ProjectEdits(cutWordIds: words.enumerated().filter { $0.offset.isMultiple(of: 5) }.map { $0.element.id })
        let model = EditorModel(document: VoxClipDocument(project: project), app: app, preview: DemoPreviewEngine())
        defer { model.close() }
        model.mediaResolved = true; model.refresh()
        let coordinator = TranscriptTextView.Coordinator(model: model)
        let text = TranscriptNSTextView(usingTextLayoutManager: true)
        text.frame = NSRect(x: 0, y: 0, width: 700, height: 600)
        text.textContainer?.containerSize = NSSize(width: 700, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = true
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.isEditable = false; text.delegate = coordinator; text.model = model
        text.textLayoutManager?.delegate = coordinator
        let renderer = coordinator.renderer
        renderer.text = text; coordinator.text = text
        text.textLayoutManager?.renderingAttributesValidator = { [weak renderer] _, fragment in MainActor.assumeIsolated { renderer?.validate(fragment) } }
        let scroll = NSScrollView(frame: text.frame)
        scroll.documentView = text
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 700, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = scroll
        defer { window.close() }
        renderer.rebuild(model: model)
        var state = TranscriptAppearance(cutWords: model.cutWordIDs, cutPauses: model.cutPauseIDs, fillers: model.fillerIDs)
        renderer.update(state)
        guard let manager = text.textLayoutManager else { throw CocoaError(.coderInvalidValue) }
        manager.ensureLayout(for: manager.documentRange)
        manager.textViewportLayoutController.layoutViewport()
        text.displayIfNeeded()
        let revision = renderer.storageRevision
        var cutTimes: [Double] = []
        var changedCounts: [Int] = []
        for iteration in 0..<30 {
            let id = words[iteration + 1].id
            let before = renderer.attributeUpdates
            let start = ContinuousClock.now
            model.apply(.toggle(id: id), name: "Performance toggle")
            state = TranscriptAppearance(cutWords: model.cutWordIDs, cutPauses: model.cutPauseIDs, fillers: model.fillerIDs)
            renderer.update(state)
            changedCounts.append(renderer.attributeUpdates - before)
            text.displayIfNeeded()
            cutTimes.append(milliseconds(start.duration(to: .now)))
        }
        var scrollTimes: [Double] = []
        for frame in 0..<120 {
            let start = ContinuousClock.now
            let maximum = max(0, text.bounds.height - scroll.contentView.bounds.height)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: min(maximum, Double(frame) * 28)))
            scroll.reflectScrolledClipView(scroll.contentView)
            manager.textViewportLayoutController.layoutViewport()
            text.displayIfNeeded()
            scrollTimes.append(milliseconds(start.duration(to: .now)))
        }
        let configuration = "DEBUG assertions=\(_isDebugAssertConfiguration())"
        let metrics = Metrics(wordCount: words.count, cutMedianMS: percentile(cutTimes, 0.5), cutP95MS: percentile(cutTimes, 0.95), cutMaximumMS: cutTimes.max() ?? 0, scrollMedianMS: percentile(scrollTimes, 0.5), scrollP95MS: percentile(scrollTimes, 0.95), storageRebuildsDuringCuts: renderer.storageRevision - revision, changedSpansPerCut: changedCounts.max() ?? 0, scope: "\(configuration). Production EditHistory.apply through EditorModel.refresh, timeline projection and TextKit display; 10,000 words with 2,000 initial cuts. Offscreen CPU frame times, not physical display refresh measurements.")
        try JSONEncoder().encode(metrics).write(to: directory.appendingPathComponent("transcript-performance.json"), options: .atomic)
        let map = text.map
        var results = [
            DebugUISuite.Result(name: "10000-word cut rendering stays below 50 ms", passed: _isDebugAssertConfiguration() || metrics.cutMaximumMS < 50),
            DebugUISuite.Result(name: "cut attributes never rebuild TextKit storage", passed: metrics.storageRebuildsDuringCuts == 0 && metrics.changedSpansPerCut <= 2),
            DebugUISuite.Result(name: "offscreen scrolling fits the 60 fps CPU budget", passed: metrics.scrollP95MS < 1000 / 60),
            DebugUISuite.Result(name: "range map indexes last words and character intersections", passed: map.span(id: words.last!.id) == map.spans.last && map.intersecting(map.spans[5000].range).count == 1),
            DebugUISuite.Result(name: "end-to-end reducer to attributes performance", passed: _isDebugAssertConfiguration() || metrics.cutMaximumMS < 50)
        ]
        var mapping = TimelineTimeIndex(plan: model.plan)
        let positions = Array(0..<400) + Array((0..<400).reversed())
        let matches = positions.allSatisfy { position in
            let time = Double(position) * 10.01 - 1
            return mapping.map(time) == model.plan?.mapTime(time)
        }
        results.append(.init(name: "indexed timeline times match the Core sample-grid mapper", passed: matches))
        results += try DebugTranscriptPixels.run(app: app, fixture: fixture, directory: directory)
        return results
    }
    private static func milliseconds(_ duration: Duration) -> Double { Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15 }
    private static func percentile(_ values: [Double], _ fraction: Double) -> Double { let sorted = values.sorted(); return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * fraction))] }
}
#endif
