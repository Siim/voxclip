import Foundation
import VoxClipCore

public enum VoiceLabRenderCapabilityError: Error, LocalizedError, Sendable, Equatable {
    case pitchPreservingFitUnverified

    public var errorDescription: String? {
        "This Mac build cannot verify the timing of a stretched Voice Lab take. The generated audio and edits are unchanged."
    }
}

public enum VoiceLabRenderPreflight {
    /// Bind a caller's exact project and scope before any paid-asset or output I/O.
    /// Source-only scopes retain the ordinary renderer, including older projects.
    public static func prepare(project: Project, scope: VoiceLabOutputScope, paidRoot: URL,
                               labelPosition: VoiceLabLabelPosition = .topLeft) throws -> VoiceLabRenderInput? {
        if project.schemaVersion < 3 {
            try VoiceLabProject.requireLegacyRendering(project, scope: scope)
            return nil
        }
        let prepared = try VoiceLabRenderContract.prepare(project, scope: scope, labelPosition: labelPosition)
        try validateFit(prepared)
        guard prepared.outputPlan.requiresSyntheticRendering else { return nil }
        return try VoiceLabRenderInput(project: project, scope: scope, labelPosition: labelPosition,
                                       paidRoot: paidRoot, prepared: prepared)
    }

    private static func validateFit(_ prepared: VoiceLabPreparedRender) throws {
        if prepared.outputPlan.requiresSyntheticRendering && prepared.selectedSegmentRecipes.contains(where: {
            abs($0.recipe.audio.stretch - 1) > 4 * Double.ulpOfOne
        }) {
            throw VoiceLabRenderCapabilityError.pitchPreservingFitUnverified
        }
    }

    static func validate(_ request: RenderRequest) throws {
        guard let input = request.voiceLab else { return }
        try input.prepared.verify(project: input.project, scope: input.scope,
                                  labelPosition: input.labelPosition)
        let source = input.project.media.source
        let attributes = try FileManager.default.attributesOfItem(atPath: request.sourceURL.path)
        guard (attributes[.size] as? NSNumber)?.int64Value == source.sizeBytes,
              try JSONProjectStore.contentKey(for: request.sourceURL) == source.contentKey else {
            throw VoiceLabAssetError.invalidSelection("source identity")
        }
        let plan = input.prepared.outputPlan
        // TimePitch can return a full frame count after source content ends. Its
        // current output has no verified body/handle crop, so a real fit cannot
        // enter snapshot or scratch preparation, regardless of its waveform.
        try validateFit(input.prepared)
        guard let transcript = input.project.transcript else { throw VoiceLabAssetError.invalidSelection("transcript") }
        let edits = input.project.edits
        let pauses = try detectPauses(transcript.words, thresholdSeconds: edits.pauseThresholdSeconds)
        let state = EditState(transcript: transcript, pauses: pauses,
                              pauseThresholdSeconds: edits.pauseThresholdSeconds, pauseKeepSeconds: edits.pauseKeepSeconds,
                              cutWordIds: Set(edits.cutWordIds), cutPauseIds: Set(edits.cutPauseIds),
                              corrections: edits.corrections, clips: edits.clips, activeClipId: nil)
        let clip: ClipRange?
        switch input.scope {
        case .full: clip = nil
        case .clip(let id):
            guard let selected = edits.clips.first(where: { $0.id == id }) else {
                throw VoiceLabAssetError.invalidSelection("render scope")
            }
            clip = selected
        }
        let expectedLegacy = try EditPlan.build(transcript: transcript, editState: state, activeClip: clip,
                                                duration: source.durationSeconds, sampleRate: plan.sampleRate)
        guard request.plan == expectedLegacy else {
            throw VoiceLabAssetError.invalidSelection("legacy source plan")
        }
        if let layout = request.captionLayout {
            let expected = plan.captions.map {
                CaptionInputWord(id: $0.id, text: $0.text, start: $0.start, end: $0.end)
            }
            guard layout.input.words == expected,
                  abs(layout.input.duration - plan.duration) < 1 / plan.sampleRate,
                  layout.input.frame.width == request.output.size.width,
                  layout.input.frame.height == request.output.size.height,
                  layout.input.style == input.project.captions.styleId,
                  layout.input.captions == CaptionLayoutInput.Settings(
                    overrides: input.project.captions.overrides,
                    position: input.project.captions.position,
                    positionByAspect: input.project.captions.positionByAspect),
                  request.captions == layout.track else {
                throw VoiceLabAssetError.invalidSelection("caption layout")
            }
        } else if request.style != nil || !request.captions.words.isEmpty || !request.captions.pages.isEmpty {
            throw VoiceLabAssetError.invalidSelection("caption layout")
        }
    }
}
