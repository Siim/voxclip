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
        var state = ExportSelection.Scope(EditingEngine.FromProject(project), target);
        var media = ExportRenderInput.Media(project);
        var plan = ExportRenderInput.Plan(media, state);
        var output = ExportRenderInput.Output(media, project.Export);
        object? voice = null;
        if (project.SchemaVersion == 3)
        {
            var scope = target is ExportTarget.Clip clip ? VoxClip.Core.Domain.VoiceLab.VoiceLabOutputScope.Clip(clip.Id) : VoxClip.Core.Domain.VoiceLab.VoiceLabOutputScope.Full;
            var prepared = VoxClip.Core.Domain.VoiceLab.VoiceLabRenderContract.Prepare(project, scope, VoxClip.Core.Domain.VoiceLab.VoiceLabLabelPosition.TopRight);
            voice = new
            {
                prepared.OutputPlan, prepared.Disclosure,
                Recipes = prepared.SelectedSegmentRecipes.Select(item => new
                {
                    item.Piece, item.Recipe.Audio, item.Recipe.RoomTone, item.Recipe.Seams,
                    Video = new { item.Recipe.Video.Mode, item.Recipe.Video.SourceStartSample, item.Recipe.Video.SourceEndSample,
                        item.Recipe.Video.OutputSamples, item.Recipe.Video.RetimeFactor, item.Recipe.Video.Zoom, item.Recipe.Video.FaceX, item.Recipe.Video.FaceY },
                    Asset = project.VoiceLab.Assets!.Where(asset => asset.Id == item.Recipe.Audio.AssetId)
                        .Select(asset => new { asset.Sha256, asset.SampleRate, asset.DurationSeconds }).Single()
                }).ToArray()
            };
        }
        // With captions off the export builds no caption track, so caption-only inputs cannot change the render.
        var captionsOn = project.Captions.StyleId != "off";
        var input = JsonSerializer.SerializeToElement(new
        {
            Version = 2, project.Media.Source.ContentKey,
            Source = new { media.DurationSeconds, media.OrientedSize, media.Video?.RotationDegrees,
                FrameRate = media.Video?.FrameRate, SampleRate = media.Audio?.SampleRate, Channels = media.Audio?.Channels },
            Plan = plan, CaptionWords = state is null || !captionsOn ? null : EditingEngine.CaptionWords(state, plan),
            Language = captionsOn ? state?.Transcript.Language : null,
            Captions = captionsOn ? (object)new { project.Captions.StyleId,
                Overrides = project.Captions.Overrides.ValueKind == JsonValueKind.Undefined ? JsonSerializer.SerializeToElement(new { }) : project.Captions.Overrides,
                Position = VoxClip.Core.Domain.Captions.CaptionEngine.StoredPosition(project.Captions, output.Size) } : new { project.Captions.StyleId },
            project.Export.Quality, Output = output, VoiceLab = voice
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
