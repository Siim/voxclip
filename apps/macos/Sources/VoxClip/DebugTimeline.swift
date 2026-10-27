#if DEBUG
import AppKit
import ApplicationServices
import AVFoundation
import SwiftUI
import VoxClipCore

@MainActor enum DebugTimeline {
    private static var endpointDocument: VoxClipDocument?
    static func audit(app: AppModel, directory: URL) async {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard let root = app.shared?.root else { throw CocoaError(.fileNoSuchFile) }
            let fixture = try DemoEditing.loadFixture(root.appendingPathComponent("fixtures/projects/interview-take.voxclip"))
            let results = try await run(app: app, fixture: fixture, directory: directory)
            try JSONEncoder().encode(results).write(to: directory.appendingPathComponent("results.json"))
            exit(results.allSatisfy(\.passed) ? 0 : 1)
        } catch { exit(1) }
    }
    static func run(app: AppModel, fixture: Project, directory: URL) async throws -> [DebugUISuite.Result] {
        var results: [DebugUISuite.Result] = []
        func check(_ name: String, _ passed: Bool) { results.append(.init(name: name, passed: passed)) }
        func mark(_ name: String) { try? Data(name.utf8).write(to: directory.appendingPathComponent("timeline-phase.txt"), options: .atomic) }
        mark("prepare model")
        check("timeline clip zoom uses the 1.5-second minimum padding", timelineZoom(clip: 10...15, duration: 50) == 8.5...16.5)
        check("timeline clip zoom caps padding at three seconds", timelineZoom(clip: 10...50, duration: 80) == 7...53)
        check("timeline zoom clamps to source bounds", timelineZoom(clip: 0.5...9.5, duration: 10) == 0...10)
        results += trimEndpoints(app: app, fixture: fixture)
        mark("trim endpoints complete")
        let project = try DebugSidebar.fiveQuestions(from: fixture)
        let shell = WorkspaceShell(app: app)
        mark("attach model")
        await shell.attachForTesting(VoxClipDocument(project: project, demo: true), selection: .fullTake)
        guard let model = shell.editor, let undo = model.undoManager else { throw CocoaError(.coderInvalidValue) }
        defer { model.close(); model.document.updateChangeCount(.changeCleared); model.document.close() }
        mark("refreshed")
        check("timeline clip numbers follow Core sidebar order and suggestions", model.timeline.clips.map(\.number) == model.sortedClips.compactMap { model.clipNumber($0.id) } && model.timeline.clips.contains { $0.state == .suggested })
        check("timeline defaults to Source", !model.editedTimeline)
        let spokenCases: [(Double, String)] = [(0, "0 seconds"), (0.5, "0 seconds"), (1.5, "2 seconds"), (59.49, "59 seconds"), (59.5, "1 minute 00"), (60.5, "1 minute 00"), (65, "1 minute 05"), (119.5, "2 minutes 00"), (135, "2 minutes 15")]
        for (time, expected) in spokenCases {
            check("timeline spoken whole seconds match Windows rounding at \(time)", timelineSpokenTime(time) == expected)
        }
        check("Edited slider uses the exact spoken design value", timelineValueText(time: 42, total: 135, cuts: 12, edited: true) == "42 seconds of 2 minutes 15 after cuts, 12 cuts")
        check("Source slider uses source duration and never says after cuts", timelineValueText(time: 42, total: 190, cuts: 12, edited: false) == "42 seconds of 3 minutes 10 source, 12 cuts")
        let revision = model.transcriptRevision
        model.selectedWordIDs = Set(model.words[3...6].map(\.id)); model.rewrite = 4...7
        check("timeline selection and Rewrite update without rebuilding the transcript", model.displayTimeline.selection?.source == model.words[3].start...model.words[6].end && model.displayTimeline.rewrite?.source == model.words[4].start...model.words[7].end && model.transcriptRevision == revision)
        model.selectedWordIDs = []; model.rewrite = nil
        guard model.keptClips.count >= 2 else { throw CocoaError(.coderInvalidValue) }
        let clip = model.keptClips[1]
        model.activate(clip)
        mark("activated")
        let oldEnd = model.index(clip.endWordId)!
        undo.removeAllActions()
        let previousSteps = model.undoSteps
        model.adjustTrim(start: false, offset: 1)
        mark("trimmed")
        check("Clip 2 end accessibility increment updates exactly one word in one Trim clip undo", model.activeClip?.endWordId == model.words[oldEnd + 1].id && model.undoSteps == previousSteps + 1 && undo.undoActionName == "Trim clip")
        undo.undo()
        mark("undone")
        check("one undo restores the pre-trim clip edge", model.activeClip?.endWordId == clip.endWordId)
        let boundary = model.words[oldEnd].end
        check("end trim snaps to the nearest word end, not word start", model.trimIndex(start: false, source: boundary + 0.001) == oldEnd)
        let scope = model.timeline.scope!.source
        check("clip projection exposes its exact source zoom", model.timeline.zoom == timelineZoom(clip: scope, duration: model.sourceDuration))
        check("zoomed scrubbing maps both endpoints without full-take scaling", model.timeline.time(0, edited: false) == model.timeline.zoom.lowerBound && model.timeline.time(1, edited: false) == model.timeline.zoom.upperBound)
        let envelope = WaveformData(fine: [0, 0, 0, 0, 1, 1, 1, 1, 1, 1])
        check("50-ms waveform buckets aggregate five 10-ms RMS levels energetically", abs(envelope.buckets[0] - sqrt(0.2)) < 0.0001 && envelope.buckets[1] == 1)
        results += try await waveform(directory: directory)
        mark("waveform complete")
        results += try await audioCaptures(app: app, fixture: fixture, directory: directory)
        results += try await missingCaptionPosition(app: app, fixture: fixture, directory: directory)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for edited in [false, true] {
                model.editedTimeline = edited
                for compact in [false, true] {
                    let suffix = "timeline-\(edited ? "edited" : "source")-\(compact ? "compact" : "viewer")-\(name)"
                    let window = makeWindow(TimelineStrip(model: model, compactTransport: compact), width: 960, appearance: appearance)
                    defer { window.close() }
                    window.setAccessibilityIdentifier(suffix)
                    window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
                    try await Task.sleep(for: .milliseconds(150))
                    _ = try capture(window.contentView!, name: suffix, directory: directory)
                    let elements = accessibility(window)
                    let sliders = elements.filter { attribute($0, kAXRoleAttribute) as? String == kAXSliderRole }
                    let spokenValues: [String] = sliders.compactMap { (element: AXUIElement) -> String? in
                        attribute(element, kAXValueDescriptionAttribute) as? String ?? attribute(element, kAXValueAttribute) as? String
                    }
                    check("\(suffix) exposes its active projection's spoken slider value", spokenValues.contains(model.timelineAccessibilityValue))
                    let labels = elements.compactMap { attribute($0, kAXDescriptionAttribute) as? String }
                    check("\(suffix) exposes one slider and separate trim handles", sliders.count == 1 && labels.contains("Clip 2 start") && labels.contains("Clip 2 end"))
                    let times = elements.filter { attribute($0, kAXIdentifierAttribute) as? String == "voxclip.compact.time" }
                    check("\(suffix) has a time readout only in compact transport", times.count == (compact ? 1 : 0))
                    try JSONSerialization.data(withJSONObject: labels).write(to: directory.appendingPathComponent("\(suffix)-ax.json"))
                }
            }
            if let bounds = model.scopeBounds {
                let selectionEnd = min(bounds.upperBound, bounds.lowerBound + 3)
                let rewriteStart = min(bounds.upperBound, bounds.lowerBound + 4)
                let rewriteEnd = min(bounds.upperBound, bounds.lowerBound + 9)
                model.selectedWordIDs = Set(model.words[bounds.lowerBound...selectionEnd].map(\.id))
                model.rewrite = rewriteStart...rewriteEnd
                let highlighted = makeWindow(TimelineTrack(projection: model.displayTimeline, edited: model.editedTimeline), width: 600, appearance: appearance)
                _ = try capture(highlighted.contentView!, name: "timeline-selection-rewrite-\(name)", directory: directory)
                highlighted.close()
                model.selectedWordIDs = []; model.rewrite = nil
            }
            var hatch = TimelineProjection()
            hatch.blocks = [TimelineBlock(source: 0.05...0.45, edited: 0...0, cut: true, pause: false, filler: false, inScope: true),
                TimelineBlock(source: 0.55...0.95, edited: 0...0, cut: true, pause: true, filler: false, inScope: true)]
            let hatchWindow = makeWindow(TimelineTrack(projection: hatch, edited: false), width: 600, appearance: appearance)
            let bitmap = try capture(hatchWindow.contentView!, name: "timeline-hatches-\(name)", directory: directory)
            let scale = bitmap.pixelsWide / 600
            check("\(name) word-cut hatch repeats every six points, not nine", repeats(bitmap, from: 70 * scale, to: 210 * scale, row: 43 * scale, period: 6 * scale) && !repeats(bitmap, from: 70 * scale, to: 210 * scale, row: 43 * scale, period: 9 * scale))
            check("\(name) pause-cut hatch repeats every nine points, not six", repeats(bitmap, from: 370 * scale, to: 510 * scale, row: 43 * scale, period: 9 * scale) && !repeats(bitmap, from: 370 * scale, to: 510 * scale, row: 43 * scale, period: 6 * scale))
            hatchWindow.close()
            var dim = TimelineProjection()
            dim.scope = TimelineBand(source: 0.3...0.7, edited: 0...1)
            let dimWindow = makeWindow(TimelineTrack(projection: dim, edited: false), width: 600, appearance: appearance)
            let dimBitmap = try capture(dimWindow.contentView!, name: "timeline-dim-\(name)", directory: directory)
            let reference = Canvas { context, size in
                let track = Path(CGRect(x: 0, y: 28, width: size.width, height: 30))
                context.fill(track, with: .color(DesignValues.color("timeline.track")))
                context.fill(track, with: .color(DesignValues.color("timeline.scopeDim")))
            }
            let referenceWindow = makeWindow(reference, width: 600, appearance: appearance)
            let referenceBitmap = try capture(referenceWindow.contentView!, name: "timeline-dim-reference-\(name)", directory: directory)
            let expected = pixel(referenceBitmap, x: 60 * scale, y: 43 * scale)
            let actual = pixel(dimBitmap, x: 60 * scale, y: 43 * scale)
            let tolerance: Double = 1.0 / 255
            let matches: Bool = zip(actual, expected).allSatisfy { (pair: (Double, Double)) -> Bool in abs(pair.0 - pair.1) < tolerance }
            check("\(name) outside-clip pixels composite timeline.scopeDim at its token alpha", matches)
            referenceWindow.close()
            dimWindow.close()
            let contrastAppearance: NSAppearance.Name = name == "light" ? .accessibilityHighContrastAqua : .accessibilityHighContrastDarkAqua
            let contrastWindow = makeWindow(TimelineTrack(projection: dim, edited: false, forceHighContrast: true), width: 600, appearance: contrastAppearance)
            let contrastBitmap = try capture(contrastWindow.contentView!, name: "timeline-contrast-\(name)", directory: directory)
            check("\(name) Increase Contrast removes outside-scope dimming", pixel(contrastBitmap, x: 60 * scale, y: 43 * scale) == pixel(contrastBitmap, x: 300 * scale, y: 43 * scale))
            contrastWindow.close()
        }
        return results
    }
    private static func missingCaptionPosition(app: AppModel, fixture: Project, directory: URL) async throws -> [DebugUISuite.Result] {
        var project = fixture
        project.media.source.absolutePath = directory.appendingPathComponent("missing.mov").path
        let document = VoxClipDocument(project: project)
        let shell = WorkspaceShell(app: app)
        await shell.attachForTesting(document, selection: .fullTake)
        guard let model = shell.editor, let undo = model.undoManager else { throw CocoaError(.coderInvalidValue) }
        defer { model.close(); document.updateChangeCount(.changeCleared); document.close() }
        model.mediaResolved = false
        model.previewError = "Can't find missing.mov. Edits are saved."
        var results = [DebugUISuite.Result(name: "missing-media caption position remains draggable", passed: model.canMoveCaptions)]
        let previous = model.project.captions
        let point = CaptionPosition(x: 0.5, y: 0.4)
        var moved = model.project
        CaptionFineTuning.position(&moved.captions, aspect: model.captionPreset, point: point)
        undo.removeAllActions()
        model.replace(moved, name: "Move captions")
        results.append(.init(name: "missing-media caption drag changes only position and registers undo", passed: model.project.captions != previous && undo.undoActionName == "Move captions"))
        undo.undo()
        results.append(.init(name: "missing-media caption position undo restores its prior placement", passed: model.project.captions == previous))
        model.replace(moved, name: "Move captions")
        var unrelated = model.project
        unrelated.captions.styleId = "off"
        model.replace(unrelated, name: "Move captions")
        results.append(.init(name: "missing-media position exception does not allow unrelated edits", passed: model.project.captions.styleId != "off"))
        let destination = directory.appendingPathComponent("missing-caption.voxclip")
        try await DebugUISuite.save(document, to: destination)
        let saved = try VoxClipDocument(data: Data(contentsOf: destination)).project
        results.append(.init(name: "missing-media caption position saves through the native document path", passed: saved.captions.positionByAspect[model.captionPreset.rawValue] == point))
        return results
    }
    private static func trimEndpoints(app: AppModel, fixture: Project) -> [DebugUISuite.Result] {
        var project = fixture
        project.media.source.durationSeconds = 60
        project.transcript?.durationSeconds = 60
        project.transcript?.words = (0..<60).map { (index: Int) -> TimedWord in
            let start: Double = Double(index)
            let end: Double = start + 1
            return TimedWord(id: "trim-\(index)", text: "word", start: start, end: end)
        }
        let clip = ClipRange(id: "trim-scope", startWordId: "trim-10", endWordId: "trim-19")
        project.edits = ProjectEdits(clips: [clip], activeClipId: clip.id)
        let document = VoxClipDocument(project: project)
        endpointDocument = document
        let model = EditorModel(document: document, app: app, preview: DemoPreviewEngine())
        defer { model.close(); model.document.updateChangeCount(.changeCleared); model.document.close() }
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.undoManager = undo
        model.mediaResolved = true
        model.refresh()
        model.editedTimeline = true
        var results: [DebugUISuite.Result] = []
        func check(_ name: String, _ passed: Bool) { results.append(.init(name: name, passed: passed)) }
        func trim(start: Bool, index: Int) {
            let currentID = start ? model.activeClip?.startWordId : model.activeClip?.endWordId
            guard model.words[index].id != currentID else { return }
            undo.beginUndoGrouping()
            model.trimClip(clip, start: start, index: index)
            undo.endUndoGrouping()
        }
        for start in [false, true] {
            let edge: String = start ? "left" : "right"
            let fraction: Double = start ? 0 : 1
            if let index = model.timelineTrimIndex(clip, start: start, fraction: fraction) {
                trim(start: start, index: index)
            }
            check("Edited \(edge)-edge trim keeps exact 10–20-second clip word IDs in a 60-second source (\(model.activeClip?.startWordId ?? "nil")...\(model.activeClip?.endWordId ?? "nil"), undo=\(undo.canUndo), duration=\(model.duration))", model.activeClip?.startWordId == clip.startWordId && model.activeClip?.endWordId == clip.endWordId && !undo.canUndo)
            let movedFraction: Double = start ? 0.2 : 0.8
            if let index = model.timelineTrimIndex(clip, start: start, fraction: movedFraction) {
                trim(start: start, index: index)
            }
            check("Edited \(edge)-handle drag creates one Trim clip undo", model.activeClip != clip && undo.undoActionName == "Trim clip")
            undo.undo()
            check("one undo of the Edited \(edge)-handle drag restores both exact saved word IDs", model.activeClip == clip && !undo.canUndo)
            undo.removeAllActions()
            let nearEdge: Double = start ? 0.0000001 : 0.9999999
            if let index = model.timelineTrimIndex(clip, start: start, fraction: nearEdge) { trim(start: start, index: index) }
            check("sample-rounded Edited \(edge) edge remains within the saved clip endpoints", model.activeClip == clip && !undo.canUndo)
        }
        undo.beginUndoGrouping()
        model.apply(.cutSelection(ids: ["trim-14"]), name: "Cut selection")
        undo.endUndoGrouping()
        undo.removeAllActions()
        let collapsedTime: Double = 4
        let fraction: Double = collapsedTime / model.duration
        let inverse: Double = model.timelineSourceTime(collapsedTime)
        let index = model.timelineTrimIndex(clip, start: false, fraction: fraction)
        check("trim and scrub share a right-continuous inverse across a collapsed cut", inverse == 15 && index == 14 && model.timelineTrimIndex(clip, start: true, fraction: fraction) == 15)
        if let index { trim(start: false, index: index) }
        check("dragging an Edited end across a collapsed cut snaps to its stable word boundary", model.activeClip?.endWordId == "trim-14" && undo.undoActionName == "Trim clip")
        undo.undo()
        check("one undo across a collapsed cut restores exact clip IDs without restoring the cut", model.activeClip == clip && model.cutWordIDs.contains("trim-14") && !undo.canUndo)
        return results
    }
    private static func audioCaptures(app: AppModel, fixture: Project, directory: URL) async throws -> [DebugUISuite.Result] {
        var project = fixture
        project.media.source.absolutePath = directory.appendingPathComponent("waveform-fixture.wav").path
        project.media.source.video = nil
        project.media.source.durationSeconds = 1
        project.media.source.contentKey = String(repeating: "b", count: 64)
        project.transcript?.words = [TimedWord(id: "audio-0", text: "Hear", start: 0.1, end: 0.4),
            TimedWord(id: "audio-1", text: "your", start: 0.42, end: 0.65),
            TimedWord(id: "audio-2", text: "story.", start: 0.67, end: 0.92)]
        project.transcript?.durationSeconds = 1
        project.edits = ProjectEdits()
        project.captions.styleId = "box-highlight"
        project.export.aspect = .portrait
        let model = EditorModel(document: VoxClipDocument(project: project), app: app, preview: DemoPreviewEngine())
        defer { model.close(); model.document.close() }
        model.mediaResolved = true; model.refresh()
        await model.loadWaveform()
        model.sourceTime = 0.5; model.playhead = 0.5
        var results = [DebugUISuite.Result(name: "audio-only stage and timeline share the decoded ten-ms envelope", passed: model.waveform?.fine.count == 100 && !model.timeline.sourceWaveform.isEmpty)]
        if let layout = try await model.renderRequest().captionLayout {
            let image = await app.captions.stage(layout, time: 0.5)
            let pixels: Data? = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)?.dataProvider?.data.map { $0 as Data }
            var ink = 0
            if let pixels {
                for offset in stride(from: 3, to: pixels.count, by: 4) where pixels[offset] > 127 { ink += 1 }
            }
            results.append(.init(name: "audio-only captions paint real export-layout glyphs, not a blank overlay", passed: ink > 20))
        }
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let timeline = makeWindow(TimelineStrip(model: model), width: 600, appearance: appearance)
            try await Task.sleep(for: .milliseconds(80))
            _ = try capture(timeline.contentView!, name: "timeline-waveform-\(name)", directory: directory)
            timeline.close()
            let host = NSHostingView(rootView: ViewerSection(model: model).frame(width: 360, height: 430).background(DesignValues.color("bg.surface")))
            host.frame = CGRect(x: 0, y: 0, width: 360, height: 430)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; window.appearance = NSAppearance(named: appearance)
            window.orderBack(nil)
            host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(450))
            let bitmap = try capture(host, name: "viewer-audio-\(name)", directory: directory)
            var highlightedPixels = 0
            for row in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
                for column in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                    let color = pixel(bitmap, x: column, y: row)
                    if color[2] > color[0] + 0.1 && color[0] > color[1] + 0.05 { highlightedPixels += 1 }
                }
            }
            results.append(.init(name: "\(name) audio-only viewer paints the highlighted caption on the actual stage", passed: highlightedPixels > 10))
            window.close()
        }
        return results
    }
    private static func waveform(directory: URL) async throws -> [DebugUISuite.Result] {
        let cache = directory.appendingPathComponent("waveform-cache")
        let content = String(repeating: "a", count: 64)
        let entry = cache.appendingPathComponent(content)
        try FileManager.default.createDirectory(at: entry, withIntermediateDirectories: true)
        let samples: [Float] = [0.2, 0.4, 0.3, 0.5, 0.1]
        let data = samples.withUnsafeBytes { Data($0) }
        try data.write(to: entry.appendingPathComponent("envelope-10ms.f32"))
        var metadata = CacheEntry(contentKey: content, createdAt: Date(), lastAccessAt: Date(), bytes: Int64(data.count))
        metadata.envelope = CacheEnvelope(sampleRate: 48_000, count: samples.count)
        try ProjectJSON.encoder().encode(metadata).write(to: entry.appendingPathComponent("meta.json"))
        let key = WaveformCache.Key(contentKey: content, source: directory.appendingPathComponent("absent.wav"), cache: cache)
        let cached = await WaveformCache.shared.load(key)
        var results = [DebugUISuite.Result(name: "waveform reuses the existing 10-ms cache without decoding a source", passed: cached?.fine == samples)]
        try Data([0]).write(to: entry.appendingPathComponent("envelope-10ms.f32"))
        results.append(.init(name: "waveform rejects truncated cached envelopes", passed: WaveformCache.readEnvelope(key) == nil))
        let wav = directory.appendingPathComponent("waveform-fixture.wav")
        do {
            let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
            let file = try AVAudioFile(forWriting: wav, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)!
            buffer.frameLength = 16_000
            buffer.floatChannelData![0].update(repeating: 0.25, count: 16_000)
            try file.write(from: buffer)
        }
        let decoded = await WaveformCache.shared.load(.init(contentKey: String(repeating: "b", count: 64), source: wav, cache: cache))
        let levelsMatch: Bool = decoded?.buckets.allSatisfy { (level: Float) -> Bool in abs(level - 0.25) < 0.001 } == true
        results.append(.init(name: "off-main AVAssetReader fallback computes fifty-ms linear-PCM RMS", passed: decoded?.buckets.count == 20 && levelsMatch))
        return results
    }
    private static func makeWindow(_ view: some View, width: CGFloat, appearance: NSAppearance.Name) -> NSWindow {
        let host = NSHostingView(rootView: view.frame(width: width, height: 72).background(DesignValues.color("bg.surface")))
        host.frame = CGRect(x: 0, y: 0, width: width, height: 72)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.appearance = NSAppearance(named: appearance)
        host.layoutSubtreeIfNeeded()
        return window
    }
    private static func capture(_ view: NSView, name: String, directory: URL) throws -> NSBitmapImageRep {
        view.layoutSubtreeIfNeeded()
        guard let cached = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CocoaError(.coderInvalidValue) }
        view.cacheDisplay(in: view.bounds, to: cached)
        guard let image = cached.cgImage, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CocoaError(.coderInvalidValue) }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let converted = context.makeImage() else { throw CocoaError(.coderInvalidValue) }
        let bitmap = NSBitmapImageRep(cgImage: converted)
        if let data = bitmap.representation(using: .png, properties: [:]) { try data.write(to: directory.appendingPathComponent("\(name).png")) }
        return bitmap
    }
    private static func pixel(_ bitmap: NSBitmapImageRep, x: Int, y: Int) -> [Double] {
        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return [] }
        return [color.redComponent, color.greenComponent, color.blueComponent]
    }
    private static func repeats(_ bitmap: NSBitmapImageRep, from: Int, to: Int, row: Int, period: Int) -> Bool {
        (from..<(to - period)).allSatisfy { (offset: Int) -> Bool in
            let next: Int = offset + period
            return zip(pixel(bitmap, x: offset, y: row), pixel(bitmap, x: next, y: row)).allSatisfy { (pair: (Double, Double)) -> Bool in abs(pair.0 - pair.1) < 0.02 }
        }
    }
    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
    private static func accessibility(_ window: NSWindow) -> [AXUIElement] {
        let application = AXUIElementCreateApplication(getpid())
        let windows = attribute(application, kAXWindowsAttribute) as? [AXUIElement] ?? []
        guard let target = windows.first(where: { attribute($0, kAXIdentifierAttribute) as? String == window.accessibilityIdentifier() }) else { return [] }
        func descendants(_ element: AXUIElement, depth: Int) -> [AXUIElement] {
            guard depth < 32 else { return [] }
            let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
            let nextDepth: Int = depth + 1
            return [element] + children.flatMap { (child: AXUIElement) -> [AXUIElement] in descendants(child, depth: nextDepth) }
        }
        return descendants(target, depth: 0)
    }
}
#endif
