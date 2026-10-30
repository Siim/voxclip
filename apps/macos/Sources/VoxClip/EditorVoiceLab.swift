import VoxClipCore

extension EditorModel {
    func applyVoiceLab(_ command: VoiceLabEditCommand, localCommands: [EditCommand] = []) throws {
        guard app.voiceLabRewriteEnabled, capabilities.edit, !capabilities.exporting, !capabilities.aiBusy else { throw VoiceLabProjectError.invalidSegment }
        var changed = try command.applying(to: project)
        if !localCommands.isEmpty {
            guard var state = editState() else { throw VoiceLabProjectError.invalidSegment }
            for local in localCommands { state = EditReducer.reduce(state, command: local, aiResults: changed.ai.results) }
            changed.edits = state.projectEdits
            try VoiceLabProject.validate(changed)
        }
        replace(changed, name: command.actionName)
    }
}
