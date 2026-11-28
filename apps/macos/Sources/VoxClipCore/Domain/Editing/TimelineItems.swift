import Foundation

public enum TimelineItemID: Hashable, Sendable {
    case effect(String), footage(String), motion(String), music(String), clip(String), part(String), contextDemo(String), voice(String)

    public var value: String {
        switch self {
        case .effect(let id), .footage(let id), .motion(let id), .music(let id), .clip(let id), .part(let id),
             .contextDemo(let id), .voice(let id): id
        }
    }
}

public enum TimelineItemLane: String, Sendable, CaseIterable {
    case captions = "CC", titles = "T1", pictures = "B1", effects = "FX", video = "V1", voice = "A1", sounds = "S1", music = "M1"
}

public struct TimelineItem: Equatable, Sendable {
    public let id: TimelineItemID
    public let kind: String
    public let lane: TimelineItemLane
    public internal(set) var row: Int
    public let partID: String?
    public let sourceAnchor: Double
    public let editedIntervals: [TimeRange]
    public let axisIntervals: [TimeRange]
    public let hidden: Bool
    public let marker: Double?
    public let seamNotches: [Double]
    public let reason: String?
}

public struct TimelineSnapTarget: Equatable, Hashable, Sendable {
    public enum Kind: String, Sendable { case word, playhead, item, partSeam, scopeEdge, gainPoint }
    public let time: Double
    public let kind: Kind
    public let item: TimelineItemID?
}

public struct TimelineItemLayout: Equatable, Sendable {
    public let items: [TimelineItem]
    public let rowCounts: [TimelineItemLane: Int]
    public let snapTargets: [TimelineSnapTarget]
}

public enum TimelineItems {
    public static let cutDropCopy = "Lands on a cut · plays at the seam"

    public static func sourceAnchor(at time: Double, axis: TimelineAxis, plan: EditPlan) -> Double {
        let source = axis == .edited ? plan.sourceTime(time) : time
        return EditingPrimitives.jsRound(source * plan.sampleRate) / plan.sampleRate
    }

    public static func dropHint(at time: Double, axis: TimelineAxis, plan: EditPlan) -> String? {
        guard axis == .source, plan.cutContaining(sourceAnchor(at: time, axis: axis, plan: plan)) != nil else { return nil }
        return cutDropCopy
    }

    public static func layout(project: Project, plan: EditPlan, scope: String?, axis: TimelineAxis,
                              playhead: Double? = nil) -> TimelineItemLayout {
        let clock = TimelineClock(project, plan: plan, scope: scope)
        let entries = TimelineEntries(project, clock: clock)
        var targets: [TimelineSnapTarget] = []
        func target(_ time: Double, _ kind: TimelineSnapTarget.Kind, _ item: TimelineItemID? = nil) {
            targets.append(.init(time: clock.round(time), kind: kind, item: item))
        }
        if let playhead, playhead.isFinite { target(playhead, .playhead) }
        if axis == .edited {
            target(0, .scopeEdge); target(plan.duration, .scopeEdge)
            for seam in plan.partSeams { target(Double(seam) / plan.sampleRate, .partSeam) }
        } else {
            for (index, part) in clock.parts.enumerated() {
                target(part.range.start, index == 0 ? .scopeEdge : .partSeam)
                target(part.range.end, index == clock.parts.count - 1 ? .scopeEdge : .partSeam)
            }
        }
        for word in clock.words {
            let range = clock.range(word.start, word.end)
            if axis == .edited {
                for interval in clock.projected(range) {
                    target(interval.edited.start, .word); target(interval.edited.end, .word)
                }
            } else if clock.parts.contains(where: { StoryClips.overlaps($0.range, range) }) {
                target(range.start, .word); target(range.end, .word)
            }
        }

        var items: [TimelineItem] = []
        var rowCounts: [TimelineItemLane: Int] = [:]
        for lane in TimelineItemLane.allCases {
            let laneEntries = entries.values.filter { $0.lane == lane }
            var members = laneEntries.map { clock.display($0, axis: axis) }
            let ranges = members.map { item in
                let starts = item.axisIntervals.map(\.start), ends = item.axisIntervals.map(\.end)
                let start = starts.min() ?? item.marker ?? 0
                return start...(ends.max() ?? start)
            }
            let rows = TimelineOverview.rows(for: ranges)
            rowCounts[lane] = (rows.max() ?? 0) + 1
            for (index, entry) in laneEntries.enumerated() {
                members[index].row = rows[index]
                let item = members[index]
                if !item.hidden {
                    for interval in item.axisIntervals {
                        target(interval.start, .item, item.id); target(interval.end, .item, item.id)
                    }
                    if let first = item.editedIntervals.first, let last = item.editedIntervals.last {
                        for point in entry.points ?? [] where clock.round(first.start + point.t) <= last.end {
                            let time = clock.round(first.start + point.t)
                            target(axis == .edited ? time : clock.source(at: time), .gainPoint, item.id)
                        }
                    }
                }
            }
            items += members
        }
        var seen: Set<TimelineSnapTarget> = []
        return .init(items: items, rowCounts: rowCounts, snapTargets: targets.filter { seen.insert($0).inserted }.sorted { $0.time < $1.time })
    }
}

struct TimelineEntry {
    let id: TimelineItemID
    let kind: String
    let lane: TimelineItemLane
    var span: TimeRange
    var ownLength: Bool = false
    var scoped: Bool = true
    var offset: Double? = nil
    var available: Double? = nil
    var points: [GainPoint]? = nil

    var name: String {
        switch kind {
        case "lowerThird": "lower third"
        case "sticker": "emoji"
        case "motionTemplate": "template"
        case "bRoll": "B-roll"
        case "videoStack": "video stack"
        case "colourLook": "look"
        case "speedForPart": "speed change"
        default: kind
        }
    }

    var wordLocked: Bool { kind == "bleep" || kind == "mute" }
    var footage: Bool { if case .footage = id { true } else { false } }
    var audio: Bool { kind == "sound" || kind == "music" }
}

struct TimelineEntries {
    let values: [TimelineEntry]

    init(_ project: Project, clock: TimelineClock) {
        let scope = clock.scope
        var result = project.clipEffects.compactMap { effect -> TimelineEntry? in
            guard effect.clipId == scope || effect.kind.isCensor else { return nil }
            let lane: TimelineItemLane = switch effect.kind {
            case .sound, .bleep, .mute: .sounds
            case .illustration: .pictures
            case .colourLook, .speedForPart, .freeze: .effects
            default: .titles
            }
            return .init(id: .effect(effect.id), kind: effect.kind.rawValue, lane: lane,
                         span: .init(start: effect.start, end: effect.end), ownLength: effect.kind == .sound,
                         scoped: effect.clipId == scope && !effect.kind.usesWords,
                         offset: effect.mediaOffsetSeconds, available: effect.sound?.durationSeconds,
                         points: effect.gainPoints)
        }
        let durations = project.media.footageDurations
        for footage in project.media.footage where footage.clipID == scope {
            result.append(.init(id: .footage(footage.id), kind: footage.kind.rawValue, lane: .pictures,
                                span: .init(start: footage.start, end: footage.end), offset: footage.footage.start,
                                available: durations[footage.footage.sourceKey]))
        }
        for cue in project.motionCues where cue.clipID == scope {
            result.append(.init(id: .motion(cue.id), kind: "zoom", lane: .effects,
                                span: .init(start: cue.sourceStart, end: cue.sourceEnd)))
        }
        if let track = project.music.first(where: { $0.clipId == scope }) {
            let segments = track.segments ?? clock.bed(track).map { [$0] } ?? []
            for segment in segments {
                result.append(.init(id: .music(segment.id), kind: "music", lane: .music,
                                    span: .init(start: segment.anchorSeconds, end: segment.anchorSeconds + segment.lengthSeconds),
                                    ownLength: true, offset: segment.songFromSeconds, available: track.asset.durationSeconds,
                                    points: segment.gainPoints))
            }
        }
        if let clip = clock.clip {
            for part in clock.parts {
                let id = clip.parts == nil ? TimelineItemID.clip(clip.id) : .part(part.id ?? clip.id)
                result.append(.init(id: id, kind: clip.parts == nil ? "clip" : "part", lane: .video, span: part.range))
            }
        }
        if scope == nil {
            for placement in project.contextDemo?.placements ?? [] {
                let start = clock.source(at: placement.editedStartSeconds)
                result.append(.init(id: .contextDemo(placement.id), kind: "contextDemo", lane: .pictures,
                                    span: .init(start: start, end: start + placement.editedEndSeconds - placement.editedStartSeconds),
                                    ownLength: true))
            }
        }
        for segment in project.voiceLab.segments where segment.enabled {
            let span = TimeRange(start: segment.replace.start, end: segment.replace.end)
            if clock.parts.contains(where: { StoryClips.overlaps($0.range, span) }) {
                result.append(.init(id: .voice(segment.id), kind: "voice", lane: .voice, span: span))
            }
        }
        values = result
    }
}

struct TimelineClock {
    struct Part {
        let id: String?
        let range: TimeRange
    }

    struct Piece {
        let source: TimeRange
        let edited: TimeRange
    }

    let plan: EditPlan
    let scope: String?
    let clip: ClipRange?
    let words: [TimedWord]
    private let cutWordIDs: Set<String>
    let parts: [Part]
    let pieces: [Piece]
    private let sourcePieces: [Piece]
    private let partPieces: [[Piece]]

    init(_ project: Project, plan: EditPlan, scope: String?) {
        self.plan = plan; self.scope = scope
        let clip = project.edits.clips.first { $0.id == scope }
        let words = ProjectClock.build(project).words
        self.clip = clip; self.words = words
        cutWordIDs = Set(project.edits.cutWordIds)
        let rate = plan.sampleRate
        let duration = Double(plan.totalSamples) / rate
        let bounds = clip.map { StoryClips.times($0, words: words) } ?? [.init(start: 0, end: duration)]
        parts = bounds.enumerated().map { index, bound in
            .init(id: clip?.playParts[index].id,
                  range: .init(start: EditingPrimitives.jsRound(bound.start * rate) / rate,
                               end: min(duration, EditingPrimitives.jsRound(bound.end * rate) / rate)))
        }
        let pieces: [Piece] = zip(plan.kept, plan.fadeParts).map { kept, output in
            .init(source: .init(start: Double(kept.startSample) / rate, end: Double(kept.endSample) / rate),
                  edited: .init(start: Double(output.outputStart) / rate, end: Double(output.outputStart + kept.count) / rate))
        }
        self.pieces = pieces
        sourcePieces = pieces.sorted { $0.source.start < $1.source.start }
        partPieces = parts.map { part in pieces.filter { StoryClips.overlaps($0.source, part.range) } }
    }

    func round(_ seconds: Double) -> Double { EditingPrimitives.jsRound(seconds * plan.sampleRate) / plan.sampleRate }
    func range(_ start: Double, _ end: Double) -> TimeRange { .init(start: round(start), end: round(end)) }

    func bed(_ track: ProjectMusic) -> MusicSegment? {
        guard let first = pieces.first else { return nil }
        return .init(id: track.id, anchorSeconds: first.source.start, lengthSeconds: plan.duration,
                     songFromSeconds: round(track.startOffsetSeconds), loop: true,
                     fadeInSeconds: round(track.fadeInSeconds), fadeOutSeconds: round(track.fadeOutSeconds))
    }

    func part(at source: Double) -> Int? {
        parts.firstIndex { $0.range.start <= source && source < $0.range.end }
    }

    func edited(at source: Double, part: Int?) -> Double {
        guard let part, parts.count > 1 else { return plan.mapTime(source) }
        let owned = partPieces[part]
        if let previous = owned.last(where: { $0.source.start <= source }) {
            return min(previous.edited.end, round(previous.edited.start + source - previous.source.start))
        }
        if let first = owned.first { return first.edited.start }
        return partPieces.prefix(part).reversed().lazy.compactMap { $0.last?.edited.end }.first ?? 0
    }

    func source(at edited: Double) -> Double {
        if edited >= plan.duration, let last = pieces.last { return last.source.end }
        return plan.sourceTime(edited)
    }

    func projected(_ span: TimeRange) -> [Piece] {
        guard span.start < span.end else { return [] }
        var lower = 0, upper = sourcePieces.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if sourcePieces[middle].source.end <= span.start { lower = middle + 1 } else { upper = middle }
        }
        return sourcePieces[lower...].prefix { $0.source.start < span.end }.map { piece -> Piece in
            let start = max(piece.source.start, span.start), end = min(piece.source.end, span.end)
            return .init(source: .init(start: start, end: end),
                         edited: range(piece.edited.start + start - piece.source.start, piece.edited.start + end - piece.source.start))
        }.sorted { $0.edited.start < $1.edited.start }
    }

    private func allCoveredWordsCut(_ span: TimeRange) -> Bool {
        guard !cutWordIDs.isEmpty else { return false }
        var covered = false
        for word in words.prefix(while: { $0.start < span.end }) where word.end > span.start {
            if !cutWordIDs.contains(word.id) { return false }
            covered = true
        }
        return covered
    }

    func display(_ entry: TimelineEntry, axis: TimelineAxis) -> TimelineItem {
        let span = range(entry.span.start, entry.span.end)
        let owner = part(at: span.start)
        let anchor = edited(at: span.start, part: owner)
        var intervals: [TimeRange] = [], visible: [TimeRange] = [], notches: [Double] = []
        var reason: String?
        if entry.ownLength {
            let end = min(plan.duration, round(anchor + span.end - span.start))
            if owner != nil, anchor < end {
                intervals = [.init(start: anchor, end: end)]
                if axis == .source {
                    visible = pieces.compactMap { piece in
                        guard StoryClips.overlaps(piece.edited, intervals[0]) else { return nil }
                        return range(piece.source.start + max(anchor, piece.edited.start) - piece.edited.start,
                                     piece.source.start + min(end, piece.edited.end) - piece.edited.start)
                    }
                    if let first = visible.first, span.start < first.start { visible[0].start = span.start }
                }
            }
        } else if (!entry.scoped || owner.map { span.end <= parts[$0].range.end } == true),
                  entry.lane == .video || !allCoveredWordsCut(span) {
            var remaining = entry.footage && entry.kind != "screenshot" && entry.available != nil
                ? max(0, round((entry.available ?? 0) - (entry.offset ?? 0))) : .infinity
            for interval in projected(span) {
                let length = round(interval.edited.end - interval.edited.start)
                let shown = min(remaining, length)
                if shown < length { reason = "The recording ends here." }
                guard shown > 0 else { continue }
                if !intervals.isEmpty { notches.append(axis == .edited ? interval.edited.start : interval.source.start) }
                intervals.append(range(interval.edited.start, interval.edited.start + shown))
                visible.append(range(interval.source.start, interval.source.start + shown))
                remaining -= shown
            }
        }
        let hidden = intervals.isEmpty
        if hidden && reason == nil {
            reason = owner == nil || (entry.scoped && !entry.ownLength && owner.map { span.end > parts[$0].range.end } == true)
                ? "Hidden · outside this clip" : "Hidden · its words are cut"
        }
        return .init(id: entry.id, kind: entry.kind, lane: entry.lane, row: 0,
                     partID: owner.flatMap { parts[$0].id }, sourceAnchor: span.start, editedIntervals: intervals,
                     axisIntervals: axis == .edited ? intervals : visible, hidden: hidden,
                     marker: hidden ? (axis == .edited ? anchor : span.start) : nil, seamNotches: notches, reason: reason)
    }
}
