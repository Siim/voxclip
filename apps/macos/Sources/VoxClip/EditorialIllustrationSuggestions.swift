import Foundation
import VoxClipCore

struct EditorialIllustrationSuggestion: Identifiable, Equatable {
    var id: String { words[0].id }
    var wordIDs: Set<String> { Set(words.map(\.id)) }
    var quote: String { selection.phrase }
    let reason: String

    fileprivate let projectID: String
    fileprivate let sourceKey: String
    fileprivate let clipID: String
    fileprivate let words: [EditorialIllustrationSuggestions.Word]
    fileprivate let selection: IllustrativeCutawaySelection
    fileprivate let clipTime: TimeRange
}

enum EditorialIllustrationSuggestions {
    static func find(in project: Project, clipID: String) -> [EditorialIllustrationSuggestion] {
        guard let context = Context(project: project, clipID: clipID) else { return [] }
        var ranked: [(cue: Cue, suggestion: EditorialIllustrationSuggestion)] = []
        for span in context.beats() where (4...22).contains(span.count) {
            let words = context.words[span].map(context.word)
            guard let cue = cue(in: words.map(\.text)), let match = context.match(words) else { continue }
            ranked.append((cue, EditorialIllustrationSuggestion(reason: cue.reason, projectID: project.id,
                sourceKey: project.media.source.contentKey, clipID: clipID, words: words,
                selection: match.selection, clipTime: match.clipTime)))
        }
        var usedSubjects: Set<String> = []
        return ranked.sorted { lhs, rhs in
            if lhs.cue.isComparison != rhs.cue.isComparison { return lhs.cue.isComparison }
            return lhs.suggestion.clipTime.start < rhs.suggestion.clipTime.start
        }.filter { usedSubjects.insert($0.cue.subject).inserted }.prefix(2).map(\.suggestion)
            .sorted { $0.clipTime.start < $1.clipTime.start }
    }

    static func current(_ suggestions: [EditorialIllustrationSuggestion], in project: Project,
                        clipID: String) -> [EditorialIllustrationSuggestion] {
        guard !suggestions.isEmpty, let context = Context(project: project, clipID: clipID) else { return [] }
        return suggestions.filter { suggestion in
            suggestion.projectID == project.id && suggestion.sourceKey == project.media.source.contentKey
                && suggestion.clipID == clipID && context.stillMatches(suggestion)
        }
    }

    fileprivate struct Word: Equatable {
        let id: String
        let text: String
        let spokenText: String
        let start: Double
        let end: Double
    }

    private struct Context {
        let project: Project
        let clipID: String
        let words: [TimedWord]
        let clip: ClosedRange<Int>
        let timeline: RenderTimeline
        let document: ContextDemoDocument
        let clipTimeline: RenderTimeline
        let clipNarration: ContextDemoNarrationSnapshot
        let occupied: [TimeRange]

        init?(project: Project, clipID: String) {
            guard let transcript = project.transcript,
                  transcript.language.map({ $0.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first == "en" }) != false,
                  let range = project.edits.clips.first(where: { $0.id == clipID }),
                  let first = transcript.words.firstIndex(where: { $0.id == range.startWordId }),
                  let last = transcript.words.firstIndex(where: { $0.id == range.endWordId }), first <= last,
                  let timeline = try? RenderCallerInputs.timeline(project: project),
                  let clipTimeline = try? RenderCallerInputs.timeline(project: project, clipID: clipID),
                  let clipNarration = try? ContextDemoNarrationSnapshot(timeline: clipTimeline) else { return nil }
            if let existing = project.contextDemo {
                guard existing.isCurrent(project: project, timeline: timeline) else { return nil }
                document = existing
            } else {
                guard let draft = try? ContextDemoDocument(project: project, planId: "illustration-suggestions", timeline: timeline) else { return nil }
                document = draft
            }
            self.project = project; self.clipID = clipID; self.words = transcript.words; self.clip = first...last
            self.timeline = timeline; self.clipTimeline = clipTimeline; self.clipNarration = clipNarration
            self.occupied = project.motionCues.filter { $0.clipID == clipID }.map {
                TimeRange(start: $0.sourceStart, end: $0.sourceEnd)
            } + ClipEffects.rendered(in: project, clipID: clipID).filter { $0.kind != .sound }.map {
                TimeRange(start: $0.start, end: $0.end)
            }
        }

        func word(_ timed: TimedWord) -> Word {
            Word(id: timed.id, text: project.edits.corrections[timed.id] ?? timed.text, spokenText: timed.text,
                 start: timed.start, end: timed.end)
        }

        func beats() -> [Range<Int>] {
            var result: [Range<Int>] = []
            var start = clip.lowerBound
            for position in clip {
                let next = position + 1
                let text = word(words[position]).text.trimmingCharacters(in: Self.closingMarks)
                let sentence = text.last.map { ".!?…".contains($0) } == true
                if next > clip.upperBound || sentence || words[next].start - words[position].end >= 0.55 {
                    result.append(start..<next)
                    start = next
                }
            }
            return result
        }

        func stillMatches(_ stored: EditorialIllustrationSuggestion) -> Bool {
            guard let start = clip.first(where: { words[$0].id == stored.id }),
                  start + stored.words.count - 1 <= clip.upperBound else { return false }
            let span = start..<(start + stored.words.count)
            guard words[span].map(word) == stored.words, let match = match(stored.words) else { return false }
            return match.selection == stored.selection && match.clipTime == stored.clipTime
        }

        func match(_ selected: [Word]) -> (selection: IllustrativeCutawaySelection, clipTime: TimeRange)? {
            guard let first = selected.first, let last = selected.last,
                  !occupied.contains(where: { $0.start < last.end && $0.end > first.start }) else { return nil }
            let ids = Set(selected.map(\.id))
            guard ids.count == selected.count, let selection = try? IllustrativeCutawaySelection.matching(
                project: project, clipID: clipID, selected: ids, timeline: timeline, document: document) else { return nil }
            let rate = clipTimeline.sampleRate
            let start = (clipTimeline.mapTime(first.start) * rate).rounded() / rate
            let end = (clipTimeline.mapTime(last.end) * rate).rounded() / rate
            guard end > start, !clipNarration.pieces.contains(where: { $0.synthetic && $0.output.start < end && $0.output.end > start }),
                  selected.allSatisfy({ word in clipNarration.pieces.contains { !$0.synthetic
                      && word.start >= $0.source.start - 1 / rate && word.end <= $0.source.end + 1 / rate }
                  }) else { return nil }
            return (selection, TimeRange(start: start, end: end))
        }

        private static let closingMarks = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'”’)]}"))
    }

    private struct Cue {
        let subject: String
        let isComparison: Bool

        var reason: String {
            isComparison ? "The comparison gives viewers a concrete image to connect to the narration."
                         : "This describes a visible action an illustration could make easier to picture."
        }
    }

    private static func cue(in text: [String]) -> Cue? {
        guard !text.contains(where: { $0.contains("?") }) else { return nil }
        let tokens = text.map { $0.lowercased().trimmingCharacters(in: wordEdges).replacingOccurrences(of: "’", with: "'") }
        guard !tokens.contains(where: { $0.isEmpty || ["not", "never", "no"].contains($0) || $0.hasSuffix("n't") }) else { return nil }
        for position in tokens.indices.dropFirst() where tokens[position] == "like" && comparisons.contains(tokens[position - 1]) {
            let tail = tokens.dropFirst(position + 1).prefix(4)
            if let article = tail.first, ["a", "an", "the"].contains(article),
               let subject = tail.dropFirst().prefix(while: { !comparisonStops.contains($0) }).first(where: { subjects.contains($0) }) {
                return Cue(subject: subject, isComparison: true)
            }
        }
        for position in tokens.indices {
            let nearby = tokens.dropFirst(position + 1).prefix(4)
            for scene in scenes where scene.subjects.contains(tokens[position]) {
                if let action = nearby.first(where: { !sceneBridges.contains($0) }), scene.actions.contains(action) {
                    return Cue(subject: scene.subjects[0], isComparison: false)
                }
            }
        }
        return nil
    }

    private static let wordEdges = CharacterSet.letters.union(.decimalDigits).inverted
    private static let comparisons: Set<String> = ["looked", "looks", "felt", "feels", "flowed", "flows", "spread", "spreads",
        "moved", "moves", "landed", "lands", "rolled", "rolls", "hung", "hangs", "fell", "falls", "worked", "works"]
    private static let comparisonStops: Set<String> = ["a", "an", "the", "of", "to", "for", "in", "from", "and", "or", "but", "with"]
    private static let subjects: Set<String> = ["avalanche", "bridge", "campfire", "canyon", "caterpillar", "compass", "dam", "domino",
        "earthquake", "flood", "funnel", "glacier", "hourglass", "iceberg", "jigsaw", "kite", "labyrinth", "lighthouse", "magnet",
        "maze", "mirror", "parachute", "pendulum", "prism", "river", "rocket", "snowball", "sponge", "telescope", "tornado",
        "volcano", "waterfall", "wave", "whirlpool", "zipper"]
    private static let sceneBridges: Set<String> = ["had", "has", "have", "was", "were", "is", "are", "just", "then", "finally",
        "suddenly", "slowly", "steadily", "quickly"]
    private static let scenes: [(subjects: [String], actions: Set<String>)] = [
        (["wave", "waves"], ["crashed", "crashes", "breaks", "broke"]),
        (["volcano", "volcanoes"], ["erupts", "erupted", "erupting"]),
        (["bridge", "bridges"], ["collapsed", "collapses", "buckled", "buckles"]),
        (["river", "rivers"], ["overflowed", "overflows", "flooded", "floods"]),
        (["glacier", "glaciers"], ["melted", "melts", "retreated", "retreats"]),
        (["domino", "dominoes"], ["toppled", "topples", "tumbled", "tumbles"]),
        (["rocket", "rockets"], ["launched", "launches", "lifted", "lifts"]),
        (["gear", "gears"], ["meshed", "mesh", "meshes", "locked", "lock", "locks"]),
        (["ice", "snow"], ["melted", "melts", "cracked", "cracks"]),
    ]
}
