using System.Text.Json;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;

namespace VoxClip.Core.Services.Project;

/// <summary>Prepares a companion for a project-only timeline without allowing a cloud transcription.</summary>
public static class HarnessRecording
{
    internal static bool ValidKey(string key) => key.Length == 64 && key.All(character => character is >= '0' and <= '9' or >= 'a' and <= 'f');

    /// <summary>Resolve only a companion already recorded in this project's media list.</summary>
    public static MediaReference Source(string key, Domain.Shared.Project project)
    {
        var source = project.Media.AdditionalSources?.FirstOrDefault(source => source.ContentKey == key);
        if (source is not { Video: not null, Audio: not null } || key == project.Media.Source.ContentKey ||
            project.Media.SpokenSources?.Any(spoken => spoken.SourceKey == key) == true)
            throw new HarnessException("Choose a companion that isn't already a spoken recording.");
        if (project.Transcript?.Engine.Id != TranscriptEngine.Whispercpp) throw Refusal(source);
        if (project.Media.SpokenSources?.Count >= 5) throw new HarnessException("A project can have up to six spoken recordings.");
        return source;
    }

    /// <summary>Tell the user how to prepare a recording that the harness cannot transcribe.</summary>
    public static HarnessException Refusal(MediaReference source) => new($"Transcribe {ProjectClock.Label(source)} in VoxClip first.");

    /// <summary>Append a local transcript through the recording reducer.</summary>
    public static Domain.Shared.Project Add(string key, Transcript transcript, Domain.Shared.Project project)
    {
        var source = Source(key, project);
        if (transcript.Engine.Id != TranscriptEngine.Whispercpp) throw Refusal(source);
        return RecordingEdits.Apply(new RecordingEdit.AddSpokenSource(key, transcript), project) switch
        {
            RecordingEditResult.Applied applied => applied.Project,
            RecordingEditResult.Refused refused => throw new HarnessException(refused.Message),
            _ => throw Refusal(source)
        };
    }

    /// <summary>Read a confirmed local transcript for a media content key, if available.</summary>
    public static Transcript? CachedTranscript(string key, string cache)
    {
        if (!ValidKey(key)) return null;
        try
        {
            var transcript = JsonSerializer.Deserialize(File.ReadAllText(CacheFile(key, cache)), ProjectJsonContext.Default.Transcript);
            return transcript?.Engine.Id == TranscriptEngine.Whispercpp ? transcript : null;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or JsonException) { return null; }
    }

    /// <summary>Remember a confirmed local transcript for another project using the same media.</summary>
    public static void CacheTranscript(string key, string cache, Transcript transcript)
    {
        if (!ValidKey(key) || transcript.Engine.Id != TranscriptEngine.Whispercpp) return;
        var target = CacheFile(key, cache);
        var temporary = target + "." + Guid.NewGuid().ToString("N");
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(target)!);
            File.WriteAllText(temporary, JsonSerializer.Serialize(transcript, ProjectJsonContext.Default.Transcript));
            File.Move(temporary, target, overwrite: true);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            try { File.Delete(temporary); }
            catch (Exception cleanup) when (cleanup is IOException or UnauthorizedAccessException) { }
        }
    }

    private static string CacheFile(string key, string cache) => Path.Combine(cache, key, "transcripts", "confirmed-v1.json");
}
