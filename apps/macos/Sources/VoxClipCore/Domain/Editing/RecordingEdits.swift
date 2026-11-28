import Foundation

public struct RecordingEditRefusal: Error, Equatable, Sendable, LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
    public init(_ message: String) { self.message = message }
}

public struct RecordingEditOutcome: Sendable {
    public let project: Project
    public let undoName: String
    public let announcement: String?
    public let details: RecordingEditDetails?
    public internal(set) var undoStep: RecordingEditStep?

    init(_ project: Project, _ undoName: String, _ announcement: String? = nil, details: RecordingEditDetails? = nil) {
        self.project = project
        self.undoName = undoName
        self.announcement = announcement
        self.details = details
    }
}

public struct RecordingEditStep: Sendable {
    public let name: String
    public let before: Project
    public let after: Project
}

public struct RecordingEditDetails: Sendable {
    public let clipId: String
    public let madePartIds: [String]
    public let leftOut: [TakeMatch.Take]
    public internal(set) var splitPartId: String? = nil
    public internal(set) var joins: [RecordingPartJoin] = []
}

public struct RecordingPartJoin: Equatable, Sendable {
    public let keptPartId: String
    public let removedPartId: String
}

public enum RecordingEdits {
    private static let prefixHighWater = "com.voxclip.spoken-prefix-high-water"
    private static let copyOrigins = "com.voxclip.recording-copy-origins"

    public static func apply(_ edit: RecordingEdit, project: Project)
        -> Result<RecordingEditOutcome, RecordingEditRefusal> {
        reduce(edit, project: project).map { applied in
            var result = applied
            if result.project != project {
                result.undoStep = .init(name: result.undoName, before: project, after: result.project)
            }
            return result
        }
    }

    private static func reduce(_ edit: RecordingEdit, project: Project) -> Result<RecordingEditOutcome, RecordingEditRefusal> {
        do {
            switch edit {
            case let .addSpokenSource(key, label, transcript, gain):
                return .success(.init(try adding(key, label: label, transcript: transcript, gain: gain, project: project), "Add recording"))
            case let .removeSpokenSource(key):
                return .success(.init(try removing(key, project: project), "Remove recording"))
            case let .startFromRecording(key):
                return .success(try start(key, project: project))
            case let .useLineVersion(clipId, beatId, key):
                return .success(try useVersion(clipId: clipId, beatId: beatId, key: key, project: project))
            case let .insertLine(clipId, key, start, end, after):
                return .success(try insertShortcut(clipId: clipId, key: key, start: start, end: end, after: after, project: project))
            case let .addPart(clipId, part, after):
                return try changeParts(clipId, project: project, name: "Add part") { parts, _ in
                    let end = parts.count
                    try insert(part, after: after, into: &parts, defaultIndex: end)
                }
            case let .movePart(clipId, partId, after):
                return try changeParts(clipId, project: project, name: "Move part") { parts, _ in
                    let index = try partIndex(partId, in: parts)
                    guard after != partId else { return }
                    let part = parts.remove(at: index)
                    try insert(part, after: after, into: &parts, defaultIndex: 0)
                }
            case let .removePart(clipId, partId):
                return try changeParts(clipId, project: project, name: "Remove part") { parts, _ in
                    guard parts.count > 1 else { throw RecordingEditRefusal("Keep at least one part in the clip.") }
                    let index = try partIndex(partId, in: parts)
                    parts.remove(at: index)
                }
            case let .trimPart(clipId, partId, start, end):
                return try changeParts(clipId, project: project, name: "Trim part") { parts, clock in
                    let index = try partIndex(partId, in: parts)
                    guard clock.region(of: parts[index].startWordId) == clock.region(of: start) else {
                        throw RecordingEditRefusal("Trim the part within its recording.")
                    }
                    parts[index].startWordId = start; parts[index].endWordId = end
                }
            case let .swapTake(clipId, partId, start, end, reason):
                return try changeParts(clipId, project: project, name: "Use version") { parts, clock in
                    let index = try partIndex(partId, in: parts)
                    guard let region = clock.region(of: start), region != clock.region(of: parts[index].startWordId) else {
                        throw RecordingEditRefusal("Choose a version from another recording.")
                    }
                    parts[index].startWordId = start; parts[index].endWordId = end; parts[index].takeReason = reason
                }
            }
        } catch let refusal as RecordingEditRefusal {
            return .failure(refusal)
        } catch VoxClipError.projectUnreadable(let reason) {
            return .failure(.init(reason))
        } catch {
            return .failure(.init("This edit would make the recording or part invalid."))
        }
    }

    private static func start(_ key: String, project: Project) throws -> RecordingEditOutcome {
        guard let state = try EditState(project: project), state.clips.count < 64 else {
            throw RecordingEditRefusal("Choose a spoken recording with words and room for another clip.")
        }
        let clock = state.projectClock ?? ProjectClock.build(project)
        let takes = TakeMatch.build(clock: clock).beats.flatMap(\.takes).filter { $0.key == key }
        let leftOut = takes.filter { $0.flags.contains("restart") || $0.flags.contains("falseStart") }
        let omitted = Set(leftOut.map(\.startWordId))
        let id = freshID("recording-clip", reserved: Set(state.clips.map(\.id)))
        var parts: [ClipPart] = []
        var separated = true
        for take in takes {
            if omitted.contains(take.startWordId) { separated = true; continue }
            if separated {
                let partId = parts.isEmpty ? id : "part-\(parts.count + 1)"
                parts.append(ClipPart(id: partId, startWordId: take.startWordId, endWordId: take.endWordId))
            } else {
                parts[parts.count - 1].endWordId = take.endWordId
            }
            separated = false
        }
        guard let first = parts.first, let last = parts.last,
              let ranges = StoryClips.indices(parts.map { ($0.startWordId, $0.endWordId) }, words: clock.words) else {
            throw RecordingEditRefusal("Choose a spoken recording with a line to keep.")
        }
        let title = EditingAlgorithms.clipTitle(ranges.lazy.flatMap { $0 }.map { state.textOf(clock.words[$0]) })
        let clip = ClipRange(id: id, startWordId: first.startWordId, endWordId: last.endWordId, title: title,
                             parts: parts.count > 1 ? parts : nil, kind: parts.count > 1 ? .story : nil)
        let original = state.activeClip.flatMap { needsPaidCopy(from: $0, to: clip, project: project, words: clock.words) ? $0 : nil }
        let applied = try addShortcutClip(clip, copyOf: original, project: project, state: state, name: "Start from recording")
        let added = applied.project.edits.clips.last!
        return .init(applied.project, applied.undoName, applied.announcement,
                     details: .init(clipId: added.id, madePartIds: added.playParts.map(\.id), leftOut: leftOut))
    }

    static func freshID(_ base: String, reserved: Set<String>) -> String {
        var number = 1
        while true {
            let suffix = number == 1 ? "" : "-\(number)"
            let id = String(base.prefix(64 - suffix.count)) + suffix
            if !reserved.contains(id) { return id }
            number += 1
        }
    }

    static func needsPaidCopy(from original: ClipRange, to changed: ClipRange, project: Project, words: [TimedWord]) -> Bool {
        let before = StoryClips.times(original, words: words)
        let after = StoryClips.times(changed, words: words)
        if before != after, project.voiceLab.wholeClipRevoices?.contains(where: { $0.clipId == original.id }) == true { return true }
        let protected = protectedSpans(for: original.id, project: project, words: words)
        return StoryClips.lipsyncWindows(project).contains { window in
            before.contains { StoryClips.contains($0, window) } && !after.contains { StoryClips.contains($0, window) } &&
                !protected.contains { StoryClips.contains($0, window) }
        }
    }

    static func addShortcutClip(_ proposed: ClipRange, copyOf original: ClipRange?, project: Project, state: EditState,
                                name: String) throws -> RecordingEditOutcome {
        guard state.clips.count < 64 else { throw RecordingEditRefusal("There isn't room for another clip.") }
        var clip = proposed, result = project
        var announcement: String?
        if let original, let index = state.clips.firstIndex(where: { $0.id == original.id }) {
            clip.id = freshID(String(original.id.prefix(59)) + "-copy", reserved: Set(state.clips.map(\.id)))
            let title = original.title ?? "Clip \(index + 1)"
            clip.title = String(title.unicodeScalars.prefix(EditingLimits.maxClipTitleScalars - 5)) + " copy"
            recordCopy(clip.id, of: original.id, in: &result)
            announcement = "Made \(clip.title!) to keep the paid voice work."
        }
        let added = try reduceEditingState(state, command: .addClip(clip), aiResults: project.ai.results, project: result)
        guard added.clips.count > state.clips.count else { throw RecordingEditRefusal("Choose up to 12 non-overlapping parts in the clip's transcript.") }
        result.edits = try reduceEditingState(added, command: .setActiveClip(clipId: clip.id)).projectEdits
        return .init(try ProjectMigrations.forWriting(result), name, announcement)
    }

    private static func adding(_ key: String, label: String?, transcript: Transcript, gain: Double?, project: Project) throws -> Project {
        var result = project
        var sources = project.media.spokenSources ?? []
        guard key != project.media.source.contentKey, !sources.contains(where: { $0.sourceKey == key }),
              project.media.additionalSources.contains(where: { $0.contentKey == key }) else {
            throw RecordingEditRefusal("Choose a companion that isn't already a spoken recording.")
        }
        guard sources.count < 5 else { throw RecordingEditRefusal("A project can have up to six spoken recordings.") }
        let previousEnd: Double
        if let last = sources.last, let reference = project.media.additionalSources.first(where: { $0.contentKey == last.sourceKey }) {
            previousEnd = Double(last.offsetSeconds) + reference.durationSeconds
        } else {
            previousEnd = project.media.source.durationSeconds
        }
        guard let offset = Int32(exactly: ceil(previousEnd) + 1), highestPrefix(project) < Int(Int32.max) else {
            throw RecordingEditRefusal("This recording can't fit on the project clock.")
        }
        sources.append(SpokenSource(sourceKey: key, label: label, offsetSeconds: Int(offset), wordIdPrefix: "r\(highestPrefix(project) + 1).",
                                    gainDb: gain, transcript: transcript))
        result.media.spokenSources = sources
        result = try ProjectMigrations.forWriting(result)
        _ = try ProjectJSON.encode(result)
        return result
    }

    private static func removing(_ key: String, project: Project) throws -> Project {
        let clock = ProjectClock.build(project)
        guard var sources = project.media.spokenSources, let index = sources.firstIndex(where: { $0.sourceKey == key }),
              let region = clock.regions.first(where: { $0.key == key }) else { throw RecordingEditRefusal("Choose a companion spoken recording.") }
        let ids = Set(sources[index].transcript.words.map { region.prefix + $0.id })
        func uses(_ start: String, _ end: String) -> Bool { ids.contains(start) || ids.contains(end) }
        let start = Double(region.offsetSamples) / Double(clock.sampleRate)
        let end = Double(region.endSample) / Double(clock.sampleRate)
        func overlaps(_ from: Double, _ to: Double) -> Bool { from < end && start < to }
        for (index, clip) in project.edits.clips.enumerated() {
            let count = clip.playParts.count { uses($0.startWordId, $0.endWordId) }
            if count > 0 {
                let title = clip.title ?? "Clip \(index + 1)"
                let parts = count == 1 ? "1 part" : "\(count) parts"
                let instruction = count == 1 ? "Remove that part first." : "Remove those parts first."
                throw RecordingEditRefusal("\(title) uses \(parts) from \(region.label). \(instruction)")
            }
        }
        let pauseIDs = try Set(clock.pauses(thresholdSeconds: project.edits.pauseThresholdSeconds)
            .filter { ids.contains(clock.words[$0.afterIndex].id) }.map(\.id))
        let edits = project.edits
        let referenced = edits.cutWordIds.contains(where: ids.contains) || edits.corrections.keys.contains(where: ids.contains) ||
            edits.cutPauseIds.contains(where: pauseIDs.contains) || project.ai.results.flatMap(\.clips).contains { clip in
                uses(clip.startWordId, clip.endWordId) || (clip.parts ?? []).contains { uses($0.startWordId, $0.endWordId) }
            }
        let anchored = project.captionTranslations.contains { uses($0.startWordId, $0.endWordId) } ||
            project.clipEffects.contains { overlaps($0.start, $0.end) || ($0.wordIds ?? []).contains(where: ids.contains) } ||
            project.media.footage.contains { overlaps($0.start, $0.end) } ||
            project.motionCues.contains { overlaps($0.sourceStart, $0.sourceEnd) } ||
            project.voiceLab.segments.contains { overlaps($0.replace.start, $0.replace.end) } ||
            project.music.flatMap { $0.segments ?? [] }.contains { start <= $0.anchorSeconds && $0.anchorSeconds < end }
        guard !referenced, !anchored else { throw RecordingEditRefusal("\(region.label) is used by edits or items. Remove them first.") }
        var result = project
        var extensions = result.extensions ?? [:]
        extensions[prefixHighWater] = .number(Double(highestPrefix(project)))
        result.extensions = extensions
        sources.remove(at: index)
        result.media.spokenSources = sources.isEmpty ? nil : sources
        for index in result.edits.clips.indices {
            let retained = result.edits.clips[index].displacedVersions?.filter { !uses($0.startWordId, $0.endWordId) }
            result.edits.clips[index].displacedVersions = !sources.isEmpty && retained?.isEmpty == false ? retained : nil
        }
        if sources.isEmpty {
            result.schemaVersion = TimelineEditFields.version
            for index in result.edits.clips.indices {
                guard let parts = result.edits.clips[index].parts else { continue }
                result.edits.clips[index].parts = parts.map { part in
                    var retained = part
                    retained.takeReason = nil
                    return retained
                }
            }
        }
        return result
    }

    private static func highestPrefix(_ project: Project) -> Int {
        let active = project.media.spokenSources?.compactMap { ProjectClock.prefixNumber($0.wordIdPrefix) }.max() ?? 1
        guard case .number(let value) = project.extensions?[prefixHighWater], let reserved = Int32(exactly: value) else { return active }
        return max(active, Int(reserved))
    }

    static func changeParts(_ id: String, project: Project, name: String,
                                    change: (inout [ClipPart], ProjectClock) throws -> Void)
        throws -> Result<RecordingEditOutcome, RecordingEditRefusal> {
        guard let state = try EditState(project: project), let clip = state.clips.first(where: { $0.id == id }) else {
            throw RecordingEditRefusal("Choose a clip first.")
        }
        let clock = state.projectClock ?? ProjectClock.build(project)
        var parts = clip.playParts
        try change(&parts, clock)
        guard parts != clip.playParts else { return .success(.init(project, name)) }
        guard parts.allSatisfy({ clock.containsRange(startWordId: $0.startWordId, endWordId: $0.endWordId) }) else {
            throw RecordingEditRefusal("A part comes from one recording.")
        }
        let changed = try reduceEditingState(state, command: .setClipParts(id: id, parts: parts), aiResults: project.ai.results,
                                             project: project, copySuffix: "copy")
        guard changed != state else { throw RecordingEditRefusal("Choose non-overlapping parts in the clip's transcript.") }
        var result = project
        result.edits = changed.projectEdits
        var announcement: String?
        if changed.clips.count > state.clips.count, let copy = changed.clips.last {
            recordCopy(copy.id, of: id, in: &result)
            announcement = "Made \(copy.title ?? "a copy") to keep the paid voice work."
        }
        return .success(.init(try ProjectMigrations.forWriting(result), name, announcement))
    }

    private static func partIndex(_ id: String, in parts: [ClipPart]) throws -> Int {
        guard let index = parts.firstIndex(where: { $0.id == id }) else { throw RecordingEditRefusal("That part isn't in the clip.") }
        return index
    }

    private static func insert(_ part: ClipPart, after id: String?, into parts: inout [ClipPart], defaultIndex: Int) throws {
        let index = try id.map { try partIndex($0, in: parts) + 1 } ?? defaultIndex
        parts.insert(part, at: index)
    }

    static func recordCopy(_ copy: String, of original: String, in project: inout Project) {
        var extensions = project.extensions ?? [:]
        var origins = extensions[copyOrigins]?.aiObject ?? [:]
        origins[copy] = .string(original)
        extensions[copyOrigins] = .object(origins)
        project.extensions = extensions
    }

    static func protectedSpans(for copy: String, project: Project, words: [TimedWord]) -> [TimeRange] {
        guard let id = project.extensions?[copyOrigins]?.aiObject?[copy]?.aiString,
              let original = project.edits.clips.first(where: { $0.id == id }) else { return [] }
        return StoryClips.times(original, words: words)
    }

    static func isRecordingCopy(_ id: String, project: Project) -> Bool {
        project.extensions?[copyOrigins]?.aiObject?[id]?.aiString != nil
    }
}
