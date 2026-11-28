using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;

namespace VoxClip.Core.Services.Project;

/// <summary>Prepares a companion for a project-only timeline without allowing a cloud transcription.</summary>
public static class HarnessRecording
{
    internal static bool ValidKey(string key) => key.Length == 64 && key.All(character => character is >= '0' and <= '9' or >= 'a' and <= 'f');

    /// <summary>Find a transcript in this project that was made with a local engine.</summary>
    public static Transcript? LocalTranscription(Domain.Shared.Project project) =>
        project.Transcript is { Engine.Id: not TranscriptEngine.Elevenlabs } primary ? primary :
            project.Media.SpokenSources?.FirstOrDefault(source => source.Transcript.Engine.Id != TranscriptEngine.Elevenlabs)?.Transcript;

    /// <summary>Resolve only a companion already recorded in this project's media list.</summary>
    public static MediaReference Source(string key, Domain.Shared.Project project)
    {
        var source = project.Media.AdditionalSources?.FirstOrDefault(source => source.ContentKey == key);
        if (source is not { Video: not null, Audio: not null } || key == project.Media.Source.ContentKey ||
            project.Media.SpokenSources?.Any(spoken => spoken.SourceKey == key) == true)
            throw new HarnessException("Choose a companion that isn't already a spoken recording.");
        if (project.Transcript is null || LocalTranscription(project) is null) throw Refusal(source);
        if (project.Media.SpokenSources?.Count >= 5) throw new HarnessException("A project can have up to six spoken recordings.");
        return source;
    }

    /// <summary>Tell the user how to prepare a recording that the harness cannot transcribe.</summary>
    public static HarnessException Refusal(MediaReference source) => new($"Transcribe {ProjectClock.Label(source)} in VoxClip first.");

    /// <summary>Append a local transcript through the recording reducer.</summary>
    public static Domain.Shared.Project Add(string key, Transcript transcript, Domain.Shared.Project project)
    {
        var source = Source(key, project);
        if (transcript.Engine.Id == TranscriptEngine.Elevenlabs) throw Refusal(source);
        return RecordingEdits.Apply(new RecordingEdit.AddSpokenSource(key, transcript), project) switch
        {
            RecordingEditResult.Applied applied => applied.Project,
            RecordingEditResult.Refused refused => throw new HarnessException(refused.Message),
            _ => throw Refusal(source)
        };
    }

    /// <summary>Read a confirmed local transcript for a media content key, if available.</summary>
    public static Transcript? CachedTranscript(string key, string cache) => RecordingTranscriptCache.Read(key, cache, localOnly: true);

    /// <summary>Remember a confirmed local transcript for another project using the same media.</summary>
    public static void CacheTranscript(string key, string cache, Transcript transcript)
    {
        if (transcript.Engine.Id != TranscriptEngine.Elevenlabs) RecordingTranscriptCache.Write(key, cache, transcript);
    }
}
