import Foundation
import Observation

struct EditorCapabilities: Equatable {
    let writable: Bool
    let media: Bool
    let transcript: Bool
    let exporting: Bool
    let aiBusy: Bool
    var edit: Bool { writable && media && transcript }
    var rename: Bool { writable }
    var captionPosition: Bool { writable }
    var export: Bool { writable && media && !exporting }
    var ai: Bool { edit && !aiBusy }
}

@MainActor @Observable final class ProjectLlmRuns {
    private(set) var token: UUID?
    var isBusy: Bool { token != nil }
    func acquire() -> UUID? {
        guard token == nil else { return nil }
        let next = UUID()
        token = next
        return next
    }
    func release(_ lease: UUID) {
        if token == lease { token = nil }
    }
}

extension EditorModel {
    func mutationEnabled(_ command: Int) -> Bool? {
        switch command {
        case 1, 2, 3, 7, 8, 9, 29, 30, 31, 37, 40, 41, 42, 43, 44: return capabilities.edit
        case 34: return capabilities.ai
        case 38: return app.voiceLabRewriteEnabled && capabilities.ai
        case 39: return false
        case 45: return canExport && mediaExportable
        default: return nil
        }
    }
    var llmRuns: ProjectLlmRuns { app.projectLlmRuns(project.id) }
    var capabilities: EditorCapabilities {
        EditorCapabilities(writable: !document.isVersion && !isLeaving, media: mediaResolved && !mediaUnreadable,
            transcript: editingAvailable, exporting: exporting, aiBusy: llmRuns.isBusy)
    }
}
