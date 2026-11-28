import Foundation

/// A clip's whole colour state (looks spec §9.6): its base look, its fine-tuning and its grade, Fix included. Make it
/// postable's Undo puts all three back, so a look Claude chose with an amount and a Fix leaves nothing behind.
public struct ClipColorState: Sendable, Equatable {
    public var look: ClipLook
    public var adjustments: ClipColorAdjustments?
    public var grade: ClipColorGrade?

    public init(look: ClipLook = .original, adjustments: ClipColorAdjustments? = nil, grade: ClipColorGrade? = nil) {
        self.look = look; self.adjustments = adjustments; self.grade = grade
    }
}

extension ProjectClipControls {
    /// `look`, `colorAdjustments` and `colorGrade` together.
    public var colorState: ClipColorState {
        get { ClipColorState(look: look, adjustments: colorAdjustments, grade: colorGrade) }
        set { look = newValue.look; colorAdjustments = newValue.adjustments; colorGrade = newValue.grade }
    }
}

extension ClipControlsProject {
    /// `project` with one clip's colour state set as one change and its other controls kept.
    public static func settingColorState(_ state: ClipColorState, clipId: String, in project: Project) throws -> Project {
        guard var controls = controls(for: clipId, in: project) else { throw ClipControlsProjectError.unknownClip }
        controls.colorState = state
        return try setting(controls, in: project)
    }
}

extension ClipColorFix {
    /// "exposure +20, temperature −12", the Fix's non-zero values for a review line; empty when it is neutral.
    public var summary: String {
        [("exposure", exposure), ("temperature", temperature), ("tint", tint)].filter { $0.1 != 0 }
            .map { "\($0.0) \($0.1 > 0 ? "+" : "\u{2212}")\(abs($0.1))" }.joined(separator: ", ")
    }
}
