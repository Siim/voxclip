import AppKit
import VoxClipCore

extension TimelineItemLane {
    var index: Int { Self.allCases.firstIndex(of: self)! }

    var title: String {
        switch self {
        case .captions: "Captions"
        case .titles: "Titles & effects"
        case .pictures: "B-roll & pictures"
        case .effects: "Zoom, looks & speed"
        case .video: "Video"
        case .voice: "Voice"
        case .sounds: "Sounds"
        case .music: "Music"
        }
    }

    var hint: String {
        switch self {
        case .titles: "Add a title with Titles & effects"
        case .pictures: "Add B-roll with ✦ Ask Claude"
        case .effects: "Add motion with FX +"
        case .sounds: "Add a sound with ✦ Ask Claude"
        case .music: "Choose background music"
        default: ""
        }
    }
}

struct TimelineItemDisplay: Equatable {
    let item: TimelineItem
    let title: String
    let kind: String
    let ranges: [TimeRange]
    let marker: Double?

    var movable: Bool {
        switch item.id {
        case .clip, .voice, .contextDemo: false
        default: true
        }
    }
    var wordLocked: Bool { item.kind == "bleep" || item.kind == "mute" }

    func accessibilityLabel(selected: Bool) -> String {
        let times = ranges.first.flatMap { first in ranges.last.map { "\(timelineItemTime(first.start)) to \(timelineItemTime($0.end))" } }
        let name = kind == title ? kind : "\(kind), \(title)"
        return [name, times ?? item.reason, selected ? "selected" : nil].compactMap { $0 }.joined(separator: ", ")
    }
}

func timelineItemTime(_ seconds: Double) -> String {
    let tenths = Int((min(abs(seconds), Double(Int32.max)) * 10).rounded())
    return String(format: "%d:%02d.%d", tenths / 600, tenths / 10 % 60, tenths % 10)
}

func timelineItemDelta(_ seconds: Double) -> String { (seconds < 0 ? "−" : "+") + timelineItemTime(seconds) }

struct TimelineItemFragment: Equatable {
    let display: TimelineItemDisplay
    let range: TimeRange
    let rect: NSRect
    let hasStart: Bool
    let hasEnd: Bool

    func grip(_ edge: TimelineEdge) -> NSRect {
        let reach = min(rect.width / 3, rect.width < 26 ? 8 : 6)
        return NSRect(x: edge == .start ? rect.minX : rect.maxX - reach, y: rect.minY, width: reach, height: rect.height)
    }

    func edge(at point: NSPoint) -> TimelineEdge? {
        guard display.movable else { return nil }
        if hasStart, grip(.start).contains(point) { return .start }
        if hasEnd, grip(.end).contains(point) { return .end }
        return nil
    }
}

@MainActor final class TimelineConnectedLane: TimelineLane {
    struct State: Equatable {
        var fragments: [TimelineItemFragment] = []
        var selected: Set<TimelineItemID> = []
        var hasItems = false
    }

    let kind: TimelineItemLane
    var state = State() { didSet { if state != oldValue { invalidate() } } }

    init(_ kind: TimelineItemLane) {
        self.kind = kind
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    private var color: NSColor {
        switch kind {
        case .titles: .systemPurple
        case .pictures: .systemBlue
        case .effects: .systemOrange
        case .sounds: .systemTeal
        case .music: .systemIndigo
        default: DesignValues.nsColor("timeline.cue")
        }
    }

    override func drawLane(in context: CGContext) {
        let lane = CGRect(x: headerWidth, y: 0, width: max(0, bounds.width - headerWidth), height: bounds.height)
        context.setFillColor(DesignValues.nsColor("timeline.lane").cgColor)
        context.fill(lane)
        context.saveGState()
        context.clip(to: lane)
        defer { context.restoreGState() }
        let font = NSFont.systemFont(ofSize: 11)
        if !state.hasItems {
            Self.draw(kind.hint, font: font, color: DesignValues.nsColor("text.disabled"), x: headerWidth + 10,
                      baseline: bounds.midY + font.xHeight / 2)
        }
        for fragment in state.fragments where fragment.rect.intersects(lane) {
            let rect = fragment.rect
            let path = CGPath(roundedRect: rect, cornerWidth: 3, cornerHeight: 3, transform: nil)
            context.addPath(path)
            context.setFillColor(color.withAlphaComponent(fragment.display.item.hidden ? 0.28 : 0.65).cgColor)
            context.fillPath()
            if state.selected.contains(fragment.display.item.id) {
                context.addPath(path)
                context.setStrokeColor(DesignValues.nsColor("text.primary").cgColor)
                context.setLineWidth(1.5)
                context.strokePath()
                if fragment.display.movable {
                    for edge: TimelineEdge in [.start, .end] where edge == .start ? fragment.hasStart : fragment.hasEnd {
                        context.setFillColor(DesignValues.nsColor("text.primary").cgColor)
                        context.fill(fragment.grip(edge).insetBy(dx: 1, dy: 3))
                    }
                }
            }
            guard rect.width > 20 else { continue }
            context.saveGState()
            context.clip(to: rect.insetBy(dx: 3, dy: 0))
            Self.draw(fragment.display.title, font: font, color: .white, x: rect.minX + 8, baseline: rect.midY + font.xHeight / 2)
            context.restoreGState()
        }
    }
}

struct TimelineItemPreview: Equatable {
    let rectangles: [NSRect]
    let readout: String?
    let point: NSPoint
    let guide: Double?
    var marquee = false
}

@MainActor final class TimelineItemOverlay: NSView {
    var preview: TimelineItemPreview? { didSet { if preview != oldValue { needsDisplay = true } } }
    var clip = NSRect.zero
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let preview else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: clip).addClip()
        for rect in preview.rectangles {
            let outline = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
            let color = preview.marquee ? NSColor.systemBlue : NSColor.white
            color.withAlphaComponent(0.2).setFill()
            outline.fill()
            color.setStroke()
            outline.stroke()
        }
        if let guide = preview.guide {
            NSColor.systemYellow.setFill()
            NSRect(x: guide - 0.5, y: clip.minY, width: 1, height: clip.height).fill()
        }
        guard let readout = preview.readout else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white]
        let size = (readout as NSString).size(withAttributes: attributes)
        let rect = NSRect(x: max(clip.minX, min(preview.point.x + 10, clip.maxX - size.width - 12)),
                          y: max(clip.minY, min(preview.point.y - 24, clip.maxY - size.height - 8)),
                          width: size.width + 12, height: size.height + 8)
        NSColor.black.withAlphaComponent(0.9).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
        (readout as NSString).draw(at: NSPoint(x: rect.minX + 6, y: rect.minY + 4), withAttributes: attributes)
    }
}

extension TimelineCanvasView {
    var itemClip: NSRect {
        NSRect(x: headerWidth, y: trackClip.frame.minY, width: max(0, trackClip.frame.width - headerWidth), height: trackClip.frame.height)
    }

    func updateTimelineItems() {
        var fragments: [TimelineItemFragment] = []
        for display in content.items {
            let item = display.item
            let lane = trackLanes[item.lane.index]
            let height = trackHeight.heights[item.lane.index]
            let isSpeech = item.lane == .video || item.lane == .voice
            let y = trackClip.frame.minY + lane.frame.minY + 2 + (isSpeech ? 0 : height * CGFloat(item.row))
            let ranges = display.marker.map { [TimeRange(start: $0, end: $0)] } ?? display.ranges
            for (index, range) in ranges.enumerated() {
                let lower = headerWidth + viewport.x(range.start)
                let upper = headerWidth + viewport.x(range.end)
                let rect = NSRect(x: lower, y: y, width: max(item.hidden ? 5 : 1, upper - lower - 1), height: isSpeech ? 15 : height - 4)
                guard rect.intersects(itemClip) else { continue }
                fragments.append(.init(display: display, range: range, rect: rect,
                                       hasStart: !item.hidden && index == 0, hasEnd: !item.hidden && index == ranges.count - 1))
            }
        }
        itemFragments = fragments
        itemOverlay.clip = itemClip
        for lane in connectedLanes {
            let offset = lane.frame.minY + trackClip.frame.minY
            let local = fragments.filter { $0.display.item.lane == lane.kind }.map { fragment in
                TimelineItemFragment(display: fragment.display, range: fragment.range, rect: fragment.rect.offsetBy(dx: 0, dy: -offset),
                                     hasStart: fragment.hasStart, hasEnd: fragment.hasEnd)
            }
            lane.state = .init(fragments: local, selected: model.timelineItemSelection,
                               hasItems: content.items.contains { $0.item.lane == lane.kind })
        }
    }

    var itemEdgeCursorRects: [NSRect] {
        guard model.capabilities.edit else { return [] }
        return itemFragments.flatMap { fragment -> [NSRect] in
            guard fragment.display.movable else { return [] }
            return [(TimelineEdge.start, fragment.hasStart), (.end, fragment.hasEnd)].compactMap { edge, exists in
                guard exists else { return nil }
                let rect = fragment.grip(edge).intersection(itemClip)
                return rect.isEmpty ? nil : rect
            }
        }
    }

    func item(at point: NSPoint) -> TimelineItemFragment? {
        guard itemClip.contains(point) else { return nil }
        return itemFragments.last { fragment in
            if case .clip = fragment.display.item.id { return false }
            return fragment.rect.contains(point)
        }
    }

    func isConnectedLane(at point: NSPoint) -> Bool {
        itemClip.contains(point) && connectedLanes.contains { $0.frame.contains(convert(point, to: trackClip)) }
    }

    func openItem(_ id: TimelineItemID) {
        switch id {
        case .effect(let id): model.adjustAskClaudeEffect(fromTimeline: id)
        case .motion(let id): openMotionCue(id: id)
        case .music: (shell ?? model.app.shell).showMusic(for: model)
        case .footage, .contextDemo:
            if let span = model.timelineItemSpan(id) {
                model.openAskClaude(.init(scope: .time(span), clipID: model.activeClip?.id))
            }
        default: break
        }
    }

    var selectedItemIDs: [TimelineItemID] {
        content.items.map(\.item.id).filter { model.timelineItemSelection.contains($0) }
    }

    func itemSourceTime(_ time: Double) -> Double {
        if content.axis == .source { return model.timelineSourceTime(time, on: .source) }
        guard let plan = model.plan else { return model.timelineSourceTime(time, on: .edited) }
        if time >= plan.duration, let last = plan.kept.last { return Double(last.endSample) / plan.sampleRate }
        return TimelineItems.sourceAnchor(at: max(0, time), axis: .edited, plan: plan)
    }

    func snapItemTime(_ time: Double, excluding ids: Set<TimelineItemID>, wordsOnly: Bool, reach: Double) -> Double? {
        let playhead = model.timelinePlayhead(on: content.axis)
        var closest: Double? = !wordsOnly && abs(playhead - time) <= reach ? playhead : nil
        var distance = closest.map { abs($0 - time) } ?? reach
        for target in content.itemLayout?.snapTargets ?? [] {
            if wordsOnly && target.kind != .word { continue }
            if let id = target.item, ids.contains(id) { continue }
            let candidate = content.axis == .source ? content.story?.time(forSource: target.time) ?? target.time : target.time
            let gap = abs(candidate - time)
            if gap < distance || (closest == nil && gap == distance) { closest = candidate; distance = gap }
        }
        return closest
    }

    func selectAndRevealItem(_ item: TimelineItemDisplay) {
        model.selectTimelineItems([item.item.id])
        let row = trackRows[item.item.lane.index]
        let top = row.y + CGFloat(item.item.row) * trackHeight.heights[item.item.lane.index]
        let bottom = min(row.maxY, top + trackHeight.heights[item.item.lane.index])
        revealItem(time: item.ranges.first?.start ?? item.marker, top: top, bottom: bottom)
    }
}
