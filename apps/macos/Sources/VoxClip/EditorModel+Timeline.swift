import Foundation
import VoxClipCore

// The editor's side of the v2 timeline (impl-plan V7a): which axis it shows, where the
// playhead is on it, and how a time on it maps back to the take.
extension EditorModel {
    /// Source while Show cuts is on, else Edited (notes.md §6).
    var timelineAxis: TimelineAxis { showsCuts ? .source : .edited }

    /// The playhead on `axis`: the scope's output time on Edited, take time on Source.
    func timelinePlayhead(on axis: TimelineAxis) -> Double { axis == .edited ? playhead : sourceTime }

    /// The scope's kept pieces, from the plan the preview and export use.
    var timelinePieces: TimelinePieces { renderTimeline.map(TimelinePieces.init) ?? TimelinePieces([]) }

    /// How long the axis runs: the scope's output on Edited, the take on Source.
    func timelineLength(on axis: TimelineAxis) -> Double { axis == .edited ? duration : sourceDuration }

    /// The playhead slider's spoken value (design §5.2), on the axis the timeline shows.
    var timelineAccessibilityValue: String {
        let edited = timelineAxis == .edited
        let cuts: Int = summary.cutWordCount + summary.cutPauseCount
        return timelineValueText(time: edited ? playhead : sourceTime, total: edited ? duration : sourceDuration, cuts: cuts, edited: edited)
    }

    /// The take time at `time` on `axis`. An Edited time maps through the scope's plan,
    /// right-continuously across a closed cut, and stays inside the open clip.
    func timelineSourceTime(_ time: Double, on axis: TimelineAxis) -> Double {
        guard axis == .edited else { return time.clamped(to: 0...max(0, sourceDuration)) }
        if time <= 0 { return scopeBounds.map { words[$0.lowerBound].start } ?? 0 }
        if time >= duration { return scopeBounds.map { words[$0.upperBound].end } ?? sourceDuration }
        let mapped: Double = renderTimeline?.sourceTime(time) ?? time
        guard let scope = scopeBounds else { return mapped }
        return mapped.clamped(to: words[scope.lowerBound].start...words[scope.upperBound].end)
    }

    /// The time on `axis` of the take time `source`: itself on Source, its place in the
    /// scope's output on Edited.
    func timelineTime(source: Double, on axis: TimelineAxis) -> Double {
        axis == .edited ? renderTimeline?.mapTime(source) ?? source : source
    }

    /// The open clip's take range (its words plus the planner's lead and tail), or nil on Full Take.
    var scopeSourceRange: ClosedRange<Double>? {
        guard let bounds = scopeBounds, let times = try? clipTimes(words, startIndex: bounds.lowerBound, endIndex: bounds.upperBound) else { return nil }
        return times.start...max(times.start, times.end)
    }

    /// The open clip's In and Out on `axis` (notes.md §6), or nil on Full Take. Edited runs
    /// from the scope's first output sample to its last.
    func timelineInOut(on axis: TimelineAxis) -> ClosedRange<Double>? {
        guard let source = scopeSourceRange else { return nil }
        return axis == .edited ? 0...max(0, duration) : source
    }

    /// The selection's take range: its words and pauses, or nil when nothing is selected.
    var selectionSourceRange: ClosedRange<Double>? {
        var lower = Double.infinity, upper = -Double.infinity
        for id in selectedWordIDs {
            guard let index = wordIndex[id] else { continue }
            lower = min(lower, words[index].start); upper = max(upper, words[index].end)
        }
        for id in selectedPauseIDs {
            guard let pause = pauseIndex[id] else { continue }
            lower = min(lower, pause.start); upper = max(upper, pause.end)
        }
        return lower <= upper ? lower...upper : nil
    }

    /// The selection on `axis`, or nil when nothing is selected.
    func timelineSelection(on axis: TimelineAxis) -> ClosedRange<Double>? {
        guard let source = selectionSourceRange else { return nil }
        let lower = timelineTime(source: source.lowerBound, on: axis), upper = timelineTime(source: source.upperBound, on: axis)
        return lower...max(lower, upper)
    }

    /// The scope's start and end as the timeline seeks to them (Home and End).
    func seekTimelineBoundary(end: Bool) {
        let source: Double
        if let bounds = scopeBounds { source = end ? words[bounds.upperBound].end : words[bounds.lowerBound].start }
        else { source = end ? sourceDuration : 0 }
        seek(source: source)
    }

    /// Seeks to `time` on `axis`; with `snap`, to the start of the word nearest it.
    func seekTimeline(_ time: Double, on axis: TimelineAxis, snap: Bool = false) {
        let source = timelineSourceTime(time, on: axis)
        if snap, let word = word(at: source, nearest: true) { seek(source: word.start) } else { seek(source: source) }
    }

    /// The word a drag of the open clip's In (`start`) or Out to `time` on `axis` lands on:
    /// the nearest word boundary to the take time there, kept on its side of the other edge.
    func timelineTrimIndex(_ clip: ClipRange, start: Bool, time: Double, on axis: TimelineAxis) -> Int? {
        let source = timelineSourceTime(time, on: axis)
        guard let candidate = trimIndex(start: start, source: source),
              let lower = index(clip.startWordId), let upper = index(clip.endWordId) else { return nil }
        return start ? candidate.clamped(to: 0...upper) : candidate.clamped(to: lower...(words.count - 1))
    }

    /// Restores the cut word or pause at `source`, as a double-click on a cut does.
    func restoreCut(at source: Double) {
        let wordIDs = word(at: source).map { cutWordIDs.contains($0.id) ? [$0.id] : [] } ?? []
        let pauseIDs = pause(at: source).map { cutPauseIDs.contains($0.id) ? [$0.id] : [] } ?? []
        guard !wordIDs.isEmpty || !pauseIDs.isEmpty else { return }
        apply(.restoreSelection(ids: wordIDs + pauseIDs), name: "Restore cut")
    }

    /// Every clip and suggestion in take time for the overview strip (notes.md §6), in
    /// Explorer order.
    var timelineOverviewClips: [TimelineOverviewClip] {
        let open = activeClip?.id
        return sortedClips.compactMap { clip in
            guard let lower = index(clip.startWordId), let upper = index(clip.endWordId), lower <= upper,
                  let number = clipNumber(clip.id) else { return nil }
            return TimelineOverviewClip(id: clip.id, source: words[lower].start...max(words[lower].start, words[upper].end), number: number,
                                        open: clip.id == open, proposal: isSuggestion(clip.id))
        }
    }
}

/// A clip or suggestion as the overview strip draws it.
struct TimelineOverviewClip: Equatable {
    let id: String
    let source: ClosedRange<Double>
    let number: Int
    /// The open tab's clip: drawn brighter.
    let open: Bool
    /// A suggestion not yet kept: drawn dashed.
    let proposal: Bool
}
