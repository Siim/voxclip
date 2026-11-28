import Foundation
import VoxClipCore

/// An exact stretch of the timeline (issue #41): what a drag with Snapping off (or ⌥) leaves,
/// or I and O set there. Frame-rounded, in the recording's own seconds, with the recording's
/// key when the project has several (#31). A selection, never part of the project.
struct TimelineRange: Equatable {
    var recording: String?
    var start: Double
    var end: Double
}

// Exact positions on the timeline (issue #41, step 1): the playhead steps by frame and by word
// boundary, and an exact range can be marked, played and used. Words stay the unit that cuts.
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

    // MARK: The exact range

    /// The exact range in take time (the project clock with several recordings), or nil.
    var timelineRangeSource: ClosedRange<Double>? {
        guard let range = timelineRange else { return nil }
        guard let key = range.recording else { return range.start...range.end }
        guard let clock = recordingClock, let region = clock.regions.first(where: { $0.key == key }) else { return nil }
        let offset = Double(region.offsetSamples) / Double(clock.sampleRate)
        return (offset + range.start)...(offset + range.end)
    }

    /// What the edit bar's range actions act on, in take time: the exact range, else the
    /// selected words and pauses.
    var timelineActionRange: ClosedRange<Double>? { timelineRangeSource ?? selectionSourceRange }

    /// The take a range around `anchor` may cover: its recording's span when there are several.
    private func timelineRangeBounds(anchor: Double) -> (key: String?, offset: Double, span: ClosedRange<Double>)? {
        guard hasSeveralRecordings, let clock = recordingClock else { return (nil, 0, 0...max(0, sourceDuration)) }
        guard let local = clock.localTime(anchor), let region = clock.regions.first(where: { $0.key == local.key }) else { return nil }
        let rate = Double(clock.sampleRate), offset = Double(region.offsetSamples) / rate
        return (region.key, offset, offset...(Double(region.endSample) / rate))
    }

    /// Marks `source` (take time) as the exact range, rounded to frames and kept inside the
    /// recording at `anchor`, at least one frame long, and selects the words wholly inside it.
    @discardableResult
    func setTimelineRange(source: ClosedRange<Double>, anchor: Double) -> Bool {
        guard source.lowerBound.isFinite, source.upperBound.isFinite, let bounds = timelineRangeBounds(anchor: anchor) else {
            clearTimelineRange(); return false
        }
        let fps = timelineFrameRate, length = bounds.span.upperBound - bounds.offset
        func frame(_ time: Double) -> Double { min(length, ((time.clamped(to: bounds.span) - bounds.offset) * fps).rounded() / fps) }
        var start = frame(source.lowerBound), end = frame(source.upperBound)
        if end <= start { if start + 1 / fps <= length { end = start + 1 / fps } else { start = max(0, end - 1 / fps) } }
        guard end > start else { clearTimelineRange(); return false }
        let range = TimelineRange(recording: bounds.key, start: start, end: end)
        if !timelineItemSelection.isEmpty { selectTimelineItems([]) }
        selectWords(inside: (bounds.offset + start)...(bounds.offset + end))
        timelineRange = range
        return true
    }

    /// A drag from `anchor` to `head` on `axis` as an exact range; returns it on `axis`. A
    /// story clip's range stays in the part the drag began in.
    @discardableResult
    func setTimelineRange(from anchor: Double, to head: Double, on axis: TimelineAxis) -> ClosedRange<Double>? {
        guard anchor.isFinite, head.isFinite, !words.isEmpty else { return nil }
        var limit = timelineDisplayRange(on: axis)
        if let story = storyTimeline {
            let spans = story.parts.compactMap { axis == .source ? $0.display : $0.edited }
            guard let span = spans.first(where: { $0.lowerBound <= anchor && anchor <= $0.upperBound }) else { return nil }
            limit = max(limit.lowerBound, span.lowerBound)...max(limit.lowerBound, min(limit.upperBound, span.upperBound))
        }
        let start = anchor.clamped(to: limit), end = head.clamped(to: limit)
        let lower = min(start, end), upper = max(start, end)
        let sourceLower = timelineSourceTime(lower, on: axis)
        // An Edited seam is right-continuous: a range ending at it ends before the closed cut.
        let sample = 1 / (renderTimeline?.sampleRate ?? 48_000)
        let sourceUpper = axis == .edited && upper > lower ? timelineSourceTime(max(lower, upper - sample), on: axis) + sample : timelineSourceTime(upper, on: axis)
        guard setTimelineRange(source: min(sourceLower, sourceUpper)...max(sourceLower, sourceUpper), anchor: timelineSourceTime(start, on: axis)) else { return nil }
        return timelineSelection(on: axis)
    }

    /// ⇧-click at `time` on `axis`: the range or word selection out to it. `exact` (Snapping
    /// off) keeps an exact range at frame grain; otherwise the selection becomes whole words.
    @discardableResult
    func extendTimelineSelection(to time: Double, on axis: TimelineAxis, exact: Bool) -> Bool {
        guard let base = timelineActionRange else { return false }
        let point = timelineSourceTime(time.clamped(to: timelineDisplayRange(on: axis)), on: axis)
        var lower = base.lowerBound, upper = base.upperBound
        if point < lower { lower = point }
        else if point > upper { upper = point }
        else if point - lower < upper - point { lower = point }
        else { upper = point }
        if exact { return setTimelineRange(source: lower...upper, anchor: (base.lowerBound + base.upperBound) / 2) }
        timelineRange = nil
        return selectTimeline(from: timelineTime(source: lower, on: axis), to: timelineTime(source: upper, on: axis), on: axis, snap: true) != nil
    }

    /// I or O with timeline focus: the range's In or Out at the playhead, on the frame grid.
    /// Without a range, or when the new edge passes the other one, the other edge is the
    /// scope's start or end (the playhead's story part in a story clip).
    func setTimelineRangeEdge(start: Bool) {
        guard !words.isEmpty else { return }
        let axis = timelineAxis
        var display = timelineDisplayRange(on: axis)
        let playhead = timelinePlayhead(on: axis).clamped(to: display)
        if let story = storyTimeline, let span = story.parts.compactMap({ axis == .source ? $0.display : $0.edited })
            .first(where: { $0.lowerBound <= playhead && playhead <= $0.upperBound }) {
            display = span.lowerBound...max(span.lowerBound, span.upperBound)
        }
        let source = timelineSourceTime(playhead, on: axis)
        let first = timelineSourceTime(display.lowerBound, on: axis), last = timelineSourceTime(display.upperBound, on: axis)
        let current = timelineRangeSource
        let lower = start ? source : current.map { $0.lowerBound < source ? $0.lowerBound : first } ?? first
        let upper = start ? current.map { $0.upperBound > source ? $0.upperBound : last } ?? last : source
        guard upper > lower else { return }
        setTimelineRange(source: lower...upper, anchor: start ? source : source - min(1e-3, (upper - lower) / 2))
    }

    /// Esc on the timeline: the range and the words under it go.
    func clearTimelineRange() {
        guard timelineRange != nil else { return }
        timelineRange = nil
        selectedWordIDs = []; selectedPauseIDs = []
    }

    /// The words wholly inside `source` in the scope, and the pauses between them, as a drag selects them.
    private func selectWords(inside source: ClosedRange<Double>) {
        let words = words, pauses = pauseByAfterIndex
        let scope = words.isEmpty ? nil : scopeBounds ?? 0...(words.count - 1)
        let inside = scope.map { $0.filter { words[$0].start >= source.lowerBound - 1e-6 && words[$0].end <= source.upperBound + 1e-6 } } ?? []
        settingTimelineRange = true
        defer { settingTimelineRange = false }
        selectedWordIDs = Set(inside.map { words[$0].id })
        selectedPauseIDs = inside.first.flatMap { first in inside.last.map { last in Set((first..<last).compactMap { pauses[$0]?.id }) } } ?? []
    }

    // MARK: Readout

    /// The toolbar's range readout, "0.43 s · 12:04.10–12:04.53": its length and its In and
    /// Out in the recording's own time.
    var timelineRangeReadout: String? { timelineRangeReadoutParts.map { "\($0.length) · \($0.span)" } }

    /// The readout's two halves: "0.43 s" and "12:04.10–12:04.53".
    var timelineRangeReadoutParts: (length: String, span: String)? {
        guard let range = timelineRange else { return nil }
        let length = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), range.end - range.start) + "\u{00A0}s"
        return (length, "\(Self.rangeTime(range.start))\u{2013}\(Self.rangeTime(range.end))")
    }

    /// "12:04.10", or "1:02:04.10" past an hour: minutes, seconds and hundredths.
    static func rangeTime(_ seconds: Double) -> String {
        let hundredths = Int((max(0, seconds) * 100).rounded())
        let whole = hundredths / 100, fraction = hundredths % 100
        let hours = whole / 3_600, minutes = whole / 60 % 60, rest = whole % 60
        return hours > 0 ? String(format: "%d:%02d:%02d.%02d", hours, minutes, rest, fraction) : String(format: "%d:%02d.%02d", minutes, rest, fraction)
    }

    // MARK: Range actions (the edit bar)

    static let timelineRangeHint = "Drag across the waveform to select words. Turn Snapping off for an exact range."
    static let timelineCutRangeReason = "Exact cuts are coming. Turn Snapping on to cut words."
    static let timelineMakeClipHelp = "Clip edges follow words"
    private static let notReady = "The timeline is not ready to edit."

    /// Why Play range can't run, or nil.
    var timelinePlayRangeReason: String? { timelineActionRange == nil ? Self.timelineRangeHint : nil }

    /// Play range: from In, stopping at Out (`previewStop`). The stop is set once the seek has
    /// landed, so a time from playback past Out can't end the range before it starts.
    func playTimelineRange() {
        guard let range = timelineActionRange, let renderTimeline else { return }
        if recordingAuditionTask != nil { stopRecordingAudition() }
        storyPartPlaybackEnd = nil
        endCorrection()
        let time = renderTimeline.mapTime(range.lowerBound)
        previewStop = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                try await preview.seek(to: time, exact: true); playhead = time; sourceTime = range.lowerBound
                previewStop = range.upperBound
                preview.play(); isPlaying = preview.isPlaying
            } catch { previewError = await app.safeError(error, context: .preview) }
        }
    }

    /// Why ✦ Ask Claude can't ask about the range or words, or nil.
    var timelineAskClaudeReason: String? {
        guard capabilities.edit else { return Self.notReady }
        guard canAskClaude else { return "Choose an AI connector in Settings \u{203A} AI." }
        if timelineRange != nil { return askClaude.timeRange == nil ? "Mark at least 0.1 s to ask Claude." : nil }
        return askClaudeWordSelection == nil ? Self.timelineRangeHint : nil
    }

    func askClaudeOnTimelineRange() {
        guard timelineAskClaudeReason == nil else { return }
        if timelineRange != nil { openAskClaudeOnTimeRange() } else { openAskClaudeOnSelection() }
    }

    /// Why Add title can't run over the range, or nil.
    var timelineAddTitleReason: String? {
        guard capabilities.edit else { return Self.notReady }
        return timelineActionRange == nil ? Self.timelineRangeHint : nil
    }

    /// Add title over the range: a title named "Title" from In to Out, with its editor open.
    func addTimelineTitleOverRange() {
        guard timelineAddTitleReason == nil else { return }
        do { try addTimelineTitle("Title") }
        catch {
            timelineItemRefusal = error.localizedDescription
            Task { await app.logFailure(error, context: .editing) }
        }
    }

    /// The item Trim item to range trims: of the visible titles, pictures, sounds and songs
    /// the range overlaps, the one it overlaps most (the upper lane on a tie). Its span is where
    /// it shows on the Source axis, so a song across a cut ends where it really ends.
    var timelineRangeTrimTarget: (id: TimelineItemID, kind: String, span: ClosedRange<Double>)? {
        guard let range = timelineActionRange, let plan = itemEditPlan else { return nil }
        let layout = TimelineItems.layout(project: project, plan: plan, scope: itemEditScope, axis: .source)
        var best: (id: TimelineItemID, kind: String, span: ClosedRange<Double>, overlap: Double)?
        for item in layout.items where !item.hidden && item.kind != "bleep" && item.kind != "mute" {
            switch item.id { case .clip, .part: continue; default: break }
            guard let lower = item.axisIntervals.map(\.start).min(), let upper = item.axisIntervals.map(\.end).max(), upper > lower else { continue }
            let span = lower...upper
            let overlap = min(span.upperBound, range.upperBound) - max(span.lowerBound, range.lowerBound)
            guard overlap > 0, overlap > (best?.overlap ?? 0) else { continue }
            best = (item.id, Self.itemKind(item.kind), span, overlap)
        }
        return best.map { ($0.id, $0.kind, $0.span) }
    }

    /// Why Trim item to range can't run, or nil.
    var timelineTrimToRangeReason: String? {
        guard capabilities.edit else { return Self.notReady }
        guard let range = timelineActionRange else { return Self.timelineRangeHint }
        guard let target = timelineRangeTrimTarget else { return "Put the range over a title, picture, sound or song to trim it." }
        if range.lowerBound <= target.span.lowerBound + 1e-6, range.upperBound >= target.span.upperBound - 1e-6 {
            return "The \(target.kind.lowercased()) already fits inside the range."
        }
        return nil
    }

    /// Trim item to range: the target's edges that lie outside the range move to In and Out,
    /// as ⌥[ and ⌥] move them to the playhead, in one "Trim to range" step.
    func trimTimelineItemToRange() {
        guard timelineTrimToRangeReason == nil, let range = timelineActionRange, let target = timelineRangeTrimTarget,
              var plan = itemEditPlan else { return }
        var commands: [TimelineEdit] = []
        if range.lowerBound > target.span.lowerBound + 1e-6 { commands.append(.trim(item: target.id, edge: .start, toSource: range.lowerBound)) }
        if range.upperBound < target.span.upperBound - 1e-6 { commands.append(.trim(item: target.id, edge: .end, toSource: range.upperBound)) }
        var next = project
        for command in commands {
            switch TimelineEdits.apply(command, project: next, plan: plan, scope: itemEditScope) {
            case .failure(let refusal):
                timelineItemRefusal = refusal.copy
                announce(refusal.copy)
                return
            case .success(let result):
                if result.project.edits.clips != next.edits.clips, let updated = try? RenderCallerInputs.editPlan(project: result.project, clipID: itemEditScope) { plan = updated }
                next = result.project
            }
        }
        timelineItemRefusal = nil
        guard next != project else { return }
        replace(next, name: "Trim to range")
        announce("Trimmed the \(target.kind.lowercased()) to the range.")
    }

    /// Why Make clip can't run, or nil.
    var timelineMakeClipReason: String? {
        guard capabilities.edit else { return Self.notReady }
        if timelineRange != nil { return timelineRangeClipWords == nil ? "There are no words in this range to make a clip from." : nil }
        return selectedIDs.isEmpty ? Self.timelineRangeHint : nil
    }

    /// The words a clip from the range runs between: each edge snaps to the nearest word start
    /// or end in the scope, as a drag with Snapping on does. Nil when no word reaches into the
    /// range (a pause or music only).
    var timelineRangeClipWords: (start: String, end: String)? {
        guard let range = timelineRangeSource, !words.isEmpty else { return nil }
        let words = words, scope = scopeBounds ?? 0...(words.count - 1)
        let region = hasSeveralRecordings ? recordingClock.flatMap { clock in clock.localTime((range.lowerBound + range.upperBound) / 2)?.key } : nil
        let candidates = scope.filter { region == nil || recordingClock?.region(of: words[$0].id)?.key == region }
        guard candidates.contains(where: { words[$0].start < range.upperBound && words[$0].end > range.lowerBound }) else { return nil }
        guard let first = candidates.min(by: { abs(words[$0].start - range.lowerBound) < abs(words[$1].start - range.lowerBound) }),
              let last = candidates.min(by: { abs(words[$0].end - range.upperBound) < abs(words[$1].end - range.upperBound) }) else { return nil }
        if first <= last { return (words[first].id, words[last].id) }
        let middle = (range.lowerBound + range.upperBound) / 2
        guard let nearest = candidates.min(by: { abs((words[$0].start + words[$0].end) / 2 - middle) < abs((words[$1].start + words[$1].end) / 2 - middle) }) else { return nil }
        return (words[nearest].id, words[nearest].id)
    }
}

extension EditorModel {
    /// A1's word ticks in `visible` on `axis` (issue #41): each word's start and end, the open
    /// clip's words only, and on Edited only the words that play.
    func timelineWordEdges(in visible: ClosedRange<Double>, on axis: TimelineAxis) -> (starts: [Double], ends: [Double]) {
        let words = words, cuts = cutWordIDs
        guard !words.isEmpty, visible.lowerBound.isFinite, visible.upperBound.isFinite else { return ([], []) }
        var indices = scopeBounds ?? 0...(words.count - 1)
        if storyTimeline == nil {
            let lower = timelineSourceTime(visible.lowerBound, on: axis), upper = timelineSourceTime(visible.upperBound, on: axis)
            var first = indices.lowerBound, end = indices.upperBound + 1
            while first < end { let middle = (first + end) / 2; if words[middle].end < lower { first = middle + 1 } else { end = middle } }
            var last = first
            while last <= indices.upperBound, words[last].start <= upper { last += 1 }
            guard first < last else { return ([], []) }
            indices = first...(last - 1)
        }
        var starts: [Double] = [], ends: [Double] = []
        for index in indices where axis == .source || !cuts.contains(words[index].id) {
            let start = timelineTime(source: words[index].start, on: axis), end = timelineTime(source: words[index].end, on: axis)
            if visible.contains(start) { starts.append(start) }
            if visible.contains(end) { ends.append(end) }
        }
        return (starts, ends)
    }
}
