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
    /// Leases taken inside `sharing`, while the holder lets its own steps in.
    private(set) var guests: Set<UUID> = []
    @ObservationIgnored private var sharers = 0
    var isBusy: Bool { token != nil || !guests.isEmpty }
    func acquire() -> UUID? {
        if token == nil && guests.isEmpty {
            let next = UUID()
            token = next
            return next
        }
        guard sharers > 0 else { return nil }
        let guest = UUID()
        guests.insert(guest)
        return guest
    }
    func release(_ lease: UUID) {
        if token == lease { token = nil } else { guests.remove(lease) }
    }
    /// Runs `body` with the project's lease shared (design.md §6.7): Claude mode applies a planned clip while it still plans
    /// the others, and that clip's own Rewrite steps (the free fit round, Keep fixing) take a lease inside the planner's.
    /// Nothing else acquires while it runs: the editor's AI actions stay off while the project is busy.
    func sharing<T>(_ body: () async -> T) async -> T {
        sharers += 1
        defer { sharers -= 1 }
        return await body()
    }
}

extension EditorModel {
    func mutationEnabled(_ command: Int) -> Bool? {
        switch command {
        case 1, 2, 3, 7, 8, 9, 29, 30, 31, 37, 40, 41, 42, 43, 44: return capabilities.edit
        case 34: return capabilities.ai
        case 62: return capabilities.ai && capabilities.edit
        case 38: return RewriteEntryPolicy.canRun(editable: capabilities.ai, scope: rewriteScopeNow)
        case 45: return canExport && mediaExportable
        default: return nil
        }
    }
    var llmRuns: ProjectLlmRuns { app.projectLlmRuns(project.id) }
    var capabilities: EditorCapabilities {
        EditorCapabilities(writable: !document.isVersion && !isLeaving, media: mediaUsable,
            transcript: editingAvailable, exporting: exporting, aiBusy: llmRuns.isBusy)
    }
}
