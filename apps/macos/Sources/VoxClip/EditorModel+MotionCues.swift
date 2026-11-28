import Foundation
import Observation
import VoxClipCore

struct MotionCueDraft: Equatable {
    var id: String
    var clipID: String
    var sourceStart: Double
    var sourceEnd: Double
    var keyframes: [MotionKeyframe]
    var original: MotionCue?

    init(cue: MotionCue, original: MotionCue? = nil) {
        id = cue.id
        clipID = cue.clipID
        sourceStart = cue.sourceStart
        sourceEnd = cue.sourceEnd
        keyframes = cue.keyframes
        self.original = original
    }

    var cue: MotionCue {
        MotionCue(id: id, clipID: clipID, sourceStart: sourceStart, sourceEnd: sourceEnd, keyframes: keyframes)
    }
}

struct TimelineMotionCue: Equatable {
    let id: String
    let range: Range<Double>
    /// What the lane writes on the cue: "Pan & Zoom" when nil; an Ask Claude effect's name on the FX lane.
    var label: String? = nil
}

/// One inline editing draft. Only Apply/Delete reach the existing Project snapshot commands.
@MainActor @Observable final class MotionCueEditing {
    var draft: MotionCueDraft { didSet { status = nil } }
    var selectedFrame: Int
    var status: String?
    let returnJob: PanelJob

    init(draft: MotionCueDraft, returnJob: PanelJob) {
        self.draft = draft
        self.returnJob = returnJob
        selectedFrame = min(1, draft.keyframes.count - 1)
    }

    func selectCue(_ id: String, model: EditorModel) {
        guard let next = model.motionCueDraft(id: id.isEmpty ? nil : id) else { return }
        draft = next
        selectedFrame = min(1, next.keyframes.count - 1)
    }

    /// Undo, Redo, timeline edits and Ask Claude or Make it undo change the saved cue while the panel
    /// stays open. The draft takes the new saved values and keeps the fields the user changed but did not apply.
    func follow(_ model: EditorModel) {
        guard let original = draft.original else { return }
        let stored = model.project.motionCues.first { $0.id == original.id }
        guard stored != original else { return }
        guard let stored, stored.clipID == draft.clipID else {
            selectCue("", model: model)
            status = model.undoManager?.isUndoing == true
                ? "This cue was removed. Redo restores it." : "This cue was removed. Undo restores it."
            return
        }
        var next = MotionCueDraft(cue: stored, original: stored)
        if draft.sourceStart != original.sourceStart { next.sourceStart = draft.sourceStart }
        if draft.sourceEnd != original.sourceEnd { next.sourceEnd = draft.sourceEnd }
        if draft.keyframes != original.keyframes { next.keyframes = draft.keyframes }
        let kept = next.cue != stored
        draft = next
        selectedFrame = min(selectedFrame, next.keyframes.count - 1)
        if kept { status = "The saved cue changed. Your unapplied edits are kept." }
    }

    /// The footer line. Apply is never disabled without one.
    func footerMessage(model: EditorModel) -> String? {
        model.motionCueValidation(draft) ?? status ?? (hasUnappliedChanges ? nil : Self.nothingToApply)
    }

    static let nothingToApply = "No unapplied changes."
    /// Apply is enabled only for a new cue or a saved cue the draft differs from.
    var hasUnappliedChanges: Bool { draft.original != draft.cue }

    @discardableResult func apply(model: EditorModel) -> Bool {
        guard model.motionCueEditing === self else { return false }
        guard model.applyMotionCue(draft) else {
            status = model.motionCueValidation(draft) ?? Self.nothingToApply
            return false
        }
        let frame = selectedFrame
        selectCue(draft.id, model: model)
        // Stay on the keyframe just edited, and show it where its timing may have moved.
        selectedFrame = min(frame, draft.keyframes.count - 1)
        showSelectedFrame(model: model)
        status = "Motion cue saved. Undo restores the previous state."
        return true
    }

    /// The Cue menu: load that cue's draft and show its selected keyframe in the paused viewer.
    func chooseCue(_ id: String, model: EditorModel) {
        selectCue(id, model: model)
        if draft.original != nil { showSelectedFrame(model: model) }
    }

    /// The Keyframe menu: the paused viewer moves to that keyframe's moment, so its zoom is in view.
    func selectFrame(_ index: Int, model: EditorModel) {
        guard draft.keyframes.indices.contains(index) else { return }
        selectedFrame = index
        showSelectedFrame(model: model)
    }

    func showSelectedFrame(model: EditorModel) {
        guard !model.isPlaying, let moment = keyframeMoment(selectedFrame) else { return }
        model.seek(source: moment)
    }

    /// The source second a keyframe happens at, kept a frame inside the cue: its range excludes
    /// `sourceEnd`, and the frame shown for the start time may begin just before it.
    func keyframeMoment(_ index: Int) -> Double? {
        guard draft.keyframes.indices.contains(index), draft.sourceStart.isFinite, draft.sourceEnd.isFinite,
              draft.sourceEnd > draft.sourceStart else { return nil }
        let length = draft.sourceEnd - draft.sourceStart
        let inset = min(0.04, length / 4)
        let moment = draft.sourceStart + draft.keyframes[index].progress * length
        return min(draft.sourceEnd - inset, max(draft.sourceStart + inset, moment))
    }

    func keyframeLabel(_ index: Int) -> String {
        guard draft.keyframes.indices.contains(index) else { return "" }
        if index == 0 { return "1 · start" }
        if index == draft.keyframes.count - 1 { return "\(index + 1) · end" }
        return "\(index + 1) · \(String(format: "%.0f", draft.keyframes[index].progress * 100))%"
    }

    func deleteCue(model: EditorModel) {
        guard model.motionCueEditing === self else { return }
        guard let original = draft.original, model.deleteMotionCue(original) else {
            status = "This cue changed or is no longer editable. Choose it again before deleting."
            return
        }
        selectCue("", model: model)
        status = "Motion cue deleted. Undo restores it."
    }

    enum FrameField {
        case progress, scale, anchorX, anchorY

        var title: String {
            switch self {
            case .progress: "Time in cue"
            case .scale: "Zoom"
            case .anchorX: "Horizontal"
            case .anchorY: "Vertical"
            }
        }

        /// VoiceOver hints; the row titles are the labels.
        var hint: String {
            switch self {
            case .progress: "When this keyframe happens, from the cue's start to its end."
            case .scale: "One hundred percent shows the whole picture. Raise it to zoom in."
            case .anchorX: "Zero keeps the left edge; one hundred percent keeps the right edge. Visible when zoomed in."
            case .anchorY: "Zero keeps the top edge; one hundred percent keeps the bottom edge. Visible when zoomed in."
            }
        }
    }

    func frameValue(_ field: FrameField) -> Double {
        guard draft.keyframes.indices.contains(selectedFrame) else { return 0 }
        let frame = draft.keyframes[selectedFrame]
        switch field {
        case .progress: return frame.progress
        case .scale: return frame.scale
        case .anchorX: return frame.anchorX
        case .anchorY: return frame.anchorY
        }
    }

    func setFrameValue(_ field: FrameField, to value: Double) {
        guard draft.keyframes.indices.contains(selectedFrame) else { return }
        let frame = draft.keyframes[selectedFrame]
        var progress = frame.progress
        if field == .progress, selectedFrame > 0, selectedFrame < draft.keyframes.count - 1 {
            let lower: Double = draft.keyframes[selectedFrame - 1].progress + 0.0001
            let upper: Double = draft.keyframes[selectedFrame + 1].progress - 0.0001
            progress = min(upper, max(lower, value))
        }
        draft.keyframes[selectedFrame] = MotionKeyframe(progress: progress,
            scale: field == .scale ? value : frame.scale,
            anchorX: field == .anchorX ? value : frame.anchorX,
            anchorY: field == .anchorY ? value : frame.anchorY)
    }

    func addKeyframe() {
        guard draft.keyframes.count < MotionCue.maximumKeyframes, selectedFrame >= 0,
              selectedFrame < draft.keyframes.count - 1 else { return }
        let first = draft.keyframes[selectedFrame]
        let last = draft.keyframes[selectedFrame + 1]
        guard last.progress - first.progress >= 0.0004 else { return }
        let progress: Double = (first.progress + last.progress) / 2
        let duration: Double = draft.sourceEnd - draft.sourceStart
        let sourceTime: Double = draft.sourceStart + progress * duration
        let transform = draft.cue.transform(atSourceTime: sourceTime)
        draft.keyframes.insert(MotionKeyframe(progress: progress, scale: transform.scale,
            anchorX: transform.anchorX, anchorY: transform.anchorY), at: selectedFrame + 1)
        selectedFrame += 1
    }

    func removeKeyframe() {
        guard selectedFrame > 0, selectedFrame < draft.keyframes.count - 1, draft.keyframes.count > 2 else { return }
        draft.keyframes.remove(at: selectedFrame)
        selectedFrame -= 1
    }
}

extension EditorModel {
    @discardableResult func openMotionCueJob(id: String? = nil, in shell: WorkspaceShell) -> Bool {
        if let reason = motionCueUnavailableReason { announce(reason); return false }
        // An existing approval question keeps its ownership and focus until answered.
        guard panelTask?.confirm == nil, let draft = motionCueDraft(id: id) else { return false }
        let previous = motionCueEditing?.returnJob ?? shell.panelJob(for: self)
        let editing = MotionCueEditing(draft: draft, returnJob: previous)
        motionCueEditing = editing
        // A saved cue opens on its moment, so the viewer shows its zoom. A new cue keeps the playhead it starts at.
        if draft.original != nil { editing.showSelectedFrame(model: self) }
        shell.choosePanelJob(.motion, for: self)
        if !shell.viewerShown { shell.toggleViewer() }
        focusedPane = .panel
        paneFocusRequest += 1
        return true
    }

    func closeMotionCueJob(in shell: WorkspaceShell) {
        guard let editing = motionCueEditing else { return }
        motionCueEditing = nil
        let previous = PanelJob.available(in: self).contains(editing.returnJob) ? editing.returnJob : .captions
        let exportReturn = shell.exportReturnJob
        shell.choosePanelJob(previous, for: self)
        // Resuming Export is not a new Export entry: Done must still return to its original job.
        if previous == .export { shell.exportReturnJob = exportReturn }
        focusedPane = shell.layout.timelineVisible ? .timeline : .transcript
        paneFocusRequest += 1
    }

    var motionCueUnavailableReason: String? {
        _ = projectRevision
        if isLeaving { return "This editor is closing. Open the project again before changing motion." }
        if !capabilities.writable { return "Open an editable project to change motion." }
        if !capabilities.media { return "Locate the source video before adding motion. Your media and edits are safe." }
        if !capabilities.transcript { return "Transcribe the video before adding motion." }
        if activeClip == nil || scopeSourceRange == nil { return "Open a clip to add motion. Full Take stays unchanged." }
        if exporting { return "Wait for export to finish before changing motion." }
        return nil
    }

    var clipMotionCues: [MotionCue] {
        _ = projectRevision
        guard let clip = activeClip else { return [] }
        return project.motionCues.filter { $0.clipID == clip.id && $0.isValid }.prefix(MotionCue.maximumCuesPerClip).sorted {
            $0.sourceStart == $1.sourceStart ? $0.id < $1.id : $0.sourceStart < $1.sourceStart
        }
    }

    func motionCueDraft(id: String? = nil) -> MotionCueDraft? {
        guard let clip = activeClip, let bounds = scopeSourceRange else { return nil }
        if let id {
            return clipMotionCues.first(where: { $0.id == id }).map { MotionCueDraft(cue: $0, original: $0) }
        }
        let selection = selectionSourceRange
        let start = min(bounds.upperBound, max(bounds.lowerBound, selection?.lowerBound ?? sourceTime))
        let end = min(bounds.upperBound, start + MotionCue.maximumDuration, selection?.upperBound ?? (start + 3))
        let lower = end - start >= MotionCue.minimumDuration ? start : bounds.lowerBound
        let upper = end - start >= MotionCue.minimumDuration ? end : min(bounds.upperBound, lower + 3)
        return MotionCueDraft(cue: MotionCue(id: UUID().uuidString, clipID: clip.id, sourceStart: lower, sourceEnd: upper,
            keyframes: [MotionKeyframe(progress: 0), MotionKeyframe(progress: 0.5, scale: 1.15), MotionKeyframe(progress: 1)]))
    }

    func motionCueValidation(_ draft: MotionCueDraft) -> String? {
        if let reason = motionCueUnavailableReason { return reason }
        guard let clip = activeClip, draft.clipID == clip.id, let bounds = scopeSourceRange else { return "The open clip changed. Choose the cue again." }
        guard draft.sourceStart.isFinite, draft.sourceEnd.isFinite,
              draft.sourceStart >= bounds.lowerBound, draft.sourceEnd <= bounds.upperBound,
              draft.sourceEnd - draft.sourceStart + 1e-9 >= MotionCue.minimumDuration,
              draft.sourceEnd - draft.sourceStart <= MotionCue.maximumDuration + 1e-9 else {
            return "Use a source range inside this clip, between 0.1 and 120 seconds long."
        }
        guard !draft.id.isEmpty, (2...MotionCue.maximumKeyframes).contains(draft.keyframes.count), draft.cue.isValid else { return "Use between two and eight motion keyframes." }
        if let original = draft.original {
            guard project.motionCues.first(where: { $0.id == draft.id }) == original else { return "This cue changed. Choose it again before applying edits." }
        } else if project.motionCues.contains(where: { $0.id == draft.id }) {
            return "This cue already exists. Choose it again before applying edits."
        } else if clipMotionCues.count >= MotionCue.maximumCuesPerClip {
            return "This clip already has 64 motion cues. Remove a cue before adding another."
        }
        guard !draft.cue.mappedIntervals(in: timelinePieces).isEmpty else { return "This range is fully cut. Choose a range with kept video." }
        guard !clipMotionCues.contains(where: { $0.id != draft.id && $0.sourceStart < draft.sourceEnd && $0.sourceEnd > draft.sourceStart }) else {
            return "Motion cues cannot overlap. Shorten this range or edit the existing cue."
        }
        guard (try? ContextDemoProject.settingMotionCues(motionCueCandidates(draft), in: project)) != nil else {
            return "This project cannot save motion yet. Review its media, clip ranges, and legacy voice edits. Your media and edits are safe."
        }
        return nil
    }

    private func motionCueCandidates(_ draft: MotionCueDraft) -> [MotionCue] {
        var cues = project.motionCues
        if let index = cues.firstIndex(where: { $0.id == draft.id }) { cues[index] = draft.cue }
        else { cues.append(draft.cue) }
        return cues
    }

    @discardableResult
    func applyMotionCue(_ draft: MotionCueDraft) -> Bool {
        guard motionCueValidation(draft) == nil else { return false }
        guard let changed = try? ContextDemoProject.settingMotionCues(motionCueCandidates(draft), in: project), changed != project else { return false }
        replace(changed, name: draft.original == nil ? "Add Motion Cue" : "Change Motion Cue")
        return project.motionCues.contains(draft.cue)
    }

    @discardableResult
    func deleteMotionCue(_ cue: MotionCue) -> Bool {
        guard motionCueUnavailableReason == nil, cue.clipID == activeClip?.id,
              project.motionCues.contains(cue) else { return false }
        let cues = project.motionCues.filter { $0.id != cue.id || $0.clipID != cue.clipID }
        guard let changed = try? ContextDemoProject.settingMotionCues(cues, in: project) else { return false }
        replace(changed, name: "Delete Motion Cue")
        return !project.motionCues.contains(cue)
    }

    func timelineMotionCues(on axis: TimelineAxis) -> [TimelineMotionCue] {
        guard let bounds = scopeSourceRange else { return [] }
        let pieces = timelinePieces
        return clipMotionCues.flatMap { cue in
            if axis == .source {
                let lower = max(bounds.lowerBound, cue.sourceStart)
                let upper = min(bounds.upperBound, cue.sourceEnd)
                return upper > lower ? [TimelineMotionCue(id: cue.id, range: lower..<upper)] : []
            }
            return cue.mappedIntervals(in: pieces).map { TimelineMotionCue(id: cue.id, range: $0.edited) }
        }
    }
}
