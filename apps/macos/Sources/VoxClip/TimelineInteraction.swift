import AppKit
import VoxClipCore

/// Pointer transactions for one canvas. Selection and the trim preview are transient;
/// the document changes only once, when an edge is released. Scrollers and header
/// controls own their hit regions before an event can reach this object.
@MainActor final class TimelineInteraction {
    unowned let canvas: TimelineCanvasView
    private var model: EditorModel { canvas.model }
    private struct Context: Equatable {
        let axis: TimelineAxis
        let scope: String?
        let revision: Int
    }
    private enum Drag {
        case overview
        case range(anchor: Double, point: NSPoint, moved: Bool)
        case trim(clip: ClipRange, start: Bool, point: NSPoint, index: Int?, time: Double?)
    }
    private var drag: Drag?
    private var context: Context?
    private(set) var selection: ClosedRange<Double>?
    private var keyAnchor: String?
    private var keyHead: String?
    private var keySelection: Set<String> = []
    var active: Bool { drag != nil }
    var followsPlayhead: Bool { if case .overview? = drag { return true }; return drag == nil }
    private var current: Context { Context(axis: model.timelineAxis, scope: model.activeClip?.id, revision: model.projectRevision) }
    init(canvas: TimelineCanvasView) { self.canvas = canvas }

    func cancel() { drag = nil; context = nil; selection = nil }
    func reconcile() { if active, context != current { cancel() } }
    func inOut(_ range: ClosedRange<Double>?) -> ClosedRange<Double>? {
        guard let range, case .trim(_, let start, _, _, let time?)? = drag else { return range }
        return start ? min(time, range.upperBound)...range.upperBound : range.lowerBound...max(time, range.lowerBound)
    }
    private func time(_ point: NSPoint) -> Double { canvas.viewport.time(atX: Double(point.x - canvas.headerWidth)) }
    private func snaps(_ event: NSEvent) -> Bool { !event.modifierFlags.contains(.option) && (model.timelineSnapping || event.modifierFlags.contains(.shift)) }

    func mouseDown(_ event: NSEvent) {
        canvas.window?.makeFirstResponder(canvas)
        cancel(); keyAnchor = nil; keyHead = nil
        let point = canvas.convert(event.locationInWindow, from: nil)
        guard point.x >= canvas.headerWidth, point.y >= 0, point.y < canvas.bounds.height - 10 else { return }
        context = current
        if point.y < TimelineMetrics.overview.maxY {
            drag = .overview
            seekOverview(point)
        } else if point.y < TimelineMetrics.ruler.maxY, let target = trimTarget(point) {
            drag = .trim(clip: target.0, start: target.1, point: point, index: nil, time: nil)
        } else if event.clickCount == 2, point.y >= TimelineMetrics.ruler.maxY {
            model.restoreCut(at: time(point), on: model.timelineAxis, tolerance: Double(TimelineMetrics.reach) / canvas.viewport.ptPerSecond)
        } else {
            drag = .range(anchor: time(point), point: point, moved: false)
            model.selectedWordIDs = []; model.selectedPauseIDs = []
            model.seekTimeline(time(point), on: model.timelineAxis)
        }
        canvas.apply()
    }
    func mouseDragged(_ event: NSEvent) {
        reconcile()
        let point = canvas.convert(event.locationInWindow, from: nil)
        switch drag {
        case .overview?: seekOverview(point)
        case .range(let anchor, let start, let moved)?:
            guard moved || hypot(point.x - start.x, point.y - start.y) >= 3 else { return }
            drag = .range(anchor: anchor, point: start, moved: true)
            selection = model.selectTimeline(from: anchor, to: time(point), on: model.timelineAxis, snap: snaps(event))
            // Update immediately; Observation will take the same IDs on its next turn.
            canvas.renderContent()
        case .trim(let clip, let start, let press, _, let preview)?:
            guard preview != nil || hypot(point.x - press.x, point.y - press.y) >= 3 else { return }
            let snap = snaps(event)
            let index = model.timelineTrimIndex(clip, start: start, time: time(point), on: model.timelineAxis, snap: snap)
            let edge = index.map { model.timelineTime(source: start ? model.words[$0].start : model.words[$0].end, on: model.timelineAxis) }
            let raw = time(point).clamped(to: 0...max(0, model.timelineLength(on: model.timelineAxis)))
            drag = .trim(clip: clip, start: start, point: press, index: index, time: snap ? edge : raw)
            canvas.apply()
        case nil: break
        }
    }
    func mouseUp(_ event: NSEvent) {
        reconcile()
        // Take the final position too, even if AppKit coalesced the last drag event.
        if active { mouseDragged(event) }
        let ended = drag
        cancel()
        if case .trim(let clip, let start, _, let index?, _)? = ended {
            model.trimClip(clip, start: start, index: index)
            canvas.renderContent(keepingZoom: true)
        } else { canvas.renderContent() }
        canvas.followPlayhead()
    }
    private func trimTarget(_ point: NSPoint) -> (ClipRange, Bool)? {
        guard model.capabilities.edit, let clip = model.activeClip, let range = canvas.content.inOut else { return nil }
        let lower = canvas.headerWidth + canvas.viewport.x(range.lowerBound)
        let upper = canvas.headerWidth + canvas.viewport.x(range.upperBound)
        let left = abs(point.x - lower), right = abs(point.x - upper)
        guard min(left, right) <= TimelineMetrics.reach else { return nil }
        return (clip, left <= right)
    }
    private func seekOverview(_ point: NSPoint) {
        guard canvas.content.takeLength > 0 else { return }
        model.seek(source: canvas.overview.time(atX: point.x).clamped(to: 0...canvas.content.takeLength))
    }

    /// Menu equivalents handle transport first. These fallbacks also work when a canvas
    /// is hosted on its own; Command/Control/Option combinations pass to the responder.
    func keyDown(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.isDisjoint(with: [.command, .control, .option]) else { return false }
        return key(event.keyCode, shift: event.modifierFlags.contains(.shift), characters: event.charactersIgnoringModifiers)
    }
    /// The SwiftUI pane's F6 stop forwards here too, retaining the same range anchor.
    func key(_ code: UInt16, shift: Bool, characters: String? = nil) -> Bool {
        if code == 53, case .trim? = drag {
            cancel(); canvas.apply(); return true
        }
        if code == 123 || code == 124 {
            let direction = code == 123 ? -1 : 1
            if !shift || keySelection != model.selectedWordIDs { keyAnchor = nil; keyHead = nil }
            if shift, keyAnchor == nil { keyAnchor = (direction < 0 ? model.selectedIDs.last : model.selectedIDs.first) ?? model.word(at: model.sourceTime, nearest: true)?.id }
            keyHead = model.stepTimeline(direction, sentence: shift, anchor: shift ? keyAnchor : nil, head: keyHead)
            keySelection = model.selectedWordIDs
            canvas.renderContent()
            return true
        }
        keyAnchor = nil; keyHead = nil
        return Self.handleKey(code, shift: shift, model: model, characters: characters)
    }
    @discardableResult static func handleKey(_ code: UInt16, shift: Bool, model: EditorModel, characters: String? = nil) -> Bool {
        switch code {
        case 123: _ = model.stepTimeline(-1, sentence: shift)
        case 124: _ = model.stepTimeline(1, sentence: shift)
        case 115: model.seekTimelineBoundary(end: false)
        case 119: model.seekTimelineBoundary(end: true)
        default:
            guard let key = characters?.lowercased(), ["j", "k", "l", "i", "o", " ", "p", "[", "]"].contains(key) else { return false }
            model.transport(key, shift: shift)
        }
        return true
    }
}
