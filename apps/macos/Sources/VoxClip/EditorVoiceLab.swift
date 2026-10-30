#if DEBUG
import VoxClipCore

extension EditorModel {
    func applyVoiceLab(_ command: VoiceLabEditCommand) throws {
        guard capabilities.edit, !capabilities.exporting, !capabilities.aiBusy else { throw VoiceLabProjectError.invalidSegment }
        let changed = try command.applying(to: project)
        replace(changed, name: command.actionName)
    }
}
#endif
