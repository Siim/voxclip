import Foundation

/// Cut edges seated in the quiet (editing §5.10). When one word is cut out of fluent speech, the edge between it and its
/// kept neighbour moves to the nearest quiet point and is stored in `edits.cutEdges`; word times never change.
///
/// Pure. Words are one recording's, in that recording's local seconds, with clock ids. Numbers follow editing §2.6:
/// binary64 in the written order, Float32 levels read as doubles, frame choices in integers. The generator twin is
/// tools/fixtures/editing/lib/cutedges.mjs and Windows has `CutEdges` in VoxClip.Core.
public enum CutEdges {
    /// How far an edge may move from the word edge, in seconds.
    public static let reach = 0.15
    /// At this gap or more the 0.1 s pad already lands in the gap, so the boundary keeps no key.
    public static let maxGap = 0.2
    /// A quiet point is a run of at least this many 10 ms frames.
    public static let minimumRun = 2

    /// What keeps a boundary at today's padding (§3.2): Voice Lab replace ranges in this recording's local seconds, and the
    /// word ranges of paid scopes (a clip with a whole-clip revoice or lip sync, a Rewrite with takes) by clock id. A key
    /// counts in a scope's inputs when word i−1 or word i lies in it, so a boundary touching a paid scope is frozen unless
    /// the commit itself changes a word of it inside the scope.
    public struct Freeze: Sendable, Equatable {
        public var voiceRanges: [TimeRange]
        public var paidScopes: [ClipWordRange]

        public init(voiceRanges: [TimeRange] = [], paidScopes: [ClipWordRange] = []) {
            self.voiceRanges = voiceRanges
            self.paidScopes = paidScopes
        }
    }

    /// New keys, and the boundaries that would have moved but sit beside a voice patch or a paid scope.
    public struct Seating: Sendable, Equatable {
        public var edges: [String: Double] = [:]
        public var frozen = 0
    }

    /// One recording's words in its local seconds, with clock ids, and the key its envelope is cached under.
    public struct Recording: Sendable, Equatable {
        public let key: String
        public let words: [TimedWord]
    }

    /// The inline offer (§6): N boundaries without a key that would move, K kept beside voice patches, and the
    /// recordings with a qualifying boundary whose envelope is not loaded.
    public struct Offer: Sendable, Equatable {
        public var count = 0
        public var frozen = 0
        public var unloaded: [String] = []
    }

    /// §3.1's qualifying boundary between `a` = words[i−1] and `b` = words[i], apart from "no key yet": both are speech,
    /// exactly one is cut, and the gap is at least 0 and under 0.2 s.
    public static func qualifies(_ a: TimedWord, _ b: TimedWord, cutWordIds: Set<String>) -> Bool {
        guard isSpeech(a), isSpeech(b), cutWordIds.contains(a.id) != cutWordIds.contains(b.id) else { return false }
        let gap = b.start - a.end
        return gap >= 0 && gap < maxGap
    }

    /// §3.1 over one recording: a key for each qualifying boundary without one (only those named by `only` when given).
    /// `changedWords` are the words whose kept/cut state the commit changed (§3.3); with none, as for Fix cut edges, the
    /// offer and a selected cut's actions, no boundary touching a paid scope gets a key.
    public static func seat(words: [TimedWord], cutWordIds: Set<String>, envelope: AudioEnvelope, sampleRate: Double,
                            freeze: Freeze = Freeze(), existing: [String: Double] = [:], only: Set<String>? = nil,
                            changedWords: Set<String> = []) -> Seating {
        var result = Seating()
        guard words.count > 1, sampleRate.isFinite, sampleRate > 0, let analysis = LevelAnalysis(words: words, envelope: envelope) else { return result }
        let positions = Dictionary(words.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        for index in words.indices.dropFirst() {
            let a = words[index - 1], b = words[index]
            guard qualifies(a, b, cutWordIds: cutWordIds), existing[b.id] == nil, only?.contains(b.id) ?? true,
                  let point = quietPoint(a, b, analysis: analysis, sampleRate: sampleRate) else { continue }
            if frozen(a, b, cutWordIds: cutWordIds, window: point.window, freeze: freeze, positions: positions, changedWords: changedWords) {
                result.frozen += 1
            } else {
                result.edges[b.id] = point.value
            }
        }
        return result
    }

    /// §3.4 for one recording: the keys still at a qualifying kept/cut boundary.
    public static func normalized(_ edges: [String: Double], words: [TimedWord], cutWordIds: Set<String>) -> [String: Double] {
        var result: [String: Double] = [:]
        for index in words.indices.dropFirst() {
            if let edge = edges[words[index].id], qualifies(words[index - 1], words[index], cutWordIds: cutWordIds) {
                result[words[index].id] = edge
            }
        }
        return result
    }

    /// Each recording's words in local seconds with clock ids, in clock order.
    public static func recordings(_ project: Project) -> [Recording] {
        guard let transcript = project.transcript else { return [] }
        var result = [Recording(key: project.media.source.contentKey, words: transcript.words)]
        for source in project.media.spokenSources ?? [] {
            result.append(Recording(key: source.sourceKey, words: source.transcript.words.map { word in
                var word = word
                word.id = source.wordIdPrefix + word.id
                return word
            }))
        }
        return result
    }

    /// §3.4 on every commit: drops keys no longer at a qualifying kept/cut boundary, so a cut followed by a restore
    /// leaves the edits as they were, and writes the version the fields now need (editing §10.1).
    public static func normalize(_ project: Project) throws -> Project {
        var result = project
        if !project.edits.cutEdges.isEmpty {
            let cut = Set(project.edits.cutWordIds)
            var kept: [String: Double] = [:]
            for recording in recordings(project) {
                kept.merge(normalized(project.edits.cutEdges, words: recording.words, cutWordIds: cut)) { first, _ in first }
            }
            result.edits.cutEdges = kept
        }
        return try ProjectMigrations.framed(result)
    }

    /// §3.3: seats the boundaries whose kept/cut state changed from `before` to `after`, in the same step, then
    /// normalizes. A recording without a loaded envelope gets no key, so today's padding applies there.
    public static func finalize(before: Project, after: Project, envelopes: [String: AudioEnvelope],
                                freeze: [String: Freeze] = [:]) throws -> Project {
        var result = after
        let was = Set(before.edits.cutWordIds), cut = Set(after.edits.cutWordIds), rate = clockRate(after)
        for recording in recordings(after) {
            guard let envelope = envelopes[recording.key] else { continue }
            let changed = changedBoundaries(recording.words, before: was, after: cut)
            guard !changed.isEmpty else { continue }
            let seated = seat(words: recording.words, cutWordIds: cut, envelope: envelope, sampleRate: rate,
                              freeze: freeze[recording.key] ?? Freeze(), existing: result.edits.cutEdges, only: changed,
                              changedWords: was.symmetricDifference(cut))
            result.edits.cutEdges.merge(seated.edges) { _, new in new }
        }
        return try normalize(result)
    }

    /// §6: what "Fix cut edges" would do now, over every qualifying boundary without a key.
    public static func offer(_ project: Project, envelopes: [String: AudioEnvelope], freeze: [String: Freeze] = [:]) -> Offer {
        fixing(project, envelopes: envelopes, freeze: freeze).offer
    }

    /// §3.2 for the boundary between `words[index − 1]` and `words[index]` of one recording, read without levels: whether
    /// a key there would move the inputs of the paid work beside it. The editors check it before a per-cut action pins a
    /// key or moves one back; nothing is being cut then, so a boundary touching a paid scope is frozen.
    public static func isFrozen(words: [TimedWord], at index: Int, cutWordIds: Set<String>, freeze: Freeze) -> Bool {
        guard index >= 1, index < words.count else { return false }
        let positions = Dictionary(words.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        let a = words[index - 1], b = words[index]
        return frozen(a, b, cutWordIds: cutWordIds, window: window(a, b), freeze: freeze, positions: positions, changedWords: [])
    }

    /// §6 "Fix cut edges": seats every qualifying boundary without a key, as one step.
    public static func fix(_ project: Project, envelopes: [String: AudioEnvelope], freeze: [String: Freeze] = [:]) throws -> (project: Project, offer: Offer) {
        let (edges, offer) = fixing(project, envelopes: envelopes, freeze: freeze)
        var result = project
        result.edits.cutEdges.merge(edges) { _, new in new }
        return (try normalize(result), offer)
    }

    /// Editing §5.10 validation, strict and run before every commit: keys name a word at index 1 or later in the same
    /// recording as the word before it, with a gap of at least 0 and under 0.2 s; values are finite, within the word edge
    /// ± (0.15 s + one sample), and strictly inside the two words. A key at a boundary that is no longer kept/cut is
    /// accepted and ignored by the planner, as unknown cut ids are.
    static func validate(_ project: Project) throws {
        let edges = project.edits.cutEdges
        guard !edges.isEmpty else { return }
        try ProjectValidation.require(project.schemaVersion >= ProjectMigrations.frameVersion, "Cut edges require project version 8")
        let rate = clockRate(project)
        var found = 0
        for recording in recordings(project) {
            for index in recording.words.indices {
                let b = recording.words[index]
                guard let value = edges[b.id] else { continue }
                found += 1
                try ProjectValidation.require(index >= 1, "A cut edge needs a word before it in the same recording")
                let a = recording.words[index - 1]
                let gap = b.start - a.end, edge = (a.end + b.start) / 2
                try ProjectValidation.require(gap >= 0 && gap < maxGap, "A cut edge sits between touching words")
                try ProjectValidation.require(value.isFinite && abs(value - edge) <= reach + 1 / rate && value > a.start && value < b.end,
                                              "A cut edge lies within 0.15 s of its word edge")
            }
        }
        try ProjectValidation.require(found == edges.count, "A cut edge names a word that does not exist")
    }

    // MARK: - Steps

    struct Point {
        let value: Double
        let window: TimeRange
    }

    static func isSpeech(_ word: TimedWord) -> Bool { word.kind == .word || word.kind == .unlabeledSpeech }

    /// The ProjectClock sample rate R.
    static func clockRate(_ project: Project) -> Double { Double(max(1, project.media.source.audio?.sampleRate ?? 48_000)) }

    /// §3.1 steps 1–8 for one boundary: the centre of the nearest quiet run, or nil when the edge stays.
    static func quietPoint(_ a: TimedWord, _ b: TimedWord, analysis: LevelAnalysis, sampleRate: Double) -> Point? {
        let levels = analysis.levels, frameLength = analysis.frameLength
        let edge = (a.end + b.start) / 2
        let edgeFrame = analysis.frameAt(edge)
        let edgeLevel = Double(levels[edgeFrame])
        guard edgeLevel > max(analysis.threshold, 0.35 * analysis.speechLevel) else { return nil }
        let quiet = max(analysis.threshold, min(0.5 * edgeLevel, 0.35 * analysis.speechLevel))
        let search = window(a, b)
        let lowTime = search.start, highTime = search.end
        let lowFrame = max(0, ceil(lowTime / frameLength))
        let highFrame = min(Double(levels.count - 1), floor(highTime / frameLength) - 1)
        guard lowFrame.isFinite, highFrame.isFinite, lowFrame <= highFrame else { return nil }
        let high = Int(highFrame)
        var best: (first: Int, last: Int, distance: Int, minimum: Double)?
        var first = Int(lowFrame)
        while first <= high {
            guard Double(levels[first]) <= quiet else {
                first += 1
                continue
            }
            var last = first, minimum = Double(levels[first])
            while last + 1 <= high, Double(levels[last + 1]) <= quiet {
                last += 1
                minimum = min(minimum, Double(levels[last]))
            }
            if last - first + 1 >= minimumRun {
                let distance = first > edgeFrame ? first - edgeFrame : edgeFrame - last
                if let current = best {
                    if distance < current.distance || (distance == current.distance && minimum < current.minimum) {
                        best = (first, last, distance, minimum)
                    }
                } else {
                    best = (first, last, distance, minimum)
                }
            }
            first = last + 1
        }
        guard let best else { return nil }
        let frames = Double(best.first + best.last + 1)
        let time = frames / 2 * frameLength
        return Point(value: EditingPrimitives.jsRound(time * sampleRate) / sampleRate, window: TimeRange(start: lowTime, end: highTime))
    }

    /// §3.1 step 5's window in seconds: within 0.15 s of the word edge, and never more than half of either word.
    static func window(_ a: TimedWord, _ b: TimedWord) -> TimeRange {
        let edge = (a.end + b.start) / 2
        let lowTime = max(edge - reach, a.start + max(0.04, 0.5 * (a.end - a.start)))
        let highTime = min(edge + reach, b.end - max(0.04, 0.5 * (b.end - b.start)))
        return TimeRange(start: lowTime, end: highTime)
    }

    /// §3.2: a Voice Lab replace range overlaps the window, or the boundary touches a paid scope, whose inputs count a key
    /// when word i−1 or word i lies in it. It is frozen when the kept word lies inside and the cut word outside (rule b),
    /// and otherwise unless one of `changedWords` at this boundary lies inside the scope: a commit that cuts or restores a
    /// word in the scope changes its cuts there anyway, and undoing that change drops the key with it.
    static func frozen(_ a: TimedWord, _ b: TimedWord, cutWordIds: Set<String>, window: TimeRange, freeze: Freeze,
                       positions: [String: Int], changedWords: Set<String>) -> Bool {
        if freeze.voiceRanges.contains(where: { $0.start < window.end && window.start < $0.end }) { return true }
        let (kept, removed) = cutWordIds.contains(a.id) ? (b, a) : (a, b)
        return freeze.paidScopes.contains { scope in
            guard let low = positions[scope.startWordId], let high = positions[scope.endWordId],
                  let keptIndex = positions[kept.id], let removedIndex = positions[removed.id] else { return false }
            let keptInside = low <= keptIndex && keptIndex <= high, removedInside = low <= removedIndex && removedIndex <= high
            guard keptInside || removedInside else { return false }
            if keptInside && !removedInside { return true }
            return !((keptInside && changedWords.contains(kept.id)) || (removedInside && changedWords.contains(removed.id)))
        }
    }

    /// The boundaries whose kept/cut state differs between two cut sets, named by the later word.
    static func changedBoundaries(_ words: [TimedWord], before: Set<String>, after: Set<String>) -> Set<String> {
        var result: Set<String> = []
        for index in words.indices.dropFirst() {
            let a = words[index - 1].id, b = words[index].id
            if before.contains(a) != after.contains(a) || before.contains(b) != after.contains(b) { result.insert(b) }
        }
        return result
    }

    static func fixing(_ project: Project, envelopes: [String: AudioEnvelope], freeze: [String: Freeze]) -> (edges: [String: Double], offer: Offer) {
        var edges: [String: Double] = [:], offer = Offer()
        let cut = Set(project.edits.cutWordIds), rate = clockRate(project)
        for recording in recordings(project) {
            guard let envelope = envelopes[recording.key] else {
                let open = recording.words.indices.dropFirst().contains { index in
                    project.edits.cutEdges[recording.words[index].id] == nil &&
                        qualifies(recording.words[index - 1], recording.words[index], cutWordIds: cut)
                }
                if open { offer.unloaded.append(recording.key) }
                continue
            }
            let seated = seat(words: recording.words, cutWordIds: cut, envelope: envelope, sampleRate: rate,
                              freeze: freeze[recording.key] ?? Freeze(), existing: project.edits.cutEdges)
            edges.merge(seated.edges) { _, new in new }
            offer.count += seated.edges.count
            offer.frozen += seated.frozen
        }
        return (edges, offer)
    }
}

extension EditState {
    /// A stored cut edge in recording-local seconds on the clock: shifted by its recording's offset as ProjectClock
    /// shifts words, unchanged in the first recording.
    func clockTime(ofEdge local: Double, word id: String) -> Double {
        guard let clock = projectClock, let region = clock.region(of: id), region.offsetSamples > 0 else { return local }
        let rate = Double(clock.sampleRate)
        return (Double(region.offsetSamples) + EditingPrimitives.jsRound(local * rate)) / rate
    }
}
