using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.Project;
using VoxClip.Media.Ffmpeg;

namespace VoxClip.Media.Pipeline;

/// <summary>Bind a planned story to verified files for both preview and export.</summary>
public static class RecordingRendering
{
    /// <summary>Verified local files for clock-addressed caches; a missing file has no cache input.</summary>
    public static async Task<IReadOnlyDictionary<string, MediaReference>> AvailableAsync(Project project, IProjectStore store,
        string projectPath, CancellationToken ct)
    {
        var resolved = new Dictionary<string, MediaReference>(StringComparer.Ordinal);
        foreach (var region in ProjectClock.Build(project).Regions)
        {
            if (Reference(project, region.Key) is not { } reference) continue;
            if (await store.ResolveMediaAsync(reference, projectPath, ct).ConfigureAwait(false) is { } path)
                resolved.Add(region.Key, reference with { AbsolutePath = path });
        }
        return resolved;
    }

    /// <summary>Resolve the recordings actually used by the kept spans, without opening unused companions.</summary>
    public static async Task<ComposeSnapshot> BindAsync(Project project, ComposeSnapshot snapshot, IProjectStore store,
        string projectPath, CancellationToken ct)
    {
        if (project.Media.SpokenSources is not { Count: > 0 }) return snapshot;
        var clock = ProjectClock.Build(project);
        var primary = project.Media.Source;
        var resolved = new Dictionary<string, RecordingRenderSource>(StringComparer.Ordinal);
        var spanSources = new RecordingRenderSource[snapshot.Plan.Kept.Count];
        for (var index = 0; index < spanSources.Length; index++)
        {
            var span = snapshot.Plan.Kept[index];
            if (clock.RegionAt(span.StartSample) is not { } region || span.EndSample > region.EndSample)
                throw new VoxClipException(VoxClipErrorCode.DecodeFailed, "A part comes from one recording.");
            if (!resolved.TryGetValue(region.Key, out var source))
            {
                var reference = region.Key == primary.ContentKey ? primary with { AbsolutePath = snapshot.Media.Path } : Reference(project, region.Key);
                if (reference is null || await store.ResolveMediaAsync(reference, projectPath, ct).ConfigureAwait(false) is not { } path)
                    throw RecordingMissing(region.Label);
                resolved.Add(region.Key, source = new(region.Key, region.Label, path, region.OffsetSamples, region.DurationSamples,
                    region.GainDb, reference.Video?.RotationDegrees ?? 0));
            }
            spanSources[index] = source;
        }
        foreach (var spans in spanSources.Zip(snapshot.Plan.Kept).GroupBy(pair => pair.First.ContentKey))
        {
            long end = -1;
            foreach (var span in spans.Select(pair => pair.Second).OrderBy(span => span.StartSample))
            {
                if (span.StartSample < end) throw new VoxClipException(VoxClipErrorCode.DecodeFailed, "Story parts cannot overlap in one recording.");
                end = span.EndSample;
            }
        }
        return snapshot with { SpanSources = spanSources };
    }

    internal static VoxClipException RecordingMissing(string label) => new(VoxClipErrorCode.MediaMissing,
        $"{label} is missing. Locate it to use its words.");

    internal static string RequirePath(RecordingRenderSource source) => File.Exists(source.Path) ? source.Path : throw RecordingMissing(source.Label);

    internal static async Task<string> RequirePathAsync(Project project, ProjectClock.Region region, IProjectStore store, string projectPath,
        CancellationToken ct)
        => Reference(project, region.Key) is { } reference && await store.ResolveMediaAsync(reference, projectPath, ct).ConfigureAwait(false) is { } path
            ? path : throw RecordingMissing(region.Label);

    private static MediaReference? Reference(Project project, string key) => key == project.Media.Source.ContentKey ? project.Media.Source :
        project.Media.AdditionalSources?.FirstOrDefault(candidate => candidate.ContentKey == key);
}

internal sealed class RecordingVideo(string primaryPath, bool hardware = true) : IDisposable
{
    private readonly Dictionary<string, VideoDecoder> decoders = new(StringComparer.Ordinal);

    internal PixelBuffer Read(RecordingRenderSource? source, double localTime, CancellationToken ct)
    {
        var key = source?.ContentKey ?? "";
        if (!decoders.TryGetValue(key, out var decoder))
            decoders.Add(key, decoder = new(source is null ? primaryPath : RecordingRendering.RequirePath(source), hardware));
        return decoder.ReadAt(localTime, false, ct);
    }

    public void Dispose()
    {
        foreach (var decoder in decoders.Values) decoder.Dispose();
    }
}
