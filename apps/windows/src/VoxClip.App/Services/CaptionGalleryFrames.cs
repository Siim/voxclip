using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Shared;
using VoxClip.Media.Thumbnails;

namespace VoxClip.App.Services;

internal static class CaptionGalleryFrames
{
    internal static async Task<PixelBuffer?> ReadAsync(Project project, string mediaPath, double time, CancellationToken ct)
    {
        var video = project.Media.Source.Video;
        if (video is null) return null;
        var oriented = video.RotationDegrees is 90 or 270 ? new PixelSize(video.Height, video.Width) : new PixelSize(video.Width, video.Height);
        var output = ExportPresets.OutputSize(oriented, project.Export.Aspect);
        const int width = 480;
        var height = Math.Max(1, (int)Math.Round(width * (double)output.Height / output.Width));
        return await CurrentFrames.ReadAsync(mediaPath, Math.Clamp(time, 0, Math.Max(0, project.Media.Source.DurationSeconds - 0.05)),
            video.RotationDegrees, new(width, height), output, ct).ConfigureAwait(false);
    }
}
