using System.Text.Json;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;

namespace VoxClip.Core.Services.Project;

/// <summary>Confirmed recording transcripts shared by the editor and the project harness.</summary>
public static class RecordingTranscriptCache
{
    private const string Local = "confirmed-local-v1.json";
    private const string Cloud = "confirmed-cloud-v1.json";
    private static readonly ProjectJsonContext LegacyWindowsReader = new(new JsonSerializerOptions
        { PropertyNameCaseInsensitive = true, RespectRequiredConstructorParameters = true });

    /// <summary>Prefer a local result; the harness never reads a cloud transcript.</summary>
    public static Transcript? Read(string key, string cache, bool localOnly = false)
    {
        if (!HarnessRecording.ValidKey(key)) return null;
        var directory = Path.Combine(cache, key, "transcripts");
        if (ReadEntry(Local) is { Engine.Id: not TranscriptEngine.Elevenlabs } local) return local;
        var legacy = ReadEntry("confirmed-v1.json");
        var legacyWindows = ReadEntry("confirmed-win-v1.json", LegacyWindowsReader);
        if (legacy is { Engine.Id: not TranscriptEngine.Elevenlabs }) return legacy;
        if (legacyWindows is { Engine.Id: not TranscriptEngine.Elevenlabs }) return legacyWindows;
        return localOnly ? null : ReadEntry(Cloud) ?? legacyWindows ?? legacy;

        Transcript? ReadEntry(string name, ProjectJsonContext? codec = null)
        {
            try
            {
                using var stream = File.OpenRead(Path.Combine(directory, name));
                var transcript = JsonSerializer.Deserialize(stream, (codec ?? ProjectJsonContext.Default).Transcript);
                return transcript is { SchemaVersion: 1, PipelineVersion: >= 1, Engine: not null, Words: not null, RawKey: not null } &&
                    Enum.IsDefined(transcript.Engine.Id) && transcript.Words.All(word => word is { Id: not null, Text: not null }) ? transcript : null;
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or JsonException) { return null; }
        }
    }

    /// <summary>Remember the result without replacing the other engine's confirmed transcript.</summary>
    public static void Write(string key, string cache, Transcript transcript)
    {
        if (!HarnessRecording.ValidKey(key)) return;
        var directory = Path.Combine(cache, key, "transcripts");
        var target = Path.Combine(directory, transcript.Engine.Id == TranscriptEngine.Elevenlabs ? Cloud : Local);
        var temporary = target + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            Directory.CreateDirectory(directory);
            using (var stream = File.Create(temporary)) JsonSerializer.Serialize(stream, transcript, ProjectJsonContext.Default.Transcript);
            File.Move(temporary, target, overwrite: true);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            try { File.Delete(temporary); }
            catch (Exception cleanup) when (cleanup is IOException or UnauthorizedAccessException) { }
        }
    }
}
