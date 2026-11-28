import Foundation
import VoxClipCore

/// The clip controls' editor commands (design.md §6.9). Each is one undo step named for what it changed; sliders call
/// them once when a drag ends, so a drag is one step. With no `clipID` they act on the open clip; on Full Take, or for a
/// clip that is not in the project, they do nothing and return false. The Make it postable plan and Ask Claude call
/// `apply(look:clipID:)` and `apply(speed:clipID:)` with the planner's own types.
extension EditorModel {
    /// The open clip's controls (the defaults when it has none stored); nil on Full Take.
    var currentClipControls: ProjectClipControls? {
        guard let id = renderedActiveClipID, project.edits.clips.contains(where: { $0.id == id }) else { return nil }
        return ClipControlsProject.controls(for: id, in: project)
    }

    /// "1.1×" for the open clip when its speed isn't 1, for the panel header.
    var clipSpeedBadge: String? {
        guard let controls = currentClipControls, controls.speed != 1 else { return nil }
        return ProjectClipControls.speedLabel(controls.speed)
    }

    /// Rotate shows only for a source with a picture to turn.
    var canRotateClip: Bool { project.media.source.video != nil }

    @discardableResult func setSpeed(_ rate: Double, clipID: String? = nil) -> Bool {
        let speed = ProjectClipControls.normalizedSpeed(rate)
        return updateClipControls(clipID, name: "Change speed", announcing: "Speed \(ProjectClipControls.speedLabel(speed))") { $0.speed = speed }
    }

    @discardableResult func setLook(_ look: ClipLook, clipID: String? = nil) -> Bool {
        updateClipControls(clipID, name: "Change look", announcing: "Look \(look.label)") { $0.look = look }
    }

    /// A look from shared/looks/clip-looks.json by ID (`ClipControlsProject.settingLookPreset`'s rule): its base,
    /// adjustments and grade, keeping the clip's Fix.
    @discardableResult func setColorPreset(_ id: String, clipID: String? = nil) -> Bool {
        guard project.media.source.video != nil, let preset = ClipLookLibrary.app?.look(id) else { return false }
        return updateClipControls(clipID, name: "Change look", announcing: "Look \(preset.label)") { $0.applyLook(preset) }
    }

    @discardableResult func setColorAdjustment(_ control: ClipColorAdjustments.Control, value: Int, clipID: String? = nil) -> Bool {
        guard project.media.source.video != nil else { return false }
        let bounds = ClipColorAdjustments.range
        let point = min(bounds.upperBound, max(bounds.lowerBound, value))
        return updateClipControls(clipID, name: "Change \(control.label.lowercased())", announcing: "\(control.label) \(point)") { controls in
            guard control != .saturation || controls.look != .bw else { return }
            var adjustments = controls.colorAdjustments ?? .neutral
            adjustments[control] = point
            controls.colorAdjustments = adjustments == .neutral ? nil : adjustments
        }
    }

    @discardableResult func resetColorAdjustments(clipID: String? = nil) -> Bool {
        updateClipControls(clipID, name: "Reset color adjustments", announcing: "Color adjustments reset") { $0.colorAdjustments = nil }
    }

    /// The clip's own frame, or nil for the project's frame.
    @discardableResult func setShape(_ shape: ClipShape?, clipID: String? = nil) -> Bool {
        updateClipControls(clipID, name: "Change clip shape", announcing: "Shape \(shape?.rawValue ?? "as the project")") { $0.shape = shape }
    }

    @discardableResult func setGain(_ db: Double, clipID: String? = nil) -> Bool {
        let gain = ProjectClipControls.normalizedGain(db)
        return updateClipControls(clipID, name: "Change clip volume", announcing: "Volume \(MusicSection.gainLabel(gain))") { $0.gainDb = gain }
    }

    /// Either fade, or both; nil leaves that one as it is.
    @discardableResult func setFade(in fadeIn: Double? = nil, out fadeOut: Double? = nil, clipID: String? = nil) -> Bool {
        updateClipControls(clipID, name: "Change fade", announcing: "Fade changed") { controls in
            if let fadeIn { controls.fadeInSeconds = ProjectClipControls.normalizedFade(fadeIn) }
            if let fadeOut { controls.fadeOutSeconds = ProjectClipControls.normalizedFade(fadeOut) }
        }
    }

    @discardableResult func setMute(_ muted: Bool, clipID: String? = nil) -> Bool {
        updateClipControls(clipID, name: muted ? "Mute source" : "Unmute source", announcing: muted ? "Source muted" : "Source unmuted") { $0.muteSource = muted }
    }

    @discardableResult func setFlip(_ flipped: Bool, clipID: String? = nil) -> Bool {
        updateClipControls(clipID, name: "Flip", announcing: flipped ? "Flipped" : "Not flipped") { $0.flipHorizontal = flipped }
    }

    /// Clockwise degrees, normalized to a quarter turn.
    @discardableResult func setRotation(_ degrees: Int, clipID: String? = nil) -> Bool {
        guard canRotateClip else { return false }
        let rotation = ProjectClipControls.normalizedRotation(degrees)
        return updateClipControls(clipID, name: "Rotate", announcing: "Rotated \(rotation) degrees") { $0.rotationDegrees = rotation }
    }

    /// The planner's look ("Claude chose Warm Print at 70%"), as one undo step: the look of shared/looks/clip-looks.json at
    /// its amount (`ClipControlsProject.settingLookPreset`'s rule, looks spec §9.6), with `fix` as the clip's Fix when given
    /// and the clip's own Fix otherwise. False for a look this build doesn't know.
    @discardableResult func apply(look: ClipAutopilotPlan.Look, fix: ClipColorFix? = nil, clipID: String? = nil) -> Bool {
        guard let preset = ClipLookLibrary.app?.look(look.id.rawValue) else { return false }
        return updateClipControls(clipID, name: "Change look", announcing: "Look \(EditorModel.makeItLookName(preset, amount: look.amount))") {
            $0.applyLook(preset, amount: look.amount, fix: fix)
        }
    }

    /// The planner's speed ("Claude chose 1.1×"), as one undo step.
    @discardableResult func apply(speed: ClipAutopilotPlan.Speed, clipID: String? = nil) -> Bool {
        setSpeed(speed.rate, clipID: clipID)
    }

    /// Back to every default: one undo step that removes the clip's stored controls.
    @discardableResult func resetClipControls(clipID: String? = nil) -> Bool {
        updateClipControls(clipID, name: "Reset clip controls", announcing: "Clip controls reset") { controls in
            controls = ProjectClipControls(clipId: controls.clipId)
        }
    }

    @discardableResult private func updateClipControls(_ clipID: String?, name: String, announcing message: String,
                                                       _ change: (inout ProjectClipControls) -> Void) -> Bool {
        guard capabilities.edit, let id = clipID ?? renderedActiveClipID,
              var controls = ClipControlsProject.controls(for: id, in: project),
              project.edits.clips.contains(where: { $0.id == id }) else { return false }
        let before = controls
        change(&controls)
        guard controls != before, let next = try? ClipControlsProject.setting(controls, in: project) else { return false }
        replace(next, name: name)
        announce(message)
        return true
    }
}
