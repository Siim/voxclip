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
            if (document.RootElement.TryGetProperty("schemaVersion", out var version))
            {
                if (version.ValueKind != JsonValueKind.Number || !version.TryGetInt32(out var number))
                    throw new JsonException("Invalid project schema version.");
                if (number > 3)
                    throw new VoxClipException(VoxClipErrorCode.ProjectTooNew, "This project was saved by a newer VoxClip. Update VoxClip to open it.");
                if (number == 3) ValidateV3EnumWire(document.RootElement);
            }
            var project = JsonSerializer.Deserialize(json, ProjectJsonContext.Default.Project) ?? throw new JsonException("Missing project.");
            Validate(project);
            return project;
        }
        catch (JsonException exception)
        {
            throw new VoxClipException(VoxClipErrorCode.ProjectUnreadable, "This project file can't be read.", exception);
        }
        catch (KeyNotFoundException exception)
        {
            throw new VoxClipException(VoxClipErrorCode.ProjectUnreadable, "This project file can't be read.", exception);
        }
    }
    private static void ValidateV3EnumWire(JsonElement root)
    {
        static JsonElement RequireKind(JsonElement element, string key, JsonValueKind kind)
        {
            if (element.ValueKind != JsonValueKind.Object || !element.TryGetProperty(key, out var value) || value.ValueKind != kind)
                throw new JsonException("Invalid Voice Lab render policy shape.");
            return value;
        }
        static void RequireKeys(JsonElement element, params string[] keys)
        {
            if (element.ValueKind != JsonValueKind.Object || keys.Any(key => !element.TryGetProperty(key, out _)))
                throw new JsonException("Incomplete Voice Lab render policy.");
        }
        static void Choice(JsonElement element, string key, params string[] values)
        {
            if (element.ValueKind != JsonValueKind.Object || !element.TryGetProperty(key, out var value) || value.ValueKind != JsonValueKind.String ||
                !values.Contains(value.GetString(), StringComparer.Ordinal)) throw new JsonException("Invalid Voice Lab enum.");
        }
        var voice = RequireKind(root, "voiceLab", JsonValueKind.Object);
        var clean = RequireKind(voice, "cleanAudio", JsonValueKind.Object);
        RequireKeys(clean, "mode", "assetId", "mix");
        Choice(clean, "mode", "off", "on");
        foreach (var reference in RequireKind(voice, "voices", JsonValueKind.Array).EnumerateArray()) Choice(reference, "status", "active", "deleted");
        foreach (var segment in RequireKind(voice, "segments", JsonValueKind.Array).EnumerateArray())
        {
            Choice(segment, "kind", "tts", "voiceChanger");
            Choice(segment, "scope", "passage", "fullTake");
            foreach (var candidate in RequireKind(segment, "candidates", JsonValueKind.Array).EnumerateArray())
            {
                if (candidate.ValueKind != JsonValueKind.Object) throw new JsonException("Invalid Voice Lab candidate shape.");
                if (!candidate.TryGetProperty("recipe", out var recipe) || recipe.ValueKind == JsonValueKind.Null)
                {
                    if (candidate.GetProperty("rejected").ValueKind == JsonValueKind.Null) throw new JsonException("Missing Voice Lab render recipe.");
                    continue;
                }
                RequireKeys(recipe, "audio", "words", "outDuration", "seed", "chunks", "roomTone", "seams", "video", "qa", "provenance", "cost", "voiceSource", "voiceRefId", "consentVerifiedAt");
                RequireKeys(RequireKind(recipe, "qa", JsonValueKind.Object), "transcriptTokens", "transcriptExact", "transcriptMatch", "lufsJumpLu", "peakDbfs", "speakerScore", "speakerThreshold", "speakerModel", "speakerPassed");
                Choice(recipe, "voiceSource", "own", "stock");
                Choice(RequireKind(recipe, "video", JsonValueKind.Object), "mode", "source", "retimed", "zoomCover", "lipsync");
                var seams = RequireKind(recipe, "seams", JsonValueKind.Object);
                Choice(RequireKind(seams, "in", JsonValueKind.Object), "kind", "none", "gap", "hard", "synthToSynth");
                Choice(RequireKind(seams, "out", JsonValueKind.Object), "kind", "none", "gap", "hard", "synthToSynth");
            }
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
        if (project.SchemaVersion > 3) throw new VoxClipException(VoxClipErrorCode.ProjectTooNew, "This project was saved by a newer VoxClip. Update VoxClip to open it.");
        if (project.Format != "voxclip-project" || project.SchemaVersion is not (1 or 2 or 3))
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
