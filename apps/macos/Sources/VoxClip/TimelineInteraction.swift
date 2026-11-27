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
        let showsSurroundingContext: Bool
    }
    private enum Drag {
        case overview
        case range(anchor: Double, point: NSPoint, moved: Bool)
        case trim(clip: ClipRange, start: Bool, point: NSPoint, index: Int?, time: Double?)
        case item(ItemDrag)
        case marquee(point: NSPoint, original: Set<TimelineItemID>, additive: Bool)
    }
    private enum ItemGesture {
        case move(duplicate: Bool), trim(TimelineEdge), fade(TimelineEdge), slip
        case volume, addKeyframe, keyframe(GainPoint, time: Double), audioRange, dip(ClosedRange<Double>)
    }
    private struct ItemDrag {
        let fragment: TimelineItemFragment
        let point: NSPoint
        let gesture: ItemGesture
        let ids: [TimelineItemID]
        let collapseOnClick: Bool
    }
    private var drag: Drag?
    private var itemCommand: TimelineEdit?
    private var heldSnapKey = false
    private var pointer: NSPoint?
    private var pointerFlags: NSEvent.ModifierFlags = []
    private var context: Context?
    private var audioSelection: (id: TimelineItemID, time: ClosedRange<Double>, context: Context)?
    private var audioRangePreview: ClosedRange<Double>?
    private(set) var selection: ClosedRange<Double>?
    private var keyAnchor: String?
    private var keyHead: String?
    private var keySelection: Set<String> = []
    var active: Bool { drag != nil }
    var trimHint: String? {
        guard case .trim(_, let start, _, let index?, _) = drag else { return nil }
        return "\(start ? "In" : "Out"): \(model.text(model.words[index]).prefix(24))"
    }
    var followsPlayhead: Bool { if case .overview? = drag { return true }; return drag == nil }
    private var current: Context { Context(axis: model.timelineAxis, scope: model.activeClip?.id, revision: model.projectRevision, showsSurroundingContext: model.showsSurroundingContext) }
    init(canvas: TimelineCanvasView) { self.canvas = canvas }

    func cancel(keepingAudioSelection: Bool = false) {
        drag = nil; context = nil; selection = nil; itemCommand = nil; pointer = nil; heldSnapKey = false
        audioRangePreview = nil
        if !keepingAudioSelection { audioSelection = nil }
        updateAudioSelection()
        canvas.itemOverlay.preview = nil
    }
    func reconcile() {
        if (active && context != current) || (audioSelection != nil && audioSelection?.context != current) { cancel() }
    }

    func updateAudioSelection() {
        guard let audioSelection, model.timelineItemSelection.contains(audioSelection.id) else {
            canvas.itemOverlay.audioSelection = []; return
        }
        canvas.itemOverlay.audioSelection = audioSelectionRects(audioSelection.time, id: audioSelection.id)
    }

    private func audioSelectionRects(_ time: ClosedRange<Double>, id: TimelineItemID) -> [NSRect] {
        canvas.itemFragments.compactMap { fragment in
            guard fragment.display.item.id == id else { return nil }
            let start = max(fragment.range.start, time.lowerBound), end = min(fragment.range.end, time.upperBound)
            guard end > start else { return nil }
            let x = canvas.headerWidth + canvas.viewport.x(start)
            return NSRect(x: x, y: fragment.rect.minY, width: canvas.viewport.x(end) - canvas.viewport.x(start), height: fragment.rect.height)
        }
    }
    func inOut(_ range: ClosedRange<Double>?) -> ClosedRange<Double>? {
        guard let range, case .trim(_, let start, _, _, let time?)? = drag else { return range }
        return start ? min(time, range.upperBound)...range.upperBound : range.lowerBound...max(time, range.lowerBound)
    }
    private func time(_ point: NSPoint) -> Double { canvas.viewport.time(atX: Double(point.x - canvas.headerWidth)) }
    private func snaps(_ event: NSEvent) -> Bool {
        !heldSnapKey && !event.modifierFlags.contains(.option) && (model.timelineSnapping || event.modifierFlags.contains(.shift))
    }

    func mouseDown(_ event: NSEvent) {
        canvas.window?.makeFirstResponder(canvas)
        reconcile(); cancel(keepingAudioSelection: true); keyAnchor = nil; keyHead = nil
        let point = canvas.convert(event.locationInWindow, from: nil)
        guard point.x >= canvas.headerWidth, point.y >= 0, point.y < canvas.bounds.height - 10 else { return }
        context = current
        if let hit = canvas.item(at: point) {
            let id = hit.display.item.id
            let original = model.timelineItemSelection
            let selectedHandle = original.contains(id)
            let edge = hit.edge(at: point)
            let audioHandles = hit.display.audio != nil
            let fadeEdge = selectedHandle || audioHandles ? [TimelineEdge.start, .end].first { hit.fadeGrip($0)?.contains(point) == true } : nil
            let slip = hit.display.mediaStart != nil && !hit.display.item.hidden && edge == nil && fadeEdge == nil &&
                (((selectedHandle || audioHandles) && hit.slipGrip?.contains(point) == true) || event.modifierFlags.contains([.option, .command]))
            let additive = !slip && !event.modifierFlags.isDisjoint(with: [.shift, .command])
            var selected: Set<TimelineItemID> = additive ? original : [id]
            if additive, !selected.insert(id).inserted { selected.remove(id) }
            let preserveGroup = !additive && event.clickCount == 1 && hit.display.movable && original.contains(id)
            if preserveGroup { selected = original }
            model.selectTimelineItems(selected)
            if event.clickCount == 2 { canvas.openItem(id) }
            else if selected.contains(id), hit.display.movable, model.capabilities.edit {
                let part = hit.display.item.lane == .video
                let gesture: ItemGesture
                if let fadeEdge { gesture = .fade(fadeEdge) }
                else if let edge { gesture = .trim(edge) }
                else if slip { gesture = .slip }
                else if hit.volumeHit(point), event.modifierFlags.contains(.option) { gesture = .addKeyframe }
                else if let keyframe = hit.volumePoint(at: point) {
                    gesture = .keyframe(keyframe.gain, time: time(keyframe.center))
                }
                else if hit.volumeHit(point), let range = audioSelection, range.id == id, range.time.contains(time(point)) {
                    gesture = .dip(range.time)
                }
                else if hit.volumeHit(point) { gesture = .volume }
                else if audioHandles, original == [id], point.y > hit.rect.midY, event.modifierFlags.isDisjoint(with: [.option, .command, .shift]) {
                    gesture = .audioRange
                }
                else { gesture = .move(duplicate: !part && event.modifierFlags.contains(.option)) }
                if case .dip = gesture {} else { audioSelection = nil }
                var ids = [id]
                if case .move = gesture, !part { ids += canvas.selectedItemIDs.filter { $0 != id } }
                drag = .item(.init(fragment: hit, point: point, gesture: gesture, ids: ids, collapseOnClick: preserveGroup))
            }
        } else if canvas.isConnectedLane(at: point) {
            audioSelection = nil
            let additive = !event.modifierFlags.isDisjoint(with: [.shift, .command])
            drag = .marquee(point: point, original: model.timelineItemSelection, additive: additive)
            if !additive { model.selectTimelineItems([]) }
        } else if point.y < TimelineMetrics.overview.maxY {
            drag = .overview
            seekOverview(point)
        } else if point.y < TimelineMetrics.ruler.maxY, let target = trimTarget(point) {
            model.selectTimelineItems([])
            drag = .trim(clip: target.0, start: target.1, point: point, index: nil, time: nil)
        } else if event.clickCount == 2, point.y >= TimelineMetrics.ruler.maxY {
            model.restoreCut(at: time(point), on: model.timelineAxis, tolerance: Double(TimelineMetrics.reach) / canvas.viewport.ptPerSecond)
        } else {
            model.selectTimelineItems([])
            drag = .range(anchor: time(point), point: point, moved: false)
            model.selectedWordIDs = []; model.selectedPauseIDs = []
            model.askClaude.timeRange = nil
            model.seekTimeline(time(point), on: model.timelineAxis)
        }
        canvas.apply()
    }
    func mouseDragged(_ event: NSEvent) {
        reconcile()
        let point = canvas.convert(event.locationInWindow, from: nil)
        switch drag {
        case .item(let transaction)?:
            pointer = point; pointerFlags = event.modifierFlags
            previewItem(transaction, at: point)
        case .marquee(let start, let original, let additive)?:
            guard hypot(point.x - start.x, point.y - start.y) >= 3 else {
                model.selectTimelineItems(additive ? original : [])
                canvas.itemOverlay.preview = nil; canvas.apply(); return
            }
            let rect = NSRect(x: min(point.x, start.x), y: min(point.y, start.y), width: max(1, abs(point.x - start.x)), height: max(1, abs(point.y - start.y)))
                .intersection(canvas.itemClip)
            let ids = Set(canvas.itemFragments.filter { fragment in
                canvas.connectedLanes.contains { $0.kind == fragment.display.item.lane } && fragment.rect.intersects(rect)
            }.map { $0.display.item.id })
            model.selectTimelineItems(additive ? original.union(ids) : ids)
            canvas.itemOverlay.preview = .init(rectangles: [rect], readout: nil, point: point, guide: nil, marquee: true)
            canvas.apply()
        case .overview?: seekOverview(point)
        case .range(let anchor, let start, let moved)?:
            guard moved || hypot(point.x - start.x, point.y - start.y) >= 3 else { return }
            drag = .range(anchor: anchor, point: start, moved: true)
            selection = model.selectTimeline(from: anchor, to: time(point), on: model.timelineAxis, snap: snaps(event))
            // Update immediately; Observation will take the same IDs on its next turn.
            canvas.renderContent()
        case .trim(let clip, let start, let press, _, let preview)?:
            guard hypot(point.x - press.x, point.y - press.y) >= 3 else {
                if preview != nil { drag = .trim(clip: clip, start: start, point: press, index: nil, time: nil); canvas.apply() }
                return
            }
            let snap = snaps(event)
            let index = model.timelineTrimIndex(clip, start: start, time: time(point), on: model.timelineAxis, snap: snap)
            let edge = index.flatMap { i -> Double? in
                guard let first = model.index(clip.startWordId), let last = model.index(clip.endWordId),
                      let span = try? clipTimes(model.words, startIndex: start ? i : first, endIndex: start ? last : i,
                                                leadIn: start && i != first ? nil : clip.leadInSeconds) else { return nil }
                return model.timelineTime(source: start ? span.start : span.end, on: model.timelineAxis)
            }
            drag = .trim(clip: clip, start: start, point: press, index: index, time: edge)
            canvas.apply()
        case nil: break
        }
    }
    func mouseUp(_ event: NSEvent) {
        reconcile()
        // Take the final position too, even if AppKit coalesced the last drag event.
        if active { mouseDragged(event) }
        let ended = drag
        let dragged = selection
        let command = itemCommand
        if case .item(let item)? = ended {
            if case .audioRange = item.gesture, let range = audioRangePreview {
                audioSelection = (item.fragment.display.item.id, range, current)
            }
        }
        let keepRange: Bool
        if case .item(let item)? = ended, case .audioRange = item.gesture { keepRange = true }
        else { keepRange = false }
        cancel(keepingAudioSelection: keepRange)
        if let command { model.commitTimelineItemEdit(command) }
        else if case .item(let transaction)? = ended, transaction.collapseOnClick {
            model.selectTimelineItems([transaction.fragment.display.item.id])
        }
        // A dragged range is what the toolbar's ✦ Ask Claude asks about (design.md §6.8), in source seconds.
        if case .range(_, _, true)? = ended, let dragged {
            let axis = model.timelineAxis
            let lower = model.timelineSourceTime(dragged.lowerBound, on: axis), upper = model.timelineSourceTime(dragged.upperBound, on: axis)
            model.askClaude.timeRange = upper - lower >= 0.1 ? lower...upper : nil
        }
        if case .trim(let clip, let start, _, let index?, _)? = ended {
            model.trimClip(clip, start: start, index: index)
            canvas.renderContent(keepingZoom: true)
        } else { canvas.renderContent() }
        canvas.followPlayhead()
    }

    private func previewItem(_ transaction: ItemDrag, at point: NSPoint) {
        guard hypot(point.x - transaction.point.x, point.y - transaction.point.y) >= 3 else {
            audioRangePreview = nil
            if case .addKeyframe = transaction.gesture {
                let fragment = transaction.fragment
                let source = canvas.itemSourceTime(time(transaction.point))
                let edited = canvas.itemPlan?.mapTime(source) ?? fragment.editedTime(atX: transaction.point.x)
                itemCommand = model.timelineAddKeyframe(fragment.display, source: source, edited: edited)
            } else { itemCommand = nil }
            canvas.itemOverlay.preview = nil; return
        }
        let fragment = transaction.fragment
        let display = fragment.display
        let id = display.item.id
        let scale = canvas.viewport.ptPerSecond
        let delta = (point.x - transaction.point.x) / scale
        let excluded = Set(transaction.ids)
        switch transaction.gesture {
        case .addKeyframe:
            itemCommand = nil; canvas.itemOverlay.preview = nil; return
        case .volume:
            guard let audio = display.audio else { return }
            let change = (transaction.point.y - point.y) * fragment.dbPerPoint
            let db = ((2 * (audio.gainDb + change)).rounded() / 2).clamped(to: audio.gainRange)
            showItemPreview(audio.setGain(id, db: db), ids: excluded, at: point, readout: timelineItemDecibels(db), guide: nil)
            return
        case .keyframe(let keyframe, let position):
            guard let audio = display.audio, let lower = display.ranges.first?.start, let upper = display.ranges.last?.end else { return }
            let raw = (position + delta).clamped(to: lower...upper)
            let target = !heldSnapKey && model.timelineSnapping && !pointerFlags.contains(.option)
                ? canvas.snapItemTime(raw, excluding: excluded, wordsOnly: false, reach: 8 / scale) : nil
            let source = canvas.itemSourceTime((target ?? raw).clamped(to: lower...upper))
            let change = (transaction.point.y - point.y) * fragment.dbPerPoint
            let db = ((2 * (keyframe.db + change)).rounded() / 2).clamped(to: -60...12)
            let command = TimelineEdit.moveGainPoint(item: id, from: keyframe.t, toSource: source, db: db)
            showItemPreview(command, ids: excluded, at: point, readout: timelineItemDecibels(audio.gainDb + db),
                            guide: target.map { canvas.headerWidth + canvas.viewport.x($0) })
            return
        case .audioRange:
            guard let first = display.ranges.first, let last = display.ranges.last else { return }
            let anchor = time(transaction.point).clamped(to: first.start...last.end)
            let end = time(point).clamped(to: first.start...last.end)
            let range = min(anchor, end)...max(anchor, end)
            audioRangePreview = range
            canvas.itemOverlay.preview = .init(rectangles: audioSelectionRects(range, id: id), readout: nil, point: point, guide: nil)
            return
        case .dip(let range):
            let db = min(0, ((transaction.point.y - point.y) * fragment.dbPerPoint * 2).rounded() / 2)
            let readout = "\(timelineItemTime(range.lowerBound))–\(timelineItemTime(range.upperBound)) · \(timelineItemDecibels(db))"
            let command = TimelineEdit.dipGain(item: id, fromSource: canvas.itemSourceTime(range.lowerBound),
                                               toSource: canvas.itemSourceTime(range.upperBound), byDb: db)
            showItemPreview(command, ids: excluded, at: point, readout: readout, guide: nil)
            return
        case .fade(let edge):
            guard let fades = display.fades else { return }
            let value = (fades[edge] + (edge == .start ? delta : -delta)).clamped(to: 0...fades.maximum)
            let readout = "Fade \(edge == .start ? "in" : "out") \(String(format: "%.1f s", value))"
            showItemPreview(.fade(item: id, edge: edge, seconds: value), ids: excluded, at: point, readout: readout, guide: nil)
            return
        case .slip:
            guard let start = display.mediaStart else { return }
            let media = display.audio.map { $0.music == nil ? "sound" : "song" } ?? "recording"
            let readout = "Slip \(timelineItemDelta(delta)) · \(media) \(timelineItemTime(start)) → \(timelineItemTime(start + delta))"
            showItemPreview(.slip(item: id, bySeconds: delta), ids: excluded, at: point, readout: readout, guide: nil)
            return
        default: break
        }
        let trimEdge: TimelineEdge? = if case .trim(let edge) = transaction.gesture { edge } else { nil }
        let start = display.ranges.first?.start ?? display.marker ?? fragment.range.start
        let end = display.ranges.last?.end ?? start
        let base = trimEdge == .end ? end : start
        let raw = base + delta
        let part = display.item.lane == .video
        let locked = display.wordLocked || (part && trimEdge != nil)
        let partEdge = part ? trimEdge : nil
        let sourceEdge = partEdge.flatMap { edge in model.timelineItemSpan(id).map { edge == .start ? $0.lowerBound : $0.upperBound } }
        let sourceWordEdge = sourceEdge.flatMap { base in
            partEdge.flatMap { edge in model.timelineWordEdge(near: base + delta, edge: edge) }
        }
        let target: Double?
        if let sourceEdge, let sourceWordEdge { target = base + sourceWordEdge - sourceEdge }
        else if part { target = nil }
        else if locked || (!heldSnapKey && model.timelineSnapping && !pointerFlags.contains(.option)) {
            target = canvas.snapItemTime(raw, excluding: excluded, wordsOnly: locked, reach: locked ? .infinity : 8 / scale)
        } else { target = nil }
        let snapped = target ?? raw
        let shift = snapped - base
        var source = canvas.itemSourceTime(snapped)
        let readout: String
        let command: TimelineEdit
        if let edge = trimEdge {
            if let sourceWordEdge {
                source = sourceWordEdge
            } else if edge == .end, canvas.content.axis == .edited,
                      let rate = model.renderTimeline?.sampleRate, snapped > 0 {
                source = canvas.itemSourceTime(max(0, snapped - 1 / rate)) + 1 / rate
            }
            command = .trim(item: id, edge: edge, toSource: source)
            let length = max(0, (display.audio?.length ?? (end - start)) + (edge == .start ? -shift : shift))
            if edge == .end, let audio = display.audio, audio.loop, length > audio.mediaDuration - audio.mediaStart {
                let loops = Int(ceil((length - (audio.mediaDuration - audio.mediaStart)) / audio.mediaDuration))
                readout = "∞ \(loops) \(loops == 1 ? "loop" : "loops") · \(String(format: "%.1f s", length))"
            } else {
                readout = "\(edge == .start ? "In" : "Out") \(timelineItemDelta(shift)) · \(String(format: "%.1f s", length))"
            }
        } else {
            if part { source = canvas.itemSourceTime(time(point)) }
            if case .move(duplicate: true) = transaction.gesture {
                command = .duplicate(items: transaction.ids, toAnchor: source)
            } else {
                command = .move(items: transaction.ids, toAnchor: source)
            }
            let word = model.word(at: source, nearest: true).map { " · on “\(model.text($0))”" } ?? ""
            let cut = canvas.content.axis == .source && model.plan?.cutContaining(source) != nil ? " · \(TimelineItems.cutDropCopy)" : ""
            readout = timelineItemDelta(shift) + word + cut
        }
        let guide = target.map { canvas.headerWidth + canvas.viewport.x($0) }
        showItemPreview(command, ids: excluded, at: point, readout: readout, guide: guide)
    }

    private func showItemPreview(_ command: TimelineEdit, ids: Set<TimelineItemID>, at point: NSPoint, readout: String, guide: Double?) {
        guard let plan = canvas.itemPlan else { return }
        itemCommand = command
        let original = canvas.itemFragments.filter { ids.contains($0.display.item.id) }.map(\.rect)
        let project = model.project
        let scope = model.itemEditScope
        let axis = canvas.content.axis
        switch TimelineEdits.apply(command, project: project, plan: plan, scope: scope) {
        case .failure(let refusal):
            canvas.itemOverlay.preview = .init(rectangles: original, readout: refusal.copy, point: point, guide: nil)
        case .success(let result):
            guard result.project != project else {
                canvas.itemOverlay.preview = .init(rectangles: original, readout: readout, point: point, guide: guide)
                return
            }
            let partsChanged = result.project.edits.clips != project.edits.clips
            let previewPlan = partsChanged ? (try? RenderCallerInputs.editPlan(project: result.project, clipID: scope)) ?? plan : plan
            let layout = TimelineItems.layout(project: result.project, plan: previewPlan, scope: scope, axis: axis)
            let visible: [TimelineItem]
            if case .duplicate = command {
                let existing = Set(canvas.content.items.map(\.item.id))
                visible = layout.items.filter { !existing.contains($0.id) }
            } else {
                visible = layout.items.filter { ids.contains($0.id) }
            }
            let displays = visible.map { model.timelineItemDisplay($0, axis: axis, story: canvas.content.story, preview: result.project) }
            let fragments = canvas.fragments(for: displays)
            let audio: [TimelineItemFragment]
            switch command {
            case .setGain, .setTrackGain, .moveGainPoint, .dipGain, .fade, .trim: audio = fragments.filter { $0.display.audio != nil }
            default: audio = []
            }
            canvas.itemOverlay.preview = .init(rectangles: fragments.map(\.rect), readout: readout, point: point, guide: guide,
                                               audio: audio, music: canvas.content.musicGraphics)
        }
    }

    func flagsChanged(_ flags: NSEvent.ModifierFlags) {
        pointerFlags = flags
        if case .item(let transaction)? = drag, let pointer { previewItem(transaction, at: pointer) }
    }

    func keyUp(_ event: NSEvent) -> Bool {
        guard event.keyCode == 45, heldSnapKey else { return false }
        heldSnapKey = false
        flagsChanged(event.modifierFlags)
        return true
    }
    private func trimTarget(_ point: NSPoint) -> (ClipRange, Bool)? {
        guard model.capabilities.edit, let clip = model.activeClip, clip.parts == nil, let range = canvas.content.inOut else { return nil }
        let lower = canvas.headerWidth + canvas.viewport.x(range.lowerBound)
        let upper = canvas.headerWidth + canvas.viewport.x(range.upperBound)
        let left = abs(point.x - lower), right = abs(point.x - upper)
        guard min(left, right) <= TimelineMetrics.trimReach else { return nil }
        return (clip, left <= right)
    }
    private func seekOverview(_ point: NSPoint) {
        guard canvas.content.takeLength > 0 else { return }
        model.seek(source: canvas.overview.time(atX: point.x).clamped(to: 0...canvas.content.takeLength))
    }

    /// Menu equivalents handle transport first. These fallbacks also work when a canvas
    /// is hosted on its own; Command/Control/Option combinations pass to the responder.
    func keyDown(_ event: NSEvent) -> Bool {
        if event.keyCode == 45, active, event.modifierFlags.isDisjoint(with: [.command, .control]) {
            heldSnapKey = true
            flagsChanged(event.modifierFlags)
            return true
        }
        if let shortcut = TimelineItemShortcut(event), handleItemShortcut(shortcut) { return true }
        guard event.modifierFlags.isDisjoint(with: [.command, .control, .option]) else { return false }
        return key(event.keyCode, shift: event.modifierFlags.contains(.shift), characters: event.charactersIgnoringModifiers)
    }
    /// The SwiftUI pane's F6 stop forwards here too, retaining the same range anchor.
    func key(_ code: UInt16, shift: Bool, characters: String? = nil) -> Bool {
        if code == 53 {
            if active || audioSelection != nil {
                if case .marquee(_, let original, _)? = drag { model.selectTimelineItems(original) }
                cancel(); canvas.renderContent(); return true
            }
            if !model.timelineItemSelection.isEmpty {
                model.selectTimelineItems([]); canvas.apply(); return true
            }
        }
        if code == 123 || code == 124 {
            if shift { model.selectTimelineItems([]) }
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
