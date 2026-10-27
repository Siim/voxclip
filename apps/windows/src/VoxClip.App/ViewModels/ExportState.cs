using System.Security.Cryptography;
using System.Text.Json;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;

namespace VoxClip.App.ViewModels;

internal sealed record ExportRecord(string ProjectId, string TargetId, DateTimeOffset ExportedAt, string PlanFingerprint, string StyleId, ExportAspect Aspect, string OutputPath);
internal readonly record struct ExportRowState(ClipExportState State, double? Progress = null)
{
    internal string Label => State switch
    {
        ClipExportState.Exported => "✓ Exported", ClipExportState.ChangedSinceExport => "⚠ Edited since export",
        ClipExportState.Exporting => Progress is { } fraction ? $"Exporting {Math.Clamp((int)Math.Round(fraction * 100), 0, 100)}%" : "Exporting…",
        ClipExportState.Failed => "⚠ Export failed", _ => ""
    };
}
internal static class ExportFingerprint
{
    internal static string TargetId(ExportTarget target) => target is ExportTarget.Clip clip ? clip.Id : "full";
    internal static string For(Project project, ExportTarget target)
    {
        var state = EditingEngine.FromProject(project);
        var words = state?.Transcript.Words ?? [];
        var first = 0; var last = words.Count - 1;
        if (target is ExportTarget.Clip selected)
        {
            var clip = project.Edits.Clips.First(clip => clip.Id == selected.Id);
            first = words.ToList().FindIndex(word => word.Id == clip.StartWordId);
            last = words.ToList().FindIndex(word => word.Id == clip.EndWordId);
        }
        var selectedWords = words.Skip(first).Take(Math.Max(0, last - first + 1)).ToArray();
        var ids = selectedWords.Select(word => word.Id).ToHashSet(StringComparer.Ordinal);
        var pauses = state?.Pauses.Where(pause => pause.AfterIndex >= first && pause.AfterIndex < last).ToArray() ?? [];
        var pauseIds = pauses.Select(pause => pause.Id).ToHashSet(StringComparer.Ordinal);
        var captions = project.Captions.Overrides.ValueKind == JsonValueKind.Undefined
            ? project.Captions with { Overrides = JsonSerializer.SerializeToElement(new { }) } : project.Captions;
        JsonElement? voice = null;
        if (project.SchemaVersion == 3)
        {
            using var document = JsonDocument.Parse(ProjectSerialization.Serialize(project));
            voice = document.RootElement.GetProperty("voiceLab").Clone();
        }
        var input = JsonSerializer.SerializeToElement(new
        {
            project.Media.Source.ContentKey, project.Media.Source.Video, project.Media.Source.DurationSeconds,
            Target = TargetId(target), Words = selectedWords, Language = state?.Transcript.Language,
            project.Edits.PauseThresholdSeconds, project.Edits.PauseKeepSeconds,
            CutWords = project.Edits.CutWordIds.Where(ids.Contains).Order(StringComparer.Ordinal).ToArray(),
            CutPauses = project.Edits.CutPauseIds.Where(pauseIds.Contains).Order(StringComparer.Ordinal).ToArray(),
            Corrections = project.Edits.Corrections.Where(pair => ids.Contains(pair.Key)).ToDictionary(),
            Captions = captions, project.Export.Aspect, VoiceLab = voice
        });
        using var stream = new MemoryStream();
        using (var writer = new Utf8JsonWriter(stream)) WriteCanonical(writer, input);
        return Convert.ToHexStringLower(SHA256.HashData(stream.ToArray()));
    }
    private static void WriteCanonical(Utf8JsonWriter writer, JsonElement value)
    {
        if (value.ValueKind == JsonValueKind.Object)
        {
            writer.WriteStartObject();
            foreach (var property in value.EnumerateObject().OrderBy(property => property.Name, StringComparer.Ordinal))
            { writer.WritePropertyName(property.Name); WriteCanonical(writer, property.Value); }
            writer.WriteEndObject();
        }
        else if (value.ValueKind == JsonValueKind.Array)
        { writer.WriteStartArray(); foreach (var item in value.EnumerateArray()) WriteCanonical(writer, item); writer.WriteEndArray(); }
        else value.WriteTo(writer);
    }
}
internal static class ExportProgressText
{
    internal static string Format(int current, int total, double? fraction, double elapsed)
    {
        var text = $"Rendering {current} of {total}";
        if (fraction is not { } progress) return text + "…";
        progress = Math.Clamp(progress, 0, 1);
        text += $" · {(int)Math.Round(progress * 100)}%";
        if (progress > 0 && progress < 1 && elapsed >= 1)
        {
            var remaining = elapsed / progress - elapsed;
            text += $" · about {Math.Max(1, (int)Math.Ceiling(remaining / 60))} min left";
        }
        return text;
    }
}
