import AppKit
import VoxClipCore

enum TimelineItemShortcut: Equatable {
    case split, splitAll, duplicate, delete, snap, fit, start, end, select, next, previous
    case nudge(Int, word: Bool)
    case volume(Int), addKeyframe

    init?(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection([.shift, .command, .option, .control])
        switch (event.keyCode, flags) {
        case (11, []), (11, .command): self = .split
        case (11, [.command, .shift]): self = .splitAll
        case (2, .command): self = .duplicate
        case (51, []), (117, []): self = .delete
        case (45, []): self = .snap
        case (6, .shift): self = .fit
        case (33, .option): self = .start
        case (30, .option): self = .end
        case (36, []), (76, []): self = .select
        case (48, []): self = .next
        case (48, .shift): self = .previous
        case (43, []), (43, .shift): self = .nudge(-1, word: flags.contains(.shift))
        case (47, []), (47, .shift): self = .nudge(1, word: flags.contains(.shift))
        case (24, .control): self = .volume(1)
        case (27, .control): self = .volume(-1)
        case (40, .option): self = .addKeyframe
        default: return nil
        }
    }

    @MainActor static func focusedCanvas(_ responder: NSResponder?) -> TimelineCanvasView? {
        guard let canvas = responder as? TimelineCanvasView, canvas.model.correctionID == nil else { return nil }
        return canvas
    }

    init?(menuTag: Int) {
        switch menuTag {
        case 71: self = .split
        case 73: self = .splitAll
        case 74: self = .duplicate
        case 75: self = .snap
        case 76: self = .fit
        default: return nil
        }
    }
}

extension TimelineInteraction {
    @discardableResult
    func handleItemShortcut(_ shortcut: TimelineItemShortcut) -> Bool {
        let model = canvas.model
        guard model.correctionID == nil else { return false }
        let ids = canvas.selectedItemIDs
        let connected = canvas.content.items.filter { item in
            guard !item.item.hidden else { return false }
            if case .clip = item.item.id { return false }
            return true
        }.sorted { lhs, rhs in
            let left = lhs.ranges.first?.start ?? 0, right = rhs.ranges.first?.start ?? 0
            return left == right ? lhs.item.lane.index < rhs.item.lane.index : left < right
        }
        switch shortcut {
        case .snap: model.toggleTimelineSnapping()
        case .fit: canvas.fitClip()
        case .select:
            let playhead = model.timelinePlayhead(on: model.timelineAxis)
            guard let item = connected.filter({ $0.ranges.contains { $0.start <= playhead && playhead < $0.end } })
                .min(by: { $0.item.lane.index < $1.item.lane.index }) else { return false }
            canvas.selectAndRevealItem(item)
        case .next, .previous:
            guard let id = ids.first, let index = connected.firstIndex(where: { $0.item.id == id }), !connected.isEmpty else { return false }
            let target = (index + (shortcut == .next ? 1 : connected.count - 1)) % connected.count
            canvas.selectAndRevealItem(connected[target])
        case .split: model.splitTimelineItems(ids)
        case .splitAll: model.splitTimelineItems([], all: true)
        case .duplicate:
            guard !ids.isEmpty else { return false }
            model.commitTimelineItemEdit(.duplicate(items: ids, toAnchor: nil))
        case .delete:
            guard !ids.isEmpty else { return false }
            if model.commitTimelineItemEdit(.delete(items: ids)) { model.selectTimelineItems([]) }
        case .nudge(let step, let word):
            // With no item selected the playhead steps instead: a frame, or with ⇧ to a word boundary.
            if ids.isEmpty {
                if word { model.stepTimelineWordBoundary(step) } else { model.stepTimelineFrame(step) }
            } else {
                model.nudgeTimelineItems(ids, by: word ? .words(step) : .frames(step))
            }
        case .start, .end:
            guard ids.count == 1, let id = ids.first else { return false }
            model.trimTimelineItemToPlayhead(id, edge: shortcut == .start ? .start : .end)
        case .volume(let delta):
            guard ids.count == 1, let item = connected.first(where: { $0.item.id == ids.first }), let audio = item.audio else { return false }
            let db = (audio.gainDb + Double(delta)).clamped(to: audio.gainRange)
            model.commitTimelineItemEdit(audio.setGain(item.item.id, db: db), announcement: "Volume \(timelineItemDecibels(db)).")
        case .addKeyframe:
            guard ids.count == 1, let item = connected.first(where: { $0.item.id == ids.first }),
                  let command = model.timelineKeyframeAtPlayhead(item) else { return false }
            model.commitTimelineItemEdit(command)
        }
        canvas.renderContent(keepingZoom: true)
        return true
    }
}
