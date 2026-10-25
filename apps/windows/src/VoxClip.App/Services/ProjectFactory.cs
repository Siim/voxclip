using System.Text.Json;
using VoxClip.Core.Domain.Shared;

namespace VoxClip.App.Services;

internal static class ProjectFactory
{
    internal static Project Create(string path, MediaInfo media, string contentKey)
    {
        var now = DateTimeOffset.UtcNow;
        var settings = App.Services;
        var breath = settings.Get("editing.pauseBreath", "natural") switch { "tight" => 0.05, "relaxed" => 0.30, _ => 0.15 };
        return new("voxclip-project", 1, Guid.NewGuid().ToString(), now, now, new("VoxClip", AppServices.Version, "windows"),
            new(new(path, Path.GetFileName(path), new FileInfo(path).Length, media.DurationSeconds, contentKey, media.Video, media.Audio)), null,
            new(1, breath, [], [], new Dictionary<string, string>(), [], null),
            new(settings.Get("captions.defaultStyleId", "vox-highlight"), JsonDocument.Parse("{}").RootElement.Clone(), null, new Dictionary<string, CaptionPosition>()),
            new(settings.Get("export.defaultAspect", "source") switch { "16:9" => ExportAspect.Landscape, "9:16" => ExportAspect.Portrait, "1:1" => ExportAspect.Square, _ => ExportAspect.Source }, settings.Get("export.quality", "standard") == "high" ? ExportQuality.High : ExportQuality.Standard, settings.Get("export.srt", false), settings.Get("export.folder", Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyVideos), "VoxClip"))),
            new(new Dictionary<string, string>()), new([]), new([])) { Title = Path.GetFileNameWithoutExtension(path) };
    }
    internal static string AvailablePath(string requested)
    {
        var path = requested;
        for (var suffix = 2; File.Exists(path); suffix++) path = Path.Combine(Path.GetDirectoryName(requested)!, Path.GetFileNameWithoutExtension(requested) + " " + suffix + Path.GetExtension(requested));
        return path;
    }
}
