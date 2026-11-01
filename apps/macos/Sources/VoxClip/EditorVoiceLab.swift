import VoxClipCore

extension EditorModel {
    /// Compatibility seam for the passage workflow. A review with several takes uses the scoped list overload below.
    func applyVoiceLab(_ command: VoiceLabEditCommand, localCommands: [EditCommand] = []) throws {
        if case .acceptAll = command { throw VoiceLabProjectError.invalidSegment }
        let output = project.edits.activeClipId.map(VoiceLabOutputScope.clip) ?? .full
        try applyVoiceLab(command, localCommands: localCommands, outputScope: output, name: command.actionName)
    }

    /// Commits all included takes, cuts and fixes through one native project-snapshot undo transaction.
    func applyVoiceLab(_ segments: [VoiceLabSegment], assets: [VoiceLabAsset], voice: VoiceLabVoiceReference,
                      scope: RewriteScope, localCommands: [EditCommand] = []) throws {
        let output: VoiceLabOutputScope
        let words: DirectorScope
        switch scope {
        case .clip(let id):
            guard let number = clipNumber(id) else { throw VoiceLabProjectError.invalidScope }
            output = .clip(id)
            words = DirectorScope(kind: .clip(number: number), wordCount: 0)
        case .fullTake:
            output = .full
            words = DirectorScope(kind: .fullTake, wordCount: 0)
        case .selection(let range):
            guard let transcript = project.transcript, range.lowerBound >= 0, range.upperBound < transcript.words.count else {
                throw VoiceLabProjectError.invalidScope
            }
            output = project.edits.activeClipId.map(VoiceLabOutputScope.clip) ?? .full
            let count = transcript.words[range].filter { $0.kind == .word }.count
            words = DirectorScope(kind: .selection(inClip: project.edits.activeClipId != nil), wordCount: count)
        }
        try applyVoiceLab(.acceptAll(segments: segments, assets: assets, voice: voice), localCommands: localCommands,
                          outputScope: output, name: words.title)
    }

    private func applyVoiceLab(_ command: VoiceLabEditCommand, localCommands: [EditCommand],
                               outputScope: VoiceLabOutputScope, name: String) throws {
        guard app.voiceLabRewriteEnabled, capabilities.edit, !capabilities.exporting, !capabilities.aiBusy else { throw VoiceLabProjectError.invalidSegment }
        var changed = try voiceLabReviewProject(localCommands: localCommands)
        changed = try command.applying(to: changed, outputScope: outputScope)
        replace(changed, name: name)
    }

    /// The passage quote and single acceptance both use the review after its local edits, in the active output scope.
    func validateVoiceLabPlacement(_ window: VoiceLabWindow, localCommands: [EditCommand] = []) throws {
        let output = project.edits.activeClipId.map(VoiceLabOutputScope.clip) ?? .full
        try VoiceLabRenderContract.validatePlacement(voiceLabReviewProject(localCommands: localCommands), scope: output, window: window)
    }

    private func voiceLabReviewProject(localCommands: [EditCommand]) throws -> Project {
        var changed = project
        if !localCommands.isEmpty {
            guard var state = editState() else { throw VoiceLabProjectError.invalidSegment }
            for local in localCommands { state = EditReducer.reduce(state, command: local, aiResults: changed.ai.results) }
            changed.edits = state.projectEdits
        }
        return changed
    }
}
