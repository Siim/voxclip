import Foundation
import VoxClipCore

// The editor's scope as a tab (impl-plan V3a, item 16, §3.3): a tab switch writes
// `activeClipId` in memory only, Undo and Redo never switch tabs, and the open Rewrite
// session belongs to its tab.

extension Project {
    /// The project with `clipID` as its active clip, so two projects compare apart from their tab.
    func scoped(to clipID: String?) -> Project {
        guard edits.activeClipId != clipID else { return self }
        var project = self
        project.edits.activeClipId = clipID
        return project
    }
}

extension EditorModel {
    /// Scopes the editor to `clipID`, or to Full Take when nil, as a tab or an Explorer
    /// row does. In memory only: no undo step and no `updateChangeCount`, so no autosave
    /// and no new version; the next real save writes it. It works in a read-only Versions
    /// window, which never writes it. False when the clip is not in the project or the
    /// project is leaving.
    @discardableResult func setScope(_ clipID: String?) -> Bool {
        guard !isLeaving else { return false }
        if let clipID, !project.edits.clips.contains(where: { $0.id == clipID }) { return false }
        guard project.edits.activeClipId != clipID else { return true }
        preview.pause(); isPlaying = false
        document.replaceProject(project.scoped(to: clipID))
        refresh()
        schedulePreviewUpdate(mediaChanged: false)
        return true
    }

    /// The scope's name, as its tab and the Explorer read it: "Full Take", "Clip {n}" or
    /// "Suggested clip {n}" (design §3.4 numbering).
    func scopeName(_ clipID: String?) -> String {
        guard let clipID else { return "Full Take" }
        let suggested = isSuggestion(clipID)
        guard let number = clipNumber(clipID) else { return suggested ? "Suggested clip" : "Clip" }
        return suggested ? "Suggested clip \(number)" : "Clip \(number)"
    }

    /// The scope a restored snapshot keeps (impl-plan §3.3): the current clip while
    /// `snapshot` still has it, else Full Take. So Undo and Redo never switch tabs, and an
    /// Undo that removes the open clip falls back to Full Take.
    func scopeKept(in snapshot: Project) -> String? {
        project.edits.activeClipId.flatMap { id in snapshot.edits.clips.contains { $0.id == id } ? id : nil }
    }

    /// `next` differs from the project in its scope and nothing else: an `apply` that only
    /// sets the active clip is a scope change, not an edit.
    func onlyScopeDiffers(_ next: Project) -> Bool {
        next.edits.activeClipId != project.edits.activeClipId && next.scoped(to: project.edits.activeClipId) == project
    }

    /// The open Rewrite session while its tab is active (impl-plan §3.3: a session belongs
    /// to its tab). On another tab it is nil, so the right column, the transcript's Escape
    /// and the viewer leave it alone; it stays open (`openRewrite`) and shows again on its
    /// own tab. Setting it sets `openRewrite`.
    var rewrite: RewriteSession? {
        get { openRewrite.flatMap { $0.project.edits.activeClipId == renderedActiveClipID ? $0 : nil } }
        set { openRewrite = newValue }
    }
    /// The scope the open Rewrite session rewrites, on its own tab; nil with no session there.
    var rewriteScope: RewriteScope? { rewrite?.rewriteScope }
}
