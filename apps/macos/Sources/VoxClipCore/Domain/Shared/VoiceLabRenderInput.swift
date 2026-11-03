import Foundation

/// Request-bound Voice Lab data. The paid root is a location for preflight only; Media reads
/// the immutable private snapshots returned by VoiceLabAssets after validation.
public struct VoiceLabRenderInput: Sendable, Equatable {
    public static func supportsVideoMode(_ mode: VoiceLabVideoMode) -> Bool { mode == .source || mode == .cut || mode == .zoomCover }

    static func supportsVideoRecipe(_ video: VoiceLabVideoRecipe) -> Bool {
        guard supportsVideoMode(video.mode) else { return false }
        if video.mode == .cut { return video.cuts?.isEmpty == false }
        if video.mode == .source { return true }
        guard video.sourceStartSample >= 0, video.sourceEndSample > video.sourceStartSample,
              video.outputSamples > 0, let declared = video.retimeFactor, declared.isFinite,
              let zoom = video.zoom, zoom.isFinite, abs(zoom - 1.12) <= 1e-9,
              let faceX = video.faceX, faceX.isFinite, (0...1).contains(faceX),
              let faceY = video.faceY, faceY.isFinite, (0...1).contains(faceY),
              video.assetId == nil, video.provider == nil, video.model == nil, video.requestId == nil,
              video.windowStartSample == nil, video.windowEndSample == nil, video.syncMode == nil else { return false }
        let factor = Double(video.sourceEndSample - video.sourceStartSample) / Double(video.outputSamples)
        return (0.80...1.25).contains(factor) && abs(factor - declared) <= 1e-6
    }
    public let project: Project
    public let scope: VoiceLabOutputScope
    public let labelPosition: VoiceLabLabelPosition
    public let paidRoot: URL
    public let prepared: VoiceLabPreparedRender

    public init(project: Project, scope: VoiceLabOutputScope, labelPosition: VoiceLabLabelPosition,
                paidRoot: URL, prepared: VoiceLabPreparedRender) throws {
        try prepared.verify(project: project, scope: scope, labelPosition: labelPosition)
        guard prepared.selectedSegmentRecipes.allSatisfy({ Self.supportsVideoRecipe($0.recipe.video) &&
            (($0.recipe.video.mode != .zoomCover && $0.recipe.video.mode != .cut) || $0.recipe.audio.stretch == 1) })
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
