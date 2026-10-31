import Foundation

// The v2 timeline's media-free math (ux/v2 notes.md §6, impl-plan V7a): the pieces a scope
// plays, the ruler's ticks and labels, Resolve-style timecode and the overview's rows. The
// app draws them; WC1 gives Windows the same rules with shared fixtures.

/// The timeline's time axis. Edited is the scope's output time, 0 at its first kept sample,
/// with every cut closed (a ripple). Source is take time. Show cuts selects Source.
public enum TimelineAxis: String, Sendable, CaseIterable {
    case edited, source
}

/// One kept interval of a scope's output: where it comes from in the take and where it plays
/// in the scope. An `.ai` piece is spoken by your AI voice (a Voice Lab synth piece): its
/// source is the take range it replaces, and its edited length is the new audio's.
public struct TimelinePiece: Sendable, Equatable {
    public enum Kind: String, Sendable { case kept, ai }
    /// Seconds in the take.
    public let source: Range<Double>
    /// Seconds in the scope's output.
    public let edited: Range<Double>
    public let kind: Kind
    public init(source: Range<Double>, edited: Range<Double>, kind: Kind = .kept) {
        self.source = source
        self.edited = edited
        self.kind = kind
    }
    public func range(on axis: TimelineAxis) -> Range<Double> { axis == .edited ? edited : source }
}

/// The pieces of one render timeline, in play order. Both their source and their edited
/// ranges ascend, so a lane finds the visible ones by binary search: O(log n) plus what shows.
public struct TimelinePieces: Sendable, Equatable {
    public let pieces: [TimelinePiece]
    public init(_ pieces: [TimelinePiece]) { self.pieces = pieces }

    /// The kept intervals of a legacy plan, butted in output order, or a Voice Lab plan's pieces.
    public init(_ timeline: RenderTimeline) {
        switch timeline {
        case .legacy(let plan):
            let rate = plan.sampleRate
            var output: Int64 = 0
            var pieces: [TimelinePiece] = []
            pieces.reserveCapacity(plan.kept.count)
            for interval in plan.kept where interval.endSample > interval.startSample {
                let length = interval.endSample - interval.startSample
                pieces.append(TimelinePiece(source: Double(interval.startSample) / rate..<Double(interval.endSample) / rate,
                                            edited: Double(output) / rate..<Double(output + length) / rate))
                output += length
            }
            self.pieces = pieces
        case .voiceLab(let plan):
            let rate = plan.sampleRate
            pieces = plan.pieces.filter { $0.outputEndSample > $0.outputStartSample }.map { piece in
                TimelinePiece(source: Double(piece.sourceStartSample) / rate..<Double(max(piece.sourceStartSample, piece.sourceEndSample)) / rate,
                              edited: Double(piece.outputStartSample) / rate..<Double(piece.outputEndSample) / rate,
                              kind: piece.kind == .synth ? .ai : .kept)
            }
        }
    }

    /// The scope's output length: where the last piece ends.
    public var editedDuration: Double { pieces.last?.edited.upperBound ?? 0 }

    /// The take range the pieces span, or nil when nothing plays.
    public var sourceSpan: Range<Double>? {
        guard let first = pieces.first, let last = pieces.last else { return nil }
        return first.source.lowerBound..<max(first.source.lowerBound, last.source.upperBound)
    }

    /// The pieces that overlap `range` on `axis`.
    public func indices(overlapping range: Range<Double>, on axis: TimelineAxis) -> Range<Int> {
        var lower = 0, upper = pieces.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if pieces[middle].range(on: axis).upperBound <= range.lowerBound { lower = middle + 1 } else { upper = middle }
        }
        let first = lower
        upper = pieces.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if pieces[middle].range(on: axis).lowerBound < range.upperBound { lower = middle + 1 } else { upper = middle }
        }
        return first..<max(first, lower)
    }
}

/// A ruler tick: `major` ticks run the ruler's full height and carry a label.
public struct TimelineTick: Sendable, Equatable {
    public let time: Double
    public let major: Bool
    public init(time: Double, major: Bool) {
        self.time = time
        self.major = major
    }
}

/// The ruler's ticks (notes.md §6): labels every 5 s, every 10 s when 5 s labels would be
/// closer than 90 pt, and coarser steps on the same rule for long scopes; 1 s minor ticks,
/// or the finest coarser step that keeps minor ticks `minorSpacing` apart.
public enum TimelineRuler {
    /// Labelled ticks are at least this far apart, in points.
    public static let labelSpacing = 90.0
    /// Minor ticks are at least this far apart, in points.
    public static let minorSpacing = 6.0
    public static let majorSteps: [Int] = [5, 10, 30, 60, 120, 300, 600, 1_800, 3_600]
    public static let minorSteps: [Int] = [1, 5, 10, 30, 60, 300, 600, 1_800]

    /// Seconds between labels at `ptPerSecond`.
    public static func majorStep(ptPerSecond: Double) -> Int {
        guard ptPerSecond.isFinite, ptPerSecond > 0 else { return majorSteps.last! }
        return majorSteps.first { Double($0) * ptPerSecond >= labelSpacing } ?? majorSteps.last!
    }

    /// Seconds between minor ticks: a divisor of the major step, never the step itself.
    public static func minorStep(ptPerSecond: Double) -> Int {
        let major = majorStep(ptPerSecond: ptPerSecond)
        guard ptPerSecond.isFinite, ptPerSecond > 0 else { return major }
        return minorSteps.first { $0 < major && major % $0 == 0 && Double($0) * ptPerSecond >= minorSpacing } ?? major
    }

    /// Every tick in `visible`, in order. Times are whole seconds, so they never drift.
    public static func ticks(visible: ClosedRange<Double>, ptPerSecond: Double) -> [TimelineTick] {
        guard visible.lowerBound.isFinite, visible.upperBound.isFinite, ptPerSecond.isFinite, ptPerSecond > 0 else { return [] }
        let major = majorStep(ptPerSecond: ptPerSecond), minor = minorStep(ptPerSecond: ptPerSecond)
        let first = Int64((visible.lowerBound / Double(minor)).rounded(.up))
        let last = Int64((visible.upperBound / Double(minor)).rounded(.down))
        guard first <= last, last - first < 100_000 else { return [] }
        return (first...last).map { index in
            let seconds = index * Int64(minor)
            return TimelineTick(time: Double(seconds), major: seconds % Int64(major) == 0)
        }
    }

    /// Where a label starts for the major tick at `tickX`, or nil where it must not draw
    /// (notes.md §6): 4 pt after the tick, 9 pt when an In bracket stands on it (to clear the
    /// bracket's foot); never across a bracket and never past `laneEnd` + 6.
    public static func labelX(tickX: Double, width: Double, brackets: [Double], inBracket: Double?, laneEnd: Double) -> Double? {
        let start = tickX + (inBracket.map { abs($0 - tickX) < 2 } == true ? 9 : 4)
        let end = start + width
        guard end <= laneEnd + 6 else { return nil }
        guard !brackets.contains(where: { start - 3 <= $0 && $0 <= end + 2 }) else { return nil }
        return start
    }
}

/// Resolve's HH:MM:SS:FF (notes.md §2) for the timeline readout and the ruler.
public enum SMPTETimecode {
    /// The frame `seconds` falls in (frame k spans k/fps up to (k + 1)/fps), tolerant of the
    /// binary error in times like 443/30.
    public static func frame(seconds: Double, fps: Int = 30) -> Int64 {
        guard seconds.isFinite, seconds > 0, fps > 0 else { return 0 }
        let frames = (seconds * Double(fps) + 1e-6).rounded(.down)
        return frames >= Double(Int64.max / 2) ? Int64.max / 2 : Int64(frames)
    }

    /// The timecode split for display: `dimPrefix` holds the leading zero groups (a zero hour,
    /// and a zero minute after it), drawn dimmed; `value` is the rest. Hours grow past 99.
    public static func format(seconds: Double, fps: Int = 30) -> (dimPrefix: String, value: String) {
        let rate = Int64(max(1, fps))
        let total = frame(seconds: seconds, fps: fps)
        let frames = total % rate, wholeSeconds = total / rate
        let hours = wholeSeconds / 3_600, minutes = wholeSeconds / 60 % 60, secondsPart = wholeSeconds % 60
        func two(_ value: Int64) -> String { value < 10 ? "0\(value)" : String(value) }
        if hours > 0 { return ("", "\(two(hours)):\(two(minutes)):\(two(secondsPart)):\(two(frames))") }
        if minutes > 0 { return ("00:", "\(two(minutes)):\(two(secondsPart)):\(two(frames))") }
        return ("00:00:", "\(two(secondsPart)):\(two(frames))")
    }

    /// The whole timecode, as VoiceOver and the clipboard see it.
    public static func string(seconds: Double, fps: Int = 30) -> String {
        let parts = format(seconds: seconds, fps: fps)
        return parts.dimPrefix + parts.value
    }
}

/// The overview strip's rows (notes.md §6): each clip range takes the first row where it
/// overlaps nothing already placed, so overlapping clips and proposals stack. Ranges that only
/// touch do not overlap.
public enum TimelineOverview {
    public static func rows(for ranges: [ClosedRange<Double>]) -> [Int] {
        var placed: [(range: ClosedRange<Double>, row: Int)] = []
        var rows: [Int] = []
        rows.reserveCapacity(ranges.count)
        for range in ranges {
            var row = 0
            while placed.contains(where: { $0.row == row && range.lowerBound < $0.range.upperBound && $0.range.lowerBound < range.upperBound }) { row += 1 }
            placed.append((range, row))
            rows.append(row)
        }
        return rows
    }
}
