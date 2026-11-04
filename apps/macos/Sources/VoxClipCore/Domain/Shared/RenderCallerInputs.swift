import Foundation

public enum RenderCallerInputs {
    public static func timeline(project: Project, clipID: String? = nil) throws -> RenderTimeline {
        let clip: ClipRange?
        if let clipID {
            guard let selected = project.edits.clips.first(where: { $0.id == clipID }) else {
                throw VoiceLabProjectError.invalidScope
            }
            clip = selected
        } else { clip = nil }
        let source = project.media.source
        let rate = Double(source.audio?.sampleRate ?? 48_000)
        let totalSamples = EditingPrimitives.jsRound(source.durationSeconds * rate)
        guard rate.isFinite, rate > 0, source.durationSeconds.isFinite, source.durationSeconds >= 0,
              totalSamples.isFinite, totalSamples >= 0, totalSamples <= 9_007_199_254_740_991 else {
            throw ContextDemoError.invalidNarration
        }
        guard let transcript = project.transcript else {
            guard clip == nil, project.edits.cutWordIds.isEmpty, project.edits.cutPauseIds.isEmpty else {
                throw VoiceLabProjectError.invalidScope
            }
            let total = Int64(totalSamples)
            return .legacy(EditPlan(sampleRate: rate, totalSamples: total,
                kept: total > 0 ? [MediaInterval(startSample: 0, endSample: total)] : []))
        }
        if project.schemaVersion >= 3 {
            let output = try VoiceLabOutputPlanner.build(project, scope: clipID.map(VoiceLabOutputScope.clip) ?? .full)
            if output.requiresSyntheticRendering { return .voiceLab(output) }
        }
        let edits = project.edits
        let state = EditState(transcript: transcript,
            pauses: try detectPauses(transcript.words, thresholdSeconds: edits.pauseThresholdSeconds),
            pauseThresholdSeconds: edits.pauseThresholdSeconds, pauseKeepSeconds: edits.pauseKeepSeconds,
            cutWordIds: Set(edits.cutWordIds), cutPauseIds: Set(edits.cutPauseIds),
            corrections: edits.corrections, clips: edits.clips, activeClipId: clipID)
        return .legacy(try EditPlan.build(transcript: transcript, editState: state, activeClip: clip,
            duration: source.durationSeconds, sampleRate: rate))
    }

    public static func prepare(_ request: RenderRequest, project: Project, clipID: String?, dataRoot: URL,
                               reduceMotion: Bool = false,
                               isCancelled: @Sendable () -> Bool = { false }) throws -> RenderRequest {
        guard !isCancelled() else { throw CancellationError() }
        try ContextDemoProject.validate(project)
        if let clipID, !project.edits.clips.contains(where: { $0.id == clipID }) {
            throw VoiceLabProjectError.invalidScope
        }
        var result = request
        result.sourceContentKey = project.media.source.contentKey
        result.motionClipID = clipID
        result.motionCues = clipID.map { selected in project.motionCues.filter { $0.clipID == selected } } ?? []
        result.music = MusicRenderInput.resolve(project: project, clipId: clipID, dataRoot: dataRoot)
        result.reduceMotion = request.forPreview && reduceMotion
        result.contextDemo = nil
        result.contextDemoRoot = nil
        if let document = project.contextDemo {
            guard request.sourceURL.standardizedFileURL == URL(fileURLWithPath: project.media.source.absolutePath).standardizedFileURL else {
                throw ContextDemoError.staleNarration
            }
            let selected = try timeline(project: project, clipID: clipID)
            guard try ContextDemoNarrationSnapshot(timeline: request.timeline) == ContextDemoNarrationSnapshot(timeline: selected) else {
                throw ContextDemoError.staleNarration
            }
            let full = try timeline(project: project)
            guard document.isCurrent(project: project, timeline: full) else { throw ContextDemoError.staleNarration }
            let scope: TimeRange
            if clipID != nil {
                let narration = try ContextDemoNarrationSnapshot(timeline: selected)
                guard let first = narration.pieces.first, let last = narration.pieces.last else {
                    throw ContextDemoError.invalidNarration
                }
                scope = TimeRange(start: full.mapTime(first.source.start), end: full.mapTime(last.source.end))
            } else { scope = TimeRange(start: 0, end: full.duration) }
            let binding = ContextDemoRenderInput(projectId: document.projectId, planId: document.planId,
                revision: document.revision, narration: document.narration, sourceContentKey: document.sourceContentKey,
                scope: scope, placements: [], assets: [])
            try binding.verifyRenderedTimeline(request.timeline)
            guard dataRoot.isFileURL else { throw ContextDemoError.unsafePath }
            let prepared = try ContextDemoPlanner.prepare(document: document, project: project, timeline: full,
                scope: scope, expectedRevision: document.revision, isCancelled: isCancelled)
            try prepared.verifyRenderedTimeline(request.timeline)
            result.contextDemo = prepared
            result.contextDemoRoot = dataRoot.standardizedFileURL.resolvingSymlinksInPath()
        }
        guard !isCancelled() else { throw CancellationError() }
        return result
    }
}
