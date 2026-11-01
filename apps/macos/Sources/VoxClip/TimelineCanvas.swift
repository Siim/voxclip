import AppKit
import QuartzCore
import VoxClipCore

// The v2 timeline's AppKit lanes (ux/v2 notes.md §6, impl-plan V7a, V7b and V9): overview,
// ruler with In/Out, V1 filmstrip, A1 audio, CC cues, FX Motion, headers, scrollers and playhead. No view is wider
// than the panel: the viewport maps time to points, and each lane draws only what it shows.
// The playhead is its own layer, moved by transform, so playback never redraws a lane.

/// The panel's rows below its toolbar, in points from the canvas top (notes.md §6).
enum TimelineMetrics {
    struct Row: Equatable {
        let y: CGFloat
        let height: CGFloat
        var maxY: CGFloat { y + height }
    }
    static let toolbar: CGFloat = 28
    /// The track headers' column. Lanes start after it.
    static let header: CGFloat = 112
    /// Lane after a fitted range, where the Out bracket and the last label sit (notes.md:
    /// 936 pt of time in a 944 pt lane).
    static let trailing: CGFloat = 8
    /// How near the pointer In, Out or a closed cut's seam must be to take a drag or a double-click.
    static let reach: CGFloat = 5
    static let overview = Row(y: 0, height: 24)
    static let ruler = Row(y: 24, height: 22)
    /// V1, A1, CC and FX at the default track height (M).
    static let tracks = [Row(y: 47, height: 36), Row(y: 84, height: 44), Row(y: 129, height: 24), Row(y: 154, height: 24)]
    static func rows(_ height: TrackHeight) -> [Row] {
        var y: CGFloat = 47
        return height.heights.map { value in
            defer { y += value + 1 }
            return Row(y: y, height: value)
        }
    }
    static var audio: Row { tracks[1] }
    static var tracksEnd: CGFloat { tracks.last?.maxY ?? ruler.maxY }
    /// The panel's default height less the toolbar.
    static let height: CGFloat = 188
}

/// What the lanes show of one axis: points per second and the time at the lane's left edge.
struct TimelineViewport: Equatable {
    var axis: TimelineAxis
    var ptPerSecond: Double
    /// Seconds on `axis` at the lane's x 0.
    var origin: Double
    /// The lane's width in points, after the track headers.
    var width: Double

    /// A fitted range keeps this much lane before and after it (f1: -1.0 s to 44.2 s).
    static let margin = 1.0

    func x(_ time: Double) -> Double { (time - origin) * ptPerSecond }
    func time(atX x: Double) -> Double { origin + x / ptPerSecond }
    var visible: ClosedRange<Double> { origin...(origin + max(0, width) / ptPerSecond) }

    /// `range` with a second of lane before and after it, in the lane less its trailing room.
    static func fitting(_ range: ClosedRange<Double>, width: Double, axis: TimelineAxis) -> TimelineViewport {
        let span = max(1, range.upperBound - range.lowerBound) + 2 * margin
        let usable = max(1, width - Double(TimelineMetrics.trailing))
        return TimelineViewport(axis: axis, ptPerSecond: usable / span, origin: range.lowerBound - margin, width: width)
    }

    /// The same zoom on `axis`, starting a second before `start` (notes.md §6: Source keeps
    /// Edited's points per second; only the axis changes).
    func switched(to axis: TimelineAxis, start: Double) -> TimelineViewport {
        TimelineViewport(axis: axis, ptPerSecond: ptPerSecond, origin: start - Self.margin, width: width)
    }

    /// Pages so `time` shows: when it is off either edge, the window starts a second before it.
    func showing(_ time: Double) -> TimelineViewport {
        let end = origin + max(0, width - Double(TimelineMetrics.trailing)) / ptPerSecond
        guard time.isFinite, time < origin || time > end else { return self }
        var next = self
        next.origin = time - Self.margin
        return next
    }

    /// Scrolled by `points` (positive is later), kept within `content` and its margins.
    func panned(by points: Double, within content: ClosedRange<Double>) -> TimelineViewport {
        var next = self
        let lower = content.lowerBound - Self.margin
        let upper = max(lower, content.upperBound + Self.margin - max(0, width - Double(TimelineMetrics.trailing)) / ptPerSecond)
        next.origin = (origin + points / ptPerSecond).clamped(to: lower...upper)
        return next
    }
}

/// What the timeline shows of the editor, taken from the model when it changes.
struct TimelineContent: Equatable {
    var axis = TimelineAxis.edited
    /// The axis's length: the scope's output on Edited, the take on Source.
    var length = 0.0
    var takeLength = 0.0
    /// The open clip, or nil on Full Take.
    var scope: String?
    /// The open clip in take time.
    var scopeSource: ClosedRange<Double>?
    /// In and Out on the axis.
    var inOut: ClosedRange<Double>?
    /// The selection on the axis.
    var selection: ClosedRange<Double>?
    var cues: [TimelineCue] = []
    var clips: [TimelineOverviewClip] = []
    /// The scope's pieces and the take's waveform, for A1, and on Source the cut ranges in it.
    var pieces = TimelinePieces([])
    var waveform: WaveformData?
    var removed: [Range<Double>] = []
    /// The scope's kept words in take time while there is no waveform (design §5.4.10).
    var words: [Range<Double>] = []
}

/// The lanes and the playhead for one editor. It follows the model by itself: content
/// changes redraw the lanes that show them; playhead changes move only the playhead layers.
@MainActor final class TimelineCanvasView: NSView {
    let model: EditorModel
    let shell: WorkspaceShell?
    var headerWidth: CGFloat { (shell?.layout.windowWidth ?? Double(window?.frame.width ?? bounds.width)) < 1000 ? 64 : TimelineMetrics.header }
    let video = VideoLane()
    let captions = CaptionLane()
    let motion = MotionLane()
    let trackClip = TimelineTrackClip()
    let headers = [TrackHeaderView(id: "V1", name: "Video"), TrackHeaderView(id: "A1", name: "Voice"), TrackHeaderView(id: "CC", name: "Captions"), TrackHeaderView(id: "FX", name: "Motion")]
    let horizontalScroller = TimelineScroller()
    let verticalScroller = TimelineScroller()
    var trackHeight: TrackHeight { shell?.layout.trackHeight ?? .medium }
    private(set) var verticalOffset = 0.0
    var onZoom: ((Double) -> Void)?
    private var zoomStep = 0
    let overview = TimelineOverviewLane()
    let ruler = TimelineRulerLane()
    let bed = TimelineTrackBed()
    let audio = TimelineAudioLane()
    let overlay = TimelineOverlayView()
    private(set) var viewport = TimelineViewport(axis: .edited, ptPerSecond: 20, origin: -TimelineViewport.margin, width: 944)
    private(set) var content = TimelineContent()
    /// The viewport fits the scope's Edited length and follows it; a pan that moves the
    /// view ends that until the scope or the take changes.
    private var fitted = true
    private var observations: [ShellObservation] = []
    lazy var interaction = TimelineInteraction(canvas: self)
    private let playheadElement = TimelineSliderElement()
    private let inElement = TimelineSliderElement()
    private let outElement = TimelineSliderElement()
    private let zoomElement = TimelineSliderElement()
    private let selectionElement = TimelineSelectionElement()

    init(model: EditorModel, shell: WorkspaceShell? = nil) {
        self.model = model
        self.shell = shell
        zoomStep = model.timelineZoomStep
        super.init(frame: NSRect(x: 0, y: 0, width: 1056, height: TimelineMetrics.height))
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        identifier = NSUserInterfaceItemIdentifier("voxclip.timeline.canvas")
        for lane in [overview, ruler, bed] as [NSView] { addSubview(lane) }
        addSubview(trackClip)
        for lane in [video, audio, captions, motion] as [NSView] { trackClip.addSubview(lane) }
        for header in headers { trackClip.addSubview(header) }
        headers[1].action = { [weak model] in
            guard let model else { return }
            let muted: Bool = model.previewMuted
            model.previewMuted = !muted
        }
        headers[2].action = { [weak model] in
            guard let model else { return }
            model.setCaptionsEnabled(model.project.captions.styleId == "off")
        }
        addSubview(overlay)
        addSubview(horizontalScroller); addSubview(verticalScroller)
        horizontalScroller.changed = { [weak self] fraction in self?.scroll(to: fraction) }
        verticalScroller.vertical = true
        verticalScroller.changed = { [weak self] fraction in
            guard let self else { return }
            self.verticalOffset = fraction * self.verticalMaximum
            self.layoutLanes()
        }
        configureAccessibility()
        toolTip = "Click to seek. Drag to select words. Option-drag bypasses snapping. Double-click a cut to restore it."
        layoutLanes()
        observations = [
            ShellObservation { [weak self] in self?.renderContent() },
            ShellObservation { [weak self] in self?.followPlayhead() },
            ShellObservation { [weak self] in
                guard let self else { return }
                let next = model.timelineZoomStep
                let delta = next - self.zoomStep
                self.zoomStep = next
                if delta != 0 { self.zoom(by: pow(1.4, Double(delta))) }
            },
            ShellObservation { [weak self] in
                guard let self else { return }
                _ = self.shell?.layout.trackHeight
                _ = self.shell?.layout.windowWidth
                self.headers[1].update(on: !model.previewMuted, enabled: true)
                self.headers[2].update(on: model.project.captions.styleId != "off", enabled: model.capabilities.writable)
                self.layoutLanes()
            }
        ]
    }
    required init?(coder: NSCoder) { nil }

    func tearDown() {
        observations.forEach { $0.cancel() }
        observations = []
        interaction.cancel()
        video.cancelLoads()
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool {
        model.focusedPane = .timeline
        return true
    }

    /// The lane's width after the headers.
    private var laneWidth: Double { max(1, Double(bounds.width - headerWidth)) }

    override func layout() {
        super.layout()
        layoutLanes()
    }

    private func layoutLanes() {
        let width = bounds.width
        overview.frame = NSRect(x: 0, y: TimelineMetrics.overview.y, width: width, height: TimelineMetrics.overview.height)
        ruler.frame = NSRect(x: 0, y: TimelineMetrics.ruler.y, width: width, height: TimelineMetrics.ruler.height)
        bed.frame = NSRect(x: 0, y: TimelineMetrics.ruler.maxY, width: width, height: max(0, bounds.height - TimelineMetrics.ruler.maxY))
        let rows = TimelineMetrics.rows(trackHeight)
        var trackRoom = max(0, bounds.height - TimelineMetrics.ruler.maxY - 10)
        if bounds.height + TimelineMetrics.toolbar < 184 {
            // Keep CC and FX wholly below the fold in short panels; vertical scrolling reveals it.
            trackRoom = min(trackRoom, rows[1].maxY - TimelineMetrics.ruler.maxY)
        }
        trackClip.frame = NSRect(x: 0, y: TimelineMetrics.ruler.maxY, width: width, height: trackRoom)
        verticalOffset = verticalOffset.clamped(to: 0...verticalMaximum)
        for (index, lane) in ([video, audio, captions, motion] as [TimelineLane]).enumerated() {
            let row = rows[index]
            lane.frame = NSRect(x: 0, y: row.y - TimelineMetrics.ruler.maxY - verticalOffset, width: width, height: row.height)
            headers[index].frame = NSRect(x: 0, y: lane.frame.minY, width: headerWidth - 1, height: row.height)
        }
        for lane in [overview, ruler, bed, video, audio, captions, motion] as [TimelineLane] { lane.headerWidth = headerWidth }
        overlay.headerWidth = headerWidth
        overlay.line.frame.size.height = max(0, min(trackClip.frame.maxY, rows.last!.maxY - verticalOffset) - TimelineMetrics.ruler.maxY + 1)
        overlay.frame = bounds
        if abs(viewport.width - laneWidth) > 0.5 {
            viewport = fitted ? fittedViewport(for: content) : TimelineViewport(axis: viewport.axis, ptPerSecond: viewport.ptPerSecond, origin: viewport.origin, width: laneWidth)
        }
        apply()
    }

    // MARK: Following the model

    /// Takes what the lanes show from the model. A new scope or take fits the viewport
    /// again. While it is fitted, Edited fits again when its length changes (a cut, a
    /// restore or a trim) or when it comes back from Source; `keepingZoom` skips that once,
    /// so an edge dropped on the timeline stays under the pointer. Source is take time,
    /// which cuts and trims do not move, so it keeps its view. A new axis keeps the zoom.
    /// It reads no playhead, so playback never runs it.
    func renderContent(keepingZoom: Bool = false) {
        _ = model.transcriptRevision
        interaction.reconcile()
        let axis = model.timelineAxis
        var next = TimelineContent()
        next.axis = axis
        next.length = model.timelineLength(on: axis)
        next.takeLength = model.sourceDuration
        next.scope = model.scopeBounds == nil ? nil : model.activeClip?.id
        next.scopeSource = model.scopeSourceRange
        next.inOut = model.timelineInOut(on: axis)
        next.selection = model.timelineSelection(on: axis)
        next.clips = model.timelineOverviewClips
        next.pieces = model.timelinePieces
        next.waveform = model.waveform
        next.removed = axis == .source ? model.timelineRemovedRanges(next.pieces) : []
        next.words = next.waveform == nil ? model.timelineKeptWords : []
        next.cues = model.timelineCaptionCues(on: axis, removed: next.removed)
        video.setSource(model.timelineFilmstripSource)
        video.mediaName = model.timelineMediaName
        let previous = content
        content = next
        if !rendered || next.scope != previous.scope || next.takeLength != previous.takeLength {
            rendered = true
            fitted = true
            viewport = fittedViewport(for: next)
        } else if fitted, !keepingZoom, next.axis == .edited, next.axis != previous.axis || next.length != previous.length {
            viewport = fittedViewport(for: next)
        } else if next.axis != previous.axis {
            viewport = viewport.switched(to: next.axis, start: next.axis == .source ? next.scopeSource?.lowerBound ?? 0 : 0)
        }
        apply()
    }
    /// The first content has been taken, so later ones keep the viewport unless the scope changes.
    private var rendered = false
    /// The playhead's last times, kept by `followPlayhead`, so drawing reads no playhead.
    private var playheadEdited = 0.0
    private var playheadSource = 0.0
    private var playheadTime: Double { content.axis == .edited ? playheadEdited : playheadSource }

    /// The viewport that fits the scope: its output on Edited; on Source the same zoom,
    /// from a second before the clip.
    private func fittedViewport(for content: TimelineContent) -> TimelineViewport {
        let edited = TimelineViewport.fitting(0...max(1, model.duration), width: laneWidth, axis: .edited)
        guard content.axis == .source else { return edited }
        return edited.switched(to: .source, start: content.scopeSource?.lowerBound ?? 0)
    }

    /// Follows the playhead: moves its layers, and pages the viewport when it leaves it.
    func followPlayhead() {
        playheadEdited = model.playhead
        playheadSource = model.sourceTime
        let paged = viewport.showing(playheadTime)
        // A scrub or a trim keeps the view under the pointer; an overview drag pages it.
        if paged != viewport, interaction.followsPlayhead {
            viewport = paged
            apply()
        } else {
            placePlayhead()
        }
    }

    private func placePlayhead() {
        let overviewX = overview.x(playheadSource)
        overlay.movePlayhead(laneX: viewport.x(playheadTime), overviewX: overviewX)
        let x = headerWidth + viewport.x(playheadTime).clamped(to: 0...laneWidth)
        playheadElement.setAccessibilityFrameInParentSpace(NSRect(x: x - 5, y: TimelineMetrics.ruler.y, width: 10, height: max(22, trackClip.frame.maxY - TimelineMetrics.ruler.y)))
        overlay.placeOverviewLabels(overview.labels(playheadX: overviewX), top: TimelineMetrics.overview.y)
    }

    /// Gives each lane what it draws. A lane redraws only when its own input changed.
    func apply() {
        let window: ClosedRange<Double>
        let visible = viewport.visible
        if content.axis == .source { window = visible }
        else {
            let lower = model.timelineSourceTime(max(0, visible.lowerBound), on: .edited)
            let upper = model.timelineSourceTime(min(content.length, visible.upperBound), on: .edited)
            window = lower...max(lower, upper)
        }
        overview.state = TimelineOverviewLane.State(clips: content.clips, takeLength: content.takeLength, window: window,
                                                    takeLabel: durationLabel(content.takeLength))
        ruler.state = TimelineRulerLane.State(viewport: viewport, inOut: shownInOut, selection: interaction.selection ?? content.selection)
        bed.state = TimelineTrackBed.State(width: Double(bounds.width))
        // On Source A1 dims outside the In/Out the ruler shows, the dragged edge included.
        audio.state = TimelineAudioLane.State(viewport: viewport, pieces: content.pieces, waveform: content.waveform, removed: content.removed,
                                              words: content.words, inOut: content.axis == .source ? shownInOut : nil,
                                              clip: content.axis == .source ? content.inOut : nil, takeLength: content.takeLength)
        video.state = VideoLane.State(viewport: viewport, pieces: content.pieces, inOut: content.axis == .source ? shownInOut : nil,
                                      clip: content.axis == .source ? content.inOut : nil, takeLength: content.takeLength)
        video.requestFrames()
        captions.state = CaptionLane.State(viewport: viewport, cues: content.cues, inOut: content.axis == .source ? shownInOut : nil)
        updateScrollers()
        onZoom?(zoomValue)
        let top = TimelineMetrics.tracks.first?.y ?? TimelineMetrics.ruler.maxY
        overlay.showWash((interaction.selection ?? content.selection).map { range in
            let lower = viewport.x(range.lowerBound), upper = viewport.x(range.upperBound)
            return NSRect(x: lower, y: top, width: max(0, upper - lower), height: max(0, min(trackClip.frame.maxY, TimelineMetrics.rows(trackHeight).last!.maxY - verticalOffset) - top))
        })
        placePlayhead()
        layoutAccessibility()
    }

    /// In and Out on the axis, with the edge being dragged at the word it would land on.
    private var shownInOut: ClosedRange<Double>? { interaction.inOut(content.inOut) }

    // MARK: Pointer and keys

    override func mouseDown(with event: NSEvent) { interaction.mouseDown(event) }
    override func mouseDragged(with event: NSEvent) { interaction.mouseDragged(event) }
    override func mouseUp(with event: NSEvent) { interaction.mouseUp(event) }

    #if DEBUG
    func auditViewport(_ next: TimelineViewport) { fitted = false; viewport = next; apply() }
    #endif
    var verticalMaximum: Double {
        max(0, Double(TimelineMetrics.rows(trackHeight).last!.maxY - TimelineMetrics.ruler.maxY) - trackClip.bounds.height)
    }
    var zoomMinimum: Double { TimelineViewport.fitting(0...max(1, model.duration), width: laneWidth, axis: content.axis).ptPerSecond }
    var zoomMaximum: Double { max(300, zoomMinimum * 8) }
    var zoomValue: Double { log(max(zoomMinimum, viewport.ptPerSecond) / zoomMinimum) / log(zoomMaximum / zoomMinimum) }
    func setZoom(_ value: Double) { zoom(by: zoomMinimum * pow(zoomMaximum / zoomMinimum, value.clamped(to: 0...1)) / viewport.ptPerSecond) }
    func zoom(by factor: Double, anchor: Double? = nil) {
        guard factor.isFinite, factor > 0 else { return }
        interaction.cancel()
        let x = anchor ?? viewport.x(playheadTime).clamped(to: 0...laneWidth)
        let time = viewport.time(atX: x)
        viewport.ptPerSecond = (viewport.ptPerSecond * factor).clamped(to: zoomMinimum...zoomMaximum)
        viewport.origin = time - x / viewport.ptPerSecond
        viewport = viewport.panned(by: 0, within: 0...max(content.length, 1))
        fitted = false
        apply()
    }
    func pan(by points: Double) {
        let next = viewport.panned(by: points, within: 0...max(content.length, 1))
        guard next != viewport else { return }
        interaction.cancel()
        fitted = false; viewport = next; apply()
    }
    func scroll(to fraction: Double) {
        let span = max(0, content.length + 2 - viewport.width / viewport.ptPerSecond)
        let origin = -1 + fraction.clamped(to: 0...1) * span
        pan(by: (origin - viewport.origin) * viewport.ptPerSecond)
    }
    private func updateScrollers() {
        let total = max(1, content.length + 2)
        let visible = viewport.width / viewport.ptPerSecond
        horizontalScroller.frame = NSRect(x: headerWidth + 4, y: bounds.height - 8, width: max(0, bounds.width - headerWidth - 12), height: 8)
        horizontalScroller.update(portion: visible / total, fraction: (viewport.origin + 1) / max(1e-9, total - visible))
        verticalScroller.frame = NSRect(x: bounds.width - 8, y: TimelineMetrics.ruler.maxY, width: 8, height: trackClip.bounds.height)
        verticalScroller.update(portion: trackClip.bounds.height / max(1, trackClip.bounds.height + verticalMaximum), fraction: verticalOffset / max(1, verticalMaximum))
    }
    override func magnify(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        zoom(by: max(0.1, 1 + event.magnification), anchor: Double(point.x - headerWidth).clamped(to: 0...laneWidth))
    }
    override func scrollWheel(with event: NSEvent) {
        let scale = event.hasPreciseScrollingDeltas ? 1.0 : 10.0
        let horizontal = event.scrollingDeltaX != 0 ? event.scrollingDeltaX : (event.modifierFlags.contains(.shift) ? event.scrollingDeltaY : 0)
        if horizontal != 0 { pan(by: -horizontal * scale) }
        else if event.scrollingDeltaY != 0, verticalMaximum > 0 {
            verticalOffset = (verticalOffset - event.scrollingDeltaY * scale).clamped(to: 0...verticalMaximum)
            layoutLanes()
        } else { super.scrollWheel(with: event) }
    }

    override func keyDown(with event: NSEvent) {
        if !interaction.keyDown(event) { super.keyDown(with: event) }
    }
    @discardableResult static func handleKey(_ code: UInt16, shift: Bool, model: EditorModel) -> Bool {
        TimelineInteraction.handleKey(code, shift: shift, model: model)
    }

    // MARK: Accessibility

    /// The playhead slider (its spoken value is design §5.2's) and, while a clip is open,
    /// its In and Out handles, which VoiceOver adjusts a word at a time.
    private func configureAccessibility() {
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Timeline")
        playheadElement.setAccessibilityParent(self)
        playheadElement.setAccessibilityLabel("Playhead")
        playheadElement.setAccessibilityIdentifier("voxclip.timeline.playhead")
        playheadElement.read = { [weak self] in
            guard let self else { return (0, 0...0, "") }
            let axis = self.model.timelineAxis
            return (self.model.timelinePlayhead(on: axis), 0...max(0, self.model.timelineLength(on: axis)), self.model.timelineAccessibilityValue)
        }
        playheadElement.adjust = { [weak self] up in _ = self?.model.stepTimeline(up ? 1 : -1, sentence: false) }
        zoomElement.setAccessibilityParent(self)
        zoomElement.setAccessibilityLabel("Timeline zoom")
        zoomElement.setAccessibilityIdentifier("voxclip.timeline.canvas.zoom")
        zoomElement.read = { [weak self] in
            guard let self else { return (0, 0...1, "") }
            return (self.zoomValue, 0...1, "\(Int((self.zoomValue * 100).rounded())) percent")
        }
        zoomElement.adjust = { [weak self] up in self?.zoom(by: up ? 1.4 : 1 / 1.4) }
        selectionElement.setAccessibilityParent(self)
        selectionElement.setAccessibilityIdentifier("voxclip.timeline.selection")
        selectionElement.read = { [weak self] in
            guard let self, let range = self.model.timelineSelection(on: self.model.timelineAxis) else { return "No selection" }
            return "\(self.model.selectedWordIDs.count) words, \(timelineSpokenTime(range.lowerBound)) to \(timelineSpokenTime(range.upperBound)), \(self.model.timelineAxis == .source ? "source" : "edited")"
        }
        for (element, start) in [(inElement, true), (outElement, false)] {
            element.setAccessibilityParent(self)
            element.setAccessibilityIdentifier(start ? "voxclip.timeline.in" : "voxclip.timeline.out")
            element.read = { [weak self] in
                guard let self, let clip = self.model.activeClip, let index = self.model.index(start ? clip.startWordId : clip.endWordId),
                      self.model.words.indices.contains(index) else { return (0, 0...0, "") }
                let source = start ? self.model.words[index].start : self.model.words[index].end
                return (source, 0...max(0, self.model.sourceDuration), timecode(source))
            }
            element.adjust = { [weak self] up in self?.model.adjustTrim(start: start, offset: up ? 1 : -1) }
        }
    }

    private func layoutAccessibility() {
        let inOut = shownInOut
        let playheadX = headerWidth + viewport.x(playheadTime).clamped(to: 0...laneWidth)
        playheadElement.setAccessibilityFrameInParentSpace(NSRect(x: playheadX - 5, y: TimelineMetrics.ruler.y, width: 10, height: max(22, trackClip.frame.maxY - TimelineMetrics.ruler.y)))
        zoomElement.setAccessibilityFrameInParentSpace(NSRect(x: headerWidth, y: 0, width: laneWidth, height: TimelineMetrics.overview.height))
        let laneRuler = NSRect(x: headerWidth, y: TimelineMetrics.ruler.y, width: laneWidth, height: TimelineMetrics.ruler.height)
        let selection = content.selection.map { NSRect(x: headerWidth + viewport.x($0.lowerBound), y: laneRuler.minY, width: max(1, viewport.x($0.upperBound) - viewport.x($0.lowerBound)), height: laneRuler.height).intersection(laneRuler) } ?? laneRuler
        selectionElement.setAccessibilityFrameInParentSpace(selection.isNull ? laneRuler : selection)
        if let inOut, let number = model.activeClip.flatMap({ model.clipNumber($0.id) }) {
            inElement.setAccessibilityLabel("Clip \(number) start")
            outElement.setAccessibilityLabel("Clip \(number) end")
            for (element, time) in [(inElement, inOut.lowerBound), (outElement, inOut.upperBound)] {
                let x = headerWidth + viewport.x(time)
                element.setAccessibilityFrameInParentSpace(NSRect(x: x - 5, y: TimelineMetrics.ruler.y, width: 10, height: TimelineMetrics.ruler.height))
            }
        }
    }

    override func accessibilityChildren() -> [Any]? {
        let times: [Any] = content.inOut == nil || model.activeClip == nil ? [playheadElement] : [playheadElement, inElement, outElement]
        return times + [selectionElement, zoomElement] + headers + [horizontalScroller, verticalScroller].filter { !$0.isHidden }
    }
}

/// Spoken selection summary reads the same IDs as the transcript, including folded cuts.
final class TimelineSelectionElement: NSAccessibilityElement {
    nonisolated(unsafe) var read: @MainActor () -> String = { "No selection" }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityLabel() -> String? { "Timeline selection" }
    override func accessibilityValue() -> Any? {
        let read = read
        return MainActor.assumeIsolated { read() }
    }
}

/// An adjustable time on the timeline for VoiceOver: the playhead, In or Out. AppKit asks
/// for accessibility on the main thread.
final class TimelineSliderElement: NSAccessibilityElement {
    /// Set once on the main actor, before VoiceOver can ask.
    nonisolated(unsafe) var read: @MainActor () -> (value: Double, range: ClosedRange<Double>, spoken: String) = { (0, 0...0, "") }
    nonisolated(unsafe) var adjust: @MainActor (Bool) -> Void = { _ in }
    private func value() -> (value: Double, range: ClosedRange<Double>, spoken: String) {
        let read = read
        return MainActor.assumeIsolated { read() }
    }
    private func step(_ up: Bool) -> Bool {
        let adjust = adjust
        MainActor.assumeIsolated { adjust(up) }
        return true
    }
    override func accessibilityRole() -> NSAccessibility.Role? { .slider }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityValue() -> Any? { NSNumber(value: value().value) }
    override func accessibilityMinValue() -> Any? { NSNumber(value: value().range.lowerBound) }
    override func accessibilityMaxValue() -> Any? { NSNumber(value: value().range.upperBound) }
    override func accessibilityValueDescription() -> String? { value().spoken }
    override func accessibilityPerformIncrement() -> Bool { step(true) }
    override func accessibilityPerformDecrement() -> Bool { step(false) }
}

// MARK: - Lanes

/// A lane: a flipped, layer-backed view that draws only when its state changes and never
/// takes the pointer (the canvas does). `invalidations` and `draws` count for the
/// playhead-without-redraw checks.
@MainActor class TimelineLane: NSView {
    var headerWidth = TimelineMetrics.header { didSet { if oldValue != headerWidth { invalidate() } } }
    private(set) var invalidations = 0
    private(set) var draws = 0
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
    func invalidate() { invalidations += 1; needsDisplay = true }
    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { invalidate() }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        invalidate()
    }
    override func draw(_ dirtyRect: NSRect) {
        draws += 1
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        // Only within the lane: a cached display can ask for more than its bounds.
        DesignValues.nsColor("bg.window").setFill()
        dirtyRect.intersection(bounds).fill()
        context.saveGState()
        context.clip(to: bounds)
        drawLane(in: context)
        context.restoreGState()
        // The headers' hairline (notes.md §6: 1 pt line.default beside the 112 pt headers).
        DesignValues.nsColor("line.default").setFill()
        NSRect(x: headerWidth - 1, y: 0, width: 1, height: bounds.height).fill()
    }
    func drawLane(in context: CGContext) {}

    /// `string` with its baseline at `baseline`.
    static func draw(_ string: String, font: NSFont, color: NSColor, x: CGFloat, baseline: CGFloat) {
        NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color]).draw(at: NSPoint(x: x, y: baseline - font.ascender))
    }
    static func width(_ string: String, font: NSFont) -> CGFloat { NSAttributedString(string: string, attributes: [.font: font]).size().width }
}

/// A clip's number in the overview strip, drawn by the overlay so that stepping it off the
/// playhead moves a layer instead of redrawing the strip.
struct TimelineOverviewLabel: Equatable {
    let text: String
    let x: CGFloat
    let baseline: CGFloat
    /// The open tab's clip: t1; the others t2.
    let open: Bool
}

/// The overview strip (notes.md §6): the whole take as a flat lane, every clip as a block
/// and the visible window. The overlay draws the block labels and the playhead.
@MainActor final class TimelineOverviewLane: TimelineLane {
    struct State: Equatable {
        var clips: [TimelineOverviewClip] = []
        var takeLength = 0.0
        /// The viewport in take time.
        var window: ClosedRange<Double>?
        var takeLabel = ""
    }
    var state = State() {
        didSet {
            guard state != oldValue else { return }
            if state.clips != oldValue.clips { rows = TimelineOverview.rows(for: state.clips.map(\.source)) }
            invalidate()
        }
    }
    /// Each clip's row: overlapping clips and proposals stack.
    private var rows: [Int] = []
    static let labelFont = VCType.mini.nsMono()

    private var laneWidth: CGFloat { max(1, bounds.width - headerWidth - TimelineMetrics.trailing) }
    func x(_ time: Double) -> CGFloat {
        headerWidth + CGFloat(time / max(0.001, state.takeLength)) * laneWidth
    }
    func time(atX x: CGFloat) -> Double { Double((x - headerWidth) / laneWidth) * state.takeLength }
    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize.width != frame.width
        super.setFrameSize(newSize)
        if changed { invalidate() }
    }

    /// The bands blocks sit in: one 10 pt band, or two 8 pt bands once clips overlap.
    private var bands: [(y: CGFloat, height: CGFloat)] { rows.contains { $0 > 0 } ? [(3.5, 8), (12.5, 8)] : [(7, 10)] }
    private func band(_ index: Int) -> (y: CGFloat, height: CGFloat) {
        let bands = bands
        return bands[min(rows.indices.contains(index) ? rows[index] : 0, bands.count - 1)]
    }

    /// The block labels, in lane coordinates: in blocks of 14 pt or more, 4 pt in, stepping
    /// 5 pt past the playhead when they would sit under it (notes.md §6).
    func labels(playheadX: CGFloat) -> [TimelineOverviewLabel] {
        state.clips.enumerated().compactMap { index, clip in
            let lower = x(clip.source.lowerBound), upper = x(clip.source.upperBound)
            guard upper - lower >= 14 else { return nil }
            let start = lower + 4
            let band = band(index)
            return TimelineOverviewLabel(text: String(clip.number), x: start - 3 <= playheadX && playheadX <= start + 8 ? playheadX + 5 : start,
                                         baseline: band.y + band.height / 2 + 3.2, open: clip.open)
        }
    }

    override func drawLane(in context: CGContext) {
        let lane = NSRect(x: headerWidth, y: 2, width: laneWidth, height: 20)
        DesignValues.nsColor("timeline.lane").setFill()
        NSBezierPath(roundedRect: lane, xRadius: 2, yRadius: 2).fill()
        let paper = DesignValues.nsColor("clip.label")
        for (index, clip) in state.clips.enumerated() {
            let band = band(index)
            let lower = x(clip.source.lowerBound), upper = x(clip.source.upperBound)
            if clip.proposal {
                let block = NSBezierPath(roundedRect: NSRect(x: lower + 0.5, y: band.y + 0.5, width: max(0, upper - lower - 1), height: band.height - 1), xRadius: 1.5, yRadius: 1.5)
                paper.withAlphaComponent(clip.open ? 0.22 : 0.05).setFill()
                block.fill()
                block.lineWidth = 1
                block.setLineDash([2, 1.6], count: 2, phase: 0)
                paper.withAlphaComponent(0.6).setStroke()
                block.stroke()
            } else {
                paper.withAlphaComponent(clip.open ? 0.42 : 0.24).setFill()
                NSBezierPath(roundedRect: NSRect(x: lower, y: band.y, width: max(0, upper - lower), height: band.height), xRadius: 1.5, yRadius: 1.5).fill()
            }
        }
        if let window = state.window {
            let lower = x(window.lowerBound), upper = x(window.upperBound)
            let frame = NSBezierPath(roundedRect: NSRect(x: lower - 2, y: 1.5, width: max(0, upper - lower) + 4, height: 21), xRadius: 2.5, yRadius: 2.5)
            frame.lineWidth = 1
            DesignValues.nsColor("text.secondary").setStroke()
            frame.stroke()
        }
        // The header: "Take" and its length (f1).
        Self.draw("Take", font: VCType.small.nsFont(), color: DesignValues.nsColor("text.tertiary"), x: 10, baseline: 16)
        let length = VCType.label.nsMono()
        Self.draw(state.takeLabel, font: length, color: DesignValues.nsColor("text.disabled"), x: headerWidth - 6 - Self.width(state.takeLabel, font: length), baseline: 16)
    }
}

/// The ruler (notes.md §6): Resolve-style timecode labels in its top half, 1 s ticks, the
/// selection bar, In/Out brackets the full height, and darker ground outside In/Out. The
/// playhead's head is the overlay's.
@MainActor final class TimelineRulerLane: TimelineLane {
    struct State: Equatable {
        var viewport = TimelineViewport(axis: .edited, ptPerSecond: 20, origin: -1, width: 944)
        var inOut: ClosedRange<Double>?
        var selection: ClosedRange<Double>?
    }
    var state = State() { didSet { if state != oldValue { invalidate() } } }
    static let labelFont = VCType.label.nsMono()

    private func x(_ time: Double) -> CGFloat { headerWidth + CGFloat(state.viewport.x(time)) }

    override func drawLane(in context: CGContext) {
        let height = bounds.height
        let lane = NSRect(x: headerWidth, y: 0, width: max(0, bounds.width - headerWidth), height: height)
        let inX = state.inOut.map { x($0.lowerBound) }, outX = state.inOut.map { x($0.upperBound) }
        if let inX, let outX {
            DesignValues.nsColor("timeline.rulerOut").setFill()
            lane.fill()
            let lower = max(lane.minX, inX), upper = min(lane.maxX, outX)
            DesignValues.nsColor("bg.window").setFill()
            if upper > lower { NSRect(x: lower, y: 0, width: upper - lower, height: height).fill() }
        }
        context.saveGState()
        context.clip(to: lane)
        let laneEnd = headerWidth + CGFloat(state.viewport.width) - TimelineMetrics.trailing
        let brackets = [inX, outX].compactMap { $0 }.map(Double.init)
        let major = DesignValues.nsColor("text.disabled"), minor = DesignValues.nsColor("timeline.tick"), label = DesignValues.nsColor("timeline.rulerLabel")
        for tick in TimelineRuler.ticks(visible: state.viewport.visible, ptPerSecond: state.viewport.ptPerSecond) where tick.time >= 0 {
            let tickX = x(tick.time)
            if tick.major {
                major.setFill()
                NSRect(x: tickX, y: 2, width: 1, height: height - 2).fill()
                let text = SMPTETimecode.format(seconds: tick.time)
                let width = Double(Self.width(text.dimPrefix + text.value, font: Self.labelFont))
                guard let start = TimelineRuler.labelX(tickX: Double(tickX), width: width, brackets: brackets, inBracket: inX.map(Double.init), laneEnd: Double(laneEnd)) else { continue }
                Self.draw(text.dimPrefix, font: Self.labelFont, color: major, x: CGFloat(start), baseline: 10)
                Self.draw(text.value, font: Self.labelFont, color: label, x: CGFloat(start) + Self.width(text.dimPrefix, font: Self.labelFont), baseline: 10)
            } else {
                minor.setFill()
                NSRect(x: tickX, y: 16, width: 1, height: 6).fill()
            }
        }
        if let selection = state.selection {
            DesignValues.nsColor("tint.default").setFill()
            NSRect(x: x(selection.lowerBound), y: 19, width: max(1, x(selection.upperBound) - x(selection.lowerBound)), height: 3).fill()
        }
        if let inX, let outX {
            let brackets = NSBezierPath()
            brackets.move(to: NSPoint(x: inX + 0.75, y: height)); brackets.line(to: NSPoint(x: inX + 0.75, y: 0.75)); brackets.line(to: NSPoint(x: inX + 4.75, y: 0.75))
            brackets.move(to: NSPoint(x: outX - 0.75, y: height)); brackets.line(to: NSPoint(x: outX - 0.75, y: 0.75)); brackets.line(to: NSPoint(x: outX - 4.75, y: 0.75))
            brackets.lineWidth = 1.5
            DesignValues.nsColor("clip.label").setStroke()
            brackets.stroke()
        }
        context.restoreGState()
    }
}

/// Background under the clipped track viewport and its overlay scrollers.
@MainActor final class TimelineTrackBed: TimelineLane {
    struct State: Equatable { var width = 0.0 }
    var state = State() { didSet { if state != oldValue { invalidate() } } }
    override func drawLane(in context: CGContext) {
        DesignValues.nsColor("timeline.lane").setFill()
        NSRect(x: headerWidth, y: 0, width: max(0, bounds.width - headerWidth), height: bounds.height).fill()
    }
}

/// A1 (notes.md §6): the scope's audio as pieces on `timeline.audioPiece` with a 1 pt
/// `timeline.piece` outline, radius 2, 1 pt inside the 44 pt row. The waveform is per-point
/// columns from the take's pyramid: a peak column (`timeline.wave` at 62%) around an RMS core
/// (`timeline.wave`), nothing in silence. AI patches are an `ai.tint` 10% fill with no outline.
/// Edited is a ripple: pieces butt and each cut is one 1 pt `timeline.seam`. Source is take
/// time: each removed range is empty lane with a dashed `timeline.cutOutline` and its audio
/// ghosted (`timeline.ghostWave`), and media outside In/Out shows at 32%, from the edge the
/// ruler shows while In or Out is dragged. With no waveform (media missing, or on another
/// computer) each kept word is one 8 pt capsule in `timeline.wave`, 2 pt in from its ends
/// (design §5.4.10). Each lane point is one waveform column, the tallest of the ranges that
/// share it, and pieces under 3 pt join their neighbour's box.
@MainActor final class TimelineAudioLane: TimelineLane {
    struct State: Equatable {
        var viewport = TimelineViewport(axis: .edited, ptPerSecond: 20, origin: -1, width: 944)
        var pieces = TimelinePieces([])
        var waveform: WaveformData?
        /// Source view's removed ranges (`EditorModel.timelineRemovedRanges`), in take time.
        var removed: [Range<Double>] = []
        /// The kept words in take time, drawn as capsules while there is no waveform.
        var words: [Range<Double>] = []
        /// In and Out in take time on Source, outside which media dims, with the edge being
        /// dragged where the ruler shows it; nil on Edited and on Full Take.
        var inOut: ClosedRange<Double>?
        /// The open clip in take time on Source, which the pieces and removed ranges fill. A
        /// drag of In or Out past it shows the take it adds as kept media.
        var clip: ClosedRange<Double>?
        var takeLength = 0.0
    }
    var state = State() { didSet { if state != oldValue { invalidate() } } }

    /// What the last draw put on the lane, in lane points, for the checks.
    struct Drawn: Equatable {
        /// The seams' x (each a 1 pt line just left of it).
        var seams: [CGFloat] = []
        /// Source view's removed ranges in view, in take time.
        var gaps: [Range<Double>] = []
        /// The lane points whose waveform column drew a peak, each once.
        var columns = 0
        /// Of those, the ones drawn outside In/Out at 32%.
        var dimmed = 0
        /// Piece boxes drawn (pieces under 3 pt share their neighbour's).
        var boxes = 0
        /// Word capsules drawn in place of a waveform.
        var capsules = 0
    }
    private(set) var drawn = Drawn()

    /// Media outside In/Out on Source (notes.md §6).
    static let outsideOpacity: CGFloat = 0.32
    /// The peak columns' opacity over the core's colour.
    static let peakOpacity: CGFloat = 0.62
    /// A piece fills the row less 1 pt above and below; the waveform keeps 1.5 pt more each side.
    nonisolated static let pieceInset: CGFloat = 1
    static let waveInset: CGFloat = 1.5
    /// Seams closer than this to the last one drawn are left out, so a zoomed-out take with
    /// cuts every few points stays a waveform rather than a row of seams.
    static let seamSpacing: CGFloat = 2
    /// Pieces narrower than this join the box before them (or the box after a narrower one)
    /// when less than a point of lane separates them, so a fitted hour of short pieces stays
    /// one box rather than none.
    nonisolated static let narrowPiece: CGFloat = 3

    private var laneRight: CGFloat { bounds.width }
    private func x(_ time: Double) -> CGFloat { headerWidth + CGFloat(state.viewport.x(time)) }

    override func drawLane(in context: CGContext) {
        drawn = Drawn()
        let lane = NSRect(x: headerWidth, y: 0, width: max(0, bounds.width - headerWidth), height: bounds.height)
        DesignValues.nsColor("timeline.lane").setFill()
        lane.fill()
        context.saveGState()
        context.clip(to: lane)
        if state.viewport.axis == .edited { drawEdited(in: context) } else { drawSource(in: context) }
        context.restoreGState()
    }

    /// Pieces butt; a seam at every cut.
    private func drawEdited(in context: CGContext) {
        let pieces = state.pieces
        let visible = state.viewport.visible
        let shown = pieces.indices(overlapping: visible.lowerBound..<max(visible.lowerBound, visible.upperBound), on: .edited)
        var kept = paint(), ai: [CGRect] = []
        for index in shown {
            let piece = pieces.pieces[index]
            if piece.kind == .ai { ai.append(pieceRect(piece.edited)); continue }
            kept.piece(x(piece.edited.lowerBound), x(piece.edited.upperBound))
            columns(piece.edited, offset: piece.source.lowerBound - piece.edited.lowerBound, into: &kept)
        }
        fillAI(ai, in: context)
        draw(&kept, in: context, wave: "timeline.wave")
        var seams: [CGRect] = []
        var last = -CGFloat.infinity
        for index in shown where pieces.isSeam(at: index) {
            let seamX = x(pieces.pieces[index].edited.lowerBound)
            guard seamX - last >= Self.seamSpacing else { continue }
            last = seamX
            seams.append(CGRect(x: seamX - 1, y: 0, width: 1, height: bounds.height))
            drawn.seams.append(seamX)
        }
        context.setFillColor(DesignValues.nsColor("timeline.seam").cgColor)
        context.fill(seams)
    }

    /// Take time: kept pieces where they are, removed ranges as empty lane with a dashed
    /// outline and ghosted audio, media outside In/Out dimmed. While In or Out is dragged,
    /// the take it adds shows as kept media and what it drops dims, as the ruler shows it.
    private func drawSource(in context: CGContext) {
        let pieces = state.pieces
        let visible = state.viewport.visible
        let window = visible.lowerBound..<max(visible.lowerBound, visible.upperBound)
        func inView(_ lower: Double, _ upper: Double) -> Range<Double>? {
            lower < upper && lower < window.upperBound && upper > window.lowerBound ? lower..<upper : nil
        }
        // Ranges a drag adds before and after the clip.
        var before: Range<Double>?, after: Range<Double>?
        if let inOut = state.inOut {
            var outside = paint()
            for range in [inView(0, inOut.lowerBound), inView(inOut.upperBound, state.takeLength)].compactMap({ $0 }) {
                outside.piece(x(range.lowerBound), x(range.upperBound))
                columns(range, offset: 0, into: &outside)
            }
            context.saveGState()
            context.setAlpha(Self.outsideOpacity)
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            drawn.dimmed = draw(&outside, in: context, wave: "timeline.wave")
            context.endTransparencyLayer()
            context.restoreGState()
            if let clip = state.clip {
                before = inView(inOut.lowerBound, min(inOut.upperBound, clip.lowerBound))
                after = inView(max(inOut.lowerBound, clip.upperBound), inOut.upperBound)
            }
            // What a drag drops from the clip shows only dimmed.
            context.saveGState()
            context.clip(to: CGRect(x: x(inOut.lowerBound), y: 0, width: max(0, x(inOut.upperBound) - x(inOut.lowerBound)), height: bounds.height))
        }
        var ghost = paint()
        let outline = CGMutablePath()
        for gap in state.removed where gap.overlaps(window) {
            drawn.gaps.append(gap)
            let rect = pieceRect(gap)
            if rect.width >= 2 { outline.addRect(rect.insetBy(dx: 0.5, dy: 0.5)) }
            columns(gap, offset: 0, into: &ghost)
        }
        context.addPath(outline)
        context.setStrokeColor(DesignValues.nsColor("timeline.cutOutline").cgColor)
        context.setLineWidth(1)
        context.setLineDash(phase: 0, lengths: [3, 3])
        context.strokePath()
        context.setLineDash(phase: 0, lengths: [])
        draw(&ghost, in: context, wave: "timeline.ghostWave")
        var kept = paint(), ai: [CGRect] = []
        func keep(_ range: Range<Double>) {
            kept.piece(x(range.lowerBound), x(range.upperBound))
            columns(range, offset: 0, into: &kept)
        }
        if let before { keep(before) }
        for index in pieces.indices(overlapping: window, on: .source) {
            let piece = pieces.pieces[index]
            if piece.kind == .ai { ai.append(pieceRect(piece.source)); continue }
            keep(piece.source)
        }
        if let after { keep(after) }
        fillAI(ai, in: context)
        draw(&kept, in: context, wave: "timeline.wave")
        if state.inOut != nil { context.restoreGState() }
    }

    /// A piece's box for `range` on the axis: 1 pt in from the row's top and bottom, ending
    /// 1 pt short of the next piece.
    private func pieceRect(_ range: Range<Double>) -> CGRect {
        let lower = x(range.lowerBound), upper = x(range.upperBound)
        return CGRect(x: lower, y: Self.pieceInset, width: max(0, upper - lower - 1), height: bounds.height - 2 * Self.pieceInset)
    }

    private func fillAI(_ rects: [CGRect], in context: CGContext) {
        guard !rects.isEmpty else { return }
        context.setFillColor(DesignValues.nsColor("ai.tint").withAlphaComponent(0.10).cgColor)
        context.fill(rects)
    }

    /// The waveform columns of `range` on the axis, whose take time is the axis time plus
    /// `offset`: one per lane point, each from the pyramid level that fits it. A point two
    /// ranges share (a piece ends inside it) keeps the taller of their columns. With no
    /// waveform, the kept words' capsules instead.
    private func columns(_ range: Range<Double>, offset: Double, into paint: inout Paint) {
        guard let waveform = state.waveform else { capsules(range, offset: offset, into: &paint); return }
        guard state.viewport.ptPerSecond > 0 else { return }
        let lower = max(headerWidth, x(range.lowerBound).rounded(.down)), upper = min(laneRight, x(range.upperBound).rounded(.up))
        guard lower < upper else { return }
        let half = bounds.height / 2 - Self.pieceInset - Self.waveInset
        var column = lower
        while column < upper {
            let start = max(range.lowerBound, state.viewport.time(atX: Double(column - headerWidth)))
            let end = min(range.upperBound, state.viewport.time(atX: Double(column + 1 - headerWidth)))
            if end > start {
                let value = waveform.column(from: start + offset, to: end + offset, span: 1 / state.viewport.ptPerSecond)
                paint.column(Int(column - headerWidth), peak: CGFloat(value.peak) * half, core: CGFloat(value.core) * half)
            }
            column += 1
        }
    }

    /// The kept words of `range` on the axis (take time = axis time + `offset`) as capsules.
    private func capsules(_ range: Range<Double>, offset: Double, into paint: inout Paint) {
        let words = state.words, lower = range.lowerBound + offset, upper = range.upperBound + offset
        var index = 0, end = words.count
        while index < end {
            let middle = (index + end) / 2
            if words[middle].lowerBound < lower { index = middle + 1 } else { end = middle }
        }
        while index > 0, words[index - 1].upperBound > lower { index -= 1 }
        let mid = bounds.height / 2
        while index < words.count, words[index].lowerBound < upper {
            let word = words[index].clamped(to: lower..<upper)
            index += 1
            let left = x(word.lowerBound - offset) + 2, right = x(word.upperBound - offset) - 2
            guard right - left >= 1 else { continue }
            let radius = min(4, (right - left) / 2)
            paint.words.addRoundedRect(in: CGRect(x: left, y: mid - 4, width: right - left, height: 8), cornerWidth: radius, cornerHeight: radius)
            drawn.capsules += 1
        }
    }

    /// A paint for this lane's width and height.
    private func paint() -> Paint {
        Paint(origin: headerWidth, points: Int(max(0, bounds.width - headerWidth).rounded(.up)), height: bounds.height)
    }

    /// Fills `paint` and records what it drew. Returns its waveform columns.
    @discardableResult private func draw(_ paint: inout Paint, in context: CGContext, wave: String) -> Int {
        let drew = paint.draw(in: context, wave: wave)
        drawn.columns += drew.columns
        drawn.boxes += drew.boxes
        return drew.columns
    }

    /// Pieces and their waveform, gathered and filled in one pass each: one box per run of
    /// pieces that butt where any is under `narrowPiece`, and one column per lane point.
    private struct Paint {
        let origin: CGFloat
        let height: CGFloat
        var boxes = CGMutablePath()
        var outlines = CGMutablePath()
        var boxCount = 0
        /// Per lane point from `origin`, the tallest peak and core (in points from the middle).
        var peaks: [CGFloat]
        var cores: [CGFloat]
        var words = CGMutablePath()
        /// The box being gathered, in lane x: from its first piece's start to its last's end.
        private var pending: (lower: CGFloat, upper: CGFloat)?
        init(origin: CGFloat, points: Int, height: CGFloat) {
            self.origin = origin
            self.height = height
            peaks = [CGFloat](repeating: 0, count: points)
            cores = [CGFloat](repeating: 0, count: points)
        }
        /// A piece from `lower` to `upper` in lane x, in order. Its box ends 1 pt short of
        /// the next piece's.
        mutating func piece(_ lower: CGFloat, _ upper: CGFloat) {
            if let current = pending, lower - current.upper < 1,
               upper - lower < TimelineAudioLane.narrowPiece || current.upper - current.lower < TimelineAudioLane.narrowPiece {
                pending = (current.lower, max(current.upper, upper))
                return
            }
            flush()
            pending = (lower, upper)
        }
        private mutating func flush() {
            guard let current = pending else { return }
            pending = nil
            let inset = TimelineAudioLane.pieceInset
            let rect = CGRect(x: current.lower, y: inset, width: max(0, current.upper - current.lower - 1), height: height - 2 * inset)
            guard rect.width > 0 else { return }
            boxCount += 1
            let radius = min(2, rect.width / 2)
            boxes.addRoundedRect(in: rect, cornerWidth: radius, cornerHeight: radius)
            if rect.width >= 3 {
                let inner = rect.insetBy(dx: 0.5, dy: 0.5), corner = min(1.5, inner.width / 2)
                outlines.addRoundedRect(in: inner, cornerWidth: corner, cornerHeight: corner)
            }
        }
        mutating func column(_ index: Int, peak: CGFloat, core: CGFloat) {
            guard peaks.indices.contains(index) else { return }
            peaks[index] = max(peaks[index], peak)
            cores[index] = max(cores[index], core)
        }
        @MainActor mutating func draw(in context: CGContext, wave: String) -> (columns: Int, boxes: Int) {
            flush()
            if boxCount > 0 {
                context.addPath(boxes)
                context.setFillColor(DesignValues.nsColor("timeline.audioPiece").cgColor)
                context.fillPath()
                context.addPath(outlines)
                context.setStrokeColor(DesignValues.nsColor("timeline.piece").cgColor)
                context.setLineWidth(1)
                context.strokePath()
            }
            // Nothing under half a point: silence draws no centre line.
            let mid = height / 2
            var peakRects: [CGRect] = [], coreRects: [CGRect] = []
            for (index, peak) in peaks.enumerated() where peak >= 0.5 {
                peakRects.append(CGRect(x: origin + CGFloat(index), y: mid - peak, width: 1, height: 2 * peak))
            }
            for (index, core) in cores.enumerated() where core >= 0.5 {
                coreRects.append(CGRect(x: origin + CGFloat(index), y: mid - core, width: 1, height: 2 * core))
            }
            let color = DesignValues.nsColor(wave)
            context.setFillColor(color.withAlphaComponent(color.alphaComponent * TimelineAudioLane.peakOpacity).cgColor)
            context.fill(peakRects)
            context.setFillColor(color.cgColor)
            context.fill(coreRects)
            context.addPath(words)
            context.fillPath()
            return (peakRects.count, boxCount)
        }
    }
}

/// Above the lanes, never drawing: the selection wash over the tracks, and the playhead in
/// the overview and through the ruler and tracks, each a layer moved by transform.
@MainActor final class TimelineOverlayView: NSView {
    /// The overlay right of the track headers, clipped to itself: the wash and the playhead
    /// live in it, in lane coordinates, so neither draws over the headers (notes.md §6).
    var headerWidth = TimelineMetrics.header { didSet { placeLaneClip() } }
    let laneClip = CALayer()
    let wash = CALayer()
    let playhead = CALayer()
    let head = CAShapeLayer()
    let line = CALayer()
    let overviewPlayhead = CALayer()
    /// Moves of the playhead layers, for the per-tick budget checks.
    private(set) var playheadMoves = 0
    override init(frame: NSRect) {
        super.init(frame: frame)
        // A layer-hosting view: its layers are its content.
        let root = CALayer()
        root.isGeometryFlipped = true
        layer = root
        wantsLayer = true
        for layer in [laneClip, wash, playhead, head, line, overviewPlayhead] { layer.actions = ["position": NSNull(), "bounds": NSNull(), "transform": NSNull(), "hidden": NSNull(), "frame": NSNull(), "path": NSNull()] }
        laneClip.masksToBounds = true
        // The head: 10.5 × 10.6 in the ruler's lower half; the line: 1 pt from the ruler's
        // foot through the tracks (notes.md §6). Both hang from x 0 of `playhead`.
        let top = TimelineMetrics.ruler.y + 11
        let path = CGMutablePath()
        path.move(to: CGPoint(x: -5.25, y: 0)); path.addLine(to: CGPoint(x: 5.25, y: 0)); path.addLine(to: CGPoint(x: 5.25, y: 4.6))
        path.addLine(to: CGPoint(x: 0, y: 10.6)); path.addLine(to: CGPoint(x: -5.25, y: 4.6)); path.closeSubpath()
        head.path = path
        head.frame = CGRect(x: 0, y: top, width: 0, height: 10.6)
        line.frame = CGRect(x: -0.5, y: TimelineMetrics.ruler.maxY - 1, width: 1, height: TimelineMetrics.tracksEnd - TimelineMetrics.ruler.maxY + 1)
        playhead.addSublayer(line)
        playhead.addSublayer(head)
        playhead.frame = CGRect(x: 0, y: 0, width: 0, height: TimelineMetrics.tracksEnd)
        overviewPlayhead.frame = CGRect(x: -0.75, y: TimelineMetrics.overview.y + 1, width: 1.5, height: 22)
        laneClip.addSublayer(wash)
        laneClip.addSublayer(playhead)
        root.addSublayer(laneClip)
        root.addSublayer(overviewPlayhead)
        placeLaneClip()
        applyColors()
    }
    required init?(coder: NSCoder) { nil }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        placeLaneClip()
    }
    private func placeLaneClip() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        laneClip.frame = CGRect(x: headerWidth, y: 0, width: max(0, bounds.width - headerWidth), height: bounds.height)
        CATransaction.commit()
    }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }
    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let tint = DesignValues.nsColor("tint.default").cgColor
            line.backgroundColor = tint
            head.fillColor = tint
            overviewPlayhead.backgroundColor = tint
            wash.backgroundColor = DesignValues.nsColor("tint.wash").cgColor
        }
        for (layer, label) in zip(labelLayers, labels) { layer.foregroundColor = labelColor(open: label.open) }
    }
    /// The playhead `laneX` into the ruler and tracks (off them, clipped away) and at
    /// `overviewX` in the overview.
    func movePlayhead(laneX: Double, overviewX: CGFloat) {
        playheadMoves += 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playhead.transform = CATransform3DMakeTranslation(CGFloat(laneX), 0, 0)
        overviewPlayhead.transform = CATransform3DMakeTranslation(overviewX, 0, 0)
        CATransaction.commit()
    }
    private var labelLayers: [CATextLayer] = []
    private var labels: [TimelineOverviewLabel] = []
    /// The overview's block labels, `top` down the overlay. Only a moved label's layer moves.
    func placeOverviewLabels(_ next: [TimelineOverviewLabel], top: CGFloat) {
        guard next != labels else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        while labelLayers.count < next.count {
            let layer = CATextLayer()
            layer.font = TimelineOverviewLane.labelFont
            layer.fontSize = TimelineOverviewLane.labelFont.pointSize
            layer.contentsScale = window?.backingScaleFactor ?? 2
            layer.actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull(), "hidden": NSNull(), "foregroundColor": NSNull()]
            self.layer?.insertSublayer(layer, below: overviewPlayhead)
            labelLayers.append(layer)
        }
        let font = TimelineOverviewLane.labelFont
        for (index, layer) in labelLayers.enumerated() {
            guard next.indices.contains(index) else { layer.isHidden = true; continue }
            let label = next[index]
            let previous = labels.indices.contains(index) ? labels[index] : nil
            if previous?.text != label.text || previous?.open != label.open || layer.isHidden {
                layer.string = label.text
                layer.foregroundColor = labelColor(open: label.open)
            }
            layer.isHidden = false
            layer.frame = CGRect(x: label.x, y: top + label.baseline - font.ascender, width: TimelineLane.width(label.text, font: font) + 2, height: ceil(font.ascender - font.descender) + 1)
        }
        labels = next
        CATransaction.commit()
    }
    private func labelColor(open: Bool) -> CGColor {
        var color = NSColor.clear.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { color = DesignValues.nsColor(open ? "text.primary" : "text.secondary").cgColor }
        return color
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        labelLayers.forEach { $0.contentsScale = window?.backingScaleFactor ?? 2 }
    }

    /// The selection's 7% wash over the tracks, in lane coordinates, or none.
    func showWash(_ rect: NSRect?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        wash.isHidden = rect == nil
        if let rect { wash.frame = rect }
        CATransaction.commit()
    }
}

/// FX's empty state (V9b, notes.md §6 and v3 f10–f14). Director will own its
/// word-anchored results later; there is no disabled or decorative action to press.
@MainActor final class MotionLane: TimelineLane {
    static let emptyHint = "Director results land here"
    private static let hintFont = NSFont.systemFont(ofSize: 11)
    override func drawLane(in context: CGContext) {
        let lane = CGRect(x: headerWidth, y: 0, width: max(0, bounds.width - headerWidth), height: bounds.height)
        context.setFillColor(DesignValues.nsColor("timeline.lane").cgColor)
        context.fill(lane)
        context.saveGState(); context.clip(to: lane)
        let font = Self.hintFont
        Self.draw(Self.emptyHint, font: font, color: DesignValues.nsColor("text.disabled"), x: headerWidth + 10, baseline: bounds.midY + font.xHeight / 2)
        context.restoreGState()
    }
}

/// The track sizes, V1/A1/CC/FX (notes.md §6).
enum TrackHeight: String, CaseIterable {
    case small, medium, large
    var label: String { switch self { case .small: "S"; case .medium: "M"; case .large: "L" } }
    var heights: [CGFloat] { switch self { case .small: [28, 32, 20, 20]; case .medium: [36, 44, 24, 24]; case .large: [52, 64, 28, 28] } }
}

@MainActor final class TimelineTrackClip: NSView {
    override var isFlipped: Bool { true }
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true; layer?.masksToBounds = true }
    required init?(coder: NSCoder) { nil }
}

/// Only actionable controls: CC changes the document's captions, A1 mutes preview only.
@MainActor final class TrackHeaderView: NSView {
    let trackID: String
    let name: String
    let button = NSButton()
    var action: (() -> Void)?
    private(set) var on = true
    private static let idFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold)
    private static let nameFont = NSFont.systemFont(ofSize: 11)
    init(id: String, name: String) {
        trackID = id; self.name = name
        super.init(frame: .zero)
        wantsLayer = true
        button.isBordered = false
        button.target = self; button.action = #selector(press)
        button.imagePosition = .imageOnly
        button.setAccessibilityIdentifier("voxclip.timeline.header.\(id)")
        button.isHidden = id == "V1" || id == "FX"
        addSubview(button)
        update(on: true, enabled: true)
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    @objc private func press() { action?() }
    func update(on: Bool, enabled: Bool) {
        self.on = on
        button.isEnabled = enabled
        let symbol = trackID == "CC" ? (on ? "eye" : "eye.slash") : (on ? "speaker.wave.1" : "speaker.slash")
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
        button.contentTintColor = DesignValues.nsColor("text.tertiary")
        button.setAccessibilityLabel("\(trackID) \(name), \(trackID == "CC" ? (on ? "shown" : "hidden") : (on ? "audible" : "muted"))")
        button.toolTip = trackID == "CC" ? (on ? "Hide captions" : "Show captions") : (on ? "Mute preview" : "Unmute preview")
        needsDisplay = true
    }
    override func layout() { super.layout(); button.frame = NSRect(x: bounds.width - 24, y: (bounds.height - 22) / 2, width: 22, height: 22) }
    override func draw(_ dirtyRect: NSRect) {
        DesignValues.nsColor("bg.window").setFill(); bounds.fill()
        let font = Self.idFont
        TimelineLane.draw(trackID, font: font, color: DesignValues.nsColor("text.secondary"), x: 10, baseline: bounds.midY + font.xHeight / 2)
        if bounds.width >= 100 {
            let nameFont = Self.nameFont
            TimelineLane.draw(name, font: nameFont, color: DesignValues.nsColor("text.tertiary"), x: trackID == "CC" ? 29 : 34, baseline: bounds.midY + nameFont.xHeight / 2)
        }
    }
    override func isAccessibilityElement() -> Bool { trackID == "V1" || trackID == "FX" }
    override func accessibilityLabel() -> String? { "\(trackID) \(name)" }
    override func accessibilityValue() -> Any? { trackID == "FX" ? MotionLane.emptyHint : nil }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
}

/// A four-point overlay thumb. Its full eight-point strip takes drags; VoiceOver adjusts
/// it in pages. No view grows with the take's duration.
@MainActor final class TimelineScroller: NSControl {
    var vertical = false
    var changed: ((Double) -> Void)?
    private(set) var portion = 1.0
    private(set) var fraction = 0.0
    private var dragOffset = 0.0
    override var isFlipped: Bool { true }
    var thumb: NSRect {
        let length = vertical ? bounds.height : bounds.width
        let size = min(length, max(24, length * portion))
        let origin = (length - size) * fraction
        return vertical ? NSRect(x: 2, y: origin, width: 4, height: size) : NSRect(x: origin, y: 2, width: size, height: 4)
    }
    func update(portion: Double, fraction: Double) {
        self.portion = portion.clamped(to: 0...1); self.fraction = fraction.clamped(to: 0...1)
        isHidden = portion >= 0.999; needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        DesignValues.nsColor("timeline.scroller").setFill()
        NSBezierPath(roundedRect: thumb, xRadius: 2, yRadius: 2).fill()
    }
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let coordinate = vertical ? p.y : p.x
        dragOffset = thumb.contains(p) ? coordinate - (vertical ? thumb.minY : thumb.minX) : (vertical ? thumb.height : thumb.width) / 2
        move(event)
    }
    override func mouseDragged(with event: NSEvent) { move(event) }
    private func move(_ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let length = vertical ? bounds.height - thumb.height : bounds.width - thumb.width
        changed?(((vertical ? p.y : p.x) - dragOffset) / max(1, length))
    }
    override func isAccessibilityElement() -> Bool { !isHidden }
    override func accessibilityRole() -> NSAccessibility.Role? { .scrollBar }
    override func accessibilityLabel() -> String? { vertical ? "Timeline tracks" : "Timeline scroll" }
    override func accessibilityValue() -> Any? { NSNumber(value: fraction) }
    override func accessibilityMinValue() -> Any? { 0 }
    override func accessibilityMaxValue() -> Any? { 1 }
    override func accessibilityPerformIncrement() -> Bool { changed?(min(1, fraction + max(0.05, portion))); return true }
    override func accessibilityPerformDecrement() -> Bool { changed?(max(0, fraction - max(0.05, portion))); return true }
}

/// V1's linked pieces. Decode results only invalidate V1; playback moves the overlay.
@MainActor final class VideoLane: TimelineLane {
    struct State: Equatable {
        var viewport = TimelineViewport(axis: .edited, ptPerSecond: 20, origin: -1, width: 944)
        var pieces = TimelinePieces([])
        var inOut: ClosedRange<Double>?
        var clip: ClosedRange<Double>?
        var takeLength = 0.0
    }
    var state = State() { didSet { if state != oldValue { invalidate() } } }
    var mediaName = "" { didSet { if mediaName != oldValue { invalidate() } } }
    private(set) var cache: FilmstripCache?
    private var source: FilmstripSource?
    private var images: [Int64: CGImage] = [:]
    private var generation = 0
    private var requested: [Int64] = []
    private var requestedTolerance: Int64?
    private let cacheFactory: @MainActor (FilmstripSource) -> FilmstripCache
    init(frame: NSRect = .zero, cacheFactory: @escaping @MainActor (FilmstripSource) -> FilmstripCache = { FilmstripCache(source: $0) }) {
        self.cacheFactory = cacheFactory
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { nil }
    private var requestTask: Task<Void, Never>?
    #if DEBUG
    var everyFrame: CGImage? { didSet { invalidate() } }
    #endif
    private(set) var names = 0
    private(set) var tiles = 0
    private(set) var seams: [CGFloat] = []
    private(set) var dimmed = 0
    private func x(_ time: Double) -> CGFloat { headerWidth + state.viewport.x(time) }
    func setSource(_ next: FilmstripSource?) {
        guard source != next else { return }
        cancelLoads()
        source = next; images = [:]; requested = []
        cache = next.map(cacheFactory)
        invalidate()
    }
    @discardableResult func cancelLoads() -> Task<Void, Never>? {
        generation += 1; requested = []; requestedTolerance = nil
        requestTask?.cancel(); requestTask = nil
        return cache.map { cache in Task { await cache.cancelAll() } }
    }
    private struct Span { let axis: Range<Double>; let source: Range<Double>; var opacity = 1.0; var coalesced = false }
    private func spans() -> [Span] {
        let axis = state.viewport.axis, visible = state.viewport.visible
        var result: [Span] = []
        for index in state.pieces.indices(overlapping: visible.lowerBound..<visible.upperBound, on: axis) {
            let piece = state.pieces.pieces[index]
            let range = axis == .edited ? piece.edited : piece.source
            if axis == .source, let io = state.inOut {
                let lower = max(range.lowerBound, io.lowerBound), upper = min(range.upperBound, io.upperBound)
                if upper > lower { result.append(Span(axis: lower..<upper, source: lower..<upper)) }
            } else { result.append(Span(axis: range, source: piece.source)) }
        }
        // At a fitted hour a kept piece can be narrower than one point. Share a visual
        // box across those neighbours, as A1 does; otherwise subtracting a seam hides V1.
        var grouped: [Span] = []
        for var span in result {
            let narrow = (span.axis.upperBound - span.axis.lowerBound) * state.viewport.ptPerSecond < 3
            if narrow, let last = grouped.last, last.coalesced,
               (span.axis.lowerBound - last.axis.upperBound) * state.viewport.ptPerSecond < 1 {
                grouped[grouped.count - 1] = Span(axis: last.axis.lowerBound..<span.axis.upperBound,
                                                source: last.source.lowerBound..<span.source.upperBound, coalesced: true)
            } else { span.coalesced = narrow; grouped.append(span) }
        }
        result = grouped
        if axis == .source, let io = state.inOut {
            if io.lowerBound > 0 { result.append(Span(axis: 0..<io.lowerBound, source: 0..<io.lowerBound, opacity: 0.32)) }
            if io.upperBound < state.takeLength { result.append(Span(axis: io.upperBound..<state.takeLength, source: io.upperBound..<state.takeLength, opacity: 0.32)) }
            if let clip = state.clip {
                if io.lowerBound < clip.lowerBound { result.append(Span(axis: io.lowerBound..<clip.lowerBound, source: io.lowerBound..<clip.lowerBound)) }
                if io.upperBound > clip.upperBound { result.append(Span(axis: clip.upperBound..<io.upperBound, source: clip.upperBound..<io.upperBound)) }
            }
        }
        return result
    }
    private struct Tile { let rect: CGRect; let frame: Int64 }
    private func tileLayout(_ span: Span, rect: CGRect) -> [Tile] {
        guard rect.width >= 3 else { return [] }
        // The empty name band stays on narrow pieces too (f1 / zoom-timeline), so
        // the filmstrip keeps one height across a cut; only the text needs 60 pt.
        let top = 11.0
        let height = max(1, rect.height - top - 1)
        let width = height * 16 / 9
        let lower = max(rect.minX + 1, headerWidth), upper = min(rect.maxX - 1, bounds.width)
        guard upper > lower else { return [] }
        let first = floor((lower - rect.minX) / width)
        let cell = TimelineFilmstrip.cellFrames(tileWidth: width, ptPerSecond: state.viewport.ptPerSecond)
        var result: [Tile] = []
        var left = rect.minX + first * width
        while left < upper {
            let middle = state.viewport.time(atX: left + width / 2 - headerWidth)
            let scale = (span.source.upperBound - span.source.lowerBound) / max(1e-9, span.axis.upperBound - span.axis.lowerBound)
            var time = span.source.lowerBound + (middle - span.axis.lowerBound) * scale
            if state.viewport.axis == .edited, span.coalesced {
                let axisTime = middle.clamped(to: span.axis.lowerBound...max(span.axis.lowerBound, span.axis.upperBound - 1e-7))
                if let index = state.pieces.indices(overlapping: axisTime..<(axisTime + 1e-7), on: .edited).first {
                    let piece = state.pieces.pieces[index]
                    let fraction = (axisTime - piece.edited.lowerBound) / max(1e-9, (piece.edited.upperBound - piece.edited.lowerBound))
                    time = piece.source.lowerBound + fraction * (piece.source.upperBound - piece.source.lowerBound)
                }
            }
            let safe = time.clamped(to: span.source.lowerBound...max(span.source.lowerBound, span.source.upperBound - 1.0 / 30))
            result.append(Tile(rect: CGRect(x: left, y: 1 + top, width: width, height: height), frame: TimelineFilmstrip.frame(at: safe, cellFrames: cell)))
            left += width
        }
        return result
    }
    private func rect(_ span: Span) -> CGRect {
        let width = x(span.axis.upperBound) - x(span.axis.lowerBound)
        return CGRect(x: x(span.axis.lowerBound), y: 1, width: max(0, width - (width >= 3 ? 1 : 0)), height: max(0, bounds.height - 2))
    }
    func requestFrames() {
        guard let cache else { return }
        let frames = spans().flatMap { tileLayout($0, rect: rect($0)) }.map(\.frame)
        var seen = Set<Int64>()
        let wanted = frames.filter { seen.insert($0).inserted }
        let tolerance = max(0.1, Double(TimelineFilmstrip.cellFrames(tileWidth: 40, ptPerSecond: state.viewport.ptPerSecond)) / 60)
        let toleranceClass = FilmstripFrameKey(0, tolerance: tolerance).toleranceTicks
        guard wanted != requested || toleranceClass != requestedTolerance else { return }
        images = toleranceClass == requestedTolerance ? images.filter { seen.contains($0.key) } : [:]
        requested = wanted; requestedTolerance = toleranceClass; generation += 1
        let generation = generation, source = source
        requestTask?.cancel()
        requestTask = Task { [weak self] in
            await cache.want(wanted, tolerance: tolerance, generation: generation) { [weak self] frame, image in
                guard let self, self.generation == generation, self.source == source, self.requested.contains(frame) else { return }
                self.images[frame] = image; self.invalidate()
            }
        }
    }
    override func drawLane(in context: CGContext) {
        names = 0; tiles = 0; dimmed = 0; seams = []
        let lane = CGRect(x: headerWidth, y: 0, width: max(0, bounds.width - headerWidth), height: bounds.height)
        context.setFillColor(DesignValues.nsColor("timeline.lane").cgColor); context.fill(lane)
        context.saveGState(); context.clip(to: lane)
        let boxes = CGMutablePath(), borders = CGMutablePath()
        for span in spans() {
            let rect = rect(span)
            guard rect.maxX > headerWidth, rect.minX < bounds.width, rect.width > 0 else { continue }
            let path = CGPath(roundedRect: rect, cornerWidth: 2, cornerHeight: 2, transform: nil)
            if span.opacity == 1 { boxes.addPath(path); borders.addRoundedRect(in: rect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 2, cornerHeight: 2) }
        }
        context.setFillColor(DesignValues.nsColor("timeline.videoPiece").cgColor); context.addPath(boxes); context.fillPath()
        for span in spans() {
            let rect = rect(span)
            guard rect.maxX > headerWidth, rect.minX < bounds.width, rect.width >= 3 else { continue }
            context.saveGState()
            if span.opacity < 1 {
                dimmed += 1
                context.setAlpha(span.opacity)
                context.beginTransparencyLayer(auxiliaryInfo: nil)
                context.setFillColor(DesignValues.nsColor("timeline.videoPiece").cgColor)
                context.addPath(CGPath(roundedRect: rect, cornerWidth: 2, cornerHeight: 2, transform: nil))
                context.fillPath()
            }
            context.saveGState()
            context.clip(to: rect.insetBy(dx: 1, dy: 1))
            if !span.coalesced, rect.width >= 60 {
                names += 1
                Self.draw(mediaName, font: .systemFont(ofSize: 9), color: DesignValues.nsColor("text.tertiary"), x: rect.minX + 4, baseline: 10)
            }
            for tile in tileLayout(span, rect: rect) {
                var image = images[tile.frame]
                #if DEBUG
                image = everyFrame ?? image
                #endif
                if let image {
                    // CGContext images are bottom-up in a flipped AppKit lane.
                    context.saveGState()
                    context.translateBy(x: tile.rect.minX, y: tile.rect.maxY)
                    context.scaleBy(x: 1, y: -1)
                    context.clip(to: CGRect(origin: .zero, size: tile.rect.size))
                    let scale = max(tile.rect.width / CGFloat(image.width), tile.rect.height / CGFloat(image.height))
                    let width: CGFloat = CGFloat(image.width) * scale
                    let height: CGFloat = CGFloat(image.height) * scale
                    let imageRect = CGRect(x: (tile.rect.width - width) / 2, y: (tile.rect.height - height) / 2, width: width, height: height)
                    context.draw(image, in: imageRect)
                    context.restoreGState()
                    tiles += 1
                }
            }
            context.restoreGState()
            if span.opacity < 1 {
                context.setStrokeColor(DesignValues.nsColor("timeline.piece").cgColor)
                context.setLineWidth(1)
                context.addPath(CGPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 2, cornerHeight: 2, transform: nil))
                context.strokePath()
                context.endTransparencyLayer()
            }
            context.restoreGState()
        }
        context.setStrokeColor(DesignValues.nsColor("timeline.piece").cgColor); context.setLineWidth(1); context.addPath(borders); context.strokePath()
        if state.viewport.axis == .edited {
            var last = -CGFloat.infinity
            let visible = state.viewport.visible
            for index in state.pieces.indices(overlapping: visible.lowerBound..<visible.upperBound, on: .edited) where state.pieces.isSeam(at: index) {
                let point = x(state.pieces.pieces[index].edited.lowerBound)
                if point - last >= 2 { seams.append(point); last = point; context.setFillColor(DesignValues.nsColor("timeline.seam").cgColor); context.fill(CGRect(x: point - 1, y: 0, width: 1, height: bounds.height)) }
            }
        }
        context.restoreGState()
    }
}

/// CC uses the actual caption layout pages, and stays empty until the first preview load.
@MainActor final class CaptionLane: TimelineLane {
    struct State: Equatable {
        var viewport = TimelineViewport(axis: .edited, ptPerSecond: 20, origin: -1, width: 944)
        var cues: [TimelineCue] = []
        var inOut: ClosedRange<Double>?
    }
    var state = State() { didSet { if state != oldValue { fits = [:]; invalidate() } } }
    private var fits: [Int: TimelineCueText.Fit] = [:]
    private(set) var textBlocks: [CGFloat] = []
    private(set) var ellipses = 0
    private(set) var blocks: [CGRect] = []
    private func x(_ time: Double) -> CGFloat { headerWidth + state.viewport.x(time) }
    override func drawLane(in context: CGContext) {
        textBlocks = []; ellipses = 0; blocks = []
        let lane = CGRect(x: headerWidth, y: 0, width: max(0, bounds.width - headerWidth), height: bounds.height)
        context.setFillColor(DesignValues.nsColor("timeline.lane").cgColor); context.fill(lane)
        context.saveGState(); context.clip(to: lane)
        let visible = state.viewport.visible
        let font = NSFont.systemFont(ofSize: 11)
        for index in TimelineCaptions.indices(of: state.cues, overlapping: visible.lowerBound..<visible.upperBound) {
            let cue = state.cues[index]
            let width = max(0, x(cue.range.upperBound) - x(cue.range.lowerBound) - 1)
            let height = min(20, max(0, bounds.height))
            let rect = CGRect(x: x(cue.range.lowerBound), y: (bounds.height - height) / 2, width: width, height: height)
            blocks.append(rect)
            let path = CGPath(roundedRect: rect, cornerWidth: 2, cornerHeight: 2, transform: nil)
            context.setFillColor(DesignValues.nsColor("timeline.cue").cgColor); context.addPath(path); context.fillPath()
            context.saveGState(); context.addPath(path); context.clip()
            if width >= 24 {
                let fit = fits[index] ?? TimelineCueText.fit(cue.text, width: width, ellipsisWidth: Self.width("…", font: font), measure: { Self.width($0, font: font) })
                if let fit {
                    fits[index] = fit; textBlocks.append(width)
                    let baseline = rect.midY + font.xHeight / 2
                    Self.draw(fit.text, font: font, color: DesignValues.nsColor("timeline.cueText"), x: rect.minX + 4, baseline: baseline)
                    if fit.ellipsis {
                        ellipses += 1
                        Self.draw("…", font: font, color: DesignValues.nsColor("text.disabled"), x: rect.minX + 5 + Self.width(fit.text, font: font), baseline: baseline)
                    }
                }
            }
            for cut in cue.cuts {
                context.setFillColor(DesignValues.nsColor("timeline.lane").withAlphaComponent(0.42).cgColor)
                context.fill(CGRect(x: x(cut.lowerBound), y: rect.minY, width: max(0, x(cut.upperBound) - x(cut.lowerBound)), height: height))
            }
            if let io = state.inOut {
                for range in [cue.range.lowerBound..<max(cue.range.lowerBound, min(cue.range.upperBound, io.lowerBound)), min(cue.range.upperBound, max(cue.range.lowerBound, io.upperBound))..<cue.range.upperBound] where !range.isEmpty {
                    context.setFillColor(DesignValues.nsColor("timeline.lane").withAlphaComponent(0.68).cgColor)
                    context.fill(CGRect(x: x(range.lowerBound), y: rect.minY, width: x(range.upperBound) - x(range.lowerBound), height: height))
                }
            }
            context.restoreGState()
        }
        context.restoreGState()
    }
}
