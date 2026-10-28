using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;

namespace VoxClip.App.ViewModels;

internal static class ExportRenderInput
{
    internal static Project ScopedProject(Project project, EditState? state) => state is null ? project : project with { Edits = project.Edits with
    {
        Clips = state.Clips.ToArray(), ActiveClipId = state.ActiveClipId,
        CutWordIds = state.CutWordIds.ToArray(), CutPauseIds = state.CutPauseIds.ToArray(), Corrections = new Dictionary<string, string>(state.Corrections),
        PauseThresholdSeconds = state.PauseThresholdSeconds, PauseKeepSeconds = state.PauseKeepSeconds
    } };
    internal static MediaInfo Media(Project project)
    {
        var source = project.Media.Source;
        var oriented = source.Video is { RotationDegrees: 90 or 270 } video ? new PixelSize(video.Height, video.Width) : new(source.Video?.Width ?? 1920, source.Video?.Height ?? 1080);
        return new(source.AbsolutePath, source.DurationSeconds, source.Video, source.Audio, oriented, null, null, false, 0, source.Audio is null ? -1 : 0, 0);
    }
    internal static EditPlan Plan(MediaInfo media, EditState? state)
    {
        var rate = media.Audio?.SampleRate ?? 48000;
        if (state is not null) return EditingEngine.BuildEditPlan(EditingEngine.BuildSegments(state, media.DurationSeconds), media.DurationSeconds, rate, state.PauseKeepSeconds);
        var samples = checked((long)Math.Floor(media.DurationSeconds * rate + 0.5));
        return new(rate, samples, [], [new(0, samples)], samples, []);
    }
    internal static OutputSpec Output(MediaInfo media, ProjectExport export)
        => ExportPresets.Output(media.OrientedSize, media.Video?.FrameRate ?? 30, export.Aspect, export.Quality);
}
