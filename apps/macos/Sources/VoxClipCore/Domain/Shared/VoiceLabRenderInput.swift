import Foundation

/// Request-bound Voice Lab data. The paid root is a location for preflight only; Media reads
/// the immutable private snapshots returned by VoiceLabAssets after validation.
public struct VoiceLabRenderInput: Sendable, Equatable {
    public static func supportsVideoMode(_ mode: VoiceLabVideoMode) -> Bool { mode == .source }
    public let project: Project
    public let scope: VoiceLabOutputScope
    public let labelPosition: VoiceLabLabelPosition
    public let paidRoot: URL
    public let prepared: VoiceLabPreparedRender

    public init(project: Project, scope: VoiceLabOutputScope, labelPosition: VoiceLabLabelPosition,
                paidRoot: URL, prepared: VoiceLabPreparedRender) throws {
        try prepared.verify(project: project, scope: scope, labelPosition: labelPosition)
        guard prepared.selectedSegmentRecipes.allSatisfy({ Self.supportsVideoMode($0.recipe.video.mode) })
        else { throw VoiceLabProjectError.videoModeUnsupported }
        self.project = project
        self.scope = scope
        self.labelPosition = labelPosition
        self.paidRoot = paidRoot
        self.prepared = prepared
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.project == rhs.project && lhs.scope == rhs.scope && lhs.labelPosition == rhs.labelPosition &&
        lhs.paidRoot == rhs.paidRoot && lhs.prepared.outputPlan == rhs.prepared.outputPlan &&
        lhs.prepared.disclosure == rhs.prepared.disclosure
    }
}
