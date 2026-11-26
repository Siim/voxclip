import Foundation
import VoxClipCore

extension EditorModel {
    var itemEditScope: String? { activeClip?.id }
    var timelineSnapHint: String { timelineSnapping ? "Snapping on (N)" : "Snapping off (N)" }
    func toggleTimelineSnapping() { timelineSnapping.toggle() }

    func restoreTimelineWords(_ item: TimelineItemDisplay) {
        guard capabilities.edit, item.hasHiddenWords, let span = timelineItemSpan(item.item.id) else { return }
        let ids = cutIDs(overlapping: span.lowerBound..<span.upperBound).filter { cutWordIDs.contains($0) }
        guard !ids.isEmpty else { return }
        apply(.restoreSelection(ids: ids), name: "Restore words")
    }

    var itemEditPlan: EditPlan? {
        try? RenderCallerInputs.editPlan(project: project, clipID: itemEditScope)
    }

    func timelineItemSpan(_ id: TimelineItemID) -> ClosedRange<Double>? {
        switch id {
        case .effect(let id):
            return project.clipEffects.first { $0.id == id }.map { $0.start...$0.end }
        case .footage(let id):
            return project.media.footage.first { $0.id == id }.map { $0.start...$0.end }
        case .motion(let id):
            return project.motionCues.first { $0.id == id }.map { $0.sourceStart...$0.sourceEnd }
        case .music(let id):
            guard let track = project.music.first(where: { $0.clipId == itemEditScope }) else { return nil }
            if let segment = track.segments?.first(where: { $0.id == id }) {
                return segment.anchorSeconds...(segment.anchorSeconds + segment.lengthSeconds)
            }
            guard id == track.id else { return nil }
            let start = scopeSourceRange?.lowerBound ?? 0
            return start...(start + (itemEditPlan?.duration ?? 0))
        case .part(let id):
            guard let position = activeClip?.parts?.firstIndex(where: { $0.id == id }),
                  let part = storyTimeline?.parts.first(where: { $0.position == position }) else { return nil }
            return part.take.lowerBound...part.take.upperBound
        case .clip: return scopeSourceRange
        default: return nil
        }
    }

    func splitTimelineItems(_ ids: [TimelineItemID], all: Bool = false) {
        let source = timelineSourceTime(timelinePlayhead(on: timelineAxis), on: timelineAxis)
        commitTimelineItemEdit(all ? .splitAll(atSource: source) : .split(items: ids, atSource: source))
    }

    func nudgeTimelineItems(_ ids: [TimelineItemID], by step: TimelineNudge) {
        commitTimelineItemEdit(.nudge(items: ids, by: step))
    }

    func trimTimelineItemToPlayhead(_ id: TimelineItemID, edge: TimelineEdge) {
        commitTimelineItemEdit(.trim(item: id, edge: edge, toSource: timelineSourceTime(timelinePlayhead(on: timelineAxis), on: timelineAxis)))
    }

    func timelineWordEdge(near time: Double, edge: TimelineEdge) -> Double? {
        words.lazy.map { edge == .start ? $0.start : $0.end }.min { abs($0 - time) < abs($1 - time) }
    }

    func selectTimelineItems(_ ids: Set<TimelineItemID>) {
        timelineItemRefusal = nil
        timelineItemSelection = ids
        guard !ids.isEmpty else { return }
        selectedWordIDs = []
        selectedPauseIDs = []
        askClaude.timeRange = nil
    }

    @discardableResult
    func commitTimelineItemEdit(_ command: TimelineEdit, announcement: String? = nil) -> Bool {
        guard capabilities.edit, let plan = itemEditPlan else {
            timelineItemRefusal = "The timeline is not ready to edit."
            return false
        }
        switch TimelineEdits.apply(command, project: project, plan: plan, scope: itemEditScope) {
        case .failure(let refusal):
            timelineItemRefusal = refusal.copy
            announce(refusal.copy)
            return false
        case .success(let result):
            timelineItemRefusal = nil
            if result.project != project {
                replace(result.project, name: result.undoName)
                announce(announcement ?? result.undoName)
            }
            return true
        }
    }

    func timelineItemDisplay(_ item: TimelineItem, axis: TimelineAxis, story: StoryTimelineLayout?, partRange: Range<Double>? = nil) -> TimelineItemDisplay {
        let kind: String
        let title: String?
        var pictureFades: TimelinePictureFades?
        var recordingStart: Double?
        switch item.id {
        case .effect(let id):
            let effect = project.clipEffects.first { $0.id == id }
            kind = Self.itemKind(item.kind)
            title = effect?.text ?? effect?.sound?.title
            if let effect, item.lane != .sounds, effect.kind != .speedForPart, effect.kind != .freeze {
                pictureFades = .init(fadeIn: effect.fadeInSeconds ?? 0, fadeOut: effect.fadeOutSeconds ?? 0, maximum: 5)
            }
        case .footage(let id):
            kind = Self.itemKind(item.kind); title = nil
            if let footage = project.media.footage.first(where: { $0.id == id }) {
                pictureFades = .init(fadeIn: footage.fadeInSeconds ?? 0, fadeOut: footage.fadeOutSeconds ?? 0, maximum: 2)
                if footage.kind != .screenshot { recordingStart = footage.footage.start }
            }
        case .motion:
            kind = "Zoom"; title = "Pan & Zoom"
        case .music:
            kind = "Music"; title = project.music.first { $0.clipId == itemEditScope }?.title
        case .part(let id):
            kind = "Part"
            title = activeClip?.parts?.firstIndex { $0.id == id }.map { "Part \($0 + 1)" }
        case .clip: kind = "Clip"; title = nil
        case .voice: kind = "AI voice"; title = nil
        case .contextDemo: kind = "Context demo"; title = nil
        }
        let ranges: [TimeRange]
        if let partRange {
            ranges = [.init(start: partRange.lowerBound, end: partRange.upperBound)]
        } else if axis == .source, let story {
            ranges = item.axisIntervals.flatMap { story.ranges(forSource: $0.start..<$0.end) }
                .sorted { $0.lowerBound < $1.lowerBound }.map { .init(start: $0.lowerBound, end: $0.upperBound) }
        } else {
            ranges = item.axisIntervals
        }
        let marker = item.marker.map { axis == .source ? story?.time(forSource: $0) ?? $0 : $0 }
        return .init(item: item, title: title ?? kind, kind: kind, ranges: ranges, marker: marker,
                     pictureFades: pictureFades, recordingStart: recordingStart)
    }

    private static func itemKind(_ kind: String) -> String {
        switch kind {
        case "lowerThird": "Lower third"
        case "sticker": "Emoji"
        case "motionTemplate": "Template"
        case "bRoll": "B-roll"
        case "videoStack": "Video stack"
        case "colourLook": "Look"
        case "speedForPart": "Speed change"
        default: kind.capitalized
        }
    }
}
