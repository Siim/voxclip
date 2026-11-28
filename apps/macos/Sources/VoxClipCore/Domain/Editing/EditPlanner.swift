import Foundation

struct SourceMapEntry: Sendable, Equatable {
    let source: MediaInterval
    let outputStart: Int64
    let outputEnd: Int64
}

func sourceMapEntry<T>(_ entries: [T], at sample: Int64, start: (T) -> Int64) -> T? {
    var lower = 0, upper = entries.count
    while lower < upper {
        let middle = lower + (upper - lower) / 2
        if start(entries[middle]) <= sample { lower = middle + 1 } else { upper = middle }
    }
    return lower == 0 ? nil : entries[lower - 1]
}

func sourceMapEntry(_ entries: [SourceMapEntry], at sample: Int64) -> SourceMapEntry? {
    sourceMapEntry(entries, at: sample) { $0.source.startSample }
}

extension ClipRange {
    func singlePartClips() -> [ClipRange] {
        playParts.enumerated().map { index, part in
            ClipRange(id: id, startWordId: part.startWordId, endWordId: part.endWordId,
                      leadInSeconds: index == 0 ? leadInSeconds : nil)
        }
    }
}

/// Plans the parts independently and joins their kept spans in playback order on a single sample grid.
public func buildStoryPlan(_ state: EditState, clip: ClipRange, duration: Double, sampleRate: Double) throws -> EditPlan {
    guard clip.parts != nil, StoryClips.valid(clip, words: state.transcript.words) else {
        throw VoxClipError.projectUnreadable("Invalid story clip parts or source hull")
    }
    let plans = try clip.singlePartClips().map { part in
        try EditPlan.build(transcript: state.transcript, editState: state, activeClip: part, duration: duration, sampleRate: sampleRate)
    }
    let total = plans[0].totalSamples
    var kept: [MediaInterval] = [], seams: [Int64] = [], offset: Int64 = 0
    for plan in plans where !plan.kept.isEmpty {
        if offset > 0 { seams.append(offset) }
        kept += plan.kept
        offset += plan.outputSamples
    }
    let sorted = kept.sorted { $0.startSample < $1.startSample }
    guard zip(sorted, sorted.dropFirst()).allSatisfy({ $0.endSample <= $1.startSample }) else {
        throw VoxClipError.projectUnreadable("Story parts overlap on the source sample grid")
    }
    return EditPlan(sampleRate: plans[0].sampleRate, totalSamples: total, cuts: complement(sorted, total: total),
                    kept: kept, partSeams: seams, recordingRegions: plans[0].recordingRegions)
}

func complement(_ ordered: [MediaInterval], total: Int64) -> [MediaInterval] {
    var cuts: [MediaInterval] = [], cursor: Int64 = 0
    for span in ordered {
        if cursor < span.startSample { cuts.append(MediaInterval(startSample: cursor, endSample: span.startSample)) }
        cursor = span.endSample
    }
    if cursor < total { cuts.append(MediaInterval(startSample: cursor, endSample: total)) }
    return cuts
}

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

    static func makeFadeParts(kept: [MediaInterval], totalSamples: Int64, sampleRate: Double, regions: [MediaInterval]) -> [FadePart] {
        guard sampleRate.isFinite, sampleRate > 0 else { return [] }
        let fadeLength = Int64(min(Double(Int64.max / 2), max(0, EditingPrimitives.jsRound(0.005 * sampleRate))))
        var offset: Int64 = 0
        return kept.map { interval in
            let fade = min(fadeLength, interval.count / 2)
            let atStart = interval.startSample <= 0 || regions.contains { $0.startSample == interval.startSample }
            let atEnd = interval.endSample >= totalSamples || regions.contains { $0.endSample == interval.endSample }
            let result = FadePart(outputStart: offset, length: interval.count, fadeIn: atStart ? 0 : fade, fadeOut: atEnd ? 0 : fade)
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

public func clipTimes(_ words: [TimedWord], startIndex: Int, endIndex: Int, leadIn: Double? = nil) throws -> TimeRange {
    guard startIndex >= 0, endIndex >= startIndex, endIndex < words.count else { throw VoxClipError.projectUnreadable("Invalid clip bounds") }
    let first = words[startIndex], last = words[endIndex]
    let lead = startIndex > 0 ? max(0, first.start - words[startIndex - 1].end) / 2 : 0.12
    let tail = endIndex + 1 < words.count ? max(0, words[endIndex + 1].start - last.end) / 2 : 0.25
    var start = max(0, first.start - min(0.12, lead))
    if let leadIn, leadIn.isFinite, leadIn > 0 {
        start = min(start, max(clipLeadInFloor(words, startIndex: startIndex), first.start - leadIn))
    }
    return TimeRange(start: start, end: last.end + min(0.25, tail))
}

/// The earliest a clip may open (ADR-R48): after the item before its first one and that item's own cut margin (`rawCutRange`
/// keeps up to 0.1 s after a cut word), so an opening lead-in moves only through silence and never brings back a sound of
/// the item before; 0 for the first item.
public func clipLeadInFloor(_ words: [TimedWord], startIndex: Int) -> Double {
    guard startIndex > 0, startIndex < words.count else { return 0 }
    let previous = words[startIndex - 1].end, first = words[startIndex].start
    return min(first, previous + min(0.1, max(0, first - previous) / 2))
}

/// The clip's own edges, its opening lead-in honoured.
public func clipTimes(_ words: [TimedWord], clip: ClipRange, startIndex: Int, endIndex: Int) throws -> TimeRange {
    try clipTimes(words, startIndex: startIndex, endIndex: endIndex, leadIn: clip.leadInSeconds)
}

func scopedClipTimes(_ state: EditState, bounds: ClosedRange<Int>, leadIn: Double?) throws -> TimeRange {
    guard let clock = state.projectClock, clock.regions.count > 1 else {
        return try clipTimes(state.transcript.words, startIndex: bounds.lowerBound, endIndex: bounds.upperBound, leadIn: leadIn)
    }
    let (region, range) = try localClipTimes(state.transcript.words, bounds: bounds, leadIn: leadIn, clock: clock)
    let offset = Double(region.offsetSamples) / Double(clock.sampleRate)
    return TimeRange(start: range.start + offset, end: range.end + offset)
}

private func localClipTimes(_ words: [TimedWord], bounds: ClosedRange<Int>, leadIn: Double?, clock: ProjectClock) throws -> (ProjectClock.Region, TimeRange) {
    let first = bounds.lowerBound, last = bounds.upperBound
    guard let region = clock.region(of: words[first].id), region == clock.region(of: words[last].id) else {
        throw VoxClipError.projectUnreadable("A part comes from one recording.")
    }
    let start = first > 0 && clock.region(of: words[first - 1].id) == region ? first - 1 : first
    let end = last + 1 < words.count && clock.region(of: words[last + 1].id) == region ? last + 1 : last
    let local = words[start...end].map { word in
        var word = word
        word.start = recordingLocalTime(word.start, region: region, rate: Double(clock.sampleRate))
        word.end = recordingLocalTime(word.end, region: region, rate: Double(clock.sampleRate))
        return word
    }
    let times = try clipTimes(local, startIndex: first - start, endIndex: last - start, leadIn: leadIn)
    return (region, TimeRange(start: times.start, end: min(times.end, Double(region.durationSamples) / Double(clock.sampleRate))))
}

private func recordingLocalTime(_ time: Double, region: ProjectClock.Region, rate: Double) -> Double {
    region.offsetSamples == 0 ? time : (EditingPrimitives.jsRound(time * rate) - Double(region.offsetSamples)) / rate
}

func buildScopedEditPlan(_ segments: [EditSegment], state: EditState, activeClip: ClipRange?, duration: Double, rate: Double) throws -> EditPlan {
    guard let clock = state.projectClock, clock.regions.count > 1 else {
        return try buildEditPlan(segments, duration: duration, sampleRate: rate, pauseKeepSeconds: state.pauseKeepSeconds)
    }
    let rate = Double(clock.sampleRate)
    let scope = try clipIndices(activeClip, words: state.transcript.words).map {
        try localClipTimes(state.transcript.words, bounds: $0, leadIn: activeClip?.leadInSeconds, clock: clock)
    }
    var kept: [MediaInterval] = []
    for region in clock.regions where scope == nil || scope?.0 == region {
        let offset = Double(region.offsetSamples) / rate
        let end = Double(region.endSample) / rate
        let duration = Double(region.durationSamples) / rate
        var local = segments.compactMap { segment -> EditSegment? in
            guard segment.kind != .range, offset <= segment.start, segment.start < end,
                  segment.kind != .pause || segment.end <= end else { return nil }
            var segment = segment
            segment.start = recordingLocalTime(segment.start, region: region, rate: rate)
            segment.end = recordingLocalTime(segment.end, region: region, rate: rate)
            segment.cutStart = segment.cutStart.map { recordingLocalTime($0, region: region, rate: rate) }
            segment.cutEnd = segment.cutEnd.map { recordingLocalTime($0, region: region, rate: rate) }
            return segment
        }
        if let (_, range) = scope {
            local.append(EditSegment(id: "clip-head", kind: .range, start: 0, end: range.start, cut: true))
            local.append(EditSegment(id: "clip-tail", kind: .range, start: range.end, end: duration, cut: true))
        }
        let plan = try buildEditPlan(local, duration: duration, sampleRate: rate, pauseKeepSeconds: state.pauseKeepSeconds)
        kept += plan.kept.map { MediaInterval(startSample: $0.startSample + Int64(region.offsetSamples), endSample: $0.endSample + Int64(region.offsetSamples)) }
    }
    let total = Int64(clock.totalSamples)
    return EditPlan(sampleRate: rate, totalSamples: total, cuts: complement(kept, total: total), kept: kept, partSeams: [],
                    recordingRegions: clock.sampleRegions)
}

func recordingSeamSamples<Piece>(_ pieces: [Piece], regions: [MediaInterval], source: (Piece) -> Int64, output: (Piece) -> Int64) -> [Int64] {
    guard regions.count > 1 else { return [] }
    var previous: Int?
    return pieces.compactMap { piece in
        let sample = source(piece)
        let current = regions.firstIndex { $0.startSample <= sample && sample < $0.endSample }
        defer { previous = current }
        return previous != nil && current != nil && previous != current ? output(piece) : nil
    }
}

func clipIndices(_ clip: ClipRange?, words: [TimedWord]) -> ClosedRange<Int>? {
    guard let clip, let ranges = clip.playPartIndices(in: words), ranges.count == 1 else { return nil }
    return ranges.first
}

public func buildSegments(_ state: EditState, activeClip: ClipRange?) throws -> [EditSegment] {
    let words = state.transcript.words
    let ranges = activeClip?.playPartIndices(in: words)
    if activeClip != nil, ranges == nil { throw VoxClipError.projectUnreadable("Invalid clip bounds") }
    var segments = words.enumerated().map { index, word in
        EditSegment(id: word.id, kind: .word, wordKind: word.kind, text: state.textOf(word), start: word.start, end: word.end,
                    cut: state.cutWordIds.contains(word.id) || !(ranges?.contains { $0.contains(index) } ?? true))
    }
    // Stored cut edges (editing §5.10) replace the padded edge at a kept/cut boundary, converted from local to clock time.
    for index in words.indices.dropFirst() {
        guard let edge = state.cutEdges[words[index].id] else { continue }
        let clock = state.clockTime(ofEdge: edge, word: words[index].id)
        if segments[index].cut && !segments[index - 1].cut { segments[index].cutStart = clock }
        if !segments[index].cut && segments[index - 1].cut { segments[index - 1].cutEnd = clock }
    }
    segments += state.pauses.filter { state.cutPauseIds.contains($0.id) }.map {
        EditSegment(id: $0.id, kind: .pause, start: $0.start, end: $0.end, cut: true)
    }
    if let ranges, ranges.count == 1, let bounds = ranges.first {
        let times = try scopedClipTimes(state, bounds: bounds, leadIn: activeClip?.leadInSeconds)
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
    return TimeRange(start: segment.cutStart ?? (segment.start - min(0.1, max(0, segment.start - earlierEnd) / 2)),
                     end: segment.cutEnd ?? (segment.end + min(0.1, max(0, nextStart - segment.end) / 2)))
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
    let seams = plan.captionSeams
    if !seams.isEmpty {
        let offsets = [0] + seams + [plan.outputSamples]
        var result: [CaptionWord] = [], keptIndex = 0
        for (start, end) in zip(offsets, offsets.dropFirst()) {
            let first = keptIndex
            while keptIndex < plan.kept.count && plan.fadeParts[keptIndex].outputStart < end { keptIndex += 1 }
            let kept = Array(plan.kept[first..<keptIndex])
            let part = EditPlan(sampleRate: plan.sampleRate, totalSamples: plan.totalSamples, cuts: complement(kept, total: plan.totalSamples), kept: kept)
            let captions = captionCopy(segments, plan: part)
            result += shiftedPartCaptions(captions, by: start, rate: plan.sampleRate, startsPart: !result.isEmpty)
        }
        return result
    }
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

func shiftedPartCaptions(_ captions: [CaptionWord], by offset: Int64, rate: Double, startsPart: Bool) -> [CaptionWord] {
    captions.enumerated().map { index, word in
        var word = word
        word.start += Double(offset) / rate
        word.end += Double(offset) / rate
        if index == 0 && startsPart { word.startsPart = true }
        return word
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
