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

    @discardableResult func apply(model: EditorModel) -> Bool {
        guard model.motionCueEditing === self else { return false }
        guard model.applyMotionCue(draft) else {
            status = model.motionCueValidation(draft) ?? "No changes to apply."
            return false
        }
        selectCue(draft.id, model: model)
        status = "Motion cue saved. Undo restores the previous state."
        return true
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

    enum FrameField { case progress, scale, anchorX, anchorY }

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
        motionCueEditing = MotionCueEditing(draft: draft, returnJob: previous)
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
        if let id, let cue = clipMotionCues.first(where: { $0.id == id }) { return MotionCueDraft(cue: cue, original: cue) }
        let selection = selectionSourceRange
        let start = min(bounds.upperBound, max(bounds.lowerBound, selection?.lowerBound ?? sourceTime))
        let end = min(bounds.upperBound, start + MotionCue.maximumDuration, selection?.upperBound ?? (start + 3))
        let lower = end - start >= MotionCue.minimumDuration ? start : bounds.lowerBound
        let upper = end - start >= MotionCue.minimumDuration ? end : min(bounds.upperBound, lower + 3)
        return MotionCueDraft(cue: MotionCue(id: UUID().uuidString, clipID: clip.id, sourceStart: lower, sourceEnd: upper,
            keyframes: [MotionKeyframe(progress: 0), MotionKeyframe(progress: 0.5, scale: 1.08), MotionKeyframe(progress: 1)]))
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
