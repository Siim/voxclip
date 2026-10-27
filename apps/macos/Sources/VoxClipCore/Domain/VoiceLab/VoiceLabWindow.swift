import Foundation

/// Patch-mode constants, voice-lab.md §8.3. Seconds unless the name says otherwise; the Windows Core uses the same names.
public enum VoiceLabPatchConstants {
    public static let SEAM_MIN_GAP = 0.12
    public static let SEAM_SEARCH_WORDS = 3
    public static let SEAM_FADE = 0.020
    public static let HARD_SEAM_FADE = 0.012
    public static let TTS_TRIM_LEAD = 0.03
    public static let TTS_TRIM_TAIL = 0.06
    public static let PAUSE_SLACK_KEEP = 0.15
    /// The silence-fit limits and the length aim (§8.9.1, §8.9.2).
    public static let SEAM_PAD_MAX = 0.3
    public static let HARD_SEAM_PAD_MAX = 0.060
    public static let PAUSE_FLOOR_PHRASE = 0.060
    public static let PAUSE_FLOOR_PUNCT = 0.150
    public static let PAUSE_GROWTH_MAX = 0.25
    public static let LENGTH_AIM_MIN = 0.92
    public static let LENGTH_AIM_MAX = 0.97
    /// dBFS of a 10 ms RMS frame.
    public static let VOICED_FRAME = -45.0
    /// 10^(VOICED_FRAME / 20) rounded to binary64, so no platform `pow` decides whether a frame is voiced.
    public static let VOICED_FRAME_LEVEL = 0.005623413251903491
    /// Seconds in one frame of the 10 ms RMS envelope: the frames `VOICED_FRAME` measures and seams are placed on.
    public static let RMS_FRAME = 0.010
    public static let ROOM_TONE_MIN_RUN = 0.5
}

/// Typed refusals from the patch geometry. Nothing here shortens a fade or substitutes a fallback.
public enum VoiceLabGeometryError: Error, Equatable, Sendable {
    /// The input is not valid. A `segmentId` names an enabled replacement whose own seam prepare refuses even without the
    /// window, so the scope does not render as it stands (§8.4 step 6).
    case invalidInput(segmentId: String? = nil)
    case unknownWord(String)
    case reversedWords
    case insertionUnsupported
    case windowCrossesWord(String)
    case seamFadeOutsideTake
    case seamFadeCrossesCut(incoming: Bool, needed: Int64, available: Int64)
    case windowTooShort(needed: Int64, available: Int64)
    /// The window would overlap the enabled replacement with this segment ID.
    case overlapsReplacement(String)
    /// The window would touch this enabled replacement, or leave it or itself without the kept source their fades need.
    case adjacentReplacement(String)
    case insufficientHandle(incoming: Bool, needed: Int64, available: Int64)
    case alignmentUnavailable
    case alignmentMismatch
    case invalidWordTiming
    case noVoicedAudio
    case roomToneUnavailable
    /// A fit plan would edit voiced audio or lose count of its frames. The planner checks every plan before it returns
    /// it (§8.9.2), so this is a planner fault, never a property of the take.
    case fitTouchesVoice
}

/// One window edge. `time` and `sample` agree under jsRound; `none` is a real take edge with no fade.
public struct VoiceLabSeamPlacement: Sendable, Equatable {
    public var kind: VoiceLabSeamKind
    public var time: Double
    public var sample: Int64
    public var fadeSamples: Int64
    public init(kind: VoiceLabSeamKind, time: Double, sample: Int64, fadeSamples: Int64) {
        self.kind = kind; self.time = time; self.sample = sample; self.fadeSamples = fadeSamples
    }
}

/// A replace window with its bridge words, in source seconds and on the source sample grid (§8.4).
public struct VoiceLabWindow: Sendable, Equatable {
    public var firstWordId: String
    public var lastWordId: String
    public var leftBridgeWordIds: [String]
    public var rightBridgeWordIds: [String]
    public var start: Double
    public var end: Double
    public var startSample: Int64
    public var endSample: Int64
    public var leftSeam: VoiceLabSeamPlacement
    public var rightSeam: VoiceLabSeamPlacement
    public init(firstWordId: String, lastWordId: String, leftBridgeWordIds: [String], rightBridgeWordIds: [String],
                start: Double, end: Double, startSample: Int64, endSample: Int64,
                leftSeam: VoiceLabSeamPlacement, rightSeam: VoiceLabSeamPlacement) {
        self.firstWordId = firstWordId; self.lastWordId = lastWordId
        self.leftBridgeWordIds = leftBridgeWordIds; self.rightBridgeWordIds = rightBridgeWordIds
        self.start = start; self.end = end; self.startSample = startSample; self.endSample = endSample
        self.leftSeam = leftSeam; self.rightSeam = rightSeam
    }
}

/// Source-grid arithmetic shared by the patch geometry. Every second-to-sample conversion is editing §4.1 jsRound.
enum VoiceLabGeometry {
    /// Sample counts below this stay exact in binary64.
    static let sampleLimit = Double(Int64(1) << 53)
    static func samples(_ seconds: Double, _ rate: Double) -> Int64 { Int64(EditingPrimitives.jsRound(seconds * rate)) }
    /// `AudioEnvelopeBuilder`'s 10 ms frame: frame `i` covers samples `[i·size, (i+1)·size)`.
    static func frameSize(_ rate: Double) -> Int64 { Int64(max(1, EditingPrimitives.jsRound(rate * VoiceLabPatchConstants.RMS_FRAME))) }
    /// Items follow the project transcript rule (`ProjectJSON.validate`): unique IDs, finite times, `0 <= start < end`
    /// and starts in transcript order. An envelope, when given, is on the source rate with finite, non-negative levels.
    static func check(rate: Double, totalSamples: Int64, envelope: AudioEnvelope?, items: [TimedWord]) throws {
        guard rate.isFinite, rate > 0, totalSamples > 0, Double(totalSamples) < sampleLimit,
              Set(items.map(\.id)).count == items.count else { throw VoiceLabGeometryError.invalidInput() }
        if let envelope {
            guard envelope.sampleRate == rate, !envelope.levels.isEmpty, envelope.levels.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
                throw VoiceLabGeometryError.invalidInput()
            }
        }
        var previous = 0.0
        for item in items {
            guard item.start.isFinite, item.end.isFinite, previous <= item.start, item.start < item.end, item.end * rate < sampleLimit else {
                throw VoiceLabGeometryError.invalidInput()
            }
            previous = item.start
        }
    }
    /// The parts of sorted, disjoint sample intervals that lie outside every range.
    static func subtract(_ intervals: [MediaInterval], _ ranges: [MediaInterval]) -> [MediaInterval] {
        intervals.flatMap { interval in
            ranges.reduce([interval]) { parts, range in
                parts.flatMap { part in
                    [MediaInterval(startSample: part.startSample, endSample: min(part.endSample, range.startSample)),
                     MediaInterval(startSample: max(part.startSample, range.endSample), endSample: part.endSample)]
                        .filter { $0.endSample > $0.startSample }
                }
            }
        }
    }
}

/// §8.4 join placement for a replace hunk `[a..b]`. Insertion stays reserved by §10.1.
public enum VoiceLabWindowPlanner {
    /// §8.4: a hard seam sits `min(0.03, gap / 2)` outside the replaced word.
    static let hardSeamReach = 0.03

    /// A synth piece of the output plan: an enabled replacement in the scope, with its selected recipe's seams, or the window
    /// being placed.
    private struct SynthPiece {
        var id: String
        var isWindow: Bool
        var start: Double
        var end: Double
        var range: MediaInterval
        var incoming: (kind: VoiceLabSeamKind, fade: Int64)
        var outgoing: (kind: VoiceLabSeamKind, fade: Int64)
    }

    /// The synth pieces of an output plan in source order and the kept source pieces around them, in samples (§10.5).
    private struct SeamLayout {
        var elements: [SynthPiece]
        var pieces: [MediaInterval]
        var total: Int64

        /// The kept pieces between element `index` - 1 (or the take start) and element `index` (or the take end).
        func run(_ index: Int) -> [MediaInterval] {
            let lo = index > 0 ? elements[index - 1].range.endSample : 0
            let hi = index < elements.count ? elements[index].range.startSample : total
            return pieces.filter { lo <= $0.startSample && $0.endSample <= hi }
        }
        /// The kept piece that ends at element `index`'s start, or starts at its end, in samples.
        func beside(_ index: Int, incoming: Bool) -> Int64 {
            let at = incoming ? elements[index].range.startSample : elements[index].range.endSample
            return pieces.first(where: { (incoming ? $0.endSample : $0.startSample) == at }).map { $0.endSample - $0.startSample } ?? 0
        }
        /// §8.4 for one seam of element `index`: kinds as prepare takes them (`none` with nothing beside it, synthToSynth only
        /// between touching pieces that agree), and a fade's outer half in the kept source right beside it.
        func sideHolds(_ index: Int, incoming: Bool) -> Bool {
            let element = elements[index], other = incoming ? index - 1 : index + 1
            let seam = incoming ? element.incoming : element.outgoing
            switch seam.kind {
            case .none:
                return run(incoming ? index : index + 1).isEmpty && !elements.indices.contains(other)
            case .synthToSynth:
                guard run(incoming ? index : index + 1).isEmpty, elements.indices.contains(other) else { return false }
                let facing = incoming ? elements[other].outgoing : elements[other].incoming
                let touching = incoming ? elements[other].range.endSample == element.range.startSample
                                        : element.range.endSample == elements[other].range.startSample
                return touching && facing.kind == .synthToSynth && facing.fade == seam.fade
            case .gap, .hard:
                return beside(index, incoming: incoming) >= (incoming ? seam.fade / 2 : seam.fade - seam.fade / 2)
            }
        }
        /// Prepare's `overlappingFades` rule between elements `index` and `index + 1`: the kept source between them holds the
        /// outer halves of both fades.
        func fadesFit(_ index: Int) -> Bool {
            let outFade = elements[index].outgoing.fade, inFade = elements[index + 1].incoming.fade
            return run(index + 1).reduce(0) { $0 + $1.endSample - $1.startSample } >= outFade - outFade / 2 + inFade / 2
        }
        /// The fades rule across one kept piece that fills the whole gap between elements `index` and `index + 1`.
        func pairHolds(_ index: Int) -> Bool {
            run(index + 1) != [MediaInterval(startSample: elements[index].range.endSample, endSample: elements[index + 1].range.startSample)]
                || fadesFit(index)
        }
        /// Prepare's own rule for one seam of element `index`, which allows a fade across a cut: the neighbouring output piece
        /// is source and holds the fade's outer half, and the fades on either side of the kept source between this element
        /// and the next one do not overlap.
        func prepareHolds(_ index: Int, incoming: Bool) -> Bool {
            let seam = incoming ? elements[index].incoming : elements[index].outgoing
            if seam.kind == .none || seam.kind == .synthToSynth { return sideHolds(index, incoming: incoming) }
            let between = run(incoming ? index : index + 1), other = incoming ? index - 1 : index + 1
            guard let piece = incoming ? between.last : between.first,
                  piece.endSample - piece.startSample >= (incoming ? seam.fade / 2 : seam.fade - seam.fade / 2) else { return false }
            return !elements.indices.contains(other) || fadesFit(min(index, other))
        }
    }

    /// The take a window is placed in, checked as `place` and `lendableSilence` both read it. It is
    /// `media.source.durationSeconds` long and ends on sample `jsRound(durationSeconds × rate)`.
    private struct Take {
        let transcript: Transcript
        let edits: ProjectEdits
        let duration: Double
        let rate: Double
        let total: Int64
        var words: [TimedWord] { transcript.words }

        init(_ project: Project) throws {
            guard let transcript = project.transcript else { throw VoiceLabGeometryError.invalidInput() }
            self.transcript = transcript
            edits = project.edits
            duration = project.media.source.durationSeconds
            rate = Double(project.media.source.audio?.sampleRate ?? 48_000)
            guard duration.isFinite, duration > 0, rate.isFinite, rate > 0, duration * rate < VoiceLabGeometry.sampleLimit,
                  edits.pauseThresholdSeconds.isFinite, edits.pauseThresholdSeconds > 0, edits.pauseKeepSeconds.isFinite,
                  (0...1).contains(edits.pauseKeepSeconds) else { throw VoiceLabGeometryError.invalidInput() }
            total = VoiceLabGeometry.samples(duration, rate)
        }
    }

    /// The render scope as `VoiceLabOutputPlanner.build` makes it (§8.4): the clip, the scope's enabled replacements, the
    /// editing segments, which items the scope keeps and which are already re-voiced, and its kept source. `place` and
    /// `lendableSilence` both read it.
    private struct ScopeSource {
        let take: Take
        let clipRange: TimeRange?
        let replacements: [SynthPiece]
        let segments: [EditSegment]
        let keptItem: [Bool]
        let replaced: [Bool]
        /// The outer half of each replacement's own fades, which a gap seam beside it must leave free.
        let reserved: [MediaInterval]

        init(_ project: Project, scope: VoiceLabOutputScope, take: Take) throws {
            self.take = take
            let words = take.words, edits = take.edits
            let pauses = try editing { try detectPauses(words, thresholdSeconds: edits.pauseThresholdSeconds) }
            let state = EditState(transcript: take.transcript, pauses: pauses, pauseThresholdSeconds: edits.pauseThresholdSeconds,
                                  pauseKeepSeconds: edits.pauseKeepSeconds, cutWordIds: Set(edits.cutWordIds),
                                  cutPauseIds: Set(edits.cutPauseIds), corrections: edits.corrections, clips: edits.clips)
            var activeClip: ClipRange?, clipRange: TimeRange?
            if case .clip(let id) = scope {
                guard let clip = edits.clips.first(where: { $0.id == id }), let indices = clipIndices(clip, words: words) else {
                    throw VoiceLabGeometryError.invalidInput()
                }
                activeClip = clip
                clipRange = try editing { try clipTimes(words, startIndex: indices.lowerBound, endIndex: indices.upperBound) }
            }
            self.clipRange = clipRange
            let replacements = try scopeReplacements(project, clipRange: clipRange, rate: take.rate, duration: take.duration)
            self.replacements = replacements
            let segments = try editing { try buildSegments(state, activeClip: activeClip) }
            self.segments = segments
            let cutIds = Set(segments.filter { $0.kind == .word && $0.cut }.map(\.id))
            keptItem = words.map { !cutIds.contains($0.id) }
            // An item inside an enabled replacement is already re-voiced: it never bridges, and a take edge never absorbs it.
            replaced = words.map { word in replacements.contains { $0.start <= word.start && word.end <= $0.end } }
            let incomingHandles: [MediaInterval] = replacements.map { (replacement: SynthPiece) -> MediaInterval in
                let halfFade: Int64 = replacement.incoming.fade / 2
                let start: Int64 = replacement.range.startSample - halfFade
                return MediaInterval(startSample: start, endSample: replacement.range.startSample)
            }
            let outgoingHandles: [MediaInterval] = replacements.map { (replacement: SynthPiece) -> MediaInterval in
                let halfFade: Int64 = replacement.outgoing.fade / 2
                let end: Int64 = replacement.range.endSample + replacement.outgoing.fade - halfFade
                return MediaInterval(startSample: replacement.range.endSample, endSample: end)
            }
            reserved = incomingHandles + outgoingHandles
        }

        /// Kept source pieces as the output plan builds them: the words and pauses inside every replacement and inside the
        /// `passage`, when given, are dropped, and neither the cuts nor the synth ranges (with `window`) are source.
        func keptSource(_ passage: (start: Double, end: Double)?, window: [MediaInterval] = []) throws -> [MediaInterval] {
            let dropped = replacements.map { ($0.start, $0.end) } + (passage.map { [($0.start, $0.end)] } ?? [])
            let remaining = segments.filter { segment in
                !(segment.kind == .word || segment.kind == .pause) || !dropped.contains { segment.start >= $0.0 && segment.end <= $0.1 }
            }
            let keep = take.edits.pauseKeepSeconds
            let kept = try editing { try buildEditPlan(remaining, duration: take.duration, sampleRate: take.rate, pauseKeepSeconds: keep).kept }
            return VoiceLabGeometry.subtract(kept, replacements.map(\.range) + window)
        }
    }

    /// Editing failures in the take become `invalidInput`.
    private static func editing<T>(_ body: () throws -> T) throws -> T {
        do { return try body() } catch { throw VoiceLabGeometryError.invalidInput() }
    }

    /// The enabled replacements `VoiceLabOutputPlanner.build` renders in this scope, by start. One that crosses the clip's
    /// range, has no synth samples, has no selected recipe or overlaps another leaves the scope unrenderable.
    private static func scopeReplacements(_ project: Project, clipRange: TimeRange?, rate: Double, duration: Double) throws -> [SynthPiece] {
        var selected: [SynthPiece] = []
        for segment in project.voiceLab.segments where segment.enabled {
            let start = segment.replace.start, end = segment.replace.end
            guard start.isFinite, end.isFinite, start >= 0, start < end, end <= duration else { throw VoiceLabGeometryError.invalidInput() }
            if let clipRange, end <= clipRange.start || start >= clipRange.end { continue }
            let range = MediaInterval(startSample: VoiceLabGeometry.samples(start, rate), endSample: VoiceLabGeometry.samples(end, rate))
            guard clipRange.map({ start >= $0.start && end <= $0.end }) ?? true, range.endSample > range.startSample,
                  segment.candidates.indices.contains(segment.selectedCandidateIndex),
                  let seams = segment.candidates[segment.selectedCandidateIndex].recipe?.seams,
                  [seams.in.fadeSamples, seams.out.fadeSamples].allSatisfy({ $0 >= 0 && Double($0) < VoiceLabGeometry.sampleLimit })
            else { throw VoiceLabGeometryError.invalidInput() }
            selected.append(SynthPiece(id: segment.id, isWindow: false, start: start, end: end, range: range,
                                       incoming: (seams.in.kind, seams.in.fadeSamples), outgoing: (seams.out.kind, seams.out.fadeSamples)))
        }
        selected.sort { $0.start < $1.start }
        guard zip(selected, selected.dropFirst()).allSatisfy({ $1.range.startSample >= $0.range.endSample }) else {
            throw VoiceLabGeometryError.invalidInput()
        }
        return selected
    }

    public static func place(project: Project, scope: VoiceLabOutputScope, envelope: AudioEnvelope,
                             afterWordId: String) throws -> VoiceLabWindow {
        throw VoiceLabGeometryError.insertionUnsupported
    }

    /// Places the window for the render `scope`, exactly as `VoiceLabOutputPlanner.build` receives it, beside the scope's
    /// enabled replacements. The take is `media.source.durationSeconds` long and ends on sample `jsRound(durationSeconds ×
    /// rate)`. Kept source comes from the editing plan the output planner builds, with the words and pauses inside every
    /// replacement and the window dropped and the synth ranges removed. A seam in a gap sits at the centre of its quietest
    /// whole 10 ms frame whose fade lies in kept source clear of a replacement's own fades (ties: nearest the gap centre,
    /// then earlier), and every seam with a fade keeps its outer half in the kept source beside it (§10.5).
    public static func place(project: Project, scope: VoiceLabOutputScope, envelope: AudioEnvelope, firstWordId: String,
                             lastWordId: String) throws -> VoiceLabWindow {
        let take = try Take(project)
        let words = take.words, duration = take.duration, rate = take.rate, total = take.total
        try VoiceLabGeometry.check(rate: rate, totalSamples: total, envelope: envelope, items: words)
        guard let a = words.firstIndex(where: { $0.id == firstWordId }) else { throw VoiceLabGeometryError.unknownWord(firstWordId) }
        guard let b = words.firstIndex(where: { $0.id == lastWordId }) else { throw VoiceLabGeometryError.unknownWord(lastWordId) }
        guard a <= b else { throw VoiceLabGeometryError.reversedWords }

        // The clip, replacements, segments and kept source VoiceLabOutputPlanner builds for this scope.
        let source = try ScopeSource(project, scope: scope, take: take)
        let clipRange = source.clipRange, replacements = source.replacements, reserved = source.reserved
        let keptItem = source.keptItem, replaced = source.replaced
        let blocking = zip(keptItem, replaced).map { $0 || $1 }
        func keptSource(_ passage: (start: Double, end: Double)?, window: [MediaInterval] = []) throws -> [MediaInterval] {
            try source.keptSource(passage, window: window)
        }
        /// Where the silence before item `index` begins: the latest end of the items before it.
        func beforeEnd(_ index: Int) -> Double { words[..<index].map(\.end).max() ?? 0 }
        /// Where the silence before item `index` ends: the earliest start of the items from it on.
        func afterStart(_ index: Int) -> Double { words[index...].map(\.start).min() ?? duration }

        let size = VoiceLabGeometry.frameSize(rate)
        let minGap = VoiceLabGeometry.samples(VoiceLabPatchConstants.SEAM_MIN_GAP, rate)
        let gapFade = VoiceLabGeometry.samples(VoiceLabPatchConstants.SEAM_FADE, rate)
        let hardFade = VoiceLabGeometry.samples(VoiceLabPatchConstants.HARD_SEAM_FADE, rate)
        func bridgeable(_ index: Int) -> Bool {
            words.indices.contains(index) && words[index].kind == .word && keptItem[index] && !replaced[index]
        }
        func quietest(_ g0: Int64, _ g1: Int64, kept: [MediaInterval]) -> Int64? {
            let first = (g0 + size - 1) / size, last = min(g1 / size - 1, Int64(envelope.levels.count) - 1)
            guard first <= last else { return nil }
            var best: (level: Double, distance: Int64, seam: Int64)?
            for index in first...last {
                let seam = index * size + (size + 1) / 2
                // The whole centred fade lies in kept source, which also keeps it inside the take; §10.5 never shortens it.
                guard kept.contains(where: { $0.startSample <= seam - gapFade / 2 && seam + gapFade - gapFade / 2 <= $0.endSample }) else {
                    continue
                }
                let level = Double(envelope.levels[Int(index)]), distance = abs(2 * index * size + size - g0 - g1)
                if best.map({ level < $0.level || level == $0.level && distance < $0.distance }) ?? true { best = (level, distance, seam) }
            }
            return best?.seam
        }
        func gapSeam(_ seam: Int64) -> VoiceLabSeamPlacement {
            VoiceLabSeamPlacement(kind: .gap, time: Double(seam) / rate, sample: seam, fadeSamples: gapFade)
        }
        func edgeSeam(_ sample: Int64, _ time: Double) -> VoiceLabSeamPlacement {
            VoiceLabSeamPlacement(kind: .none, time: time, sample: sample, fadeSamples: 0)
        }
        func hardSeam(_ time: Double) -> VoiceLabSeamPlacement {
            VoiceLabSeamPlacement(kind: .hard, time: time, sample: VoiceLabGeometry.samples(time, rate), fadeSamples: hardFade)
        }

        // Take edges count kept and replaced items only: earlier or later cut items are absorbed into the window. In a clip
        // scope the window can reach a take edge only when the clip's kept range does.
        let touchesStart = clipRange.map { $0.start <= 0 } ?? true, touchesEnd = clipRange.map { $0.end >= duration } ?? true
        var aMin = a, bMax = b
        while a - aMin < VoiceLabPatchConstants.SEAM_SEARCH_WORDS && bridgeable(aMin - 1) { aMin -= 1 }
        while bMax - b < VoiceLabPatchConstants.SEAM_SEARCH_WORDS && bridgeable(bMax + 1) { bMax += 1 }
        // Each search measures kept source against the widest window the other side could reach, because a cut's reach
        // depends on which items the window drops. The exact window is checked after placement.
        let widestEnd = touchesEnd && !blocking[(bMax + 1)...].contains(true) ? duration : afterStart(bMax + 1)
        let widestStart = touchesStart && !blocking[..<aMin].contains(true) ? 0 : beforeEnd(aMin)

        var left: VoiceLabSeamPlacement?, first = a
        for bridge in 0...VoiceLabPatchConstants.SEAM_SEARCH_WORDS {
            let k = a - bridge
            if bridge > 0 && !bridgeable(k) { break }
            let g0 = VoiceLabGeometry.samples(beforeEnd(k), rate), g1 = VoiceLabGeometry.samples(afterStart(k), rate)
            guard g1 - g0 >= minGap else { continue }
            let kept = VoiceLabGeometry.subtract(try keptSource((afterStart(k), widestEnd)), reserved)
            guard let seam = quietest(g0, g1, kept: kept) else { continue }
            left = gapSeam(seam); first = k
            break
        }
        // A replacement that ends in the silence before the passage keeps its own fade's outer half and this seam's: the
        // silence is measured from where both fit. Overlapping items leave no silence: the reach is clamped at zero, as
        // editing §7.3 clamps a cut's reach.
        let passageStart = afterStart(a)
        let silenceStart = replacements.filter { $0.end <= passageStart }.reduce(beforeEnd(a)) {
            max($0, Double($1.range.endSample + $1.outgoing.fade - $1.outgoing.fade / 2 + hardFade / 2) / rate)
        }
        var leftSeam = left ?? hardSeam(passageStart - min(hardSeamReach, max(0, passageStart - silenceStart) / 2))
        if touchesStart && !blocking[..<first].contains(true) { leftSeam = edgeSeam(0, 0) }

        var right: VoiceLabSeamPlacement?, last = b
        for bridge in 0...VoiceLabPatchConstants.SEAM_SEARCH_WORDS {
            let k = b + bridge
            if bridge > 0 && !bridgeable(k) { break }
            let g0 = VoiceLabGeometry.samples(beforeEnd(k + 1), rate), g1 = VoiceLabGeometry.samples(afterStart(k + 1), rate)
            guard g1 - g0 >= minGap else { continue }
            let kept = VoiceLabGeometry.subtract(try keptSource((widestStart, beforeEnd(k + 1))), reserved)
            guard let seam = quietest(g0, g1, kept: kept) else { continue }
            right = gapSeam(seam); last = k
            break
        }
        let passageEnd = beforeEnd(b + 1)
        let silenceEnd = replacements.filter { $0.start >= passageEnd }.reduce(afterStart(b + 1)) {
            min($0, Double($1.range.startSample - $1.incoming.fade / 2 - (hardFade - hardFade / 2)) / rate)
        }
        var rightSeam = right ?? hardSeam(passageEnd + min(hardSeamReach, max(0, silenceEnd - passageEnd) / 2))
        if touchesEnd && !blocking[(last + 1)...].contains(true) { rightSeam = edgeSeam(total, duration) }

        let start = leftSeam.time, end = rightSeam.time
        guard rightSeam.sample > leftSeam.sample else { throw VoiceLabGeometryError.invalidInput() }
        if let overlapped = replacements.first(where: { $0.start < end && start < $0.end }) {
            throw VoiceLabGeometryError.overlapsReplacement(overlapped.id)
        }
        if let crossing = words.first(where: { $0.start < start && start < $0.end || $0.start < end && end < $0.end }) {
            throw VoiceLabGeometryError.windowCrossesWord(crossing.id)
        }
        // The window holds the passage and its bridges. It absorbs cut items, events and unlabeled speech, but a kept word
        // that is neither a passage nor a bridge word would lose its speech.
        let inside = words.indices.filter { words[$0].start >= start && words[$0].end <= end }
        if let uncovered = (first...last).first(where: { !inside.contains($0) }) {
            throw VoiceLabGeometryError.windowCrossesWord(words[uncovered].id)
        }
        if let lost = inside.first(where: { !(first...last).contains($0) && words[$0].kind == .word && keptItem[$0] }) {
            throw VoiceLabGeometryError.windowCrossesWord(words[lost].id)
        }
        // A hard fade crossing a take edge has a kept item between the passage and that edge.
        if leftSeam.kind == .hard && leftSeam.sample - hardFade / 2 < 0 || rightSeam.kind == .hard && rightSeam.sample + hardFade - hardFade / 2 > total {
            throw VoiceLabGeometryError.seamFadeOutsideTake
        }

        // §10.5 on the pieces the output plan builds with the window as one more replacement: a seam with a fade needs the
        // fade's outer half in the kept source right beside it, and two replacements beside one kept piece need room for both
        // outer halves. Seam kinds follow prepare: `none` only with nothing beside it, synthToSynth only between two touching
        // replacements, which `place` never makes.
        let windowRange = MediaInterval(startSample: leftSeam.sample, endSample: rightSeam.sample)
        let window = SynthPiece(id: "", isWindow: true, start: start, end: end, range: windowRange,
                                incoming: (leftSeam.kind, leftSeam.fadeSamples), outgoing: (rightSeam.kind, rightSeam.fadeSamples))
        let layout = SeamLayout(elements: (replacements + [window]).sorted { $0.range.startSample < $1.range.startSample },
                                pieces: try keptSource((start, end), window: [windowRange]), total: total)
        // The scope as it renders without the window. A replacement's check that already fails there is not the window's doing.
        let alone = SeamLayout(elements: replacements, pieces: try keptSource(nil), total: total)
        let elements = layout.elements, w = elements.firstIndex(where: \.isWindow)!
        /// Throws unless replacement `index`'s seam on that side still renders beside the window. A check that holds without
        /// the window and fails with it is the window's doing. A check that already fails is judged by prepare's own rule, and
        /// when that fails without the window too, the scope was unrenderable before the window.
        func judge(_ index: Int, incoming: Bool) throws {
            let id = elements[index].id, before = index > w ? index - 1 : index
            if layout.sideHolds(index, incoming: incoming) { return }
            if alone.sideHolds(before, incoming: incoming) { throw VoiceLabGeometryError.adjacentReplacement(id) }
            if layout.prepareHolds(index, incoming: incoming) { return }
            throw alone.prepareHolds(before, incoming: incoming) ? VoiceLabGeometryError.adjacentReplacement(id) : .invalidInput(segmentId: id)
        }
        if w > 0 {
            guard !layout.run(w).isEmpty else { throw VoiceLabGeometryError.adjacentReplacement(elements[w - 1].id) }
            try judge(w - 1, incoming: false)
            guard layout.pairHolds(w - 1) else { throw VoiceLabGeometryError.adjacentReplacement(elements[w - 1].id) }
        }
        if leftSeam.kind != .none {
            let needed = leftSeam.fadeSamples / 2, available = layout.beside(w, incoming: true)
            if available < needed { throw VoiceLabGeometryError.seamFadeCrossesCut(incoming: true, needed: needed, available: available) }
        }
        if w + 1 < elements.count {
            guard !layout.run(w + 1).isEmpty else { throw VoiceLabGeometryError.adjacentReplacement(elements[w + 1].id) }
            try judge(w + 1, incoming: true)
            guard layout.pairHolds(w) else { throw VoiceLabGeometryError.adjacentReplacement(elements[w + 1].id) }
        }
        if rightSeam.kind != .none {
            let needed = rightSeam.fadeSamples - rightSeam.fadeSamples / 2, available = layout.beside(w, incoming: false)
            if available < needed { throw VoiceLabGeometryError.seamFadeCrossesCut(incoming: false, needed: needed, available: available) }
        }
        // The validator's overlappingFades condition: the inner halves of both fades must fit inside the window.
        let inner = leftSeam.fadeSamples - leftSeam.fadeSamples / 2 + rightSeam.fadeSamples / 2
        if inner > rightSeam.sample - leftSeam.sample {
            throw VoiceLabGeometryError.windowTooShort(needed: inner, available: rightSeam.sample - leftSeam.sample)
        }
        // Dropping the window's items can lengthen a cut's reach past a replacement further away. Across one kept piece the
        // pair rule is prepare's own, so a pair that already breaks it leaves the scope unrenderable.
        for index in elements.indices where index != w {
            try judge(index, incoming: true)
            try judge(index, incoming: false)
            if index + 1 != w && index + 1 < elements.count && !layout.pairHolds(index) {
                let id = elements[index].id
                throw alone.pairHolds(index > w ? index - 1 : index) ? VoiceLabGeometryError.adjacentReplacement(id) : .invalidInput(segmentId: id)
            }
        }
        return VoiceLabWindow(firstWordId: words[inside[0]].id, lastWordId: words[inside[inside.count - 1]].id,
                              leftBridgeWordIds: words[first..<a].map(\.id), rightBridgeWordIds: words[(b + 1)..<(last + 1)].map(\.id),
                              start: start, end: end, startSample: leftSeam.sample, endSample: rightSeam.sample,
                              leftSeam: leftSeam, rightSeam: rightSeam)
    }
}

extension VoiceLabWindowPlanner {
    /// The §8.9.2 lendable silence of each gap seam of `window`, a window `place` returned for this `scope`, in seconds
    /// (source samples over the source rate). It is the kept source contiguous with the seam on its outer side, measured
    /// as §8.4 step 5 measures it for the final window, with every replacement's outer fade halves taken out, up to the
    /// nearest kept item outside the window. So it stops at that item, a cut item's reach, a cut pause, a clip edge or
    /// another replacement's outer fade half. A take-edge seam returns the silence to the nearest word inside the window,
    /// in transcript seconds, and a hard seam returns nil. Pass both results directly to `VoiceLabFitPlanner.plan`;
    /// only a gap seam can borrow, at most this less `PAUSE_SLACK_KEEP`.
    public static func lendableSilence(project: Project, scope: VoiceLabOutputScope,
                                       window: VoiceLabWindow) throws -> (incoming: Double?, outgoing: Double?) {
        let take = try Take(project)
        try VoiceLabGeometry.check(rate: take.rate, totalSamples: take.total, envelope: nil, items: take.words)
        guard 0 <= window.startSample, window.startSample < window.endSample, window.endSample <= take.total,
              window.leftSeam.sample == window.startSample, window.rightSeam.sample == window.endSample else {
            throw VoiceLabGeometryError.invalidInput()
        }
        let source = try ScopeSource(project, scope: scope, take: take)
        let range = MediaInterval(startSample: window.startSample, endSample: window.endSample)
        let kept = VoiceLabGeometry.subtract(try source.keptSource((window.start, window.end), window: [range]), source.reserved)
        var before: [Int64] = [], after: [Int64] = []
        for (word, isKept) in zip(take.words, source.keptItem) where isKept {
            if word.end <= window.start { before.append(VoiceLabGeometry.samples(word.end, take.rate)) }
            if word.start >= window.end { after.append(VoiceLabGeometry.samples(word.start, take.rate)) }
        }
        func lend(_ seam: VoiceLabSeamPlacement, incoming: Bool) -> Double? {
            if seam.kind == .none {
                let words = take.words.filter { $0.kind == .word && $0.start >= window.start && $0.end <= window.end }
                if incoming { return max(0, (words.map(\.start).min() ?? window.start) - window.start) }
                return max(0, window.end - (words.map(\.end).max() ?? window.end))
            }
            guard seam.kind == .gap else { return nil }
            guard let piece = kept.first(where: { (incoming ? $0.endSample : $0.startSample) == seam.sample }) else { return 0 }
            let stop = incoming ? max(piece.startSample, before.max() ?? piece.startSample)
                                : min(piece.endSample, after.min() ?? piece.endSample)
            let distance: Int64 = incoming ? seam.sample - stop : stop - seam.sample
            let samples: Int64 = max(0, distance)
            let sampleCount: Double = Double(samples)
            return sampleCount / take.rate
        }
        return (lend(window.leftSeam, incoming: true), lend(window.rightSeam, incoming: false))
    }
}

/// §10.5 seam handles with exactly the render validator's arithmetic.
public enum VoiceLabHandles {
    /// An incoming seam needs `floor(N/2)` output samples of asset before its trim, an outgoing one `ceil(N/2)` after;
    /// the source keeps the other half inside the window.
    public static func minimum(fadeSamples: Int64, incoming: Bool, assetSampleRate: Int, sourceSampleRate: Double,
                               stretch: Double) throws -> (assetFrames: Int64, sourceSamples: Int64) {
        guard fadeSamples >= 0, Double(fadeSamples) < VoiceLabGeometry.sampleLimit, assetSampleRate > 0,
              sourceSampleRate.isFinite, sourceSampleRate > 0, stretch.isFinite, stretch > 0 else { throw VoiceLabGeometryError.invalidInput() }
        let needed = incoming ? fadeSamples / 2 : fadeSamples - fadeSamples / 2
        let rawFrames = Double(needed) * Double(assetSampleRate) / (sourceSampleRate * stretch)
        guard rawFrames.isFinite, rawFrames < VoiceLabGeometry.sampleLimit else { throw VoiceLabGeometryError.invalidInput() }
        let nearest = rawFrames.rounded()
        // Persisted stretch ratios can put an integral frame one ULP above its exact value.
        return (Int64(abs(rawFrames - nearest) <= 4 * rawFrames.ulp ? nearest : ceil(rawFrames)), fadeSamples - needed)
    }

    /// The recipe seam with minimum handles. A take edge has none; a synth-to-synth seam has no source handle.
    public static func seam(kind: VoiceLabSeamKind, fadeSamples: Int64, incoming: Bool, assetSampleRate: Int,
                            sourceSampleRate: Double, stretch: Double) throws -> VoiceLabSeam {
        guard kind != .none else { return VoiceLabSeam(kind: .none, fadeSamples: 0, sourceHandleSamples: 0, assetHandleFrames: 0) }
        let handle = try minimum(fadeSamples: fadeSamples, incoming: incoming, assetSampleRate: assetSampleRate,
                                 sourceSampleRate: sourceSampleRate, stretch: stretch)
        return VoiceLabSeam(kind: kind, fadeSamples: fadeSamples, sourceHandleSamples: kind == .synthToSynth ? 0 : handle.sourceSamples,
                            assetHandleFrames: handle.assetFrames)
    }

    /// Requires the asset frames before `trimStart` and after `trimEnd` that the seams declare, on the asset grid.
    public static func checkTrim(seams: VoiceLabSeams, trimStart: Double, trimEnd: Double, assetDurationSeconds: Double,
                                 assetSampleRate: Int) throws {
        guard trimStart.isFinite, trimEnd.isFinite, assetDurationSeconds.isFinite, trimStart >= 0, trimStart < trimEnd,
              trimEnd <= assetDurationSeconds, assetSampleRate > 0,
              assetDurationSeconds * Double(assetSampleRate) < VoiceLabGeometry.sampleLimit else { throw VoiceLabGeometryError.invalidInput() }
        let rate = Double(assetSampleRate)
        let before = VoiceLabGeometry.samples(trimStart, rate), after = VoiceLabGeometry.samples(assetDurationSeconds - trimEnd, rate)
        if seams.in.assetHandleFrames > before {
            throw VoiceLabGeometryError.insufficientHandle(incoming: true, needed: seams.in.assetHandleFrames, available: before)
        }
        if seams.out.assetHandleFrames > after {
            throw VoiceLabGeometryError.insufficientHandle(incoming: false, needed: seams.out.assetHandleFrames, available: after)
        }
    }
}
