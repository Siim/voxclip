import Foundation

public struct FadePart: Sendable, Equatable, Codable {
    public var outputStart: Int64
    public var length: Int64
    public var fadeIn: Int64
    public var fadeOut: Int64
}

extension EditPlan {
    func clampSample(_ time: Double) -> Int64 {
        Int64(min(Double(totalSamples), max(0, EditingPrimitives.jsRound(time * sampleRate))))
    }

    public func cutContaining(_ time: Double) -> MediaInterval? {
        cuts.first { Double($0.startSample) / sampleRate <= time && time < Double($0.endSample) / sampleRate }
    }

    static func makeFadeParts(kept: [MediaInterval], totalSamples: Int64, sampleRate: Double) -> [FadePart] {
        guard sampleRate.isFinite, sampleRate > 0 else { return [] }
        let fadeLength = Int64(min(Double(Int64.max / 2), max(0, EditingPrimitives.jsRound(0.005 * sampleRate))))
        var offset: Int64 = 0
        return kept.map { interval in
            let fade = min(fadeLength, interval.count / 2)
            let result = FadePart(outputStart: offset, length: interval.count, fadeIn: interval.startSample > 0 ? fade : 0,
                                  fadeOut: interval.endSample < totalSamples ? fade : 0)
            offset += interval.count
            return result
        }
    }

    static func makeJoins(parts: [FadePart], outputSamples: Int64) -> [Join] {
        var joins: [Join] = []
        joins.reserveCapacity(parts.count + 1)
        for (index, part) in parts.enumerated() {
            if index == 0 {
                if part.fadeIn > 0 { joins.append(Join(outSample: 0, fadeOutLen: 0, fadeInLen: part.fadeIn)) }
            } else {
                joins.append(Join(outSample: part.outputStart, fadeOutLen: parts[index - 1].fadeOut, fadeInLen: part.fadeIn))
            }
        }
        if let last = parts.last, last.fadeOut > 0 { joins.append(Join(outSample: outputSamples, fadeOutLen: last.fadeOut, fadeInLen: 0)) }
        return joins
    }
}

func validSegment(_ segment: EditSegment) -> Bool { segment.start.isFinite && segment.end.isFinite && segment.end > segment.start }

public func clipTimes(_ words: [TimedWord], startIndex: Int, endIndex: Int) throws -> TimeRange {
    guard startIndex >= 0, endIndex >= startIndex, endIndex < words.count else { throw VoxClipError.projectUnreadable("Invalid clip bounds") }
    let first = words[startIndex], last = words[endIndex]
    let lead = startIndex > 0 ? max(0, first.start - words[startIndex - 1].end) / 2 : 0.12
    let tail = endIndex + 1 < words.count ? max(0, words[endIndex + 1].start - last.end) / 2 : 0.25
    return TimeRange(start: max(0, first.start - min(0.12, lead)), end: last.end + min(0.25, tail))
}

func clipIndices(_ clip: ClipRange?, words: [TimedWord]) -> ClosedRange<Int>? {
    guard let clip, let start = words.firstIndex(where: { $0.id == clip.startWordId }),
          let end = words.firstIndex(where: { $0.id == clip.endWordId }), start <= end else { return nil }
    return start...end
}

public func buildSegments(_ state: EditState, activeClip: ClipRange?) throws -> [EditSegment] {
    let words = state.transcript.words
    let bounds = clipIndices(activeClip, words: words)
    if activeClip != nil, bounds == nil { throw VoxClipError.projectUnreadable("Invalid clip bounds") }
    var segments = words.enumerated().map { index, word in
        EditSegment(id: word.id, kind: .word, wordKind: word.kind, text: state.textOf(word), start: word.start, end: word.end,
                    cut: state.cutWordIds.contains(word.id) || !(bounds?.contains(index) ?? true))
    }
    segments += state.pauses.filter { state.cutPauseIds.contains($0.id) }.map {
        EditSegment(id: $0.id, kind: .pause, start: $0.start, end: $0.end, cut: true)
    }
    if let bounds {
        let times = try clipTimes(words, startIndex: bounds.lowerBound, endIndex: bounds.upperBound)
        if times.start > 0 { segments.append(EditSegment(id: "clip-head", kind: .range, start: 0, end: times.start, cut: true)) }
        let end = max(times.end, words.last?.end ?? times.end) + 3600
        if end > times.end { segments.append(EditSegment(id: "clip-tail", kind: .range, start: times.end, end: end, cut: true)) }
    }
    return EditingPrimitives.stableSorted(segments, by: \.start)
}

public func cutRange(_ segment: EditSegment, segments: [EditSegment], pauseKeepSeconds: Double) throws -> TimeRange {
    try cutRange(segment, segments: segments, duration: segments.filter(validSegment).map(\.end).max() ?? segment.end, pauseKeepSeconds: pauseKeepSeconds)
}

public func cutRange(_ segment: EditSegment, segments: [EditSegment], duration: Double, pauseKeepSeconds: Double) throws -> TimeRange {
    guard let position = segments.firstIndex(where: { $0.id == segment.id && $0 == segment }) else { throw VoxClipError.projectUnreadable("Missing segment") }
    return rawCutRange(at: position, segments: segments, index: CutRangeIndex(segments), duration: duration, pauseKeep: pauseKeepSeconds)
}

func speechIndices(_ segments: [EditSegment]) -> [Int] {
    EditingPrimitives.stableSorted(segments.indices.filter { segments[$0].kind == .word && validSegment(segments[$0]) }) { segments[$0].start }
}

struct CutRangeIndex {
    let speech: [Int]
    let ranks: [Int]
    let earlierEnds: [Double]
    let starts: [Double]
    let byEnd: [Int]
    let ends: [Double]

    init(_ segments: [EditSegment]) {
        let speech = speechIndices(segments)
        self.speech = speech
        var ranks = Array(repeating: -1, count: segments.count)
        var earlierEnds: [Double] = []
        earlierEnds.reserveCapacity(speech.count)
        var earlierEnd = 0.0
        for (rank, position) in speech.enumerated() {
            ranks[position] = rank
            earlierEnds.append(earlierEnd)
            earlierEnd = max(earlierEnd, segments[position].end)
        }
        self.ranks = ranks
        self.earlierEnds = earlierEnds
        starts = speech.map { segments[$0].start }
        let byEnd = speech.sorted {
            let left = segments[$0].end, right = segments[$1].end
            return left == right ? ranks[$0] > ranks[$1] : left < right
        }
        self.byEnd = byEnd
        ends = byEnd.map { segments[$0].end }
    }

    func lowerBound(_ values: [Double], _ target: Double, inclusive: Bool) -> Int {
        var lower = 0, upper = values.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if values[middle] < target || (inclusive && values[middle] == target) { lower = middle + 1 }
            else { upper = middle }
        }
        return lower
    }
}

func rawCutRange(at position: Int, segments: [EditSegment], index: CutRangeIndex, duration: Double, pauseKeep: Double) -> TimeRange {
    let segment = segments[position]
    if segment.kind == .range { return TimeRange(start: segment.start, end: segment.end) }
    if segment.kind == .pause {
        let beforeRank = index.lowerBound(index.ends, segment.start + 1e-6, inclusive: true) - 1
        let afterRank = index.lowerBound(index.starts, segment.end - 1e-6, inclusive: false)
        let before = beforeRank >= 0 ? segments[index.byEnd[beforeRank]] : nil
        let after = afterRank < index.speech.count ? segments[index.speech[afterRank]] : nil
        return TimeRange(start: segment.start + (before.map { !$0.cut } == true ? pauseKeep : 0),
                         end: segment.end - (after.map { !$0.cut } == true ? pauseKeep : 0))
    }
    let rank = index.ranks[position]
    guard rank >= 0 else { return TimeRange(start: segment.start, end: segment.end) }
    let earlierEnd = index.earlierEnds[rank]
    if earlierEnd >= segment.end { return TimeRange(start: segment.start, end: segment.end) }
    let nextStart = rank + 1 < index.speech.count ? index.starts[rank + 1] : duration
    return TimeRange(start: segment.start - min(0.1, max(0, segment.start - earlierEnd) / 2),
                     end: segment.end + min(0.1, max(0, nextStart - segment.end) / 2))
}

public func buildEditPlan(_ segments: [EditSegment], duration: Double, sampleRate: Double, pauseKeepSeconds: Double = 0.15) throws -> EditPlan {
    guard duration.isFinite, duration >= 0, sampleRate.isFinite, sampleRate > 0,
          (duration * sampleRate).isFinite, EditingPrimitives.jsRound(duration * sampleRate) < Double(Int64.max),
          pauseKeepSeconds.isFinite, (0...1).contains(pauseKeepSeconds) else {
        throw VoxClipError.projectUnreadable("Invalid media duration or sample rate")
    }
    guard !segments.contains(where: { $0.kind == .range && !$0.cut }) else { throw VoxClipError.projectUnreadable("Range segments must be cut") }
    let total = Int64(max(0, EditingPrimitives.jsRound(duration * sampleRate)))
    var plan = EditPlan(sampleRate: sampleRate, totalSamples: total)
    let cutIndex = CutRangeIndex(segments)
    var selected: [(Int, MediaInterval)] = []
    for index in segments.indices where segments[index].cut && validSegment(segments[index]) {
        let range = rawCutRange(at: index, segments: segments, index: cutIndex, duration: duration, pauseKeep: pauseKeepSeconds)
        let interval = MediaInterval(startSample: plan.clampSample(range.start), endSample: plan.clampSample(range.end))
        if interval.count > 0 { selected.append((index, interval)) }
    }
    selected.sort { $0.1.startSample == $1.1.startSample ? $0.0 < $1.0 : $0.1.startSample < $1.1.startSample }
    for (_, interval) in selected {
        if let last = plan.cuts.indices.last, interval.startSample <= plan.cuts[last].endSample {
            plan.cuts[last].endSample = max(plan.cuts[last].endSample, interval.endSample)
        } else { plan.cuts.append(interval) }
    }
    var kept: [MediaInterval] = []
    var cursor: Int64 = 0
    for cut in plan.cuts {
        if cut.startSample > cursor { kept.append(MediaInterval(startSample: cursor, endSample: cut.startSample)) }
        cursor = cut.endSample
    }
    if cursor < total { kept.append(MediaInterval(startSample: cursor, endSample: total)) }
    plan.kept = kept
    return plan
}

public func captionCopy(_ segments: [EditSegment], plan: EditPlan) -> [CaptionWord] {
    let words = segments.filter { $0.kind == .word && $0.wordKind == .word && !$0.cut && validSegment($0) }
    var samples: [Int64] = []
    samples.reserveCapacity(words.count * 2)
    for word in words {
        samples.append(plan.clampSample(word.start))
        samples.append(plan.clampSample(word.end))
    }
    let ordered = orderedCaptionBoundaries(samples)
    var mapped = Array(repeating: Int64(0), count: samples.count)
    var cutIndex = 0, removed: Int64 = 0
    for index in ordered {
        let sample = samples[index]
        while cutIndex < plan.cuts.count, plan.cuts[cutIndex].endSample <= sample {
            removed += plan.cuts[cutIndex].count
            cutIndex += 1
        }
        let partial = cutIndex < plan.cuts.count ? max(0, sample - plan.cuts[cutIndex].startSample) : 0
        mapped[index] = min(plan.outputSamples, max(0, sample - removed - partial))
    }
    return words.indices.compactMap { index in
        let start = Double(mapped[index * 2]) / plan.sampleRate, end = Double(mapped[index * 2 + 1]) / plan.sampleRate
        let word = words[index]
        return end > start ? CaptionWord(id: word.id, text: word.text, start: start, end: end) : nil
    }
}

func orderedCaptionBoundaries(_ samples: [Int64]) -> [Int] {
    var ordered = Array(samples.indices)
    guard zip(samples, samples.dropFirst()).contains(where: { $0 > $1 }) else { return ordered }
    let largest = samples.max() ?? 0
    var buffer = ordered
    var shift = 0
    while shift < Int64.bitWidth, largest >> shift > 0 {
        var offsets = Array(repeating: 0, count: 256)
        for index in ordered { offsets[Int((samples[index] >> shift) & 255)] += 1 }
        var offset = 0
        for bucket in offsets.indices {
            let count = offsets[bucket]
            offsets[bucket] = offset
            offset += count
        }
        for index in ordered {
            let bucket = Int((samples[index] >> shift) & 255)
            buffer[offsets[bucket]] = index
            offsets[bucket] += 1
        }
        swap(&ordered, &buffer)
        shift += 8
    }
    return ordered
}
