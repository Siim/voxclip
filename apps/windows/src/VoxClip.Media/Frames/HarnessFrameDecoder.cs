using VoxClip.Core.Services.Project;
using VoxClip.Media.Pipeline;

namespace VoxClip.Media.Frames;

/// <summary>Decodes JPEG previews from a source already resolved by the project harness.</summary>
public static class HarnessFrameDecoder
{
    /// <summary>Read the specified local source times as JPEG previews.</summary>
    public static IReadOnlyList<HarnessFrame> Decode(string path, IReadOnlyList<double> times, CancellationToken ct)
    {
        using var reader = FfmpegFrameDecoder.OpenLocalQuickTime(path, 480, ct);
        return times.Select(time =>
        {
            var frame = reader.Read(time, ct);
            return new HarnessFrame(time, frame.Time, Convert.ToBase64String(FrameJpeg.Encode(frame.Pixels, 480, 72)));
        }).ToArray();
    }
}
