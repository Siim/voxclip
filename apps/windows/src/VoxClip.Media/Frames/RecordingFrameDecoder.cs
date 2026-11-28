using System.Security.Cryptography;
using System.Text;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.Project;
using VoxClip.Media.Pipeline;

namespace VoxClip.Media.Frames;

/// <summary>Present clock-addressed frames to the analyzer while keeping each native reader in its recording.</summary>
public sealed class RecordingFrameDecoder(Project project, ProjectClock clock, IProjectStore store, string projectPath) : IFrameDecoding
{
    /// <summary>The frame cache depends on both file content and its position on the project clock.</summary>
    public string ContentKey { get; } = Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(string.Join('\n', clock.Regions.Select(region =>
        FormattableString.Invariant($"{region.Key}:{region.OffsetSamples}:{region.DurationSamples}:{clock.SampleRate}"))))));

    /// <inheritdoc/>
    public IFrameReader Open(string source, int maximumEdge, double tolerance, CancellationToken ct) =>
        new Reader(project, clock, store, projectPath, maximumEdge, tolerance);

    private sealed class Reader(Project project, ProjectClock clock, IProjectStore store, string projectPath, int maximumEdge,
        double tolerance) : IFrameReader
    {
        private readonly Dictionary<string, IFrameReader> readers = new(StringComparer.Ordinal);

        public DecodedFrame Read(double time, CancellationToken ct)
        {
            if (clock.LocalTime(time) is not { } local)
                throw new VoxClipException(VoxClipErrorCode.DecodeFailed, "There is no recording at this time.");
            var recording = clock.Regions.First(region => region.Key == local.Key);
            if (!readers.TryGetValue(recording.Key, out var reader))
            {
                var path = RecordingRendering.RequirePathAsync(project, recording, store, projectPath, ct).GetAwaiter().GetResult();
                readers.Add(recording.Key, reader = new FfmpegFrameDecoder().Open(path, maximumEdge, tolerance, ct));
            }
            var frame = reader.Read(local.LocalSeconds, ct);
            return frame with { Time = clock.ClockTime(recording.Key, frame.Time) ?? time };
        }

        public void Dispose()
        {
            foreach (var reader in readers.Values) reader.Dispose();
        }
    }
}
