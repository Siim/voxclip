import Foundation
import VoxClipCore

struct StoryTimelineLayout: Equatable {
    struct Part: Equatable {
        let position: Int
        let take: Range<Double>
        let display: Range<Double>
        let edited: Range<Double>?
        let firstWordTime: Double
        var offset: Double { take.lowerBound - display.lowerBound }
    }

    struct Marker: Equatable {
        let position: Int
        let range: Range<Double>
        let time: Double
        let jump: String?

        var label: String { "\(position + 1) · \(storyTakeTime(time))" }
        var seamLabel: String? { jump.map { "\($0) \(storyTakeTime(time))" } }
    }

    let parts: [Part]
    var length: Double { parts.last?.display.upperBound ?? 0 }

    @MainActor init?(model: EditorModel) {
        guard let clip = model.activeClip, clip.parts != nil, let ranges = model.scopePartBounds else { return nil }
        let words = model.words, duration = model.sourceDuration
        let pieces = model.timelinePieces
        var next = 0.0
        parts = ranges.enumerated().compactMap { position, bounds in
            guard let times = try? clipTimes(words, startIndex: bounds.lowerBound, endIndex: bounds.upperBound,
                                             leadIn: position == 0 ? clip.leadInSeconds : nil) else { return nil }
            let end = min(duration, times.end)
            guard end > times.start else { return nil }
            let take = times.start..<end
            let display = next..<(next + end - times.start)
            next = display.upperBound
            let kept = pieces.pieces(on: .source)[pieces.indices(overlapping: take, on: .source)].filter { piece in
                let tolerance = 1 / (model.renderTimeline?.sampleRate ?? 48_000)
                return piece.source.upperBound - take.lowerBound > tolerance && take.upperBound - piece.source.lowerBound > tolerance
            }
            let edited = kept.first.flatMap { first in kept.last.map { first.edited.lowerBound..<$0.edited.upperBound } }
            return Part(position: position, take: take, display: display, edited: edited, firstWordTime: words[bounds.lowerBound].start)
        }
    }

    func markers(on axis: TimelineAxis, pieces: TimelinePieces) -> [Marker] {
        var previous: Part?
        return parts.compactMap { part in
            guard let range = axis == .source ? part.display : part.edited else { return nil }
            let jump: String?
            if let previous {
                if axis == .edited, let index = pieces.pieces.firstIndex(where: { $0.edited.lowerBound == range.lowerBound }), pieces.isPartSeam(at: index) {
                    jump = pieces.isBackwardPartSeam(at: index) ? "↶" : "↷"
                } else { jump = part.take.lowerBound < previous.take.upperBound ? "↶" : "↷" }
            } else { jump = nil }
            previous = part
            return Marker(position: part.position, range: range, time: part.firstWordTime, jump: jump)
        }
    }

    func sourceTime(_ time: Double) -> Double {
        guard let part = parts.first(where: { time < $0.display.upperBound }) ?? parts.last else { return time }
        return (time + part.offset).clamped(to: part.take.lowerBound...part.take.upperBound)
    }

    func time(forSource time: Double) -> Double {
        let part = parts.first { $0.take.contains(time) } ?? parts.min { distance(time, $0.take) < distance(time, $1.take) }
        guard let part else { return time }
        return (time - part.offset).clamped(to: part.display.lowerBound...part.display.upperBound)
    }

    func offset(at time: Double) -> Double {
        (parts.first { $0.display.contains(time) } ?? parts.last)?.offset ?? 0
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
