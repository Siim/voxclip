import Foundation
import VoxClipCore

// The editor's side of the v2 timeline (impl-plan V7a, V7b): which axis it shows, where the
// playhead is on it, and how a time on it maps back to the take.
extension EditorModel {
    /// Source while Show cuts is on, else Edited (notes.md §6).
    var timelineAxis: TimelineAxis { showsCuts ? .source : .edited }

    /// The playhead on `axis`: the scope's output time on Edited, take time on Source.
    func timelinePlayhead(on axis: TimelineAxis) -> Double { axis == .edited ? playhead : sourceTime }

    /// The scope's pieces, from the plan the preview and export use.
    var timelinePieces: TimelinePieces { renderTimeline.map(TimelinePieces.init) ?? TimelinePieces([]) }

    /// True while the playhead plays a Voice Lab patch, whose audio is your AI voice rather
    /// than the take: the toolbar's src TC reads "src AI voice" (notes.md §6).
    var playheadInAIVoice: Bool {
        guard let plan = voiceLabPlan else { return false }
        let sample = playhead * plan.sampleRate
        var lower = 0, upper = plan.pieces.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if Double(plan.pieces[middle].outputEndSample) <= sample { lower = middle + 1 } else { upper = middle }
        }
        guard plan.pieces.indices.contains(lower) else { return false }
        let piece = plan.pieces[lower]
        return piece.kind == .synth && Double(piece.outputStartSample) <= sample
    }

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

    /// Source view's removed ranges in the scope (notes.md §6): take time between In and Out,
    /// or in the whole take on Full Take, that no piece plays: cut words, and the cut part of
    /// a cut pause (the planner keeps a little of it, so one can end just inside Out).
    func timelineRemovedRanges(_ pieces: TimelinePieces) -> [Range<Double>] {
        pieces.gaps(within: scopeSourceRange.map { $0.lowerBound..<$0.upperBound } ?? 0..<max(0, sourceDuration))
    }

    /// The scope's kept words in take time, in order: A1's stand-in when there is no
    /// waveform (design §5.4.10).
    var timelineKeptWords: [Range<Double>] {
        let indices = scopeBounds ?? 0...max(0, words.count - 1)
        guard !words.isEmpty else { return [] }
        return words[indices].filter { !cutWordIDs.contains($0.id) && $0.end > $0.start }.map { $0.start..<$0.end }
    }

    /// The selection's take range: its words and pauses, or nil when nothing is selected.
    var selectionSourceRange: ClosedRange<Double>? {
        // Read observable collections once per selection frame, rather than once per ID.
        let words = words, wordIndex = wordIndex, pauseIndex = pauseIndex
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

    /// Seeks to `time` on the displayed axis.
    func seekTimeline(_ time: Double, on axis: TimelineAxis) {
        seek(source: timelineSourceTime(time, on: axis))
    }

    /// Shared word selection with the transcript. Edited endpoints map through the render
    /// plan; words and cut pauses between them remain selected across folded cuts. Only
    /// original transcript IDs enter this set (proposal/inserted display runs never do).
    @discardableResult
    func selectTimeline(from anchor: Double, to head: Double, on axis: TimelineAxis, snap: Bool) -> ClosedRange<Double>? {
        guard anchor.isFinite, head.isFinite, !words.isEmpty else { return nil }
        let limit = max(0, timelineLength(on: axis))
        let lower = min(anchor, head).clamped(to: 0...limit)
        let upper = max(anchor, head).clamped(to: 0...limit)
        let sourceLower = timelineSourceTime(lower, on: axis)
        // An Edited seam is right-continuous for seeking. A selection ending at it owns
        // the word on the left, not the first word after the closed cut.
        let lastSample = axis == .edited && upper > lower ? max(lower, upper - 1 / (renderTimeline?.sampleRate ?? 48_000)) : upper
        let sourceUpper = timelineSourceTime(lastSample, on: axis)
        let first: Int?, last: Int?
        if snap {
            first = timelineSelectionBoundary(source: sourceLower, start: true, on: axis)
            last = timelineSelectionBoundary(source: sourceUpper, start: false, on: axis)
        } else {
            first = words.firstIndex { $0.end > sourceLower }
            last = words.lastIndex { $0.start < sourceUpper }
        }
        guard let first, let last else {
            selectedWordIDs = []; selectedPauseIDs = []
            return nil
        }
        let span: ClosedRange<Int>
        if first <= last { span = first...last }
        else if let word = word(at: (sourceLower + sourceUpper) / 2, nearest: true), let index = index(word.id) { span = index...index }
        else { return nil }
        let words = words, pauses = pauseByAfterIndex, cutPauses = cutPauseIDs
        selectedWordIDs = Set(words[span].map(\.id))
        selectedPauseIDs = Set(span.dropLast().compactMap { pauses[$0]?.id }.filter(cutPauses.contains))
        return snap ? timelineSelection(on: axis) : lower...upper
    }

    private func timelineSelectionBoundary(source: Double, start: Bool, on axis: TimelineAxis) -> Int? {
        // Snapshot once: per-word Observation reads dominate an hour-long drag otherwise.
        let words = words, cuts = cutWordIDs
        let scope = axis == .edited ? scopeBounds ?? 0...(words.count - 1) : 0...(words.count - 1)
        var best: Int?, distance = Double.infinity
        for index in scope where axis == .source || !cuts.contains(words[index].id) {
            let candidate = abs((start ? words[index].start : words[index].end) - source)
            if best == nil || candidate < distance { best = index; distance = candidate }
        }
        return best
    }

    /// Timeline navigation is confined to the active tab's scope. Edited skips folded
    /// words when moving the caret; an extended range still owns their original IDs.
    func stepTimeline(_ direction: Int, sentence: Bool, anchor: String? = nil, head: String? = nil) -> String? {
        guard !words.isEmpty else { return nil }
        let scope = scopeBounds ?? 0...(words.count - 1)
        let visible = scope.filter { timelineAxis == .source || !cutWordIDs.contains(words[$0].id) }
        guard !visible.isEmpty else { return nil }
        let selected = selectedIDs
        let current = head.flatMap(index) ?? (direction < 0 ? selected.first.flatMap(index) : selected.last.flatMap(index))
            ?? word(at: sourceTime, nearest: true).flatMap { index($0.id) } ?? scope.lowerBound
        var position = current
        repeat {
            let candidates = direction < 0 ? visible.last(where: { $0 < position }) : visible.first(where: { $0 > position })
            guard let next = candidates else { break }
            position = next
            if !sentence || (direction < 0 ? position == scope.lowerBound || TranscriptParagraphs.endsSentence(words[position - 1].text) : TranscriptParagraphs.endsSentence(words[position].text)) { break }
        } while true
        position = position.clamped(to: scope)
        if let anchor, let anchorIndex = index(anchor) {
            let start = anchorIndex.clamped(to: scope)
            let span = min(start, position)...max(start, position)
            selectedWordIDs = Set(words[span].map(\.id))
            selectedPauseIDs = Set(span.dropLast().compactMap { pauseByAfterIndex[$0]?.id }.filter(cutPauseIDs.contains))
            if !isPlaying { seek(source: words[position].start) }
        } else { select(words[position].id) }
        return words[position].id
    }

    /// The word a drag of the open clip's In (`start`) or Out to `time` on `axis` lands on:
    /// the nearest word boundary to the take time there, kept on its side of the other edge.
    func timelineTrimIndex(_ clip: ClipRange, start: Bool, time: Double, on axis: TimelineAxis, snap: Bool = true) -> Int? {
        let source = timelineSourceTime(time, on: axis)
        let target = snap ? trimIndex(start: start, source: source) : (word(at: source) ?? word(at: source, nearest: true)).flatMap { index($0.id) }
        guard let candidate = target,
              let lower = index(clip.startWordId), let upper = index(clip.endWordId) else { return nil }
        return start ? candidate.clamped(to: 0...upper) : candidate.clamped(to: lower...(words.count - 1))
    }

    /// Restores the cut at `time` on `axis`, as a double-click on a cut does, in one "Restore
    /// cut" step. On Source it is the cut word or pause there. On Edited a cut is closed to a
    /// seam, so it is everything cut at the seam nearest `time`, within `tolerance` seconds.
    func restoreCut(at time: Double, on axis: TimelineAxis, tolerance: Double) {
        var ids: [String] = []
        if axis == .source {
            if let word = word(at: time), cutWordIDs.contains(word.id) { ids.append(word.id) }
            if let pause = pause(at: time), cutPauseIDs.contains(pause.id) { ids.append(pause.id) }
        } else if let gap = timelineSeamGap(near: time, within: tolerance) {
            ids = cutIDs(overlapping: gap)
        }
        guard !ids.isEmpty else { return }
        apply(.restoreSelection(ids: ids), name: "Restore cut")
    }

    /// The take time a closed cut leaves out on Edited, between the pieces either side of
    /// the seam nearest `time` within `tolerance` seconds, or nil when no seam is that near.
    func timelineSeamGap(near time: Double, within tolerance: Double) -> Range<Double>? {
        guard tolerance > 0 else { return nil }
        let pieces = timelinePieces
        var nearest: (distance: Double, gap: Range<Double>)?
        // Pieces butt on Edited, so both pieces of a seam in reach overlap the reach.
        for index in pieces.indices(overlapping: (time - tolerance)..<(time + tolerance), on: .edited).dropFirst() {
            let before = pieces.pieces[index - 1], after = pieces.pieces[index]
            let distance = abs(after.edited.lowerBound - time)
            guard distance <= tolerance, pieces.isSeam(at: index),
                  nearest.map({ distance < $0.distance }) ?? true else { continue }
            nearest = (distance, before.source.upperBound..<after.source.lowerBound)
        }
        return nearest?.gap
    }

    /// The cut words and pauses that overlap `range` in take time, in take order.
    func cutIDs(overlapping range: Range<Double>) -> [String] {
        func first<T>(_ items: [T], end: (T) -> Double) -> Int {
            var lower = 0, upper = items.count
            while lower < upper { let middle = (lower + upper) / 2; if end(items[middle]) <= range.lowerBound { lower = middle + 1 } else { upper = middle } }
            return lower
        }
        let words = words
        var ids: [String] = []
        for word in words[first(words, end: \.end)...] {
            guard word.start < range.upperBound else { break }
            if cutWordIDs.contains(word.id) { ids.append(word.id) }
        }
        for pause in pauses[first(pauses, end: \.end)...] {
            guard pause.start < range.upperBound else { break }
            if cutPauseIDs.contains(pause.id) { ids.append(pause.id) }
        }
        return ids
    }

    /// The CC lane's cues on `axis` (notes.md §6, impl-plan V9) from the preview's caption
    /// pages, with `removed` (Source's cut ranges) inside them. A page's words map through the
    /// scope's current plan by their ids, so a cut shows before the preview has
    /// laid the captions out again; a page of AI-voice words keeps the layout's own times.
    /// Pages outside the open clip (a layout from before a tab switch) are left out.
    func timelineCaptionCues(on axis: TimelineAxis, removed: [Range<Double>] = []) -> [TimelineCue] {
        guard project.captions.styleId != "off" else { return [] }
        let scope = scopeSourceRange
        var pages: [TimelineCaptions.Page] = []
        pages.reserveCapacity(captionPages.count)
        for page in captionPages {
            let visibleWords = page.words.filter { word in
                guard let index = wordIndex[word.id] else { return true }
                if cutWordIDs.contains(word.id) { return false }
                guard let scope else { return true }
                return words[index].end > scope.lowerBound && words[index].start < scope.upperBound
            }
            guard let first = visibleWords.first, let last = visibleWords.last else { continue }
            let text = visibleWords.map(\.text).joined(separator: " ")
            if let lower = wordIndex[first.id], let upper = wordIndex[last.id] {
                let start = words[lower].start, end = max(start, words[upper].end)
                if let scope, end <= scope.lowerBound || start >= scope.upperBound { continue }
                let editedStart = timelineTime(source: start, on: .edited), editedEnd = timelineTime(source: end, on: .edited)
                pages.append(.init(edited: editedStart..<max(editedStart, editedEnd), source: start..<end, text: text))
            } else {
                let start = timelineSourceTime(page.start, on: .edited), end = timelineSourceTime(max(page.start, page.end), on: .edited)
                pages.append(.init(edited: page.start..<max(page.start, page.end), source: start..<max(start, end), text: text))
            }
        }
        return TimelineCaptions.cues(pages, on: axis, removed: removed)
    }

    /// Where V1's filmstrip reads its frames (impl-plan V9), or nil when it has none: a demo,
    /// media that is missing or unreadable, or a take without video.
    var timelineFilmstripSource: FilmstripSource? {
        guard !document.demo, mediaResolved, !mediaUnreadable, project.media.source.video != nil else { return nil }
        return FilmstripSource(url: sourceURL, contentKey: project.media.source.contentKey, cache: app.locations.cache)
    }

    /// V1's name strip (notes.md §6): the end of the take's file name, as "…0075_D".
    var timelineMediaName: String {
        let stem = (URL(fileURLWithPath: project.media.source.absolutePath).lastPathComponent as NSString).deletingPathExtension
        return stem.count > 7 ? "\u{2026}" + String(stem.suffix(6)) : stem
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
