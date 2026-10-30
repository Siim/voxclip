import Foundation

/// One transcript item as §6.5.1 reads it. Times are source seconds, never edited times.
public struct VoiceTrainingItem: Sendable, Equatable {
    public var kind: WordKind
    public var start: Double
    public var end: Double
    public var conf: Double?
    public var speaker: String?
    public var synthetic: Bool
    public init(kind: WordKind = .word, start: Double, end: Double, conf: Double? = nil, speaker: String? = nil, synthetic: Bool = false) {
        self.kind = kind; self.start = start; self.end = end; self.conf = conf; self.speaker = speaker; self.synthetic = synthetic
    }
}

/// A source range in seconds that training never uses.
public struct VoiceTrainingRange: Sendable, Equatable {
    public var start: Double
    public var end: Double
    public init(start: Double, end: Double) { self.start = start; self.end = end }
}

public struct VoiceTrainingSpan: Sendable, Equatable {
    public var startMs: Int
    public var endMs: Int
    public var snrDb: Double
    public init(startMs: Int, endMs: Int, snrDb: Double) { self.startMs = startMs; self.endMs = endMs; self.snrDb = snrDb }
    public var durationMs: Int { endMs - startMs }
}

public struct VoiceTrainingRejection: Sendable, Equatable {
    public enum Reason: String, Sendable { case short, unsplittable, lowSnr }
    public var startMs: Int
    public var endMs: Int
    public var reason: Reason
    public var snrDb: Double?
    public init(startMs: Int, endMs: Int, reason: Reason, snrDb: Double?) {
        self.startMs = startMs; self.endMs = endMs; self.reason = reason; self.snrDb = snrDb
    }
}

public struct VoiceTrainingSpanSelection: Sendable, Equatable {
    public enum Status: String, Sendable { case ok, belowMinimum }
    public var status: Status
    public var availableMs: Int
    public var selectedMs: Int
    /// Source order.
    public var selected: [VoiceTrainingSpan]
    /// Source order, for tests and diagnostics.
    public var qualifying: [VoiceTrainingSpan]
    /// Source order, for tests and diagnostics.
    public var rejected: [VoiceTrainingRejection]
    public init(status: Status, availableMs: Int, selectedMs: Int, selected: [VoiceTrainingSpan], qualifying: [VoiceTrainingSpan], rejected: [VoiceTrainingRejection]) {
        self.status = status; self.availableMs = availableMs; self.selectedMs = selectedMs
        self.selected = selected; self.qualifying = qualifying; self.rejected = rejected
    }
}

/// §6.5.1: the spans of a project's own speech that may train an own-voice clone. Pure, and identical to the C# Core.
/// Vectors: shared/fixtures/voice-lab/training-spans.json.
public enum VoiceTrainingSpans {
    public static let TRAIN_MIN_CONF = 0.8
    public static let TRAIN_MAX_GAP = 2_000
    public static let TRAIN_SPAN_MIN = 5_000
    public static let TRAIN_SPAN_MAX = 30_000
    public static let TRAIN_VOICED = -45.0
    public static let TRAIN_MIN_SNR = 20.0
    public static let TRAIN_TOTAL_MIN = 30_000
    public static let TRAIN_TOTAL_MAX = 120_000

    private struct Word { let start: Int; let end: Int }
    private enum Outcome { case kept(Int, Int), rejected(VoiceTrainingRejection) }

    /// Every time is first converted to whole milliseconds; everything after that is integer arithmetic, except the SNR.
    /// A non-finite number, an excluded range ending before it starts or a negative duration is `invalidInput`.
    public static func select(items: [VoiceTrainingItem], excluded: [VoiceTrainingRange], frameDb: [Double], duration: Double) throws -> VoiceTrainingSpanSelection {
        guard duration.isFinite, duration >= 0, frameDb.allSatisfy(\.isFinite) else { throw VoiceLabError.invalidInput }
        let total = try ms(duration)
        let ranges: [(start: Int, end: Int)] = try excluded.map { range in
            guard range.start.isFinite, range.end.isFinite, range.end >= range.start else { throw VoiceLabError.invalidInput }
            return (try ms(range.start), try ms(range.end))
        }
        // Steps 1 and 2: any item that is not a usable word ends the run; a speaker change, a gap over TRAIN_MAX_GAP or an
        // excluded range inside the gap starts a new one.
        var runs: [[Word]] = [], run: [Word] = [], runSpeaker: String?, runEnd = 0
        for item in items {
            guard item.start.isFinite, item.end.isFinite, item.conf?.isFinite ?? true else { throw VoiceLabError.invalidInput }
            let start = try ms(item.start), end = try ms(item.end)
            let usable = item.kind == .word && (item.conf.map { $0 >= TRAIN_MIN_CONF } ?? true) && !item.synthetic
                && start < end && end <= total && !ranges.contains { $0.start < end && $0.end > start }
            guard usable else {
                if !run.isEmpty { runs.append(run); run = [] }
                continue
            }
            if !run.isEmpty, item.speaker == runSpeaker, start - runEnd <= TRAIN_MAX_GAP, !ranges.contains(where: { $0.start < start && $0.end > runEnd }) {
                run.append(Word(start: start, end: end)); runEnd = max(runEnd, end)
            } else {
                if !run.isEmpty { runs.append(run) }
                run = [Word(start: start, end: end)]; runSpeaker = item.speaker; runEnd = end
            }
        }
        if !run.isEmpty { runs.append(run) }
        // Step 3: split long pieces at the longest valid gap, the one nearest the middle, then the earliest; left side first.
        var outcomes: [Outcome] = []
        for words in runs {
            var pending = [0..<words.count]
            while let piece = pending.popLast() {
                let start = words[piece.lowerBound].start
                let end = words[piece].map(\.end).max()!
                if end - start < TRAIN_SPAN_MIN { outcomes.append(.rejected(.init(startMs: start, endMs: end, reason: .short, snrDb: nil))); continue }
                if end - start <= TRAIN_SPAN_MAX { outcomes.append(.kept(start, end)); continue }
                var rightEnds = [Int](repeating: 0, count: piece.count)
                var latest = Int.min
                for index in piece.reversed() { latest = max(latest, words[index].end); rightEnds[index - piece.lowerBound] = latest }
                var best: (gap: Int, center: Int, boundary: Int)?
                var leftEnd = Int.min
                for boundary in piece.lowerBound..<(piece.upperBound - 1) {
                    leftEnd = max(leftEnd, words[boundary].end)
                    let rightStart = words[boundary + 1].start, rightEnd = rightEnds[boundary + 1 - piece.lowerBound]
                    guard leftEnd - start >= TRAIN_SPAN_MIN, rightEnd - rightStart >= TRAIN_SPAN_MIN else { continue }
                    let gap = rightStart - leftEnd, center = abs(leftEnd + rightStart - start - end)
                    if best.map({ gap > $0.gap || (gap == $0.gap && center < $0.center) }) ?? true { best = (gap, center, boundary) }
                }
                guard let best else { outcomes.append(.rejected(.init(startMs: start, endMs: end, reason: .unsplittable, snrDb: nil))); continue }
                pending.append((best.boundary + 1)..<piece.upperBound)
                pending.append(piece.lowerBound..<(best.boundary + 1))
            }
        }
        // Step 4: SNR is the piece's median voiced frame over the take's 10th-percentile frame.
        let count = frameDb.count
        let floorDb: Double? = count == 0 ? nil : frameDb.sorted()[count / 10]
        var qualifying: [(span: VoiceTrainingSpan, order: Int)] = [], rejected: [(rejection: VoiceTrainingRejection, order: Int)] = []
        for (order, outcome) in outcomes.enumerated() {
            switch outcome {
            case .rejected(let rejection): rejected.append((rejection, order))
            case .kept(let start, let end):
                let low = min(max(floorDivide(start + 5, 10), 0), count), high = min(max(floorDivide(end + 5, 10), 0), count)
                let voiced = low < high ? frameDb[low..<high].filter { $0 > TRAIN_VOICED }.sorted() : []
                let snr = floorDb.flatMap { floor in voiced.isEmpty ? nil : voiced[voiced.count / 2] - floor }
                if let snr, snr >= TRAIN_MIN_SNR { qualifying.append((.init(startMs: start, endMs: end, snrDb: snr), order)) }
                else { rejected.append((.init(startMs: start, endMs: end, reason: .lowSnr, snrDb: snr), order)) }
            }
        }
        qualifying.sort { $0.span.startMs == $1.span.startMs ? $0.order < $1.order : $0.span.startMs < $1.span.startMs }
        rejected.sort { $0.rejection.startMs == $1.rejection.startMs ? $0.order < $1.order : $0.rejection.startMs < $1.rejection.startMs }
        let spans = qualifying.map(\.span)
        let available = spans.reduce(0) { $0 + $1.durationMs }
        guard available >= TRAIN_TOTAL_MIN else {
            return .init(status: .belowMinimum, availableMs: available, selectedMs: 0, selected: [], qualifying: spans, rejected: rejected.map(\.rejection))
        }
        // Steps 5 and 6: best SNR, then longest, then earliest; a span that would pass TRAIN_TOTAL_MAX is skipped.
        let ranked = spans.indices.sorted { left, right in
            let a = spans[left], b = spans[right]
            if a.snrDb != b.snrDb { return a.snrDb > b.snrDb }
            if a.durationMs != b.durationMs { return a.durationMs > b.durationMs }
            return a.startMs == b.startMs ? left < right : a.startMs < b.startMs
        }
        var chosen: [Int] = [], selected = 0
        for index in ranked where selected + spans[index].durationMs <= TRAIN_TOTAL_MAX {
            chosen.append(index); selected += spans[index].durationMs
        }
        return .init(status: .ok, availableMs: available, selectedMs: selected, selected: chosen.sorted().map { spans[$0] },
                     qualifying: spans, rejected: rejected.map(\.rejection))
    }

    /// §6.5.1 inputs from a project: its transcript items in stored order, synthetic from `firstWordId` to `lastWordId`
    /// of every Voice Lab segment, and every segment's `replace` range excluded, enabled or not. Times are source
    /// seconds; cuts and corrections are ignored.
    public static func inputs(project: Project) -> (items: [VoiceTrainingItem], excluded: [VoiceTrainingRange]) {
        let words = project.transcript?.words ?? []
        var positions: [String: Int] = [:]
        for (position, word) in words.enumerated() where positions[word.id] == nil { positions[word.id] = position }
        var synthetic = [Bool](repeating: false, count: words.count)
        for segment in project.voiceLab.segments {
            guard let first = positions[segment.replace.firstWordId], let last = positions[segment.replace.lastWordId], first <= last else { continue }
            for position in first...last { synthetic[position] = true }
        }
        let items = words.enumerated().map { position, word in
            VoiceTrainingItem(kind: word.kind, start: word.start, end: word.end, conf: word.conf, speaker: word.speaker, synthetic: synthetic[position])
        }
        return (items, project.voiceLab.segments.map { VoiceTrainingRange(start: $0.replace.start, end: $0.replace.end) })
    }

    /// `ms(t) = floor(t × 1000 + 0.5)` in binary64. A time beyond ±2^53 ms cannot be held exactly and is refused.
    static func ms(_ seconds: Double) throws -> Int {
        let value = (seconds * 1000 + 0.5).rounded(.down)
        guard value.isFinite, abs(value) <= 9_007_199_254_740_992 else { throw VoiceLabError.invalidInput }
        return Int(value)
    }

    private static func floorDivide(_ value: Int, _ divisor: Int) -> Int {
        let quotient = value / divisor
        return value % divisor != 0 && (value < 0) != (divisor < 0) ? quotient - 1 : quotient
    }
}
