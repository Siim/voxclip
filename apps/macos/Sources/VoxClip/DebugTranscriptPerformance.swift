#if DEBUG
import AppKit
import VoxClipCore

@MainActor enum DebugTranscriptPerformance {
    struct Metrics: Codable {
        let fixture: String
        let wordCount: Int
        let paragraphs: Int
        let longestParagraph: Int
        let cutMedianMS: Double
        let cutP95MS: Double
        let cutMaximumMS: Double
        let scrollMedianMS: Double
        let scrollP95MS: Double
        let storageRebuildsDuringCuts: Int
        let changedSpansPerCut: Int
        let tabSwitchMaximumMS: Double
        let tabSwitchRestyles: [Int]
        /// Cuts and restores with Show Cut Words off, each folding or unfolding a run of words
        /// into one `⋯ N cut` token: a storage edit, as V8b's folds will be (impl-plan V8a).
        let foldCutMedianMS: Double
        let foldCutP95MS: Double
        let foldCutMaximumMS: Double
        let paragraphsReplacedPerCut: Int
        let documentRebuildsDuringCuts: Int
        let stylesPerFoldCut: Int
        let showCutsToggleMaximumMS: Double
        let scope: String
    }
    /// 10,000 words: speakers alternate every 20 words, or one speaker talks throughout with a
    /// sentence end every 37 words, which only the paragraph cap breaks up (impl-plan §3.1).
    static func fixtures() -> [(name: String, words: [TimedWord])] {
        let alternating: [TimedWord] = (0..<10_000).map { (index: Int) -> TimedWord in
            let text: String = index % 20 == 19 ? "word." : "word"
            let start: Double = Double(index) * 0.4
            return TimedWord(id: "benchmark-\(index)", text: text, start: start, end: start + 0.3, speaker: "speaker-\(index / 20 % 2)")
        }
        let single: [TimedWord] = (0..<10_000).map { (index: Int) -> TimedWord in
            let start: Double = Double(index) * 0.4 + Double(index % 7) * 0.02
            return TimedWord(id: "benchmark-\(index)", text: index % 37 == 36 ? "word." : "word", start: start, end: start + 0.3, speaker: "speaker-0")
        }
        return [("speaker-alternating", alternating), ("single-speaker", single)]
    }
    static func run(app: AppModel, fixture: Project, directory: URL) throws -> [DebugUISuite.Result] {
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical], reason: "Measure interactive edits while the app stays offscreen")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        var results: [DebugUISuite.Result] = []
        var measured: [Metrics] = []
        for (name, words) in fixtures() {
            let (metrics, checks) = try measure(name, words: words, app: app, fixture: fixture)
            measured.append(metrics); results += checks
        }
        try JSONEncoder().encode(measured).write(to: directory.appendingPathComponent("transcript-performance.json"), options: .atomic)
        results += try DebugTranscriptPixels.run(app: app, fixture: fixture, directory: directory)
        return results
    }
    private static func measure(_ name: String, words: [TimedWord], app: AppModel, fixture: Project) throws -> (Metrics, [DebugUISuite.Result]) {
        var project = fixture
        project.transcript?.words = words
        project.transcript?.durationSeconds = 4000
        project.media.source.durationSeconds = 4000
        project.edits = ProjectEdits(cutWordIds: words.enumerated().filter { $0.offset.isMultiple(of: 5) }.map { $0.element.id })
        // Two neighbouring clips in the middle of the take, for the tab switches.
        project.edits.clips = [ClipRange(id: "benchmark-a", startWordId: words[5_000].id, endWordId: words[5_149].id, title: "A"),
                               ClipRange(id: "benchmark-b", startWordId: words[5_150].id, endWordId: words[5_299].id, title: "B")]
        let model = EditorModel(document: VoxClipDocument(project: project), app: app, preview: DemoPreviewEngine())
        defer { model.close() }
        model.mediaResolved = true; model.refresh()
        let coordinator = TranscriptTextView.Coordinator(model: model)
        let scroll = TranscriptTextView.makeScrollView(model: model, coordinator: coordinator, width: 700, height: 600)
        guard let text = scroll.documentView as? TranscriptNSTextView, let manager = text.textLayoutManager else { throw CocoaError(.coderInvalidValue) }
        let renderer = coordinator.renderer
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 700, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = scroll
        defer { window.close() }
        func state() -> TranscriptAppearance {
            TranscriptAppearance(cutWords: model.cutWordIDs, cutPauses: model.cutPauseIDs, fillers: model.fillerIDs, scope: model.scopeBounds, activeClipID: model.activeClip?.id, playhead: model.sourceTime)
        }
        renderer.rebuild(model: model)
        renderer.update(state())
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
            renderer.update(state())
            changedCounts.append(renderer.attributeUpdates - before)
            text.displayIfNeeded()
            cutTimes.append(milliseconds(start.duration(to: .now)))
        }
        let storageRebuildsDuringCuts = renderer.storageRevision - revision
        // Tab switches: Full Take to clip A, A to its neighbour B, B back to Full Take.
        var switchTimes: [Double] = []
        var restyles: [Int] = []
        for target in ["benchmark-a", "benchmark-b", nil] as [String?] {
            let before = renderer.scopeRestyles
            let start = ContinuousClock.now
            model.apply(.setActiveClip(clipId: target), name: "Performance tab")
            renderer.update(state())
            text.displayIfNeeded()
            switchTimes.append(milliseconds(start.duration(to: .now)))
            restyles.append(renderer.scopeRestyles - before)
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
        // Fold edits (impl-plan V8a): with Show Cut Words off, a cut or a restore folds or
        // unfolds a run of words into one `⋯ N cut` token, so the text is rebuilt as
        // TranscriptTextView.updateNSView rebuilds it. Turning Show Cut Words off and on again
        // are the Show cuts toggles.
        func render() { renderer.rebuild(model: model); renderer.update(state()); text.displayIfNeeded() }
        var toggleTimes: [Double] = []
        var toggleRebuilds = 0
        func toggle(_ shown: Bool) {
            let rebuilds = renderer.documentRebuilds
            let start = ContinuousClock.now
            model.showCuts = shown
            render()
            toggleTimes.append(milliseconds(start.duration(to: .now)))
            toggleRebuilds += renderer.documentRebuilds - rebuilds
        }
        toggle(false)
        let foldRebuilds = renderer.documentRebuilds
        var foldTimes: [Double] = [], replaced: [Int] = [], styles: [Int] = []
        // Single toggles spread over the take, then the two words either side of three paragraph breaks.
        var edits: [() -> EditCommand] = (0..<24).map { index in { .toggle(id: words[(index * 409 + 1) % words.count].id) } }
        for paragraph in [3, renderer.paragraphs.count / 2, renderer.paragraphs.count - 2] where paragraph > 0 && paragraph < renderer.paragraphs.count {
            let ids = [words[renderer.paragraphs[paragraph].firstWord - 1].id, words[renderer.paragraphs[paragraph].firstWord].id]
            let edit = { ids.allSatisfy(model.cutWordIDs.contains) ? EditCommand.restoreSelection(ids: ids) : .cutSelection(ids: ids) }
            edits += [edit, edit]
        }
        for edit in edits {
            let before = (paragraphs: renderer.paragraphReplacements, styles: renderer.rebuildStyles)
            let start = ContinuousClock.now
            model.apply(edit(), name: "Performance fold")
            render()
            foldTimes.append(milliseconds(start.duration(to: .now)))
            replaced.append(renderer.paragraphReplacements - before.paragraphs)
            styles.append(renderer.rebuildStyles - before.styles)
        }
        let documentRebuildsDuringFolds = renderer.documentRebuilds - foldRebuilds
        // The edited text, its spans and their styles equal a fresh build of the same take.
        let fresh = TranscriptTextView.Coordinator(model: model)
        let freshScroll = TranscriptTextView.makeScrollView(model: model, coordinator: fresh, width: 700, height: 600)
        fresh.renderer.rebuild(model: model)
        fresh.renderer.update(state())
        let edited = text.map.spans
        func color(_ renderer: TranscriptRenderer, _ id: String) -> NSColor? { renderer.attributes[id]?[.foregroundColor] as? NSColor }
        let roundTrip = (freshScroll.documentView as? TranscriptNSTextView).map { $0.string == text.string && $0.map.spans == edited } == true
            && edited.allSatisfy { span in
                text.map.span(id: span.id) == span && span.ids.allSatisfy { text.map.span(id: $0) == span } && text.map.intersecting(span.range) == [span]
                    && (!span.selectable || text.map.span(at: span.range.location) == span) && color(renderer, span.id) === color(fresh.renderer, span.id)
            }
            && Set(renderer.attributes.keys) == Set(edited.map(\.id)) && renderer.paragraphs == fresh.renderer.paragraphs
        toggle(true)
        let lengths = zip(renderer.paragraphs, renderer.paragraphs.dropFirst().map(\.firstWord) + [words.count]).map { $1 - $0.firstWord }
        let configuration = "DEBUG assertions=\(_isDebugAssertConfiguration())"
        let metrics = Metrics(fixture: name, wordCount: words.count, paragraphs: lengths.count, longestParagraph: lengths.max() ?? 0, cutMedianMS: percentile(cutTimes, 0.5), cutP95MS: percentile(cutTimes, 0.95),
                              cutMaximumMS: cutTimes.max() ?? 0, scrollMedianMS: percentile(scrollTimes, 0.5), scrollP95MS: percentile(scrollTimes, 0.95), storageRebuildsDuringCuts: storageRebuildsDuringCuts,
                              changedSpansPerCut: changedCounts.max() ?? 0, tabSwitchMaximumMS: switchTimes.max() ?? 0, tabSwitchRestyles: restyles,
                              foldCutMedianMS: percentile(foldTimes, 0.5), foldCutP95MS: percentile(foldTimes, 0.95), foldCutMaximumMS: foldTimes.max() ?? 0,
                              paragraphsReplacedPerCut: replaced.max() ?? 0, documentRebuildsDuringCuts: documentRebuildsDuringFolds, stylesPerFoldCut: styles.max() ?? 0,
                              showCutsToggleMaximumMS: toggleTimes.max() ?? 0,
                              scope: "\(configuration). Production EditHistory.apply through EditorModel.refresh, timeline projection and TextKit display; 10,000 words with 2,000 initial cuts. Tab switches go through setActiveClip and the renderer's scope restyle. Fold edits rebuild the text with Show Cut Words off, as the editor does: 24 single toggles and 6 two-word edits across paragraph breaks. Offscreen CPU frame times, not physical display refresh measurements.")
        let map = text.map
        // Full Take to A restyles the words outside A; A to B only the 300 words of both; B to Full Take the words outside B.
        let outside = words.count - 150
        var results = [
            DebugUISuite.Result(name: "\(name): 10000-word cut rendering stays below 50 ms", passed: _isDebugAssertConfiguration() || metrics.cutMaximumMS < 50),
            DebugUISuite.Result(name: "\(name): a cut replaces at most 2 paragraphs and never rebuilds the document (\(replaced.filter { $0 == 2 }.count) edits replaced 2)",
                                passed: metrics.storageRebuildsDuringCuts == 0 && metrics.changedSpansPerCut <= 2 && metrics.paragraphsReplacedPerCut <= 2 && replaced.contains(2) && metrics.documentRebuildsDuringCuts == 0),
            DebugUISuite.Result(name: "\(name): a fold edit stays below 50 ms (\(String(format: "%.1f", metrics.foldCutMaximumMS)) ms)", passed: _isDebugAssertConfiguration() || metrics.foldCutMaximumMS < 50),
            DebugUISuite.Result(name: "\(name): a fold edit restyles only its paragraphs' spans, and untouched paragraphs keep theirs (at most \(metrics.stylesPerFoldCut) of \(edited.count))",
                                passed: metrics.stylesPerFoldCut > 0 && metrics.stylesPerFoldCut <= 2 * metrics.longestParagraph),
            DebugUISuite.Result(name: "\(name): after fold edits the range map round-trips and the text, spans and styles equal a fresh build", passed: roundTrip),
            DebugUISuite.Result(name: "\(name): a Show cuts toggle rebuilds the document in at most 150 ms (\(String(format: "%.1f", metrics.showCutsToggleMaximumMS)) ms)",
                                passed: toggleRebuilds == 2 && (_isDebugAssertConfiguration() || metrics.showCutsToggleMaximumMS <= 150)),
            DebugUISuite.Result(name: "\(name): offscreen scrolling fits the 60 fps CPU budget", passed: metrics.scrollP95MS < 1000 / 60),
            DebugUISuite.Result(name: "\(name): range map indexes last words and character intersections", passed: map.span(id: words.last!.id) == map.spans.last && map.intersecting(map.spans[5000].range).count == 1),
            DebugUISuite.Result(name: "\(name): end-to-end reducer to attributes performance", passed: _isDebugAssertConfiguration() || metrics.cutMaximumMS < 50),
            DebugUISuite.Result(name: "\(name): paragraphs hold at most 150 words (\(metrics.paragraphs) paragraphs, longest \(metrics.longestParagraph))", passed: metrics.longestParagraph <= 150 && metrics.paragraphs >= words.count / 150),
            DebugUISuite.Result(name: "\(name): a tab switch takes at most 50 ms (\(String(format: "%.1f", metrics.tabSwitchMaximumMS)) ms)", passed: _isDebugAssertConfiguration() || metrics.tabSwitchMaximumMS <= 50),
            DebugUISuite.Result(name: "\(name): a tab switch restyles only the spans whose in-clip state changed (\(restyles))",
                                passed: restyles.count == 3 && restyles[1] <= 300 && restyles[1] > 0 && restyles[0] <= outside && restyles[2] <= outside && restyles[0] > 0)
        ]
        var mapping = TimelineTimeIndex(plan: model.plan)
        let positions = Array(0..<400) + Array((0..<400).reversed())
        let matches = positions.allSatisfy { position in
            let time = Double(position) * 10.01 - 1
            return mapping.map(time) == model.plan?.mapTime(time)
        }
        results.append(.init(name: "\(name): indexed timeline times match the Core sample-grid mapper", passed: matches))
        return (metrics, results)
    }
    private static func milliseconds(_ duration: Duration) -> Double { Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15 }
    private static func percentile(_ values: [Double], _ fraction: Double) -> Double { let sorted = values.sorted(); return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * fraction))] }
}
#endif
