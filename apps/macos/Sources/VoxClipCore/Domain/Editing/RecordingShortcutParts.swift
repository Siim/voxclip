extension RecordingEdits {
    public static func placement(clipId: String, soloRun: TakeMatch.SoloRun, project: Project) -> String? {
        guard let after = soloRun.afterBeatId, let clip = project.edits.clips.first(where: { $0.id == clipId }) else { return nil }
        let clock = ProjectClock.build(project)
        guard let beat = TakeMatch.build(clock: clock).beats.first(where: { $0.id == after }),
              let line = ShortcutParts(clip: clip, clock: clock).currentLine(beat) else { return nil }
        return clock.words[line.range.upperBound].id
    }

    static func useVersion(clipId: String, beatId: String, key: String, project: Project) throws -> RecordingEditOutcome {
        var change = try shortcut(clipId, project: project)
        guard let beat = TakeMatch.build(clock: change.clock).beats.first(where: { $0.id == beatId }),
              let line = change.currentLine(beat) else { throw RecordingEditRefusal("That line isn't in the clip.") }
        guard line.key != key else { return .init(project, "Use version") }
        guard let span = beat.spans.first(where: { $0.fromKey == line.key && $0.toKey == key }) else {
            throw RecordingEditRefusal("Choose a version from another recording.")
        }
        let take = beat.takes.first { $0.key == key }
        let target = take.flatMap { change.range($0.startWordId, $0.endWordId) }
        let savedIndex = change.displacedVersions.lastIndex { saved in
            guard let target, let bounds = change.range(saved.startWordId, saved.endWordId) else { return false }
            return target.contains(bounds.lowerBound) && target.contains(bounds.upperBound)
        }
        let saved = savedIndex.map { change.displacedVersions.remove(at: $0) }
        change.displacedVersions.append(.init(startWordId: change.clock.words[line.range.lowerBound].id,
                                              endWordId: change.clock.words[line.range.upperBound].id))
        var replacement = change.parts[line.partIndex]
        replacement.startWordId = saved?.startWordId ?? span.startWordId
        replacement.endWordId = saved?.endWordId ?? span.endWordId
        replacement.takeReason = nil
        change.replace(line.partIndex, start: line.range.lowerBound, end: line.range.upperBound + 1, with: replacement, keepLeadingId: true)
        return try finishShortcut(change, project: project, name: "Use version")
    }

    static func insertShortcut(clipId: String, key: String, start: String, end: String, after: String?, project: Project) throws -> RecordingEditOutcome {
        var change = try shortcut(clipId, project: project)
        guard let first = change.positions[start], let last = change.positions[end], first <= last,
              change.clock.region(of: start)?.key == key, change.clock.region(of: end)?.key == key else {
            throw RecordingEditRefusal("Choose words from one recording.")
        }
        var inserted = ClipPart(id: change.nextID(), startWordId: start, endWordId: end)
        change.made.append(inserted.id)
        if let after {
            guard let position = change.positions[after], let index = change.parts.firstIndex(where: { change.range($0)?.contains(position) == true }) else {
                throw RecordingEditRefusal("That line isn't in the clip.")
            }
            if position + 1 == first, change.clock.region(of: after)?.key == key { inserted.reframe = change.parts[index].reframe }
            change.replace(index, start: position + 1, end: position + 1, with: inserted, keepLeadingId: false)
        } else if let before = change.parts.last {
            if change.positions[before.endWordId].map({ $0 + 1 == first }) == true, change.clock.region(of: before.endWordId)?.key == key {
                inserted.reframe = before.reframe
            }
            change.parts.append(inserted)
            change.touched.insert(inserted.id)
        }
        return try finishShortcut(change, project: project, name: "Add part")
    }

    private static func shortcut(_ clipId: String, project: Project) throws -> ShortcutParts {
        guard let clip = project.edits.clips.first(where: { $0.id == clipId }) else { throw RecordingEditRefusal("Choose a clip first.") }
        let change = ShortcutParts(clip: clip, clock: ProjectClock.build(project))
        guard clip.playPartIndices(in: change.clock.words) != nil else {
            throw RecordingEditRefusal("Choose non-overlapping parts in the clip's transcript.")
        }
        return change
    }

    private static func finishShortcut(_ proposed: ShortcutParts, project: Project, name: String) throws -> RecordingEditOutcome {
        var change = proposed
        change.join()
        let words = change.clock.words
        guard let state = try EditState(project: project), let first = change.parts.first,
              let ranges = StoryClips.indices(change.parts.map { ($0.startWordId, $0.endWordId) }, words: words),
              let start = ranges.map(\.lowerBound).min(), let end = ranges.map(\.upperBound).max() else {
            throw RecordingEditRefusal("Choose non-overlapping parts in the clip's transcript.")
        }
        var clip = change.clip
        clip.startWordId = words[start].id
        clip.endWordId = words[end].id
        clip.parts = change.parts.count > 1 ? change.parts : nil
        clip.kind = clip.parts == nil ? nil : clip.kind ?? .story
        if change.clip.playParts.first?.startWordId != first.startWordId { clip.leadInSeconds = nil }
        let applied: RecordingEditOutcome
        if needsPaidCopy(from: change.clip, to: clip, project: project, words: words) {
            applied = try addShortcutClip(clip, copyOf: change.clip, project: project, state: state, name: name)
        } else {
            applied = try changeParts(change.clip.id, project: project, name: name) { parts, _ in parts = change.parts }.get()
        }
        let clipId = applied.project.edits.clips.count > project.edits.clips.count ? applied.project.edits.clips.last!.id : change.clip.id
        var result = applied.project
        if let index = result.edits.clips.firstIndex(where: { $0.id == clipId }) {
            result.edits.clips[index].displacedVersions = change.displacedVersions.isEmpty ? nil : change.displacedVersions
        }
        return .init(result, name, applied.announcement,
                     details: .init(clipId: clipId, madePartIds: change.made, leftOut: [], splitPartId: change.split, joins: change.joins))
    }
}

private struct ShortcutParts {
    let clip: ClipRange
    let clock: ProjectClock
    let positions: [String: Int]
    var parts: [ClipPart]
    var displacedVersions: [ClipWordRange]
    var touched: Set<String> = []
    var made: [String] = []
    var joins: [RecordingPartJoin] = []
    private(set) var split: String?
    private var reserved: Set<String>

    init(clip: ClipRange, clock: ProjectClock) {
        self.clip = clip
        self.clock = clock
        self.positions = Dictionary(clock.words.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        self.parts = clip.playParts
        self.displacedVersions = clip.displacedVersions ?? []
        self.reserved = Set(clip.playParts.map(\.id))
    }

    func range(_ part: ClipPart) -> ClosedRange<Int>? { range(part.startWordId, part.endWordId) }

    func range(_ start: String, _ end: String) -> ClosedRange<Int>? {
        guard let first = positions[start], let last = positions[end], first <= last else { return nil }
        return first...last
    }

    func currentLine(_ beat: TakeMatch.Beat) -> (partIndex: Int, key: String, range: ClosedRange<Int>)? {
        for (index, part) in parts.enumerated() {
            guard let key = clock.region(of: part.startWordId)?.key, let bounds = range(part),
                  let take = beat.takes.first(where: { $0.key == key }) else { continue }
            if let full = range(take.startWordId, take.endWordId), bounds.contains(full.lowerBound), bounds.contains(full.upperBound) {
                return (index, key, full)
            }
            var aligned: ClosedRange<Int>?
            for span in beat.spans where span.toKey == key {
                if let match = range(span.startWordId, span.endWordId), bounds.contains(match.lowerBound), bounds.contains(match.upperBound),
                   match.count > (aligned?.count ?? 0) { aligned = match }
            }
            if let aligned { return (index, key, aligned) }
        }
        return nil
    }

    mutating func nextID() -> String {
        let id = RecordingEdits.freshID("part", reserved: reserved)
        reserved.insert(id)
        return id
    }

    mutating func replace(_ index: Int, start: Int, end: Int, with inserted: ClipPart, keepLeadingId: Bool) {
        let original = parts[index]
        guard let bounds = range(original) else { return }
        let before = bounds.lowerBound < start
        let after = end <= bounds.upperBound
        var replacement = inserted
        var fragments: [ClipPart] = []
        if before {
            var leading = original
            leading.endWordId = clock.words[start - 1].id
            fragments.append(leading)
            if keepLeadingId {
                replacement.id = nextID()
                made.append(replacement.id)
            }
        }
        fragments.append(replacement)
        if after {
            var following = original
            following.id = nextID()
            following.startWordId = clock.words[end].id
            fragments.append(following)
            made.append(following.id)
        }
        if after || (keepLeadingId && before) { split = original.id }
        parts.replaceSubrange(index...index, with: fragments)
        touched.formUnion(fragments.map(\.id))
    }

    mutating func join() {
        var index = 1
        while index < parts.count {
            let before = parts[index - 1], after = parts[index]
            if (touched.contains(before.id) || touched.contains(after.id)), before.reframe?.mode == after.reframe?.mode,
               clock.region(of: before.endWordId) == clock.region(of: after.startWordId),
               positions[before.endWordId].map({ $0 + 1 }) == positions[after.startWordId] {
                parts[index - 1].endWordId = after.endWordId
                parts.remove(at: index)
                touched.insert(before.id)
                joins.append(.init(keptPartId: before.id, removedPartId: after.id))
                index = max(1, index - 1)
            } else { index += 1 }
        }
    }
}
