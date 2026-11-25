using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.VoiceLab;

namespace VoxClip.Core.Domain.Shared;

/// <summary>Build the common timeline for a preview, export, or check.</summary>
public static class RenderCallerInputs
{
    /// <summary>Resolve an explicit clip or the full take, including any existing voice patches.</summary>
    public static RenderTimeline Timeline(Project project, string? clipId = null) => Timeline(project, clipId, includeRewrites: true);

    /// <summary>The source edit plan used for timeline placement and gestures.</summary>
    public static EditPlan PlacementPlan(Project project, string? clipId = null) =>
        ((RenderTimeline.Legacy)Timeline(project, clipId, includeRewrites: false)).Plan;

    private static RenderTimeline Timeline(Project project, string? clipId, bool includeRewrites)
    {
        if (clipId is not null && !project.Edits.Clips.Any(clip => clip.Id == clipId))
            throw new VoiceLabProjectException(VoiceLabProjectErrorCode.InvalidScope);
        var source = project.Media.Source;
        var rate = source.Audio?.SampleRate ?? 48_000;
        if (EditingEngine.FromProject(project) is { } state)
        {
            if (includeRewrites && project.SchemaVersion >= 3)
            {
                var voice = VoiceLabOutputPlanner.Build(project, clipId is null ? VoiceLabOutputScope.Full : VoiceLabOutputScope.Clip(clipId));
                if (voice.RequiresSyntheticRendering) return new RenderTimeline.VoiceLab(voice);
            }
            return new RenderTimeline.Legacy(EditingEngine.BuildPlan(state with { ActiveClipId = clipId }, source.DurationSeconds, rate));
        }
        if (clipId is not null) throw new VoiceLabProjectException(VoiceLabProjectErrorCode.InvalidScope);
        return new RenderTimeline.Legacy(EditingEngine.BuildEditPlan([], source.DurationSeconds, rate));
    }
}
