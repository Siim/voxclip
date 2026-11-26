using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.Project;
using VoxClip.Media.Ffmpeg;

namespace VoxClip.Media.Pipeline;

/// <summary>Prepares companion video for the shared preview and export compositor.</summary>
public static class FootageRendering
{
    /// <summary>Verify companion files and map this clip's placements to its edited timeline.</summary>
    public static async Task<IReadOnlyList<FootageRenderLayer>> ResolveAsync(Project project, ComposeSnapshot snapshot,
        IProjectStore store, string projectPath, CancellationToken ct)
    {
        if (project.Edits.ActiveClipId is not { } clipId || project.Media.Footage is not { Count: > 0 } placements) return [];
        var paths = new Dictionary<string, string>(StringComparer.Ordinal);
        var layers = new List<FootageRenderLayer>();
        var timeline = snapshot.Timeline;
        var speed = snapshot.Speed;
        var clip = project.Edits.Clips.FirstOrDefault(clip => clip.Id == clipId);
        var words = project.Transcript?.Words;
        var parts = words is null ? null : clip?.PlayPartIndices(words)?.Select((part, index) =>
            EditingAlgorithms.ClipTimes(words, part.Start, part.End, index == 0 ? clip.LeadInSeconds : null)).ToArray();
        foreach (var entry in placements.Where(entry => entry.ClipId == clipId).OrderBy(entry => entry.Start))
        {
            ct.ThrowIfCancellationRequested();
            if (parts is not null && !parts.Any(part => part.Start <= entry.Start && entry.End <= part.End)) continue;
            var start = timeline.MapTime(entry.Start);
            var end = timeline.MapEndTime(entry.End);
            if (end <= start) continue;
            var key = entry.Footage.SourceKey;
            var asset = project.Media.AdditionalSources?.FirstOrDefault(source => source.FootageKey == key);
            if (asset is null)
                throw new VoxClipException(VoxClipErrorCode.MediaMissing, "The companion recording is missing or changed. Your edits are saved.");
            var available = asset.DurationSeconds - entry.Footage.Start;
            if (available <= 0) continue;
            if (entry.Kind != "screenshot" && available < speed.Rendered(end) - speed.Rendered(start))
                end = speed.Edited(speed.Rendered(start) + available);
            if (!paths.TryGetValue(key, out var path))
            {
                if (await store.ResolveMediaAsync(asset, projectPath, ct).ConfigureAwait(false) is not { } resolved)
                    throw new VoxClipException(VoxClipErrorCode.MediaMissing, "The companion recording is missing or changed. Your edits are saved.");
                paths[key] = path = resolved;
            }
            layers.Add(new(entry, path, start, end));
        }
        return layers.ToArray();
    }
}

internal sealed class FootageFrames : IVideoLayerFrames
{
    private readonly Dictionary<string, VideoDecoder> decoders = new(StringComparer.Ordinal);

    internal FootageFrames(IReadOnlyList<FootageRenderLayer> layers)
    {
        try
        {
            foreach (var path in layers.Select(layer => layer.Path).Distinct(StringComparer.Ordinal))
                decoders.Add(path, new VideoDecoder(path, hardware: false));
        }
        catch { Dispose(); throw; }
    }

    public (PixelBuffer Frame, int Rotation) Read(string assetId, double sourceTime, CancellationToken ct)
    {
        var decoder = decoders[assetId];
        lock (decoder)
        {
            var frame = decoder.ReadAt(sourceTime, false, ct);
            return (new(frame.Pixels.ToArray(), frame.Width, frame.Height, frame.Stride), decoder.RotationDegrees);
        }
    }

    public void Dispose()
    {
        foreach (var decoder in decoders.Values) decoder.Dispose();
        decoders.Clear();
    }
}
