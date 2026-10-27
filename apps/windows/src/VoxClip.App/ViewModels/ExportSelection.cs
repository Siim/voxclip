using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;

namespace VoxClip.App.ViewModels;

public enum ExportScopeKind { ThisClip, AllClips, FullVideo }
/// <summary>Freeze one export range before deriving the edit plan and captions.</summary>
public static class ExportSelection
{
    public static string AvailablePath(string requested)
    {
        var path = requested;
        for (var suffix = 2; File.Exists(path); suffix++) path = Path.Combine(Path.GetDirectoryName(requested)!, Path.GetFileNameWithoutExtension(requested) + " " + suffix + Path.GetExtension(requested));
        return path;
    }
    public static (string Mp4, string? Srt) Paths(string project, string? clip, ExportAspect aspect, bool srt, string folder, string pattern)
    {
        var title = string.Join("_", pattern.Replace("{project}", project, StringComparison.Ordinal).Replace("{clip}", clip ?? "full", StringComparison.Ordinal)
            .Replace("{aspect}", AspectSuffix(aspect), StringComparison.Ordinal).Split(Path.GetInvalidFileNameChars(), StringSplitOptions.RemoveEmptyEntries)).TrimEnd('.', ' ');
        if (title.Length > 180) title = string.Concat(title.EnumerateRunes().Take(90).Select(rune => rune.ToString()));
        var output = AvailablePath(Path.Combine(folder, (title.Length == 0 ? "VoxClip" : title) + ".mp4"));
        return (output, srt ? Path.ChangeExtension(output, ".srt") : null);
    }
    public static IReadOnlyList<ExportTarget> Targets(ExportScopeKind kind, string? selectedClipId, IReadOnlyList<string> keptIds) => kind switch
    {
        ExportScopeKind.FullVideo => [new ExportTarget.FullEdit()],
        ExportScopeKind.AllClips => keptIds.Select(id => (ExportTarget)new ExportTarget.Clip(id)).ToArray(),
        ExportScopeKind.ThisClip when selectedClipId is not null && keptIds.Contains(selectedClipId, StringComparer.Ordinal) => [new ExportTarget.Clip(selectedClipId)],
        _ => throw new ArgumentException("Choose a kept clip.", nameof(selectedClipId))
    };
    public static string AspectSuffix(ExportAspect aspect) => aspect switch
    {
        ExportAspect.Portrait => "9x16", ExportAspect.Square => "1x1", ExportAspect.Landscape => "16x9", _ => "source"
    };
    public static EditState? Scope(EditState? state, ExportTarget target)
    {
        if (state is null)
        {
            if (target is ExportTarget.Clip) throw new ArgumentException("A clip needs a transcript.", nameof(target));
            return null;
        }
        return target switch
        {
            ExportTarget.FullEdit => state with { ActiveClipId = null },
            ExportTarget.Clip clip when state.Clips.Any(item => item.Id == clip.Id) => state with { ActiveClipId = clip.Id },
            _ => throw new ArgumentException("Choose an existing clip.", nameof(target))
        };
    }
}
