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

    /// Tighten (impl-plan item 1, the clip bar): Cut Fillers and Tighten Pauses inside the open tab's scope as one undo
    /// step, "Tighten clip {n}" or "Tighten full take". Local and free. `clipID` is the scope the caller showed, so a bar
    /// that is behind a tab switch tightens nothing. Returns the cuts it added (words and pauses); nil when nothing changed.
    @discardableResult func tighten(scope clipID: String?) -> Int? {
        guard clipID == project.edits.activeClipId, let before = editState() else { return nil }
        guard apply([.cutFillers, .tightenPauses], name: tightenStepName(clipID)), let after = editState() else { return nil }
        let cuts = after.cutWordIds.subtracting(before.cutWordIds).count + after.cutPauseIds.subtracting(before.cutPauseIds).count
        announce("\(scopeName(clipID)) tightened: \(cuts == 1 ? "1 cut" : "\(cuts) cuts")")
        return cuts
    }
    /// Tighten's undo step: "Tighten clip {n}" or "Tighten full take".
    func tightenStepName(_ clipID: String?) -> String { clipID.flatMap(clipNumber).map { "Tighten clip \($0)" } ?? "Tighten full take" }
    /// Tighten can act: the scope has an uncut filler or an uncut pause.
    var canTighten: Bool { capabilities.edit && (summary.canCutFillers || summary.canTighten) }

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
    /// The words the transcript and the timeline mark for Rewrite: the open session's on
    /// its own tab, none on another tab, and with no session whatever was set. Setting it
    /// sets `openRewriteRange`.
    var rewriteRange: ClosedRange<Int>? {
        get { openRewrite != nil && rewrite == nil ? nil : openRewriteRange }
        set { openRewriteRange = newValue }
    }

    /// The open Rewrite session outlives an edit from `old` to `new` when the edit is
    /// outside the session's clip and words (impl-plan §3.3, design.md R3): the clip's
    /// bounds, the cuts, corrections and pauses of its words and the session's words, the
    /// transcript, media, pause settings and Voice Lab state are unchanged. Other clips,
    /// Find Clips results, captions, export and share settings are outside it. A session
    /// opened on Full Take has every word in scope, so any edit closes it, as before.
    func rewriteOutlives(_ old: Project, _ new: Project) -> Bool {
        guard let session = openRewrite, session.isOpen, case .clip(let id) = session.scope,
              let clip = old.edits.clips.first(where: { $0.id == id }),
              let moved = new.edits.clips.first(where: { $0.id == id }),
              moved.startWordId == clip.startWordId, moved.endWordId == clip.endWordId,
              var lower = index(clip.startWordId), var upper = index(clip.endWordId), lower <= upper else { return false }
        if let first = session.source.first.flatMap({ index($0.id) }), let last = session.source.last.flatMap({ index($0.id) }) {
            lower = min(lower, first)
            upper = max(upper, last)
        }
        let words = lower...upper
        func inside(_ project: Project) -> Project {
            var project = project
            project.modifiedAt = .distantPast
            project.title = nil
            project.edits.activeClipId = nil
            project.edits.clips = []
            project.edits.cutWordIds = project.edits.cutWordIds.filter { wordIndex[$0].map(words.contains) ?? true }
            project.edits.cutPauseIds = project.edits.cutPauseIds.filter { id in
                pauseIndex[id].map { $0.afterIndex >= lower && $0.afterIndex < upper } ?? true
            }
            project.edits.corrections = project.edits.corrections.filter { wordIndex[$0.key].map(words.contains) ?? true }
            project.captions = CaptionSettings()
            project.export = ProjectExport()
            project.share = ProjectShare()
            project.ai = ProjectAI()
            return project
        }
        return inside(old) == inside(new)
    }
}
