import Foundation

public enum RenderCallerInputs {
    public static func recordingFiles(project: Project, primary: URL, projectURL: URL? = nil) -> [RenderRecording] {
        ProjectClock.build(project).regions.compactMap { region in
            if region.prefix.isEmpty { return RenderRecording(region: region, url: primary) }
            guard let reference = project.media.additionalSources.first(where: { $0.contentKey == region.key }),
                  let url = JSONProjectStore.recordingURL(reference, beside: primary, projectURL: projectURL) else { return nil }
            return RenderRecording(region: region, url: url)
        }
    }
    static func scopedAnchors(project: Project, clipID: String?) -> ((Double) -> Bool)? {
        guard let clipID, let clip = project.edits.clips.first(where: { $0.id == clipID }),
              let words = ProjectClock.build(project).transcript?.words else { return nil }
        let rate = Double(project.media.source.audio?.sampleRate ?? 48_000)
        let parts = StoryClips.times(clip, words: words).map {
            TimeRange(start: EditingPrimitives.jsRound($0.start * rate), end: EditingPrimitives.jsRound($0.end * rate))
        }
        return { seconds in
            let sample = EditingPrimitives.jsRound(seconds * rate)
            return parts.contains { $0.start <= sample && sample < $0.end }
        }
    }

    public static func timeline(project: Project, clipID: String? = nil) throws -> RenderTimeline {
        if project.schemaVersion >= 3, project.transcript != nil {
            let output = try VoiceLabOutputPlanner.build(project, scope: clipID.map(VoiceLabOutputScope.clip) ?? .full)
            if output.requiresSyntheticRendering { return .voiceLab(output) }
        }
        return .legacy(try editPlan(project: project, clipID: clipID))
    }

    public static func editPlan(project: Project, clipID: String? = nil) throws -> EditPlan {
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
        guard var state = try EditState(project: project) else {
            guard clip == nil, project.edits.cutWordIds.isEmpty, project.edits.cutPauseIds.isEmpty else {
                throw VoiceLabProjectError.invalidScope
            }
            let total = Int64(totalSamples)
            return EditPlan(sampleRate: rate, totalSamples: total,
                kept: total > 0 ? [MediaInterval(startSample: 0, endSample: total)] : [])
        }
        state.activeClipId = clipID
        return try EditPlan.build(transcript: state.transcript, editState: state, activeClip: clip,
            duration: source.durationSeconds, sampleRate: rate)
    }

    public static func prepare(_ request: RenderRequest, project: Project, clipID: String?, dataRoot: URL,
                               shared: SharedResources? = nil, resolveFootageURL: (URL) -> URL = { $0 },
                               projectURL: URL? = nil,
                               reduceMotion: Bool = false,
                               isCancelled: @Sendable () -> Bool = { false }) throws -> RenderRequest {
        guard !isCancelled() else { throw CancellationError() }
        try ContextDemoProject.validate(project)
        if let clipID, !project.edits.clips.contains(where: { $0.id == clipID }) {
            throw VoiceLabProjectError.invalidScope
        }
        var result = request
        result.sourceContentKey = project.media.source.contentKey
        let clock = ProjectClock.build(project)
        if clock.regions.count > 1 {
            let intervals: [MediaInterval]
            switch request.timeline {
            case .legacy(let plan): intervals = plan.kept
            case .voiceLab(let plan): intervals = plan.pieces.map { .init(startSample: $0.sourceStartSample, endSample: $0.sourceEndSample) }
            }
            guard request.timeline.sampleRate == Double(clock.sampleRate) else {
                throw VoxClipError.exportFailed("Invalid recording sample grid")
            }
            result.spanSources = try intervals.map { span in
                guard let start = Int(exactly: span.startSample), let region = clock.region(at: start),
                      span.endSample <= region.endSample, span.endSample > span.startSample else {
                    throw VoxClipError.exportFailed("Invalid recording span")
                }
                return region.key
            }
            let used = Set(result.spanSources)
            result.recordings = try clock.regions.filter { used.contains($0.key) }.map { region in
                if region.prefix.isEmpty { return RenderRecording(region: region, url: request.sourceURL) }
                guard let reference = project.media.additionalSources.first(where: { $0.contentKey == region.key }),
                      let url = JSONProjectStore.recordingURL(reference, beside: request.sourceURL, projectURL: projectURL) else {
                    throw VoxClipError.recordingMissing(region.label)
                }
                return RenderRecording(region: region, url: url)
            }
        }
        result.motionClipID = clipID
        result.motionCues = clipID.map { selected in project.motionCues.filter { $0.clipID == selected } } ?? []
        result.music = MusicRenderInput.resolve(project: project, clipId: clipID, dataRoot: dataRoot)
        result.effects = ClipEffectsRenderInput.resolve(project: project, clipID: clipID, dataRoot: dataRoot, shared: shared)
        result.footage = []
        if let clipID, let span = ClipControlsProject.sourceSpan(of: clipID, in: project) {
            result.footage = project.media.footage.compactMap {
                $0.renderInput(clipID: clipID, span: span, sources: project.media.additionalSources, resolveURL: resolveFootageURL)
            }
        }
        result.clipControls = ClipControlsProject.controls(for: clipID, in: project).flatMap { $0.isDefault ? nil : $0 }
        result.partReframes = []
        if let clipID, let words = clock.transcript?.words,
           let clip = project.edits.clips.first(where: { $0.id == clipID }), let parts = clip.parts {
            result.partReframes = zip(StoryClips.times(clip, words: words), parts).compactMap { source, part in
                part.reframe.map { StoryPartReframe(source: source, reframe: $0) }
            }
        }
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
            result.contextDemoRoot = dataRoot.standardizedFileURL
        }
        guard !isCancelled() else { throw CancellationError() }
        return result
    }
}
