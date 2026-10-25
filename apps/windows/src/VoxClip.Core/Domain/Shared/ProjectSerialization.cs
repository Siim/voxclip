using System.Text.Json;
using VoxClip.Core.Domain.VoiceLab;
namespace VoxClip.Core.Domain.Shared;

/// <summary>Schema-v1 encoding boundary; architecture §3 and editing §10. Store implementation adds reference cleanup and atomic I/O.</summary>
public static class ProjectSerialization
{
    /// <summary>Read a project with source-generated metadata; unknown keys are refused except inside extensions and merge patches.</summary>
    public static Project Deserialize(string json)
    {
        try
        {
            using var document = JsonDocument.Parse(json);
            if (document.RootElement.ValueKind != JsonValueKind.Object) throw new JsonException("Expected a project object.");
            if (document.RootElement.TryGetProperty("schemaVersion", out var version) && version.TryGetInt32(out var number) && number > 2)
                throw new VoxClipException(VoxClipErrorCode.ProjectTooNew, "This project was saved by a newer VoxClip. Update VoxClip to open it.");
            var project = JsonSerializer.Deserialize(json, ProjectJsonContext.Default.Project) ?? throw new JsonException("Missing project.");
            Validate(project);
            return project;
        }
        catch (JsonException exception)
        {
            throw new VoxClipException(VoxClipErrorCode.ProjectUnreadable, "This project file can't be read.", exception);
        }
    }
    /// <summary>UTF8-compatible JSON with stable timestamps and LF terminator; source word doubles retain round-trip precision.</summary>
    public static string Serialize(Project project)
    {
        Validate(project);
        return JsonSerializer.Serialize(project, ProjectJsonContext.Default.Project) + "\n";
    }
    /// <summary>Validate format, v1 placeholder and immutable word invariants; editing §2.2 and §10.4.</summary>
    public static void Validate(Project project)
    {
        if (project.SchemaVersion > 2) throw new VoxClipException(VoxClipErrorCode.ProjectTooNew, "This project was saved by a newer VoxClip. Update VoxClip to open it.");
        if (project.Format != "voxclip-project" || project.SchemaVersion is not (1 or 2))
            throw new VoxClipException(VoxClipErrorCode.ProjectUnreadable, "Invalid project format.");
        if (project.Transcript is { } transcript)
        {
            var ids = new HashSet<string>(StringComparer.Ordinal);
            var previous = double.NegativeInfinity;
            foreach (var word in transcript.Words)
            {
                if (!double.IsFinite(word.Start) || !double.IsFinite(word.End) || word.Start < 0 || word.End <= word.Start || word.Start < previous ||
                    !ids.Add(word.Id) || word.Timing == VoxClip.Core.Domain.Transcript.TimingSource.Estimated)
                    throw new VoxClipException(VoxClipErrorCode.ProjectUnreadable, "The transcript contains invalid source timings or ids.");
                previous = word.Start;
            }
        }
        VoiceLabProject.Validate(project);
    }
}
