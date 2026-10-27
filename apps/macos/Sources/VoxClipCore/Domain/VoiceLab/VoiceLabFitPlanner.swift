import Foundation

/// The trimmed take (§8.7 step 1) on its paid asset, as the fit planner reads it (§8.9.2).
public struct VoiceLabFitTake: Sendable, Equatable {
    /// Every frame of the paid asset, fewer than 2^31.
    public var assetFrames: Int64
    public var assetSampleRate: Int
    /// The §8.7 trims in asset seconds; each lands on the frame jsRound gives.
    public var trimStart: Double
    public var trimEnd: Double
    /// The take's words from its character alignment (§8.8), in asset seconds and in order.
    public var words: [VoiceLabWord]
    /// The paid asset's 10 ms RMS envelope at its own rate: every whole frame from its first sample.
    public var envelope: AudioEnvelope
    public init(assetFrames: Int64, assetSampleRate: Int, trimStart: Double, trimEnd: Double, words: [VoiceLabWord],
                envelope: AudioEnvelope) {
        self.assetFrames = assetFrames; self.assetSampleRate = assetSampleRate
        self.trimStart = trimStart; self.trimEnd = trimEnd; self.words = words; self.envelope = envelope
    }
}

public enum VoiceLabFitEditKind: String, Sendable, Equatable { case remove, insert }

/// One pause edit in paid-asset frames. A removal drops frames `[start, start + count)`, and an insertion plays them twice.
/// Either way the playhead jumps once, at `start` for a removal and at `start + count` for an insertion, with one
/// equal-power `SEAM_FADE` join centred on the jump: `floor(N/2)` frames before it and `ceil(N/2)` after.
public struct VoiceLabFitEdit: Sendable, Equatable {
    public var kind: VoiceLabFitEditKind
    public var start: Int64
    public var count: Int64
    public init(kind: VoiceLabFitEditKind, start: Int64, count: Int64) { self.kind = kind; self.start = start; self.count = count }
}

/// One seam of a fitted take: silence on the asset grid, a take-edge pad included, and source samples borrowed from its gap.
public struct VoiceLabFitSeam: Sendable, Equatable {
    public var padFrames: Int64
    public var borrowedSamples: Int64
    public init(padFrames: Int64, borrowedSamples: Int64) { self.padFrames = padFrames; self.borrowedSamples = borrowedSamples }
}

/// A fit plan (§8.9.2 Output): the incoming pad, the edited take between the final trims and the outgoing pad.
public struct VoiceLabFitPlan: Sendable, Equatable {
    public var edits: [VoiceLabFitEdit]
    public var incoming: VoiceLabFitSeam
    public var outgoing: VoiceLabFitSeam
    /// The final trims on the paid asset's grid; the rounding residual may have moved one of them by a frame.
    public var trimStartFrame: Int64
    public var trimEndFrame: Int64
    /// The window after borrowing. A seam that borrowed sits on the source grid; the other keeps the window's time.
    public var windowStart: Double
    public var windowEnd: Double
    public var windowStartSample: Int64
    public var windowEndSample: Int64
    /// Asset frames between the handles. An exact plan has `jsRound(n × assetRate / sourceRate)` for its window's `n`.
    public var outputFrames: Int64
    /// The aligned words relative to the output start, all synthetic: each keeps its aligned frames and moves by the
    /// incoming pad and the edits before it.
    public var words: [VoiceLabWord]
    public init(edits: [VoiceLabFitEdit], incoming: VoiceLabFitSeam, outgoing: VoiceLabFitSeam, trimStartFrame: Int64,
                trimEndFrame: Int64, windowStart: Double, windowEnd: Double, windowStartSample: Int64, windowEndSample: Int64,
                outputFrames: Int64, words: [VoiceLabWord]) {
        self.edits = edits; self.incoming = incoming; self.outgoing = outgoing
        self.trimStartFrame = trimStartFrame; self.trimEndFrame = trimEndFrame
        self.windowStart = windowStart; self.windowEnd = windowEnd
        self.windowStartSample = windowStartSample; self.windowEndSample = windowEndSample
        self.outputFrames = outputFrames; self.words = words
    }
}

/// `exact` fills the window. `changedDuration` keeps every edit at its limit and lasts `duration(W) + residualSeconds`,
/// with the sign of ρ (§8.9 step 3); `naturalOut` is `e + D`, the take's length before any edit.
public enum VoiceLabFitResult: Sendable, Equatable {
    case exact(VoiceLabFitPlan)
    case changedDuration(VoiceLabFitPlan, naturalOut: Double, residualSeconds: Double)

    public var plan: VoiceLabFitPlan {
        switch self {
        case .exact(let plan), .changedDuration(let plan, _, _): plan
        }
    }
}

/// §8.9.2 silence-only duration fit: pure, deterministic and identical on both platforms (`fit-cases.json`). It edits only
/// the take's pauses and silence at the seams; every voiced frame is copied, which `plan` checks before it returns.
public enum VoiceLabFitPlanner {
    /// Paid-asset frames below this keep every product of the proportional split inside Int64.
    static let frameLimit: Int64 = 1 << 31
    /// Source rates the planner accepts: the schema's 1 Hz floor, and a ceiling under which no borrow overflows Int64.
    static let sourceRates: ClosedRange<Double> = 1...1_000_000

    /// One internal pause: the editable run after word `word`, in paid-asset frames.
    private struct Pause {
        var word: Int
        var start: Int64
        var end: Int64
        var punctuation: Bool
        var length: Int64 { end - start }
    }

    /// Plans the fit of `take` into `window`. `incomingSilence` and `outgoingSilence` are the §8.9.2 outside silences in
    /// seconds: for a gap seam the silence it can lend, which `VoiceLabWindowPlanner.lendableSilence(project:scope:window:)`
    /// measures, for a take edge (`none`) the silence to the window's nearest word, and nil for a hard seam. `tokens` are
    /// the patch tokens, one per word.
    public static func plan(window: VoiceLabWindow, incomingSilence: Double?, outgoingSilence: Double?, take: VoiceLabFitTake,
                            tokens: [String], sourceSampleRate rate: Double) throws -> VoiceLabFitResult {
        let kinds: [VoiceLabSeamKind] = [window.leftSeam.kind, window.rightSeam.kind]
        let silences: [Double?] = [incomingSilence, outgoingSilence]
        let reach = try validate(window: window, kinds: kinds, silences: silences, take: take, rate: rate)
        let assetRate = Double(take.assetSampleRate), total = take.assetFrames
        let size = VoiceLabGeometry.frameSize(assetRate)
        var t0 = VoiceLabGeometry.samples(take.trimStart, assetRate), t1 = VoiceLabGeometry.samples(take.trimEnd, assetRate)
        let spans = try wordSpans(take: take, tokens: tokens, t0: t0, t1: t1, rate: rate)
        let unvoiced = take.envelope.levels.map { Double($0) < VoiceLabPatchConstants.VOICED_FRAME_LEVEL }
        let pauses = findPauses(spans: spans, unvoiced: unvoiced, size: size, tokens: tokens)

        // The take must fill w = duration(W) − e frames; ρ > 0 means it is too long.
        let fade = VoiceLabGeometry.samples(VoiceLabPatchConstants.SEAM_FADE, assetRate)
        let leadIn = spans[0].start - t0, tailOut = t1 - spans[spans.count - 1].end
        let edgeIn: Int64 = kinds[0] == .none ? max(0, VoiceLabGeometry.samples(silences[0] ?? 0, assetRate) - leadIn) : 0
        let edgeOut: Int64 = kinds[1] == .none ? max(0, VoiceLabGeometry.samples(silences[1] ?? 0, assetRate) - tailOut) : 0
        let n = window.endSample - window.startSample
        let target = framesOf(n, assetRate: assetRate, rate: rate)
        let natural = edgeIn + edgeOut + t1 - t0
        let rho = natural - target, shorten = rho > 0
        let lengths = pauses.map(\.length)
        let rooms = roomsOf(pauses, shorten: shorten, assetRate: assetRate, fade: fade)
        var alloc = [Int64](repeating: 0, count: pauses.count)
        var remaining = abs(rho)
        for punctuation in [true, false] {
            let group = pauses.indices.filter { pauses[$0].punctuation == punctuation }
            remaining = spread(remaining, group, lengths: lengths, rooms: rooms, alloc: &alloc)
        }

        // Seams: borrow source samples into a gap, keeping PAUSE_SLACK_KEEP beside the kept word, or pad silence.
        var borrow: [Int64] = [0, 0], pad: [Int64] = [edgeIn, edgeOut], exact = true, lend: [Int64] = [0, 0]
        if remaining > 0 && shorten {
            let keep = VoiceLabGeometry.samples(VoiceLabPatchConstants.PAUSE_SLACK_KEEP, rate)
            let caps: [Int64] = reach.map { (samples: Int64) -> Int64 in
                let available: Int64 = samples - keep
                return max(0, available)
            }
            lend = caps
            let widest = framesOf(n + caps[0] + caps[1], assetRate: assetRate, rate: rate)
            if target + remaining <= widest {
                let remainingFrames: Double = Double(remaining)
                let neededSamples: Double = remainingFrames * rate / assetRate
                let roundedSamples: Double = EditingPrimitives.jsRound(neededSamples)
                let need: Int64 = Int64(roundedSamples)
                borrow = split(need, caps: caps)
            } else {
                borrow = caps; exact = false
            }
        } else if remaining > 0 {
            let gapPad = VoiceLabGeometry.samples(VoiceLabPatchConstants.SEAM_PAD_MAX, assetRate)
            let hardPad = VoiceLabGeometry.samples(VoiceLabPatchConstants.HARD_SEAM_PAD_MAX, assetRate)
            let caps: [Int64] = kinds.map { $0 == .hard ? hardPad : gapPad }
            let extra = split(remaining, caps: caps)
            pad = [pad[0] + extra[0], pad[1] + extra[1]]
            exact = extra[0] + extra[1] == remaining
        }
        let deltas: [Int64] = alloc.map { (frames: Int64) -> Int64 in shorten ? -frames : frames }
        var windowFrames = framesOf(n + borrow[0] + borrow[1], assetRate: assetRate, rate: rate)
        var output = pad[0] + t1 - t0 + deltas.reduce(0, +) + pad[1]
        if exact && output != windowFrames {
            // The rounding residual: a gap or edge pad, incoming first, while it stays non-negative; then the tail trim,
            // then the lead trim, each keeping the aligned words inside the trim and the trim inside the asset.
            let residual = windowFrames - output
            if kinds[0] != .hard && pad[0] + residual >= 0 {
                pad[0] += residual
            } else if kinds[1] != .hard && pad[1] + residual >= 0 {
                pad[1] += residual
            } else if spans[spans.count - 1].end <= t1 + residual && t1 + residual <= total {
                t1 += residual
            } else if 0 <= t0 - residual && t0 - residual <= spans[0].start {
                t0 -= residual
            } else if borrow[0] + borrow[1] < lend[0] + lend[1] {
                // Nothing can take a negative residual: the seams borrow the fewest more source samples whose widened
                // window holds the planned frames, within their limits and split again, and the residual, now zero or
                // more, pads the gap seam that borrowed, the incoming one first.
                let most = lend[0] + lend[1]
                var lent = borrow[0] + borrow[1]
                while lent < most && framesOf(n + lent, assetRate: assetRate, rate: rate) < output { lent += 1 }
                borrow = split(lent, caps: lend)
                windowFrames = framesOf(n + lent, assetRate: assetRate, rate: rate)
                guard windowFrames >= output else { throw VoiceLabGeometryError.fitTouchesVoice }
                pad[borrow[0] > 0 ? 0 : 1] += windowFrames - output
            } else {
                throw VoiceLabGeometryError.fitTouchesVoice
            }
            output = windowFrames
        }

        var edits: [VoiceLabFitEdit] = []
        var shifts = [Int64](repeating: 0, count: take.words.count)
        for (index, pause) in pauses.enumerated() where alloc[index] > 0 {
            let start = pause.start + (pause.length - alloc[index]) / 2
            edits.append(VoiceLabFitEdit(kind: shorten ? .remove : .insert, start: start, count: alloc[index]))
            for word in (pause.word + 1)..<take.words.count { shifts[word] += deltas[index] }
        }
        let startSample = window.startSample - borrow[0], endSample = window.endSample + borrow[1]
        let start = Double(startSample) / rate
        let end = Double(endSample) / rate
        let residualFrames: Int64 = output - windowFrames
        let residualFrameCount: Double = Double(residualFrames)
        let residualSeconds: Double = residualFrameCount / assetRate
        // Each word ends inside the output the recipe states (§10.5): the window, plus residualSeconds after a partial fit.
        let duration: Double = exact ? end - start : end - start + residualSeconds
        let lead = pad[0] - t0
        let words: [VoiceLabWord] = take.words.indices.map { (index: Int) -> VoiceLabWord in
            let word = take.words[index]
            let offsetFrames: Int64 = lead + shifts[index]
            let offsetFrameCount: Double = Double(offsetFrames)
            let offset: Double = offsetFrameCount / assetRate
            let wordStart: Double = min(word.start + offset, duration)
            let wordEnd: Double = min(word.end + offset, duration)
            return VoiceLabWord(text: word.text, start: wordStart, end: wordEnd, synthetic: true)
        }
        try validate(words: words, duration: duration, rate: rate)
        let incoming = VoiceLabFitSeam(padFrames: pad[0], borrowedSamples: borrow[0])
        let outgoing = VoiceLabFitSeam(padFrames: pad[1], borrowedSamples: borrow[1])
        let plan = VoiceLabFitPlan(edits: edits, incoming: incoming, outgoing: outgoing, trimStartFrame: t0, trimEndFrame: t1,
                                   windowStart: start, windowEnd: end, windowStartSample: startSample, windowEndSample: endSample,
                                   outputFrames: output, words: words)
        try checkVoice(plan, spans: spans, unvoiced: unvoiced, size: size, fade: fade)
        guard !exact else { return .exact(plan) }
        return .changedDuration(plan, naturalOut: Double(natural) / assetRate, residualSeconds: residualSeconds)
    }

    /// `jsRound(n × assetRate / sourceRate)`: asset frames for `n` source samples.
    private static func framesOf(_ samples: Int64, assetRate: Double, rate: Double) -> Int64 {
        let sampleCount: Double = Double(samples)
        let frameCount: Double = sampleCount * assetRate / rate
        let roundedFrames: Double = EditingPrimitives.jsRound(frameCount)
        return Int64(roundedFrames)
    }

    /// The input checks that come before the words, all `invalidInput`. Returns the source samples of each gap seam's
    /// outside silence, 0 for the other kinds.
    private static func validate(window: VoiceLabWindow, kinds: [VoiceLabSeamKind], silences: [Double?], take: VoiceLabFitTake,
                                 rate: Double) throws -> [Int64] {
        let limit = VoiceLabGeometry.sampleLimit, total = take.assetFrames
        guard rate.isFinite, sourceRates.contains(rate), take.assetSampleRate > 0, total > 0, total < frameLimit else {
            throw VoiceLabGeometryError.invalidInput()
        }
        let assetRate = Double(take.assetSampleRate)
        guard !kinds.contains(.synthToSynth), window.startSample >= 0, window.startSample < window.endSample,
              Double(window.endSample) < limit, window.leftSeam.sample == window.startSample,
              window.rightSeam.sample == window.endSample, kinds[0] != .none || window.startSample == 0,
              window.start.isFinite, window.end.isFinite else { throw VoiceLabGeometryError.invalidInput() }
        for (kind, silence) in zip(kinds, silences) {
            guard (kind == .hard) == (silence == nil) else { throw VoiceLabGeometryError.invalidInput() }
            if let silence, !(silence.isFinite && silence >= 0 && silence * rate < limit && silence * assetRate < limit) {
                throw VoiceLabGeometryError.invalidInput()
            }
        }
        let reach: [Int64] = zip(kinds, silences).map { kind, silence in
            kind == .gap ? VoiceLabGeometry.samples(silence ?? 0, rate) : 0
        }
        let widestEnd: Int64 = window.endSample + reach[1]
        let widestEndSample: Double = Double(widestEnd)
        let widestEndProduct: Double = widestEndSample * assetRate
        guard reach[0] <= window.startSample, widestEndProduct < limit else {
            throw VoiceLabGeometryError.invalidInput()
        }
        let levels = take.envelope.levels, size = VoiceLabGeometry.frameSize(assetRate)
        guard take.envelope.sampleRate == assetRate, Int64(levels.count) == total / size,
              levels.allSatisfy({ $0.isFinite && $0 >= 0 }) else { throw VoiceLabGeometryError.invalidInput() }
        // The trims are compared in seconds before either becomes frames, so a tail trim far below zero cannot overflow.
        guard take.trimStart.isFinite, take.trimEnd.isFinite, take.trimStart >= 0, take.trimStart < take.trimEnd,
              take.trimStart * assetRate < limit, take.trimEnd * assetRate < limit else { throw VoiceLabGeometryError.invalidInput() }
        let t0 = VoiceLabGeometry.samples(take.trimStart, assetRate), t1 = VoiceLabGeometry.samples(take.trimEnd, assetRate)
        guard 0 <= t0, t0 < t1, t1 <= total else { throw VoiceLabGeometryError.invalidInput() }
        return reach
    }

    /// The words' frame spans after the word checks: `alignmentUnavailable` without words, `alignmentMismatch` unless each
    /// word has a non-empty patch token, and `invalidWordTiming` for words out of order, empty or outside the trims. A word
    /// covers every paid-asset frame its aligned span touches.
    private static func wordSpans(take: VoiceLabFitTake, tokens: [String], t0: Int64, t1: Int64, rate: Double) throws -> [(start: Int64, end: Int64)] {
        guard !take.words.isEmpty else { throw VoiceLabGeometryError.alignmentUnavailable }
        guard tokens.count == take.words.count, !tokens.contains(""), !take.words.contains(where: { $0.text.isEmpty })
        else { throw VoiceLabGeometryError.alignmentMismatch }
        let assetRate = Double(take.assetSampleRate)
        var previous = 0.0
        for word in take.words {
            guard word.start.isFinite, word.end.isFinite, previous <= word.start, word.start < word.end,
                  (word.end - word.start) * rate >= 1,
                  word.end * assetRate < VoiceLabGeometry.sampleLimit else { throw VoiceLabGeometryError.invalidWordTiming }
            previous = word.end
        }
        let spans: [(start: Int64, end: Int64)] = take.words.map { (word: VoiceLabWord) -> (start: Int64, end: Int64) in
            let startFrame: Double = word.start * assetRate
            let endFrame: Double = word.end * assetRate
            let roundedStart: Double = startFrame.rounded(.down)
            let roundedEnd: Double = endFrame.rounded(.up)
            return (Int64(roundedStart), Int64(roundedEnd))
        }
        guard spans[0].start >= t0, spans[spans.count - 1].end <= t1 else { throw VoiceLabGeometryError.invalidWordTiming }
        return spans
    }

    private static func validate(words: [VoiceLabWord], duration: Double, rate: Double) throws {
        var previous = 0.0
        let out = VoiceLabGeometry.samples(duration, rate)
        for word in words {
            guard word.start >= previous, word.end > word.start, word.end <= duration,
                  VoiceLabGeometry.samples(word.end, rate) > VoiceLabGeometry.samples(word.start, rate),
                  VoiceLabGeometry.samples(word.end, rate) <= out else { throw VoiceLabGeometryError.invalidWordTiming }
            previous = word.end
        }
    }

    /// The editable run between each pair of words: the longest run of whole envelope frames, counted from the paid asset's
    /// first sample, between the two spans with every frame below `VOICED_FRAME`. Ties go to the earliest run.
    private static func findPauses(spans: [(start: Int64, end: Int64)], unvoiced: [Bool], size: Int64, tokens: [String]) -> [Pause] {
        var pauses: [Pause] = []
        for word in 0..<(spans.count - 1) {
            let nextWord: Int = word + 1
            let lowerBlock: Int64 = (spans[word].end + size - 1) / size
            let upperBlock: Int64 = spans[nextWord].start / size
            let blockCount: Int64 = Int64(unvoiced.count)
            let lo: Int64 = lowerBlock
            let hi: Int64 = min(upperBlock, blockCount)
            var best: Int64 = 0, first: Int64 = 0, run: Int64 = 0
            var block = lo
            while block < hi {
                let blockIndex: Int = Int(block)
                let nextRun: Int64 = run + 1
                run = unvoiced[blockIndex] ? nextRun : 0
                if run > best { best = run; first = block + 1 - run }
                block += 1
            }
            if best > 0 {
                let punctuation = tokens[word].unicodeScalars.last.map(isPunctuation) ?? false
                pauses.append(Pause(word: word, start: first * size, end: (first + best) * size, punctuation: punctuation))
            }
        }
        return pauses
    }

    /// General category P: Pc, Pd, Ps, Pe, Pi, Pf or Po.
    static func isPunctuation(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation, .initialPunctuation,
             .finalPunctuation, .otherPunctuation: true
        default: false
        }
    }

    /// How far each pause may change. Shortening stops at the pause's floor. Lengthening repeats frames of the run once, so
    /// the repeated frames and the join fit in it, and stops at `PAUSE_GROWTH_MAX`; a run no longer than `SEAM_FADE` has no
    /// room.
    private static func roomsOf(_ pauses: [Pause], shorten: Bool, assetRate: Double, fade: Int64) -> [Int64] {
        if shorten {
            let punctuation = VoiceLabGeometry.samples(VoiceLabPatchConstants.PAUSE_FLOOR_PUNCT, assetRate)
            let phrase = VoiceLabGeometry.samples(VoiceLabPatchConstants.PAUSE_FLOOR_PHRASE, assetRate)
            return pauses.map { (pause: Pause) -> Int64 in
                let floor: Int64 = pause.punctuation ? punctuation : phrase
                let room: Int64 = pause.length - floor
                return max(0, room)
            }
        }
        let growth = VoiceLabGeometry.samples(VoiceLabPatchConstants.PAUSE_GROWTH_MAX, assetRate)
        return pauses.map { (pause: Pause) -> Int64 in
            let room: Int64 = pause.length - fade
            return pause.length > fade ? min(growth, room) : 0
        }
    }

    /// Distribution steps 1 and 2: `amount` frames over the pauses in `group`, in proportion to their lengths. Every pause
    /// whose exact share would pass its room stops at the room, and the rest is spread again over the others. The last
    /// spread is split by the largest-remainder rule: each pause takes the floor of its share, and the frames left over go
    /// one each to the largest remainders, ties to the earlier pause. Returns what the group cannot hold. An amount that
    /// covers every room fills each pause to its room, as the spread would; below that, every product stays under 2^62.
    static func spread(_ amount: Int64, _ group: [Int], lengths: [Int64], rooms: [Int64], alloc: inout [Int64]) -> Int64 {
        var amount = amount
        var active = group.filter { rooms[$0] > 0 }
        let capacity: Int64 = active.reduce(0) { (sum: Int64, index: Int) -> Int64 in sum + rooms[index] }
        if amount >= capacity {
            for index in active { alloc[index] = rooms[index] }
            return amount - capacity
        }
        while amount > 0 && !active.isEmpty {
            let total: Int64 = active.reduce(0) { (sum: Int64, index: Int) -> Int64 in sum + lengths[index] }
            let full: [Int] = active.filter { (index: Int) -> Bool in
                let share: Int64 = amount * lengths[index]
                let limit: Int64 = rooms[index] * total
                return share > limit
            }
            if !full.isEmpty {
                for index in full { alloc[index] = rooms[index]; amount -= rooms[index] }
                active.removeAll { full.contains($0) }
                continue
            }
            var shares: [Int64] = active.map { (index: Int) -> Int64 in
                let numerator: Int64 = amount * lengths[index]
                return numerator / total
            }
            let remainders: [Int64] = active.map { (index: Int) -> Int64 in
                let numerator: Int64 = amount * lengths[index]
                return numerator % total
            }
            let assigned: Int64 = shares.reduce(0, +)
            let remainderCount: Int64 = amount - assigned
            let left: Int = Int(remainderCount)
            let order = active.indices.sorted { remainders[$0] != remainders[$1] ? remainders[$0] > remainders[$1] : $0 < $1 }
            for position in order.prefix(left) { shares[position] += 1 }
            for (position, index) in active.enumerated() { alloc[index] = shares[position] }
            amount = 0
        }
        return amount
    }

    /// Distribution step 3: half at each seam, the incoming seam taking the odd frame or sample. A seam at its limit passes
    /// the rest to the other seam.
    static func split(_ amount: Int64, caps: [Int64]) -> [Int64] {
        let first = min(amount - amount / 2, caps[0]), second = min(amount / 2, caps[1])
        let rest = amount - first - second, more = min(rest, caps[1] - second)
        return [first + min(rest - more, caps[0] - first), second + more]
    }

    /// The never-touch-voice invariant (§8.9.2 Edits): every edit and its join lie inside the trim, in order and apart, clear
    /// of every word span and of every envelope frame at or above `VOICED_FRAME`, so every other output sample is a copy of
    /// its paid frame; and the output length adds up.
    private static func checkVoice(_ plan: VoiceLabFitPlan, spans: [(start: Int64, end: Int64)], unvoiced: [Bool], size: Int64,
                                   fade: Int64) throws {
        guard plan.incoming.padFrames >= 0, plan.outgoing.padFrames >= 0 else { throw VoiceLabGeometryError.fitTouchesVoice }
        var cursor = plan.trimStartFrame
        var frames = plan.incoming.padFrames + plan.trimEndFrame - plan.trimStartFrame + plan.outgoing.padFrames
        for edit in plan.edits {
            let lo = edit.start - fade / 2, hi = edit.start + edit.count + fade - fade / 2
            guard edit.count > 0, cursor <= lo, hi <= plan.trimEndFrame,
                  !spans.contains(where: { $0.start < hi && lo < $0.end }) else { throw VoiceLabGeometryError.fitTouchesVoice }
            var block = lo / size
            while block * size < hi {
                guard block < Int64(unvoiced.count), unvoiced[Int(block)] else { throw VoiceLabGeometryError.fitTouchesVoice }
                block += 1
            }
            cursor = hi
            frames += edit.kind == .insert ? edit.count : -edit.count
        }
        guard frames == plan.outputFrames else { throw VoiceLabGeometryError.fitTouchesVoice }
    }
}
