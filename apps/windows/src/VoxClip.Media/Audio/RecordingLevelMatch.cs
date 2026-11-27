using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Loudness;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.Project;
using VoxClip.Media.Ffmpeg;
using VoxClip.Media.Pipeline;

namespace VoxClip.Media.Audio;

/// <summary>Prepare the saved gain for a recording addition, before applying its undoable edit.</summary>
public static class RecordingLevelMatch
{
    /// <summary>Measure the two recordings over kept words and return the add command with its durable gain.</summary>
    public static async Task<RecordingEdit.AddSpokenSource> MatchOnAddAsync(Project project, RecordingEdit.AddSpokenSource add,
        IProjectStore store, string projectPath, CancellationToken ct)
    {
        if (add.GainDb is not null || project.Transcript is not { } transcript ||
            project.Media.AdditionalSources?.FirstOrDefault(source => source.ContentKey == add.Key) is not { } companion) return add;
        var primary = project.Media.Source;
        var primaryPath = await store.ResolveMediaAsync(primary, projectPath, ct).ConfigureAwait(false);
        var companionPath = await store.ResolveMediaAsync(companion, projectPath, ct).ConfigureAwait(false);
        var primaryLabel = ProjectClock.Build(project).Regions[0].Label;
        if (primaryPath is null) throw RecordingRendering.RecordingMissing(primaryLabel);
        if (companionPath is null) throw RecordingRendering.RecordingMissing(add.Label ?? ProjectClock.Label(companion));
        await FfmpegLoader.InitializeAsync(ct).ConfigureAwait(false);
        var cut = project.Edits.CutWordIds.ToHashSet(StringComparer.Ordinal);
        return await MediaThread.Run("vc-recording-level", () =>
        {
            var first = Measure(primaryPath, transcript.Words.Where(word => !cut.Contains(word.Id)), primary.DurationSeconds, ct);
            var second = Measure(companionPath, add.Transcript.Words, companion.DurationSeconds, ct);
            return add with { GainDb = first is { } target && second is { } level ?
                Math.Round(Math.Clamp(target - level, -12, 12), 1, MidpointRounding.AwayFromZero) : 0 };
        }, ct).ConfigureAwait(false);
    }

    private static double? Measure(string path, IEnumerable<TimedWord> words, double duration, CancellationToken ct)
    {
        const int rate = 48_000;
        var speech = GatedSpeechMeter.Ranges(words.Where(word => word.Kind == WordKind.Word).Select(word => new TimeRange(word.Start, word.End)),
            rate, 0, 0, duration);
        if (speech.Count == 0) return null;
        var meter = new GatedSpeechMeter(rate, 2, speech);
        using var decoder = new AudioDecoder(path, 2, rate);
        var samples = new float[4096 * 2];
        long position = -1;
        foreach (var (start, end) in speech)
        {
            if (position < 0 || start - position > rate / 2) { decoder.Seek(start); position = start; }
            while (position < end)
            {
                var count = (int)Math.Min(4096, end - position);
                var data = samples.AsSpan(0, count * 2);
                decoder.Read(data, count, ct);
                meter.Append(position, data);
                position += count;
            }
        }
        return meter.Finish();
    }
}

internal sealed class GatedSpeechMeter(int rate, int channels, IReadOnlyList<MediaInterval> ranges)
{
    private readonly SocialLoudnessMeter meter = new(rate, channels);
    private int next;

    internal static IReadOnlyList<MediaInterval> Ranges(IEnumerable<TimeRange> words, int rate, double origin, double start, double end)
    {
        long Sample(double seconds) => Math.Max(0, Native.Round((seconds - origin) * rate));
        var ranges = new List<MediaInterval>();
        foreach (var word in words.OrderBy(word => word.Start))
        {
            var first = Sample(Math.Max(word.Start, start));
            var last = Sample(Math.Min(word.End, end));
            if (last <= first) continue;
            if (ranges.Count > 0 && ranges[^1].EndSample >= first)
                ranges[^1] = ranges[^1] with { EndSample = Math.Max(ranges[^1].EndSample, last) };
            else ranges.Add(new(first, last));
        }
        return ranges;
    }

    internal void Append(long start, ReadOnlySpan<float> samples)
    {
        var end = start + samples.Length / channels;
        while (next < ranges.Count)
        {
            var range = ranges[next];
            if (range.StartSample >= end) break;
            var first = Math.Max(start, range.StartSample);
            var last = Math.Min(end, range.EndSample);
            if (last > first) meter.Append(samples.Slice((int)(first - start) * channels, (int)(last - first) * channels));
            if (range.EndSample > end) break;
            next++;
        }
    }

    internal double? Finish() => meter.Finish().IntegratedLufs();
}
