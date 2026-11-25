import Foundation
import VoxClipCore

struct TimelineAudioMeter: Sendable {
    static let rate = 48_000.0
    let ranges: [Range<Int>]
    private var sums: [Double]
    private var frames = 0
    private var cursor = 0

    init(_ ranges: [Range<Int>]) {
        self.ranges = ranges
        sums = Array(repeating: 0, count: ranges.count)
    }

    static func probes(for windows: [ExportCheckExpectation.AudioWindow]) -> [Range<Int>] {
        var deltas: [Int: Int] = [:]
        for window in windows {
            let start = Int((window.range.lowerBound * rate).rounded())
            let end = Int((window.range.upperBound * rate).rounded())
            deltas[start, default: 0] += 1
            deltas[end, default: 0] -= 1
        }
        let edges = deltas.keys.sorted()
        var active = 0
        let step = Int(rate * 0.1)
        let guardFrames = Int(rate * 0.025)
        var probes: [Range<Int>] = []
        for (start, end) in zip(edges, edges.dropFirst()) {
            active += deltas[start, default: 0]
            guard active > 0, end - start >= guardFrames else { continue }
            let margin = min(guardFrames, (end - start) / 4)
            let lower = start + margin, upper = end - margin
            for frame in stride(from: lower, to: upper, by: step) {
                probes.append(frame..<min(frame + step, upper))
            }
        }
        return probes
    }

    mutating func append(_ samples: UnsafeBufferPointer<Float>) {
        let end = frames + samples.count / 2
        while cursor < ranges.count, ranges[cursor].lowerBound < end {
            let range = ranges[cursor]
            let lower = 2 * (max(frames, range.lowerBound) - frames)
            let upper = 2 * (min(end, range.upperBound) - frames)
            if lower < upper {
                var sum = 0.0
                for index in lower..<upper {
                    let value = Double(samples[index])
                    sum += value * value
                }
                sums[cursor] += sum
            }
            if range.upperBound > end { break }
            cursor += 1
        }
        frames = end
    }

    var levels: [Double] {
        zip(ranges, sums).map { range, sum in
            10 * log10(max(1e-12, sum / Double(2 * range.count)))
        }
    }
}
