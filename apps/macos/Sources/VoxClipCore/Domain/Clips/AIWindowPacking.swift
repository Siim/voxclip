import Foundation

struct AIWindowRange: Sendable {
    let range: Range<Int>
    let estimatedCost: Int
}

enum AIWindowPacking {
    static func pack(lines: [TranscriptLine], budget: Int, maxWords: Int, overlap: Double, tokenPolicy: AITokenPolicy = AITokenPolicy()) throws -> [AIWindowRange] {
        guard budget >= 600 else { throw LLMError.contextTooLong }
        var result: [AIWindowRange] = []
        var first = 0
        while first < lines.count {
            var last = first
            var cost = 0
            var count = 0
            while last < lines.count {
                let line = lines[last]
                let lineCost = tokenPolicy.estimate(line.text + "\n") + (line.pauseAfter.map { tokenPolicy.estimate($0 + "\n") } ?? 0)
                let lineCount = line.lastPos - line.firstPos + 1
                if last > first && (cost + lineCost > budget || count + lineCount > maxWords) { break }
                cost += lineCost
                count += lineCount
                last += 1
            }
            result.append(AIWindowRange(range: first..<last, estimatedCost: cost))
            if last == lines.count { break }
            if overlap <= 0 { first = last; continue }
            let threshold = lines[last - 1].end - overlap
            first = (first + 1..<last).first { lines[$0].start >= threshold } ?? last
        }
        return result
    }

    static func longestTimeLines(_ lines: [TranscriptLine]) -> [TranscriptLine] {
        guard let start = lines.max(by: { AIText.formatTime($0.start).utf8.count < AIText.formatTime($1.start).utf8.count }),
              let end = lines.max(by: { AIText.formatTime($0.end).utf8.count < AIText.formatTime($1.end).utf8.count }) else { return [] }
        return [start, end]
    }
}

func clipsSnapPair(start: Int, end: Int, lines: [TranscriptLine], radius: Int = 3) -> (Int, Int) {
    let starts = lines.map(\.firstIndex)
    let ends = lines.map(\.lastIndex)
    let snappedStart = starts.filter { abs($0 - start) <= radius }.min { abs($0 - start) == abs($1 - start) ? $0 < $1 : abs($0 - start) < abs($1 - start) } ?? start
    let snappedEnd = ends.filter { abs($0 - end) <= radius }.min { abs($0 - end) == abs($1 - end) ? $0 > $1 : abs($0 - end) < abs($1 - end) } ?? end
    return snappedStart <= snappedEnd ? (snappedStart, snappedEnd) : (start, end)
}
