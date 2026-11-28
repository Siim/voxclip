using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Frames;
using VoxClip.Media.Frames;

namespace VoxClip.App.ViewModels;

/// <summary>The Picture tab (looks spec §3.7): its model, and Auto's measurement on the clip's frames.</summary>
public sealed partial class EditorViewModel
{
    private PicturePanelModel? picture;

    /// <summary>The Picture tab's state.</summary>
    public PicturePanelModel Picture => picture ??= new(this);

    /// <summary>Auto's Fix for <paramref name="clipId"/> (looks spec §5.9): up to eight of the clip's sheet frames from the whole video's
    /// frame pass, measured on this PC. Null when there is no pass (no face models, no video) or no frame could be read.</summary>
    internal async Task<ClipColorFix?> MeasurePictureFixAsync(string clipId, CancellationToken ct)
    {
        if (picture?.Services?.Looks is not { } looks || project.Transcript is not { } transcript || state is null) return null;
        var range = state.Clips.FirstOrDefault(clip => clip.Id == clipId);
        if (range is null || FrameClip.Make(transcript, range, state.CutWordIds.ToHashSet(StringComparer.Ordinal)) is not { } clip) return null;
        if (StartFramePass() is not { } pass || await pass.FramesAsync(clip, ct).ConfigureAwait(true) is not { } found) return null;
        var frames = found.Sheet.Frames;
        return await Task.Run(() => FrameLightSampling.Fix(frames, looks.Measure), ct).ConfigureAwait(true);
    }
}
