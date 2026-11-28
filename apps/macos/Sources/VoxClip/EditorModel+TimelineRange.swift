import Foundation
import VoxClipCore

// Exact positions on the timeline (issue #41, step 1): the playhead steps by frame and by word
// boundary. Words stay the unit that cuts; these move only the playhead.
extension EditorModel {
    /// The take's frame rate: the grid the item nudge uses (TimelineEdits `.frames`), 30 when unknown.
    var timelineFrameRate: Double {
        let fps = project.media.source.video?.frameRate ?? 30
        return fps > 0 ? fps : 30
    }

    /// , / . with nothing selected: the playhead to the previous or next frame on the axis.
    func stepTimelineFrame(_ direction: Int) {
        let axis = timelineAxis, fps = timelineFrameRate
        let frame = timelineStepOrigin(on: axis) * fps
        let next = direction < 0 ? (frame - 1e-6).rounded(.up) - 1 : (frame + 1e-6).rounded(.down) + 1
        seekTimelineStep(next / fps, on: axis)
    }

    /// ⇧, / ⇧. with nothing selected: the playhead to the previous or next word start or end in
    /// the scope. Edited skips folded words, as ← and → do.
    func stepTimelineWordBoundary(_ direction: Int) {
        guard !words.isEmpty else { return }
        let axis = timelineAxis, current = timelineStepOrigin(on: axis)
        let words = words, cuts = cutWordIDs
        let scope = scopeBounds ?? 0...(words.count - 1)
        var best: Double?
        for index in scope where axis == .source || !cuts.contains(words[index].id) {
            for edge in [words[index].start, words[index].end] {
                let time = timelineTime(source: edge, on: axis)
                if direction > 0 ? time > current + 1e-6 && time < (best ?? .infinity) : time < current - 1e-6 && time > (best ?? -.infinity) {
                    best = time
                }
            }
        }
        if let best { seekTimelineStep(best, on: axis) }
    }

    private func timelineStepOrigin(on axis: TimelineAxis) -> Double {
        let playhead = timelinePlayhead(on: axis)
        if let step = timelineStep, step.axis == axis, step.from == playhead { return step.to }
        return playhead
    }

    private func seekTimelineStep(_ time: Double, on axis: TimelineAxis) {
        let target = time.clamped(to: timelineDisplayRange(on: axis))
        timelineStep = (axis, timelinePlayhead(on: axis), target)
        seekTimeline(target, on: axis)
    }
}
