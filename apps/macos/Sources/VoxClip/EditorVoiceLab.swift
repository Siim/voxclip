import VoxClipCore

extension EditorModel {
    /// Compatibility seam for the passage workflow. A review with several takes uses the scoped list overload below.
    func applyVoiceLab(_ command: VoiceLabEditCommand, localCommands: [EditCommand] = []) throws {
        if case .acceptAll = command { throw VoiceLabProjectError.invalidSegment }
        let output = project.edits.activeClipId.map(VoiceLabOutputScope.clip) ?? .full
        try applyVoiceLab(command, localCommands: localCommands, outputScope: output, name: command.actionName)
    }

    /// Commits all included takes, cuts and fixes through one native project-snapshot undo transaction.
    func applyVoiceLab(_ segments: [VoiceLabSegment], assets: [VoiceLabAsset], voice: VoiceLabVoiceReference?,
                      scope: RewriteScope, localCommands: [EditCommand] = [], videoAssets: [VoiceLabVideoAsset] = [],
                      wholeClip: WholeClipRevoiceRecord? = nil) throws {
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
        var changed = try changedByVoiceLab(.acceptAll(segments: segments, assets: assets, voice: voice), localCommands: localCommands,
                                            outputScope: output, videoAssets: videoAssets)
        // A whole-clip revoice's record goes in with its segments, in the same undo step (ADR-R46).
        if let wholeClip {
            changed.voiceLab.wholeClipRevoices = (changed.voiceLab.wholeClipRevoices ?? []) + [wholeClip]
            try VoiceLabProject.validate(changed)
        }
        replace(changed, name: wholeClip == nil ? words.title : "Revoice Whole Clip")
    }

    /// Whether these takes would go into the project as Use puts them, without changing it: how Use finds the phrase
    /// whose take can't (`RewriteSession.unusablePhrases`).
    func acceptsVoiceLab(_ segments: [VoiceLabSegment], assets: [VoiceLabAsset], voice: VoiceLabVoiceReference?,
                         scope: RewriteScope, localCommands: [EditCommand] = [], videoAssets: [VoiceLabVideoAsset] = []) -> Bool {
        let output: VoiceLabOutputScope
        switch scope {
        case .clip(let id): output = .clip(id)
        case .fullTake: output = .full
        case .selection: output = project.edits.activeClipId.map(VoiceLabOutputScope.clip) ?? .full
        }
        return (try? changedByVoiceLab(.acceptAll(segments: segments, assets: assets, voice: voice), localCommands: localCommands,
                                       outputScope: output, videoAssets: videoAssets)) != nil
    }

    private func applyVoiceLab(_ command: VoiceLabEditCommand, localCommands: [EditCommand],
                               outputScope: VoiceLabOutputScope, name: String, videoAssets: [VoiceLabVideoAsset] = []) throws {
        replace(try changedByVoiceLab(command, localCommands: localCommands, outputScope: outputScope, videoAssets: videoAssets), name: name)
    }
    private func changedByVoiceLab(_ command: VoiceLabEditCommand, localCommands: [EditCommand],
                                   outputScope: VoiceLabOutputScope, videoAssets: [VoiceLabVideoAsset]) throws -> Project {
        guard app.voiceLabRewriteEnabled, capabilities.edit, !capabilities.exporting, !capabilities.aiBusy else { throw VoiceLabProjectError.invalidSegment }
        let changed = try voiceLabReviewProject(localCommands: localCommands)
        return try command.applying(to: changed, outputScope: outputScope, videoAssets: videoAssets)
    }

    /// The passage quote and single acceptance both use the review after its local edits, in the active output scope.
    func validateVoiceLabPlacement(_ window: VoiceLabWindow, localCommands: [EditCommand] = []) throws {
        let output = project.edits.activeClipId.map(VoiceLabOutputScope.clip) ?? .full
        try VoiceLabRenderContract.validatePlacement(voiceLabReviewProject(localCommands: localCommands), scope: output, window: window)
    }

    func voiceLabReviewProject(localCommands: [EditCommand]) throws -> Project {
        var changed = project
        if !localCommands.isEmpty {
            guard var state = editState() else { throw VoiceLabProjectError.invalidSegment }
            for local in localCommands { state = EditReducer.reduce(state, command: local, aiResults: changed.ai.results) }
            changed.edits = state.projectEdits
        }
        return changed
    }
}
