import Foundation
import VoxClipCore

struct StoryTimelineLayout: Equatable {
    struct Part: Equatable {
        let position: Int
        let take: Range<Double>
        let display: Range<Double>
        let edited: Range<Double>?
        let firstWordTime: Double
        var recording: ProjectClock.Region? = nil
        var localTime: Double? = nil
        var alternateRecordingShade = false
        var restartOut = false
        var offset: Double { take.lowerBound - display.lowerBound }
    }

    struct Marker: Equatable {
        let position: Int
        let range: Range<Double>
        let time: Double
        let jump: String?
        var recording: ProjectClock.Region? = nil
        var alternateRecordingShade = false
        var crossRecording = false
        var restartOut = false

        var label: String { "\(recording?.label ?? String(position + 1)) · \(storyTakeTime(time))" }
        var seamLabel: String? {
            guard let jump else { return nil }
            if crossRecording, let recording { return "→ \(recording.label) \(storyTakeTime(time))" }
            return "\(jump) \(storyTakeTime(time))" + (restartOut ? " · restart out" : "")
        }
        var gainLabel: String? {
            guard let gain = recording?.gainDb, gain != 0 else { return nil }
            return "\(gain < 0 ? "−" : "+")\(toFixed1(abs(gain))) dB"
        }
    }

    let parts: [Part]
    private let clockLength: Double?
    var usesRecordingClock: Bool { clockLength != nil }
    var length: Double { clockLength ?? parts.last?.display.upperBound ?? 0 }

    @MainActor init?(model: EditorModel) {
        guard let clip = model.activeClip, clip.parts != nil, let ranges = model.scopePartBounds else { return nil }
        let words = model.words, duration = model.recordingTimelineDuration
        let clock = model.hasSeveralRecordings ? model.recordingClock : nil
        let colored = model.storyRecordingRegions.count > 1
        let rate = Double(clock?.sampleRate ?? 48_000)
        clockLength = clock.map { Double($0.totalSamples) / Double($0.sampleRate) }
        let pieces = model.timelinePieces
        let restarts = model.recordingTakeMatches?.beats.flatMap(\.takes).compactMap { take -> ClosedRange<Int>? in
            guard take.flags.contains("restart") || take.flags.contains("falseStart"),
                  let first = model.index(take.startWordId), let last = model.index(take.endWordId) else { return nil }
            return first...last
        } ?? []
        var next = 0.0
        var previous: ProjectClock.Region?
        var alternate = false
        parts = ranges.enumerated().compactMap { position, bounds in
            let region = clock?.region(of: words[bounds.lowerBound].id)
            let offset = Double(region?.offsetSamples ?? 0) / rate
            guard let times = try? clipTimes(words, startIndex: bounds.lowerBound, endIndex: bounds.upperBound,
                                             leadIn: position == 0 ? clip.leadInSeconds : nil) else { return nil }
            let start = max(offset, times.start), end = min(region.map { Double($0.endSample) / rate } ?? duration, times.end)
            guard end > start else { return nil }
            let take = start..<end
            let display = clock == nil ? next..<(next + end - start) : take
            next = display.upperBound
            alternate = colored && region != nil && previous == region && !alternate
            previous = region
            let kept = pieces.pieces(on: .source)[pieces.indices(overlapping: take, on: .source)].filter { piece in
                let tolerance = 1 / (model.renderTimeline?.sampleRate ?? 48_000)
                return piece.source.upperBound - take.lowerBound > tolerance && take.upperBound - piece.source.lowerBound > tolerance
            }
            let edited = kept.first.flatMap { first in kept.last.map { first.edited.lowerBound..<$0.edited.upperBound } }
            let restartOut = position > 0 && region != nil && region == clock?.region(of: words[ranges[position - 1].upperBound].id)
                && restarts.contains { $0.lowerBound > ranges[position - 1].upperBound && $0.upperBound < bounds.lowerBound }
            return Part(position: position, take: take, display: display, edited: edited, firstWordTime: words[bounds.lowerBound].start,
                recording: colored ? region : nil, localTime: region.map { _ in words[bounds.lowerBound].start - offset },
                alternateRecordingShade: alternate, restartOut: restartOut)
        }
    }

    func markers(on axis: TimelineAxis, pieces: TimelinePieces) -> [Marker] {
        var previous: Part?
        return parts.compactMap { part in
            guard let range = axis == .source ? part.display : part.edited else { return nil }
            let jump: String?
            let cross = previous?.recording != nil && previous?.recording != part.recording
            if let previous {
                if axis == .edited, let index = pieces.pieces.firstIndex(where: { $0.edited.lowerBound == range.lowerBound }), pieces.isPartSeam(at: index) {
                    jump = pieces.isBackwardPartSeam(at: index) ? "↶" : "↷"
                } else { jump = part.take.lowerBound < previous.take.upperBound ? "↶" : "↷" }
            } else { jump = nil }
            previous = part
            return Marker(position: part.position, range: range, time: part.localTime ?? part.firstWordTime,
                jump: axis == .source && usesRecordingClock ? nil : jump, recording: part.recording,
                alternateRecordingShade: part.alternateRecordingShade, crossRecording: cross, restartOut: part.restartOut)
        }
    }

    func sourceTime(_ time: Double) -> Double {
        if usesRecordingClock { return time.clamped(to: 0...length) }
        guard let part = parts.first(where: { time < $0.display.upperBound }) ?? parts.last else { return time }
        return (time + part.offset).clamped(to: part.take.lowerBound...part.take.upperBound)
    }

    func time(forSource time: Double) -> Double {
        if usesRecordingClock { return time.clamped(to: 0...length) }
        let part = parts.first { $0.take.contains(time) } ?? parts.min { distance(time, $0.take) < distance(time, $1.take) }
        guard let part else { return time }
        return (time - part.offset).clamped(to: part.display.lowerBound...part.display.upperBound)
    }

    func offset(at time: Double) -> Double {
        if usesRecordingClock { return 0 }
        return (parts.first { $0.display.contains(time) } ?? parts.last)?.offset ?? 0
    }

    func ranges(forSource range: Range<Double>) -> [Range<Double>] {
        parts.compactMap { part in
            let lower = max(range.lowerBound, part.take.lowerBound), upper = min(range.upperBound, part.take.upperBound)
            return lower < upper ? (lower - part.offset)..<(upper - part.offset) : nil
        }
    }

    func sourcePieces(_ pieces: TimelinePieces) -> TimelinePieces {
        TimelinePieces(pieces.pieces.flatMap { piece in
            ranges(forSource: piece.source).map { TimelinePiece(source: $0, edited: piece.edited, kind: piece.kind) }
        })
    }

    private func distance(_ time: Double, _ range: Range<Double>) -> Double {
        max(range.lowerBound - time, time - range.upperBound, 0)
    }
}
