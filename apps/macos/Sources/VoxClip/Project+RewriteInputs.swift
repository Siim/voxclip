import Foundation
import VoxClipCore

extension Project {
    /// Inputs shared by opening, consent, edit following and successful-reply acceptance. The source transcript, media,
    /// pause settings and Voice Lab replacement segments remain; cuts, cut edges, corrections and clip bounds are scoped. A selection
    /// includes its enclosing clip's placement context and both edge pauses. Save metadata, tab/title, schema/extensions,
    /// captions/clip style/export/share, Motion, Demo and the Voice Lab asset/voice catalogs do not change a text proposal.
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
        project.clipControls = []
        project.captionTranslations = []
        project.contextDemo = nil
        project.edits.activeClipId = nil
        project.edits.clips = clip.map { [ClipRange(id: $0.id, startWordId: $0.startWordId, endWordId: $0.endWordId)] } ?? []
        project.edits.cutWordIds = edits.cutWordIds.filter { positions[$0].map(words.contains) ?? true }
        project.edits.cutPauseIds = edits.cutPauseIds.filter { id in
            pausePositions[id].map { $0 >= pauseLower && $0 <= pauseUpper } ?? true
        }
        project.edits.corrections = edits.corrections.filter { positions[$0.key].map(words.contains) ?? true }
        // A cut edge (editing §5.10) sits between word i−1 and word i, so it counts when either is in scope.
        project.edits.cutEdges = edits.cutEdges.filter { key, _ in
            positions[key].map { words.contains($0) || words.contains($0 - 1) } ?? true
        }
        project.captions = CaptionSettings()
        // The clip style (its caption picks, preset, music, shapes and tone) is read by a new run's instruction and by
        // Claude mode, never by an open proposal or its takes: Claude's caption picks are an edit outside the scope.
        project.clipStyle = nil
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

    /// What a Rewrite's paid voice work is made from (voice-lab.md, "What counts as an edit"): the voice takes, a whole
    /// clip's voice and a lip sync stay current while this is unchanged. It is `rewriteInputs` with the clean-audio choice
    /// kept, because clean audio changes the source a take is fitted to: the transcript, the media apart from its relative
    /// path, the scoped clip, cuts, pauses and corrections, the pause threshold and the Voice Lab segments. Save metadata
    /// (modifiedAt, savedBy, relativePath, title), the active tab, music, captions and the clip style, motion cues, clip
    /// controls and effects, export, share, the AI connector's results, the Voice Lab asset and voice catalogs and
    /// VoxClip's own speaking-rate samples are not part of it. Lip sync and takes never read clip controls, effects or
    /// music (LipsyncWindowPreparation.swift strips them from the lip-sync input). The chosen voice and model are checked
    /// beside it, by the plan. Windows has the same rule (`ProjectVoiceTakeIdentity`), replayed from
    /// shared/fixtures/voice-lab/voice-take-identity-cases.json.
    func voiceTakeIdentity(scope: RewriteScope, enclosingClipID: String?) -> Project {
        var project = rewriteInputs(scope: scope, enclosingClipID: enclosingClipID)
        // A project from before schema v3 has no clean-audio choice, which is clean audio off: the upgrade an edit such as
        // a colour makes (`ContextDemoProject.upgradeToV4`) writes it so.
        project.voiceLab.cleanAudio = voiceLab.cleanAudio ?? VoiceLabCleanAudio(mode: .off)
        return project
    }
}
