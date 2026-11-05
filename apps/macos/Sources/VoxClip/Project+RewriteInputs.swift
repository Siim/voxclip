import Foundation
import VoxClipCore

extension Project {
    /// Inputs shared by opening, consent, edit following and successful-reply acceptance. The source transcript, media,
    /// pause settings and Voice Lab replacement segments remain; cuts, corrections and clip bounds are scoped. A selection
    /// includes its enclosing clip's placement context and both edge pauses. Save metadata, tab/title, schema/extensions,
    /// captions/export/share, Motion, Demo and the Voice Lab asset/voice catalogs do not change a text proposal.
    func rewriteInputs(scope: RewriteScope, enclosingClipID: String?) -> Project {
        let transcriptWords = transcript?.words ?? []
        let positions = Dictionary(uniqueKeysWithValues: transcriptWords.enumerated().map { ($0.element.id, $0.offset) })
        let clipID: String? = if case .clip(let id) = scope { id } else { enclosingClipID }
        let clip = edits.clips.first { $0.id == clipID }
        let clipBounds: ClosedRange<Int>?
        if let clip, let lower = positions[clip.startWordId], let upper = positions[clip.endWordId], lower <= upper {
            clipBounds = lower...upper
        } else {
            clipBounds = nil
        }
        let words: ClosedRange<Int>
        let includesEdgePauses: Bool
        switch scope {
        case .fullTake:
            words = 0...max(0, transcriptWords.count - 1)
            includesEdgePauses = false
        case .clip:
            words = clipBounds ?? 0...0
            includesEdgePauses = false
        case .selection(let selection):
            words = clipBounds.map { min(selection.lowerBound, $0.lowerBound)...max(selection.upperBound, $0.upperBound) } ?? selection
            includesEdgePauses = true
        }
        let pauses = (try? detectPauses(transcriptWords, thresholdSeconds: edits.pauseThresholdSeconds)) ?? []
        let pausePositions = Dictionary(uniqueKeysWithValues: pauses.map { ($0.id, $0.afterIndex) })
        let pauseLower = includesEdgePauses ? max(0, words.lowerBound - 1) : words.lowerBound
        let pauseUpper = includesEdgePauses ? words.upperBound : words.upperBound - 1
        var project = self
        project.modifiedAt = .distantPast
        project.savedBy = ProjectWriter(version: "0.0.0")
        project.media.source.relativePath = nil
        project.title = nil
        project.schemaVersion = 1
        project.extensions = nil
        project.motionCues = []
        project.music = []
        project.clipEffects = []
        project.contextDemo = nil
        project.edits.activeClipId = nil
        project.edits.clips = clip.map { [ClipRange(id: $0.id, startWordId: $0.startWordId, endWordId: $0.endWordId)] } ?? []
        project.edits.cutWordIds = edits.cutWordIds.filter { positions[$0].map(words.contains) ?? true }
        project.edits.cutPauseIds = edits.cutPauseIds.filter { id in
            pausePositions[id].map { $0 >= pauseLower && $0 <= pauseUpper } ?? true
        }
        project.edits.corrections = edits.corrections.filter { positions[$0.key].map(words.contains) ?? true }
        project.captions = CaptionSettings()
        project.export = ProjectExport()
        project.share = ProjectShare()
        project.ai = ProjectAI()
        project.voiceLab.assets = nil
        project.voiceLab.cleanAudio = nil
        project.voiceLab.videoAssets = nil
        project.voiceLab.voices = nil
        project.voiceLab.speakingRateSamples = nil
        return project
    }
}
