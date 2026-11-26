import Foundation

public enum TimelineEdge: String, Sendable { case start, end }
public enum TimelineNudge: Sendable { case frames(Int), words(Int) }

public enum TimelineEdit: Sendable {
    case move(items: [TimelineItemID], toAnchor: Double)
    case nudge(items: [TimelineItemID], by: TimelineNudge)
    case trim(item: TimelineItemID, edge: TimelineEdge, toSource: Double)
    case split(items: [TimelineItemID], atSource: Double)
    case splitAll(atSource: Double)
    case fade(item: TimelineItemID, edge: TimelineEdge, seconds: Double)
    case setGain(item: TimelineItemID, db: Double)
    case setTrackGain(track: String, db: Double)
    case addGainPoint(item: TimelineItemID, atSource: Double, db: Double)
    case dipGain(item: TimelineItemID, fromSource: Double, toSource: Double, byDb: Double)
    case moveGainPoint(item: TimelineItemID, from: Double, toSource: Double, db: Double)
    case removeGainPoint(item: TimelineItemID, at: Double)
    case slip(item: TimelineItemID, bySeconds: Double)
    case setLoop(item: TimelineItemID, Bool)
    case setDuck(track: String, db: Double)
    case duplicate(items: [TimelineItemID], toAnchor: Double?)
    case delete(items: [TimelineItemID])
}

public struct TimelineEditRefusal: Error, Equatable, Sendable, LocalizedError {
    public let copy: String
    public var errorDescription: String? { copy }
    public init(_ copy: String) { self.copy = copy }
}

public enum TimelineEdits {
    public static func apply(_ edit: TimelineEdit, project: Project, plan: EditPlan, scope: String?)
        -> Result<(project: Project, undoName: String), TimelineEditRefusal> {
        guard plan.sampleRate.isFinite, plan.sampleRate > 0 else { return .failure(.init("The timeline is not ready.")) }
        do {
            var reducer = TimelineReducer(project, plan: plan, scope: scope)
            let name = try reducer.apply(edit)
            var result = reducer.project
            if result != project {
                if result.schemaVersion < 4 { result = try ContextDemoProject.upgradeToV4(result) }
                result.schemaVersion = TimelineEditFields.version
            }
            return .success((result, name))
        } catch let refusal as TimelineEditRefusal {
            return .failure(refusal)
        } catch {
            return .failure(.init("This edit would make the item invalid."))
        }
    }
}

private struct TimelineReducer {
    static let insidePart = TimelineEditRefusal("Place it inside one part.")
    static let wholeWords = TimelineEditRefusal("A bleep covers whole words. Trim it to fewer words instead.")
    static let tooShort = TimelineEditRefusal("Too short to split here.")
    static let noItem = TimelineEditRefusal("Select an item on this timeline.")
    static let invalidTime = TimelineEditRefusal("Enter a valid time.")
    static let readOnly = TimelineEditRefusal("This item is read-only.")
    static let invalid = TimelineEditRefusal("This edit would make the item invalid.")

    var project: Project
    let clock: TimelineClock
    let entries: [TimelineEntry]

    init(_ project: Project, plan: EditPlan, scope: String?) {
        self.project = project
        clock = TimelineClock(project, plan: plan, scope: scope)
        entries = TimelineEntries(project, clock: clock).values
    }

    mutating func apply(_ command: TimelineEdit) throws -> String {
        if clock.scope != nil && clock.clip == nil { throw Self.noItem }
        switch command {
        case .move(let ids, let anchor):
            return try move(select(ids), anchor: time(anchor), verb: "Move")
        case .nudge(let ids, let step):
            let selected = try select(ids)
            let start = selected[0].span.start
            let target: Double
            switch step {
            case .frames(let count):
                let fps = project.media.source.video?.frameRate ?? 30
                target = try time(start + Double(count) * clock.round(1 / (fps > 0 ? fps : 30)))
            case .words(let count):
                let words = clock.words.filter { word in
                    !clock.projected(clock.range(word.start, word.end)).isEmpty
                }.sorted { clock.edited(at: $0.start, part: clock.part(at: $0.start)) < clock.edited(at: $1.start, part: clock.part(at: $1.start)) }
                let position = clock.edited(at: start, part: clock.part(at: start))
                let positions = words.map { clock.edited(at: $0.start, part: clock.part(at: $0.start)) }
                let index = count < 0 ? (positions.firstIndex { $0 >= position } ?? words.count) : (positions.lastIndex { $0 <= position } ?? -1)
                let next = Double(index) + Double(count)
                guard !words.isEmpty else { throw Self.noItem }
                target = next >= 0 && next < Double(words.count) ? try time(words[Int(next)].start) : try time(start)
            }
            return try move(selected, anchor: target, verb: "Nudge")
        case .duplicate(let ids, let anchor):
            return try move(select(ids), anchor: anchor.map(time), verb: "Duplicate", duplicate: true)
        case .delete(let ids):
            let selected = try select(ids)
            for item in selected { try delete(item) }
            return name("Delete", selected)
        case .trim(let id, let edge, let source):
            let item = try entry(id), source = try time(source)
            if item.lane == .video { return try trimSpeech(item, edge: edge, source: source) }
            try trim(item, edge: edge, source: source)
            return name("Trim", [item])
        case .split(let ids, let source):
            let source = try time(source)
            let selected = ids.isEmpty ? try underPlayhead(source, skipUnsupported: false) : try select(ids)
            guard !selected.isEmpty else { throw Self.noItem }
            for item in selected { try split(item, source: source) }
            return name("Split", selected)
        case .splitAll(let source):
            let source = try time(source)
            if clock.scope == nil { return try splitFullTake(at: source) }
            let (clip, leftEnd, rightStart) = try splitSpeech(at: source)
            try checkSpeech(clip)
            let before = project
            let crossing = try underPlayhead(rightStart, skipUnsupported: true)
            for item in crossing {
                if item.ownLength { try split(item, source: rightStart) }
                else if item.span.start < leftEnd { try split(item, source: rightStart, leftEnd: leftEnd) }
                else { try trim(item, edge: .start, source: rightStart) }
            }
            if leftEnd < rightStart {
                let ending = try underPlayhead(leftEnd, skipUnsupported: true)
                for item in ending where !item.ownLength && !crossing.contains(where: { $0.id == item.id }) {
                    try trim(item, edge: .end, source: leftEnd)
                }
            }
            try replaceSpeech(clip, preserving: before)
            return "Split all"
        case .fade(let id, let edge, let seconds):
            let item = try entry(id)
            try requireEditable(item)
            let maxFade = item.kind == "music" ? 10.0 : item.footage ? 2 : 5
            switch id {
            case .effect:
                guard let kind = ClipEffect.Kind(rawValue: item.kind), ClipEffect.allowsFades(kind) else { throw unsupported("fade", item) }
            case .footage, .music: break
            default: throw unsupported("fade", item)
            }
            var draft = Draft(item, clock: clock)
            draft.setFade(edge, min(maxFade, max(0, try time(seconds))))
            try write(item, draft)
            return name("Fade", [item])
        case .setGain(let id, let db):
            let item = try audio(id)
            var draft = Draft(item, clock: clock)
            draft.gain = try level(db, range: item.kind == "sound" ? ClipEffect.gainRange : -40...12)
            try write(item, draft)
            return "Change volume"
        case .setTrackGain(let track, let db):
            guard let index = project.music.firstIndex(where: { $0.id == track && $0.clipId == clock.scope }) else { throw Self.noItem }
            let gain = try level(db, range: ProjectMusic.gainRange)
            if gain != project.music[index].gainDb {
                try materialise(index)
                project.music[index].gainDb = gain
            }
            return "Change volume"
        case .addGainPoint(let id, let source, let db):
            try gainPoint(id, removing: nil, adding: (source, db))
            return "Add volume keyframe"
        case .dipGain(let id, let from, let to, let db):
            try dipGain(id, from: from, to: to, by: db)
            return "Dip volume"
        case .moveGainPoint(let id, let from, let source, let db):
            try gainPoint(id, removing: from, adding: (source, db))
            return "Move volume keyframe"
        case .removeGainPoint(let id, let at):
            try gainPoint(id, removing: at, adding: nil)
            return "Remove volume keyframe"
        case .slip(let id, let seconds):
            let item = try entry(id)
            try requireEditable(item)
            guard item.audio || item.footage else { throw unsupported("slip", item) }
            var draft = Draft(item, clock: clock)
            draft.offset = try time((item.offset ?? 0) + time(seconds))
            try checkMedia(item, draft, length: length(item, draft.span))
            try write(item, draft)
            return name("Slip", [item])
        case .setLoop(let id, let enabled):
            let item = try entry(id)
            try requireEditable(item)
            guard item.kind == "music" else { throw unsupported("loop", item) }
            var draft = Draft(item, clock: clock)
            draft.loop = enabled
            try checkMedia(item, draft, length: length(item, draft.span))
            try write(item, draft)
            return "Loop music"
        case .setDuck(let track, let db):
            guard let index = project.music.firstIndex(where: { $0.id == track && $0.clipId == clock.scope }) else { throw Self.noItem }
            try materialise(index)
            let depth = try level(db, range: -24...0)
            project.music[index].duckDb = depth
            project.music[index].ducking = depth != 0
            return "Change ducking"
        }
    }

    func time(_ value: Double) throws -> Double {
        guard value.isFinite, (value * clock.plan.sampleRate).isFinite else { throw Self.invalidTime }
        return clock.round(value)
    }

    func level(_ value: Double, range: ClosedRange<Double>) throws -> Double {
        guard value.isFinite else { throw Self.invalid }
        return min(range.upperBound, max(range.lowerBound, value))
    }

    func entry(_ id: TimelineItemID) throws -> TimelineEntry {
        guard let entry = entries.first(where: { $0.id == id }) else { throw Self.noItem }
        return entry
    }

    func select(_ ids: [TimelineItemID]) throws -> [TimelineEntry] {
        guard !ids.isEmpty else { throw Self.noItem }
        var seen: Set<TimelineItemID> = []
        return try ids.filter { seen.insert($0).inserted }.map(entry)
    }

    func name(_ action: String, _ items: [TimelineEntry]) -> String {
        action + " " + (items.count == 1 ? items[0].name : "\(items.count) items")
    }

    func unsupported(_ action: String, _ item: TimelineEntry) -> TimelineEditRefusal {
        .init("You can’t \(action) this \(item.name).")
    }

    func requireEditable(_ item: TimelineEntry) throws {
        if item.lane == .video || item.kind == "contextDemo" || item.lane == .voice { throw Self.readOnly }
    }

    func audio(_ id: TimelineItemID) throws -> TimelineEntry {
        let item = try entry(id)
        try requireEditable(item)
        guard item.audio else { throw unsupported("change the volume of", item) }
        return item
    }

    func length(_ item: TimelineEntry, _ span: TimeRange) -> Double {
        if !item.footage { return clock.round(span.end - span.start) }
        return clock.round(clock.projected(span).reduce(0) { $0 + $1.edited.end - $1.edited.start })
    }

    func edited(_ source: Double, for item: TimelineEntry) -> Double {
        clock.edited(at: source, part: clock.part(at: source) ?? clock.part(at: item.span.start))
    }

    func local(_ source: Double, for item: TimelineEntry) -> Double {
        clock.round(edited(source, for: item) - edited(item.span.start, for: item))
    }

    func checkSpan(_ item: TimelineEntry, _ span: TimeRange) throws {
        let minimum = item.kind == "music" ? 0.1 + 1 / clock.plan.sampleRate : item.kind == "sound" ? 0.05 : item.kind == "zoom" ? 0.1 : 1 / clock.plan.sampleRate
        guard clock.round(span.end - span.start) >= minimum - 1e-9 else { throw .init("Keep a longer item.") as TimelineEditRefusal }
        guard let part = clock.part(at: span.start), item.ownLength || span.end <= clock.parts[part].range.end else {
            throw clock.clip == nil ? TimelineEditRefusal("Place it inside the take.") : Self.insidePart
        }
    }

    func checkMedia(_ item: TimelineEntry, _ draft: Draft, length: Double) throws {
        guard let duration = item.available else { throw Self.invalid }
        let offset = draft.offset ?? item.offset ?? 0
        let loop = draft.loop ?? segment(item)?.loop ?? false
        let available = duration - offset
        if offset >= 0, offset < duration, loop || item.kind == "screenshot" || length <= available + 1e-9 { return }
        if item.kind == "music" && !loop && offset >= 0 {
            throw TimelineEditRefusal("The song ends at \(StoryClips.clock(duration)). Turn on Loop to extend it.")
        }
        if item.footage { throw TimelineEditRefusal("The recording ends here.") }
        throw TimelineEditRefusal(item.kind == "sound" ? "Keep it inside the sound." : "Keep it inside the song.")
    }

    mutating func move(_ items: [TimelineEntry], anchor: Double?, verb: String, duplicate: Bool = false) throws -> String {
        if items.count == 1, case .part(let id) = items[0].id, !duplicate, let anchor {
            return try movePart(id, to: anchor)
        }
        let delta = anchor.map { clock.round($0 - clock.round(items[0].span.start)) } ?? (duplicate ? duplicateOffset(items) : 0)
        for item in items {
            try requireEditable(item)
            if delta == 0 && !duplicate { continue }
            var draft = Draft(item, clock: clock)
            draft.span = clock.range(draft.span.start + delta, draft.span.end + delta)
            if item.wordLocked { try snapWords(item, draft: &draft, edge: nil) }
            if item.wordLocked, !duplicate, draft.span == item.span { continue }
            try checkSpan(item, draft.span)
            if duplicate { draft.newID = fresh(item.id.value, taken: allIDs(item.id)) }
            draft.trackShift = delta
            try write(item, draft)
        }
        if items.contains(where: \.footage) { try checkFootageOverlap() }
        return name(verb, items)
    }

    mutating func trim(_ item: TimelineEntry, edge: TimelineEdge, source: Double) throws {
        try requireEditable(item)
        var draft = Draft(item, clock: clock)
        let oldLength = length(item, draft.span)
        var consumed = 0.0
        switch edge {
        case .start:
            if item.ownLength {
                consumed = local(source, for: item)
                draft.span = clock.range(source, source + oldLength - consumed)
            } else {
                draft.span.start = source
                if item.footage {
                    consumed = clock.round(clock.projected(clock.range(min(source, item.span.start), max(source, item.span.start)))
                        .reduce(0) { $0 + $1.edited.end - $1.edited.start }) * (source < item.span.start ? -1 : 1)
                }
            }
        case .end:
            draft.span.end = item.ownLength ? clock.round(draft.span.start + local(source, for: item)) : source
        }
        if item.wordLocked { try snapWords(item, draft: &draft, edge: edge) }
        try checkSpan(item, draft.span)
        if item.footage { try checkFootageOverlap(item, draft.span) }
        let newLength = length(item, draft.span)
        if item.audio || item.footage {
            if edge == .start && item.kind != "screenshot" {
                draft.offset = mediaOffset(item, advancedBy: consumed)
            }
            try checkMedia(item, draft, length: newLength)
        }
        draft.points = envelope(item.points, from: consumed, to: clock.round(consumed + newLength))
        try write(item, draft)
    }

    func mediaOffset(_ item: TimelineEntry, advancedBy seconds: Double) -> Double {
        let offset = clock.round((item.offset ?? 0) + seconds)
        if segment(item)?.loop == true, let duration = item.available, duration > 0 {
            let wrapped = offset.truncatingRemainder(dividingBy: duration)
            let grid = clock.round(wrapped < 0 ? wrapped + duration : wrapped)
            return grid >= duration ? 0 : grid
        }
        return offset
    }

    func underPlayhead(_ source: Double, skipUnsupported: Bool) throws -> [TimelineEntry] {
        let time = clock.edited(at: source, part: clock.part(at: source))
        return entries.filter { item in
            guard item.lane != .video, item.lane != .voice, item.kind != "contextDemo", !skipUnsupported || !item.wordLocked else { return false }
            let layout = clock.display(item, axis: .edited)
            guard let first = layout.editedIntervals.first, let last = layout.editedIntervals.last else { return false }
            return first.start < time && time < last.end && (item.ownLength || (item.span.start < source && source < item.span.end))
        }
    }

    mutating func split(_ item: TimelineEntry, source: Double, leftEnd: Double? = nil) throws {
        if item.lane == .video { throw TimelineEditRefusal("Use Split All to split speech.") }
        try requireEditable(item)
        if item.wordLocked { throw Self.wholeWords }
        var left = Draft(item, clock: clock), right = left
        let full = length(item, left.span), leftEdge = leftEnd ?? source
        let offset = item.ownLength ? local(source, for: item) : length(item, clock.range(item.span.start, leftEdge))
        let skipped = item.ownLength ? 0 : length(item, clock.range(leftEdge, source))
        let rest = clock.round(full - offset - skipped)
        let minimum = item.kind == "zoom" ? 0.2 : item.kind == "music" ? 0.1 + 1 / clock.plan.sampleRate : item.kind == "sound" ? 0.05 : 1 / clock.plan.sampleRate
        guard offset >= minimum - 1e-9, rest >= minimum - 1e-9 else { throw Self.tooShort }
        if !item.ownLength && !(left.span.start < source && source < left.span.end) { throw Self.tooShort }
        left.span.end = item.ownLength ? clock.round(left.span.start + offset) : leftEdge
        right.span.start = source
        if item.ownLength { right.span.end = clock.round(source + rest) }
        try checkSpan(item, left.span); try checkSpan(item, right.span)
        if item.audio || (item.footage && item.kind != "screenshot") {
            right.offset = mediaOffset(item, advancedBy: offset + skipped)
            try checkMedia(item, right, length: item.footage ? min(rest, (item.available ?? 0) - (right.offset ?? 0)) : rest)
        }
        if item.audio { left.points = envelope(item.points, from: 0, to: offset); right.points = envelope(item.points, from: offset, to: full) }
        if item.footage || item.audio || (item.kind != "illustration" && ClipEffect.Kind(rawValue: item.kind).map(ClipEffect.allowsFades) == true) {
            left.fadeOut = 0; right.fadeIn = 0
        }
        if item.kind == "zoom", let cue = project.motionCues.first(where: { $0.id == item.id.value }) {
            let duration = cue.sourceEnd - cue.sourceStart
            let lower = (leftEdge - cue.sourceStart) / duration, upper = (source - cue.sourceStart) / duration
            func frame(_ progress: Double, at time: Double) -> MotionKeyframe {
                let pose = cue.transform(atSourceTime: time)
                return .init(progress: progress, scale: pose.scale, anchorX: pose.anchorX, anchorY: pose.anchorY)
            }
            func resample(_ key: MotionKeyframe, from: Double, to: Double) -> MotionKeyframe {
                .init(progress: (key.progress - from) / (to - from), scale: key.scale, anchorX: key.anchorX, anchorY: key.anchorY)
            }
            left.motion = cue.keyframes.filter { $0.progress < lower }.map { resample($0, from: 0, to: lower) } + [frame(1, at: leftEdge)]
            right.motion = [frame(0, at: source)] + cue.keyframes.filter { $0.progress > upper }.map { resample($0, from: upper, to: 1) }
        }
        right.newID = fresh(item.id.value, taken: allIDs(item.id))
        try write(item, right); try write(item, left)
    }

    func envelope(_ points: [GainPoint]?, from: Double, to: Double) -> [GainPoint]? {
        guard let points, !points.isEmpty else { return points }
        func gain(at time: Double) -> Double {
            guard let upper = points.firstIndex(where: { $0.t > time }) else { return points[points.count - 1].db }
            guard upper > 0 else { return points[0].db }
            let left = points[upper - 1], right = points[upper]
            return left.db + (right.db - left.db) * (time - left.t) / (right.t - left.t)
        }
        var result = points.filter { $0.t >= from && $0.t <= to }.map { GainPoint(t: clock.round($0.t - from), db: $0.db) }
        if from > points[0].t, from < points[points.count - 1].t, result.first?.t != 0 { result.insert(.init(t: 0, db: gain(at: from)), at: 0) }
        let end = clock.round(to - from)
        if to > points[0].t, to < points[points.count - 1].t, result.last?.t != end { result.append(.init(t: end, db: gain(at: to))) }
        if result.isEmpty { result.append(.init(t: 0, db: gain(at: from))) }
        return result
    }

    mutating func gainPoint(_ id: TimelineItemID, removing oldTime: Double?, adding point: (Double, Double)?) throws {
        let item = try audio(id)
        var points = item.points ?? []
        if let oldTime {
            let original = try time(oldTime)
            guard let index = points.firstIndex(where: { clock.round($0.t) == original }) else { throw TimelineEditRefusal("Choose a volume keyframe.") }
            points.remove(at: index)
        }
        if let point {
            let position = local(try time(point.0), for: item)
            guard position >= 0, position <= length(item, item.span) else { throw TimelineEditRefusal("Place the keyframe inside the item.") }
            guard !points.contains(where: { clock.round($0.t) == position }) else { throw TimelineEditRefusal("There is already a volume keyframe here.") }
            guard points.count < ItemShape.maximumGainPoints else { throw TimelineEditRefusal("An item can have up to 64 volume keyframes.") }
            points.append(.init(t: position, db: try level(point.1, range: -60...12)))
            points.sort { $0.t < $1.t }
        }
        var draft = Draft(item, clock: clock)
        draft.points = points
        try write(item, draft)
    }

    mutating func dipGain(_ id: TimelineItemID, from: Double, to: Double, by db: Double) throws {
        let item = try audio(id)
        let start = local(try time(from), for: item), end = local(try time(to), for: item)
        let ramp = min(0.05, (end - start) / 3)
        let innerStart = clock.round(start + ramp), innerEnd = clock.round(end - ramp)
        guard start >= 0, end <= length(item, item.span), start < innerStart, innerStart < innerEnd, innerEnd < end else {
            throw TimelineEditRefusal("Select a longer range inside the item.")
        }
        let depth = try level(db, range: -60...0)
        guard depth < 0 else { return }
        let original = item.points ?? []
        var points = original.filter { $0.t < start || $0.t > end }
        guard points.count + 4 <= ItemShape.maximumGainPoints else { throw TimelineEditRefusal("An item can have up to 64 volume keyframes.") }
        for position in [start, innerStart, innerEnd, end] {
            let base = MusicMix.envelopeDb(at: position, points: original)
            let db = try level(base + (position == start || position == end ? 0 : depth), range: -60...12)
            points.append(.init(t: position, db: db))
        }
        var draft = Draft(item, clock: clock)
        draft.points = points.sorted { $0.t < $1.t }
        try write(item, draft)
    }

    func snapWords(_ item: TimelineEntry, draft: inout Draft, edge: TimelineEdge?) throws {
        let words = clock.words
        let first = nearest(draft.span.start, indices: words.indices) { words[$0].start }
        let last: Int?
        if edge == nil, case .effect(let id) = item.id,
           let count = project.clipEffects.first(where: { $0.id == id })?.wordIds?.count, let first {
            last = first + count - 1
        } else {
            last = nearest(draft.span.end, indices: words.indices) { words[$0].end }
        }
        guard let first, let last, last >= first, last < words.count, last - first < ClipEffect.maximumWords else { throw Self.wholeWords }
        draft.span = clock.range(words[first].start, words[last].end)
        draft.words = words[first...last].map(\.id)
    }

    func nearest(_ source: Double, indices: Range<Int>, edge: (Int) -> Double) -> Int? {
        indices.min { abs(clock.round(edge($0)) - source) < abs(clock.round(edge($1)) - source) }
    }

    func duplicateOffset(_ items: [TimelineEntry]) -> Double {
        let moving = items.filter(\.footage).map { clock.range($0.span.start, $0.span.end) }
        let occupied = project.media.footage.filter { $0.clipID == clock.scope }.map { clock.range($0.start, $0.end) }
        var delta = 0.0
        while true {
            var next = delta
            for span in moving {
                let candidate = clock.range(span.start + delta, span.end + delta)
                for other in occupied where StoryClips.overlaps(candidate, other) {
                    next = max(next, clock.round(other.end - span.start))
                }
            }
            if next <= delta { return delta }
            delta = next
        }
    }

    func checkFootageOverlap(_ item: TimelineEntry, _ span: TimeRange) throws {
        if project.media.footage.contains(where: { value in
            value.clipID == clock.scope && value.id != item.id.value &&
                StoryClips.overlaps(clock.range(value.start, value.end), span)
        }) { throw TimelineEditRefusal("Place it where no other recording plays.") }
    }

    func checkFootageOverlap() throws {
        let spans = project.media.footage.filter { $0.clipID == clock.scope }.sorted { $0.start < $1.start }
        if zip(spans, spans.dropFirst()).contains(where: { $0.end > $1.start }) {
            throw TimelineEditRefusal("Place it where no other recording plays.")
        }
    }

    func allIDs(_ id: TimelineItemID) -> [String] {
        switch id {
        case .effect: project.clipEffects.map(\.id)
        case .footage: project.media.footage.map(\.id)
        case .motion: project.motionCues.map(\.id)
        case .music: project.music.flatMap { track in track.segments?.map(\.id) ?? [track.id] }
        case .clip: project.edits.clips.map(\.id)
        case .part: project.edits.clips.flatMap { $0.playParts.map(\.id) }
        default: []
        }
    }

    func fresh(_ id: String, taken: [String]) -> String {
        let used = Set(taken)
        var index = 2
        while true {
            let suffix = "-\(index)"
            let candidate = String(id.prefix(64 - suffix.count)) + suffix
            if !used.contains(candidate) { return candidate }
            index += 1
        }
    }

    func segment(_ item: TimelineEntry) -> MusicSegment? {
        guard item.kind == "music", let track = project.music.first(where: { $0.clipId == clock.scope }) else { return nil }
        return track.segments?.first { $0.id == item.id.value } ?? (track.segments == nil ? clock.bed(track) : nil)
    }

    mutating func materialise(_ index: Int) throws {
        if project.music[index].segments == nil {
            guard let bed = clock.bed(project.music[index]), bed.lengthSeconds > 0.1 else { throw Self.invalid }
            project.music[index].segments = [bed]
        }
    }

    mutating func write(_ item: TimelineEntry, _ draft: Draft) throws {
        let id = draft.newID ?? item.id.value, append = draft.newID != nil
        switch item.id {
        case .effect(let original):
            guard let index = project.clipEffects.firstIndex(where: { $0.id == original }) else { throw Self.noItem }
            var value = project.clipEffects[index]
            value.id = id; value.start = draft.span.start; value.end = draft.span.end
            value.fadeInSeconds = draft.fadeIn ?? value.fadeInSeconds; value.fadeOutSeconds = draft.fadeOut ?? value.fadeOutSeconds
            value.gainDb = draft.gain ?? value.gainDb; value.mediaOffsetSeconds = draft.offset ?? value.mediaOffsetSeconds
            value.gainPoints = draft.points; value.wordIds = draft.words ?? value.wordIds
            if draft.trackShift != 0 {
                value.track = value.track?.map { .init(t: clock.round($0.t + draft.trackShift), rect: $0.rect) }
            }
            try ClipEffects.validate(value, projectId: project.id)
            if append {
                guard project.clipEffects.count < ClipEffect.maximumEntries else { throw Self.invalid }
                project.clipEffects.append(value)
            } else { project.clipEffects[index] = value }
        case .footage(let original):
            guard let index = project.media.footage.firstIndex(where: { $0.id == original }) else { throw Self.noItem }
            var value = project.media.footage[index]
            value.id = id; value.start = draft.span.start; value.end = draft.span.end
            value.footage.start = draft.offset ?? value.footage.start
            value.fadeInSeconds = draft.fadeIn ?? value.fadeInSeconds; value.fadeOutSeconds = draft.fadeOut ?? value.fadeOutSeconds
            if append { project.media.footage.append(value) } else { project.media.footage[index] = value }
        case .motion(let original):
            guard let index = project.motionCues.firstIndex(where: { $0.id == original }) else { throw Self.noItem }
            let cue = project.motionCues[index]
            let value = MotionCue(id: id, clipID: cue.clipID, sourceStart: draft.span.start, sourceEnd: draft.span.end, keyframes: draft.motion ?? cue.keyframes)
            guard value.sourceEnd == draft.span.end else { throw Self.invalid }
            if append {
                guard project.motionCues.filter({ $0.clipID == cue.clipID }).count < MotionCue.maximumCuesPerClip else { throw Self.invalid }
                project.motionCues.append(value)
            } else { project.motionCues[index] = value }
        case .music(let original):
            guard let track = project.music.firstIndex(where: { $0.clipId == clock.scope }) else { throw Self.noItem }
            try materialise(track)
            guard var segments = project.music[track].segments, let index = segments.firstIndex(where: { $0.id == original }) else { throw Self.noItem }
            var value = segments[index]
            value.id = id; value.anchorSeconds = draft.span.start; value.lengthSeconds = length(item, draft.span)
            value.songFromSeconds = draft.offset ?? value.songFromSeconds; value.loop = draft.loop ?? value.loop
            value.gainDb = draft.gain ?? value.gainDb; value.gainPoints = draft.points
            value.fadeInSeconds = draft.fadeIn ?? value.fadeInSeconds; value.fadeOutSeconds = draft.fadeOut ?? value.fadeOutSeconds
            if append {
                guard segments.count < ProjectMusic.maximumSegments else { throw TimelineEditRefusal("A track can have up to 8 segments.") }
                segments.append(value)
            } else { segments[index] = value }
            project.music[track].segments = segments
            try MusicProject.validate(project.music[track], projectId: project.id)
        default: throw Self.readOnly
        }
    }

    mutating func delete(_ item: TimelineEntry) throws {
        try requireEditable(item)
        switch item.id {
        case .effect(let id): project.clipEffects.removeAll { $0.id == id }
        case .footage(let id): project.media.footage.removeAll { $0.id == id }
        case .motion(let id): project.motionCues.removeAll { $0.id == id }
        case .music(let id):
            guard let index = project.music.firstIndex(where: { $0.clipId == clock.scope }) else { throw Self.noItem }
            let rest = project.music[index].segments?.filter { $0.id != id } ?? []
            if rest.isEmpty { project.music.remove(at: index) } else { project.music[index].segments = rest }
        default: throw Self.readOnly
        }
    }

    func checkSpeech(_ clip: ClipRange) throws {
        guard StoryClips.valid(clip, words: clock.words) else { throw Self.insidePart }
        let spans = StoryClips.times(clip, words: clock.words).map { clock.range($0.start, $0.end) }
        let windows = StoryClips.lipsyncWindows(project)
        if let refusal = StoryClips.lipsyncRefusal(spans, windows: windows) { throw TimelineEditRefusal(refusal) }
    }

    mutating func replaceSpeech(_ clip: ClipRange, preserving snapshot: Project? = nil) throws {
        if let index = project.edits.clips.firstIndex(where: { $0.id == clip.id }) {
            let original = project.edits.clips[index]
            let before = StoryClips.times(original, words: clock.words), after = StoryClips.times(clip, words: clock.words)
            let whole = project.voiceLab.wholeClipRevoices?.contains { $0.clipId == clip.id } == true
            let losesLipsync = StoryClips.lipsyncWindows(project).contains { window in
                before.contains { StoryClips.overlaps($0, window) } && !after.contains { StoryClips.overlaps($0, window) }
            }
            if clip.parts != nil, (whole && before != after) || losesLipsync {
                var copy = clip
                copy.id = fresh(clip.id + "-story", taken: allIDs(.clip("")))
                copy.title = String(((original.title ?? "Clip \(index + 1)") + " story").unicodeScalars.prefix(120))
                project = try copyScope(clip.id, to: copy, in: snapshot ?? project)
            } else { project.edits.clips[index] = clip }
        }
        else {
            guard project.edits.clips.count < 64 else { throw Self.invalid }
            project.edits.clips.append(clip)
            project.edits.activeClipId = clip.id
        }
    }

    func updateHull(_ clip: inout ClipRange, parts: [ClipPart]) throws {
        guard let ranges = StoryClips.indices(parts.map { ($0.startWordId, $0.endWordId) }, words: clock.words),
              let first = ranges.map(\.lowerBound).min(), let last = ranges.map(\.upperBound).max() else { throw Self.insidePart }
        if clip.playParts.first?.startWordId != parts.first?.startWordId { clip.leadInSeconds = nil }
        clip.parts = parts
        clip.startWordId = clock.words[first].id; clip.endWordId = clock.words[last].id
    }

    mutating func trimSpeech(_ item: TimelineEntry, edge: TimelineEdge, source: Double) throws -> String {
        guard var clip = clock.clip, let index = clip.playParts.firstIndex(where: { $0.id == item.id.value }),
              let range = clip.playPartIndices(in: clock.words)?[index],
              let word = nearest(source, indices: clock.words.indices, edge: { edge == .start ? clock.words[$0].start : clock.words[$0].end }) else { throw Self.noItem }
        guard edge == .start ? word <= range.upperBound : word >= range.lowerBound else { throw Self.insidePart }
        let id = clock.words[word].id
        if var parts = clip.parts {
            if edge == .start { parts[index].startWordId = id } else { parts[index].endWordId = id }
            try updateHull(&clip, parts: parts)
        } else if edge == .start {
            if clip.startWordId != id { clip.leadInSeconds = nil }
            clip.startWordId = id
        } else { clip.endWordId = id }
        try checkSpeech(clip); try replaceSpeech(clip)
        return clip.parts == nil ? "Trim clip" : "Trim part \(index + 1)"
    }

    mutating func movePart(_ id: String, to source: Double) throws -> String {
        guard var clip = clock.clip, var parts = clip.parts, let old = parts.firstIndex(where: { $0.id == id }),
              let destination = clock.part(at: source) ?? clock.parts.firstIndex(where: { $0.range.end == source }) else { throw Self.insidePart }
        let value = parts.remove(at: old)
        parts.insert(value, at: destination)
        try updateHull(&clip, parts: parts)
        try checkSpeech(clip); try replaceSpeech(clip)
        return "Move part"
    }

    func splitSpeech(at source: Double) throws -> (ClipRange, Double, Double) {
        let words = clock.words
        guard var clip = clock.clip, let index = clock.part(at: source), let range = clip.playPartIndices(in: words)?[index],
              range.lowerBound < range.upperBound else { throw Self.tooShort }
        var parts = clip.playParts
        guard parts.count < 12, let next = nearest(source, indices: (range.lowerBound + 1)..<(range.upperBound + 1),
                                                  edge: { (words[$0 - 1].end + words[$0].start) / 2 }) else { throw Self.tooShort }
        let part = parts[index]
        parts[index].endWordId = words[next - 1].id
        let partID = fresh(part.id, taken: allIDs(.part("")) + parts.map(\.id))
        parts.insert(ClipPart(id: partID, startWordId: words[next].id, endWordId: part.endWordId, reframe: part.reframe), at: index + 1)
        try updateHull(&clip, parts: parts)
        if clip.kind == nil { clip.kind = .story }
        let spans = StoryClips.times(clip, words: words)
        let end = clock.round(spans[index].end), start = clock.round(spans[index + 1].start)
        guard end <= start else { throw Self.insidePart }
        return (clip, end, start)
    }

    mutating func splitFullTake(at source: Double) throws -> String {
        guard let first = clock.words.first, let last = clock.words.last else { throw Self.tooShort }
        let clip = ClipRange(id: fresh("clip", taken: allIDs(.clip(""))), startWordId: first.id, endWordId: last.id)
        let basis = try copyScope(nil, to: clip, in: project)
        var reducer = TimelineReducer(basis, plan: clock.plan, scope: clip.id)
        let name = try reducer.apply(.splitAll(atSource: source))
        project = reducer.project
        return name
    }

    func copyScope(_ source: String?, to clip: ClipRange, in basis: Project) throws -> Project {
        var copy = basis
        guard copy.edits.clips.count < 64 else { throw Self.invalid }
        copy.edits.clips.append(clip)
        copy.edits.activeClipId = clip.id
        var ids = copy.clipEffects.map(\.id)
        for effect in project.clipEffects where effect.clipId == source && !effect.kind.isCensor {
            var duplicate = effect
            duplicate.id = fresh(effect.id, taken: ids)
            ids.append(duplicate.id)
            duplicate.clipId = clip.id
            copy.clipEffects.append(duplicate)
        }
        guard copy.clipEffects.count <= ClipEffect.maximumEntries else { throw Self.invalid }
        for footage in project.media.footage where footage.clipID == source {
            var duplicate = footage
            duplicate.id = fresh(footage.id, taken: copy.media.footage.map(\.id))
            duplicate.clipID = clip.id
            copy.media.footage.append(duplicate)
        }
        for cue in project.motionCues where cue.clipID == source {
            copy.motionCues.append(.init(id: fresh(cue.id, taken: copy.motionCues.map(\.id)), clipID: clip.id,
                                        sourceStart: cue.sourceStart, sourceEnd: cue.sourceEnd, keyframes: cue.keyframes))
        }
        if var track = project.music.first(where: { $0.clipId == source }) {
            track.id = fresh(track.id, taken: copy.music.map(\.id)); track.clipId = clip.id
            copy.music.append(track)
        }
        return copy
    }

    struct Draft {
        var span: TimeRange
        var offset: Double?
        var fadeIn: Double?
        var fadeOut: Double?
        var gain: Double?
        var loop: Bool?
        var points: [GainPoint]?
        var words: [String]?
        var motion: [MotionKeyframe]?
        var newID: String?
        var trackShift = 0.0

        init(_ item: TimelineEntry, clock: TimelineClock) {
            span = clock.range(item.span.start, item.span.end)
            points = item.points
        }

        mutating func setFade(_ edge: TimelineEdge, _ value: Double) {
            if edge == .start { fadeIn = value } else { fadeOut = value }
        }
    }
}
