import AppKit
import QuartzCore
import VoxClipCore

// The v2 timeline's AppKit lanes (ux/v2 notes.md §6, impl-plan V7a and V7b): the overview
// strip, the ruler with In/Out, the track bed, A1's audio and the playhead. No view is wider
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
    /// V1, A1 and CC at the default track height (M). V9 fills V1 and CC.
    static let tracks = [Row(y: 47, height: 36), Row(y: 84, height: 44), Row(y: 129, height: 24)]
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
    private var drag: Drag?
    private let playheadElement = TimelineSliderElement()
    private let inElement = TimelineSliderElement()
    private let outElement = TimelineSliderElement()

    private enum Drag: Equatable {
        case scrub
        case overview
        /// The open clip's In (`start`) or Out, and the word it would land on.
        case trim(clip: ClipRange, start: Bool, index: Int?)
    }

    init(model: EditorModel) {
        self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: 1056, height: TimelineMetrics.height))
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        identifier = NSUserInterfaceItemIdentifier("voxclip.timeline.canvas")
        for lane in [overview, ruler, bed, audio] as [NSView] { addSubview(lane) }
        addSubview(overlay)
        configureAccessibility()
        toolTip = "Drag to scrub. Shift-drag snaps to word starts. Double-click a cut to restore it."
        layoutLanes()
        observations = [
            ShellObservation { [weak self] in self?.renderContent() },
            ShellObservation { [weak self] in self?.followPlayhead() }
        ]
    }
    required init?(coder: NSCoder) { nil }

    func tearDown() {
        observations.forEach { $0.cancel() }
        observations = []
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool {
        model.focusedPane = .timeline
        return true
    }

    /// The lane's width after the headers.
    private var laneWidth: Double { max(1, Double(bounds.width - TimelineMetrics.header)) }

    override func layout() {
        super.layout()
        layoutLanes()
    }

    private func layoutLanes() {
        let width = bounds.width
        overview.frame = NSRect(x: 0, y: TimelineMetrics.overview.y, width: width, height: TimelineMetrics.overview.height)
        ruler.frame = NSRect(x: 0, y: TimelineMetrics.ruler.y, width: width, height: TimelineMetrics.ruler.height)
        bed.frame = NSRect(x: 0, y: TimelineMetrics.ruler.maxY, width: width, height: max(0, bounds.height - TimelineMetrics.ruler.maxY))
        audio.frame = NSRect(x: 0, y: TimelineMetrics.audio.y, width: width, height: TimelineMetrics.audio.height)
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
        if paged != viewport, drag == nil || drag == .overview {
            viewport = paged
            apply()
        } else {
            placePlayhead()
        }
    }

    private func placePlayhead() {
        let overviewX = overview.x(playheadSource)
        overlay.movePlayhead(laneX: viewport.x(playheadTime), overviewX: overviewX)
        overlay.placeOverviewLabels(overview.labels(playheadX: overviewX), top: TimelineMetrics.overview.y)
    }

    /// Gives each lane what it draws. A lane redraws only when its own input changed.
    private func apply() {
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
        ruler.state = TimelineRulerLane.State(viewport: viewport, inOut: shownInOut, selection: content.selection)
        bed.state = TimelineTrackBed.State(width: Double(bounds.width))
        // On Source A1 dims outside the In/Out the ruler shows, the dragged edge included.
        audio.state = TimelineAudioLane.State(viewport: viewport, pieces: content.pieces, waveform: content.waveform, removed: content.removed,
                                              words: content.words, inOut: content.axis == .source ? shownInOut : nil,
                                              clip: content.axis == .source ? content.inOut : nil, takeLength: content.takeLength)
        let top = TimelineMetrics.tracks.first?.y ?? TimelineMetrics.ruler.maxY
        overlay.showWash(content.selection.map { range in
            let lower = viewport.x(range.lowerBound), upper = viewport.x(range.upperBound)
            return NSRect(x: lower, y: top, width: max(0, upper - lower), height: TimelineMetrics.tracksEnd - top)
        })
        placePlayhead()
        layoutAccessibility()
    }

    /// In and Out on the axis, with the edge being dragged at the word it would land on.
    private var shownInOut: ClosedRange<Double>? {
        guard let current = content.inOut else { return nil }
        guard case .trim(_, let start, let index)? = drag, let index, model.words.indices.contains(index) else { return current }
        let time = model.timelineTime(source: start ? model.words[index].start : model.words[index].end, on: content.axis)
        return start ? min(time, current.upperBound)...current.upperBound : current.lowerBound...max(time, current.lowerBound)
    }

    // MARK: Pointer and keys

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        guard point.x >= TimelineMetrics.header else { return }
        let laneX = Double(point.x - TimelineMetrics.header)
        if point.y < TimelineMetrics.overview.maxY {
            drag = .overview
            seekOverview(at: point.x)
            return
        }
        if point.y < TimelineMetrics.ruler.maxY, let target = trimTarget(at: point.x) {
            drag = .trim(clip: target.clip, start: target.start, index: nil)
            return
        }
        if event.clickCount == 2, point.y >= TimelineMetrics.ruler.maxY {
            model.restoreCut(at: viewport.time(atX: laneX), on: content.axis, tolerance: Double(TimelineMetrics.reach) / viewport.ptPerSecond)
            return
        }
        drag = .scrub
        model.seekTimeline(viewport.time(atX: laneX), on: content.axis, snap: event.modifierFlags.contains(.shift))
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let laneX = Double(point.x - TimelineMetrics.header)
        switch drag {
        case .overview?: seekOverview(at: point.x)
        case .scrub?: model.seekTimeline(viewport.time(atX: laneX), on: content.axis, snap: event.modifierFlags.contains(.shift))
        case .trim(let clip, let start, _)?:
            drag = .trim(clip: clip, start: start, index: model.timelineTrimIndex(clip, start: start, time: viewport.time(atX: laneX), on: content.axis))
            apply()
        case nil: break
        }
    }

    override func mouseUp(with event: NSEvent) {
        let ended = drag
        drag = nil
        if case .trim(let clip, let start, let index?)? = ended {
            model.trimClip(clip, start: start, index: index)
            // The trimmed clip at the zoom it was dropped at, so the edge stays under the pointer.
            renderContent(keepingZoom: true)
        } else {
            apply()
        }
        // A scrub may have left the playhead off the lanes: page to it now the pointer is up.
        followPlayhead()
    }

    /// The open clip's In or Out under `x` in the ruler, within reach, while it can be trimmed.
    private func trimTarget(at x: CGFloat) -> (clip: ClipRange, start: Bool)? {
        guard model.capabilities.edit, let clip = model.activeClip, let inOut = content.inOut else { return nil }
        let inX = TimelineMetrics.header + viewport.x(inOut.lowerBound), outX = TimelineMetrics.header + viewport.x(inOut.upperBound)
        let toIn = abs(x - inX), toOut = abs(x - outX)
        guard min(toIn, toOut) <= TimelineMetrics.reach else { return nil }
        return (clip, toIn <= toOut)
    }

    private func seekOverview(at x: CGFloat) {
        guard content.takeLength > 0 else { return }
        model.seek(source: overview.time(atX: x).clamped(to: 0...content.takeLength))
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaX : event.scrollingDeltaX * 10
        guard delta != 0 else { super.scrollWheel(with: event); return }
        let panned = viewport.panned(by: -Double(delta), within: 0...max(content.length, 1))
        // A swipe against the content's end moves nothing and keeps the fit.
        guard panned != viewport else { return }
        fitted = false
        viewport = panned
        apply()
    }

    override func keyDown(with event: NSEvent) {
        if !Self.handleKey(event.keyCode, shift: event.modifierFlags.contains(.shift), model: model) { super.keyDown(with: event) }
    }

    /// The timeline's own keys (Space, J/K/L, I/O and [ ] are menu commands): ← and → step a
    /// word, with ⇧ a sentence; Home and End go to the scope's bounds. True when handled.
    @discardableResult static func handleKey(_ code: UInt16, shift: Bool, model: EditorModel) -> Bool {
        switch code {
        case 123: model.step(-1, sentence: shift)
        case 124: model.step(1, sentence: shift)
        case 115: model.seekTimelineBoundary(end: false)
        case 119: model.seekTimelineBoundary(end: true)
        default: return false
        }
        return true
    }

    // MARK: Accessibility

    /// The playhead slider (its spoken value is design §5.2's) and, while a clip is open,
    /// its In and Out handles, which VoiceOver adjusts a word at a time.
    private func configureAccessibility() {
        setAccessibilityElement(false)
        playheadElement.setAccessibilityParent(self)
        playheadElement.setAccessibilityLabel("Playhead")
        playheadElement.setAccessibilityIdentifier("voxclip.timeline.playhead")
        playheadElement.read = { [weak self] in
            guard let self else { return (0, 0...0, "") }
            let axis = self.model.timelineAxis
            return (self.model.timelinePlayhead(on: axis), 0...max(0, self.model.timelineLength(on: axis)), self.model.timelineAccessibilityValue)
        }
        playheadElement.adjust = { [weak self] up in self?.model.step(up ? 1 : -1) }
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
        playheadElement.setAccessibilityFrameInParentSpace(NSRect(x: TimelineMetrics.header, y: 0, width: CGFloat(laneWidth), height: bounds.height))
        if let inOut, let number = model.activeClip.flatMap({ model.clipNumber($0.id) }) {
            inElement.setAccessibilityLabel("Clip \(number) start")
            outElement.setAccessibilityLabel("Clip \(number) end")
            for (element, time) in [(inElement, inOut.lowerBound), (outElement, inOut.upperBound)] {
                let x = TimelineMetrics.header + viewport.x(time)
                element.setAccessibilityFrameInParentSpace(NSRect(x: x - 5, y: TimelineMetrics.ruler.y, width: 10, height: TimelineMetrics.ruler.height))
            }
        }
    }

    override func accessibilityChildren() -> [Any]? {
        content.inOut == nil || model.activeClip == nil ? [playheadElement] : [playheadElement, inElement, outElement]
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
        NSRect(x: TimelineMetrics.header - 1, y: 0, width: 1, height: bounds.height).fill()
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

    private var laneWidth: CGFloat { max(1, bounds.width - TimelineMetrics.header - TimelineMetrics.trailing) }
    func x(_ time: Double) -> CGFloat {
        TimelineMetrics.header + CGFloat(time / max(0.001, state.takeLength)) * laneWidth
    }
    func time(atX x: CGFloat) -> Double { Double((x - TimelineMetrics.header) / laneWidth) * state.takeLength }
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
        let lane = NSRect(x: TimelineMetrics.header, y: 2, width: laneWidth, height: 20)
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
        Self.draw(state.takeLabel, font: length, color: DesignValues.nsColor("text.disabled"), x: TimelineMetrics.header - 6 - Self.width(state.takeLabel, font: length), baseline: 16)
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

    private func x(_ time: Double) -> CGFloat { TimelineMetrics.header + CGFloat(state.viewport.x(time)) }

    override func drawLane(in context: CGContext) {
        let height = bounds.height
        let lane = NSRect(x: TimelineMetrics.header, y: 0, width: max(0, bounds.width - TimelineMetrics.header), height: height)
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
        let laneEnd = TimelineMetrics.header + CGFloat(state.viewport.width) - TimelineMetrics.trailing
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

/// The ground of the track rows A1 does not draw: V1 and CC as flat lanes beside the
/// headers, until V9 fills them.
@MainActor final class TimelineTrackBed: TimelineLane {
    struct State: Equatable { var width = 0.0 }
    var state = State() { didSet { if state != oldValue { invalidate() } } }
    override func drawLane(in context: CGContext) {
        DesignValues.nsColor("timeline.lane").setFill()
        for row in TimelineMetrics.tracks where row != TimelineMetrics.audio {
            NSRect(x: TimelineMetrics.header, y: row.y - TimelineMetrics.ruler.maxY, width: max(0, bounds.width - TimelineMetrics.header), height: row.height).fill()
        }
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
    private func x(_ time: Double) -> CGFloat { TimelineMetrics.header + CGFloat(state.viewport.x(time)) }

    override func drawLane(in context: CGContext) {
        drawn = Drawn()
        let lane = NSRect(x: TimelineMetrics.header, y: 0, width: max(0, bounds.width - TimelineMetrics.header), height: bounds.height)
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
            draw(&outside, in: context, wave: "timeline.wave")
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
        let lower = max(TimelineMetrics.header, x(range.lowerBound).rounded(.down)), upper = min(laneRight, x(range.upperBound).rounded(.up))
        guard lower < upper else { return }
        let half = bounds.height / 2 - Self.pieceInset - Self.waveInset
        var column = lower
        while column < upper {
            let start = max(range.lowerBound, state.viewport.time(atX: Double(column - TimelineMetrics.header)))
            let end = min(range.upperBound, state.viewport.time(atX: Double(column + 1 - TimelineMetrics.header)))
            if end > start {
                let value = waveform.column(from: start + offset, to: end + offset, span: 1 / state.viewport.ptPerSecond)
                paint.column(Int(column - TimelineMetrics.header), peak: CGFloat(value.peak) * half, core: CGFloat(value.core) * half)
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
        Paint(origin: TimelineMetrics.header, points: Int(max(0, bounds.width - TimelineMetrics.header).rounded(.up)), height: bounds.height)
    }

    /// Fills `paint` and records what it drew.
    private func draw(_ paint: inout Paint, in context: CGContext, wave: String) {
        let drew = paint.draw(in: context, wave: wave)
        drawn.columns += drew.columns
        drawn.boxes += drew.boxes
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
        laneClip.frame = CGRect(x: TimelineMetrics.header, y: 0, width: max(0, bounds.width - TimelineMetrics.header), height: bounds.height)
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
