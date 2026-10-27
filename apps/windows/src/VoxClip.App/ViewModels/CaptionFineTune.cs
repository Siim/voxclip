using System.Text.Json;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Shared;

namespace VoxClip.App.ViewModels;

internal static class CaptionFineTune
{
    internal static double TileWidth(double inner) => Math.Max(1, (inner - 8) / 2);
    internal static readonly (string Name, string Value)[] Colors = [("Yellow", "#FFE14D"), ("Green", "#4BE38A"), ("Cyan", "#5CE1FF"), ("Pink", "#FF6FAE"), ("Paper", "#F3F0E7"), ("White", "#FFFFFF")];
    internal static string Group(CaptionStyle style) => style.Tags.Contains("one-word") ? "Word by word"
        : style.Tags.Contains("phrase") ? "Phrase" : style.Tags.Contains("sentence") ? "Sentence" : "Other";
    internal static int GroupOrder(string group) => group switch { "Word by word" => 0, "Phrase" => 1, "Sentence" => 2, _ => 3 };
    internal static string TurnOn(string? remembered, string fallback) => !string.IsNullOrEmpty(remembered) && remembered != "off" ? remembered : fallback;
    internal static JsonObject Patch(ProjectCaptions captions) => captions.Overrides.ValueKind == JsonValueKind.Object
        ? JsonNode.Parse(captions.Overrides.GetRawText())!.AsObject() : [];
    internal static JsonElement Change(ProjectCaptions captions, string section, params (string Key, JsonNode? Value)[] changes)
    {
        var patch = Patch(captions);
        if (section.Length == 0)
        {
            foreach (var change in changes) { if (change.Value is null) patch.Remove(change.Key); else patch[change.Key] = change.Value; }
        }
        else
        {
            var child = patch[section] as JsonObject ?? new JsonObject();
            foreach (var change in changes) { if (change.Value is null) child.Remove(change.Key); else child[change.Key] = change.Value; }
            if (child.Count == 0) patch.Remove(section); else patch[section] = child;
        }
        return JsonSerializer.SerializeToElement(patch);
    }
    internal static string? Preset(Project project)
    {
        if (project.Export.Aspect != ExportAspect.Source) return project.Export.Aspect switch { ExportAspect.Portrait => "9:16", ExportAspect.Square => "1:1", _ => "16:9" };
        var video = project.Media.Source.Video;
        if (video is null) return null;
        var width = video.RotationDegrees is 90 or 270 ? video.Height : video.Width;
        var height = video.RotationDegrees is 90 or 270 ? video.Width : video.Height;
        return 16L * width == 9L * height ? "9:16" : 9L * width == 16L * height ? "16:9" : width == height ? "1:1" : null;
    }
    internal static ProjectCaptions Position(Project project, int choice)
    {
        CaptionPosition? value = choice < 2 ? new CaptionPosition(0.5, choice == 0 ? 0.2 : 0.5) : null;
        if (Preset(project) is not { } preset) return project.Captions with { Position = value };
        var positions = project.Captions.PositionByAspect.ToDictionary();
        if (value is null) positions.Remove(preset); else positions[preset] = value.Value;
        return project.Captions with { PositionByAspect = positions };
    }
    internal static CaptionPosition? StoredPosition(Project project) => Preset(project) is { } preset && project.Captions.PositionByAspect.TryGetValue(preset, out var position) ? position : project.Captions.Position;
    internal static ProjectCaptions Anchor(Project project, CaptionPosition value)
    {
        value = new(Math.Clamp(value.X, 0, 1), Math.Clamp(value.Y, 0, 1));
        if (Preset(project) is not { } preset) return project.Captions with { Position = value };
        var positions = project.Captions.PositionByAspect.ToDictionary(); positions[preset] = value;
        return project.Captions with { PositionByAspect = positions };
    }
    internal static bool Edited(Project project) => Patch(project.Captions).Count > 0 || StoredPosition(project) is not null;
    internal static string Summary(CaptionStyle style, Project project)
    {
        var patch = Patch(project.Captions);
        var preset = Preset(project);
        var video = project.Media.Source.Video;
        var width = video?.RotationDegrees is 90 or 270 ? video.Height : video?.Width ?? 16;
        var height = video?.RotationDegrees is 90 or 270 ? video.Width : video?.Height ?? 9;
        var aspect = preset switch { "9:16" => style.Aspects?.Portrait, "1:1" => style.Aspects?.Square, "16:9" => style.Aspects?.Landscape,
            _ => 10L * width < 9L * height ? style.Aspects?.Portrait : 9L * width > 10L * height ? style.Aspects?.Landscape : style.Aspects?.Square };
        var accent = patch["accent"]?.GetValue<string>() ?? style.Accent;
        var color = Colors.FirstOrDefault(color => string.Equals(color.Value, accent, StringComparison.OrdinalIgnoreCase)).Name ?? accent;
        var upper = patch["text"]?["transform"]?.GetValue<string>() is { } transform ? transform == "uppercase" : style.Text.Transform == CaptionTextTransformValue.Uppercase;
        var count = patch["layout"]?["maxWords"]?.GetValue<int>() ?? aspect?.MaxWords ?? style.Layout.MaxWords;
        var words = count >= 16 ? "Line" : count == 1 ? "1 word" : $"{count} words";
        return string.Join(" · ", new[] { style.Accent is not null ? color : null, upper ? "ALL CAPS" : "As said", words }.Where(value => value is not null));
    }
    internal static ProjectCaptions Reset(ProjectCaptions captions) => captions with { Overrides = JsonSerializer.SerializeToElement(new { }), Position = null, PositionByAspect = new Dictionary<string, CaptionPosition>() };
}
