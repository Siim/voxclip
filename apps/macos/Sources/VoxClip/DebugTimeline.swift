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
        results += trimEndpoints(app: app, fixture: fixture)
        mark("trim endpoints complete")
        let project = try DebugSidebar.fiveQuestions(from: fixture)
        let shell = WorkspaceShell(app: app)
        mark("attach model")
        await shell.attachForTesting(VoxClipDocument(project: project, demo: true), selection: .fullTake)
        guard let model = shell.editor, let undo = model.undoManager else { throw CocoaError(.coderInvalidValue) }
        defer { model.close(); model.document.updateChangeCount(.changeCleared); model.document.close() }
        mark("refreshed")
        check("timeline defaults to Edited: Show cuts is off", !model.showsCuts && model.timelineAxis == .edited)
        let steps = model.undoSteps, edited = model.document.isDocumentEdited
        model.showsCuts = true
        check("Show cuts switches the timeline to take time without an undo step or a document change",
              model.timelineAxis == .source && model.undoSteps == steps && model.document.isDocumentEdited == edited && !undo.canUndo)
        model.showsCuts = false
        let spokenCases: [(Double, String)] = [(0, "0 seconds"), (0.5, "0 seconds"), (1.5, "2 seconds"), (59.49, "59 seconds"), (59.5, "1 minute 00"), (60.5, "1 minute 00"), (65, "1 minute 05"), (119.5, "2 minutes 00"), (135, "2 minutes 15")]
        for (time, expected) in spokenCases {
            check("timeline spoken whole seconds match Windows rounding at \(time)", timelineSpokenTime(time) == expected)
        }
        check("Edited slider uses the exact spoken design value", timelineValueText(time: 42, total: 135, cuts: 12, edited: true) == "42 seconds of 2 minutes 15 after cuts, 12 cuts")
        check("Source slider uses source duration and never says after cuts", timelineValueText(time: 42, total: 190, cuts: 12, edited: false) == "42 seconds of 3 minutes 10 source, 12 cuts")
        check("overview clips follow Explorer order and mark suggestions", model.timelineOverviewClips.map(\.number) == model.sortedClips.compactMap { model.clipNumber($0.id) }
              && model.timelineOverviewClips.contains { $0.proposal })
        model.selectedWordIDs = Set(model.words[3...6].map(\.id))
        check("the timeline selection is the selected words' take range", model.timelineSelection(on: .source) == model.words[3].start...model.words[6].end)
        model.selectedWordIDs = []
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
        check("Edited In and Out run from 0 to the clip's output length", model.timelineInOut(on: .edited) == 0...model.duration)
        check("Source In and Out are the clip's take range", model.timelineInOut(on: .source) == model.scopeSourceRange && model.scopeSourceRange != nil)
        let envelope = WaveformData(fine: [0, 0, 0, 0.5, 1, 1, 1, 1, 0.2])
        check("the 40 ms level folds four 10 ms frames: their loudest value and their energetic RMS",
              envelope.levels.map(\.frameSeconds) == [0.01, 0.04, 0.16, 0.64] && envelope.levels[1].max == [0.5, 1, 0.2]
              && abs(envelope.levels[1].rms[0] - sqrt(0.0625)) < 0.0001 && envelope.levels[1].rms[1] == 1 && abs(envelope.levels[2].rms[0] - sqrt(4.29 / 9)) < 0.0001)
        results += try await waveform(directory: directory)
        mark("waveform complete")
        results += try await audioCaptures(app: app, fixture: fixture, directory: directory)
        results += try await missingCaptionPosition(app: app, fixture: fixture, directory: directory)
        mark("panel scenes")
        results += try await panelScenes(app: app, shell: shell, model: model, directory: directory)
        mark("hide")
        shell.layout.rightVisible = true
        shell.layout.timelineVisible = true
        shell.toggleTimeline()
        let hidden = !shell.layout.timelineVisible
        shell.toggleTimeline()
        check("⌘J's toggle hides the timeline panel and shows it again", hidden && shell.layout.timelineVisible)
        return results
    }

    /// The panel at notes.md's 1056 × 216 in Edited and Source view, Clip 2 open, dark: the
    /// lanes' pixels, the playhead slider and the trim handles for VoiceOver, and a playhead
    /// tick that moves only the playhead layers. Captures `v2-timeline-edited-dark` and
    /// `v2-timeline-source-dark` from the window server while the session is unlocked.
    private static func panelScenes(app: AppModel, shell: WorkspaceShell, model: EditorModel, directory: URL) async throws -> [DebugUISuite.Result] {
        var results: [DebugUISuite.Result] = []
        func check(_ name: String, _ passed: Bool) { results.append(.init(name: name, passed: passed)) }
        guard let clip = model.activeClip, let number = model.clipNumber(clip.id) else { throw CocoaError(.coderInvalidValue) }
        let size = NSSize(width: 1056, height: 216)
        // A demo project reads no media: A1 draws a speech envelope made from its words.
        model.waveform = speech(words: model.words, duration: model.sourceDuration)
        // Two cuts inside the clip, so Edited has seams and Source removed ranges, and a
        // selection inside it, as f1 has: the toolbar shows its length.
        let first = model.index(clip.startWordId) ?? 0
        let cuts = [first + 7, first + 11].filter { model.words.indices.contains($0) && $0 < (model.index(clip.endWordId) ?? 0) }.map { model.words[$0].id }
            .filter { !model.cutWordIDs.contains($0) }
        if !cuts.isEmpty { model.apply(.cutSelection(ids: cuts), name: "Cut") }
        defer { if !cuts.isEmpty { model.apply(.restoreSelection(ids: cuts), name: "Restore cut") } }
        let selected = Array(model.words[first...].prefix(6).dropFirst(2))
        model.selectedWordIDs = Set(selected.map(\.id))
        for axis in [TimelineAxis.edited, .source] {
            model.showsCuts = axis == .source
            // The playhead a third of the way into the clip before the canvas follows it,
            // so the fitted view keeps In in sight.
            let inOut = model.timelineInOut(on: axis) ?? 0...model.duration
            let source = model.timelineSourceTime(axis == .edited ? model.duration / 3 : inOut.lowerBound + (inOut.upperBound - inOut.lowerBound) / 3, on: axis)
            model.sourceTime = source; model.playhead = model.timelineTime(source: source, on: .edited)
            let name = "v2-timeline-\(axis.rawValue)-dark"
            let host = ShellHost.controller(TimelinePanel(model: model, shell: shell), app: app)
            host.view.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10000, y: -10000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentViewController = host
            window.setContentSize(size)
            window.setAccessibilityIdentifier(name)
            defer { window.close() }
            window.orderFront(nil)
            host.view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(200))
            guard let canvas = DebugShell.firstView(TimelineCanvasView.self, in: host.view) else {
                check("\(name) hosts the AppKit lanes", false)
                continue
            }
            canvas.renderContent()
            canvas.followPlayhead()
            canvas.layoutSubtreeIfNeeded(); canvas.displayIfNeeded()
            let lanes: [TimelineLane] = [canvas.overview, canvas.ruler, canvas.bed, canvas.audio]
            lanes.forEach { $0.layer?.displayIfNeeded() }
            // cacheDisplay draws the lanes and composites the overlay's layers, the right way up.
            let bitmap = try capture(canvas, name: "\(name)-lanes", directory: directory)
            let scale = CGFloat(bitmap.pixelsWide) / canvas.bounds.width
            func color(_ x: CGFloat, _ y: CGFloat) -> [Double] { pixel(bitmap, x: Int(x * scale), y: Int(y * scale)) }
            func matches(_ actual: [Double], _ token: String, alpha: CGFloat = 1, over ground: String? = nil) -> Bool {
                guard let expected = try? swatch(token, alpha: alpha, over: ground) else { return false }
                return actual.count == 3 && expected.count == 3 && zip(actual, expected).allSatisfy { abs($0 - $1) < 3.0 / 255 }
            }
            let viewport = canvas.viewport
            let playX = TimelineMetrics.header + viewport.x(model.timelinePlayhead(on: axis))
            let lineY = TimelineMetrics.tracks[1].y + 10
            check("\(name) draws the playhead as a 1 pt tint line through the tracks", matches(color(playX, lineY), "tint.default"))
            check("\(name) draws the playhead's head in the ruler's lower half", matches(color(playX, TimelineMetrics.ruler.y + 14), "tint.default"))
            let inX = TimelineMetrics.header + viewport.x(inOut.lowerBound)
            check("\(name) draws the In bracket the full ruler height in clip.label", matches(color(inX + 0.75, TimelineMetrics.ruler.y + 12), "clip.label"))
            check("\(name) draws the ruler inside In/Out on chrome", matches(color(inX + 3, TimelineMetrics.ruler.y + 13), "bg.window"))
            if inX - 8 > TimelineMetrics.header {
                check("\(name) darkens the ruler outside In/Out", matches(color(inX - 6, TimelineMetrics.ruler.y + 13), "timeline.rulerOut"))
            }
            check("\(name) draws the track lanes on timeline.lane", matches(color(TimelineMetrics.header + 4, TimelineMetrics.tracks[0].y + 18), "timeline.lane"))
            let open = canvas.overview.x((model.timelineOverviewClips.first { $0.open }?.source.lowerBound ?? 0) + 0.3)
            // One 10 pt band (y 7–17), or two 8 pt rows (3.5–11.5 and 12.5–20.5) once clips overlap.
            check("\(name) draws the open clip's overview block at 42% clip.label",
                  [8, 12, 16].contains { matches(color(open, TimelineMetrics.overview.y + $0), "clip.label", alpha: 0.42, over: "timeline.lane") })
            check("\(name) has no red pixels", !hasRed(bitmap))
            results += audioChecks(name: name, canvas: canvas, model: model, matches: { matches(color($0, $1), $2, alpha: $3, over: $4) })
            // A playhead tick moves only the playhead layers: no lane draws again.
            let draws = lanes.map(\.draws)
            let moves = canvas.overlay.playheadMoves
            let before = canvas.overlay.playhead.transform.m41
            let later = model.timelineSourceTime(model.timelinePlayhead(on: axis) + 0.5, on: axis)
            model.sourceTime = later; model.playhead = model.timelineTime(source: later, on: .edited)
            canvas.followPlayhead()
            canvas.displayIfNeeded()
            lanes.forEach { $0.layer?.displayIfNeeded() }
            check("\(name) moves the playhead layer on a tick without redrawing a lane (draws \(draws) → \(lanes.map(\.draws)))",
                  draws.allSatisfy { $0 >= 1 } && lanes.map(\.draws) == draws && canvas.overlay.playheadMoves > moves && canvas.overlay.playhead.transform.m41 > before)
            // VoiceOver: the playhead slider keeps design §5.2's spoken value; In and Out adjust a word at a time.
            let children = canvas.accessibilityChildren()?.compactMap { $0 as? TimelineSliderElement } ?? []
            let labels = children.compactMap { $0.accessibilityLabel() }
            check("\(name) exposes the Playhead slider with the design's spoken value",
                  children.first?.accessibilityLabel() == "Playhead" && children.first?.accessibilityValueDescription() == model.timelineAccessibilityValue)
            check("\(name) exposes Clip \(number)'s start and end handles", labels == ["Playhead", "Clip \(number) start", "Clip \(number) end"])
            let ax = accessibility(window)
            let sliders = ax.filter { attribute($0, kAXRoleAttribute) as? String == kAXSliderRole }
            let spoken = sliders.compactMap { attribute($0, kAXValueDescriptionAttribute) as? String }
            check("\(name) reaches VoiceOver with the playhead's spoken value", ax.isEmpty || spoken.contains(model.timelineAccessibilityValue))
            check("\(name) shows the toolbar's timecode readout", ax.isEmpty || ax.contains { attribute($0, kAXIdentifierAttribute) as? String == "voxclip.timeline.time" })
            if DebugUISuite.sessionLocked {
                results.append(.init(name: "capture \(name)", passed: true, skipped: "the console session is locked"))
            } else {
                check("capture \(name)", await windowServerCapture(window, name: name, directory: directory))
            }
            canvas.tearDown()
        }
        model.showsCuts = false
        model.selectedWordIDs = []
        return results
    }

    /// A1 in a panel scene (notes.md §6), against swatches drawn the same way: on Edited the
    /// pieces on `timeline.audioPiece`, a seam at every cut in the clip, the waveform's core
    /// and nothing in silence; on Source each cut range as empty lane, with media outside
    /// In/Out at 32%.
    private static func audioChecks(name: String, canvas: TimelineCanvasView, model: EditorModel,
                                    matches: (CGFloat, CGFloat, String, CGFloat, String?) -> Bool) -> [DebugUISuite.Result] {
        var results: [DebugUISuite.Result] = []
        func check(_ label: String, _ passed: Bool) { results.append(.init(name: "\(name) \(label)", passed: passed)) }
        let lane = canvas.audio, viewport = canvas.viewport, pieces = model.timelinePieces
        let top = TimelineMetrics.audio.y, mid = top + TimelineMetrics.audio.height / 2
        func x(_ time: Double) -> CGFloat { TimelineMetrics.header + CGFloat(viewport.x(time)) }
        let laneEnd = canvas.bounds.width
        // Away from the selection's wash and the playhead, which draw over the lane.
        let selection = model.timelineSelection(on: viewport.axis), playhead = x(model.timelinePlayhead(on: viewport.axis))
        func clear(_ range: ClosedRange<Double>) -> Bool {
            x(range.lowerBound) > TimelineMetrics.header + 4 && x(range.upperBound) < laneEnd - 4 && !(selection?.overlaps(range) ?? false)
                && !(x(range.lowerBound) - 2...x(range.upperBound) + 2).contains(playhead)
        }
        if viewport.axis == .edited {
            let inside = pieces.seams.filter { clear($0 - 0.05...$0 + 0.05) }
            check("draws one seam at each cut in the clip (\(lane.drawn.seams.count) of \(pieces.seams.count))", !pieces.seams.isEmpty && lane.drawn.seams.count == pieces.seams.count)
            if let seam = inside.first { check("draws the seam in timeline.seam", matches(x(seam) - 0.5, mid, "timeline.seam", 1, nil)) }
            // A kept word of the clip, clear of the wash and the playhead.
            let words = (model.scopeBounds.map { Array(model.words[$0]) } ?? model.words).filter { !model.cutWordIDs.contains($0.id) }
            if let waveform = model.waveform, let word = words.first(where: { word in
                clear(model.timelineTime(source: word.start, on: .edited)...model.timelineTime(source: word.end, on: .edited))
            }) {
                // The word's loudest column: its core in timeline.wave, the piece above it bare.
                let offset = word.start - model.timelineTime(source: word.start, on: .edited)
                let columns = stride(from: x(word.start - offset).rounded(.up), to: x(word.end - offset) - 1, by: 1)
                let loudest = columns.max { lower, upper in
                    waveform.column(from: viewport.time(atX: Double(lower - TimelineMetrics.header)) + offset, to: viewport.time(atX: Double(lower + 1 - TimelineMetrics.header)) + offset).core
                        < waveform.column(from: viewport.time(atX: Double(upper - TimelineMetrics.header)) + offset, to: viewport.time(atX: Double(upper + 1 - TimelineMetrics.header)) + offset).core
                }
                if let loudest {
                    check("draws the waveform's core in timeline.wave", matches(loudest + 0.5, mid, "timeline.wave", 1, nil))
                    check("draws the piece on timeline.audioPiece", matches(loudest + 0.5, top + 2.25, "timeline.audioPiece", 1, nil))
                }
            }
        } else {
            let inOut = model.scopeSourceRange
            let window = viewport.visible.lowerBound..<viewport.visible.upperBound
            let expected = model.timelineRemovedRanges(pieces).filter { $0.overlaps(window) }
            check("draws each cut range in view as a removed range (\(lane.drawn.gaps.count))", !expected.isEmpty && lane.drawn.gaps == expected)
            if let gap = expected.first(where: { clear($0.lowerBound...$0.upperBound) && x($0.upperBound) - x($0.lowerBound) > 6 }) {
                check("leaves a removed range as empty lane", matches(x(gap.lowerBound) + (x(gap.upperBound) - x(gap.lowerBound)) / 2, top + 2.25, "timeline.lane", 1, nil))
            }
            let early = viewport.time(atX: 6)
            if let inOut, inOut.lowerBound - 0.01 > early, clear(early...inOut.lowerBound - 0.01) {
                check("shows media outside In/Out at 32%", matches(x(inOut.lowerBound) - 4, top + 2.25, "timeline.audioPiece", TimelineAudioLane.outsideOpacity, "timeline.lane"))
            }
        }
        check("has a waveform", lane.drawn.columns > 20)
        return results
    }

    /// A take's 10 ms envelope that sounds like its words, for scenes with no media, after
    /// the mockup's generator (ux/v2 src/model.py): each word's syllables, about 170 ms, with
    /// an attack and a release, jagged by noise correlated over about 30 ms and a slower
    /// wobble, now and then a consonant spike; a dip where words run together and silence
    /// where they do not.
    static func speech(words: [TimedWord], duration: Double) -> WaveformData {
        let rate = 1 / WaveformData.frameSeconds
        var fine = [Float](repeating: 0, count: max(1, Int((duration * rate).rounded(.up))))
        var seed: UInt32 = 0x5EED
        func random(_ lower: Float, _ upper: Float) -> Float {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return lower + (upper - lower) * Float(seed >> 8) / Float(1 << 24)
        }
        var noise: Float = 0.85, wobble: Float = 0.85
        for (index, word) in words.enumerated() {
            let first = max(0, Int(word.start * rate)), last = min(fine.count, Int(word.end * rate))
            guard first < last else { continue }
            let loud = 0.1 * random(0.7, 1.08)
            let length = last - first
            let syllables = max(1, Int((Double(length) / (0.17 * rate)).rounded()))
            var edges = [first]
            for syllable in 1..<max(1, syllables) {
                edges.append(first + Int(Float(length) * (Float(syllable) + random(-0.18, 0.18)) / Float(syllables)))
            }
            edges.append(last)
            for syllable in 0..<syllables {
                let lower = edges[syllable], span = max(1, edges[syllable + 1] - lower)
                let level = loud * random(0.55, 1.0)
                let attack = max(1, Int(Float(span) * random(0.12, 0.22))), release = max(1, Int(Float(span) * random(0.25, 0.4)))
                for frame in 0..<span where lower + frame < last {
                    let shape: Float = frame < attack ? 0.35 + 0.65 * Float(frame) / Float(attack)
                        : frame > span - release ? 0.22 + 0.78 * Float(span - frame) / Float(release)
                        : 1 - 0.15 * Float(frame - attack) / Float(max(1, span - attack - release))
                    noise = 0.55 * noise + 0.45 * random(0.66, 1.0)
                    wobble = 0.86 * wobble + 0.14 * random(0.35, 1.15)
                    fine[lower + frame] = max(0.16 * loud, level * shape * noise * min(1, wobble + 0.12))
                }
                if random(0, 1) < 0.35 { fine[lower] = max(fine[lower], loud * random(0.98, 1.14)) }
            }
            // Words that run together keep a dip between them; a pause is silence.
            if index + 1 < words.count, words[index + 1].start - word.end < 0.05 {
                for frame in last..<min(fine.count, max(last, Int(words[index + 1].start * rate))) { fine[frame] = loud * random(0.05, 0.12) }
            }
        }
        return WaveformData(fine: fine)
    }

    /// The whole panel as the window server composites it (SwiftUI toolbar and AppKit lanes).
    private static func windowServerCapture(_ window: NSWindow, name: String, directory: URL) async -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(window.windowNumber), directory.appendingPathComponent("\(name).png").path]
        guard (try? process.run()) != nil else { return false }
        while process.isRunning { try? await Task.sleep(for: .milliseconds(20)) }
        return process.terminationStatus == 0 && FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(name).png").path)
    }

    /// A red pixel: red well above green and blue (notes.md §3: no red anywhere).
    private static func hasRed(_ bitmap: NSBitmapImageRep) -> Bool {
        for row in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
            for column in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                let value = pixel(bitmap, x: column, y: row)
                if value.count == 3, value[0] > 0.55, value[1] < 0.3, value[2] < 0.3 { return true }
            }
        }
        return false
    }

    /// Budgets on a 60-minute take with 9,000 words and 1,500 cuts (impl-plan §3.1): the
    /// waveform pyramid built off the main thread within 150 ms, a full redraw within 8 ms, a
    /// playhead tick within 1 ms that redraws no lane, and zoom frames within 16.7 ms at p95.
    /// Enforced in optimized builds (`./bundle.sh profile`); a debug build records them.
    static func performance(app: AppModel, fixture: Project, directory: URL) throws -> [DebugUISuite.Result] {
        var project = fixture
        let words: [TimedWord] = (0..<9_000).map { index in
            let start = Double(index) * 0.4
            return TimedWord(id: "timeline-\(index)", text: index % 20 == 19 ? "word." : "word", start: start, end: start + 0.3)
        }
        project.transcript?.words = words
        project.transcript?.durationSeconds = 3_600
        project.media.source.durationSeconds = 3_600
        project.edits = ProjectEdits(cutWordIds: stride(from: 3, to: 9_000, by: 6).map { words[$0].id })
        let model = EditorModel(document: VoxClipDocument(project: project), app: app, preview: DemoPreviewEngine())
        defer { model.close() }
        model.mediaResolved = true; model.refresh()
        // The pyramid is built off the main thread, as the cache's load task builds it; the
        // gate waits for it.
        final class Built: @unchecked Sendable { var waveform: WaveformData?; var offMain = false }
        let envelope = speech(words: words, duration: 3_600).fine, built = Built(), done = DispatchSemaphore(value: 0)
        let pyramidStart = ContinuousClock.now
        Thread.detachNewThread {
            built.waveform = WaveformData(fine: envelope)
            built.offMain = !Thread.isMainThread
            done.signal()
        }
        done.wait()
        let pyramid = milliseconds(pyramidStart.duration(to: .now)), offMain = built.offMain
        model.waveform = built.waveform
        let canvas = TimelineCanvasView(model: model)
        defer { canvas.tearDown() }
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 1056, height: TimelineMetrics.height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = canvas
        defer { window.close() }
        canvas.layoutSubtreeIfNeeded()
        canvas.renderContent()
        canvas.displayIfNeeded()
        let lanes: [TimelineLane] = [canvas.overview, canvas.ruler, canvas.bed, canvas.audio]
        // Each lane draws through its layer at once, in or out of a shown window.
        var redraws: [Double] = []
        for _ in 0..<30 {
            let start = ContinuousClock.now
            lanes.forEach { $0.invalidate() }
            lanes.forEach { $0.layer?.displayIfNeeded() }
            redraws.append(milliseconds(start.duration(to: .now)))
        }
        let drawn = lanes.map(\.draws)
        var ticks: [Double] = []
        let edited = model.duration
        for frame in 0..<300 {
            let time = edited * Double(frame) / 300
            let start = ContinuousClock.now
            model.playhead = time; model.sourceTime = model.timelineSourceTime(time, on: .edited)
            canvas.followPlayhead()
            lanes.forEach { $0.layer?.displayIfNeeded() }
            ticks.append(milliseconds(start.duration(to: .now)))
        }
        let redrawMaximum = redraws.max() ?? 0, tickP95 = percentile(ticks, 0.95), tickMaximum = ticks.max() ?? 0
        let tickDraws = zip(lanes.map(\.draws), drawn).map { $0 - $1 }.reduce(0, +)
        // Zoom: from the fitted hour to 100 pt/s and back, on both axes, with the ruler and A1
        // drawing each frame (V9 adds the controls; the lanes' cost is this).
        var zooms: [Double] = []
        let fitted = canvas.viewport
        for axis in [TimelineAxis.edited, .source] {
            for frame in 0..<120 {
                let step = Double(frame < 60 ? frame : 119 - frame) / 59
                let zoom = fitted.ptPerSecond * pow(100 / fitted.ptPerSecond, step)
                let center = (axis == .edited ? model.duration : model.sourceDuration) / 2
                let viewport = TimelineViewport(axis: axis, ptPerSecond: zoom, origin: center - fitted.width / zoom / 2, width: fitted.width)
                let start = ContinuousClock.now
                canvas.ruler.state.viewport = viewport
                canvas.audio.state.viewport = viewport
                canvas.ruler.layer?.displayIfNeeded()
                canvas.audio.layer?.displayIfNeeded()
                zooms.append(milliseconds(start.duration(to: .now)))
            }
        }
        let zoomP95 = percentile(zooms, 0.95)
        let optimized = !_isDebugAssertConfiguration()
        let metrics: [String: Double] = ["words": 9_000, "cuts": Double(project.edits.cutWordIds.count), "fullRedrawMaximumMS": redrawMaximum,
                                         "fullRedrawMedianMS": percentile(redraws, 0.5), "tickP95MS": tickP95, "tickMaximumMS": tickMaximum,
                                         "laneDrawsDuringTicks": Double(tickDraws), "pyramidMS": pyramid, "zoomFrameP95MS": zoomP95,
                                         "zoomFrameMaximumMS": zooms.max() ?? 0, "audioColumns": Double(canvas.audio.drawn.columns), "optimized": optimized ? 1 : 0]
        try JSONEncoder().encode(metrics).write(to: directory.appendingPathComponent("timeline-performance.json"), options: .atomic)
        return [
            .init(name: "60-minute waveform pyramid builds off the main thread within 150 ms (\(String(format: "%.1f", pyramid)) ms)", passed: offMain && (!optimized || pyramid <= 150)),
            .init(name: "60-minute zoom frames draw the ruler and A1 within 16.7 ms at p95 (\(String(format: "%.2f", zoomP95)) ms)", passed: canvas.audio.drawn.columns > 100 && (!optimized || zoomP95 <= 1000.0 / 60)),
            .init(name: "60-minute timeline full redraw stays within 8 ms (\(String(format: "%.2f", redrawMaximum)) ms)", passed: drawn.allSatisfy { $0 > 1 } && (!optimized || redrawMaximum <= 8)),
            .init(name: "60-minute playhead tick stays within 1 ms (p95 \(String(format: "%.3f", tickP95)) ms)", passed: !optimized || tickP95 <= 1),
            .init(name: "60-minute playhead ticks redraw no lane (\(tickDraws) draws)", passed: tickDraws == 0)
        ]
    }
    private static func milliseconds(_ duration: Duration) -> Double { Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15 }
    private static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        let sorted = values.sorted()
        return sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * fraction))]
    }

    private static func missingCaptionPosition(app: AppModel, fixture: Project, directory: URL) async throws -> [DebugUISuite.Result] {
        var project = fixture
        project.media.source.absolutePath = directory.appendingPathComponent("missing.mov").path
        project.captions.styleId = "box-highlight"
        project.export.aspect = .landscape
        let document = VoxClipDocument(project: project)
        let shell = WorkspaceShell(app: app)
        await shell.attachForTesting(document, selection: .fullTake)
        guard let model = shell.editor, let undo = model.undoManager else { throw CocoaError(.coderInvalidValue) }
        defer { model.close(); document.updateChangeCount(.changeCleared); document.close() }
        model.mediaResolved = false
        model.previewError = "Can't find missing.mov. Edits are saved."
        var results = [DebugUISuite.Result(name: "missing-media caption position remains draggable", passed: model.canMoveCaptions)]
        let previous = model.project.captions
        undo.removeAllActions()
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let host = NSHostingView(rootView: ViewerSection(model: model, columnWidth: 360).frame(width: 360, height: 340).background(DesignValues.color("bg.surface")))
            host.frame = CGRect(x: 0, y: 0, width: 360, height: 340)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; window.appearance = NSAppearance(named: appearance)
            window.setAccessibilityIdentifier("missing-caption-\(name)")
            window.orderBack(nil); host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(150))
            let control = accessibility(window).first { attribute($0, kAXIdentifierAttribute) as? String == "voxclip.caption.position" }
            results.append(.init(name: "\(name) missing-media stage exposes the caption-position UI despite previewError", passed: control != nil))
            if name == "light", let control {
                results.append(.init(name: "missing-media caption-position control handles a native UI move", passed: AXUIElementPerformAction(control, kAXDecrementAction as CFString) == .success))
                try await Task.sleep(for: .milliseconds(80))
            }
            _ = try capture(host, name: "viewer-missing-caption-\(name)", directory: directory)
            window.close()
        }
        let moved = model.project
        let point = moved.captions.positionByAspect[model.captionPreset.rawValue]
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
        results.append(.init(name: "missing-media caption position saves through the native document path", passed: point != nil && saved.captions.positionByAspect[model.captionPreset.rawValue] == point))
        model.selectedWordIDs = Set(model.words.prefix(1).map(\.id))
        let beforeCut = model.project.edits.cutWordIds
        model.cutSelection()
        results.append(.init(name: "missing-media caption move does not unblock transcript edits or export", passed: model.project.edits.cutWordIds == beforeCut && !model.canExport))
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
        model.showsCuts = false
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
            if let index = model.timelineTrimIndex(clip, start: start, time: fraction * model.duration, on: .edited) {
                trim(start: start, index: index)
            }
            check("Edited \(edge)-edge trim keeps exact 10–20-second clip word IDs in a 60-second source (\(model.activeClip?.startWordId ?? "nil")...\(model.activeClip?.endWordId ?? "nil"), undo=\(undo.canUndo), duration=\(model.duration))", model.activeClip?.startWordId == clip.startWordId && model.activeClip?.endWordId == clip.endWordId && !undo.canUndo)
            let movedFraction: Double = start ? 0.2 : 0.8
            if let index = model.timelineTrimIndex(clip, start: start, time: movedFraction * model.duration, on: .edited) {
                trim(start: start, index: index)
            }
            check("Edited \(edge)-handle drag creates one Trim clip undo", model.activeClip != clip && undo.undoActionName == "Trim clip")
            undo.undo()
            check("one undo of the Edited \(edge)-handle drag restores both exact saved word IDs", model.activeClip == clip && !undo.canUndo)
            undo.removeAllActions()
            let nearEdge: Double = start ? 0.0000001 : 0.9999999
            if let index = model.timelineTrimIndex(clip, start: start, time: nearEdge * model.duration, on: .edited) { trim(start: start, index: index) }
            check("sample-rounded Edited \(edge) edge remains within the saved clip endpoints", model.activeClip == clip && !undo.canUndo)
        }
        undo.beginUndoGrouping()
        model.apply(.cutSelection(ids: ["trim-14"]), name: "Cut selection")
        undo.endUndoGrouping()
        undo.removeAllActions()
        let collapsedTime: Double = 4
        let inverse: Double = model.timelineSourceTime(collapsedTime, on: .edited)
        let index = model.timelineTrimIndex(clip, start: false, time: collapsedTime, on: .edited)
        check("trim and scrub share a right-continuous inverse across a collapsed cut", inverse == 15 && index == 14 && model.timelineTrimIndex(clip, start: true, time: collapsedTime, on: .edited) == 15)
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
        // No timeline shows: the model loads the waveform itself once the media is there (impl-plan §3.1).
        await model.waveformTask?.value
        model.sourceTime = 0.5; model.playhead = 0.5
        var results = [DebugUISuite.Result(name: "audio-only stage gets the decoded ten-ms envelope with no timeline shown", passed: model.waveform?.fine.count == 100)]
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
            let host = NSHostingView(rootView: ViewerSection(model: model, columnWidth: 360).frame(width: 360, height: 430).background(DesignValues.color("bg.surface")))
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
        let levelsMatch: Bool = decoded?.fine.allSatisfy { (level: Float) -> Bool in abs(level - 0.25) < 0.001 } == true
        results.append(.init(name: "off-main AVAssetReader fallback computes ten-ms linear-PCM RMS and its pyramid", passed: decoded?.fine.count == 100 && levelsMatch && decoded?.levels[1].max.count == 25))
        return results
    }
    private static func capture(_ view: NSView, name: String, directory: URL) throws -> NSBitmapImageRep {
        let bitmap = try sRGBBitmap(of: view)
        if let data = bitmap.representation(using: .png, properties: [:]) { try data.write(to: directory.appendingPathComponent("\(name).png")) }
        return bitmap
    }
    /// `view` as its window draws it (lanes and their layers), read back in sRGB.
    static func sRGBBitmap(of view: NSView) throws -> NSBitmapImageRep {
        view.layoutSubtreeIfNeeded()
        guard let cached = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CocoaError(.coderInvalidValue) }
        view.cacheDisplay(in: view.bounds, to: cached)
        guard let image = cached.cgImage, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CocoaError(.coderInvalidValue) }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let converted = context.makeImage() else { throw CocoaError(.coderInvalidValue) }
        return NSBitmapImageRep(cgImage: converted)
    }
    /// What `token`, at `alpha` over `ground`, reads back as through the same path as a
    /// lane: a view filled with it in a window like the panel's. Colour management treats
    /// both alike, so pixel checks compare like with like.
    static func swatch(_ token: String, alpha: CGFloat = 1, over ground: String? = nil, appearance: NSAppearance.Name = .darkAqua) throws -> [Double] {
        final class Swatch: NSView {
            var paint: () -> Void = {}
            override func draw(_ dirtyRect: NSRect) { paint() }
        }
        let view = Swatch(frame: NSRect(x: 0, y: 0, width: 8, height: 8))
        view.paint = {
            if let ground { DesignValues.nsColor(ground).setFill(); view.bounds.fill() }
            DesignValues.nsColor(token).withAlphaComponent(DesignValues.nsColor(token).alphaComponent * alpha).setFill()
            view.bounds.fill(using: .sourceOver)
        }
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 8, height: 8), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = view
        defer { window.close() }
        let bitmap = try sRGBBitmap(of: view)
        return pixel(bitmap, x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)
    }
    static func pixel(_ bitmap: NSBitmapImageRep, x: Int, y: Int) -> [Double] {
        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return [] }
        return [color.redComponent, color.greenComponent, color.blueComponent]
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
