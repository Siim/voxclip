import Foundation

extension ClipRange {
    /// The inclusive transcript indices of each part, in play order; nil for invalid or overlapping ranges.
    public func playPartIndices(in words: [TimedWord]) -> [ClosedRange<Int>]? {
        StoryClips.indices(playParts.map { ($0.startWordId, $0.endWordId) }, words: words)
    }
}

enum StoryClips {
    static let maxTakeReasonScalars = 160
    static func indices(_ ranges: [(String, String)], words: [TimedWord]) -> [ClosedRange<Int>]? {
        let ids = Dictionary(words.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        let result = ranges.compactMap { start, end -> ClosedRange<Int>? in
            guard let lower = ids[start], let upper = ids[end], lower <= upper else { return nil }
            return lower...upper
        }
        let sorted = result.sorted { $0.lowerBound < $1.lowerBound }
        guard result.count == ranges.count, zip(sorted, sorted.dropFirst()).allSatisfy({ $0.upperBound < $1.lowerBound }) else { return nil }
        return result
    }

    static func valid(_ clip: ClipRange, words: [TimedWord]) -> Bool {
        guard let parts = clip.parts else { return clip.kind == nil }
        guard (2...12).contains(parts.count), Set(parts.map(\.id)).count == parts.count,
              parts.allSatisfy({ part in
                  guard ProjectValidation.matches(part.id, EditingLimits.clipIDPattern),
                        (part.takeReason?.unicodeScalars.count ?? 0) <= maxTakeReasonScalars else { return false }
                  guard let face = part.reframe else { return true }
                  return face.mode == ReframeSettings.faceMode && face.zoom == 1 &&
                      [face.centerX, face.centerY].allSatisfy { $0.map { (0...1).contains($0) } == true }
              }), let ranges = clip.playPartIndices(in: words),
              let first = ranges.map(\.lowerBound).min(), let last = ranges.map(\.upperBound).max() else { return false }
        return clip.startWordId == words[first].id && clip.endWordId == words[last].id
    }

    static func forWriting(_ project: Project) throws -> Project {
        guard (1...5).contains(project.schemaVersion) else { return project }
        if project.edits.clips.contains(where: { $0.parts != nil }) {
            var result = project.schemaVersion < 4 ? try ContextDemoProject.upgradeToV4(project) : project
            result.schemaVersion = 5
            return result
        }
        var result = project
        if result.schemaVersion == 5 { result.schemaVersion = 4 }
        for resultIndex in result.ai.results.indices {
            for clipIndex in result.ai.results[resultIndex].clips.indices {
                result.ai.results[resultIndex].clips[clipIndex].parts = nil
                result.ai.results[resultIndex].clips[clipIndex].notInTake = nil
            }
        }
        return result
    }

    static func validate(_ project: Project) throws {
        let clock = ProjectClock.build(project)
        let words = clock.words
        let stories = project.edits.clips.filter { $0.parts != nil }
        try ProjectValidation.require(project.schemaVersion >= 6 || (project.schemaVersion == 5) == !stories.isEmpty, "Invalid story clip project version")
        for clip in project.edits.clips {
            try ProjectValidation.require(valid(clip, words: words), "Invalid story clip parts or source hull")
            try ProjectValidation.require(project.media.spokenSources != nil || clip.playParts.allSatisfy { $0.takeReason == nil },
                                          "Version reasons require project version 7")
            if clock.regions.count > 1 {
                try ProjectValidation.require(clip.playParts.allSatisfy { clock.containsRange(startWordId: $0.startWordId, endWordId: $0.endWordId) }, "A part comes from one recording.")
            }
            if clip.parts != nil { try validatePlacement(clip, project: project, words: words) }
        }
        for clip in project.ai.results.flatMap(\.clips) {
            try ProjectValidation.text(clip.notInTake, max: 200)
            if let parts = clip.parts {
                let ranges = indices(parts.map { ($0.startWordId, $0.endWordId) }, words: words)
                try ProjectValidation.require((2...12).contains(parts.count) && ranges != nil, "Invalid AI clip parts")
                if clock.regions.count > 1 {
                    try ProjectValidation.require(parts.allSatisfy { clock.containsRange(startWordId: $0.startWordId, endWordId: $0.endWordId) }, "A part comes from one recording.")
                }
            }
        }
    }

    static func times(_ clip: ClipRange, words: [TimedWord]) -> [TimeRange] {
        (clip.playPartIndices(in: words) ?? []).enumerated().compactMap { index, range in
            try? clipTimes(words, startIndex: range.lowerBound, endIndex: range.upperBound, leadIn: index == 0 ? clip.leadInSeconds : nil)
        }
    }

    static func lipsyncWindows(_ project: Project) -> [TimeRange] {
        let rate = Double(project.media.source.audio?.sampleRate ?? 48_000)
        return project.voiceLab.segments.flatMap(\.candidates).compactMap { candidate in
            guard let video = candidate.recipe?.video, video.mode == .lipsync,
                  let start = video.windowStartSample, let end = video.windowEndSample, start < end else { return nil }
            return TimeRange(start: Double(start) / rate, end: Double(end) / rate)
        }
    }

    static func validatePlacement(_ clip: ClipRange, project: Project, words: [TimedWord]) throws {
        let spans = times(clip, words: words)
        var windows = lipsyncWindows(project)
        if RecordingEdits.isRecordingCopy(clip.id, project: project) {
            windows = windows.filter { window in spans.contains { contains($0, window) } }
        }
        if let refusal = lipsyncRefusal(spans, windows: windows) {
            throw VoxClipError.projectUnreadable(refusal)
        }
        guard project.schemaVersion < TimelineEditFields.version else { return }
        for effect in project.clipEffects where effect.clipId == clip.id {
            try ProjectValidation.require(spans.contains { contains($0, TimeRange(start: effect.start, end: effect.end)) }, "Place it inside one part.")
        }
    }

    static func lipsyncRefusal(_ spans: [TimeRange], windows: [TimeRange]) -> String? {
        for (index, span) in spans.enumerated() {
            for window in windows where overlaps(span, window) && !contains(span, window) {
                return "Part \(index + 1) cuts through a lip-synced stretch. Include all of \(clock(window.start))–\(clock(window.end)) or none of it."
            }
        }
        return nil
    }

    static func overlaps(_ span: TimeRange, _ window: TimeRange) -> Bool {
        span.start < window.end && window.start < span.end
    }

    static func contains(_ span: TimeRange, _ window: TimeRange) -> Bool {
        span.start <= window.start && window.end <= span.end
    }

    static func clock(_ seconds: Double) -> String {
        let whole = Int(seconds)
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}
