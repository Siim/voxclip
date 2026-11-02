import Foundation

public enum ContextDemoProject {
    public static func upgradeToV4(_ project: Project) throws -> Project {
        try validate(project)
        var result = try VoiceLabProject.upgradeToV3(project)
        result.schemaVersion = 4
        try validate(result)
        return result
    }

    public static func validate(_ project: Project) throws {
        guard (1...4).contains(project.schemaVersion) else { throw ContextDemoError.unsupportedVersion }
        guard project.schemaVersion == 4 || (project.contextDemo == nil && project.motionCues.isEmpty) else {
            throw ContextDemoError.unsupportedVersion
        }
        if let document = project.contextDemo {
            try document.validate()
            guard document.projectId == project.id, document.sourceContentKey == project.media.source.contentKey,
                  document.narration.pieces.allSatisfy({ $0.source.end <= project.media.source.durationSeconds + 1 / document.narration.sampleRate }) else {
                throw ContextDemoError.staleNarration
            }
        }
        let clips = Set(project.edits.clips.map(\.id))
        var identities = Set<String>()
        var clipCounts: [String: Int] = [:]
        for cue in project.motionCues {
            guard cue.isValid, ContextDemoValidation.identifier(cue.id), ContextDemoValidation.identifier(cue.clipID),
                  identities.insert(cue.id).inserted, clips.contains(cue.clipID),
                  cue.sourceStart.isFinite, cue.sourceEnd.isFinite, cue.sourceStart >= 0,
                  cue.sourceEnd <= project.media.source.durationSeconds,
                  cue.sourceEnd - cue.sourceStart <= MotionCue.maximumDuration + 1e-9,
                  (2...MotionCue.maximumKeyframes).contains(cue.keyframes.count) else {
                throw ContextDemoError.invalidPlacement
            }
            clipCounts[cue.clipID, default: 0] += 1
            guard clipCounts[cue.clipID, default: 0] <= MotionCue.maximumCuesPerClip else {
                throw ContextDemoError.invalidPlacement
            }
        }
    }

    public static func setting(_ document: ContextDemoDocument?, in project: Project, timeline: RenderTimeline) throws -> Project {
        var base = project
        base.contextDemo = nil
        try validate(base)
        if let document {
            guard document.isCurrent(project: project, timeline: timeline) else { throw ContextDemoError.staleNarration }
        }
        var result = try document == nil ? base : upgradeToV4(base)
        result.contextDemo = document
        try validate(result)
        return result
    }

    public static func settingMotionCues(_ cues: [MotionCue], in project: Project) throws -> Project {
        var result = try cues.isEmpty ? project : upgradeToV4(project)
        result.motionCues = cues
        try validate(result)
        return result
    }

    public static func replacingPlacement(_ placement: ContextDemoPlacement, in project: Project,
                                          timeline: RenderTimeline, expectedRevision: Int) throws -> Project {
        guard let document = project.contextDemo else { throw ContextDemoError.invalidPlacement }
        return try setting(document.replacingPlacement(placement, expectedRevision: expectedRevision), in: project, timeline: timeline)
    }

    public static func removingPlacement(id: String, in project: Project, timeline: RenderTimeline,
                                         expectedRevision: Int) throws -> Project {
        guard let document = project.contextDemo else { throw ContextDemoError.invalidPlacement }
        return try setting(document.removingPlacement(id: id, expectedRevision: expectedRevision), in: project, timeline: timeline)
    }

    public static func placing(asset: ContextDemoAsset, placement: ContextDemoPlacement, in project: Project,
                                timeline: RenderTimeline, expectedRevision: Int) throws -> Project {
        guard let document = project.contextDemo else { throw ContextDemoError.invalidPlacement }
        return try setting(document.placing(asset: asset, placement: placement, expectedRevision: expectedRevision), in: project, timeline: timeline)
    }
}
