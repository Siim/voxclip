import Foundation
import VoxClipCore
import VoxClipMedia

struct IllustrativeCutawaySelection: Equatable {
    static let maximumPromptBytes = 1_024
    let phrase: String
    let start: Double
    let duration: Double

    var end: Double { start + duration }

    var suggestedPrompt: String {
        "An illustrative cutaway, without text or logos, for the narration: \(phrase)"
    }

    static func reviewedPrompt(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= maximumPromptBytes,
              !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t" }) else { return nil }
        return trimmed
    }

    static func matching(project: Project, clipID: String?, selected: Set<String>, timeline: RenderTimeline,
                         document: ContextDemoDocument) throws -> Self {
        guard (1...30).contains(selected.count), let words = project.transcript?.words else {
            throw IllustrativeCutawayIssue.selection
        }
        let indices = words.indices.filter { selected.contains(words[$0].id) }
        guard indices.count == selected.count, let first = indices.first, let last = indices.last,
              last - first + 1 == indices.count else { throw IllustrativeCutawayIssue.selection }
        if let clipID {
            guard let clip = project.edits.clips.first(where: { $0.id == clipID }),
                  let clipStart = words.firstIndex(where: { $0.id == clip.startWordId }),
                  let clipEnd = words.firstIndex(where: { $0.id == clip.endWordId }),
                  clipStart <= first, last <= clipEnd else { throw IllustrativeCutawayIssue.selection }
        }
        let sourceStart = words[first].start, sourceEnd = words[last].end
        guard sourceStart.isFinite, sourceEnd.isFinite, sourceStart >= 0,
              sourceEnd > sourceStart, sourceEnd - sourceStart <= 12 else { throw IllustrativeCutawayIssue.selection }
        let sampleRate = timeline.sampleRate
        let firstSample = (timeline.mapTime(sourceStart) * sampleRate).rounded()
        let lastSample = (timeline.mapTime(sourceEnd) * sampleRate).rounded()
        let start = firstSample / sampleRate, end = lastSample / sampleRate
        let duration = (lastSample - firstSample) / sampleRate
        let tolerance = 1 / sampleRate
        let cutIDs = Set(project.edits.cutWordIds)
        let sourcePieces = document.narration.pieces.filter { !$0.synthetic && $0.source.start < sourceEnd && $0.source.end > sourceStart }
        guard start.isFinite, end.isFinite, start >= 0, end <= timeline.duration,
              (0.75...IllustrativeCutawayAssets.maximumSeconds).contains(duration),
              !document.narration.pieces.contains(where: { $0.synthetic && $0.output.start < end && $0.output.end > start }),
              words[first...last].allSatisfy({ word in
                  word.kind == .word && !cutIDs.contains(word.id) && word.start >= sourceStart && word.end <= sourceEnd
                      && word.end > word.start && sourcePieces.contains {
                          word.start >= $0.source.start - tolerance && word.end <= $0.source.end + tolerance
                      }
              }) else { throw IllustrativeCutawayIssue.selection }
        guard document.assets.count < 64, document.placements.count < 64,
              !document.placements.contains(where: { $0.editedStartSeconds < end && $0.editedEndSeconds > start }) else {
            throw IllustrativeCutawayIssue.occupied
        }
        let phrase = words[first...last].map { project.edits.corrections[$0.id] ?? $0.text }.joined(separator: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let result = Self(phrase: phrase, start: start, duration: duration)
        guard !phrase.isEmpty, reviewedPrompt(result.suggestedPrompt) != nil else { throw IllustrativeCutawayIssue.selection }
        return result
    }
}

enum IllustrativeCutawayIssue: LocalizedError, Equatable {
    case selection, occupied, stale, asset

    var errorDescription: String? {
        switch self {
        case .selection: "Select one continuous phrase of up to 30 kept source words, lasting 0.75–8 edited seconds and at most 12 source seconds."
        case .occupied: "Choose a phrase without an existing demonstration or illustration, or remove a placement to make room."
        case .stale: "The narration, selection or project changed. Review the phrase again. Your media and edits are safe."
        case .asset: "Couldn’t prepare a usable illustration. Your media and edits are safe."
        }
    }
}
