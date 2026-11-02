import Foundation
import VoxClipCore

struct ContextDemoEditorSnapshot: Equatable {
    let project: Project
    let revision: Int
    let selectedWordIDs: Set<String>
    let selectedPauseIDs: Set<String>
}

extension EditorModel {
    var contextDemoUnavailableReason: String? {
        if isLeaving { return "This editor is closing. Open the project again before recording a demonstration." }
        if !capabilities.writable { return "This project version is read-only. Open an editable project to place a demonstration." }
        if !capabilities.media { return "Locate readable source media before recording a demonstration. Your media and edits are safe." }
        if !capabilities.transcript { return "Transcribe the source narration before matching a demonstration to its words." }
        if exporting { return "Wait for export to finish before changing demonstrations." }
        return nil
    }

    func contextDemoSnapshot() -> ContextDemoEditorSnapshot {
        ContextDemoEditorSnapshot(project: project, revision: projectRevision,
            selectedWordIDs: selectedWordIDs, selectedPauseIDs: selectedPauseIDs)
    }

    func contextDemoIsCurrent(_ snapshot: ContextDemoEditorSnapshot) -> Bool {
        contextDemoUnavailableReason == nil && projectRevision == snapshot.revision && project == snapshot.project
            && selectedWordIDs == snapshot.selectedWordIDs && selectedPauseIDs == snapshot.selectedPauseIDs
    }

    var contextDemoDocument: ContextDemoDocument? {
        _ = projectRevision
        return project.contextDemo
    }

    func contextDemoDraftDocument() throws -> ContextDemoDocument {
        let timeline = try RenderCallerInputs.timeline(project: project)
        if let document = contextDemoDocument {
            guard document.isCurrent(project: project, timeline: timeline) else { throw ContextDemoError.staleNarration }
            return document
        }
        return try ContextDemoDocument(project: project, planId: UUID().uuidString, timeline: timeline)
    }

    func contextDemoPlayheadPosition() throws -> Double {
        guard let scoped = renderTimeline, playhead.isFinite else { throw ContextDemoError.invalidNarration }
        let full = try RenderCallerInputs.timeline(project: project)
        return min(full.duration, max(0, full.mapTime(scoped.sourceTime(playhead))))
    }

    @discardableResult
    func commitContextDemoDocument(_ document: ContextDemoDocument, expected snapshot: ContextDemoEditorSnapshot,
                                   name: String) throws -> Bool {
        guard contextDemoIsCurrent(snapshot) else { throw ContextDemoError.staleNarration }
        let timeline = try RenderCallerInputs.timeline(project: project)
        let next = try ContextDemoProject.setting(document, in: project, timeline: timeline)
        guard next != project else { return false }
        replace(next, name: name)
        return project.contextDemo == document
    }

    func openContextDemoJob() {
        guard capabilities.writable else { return }
        if contextDemoSession == nil || contextDemoSession?.phase == .closed {
            contextDemoSession = ContextDemoSession(model: self)
        }
        if app.shell.editor === self, !app.shell.viewerShown { app.shell.toggleViewer() }
        app.shell.choosePanelJob(.demo, for: self)
        focusedPane = .panel
        paneFocusRequest += 1
    }

    func closeContextDemoJob() {
        contextDemoSession?.close()
        contextDemoSession = nil
        app.shell.choosePanelJob(.captions, for: self)
        focusedPane = .transcript
        paneFocusRequest += 1
    }
}
