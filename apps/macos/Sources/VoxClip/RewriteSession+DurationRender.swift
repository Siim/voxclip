import Foundation
import VoxClipCore
import VoxClipMedia

extension RewriteSession {
    func durationRenderPreparer() -> VideoDurationRenderPreparer {
        { [weak self] proposed, outputScope in
            guard let self, current, outputScope == scope else { throw VoiceLabProjectError.staleRenderContract }
            let original = editor.project
            guard proposed.id == original.id, proposed.media == original.media,
                  proposed.transcript == original.transcript else { throw VoiceLabProjectError.staleRenderContract }
            try Task.checkCancellation()
            guard let transcript = proposed.transcript else { throw VoiceLabProjectError.invalidSegment }
            let edits = proposed.edits
            let target: ExportTarget
            let clipID: String?
            switch outputScope {
            case .full: target = .fullEdit; clipID = nil
            case .clip(let id): target = .clip(id); clipID = id
            }
            let state = EditState(transcript: transcript,
                pauses: try detectPauses(transcript.words, thresholdSeconds: edits.pauseThresholdSeconds),
                pauseThresholdSeconds: edits.pauseThresholdSeconds, pauseKeepSeconds: edits.pauseKeepSeconds,
                cutWordIds: Set(edits.cutWordIds), cutPauseIds: Set(edits.cutPauseIds),
                corrections: edits.corrections, clips: edits.clips, activeClipId: clipID)
            let snapshot = EditorRenderSnapshot(project: proposed, state: state, plan: nil)
            let request = try await editor.renderRequest(target: target, snapshot: snapshot)
            try Task.checkCancellation()
            guard current, editor.project == original, request.voiceLab?.project == proposed,
                  request.voiceLab?.scope == outputScope else { throw VoiceLabProjectError.staleRenderContract }
            return request
        }
    }
}
