using System.Text.Json;
using VoxClip.Core.Domain.Transcript;

namespace VoxClip.App.Services;

internal static class RecordingTranscriptCache
{
    private static string? Entry(string key) => key.Length > 0 && key.All(Uri.IsHexDigit)
        ? Path.Combine(App.Services.Data.Cache, key, "transcripts", "confirmed-win-v1.json") : null;

    internal static async Task<Transcript?> ReadAsync(string key, CancellationToken token)
    {
        try
        {
            using var lease = await App.Services.CacheKeys.LeaseAsync(key, token);
            if (Entry(key) is { } path && File.Exists(path))
            {
                await using var stream = File.OpenRead(path);
                return await JsonSerializer.DeserializeAsync<Transcript>(stream, cancellationToken: token);
            }
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or JsonException) { }
        foreach (var recent in App.Services.Get<string[]>("general.recentProjects", []))
        {
            try
            {
                var project = (await App.Services.Projects.LoadAsync(recent, token)).Project;
                if (project.Media.Source.ContentKey == key && project.Transcript is { } transcript) return transcript;
                if (project.Media.SpokenSources?.FirstOrDefault(source => source.SourceKey == key) is { } spoken) return spoken.Transcript;
            }
            catch (Exception exception) when (exception is not (OperationCanceledException or OutOfMemoryException)) { }
        }
        return null;
    }

    internal static async Task WriteAsync(string key, Transcript transcript)
    {
        if (Entry(key) is not { } path) return;
        var temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            await using (var stream = File.Create(temporary)) await JsonSerializer.SerializeAsync(stream, transcript);
            File.Move(temporary, path, overwrite: true);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            try { File.Delete(temporary); }
            catch (Exception cleanup) when (cleanup is IOException or UnauthorizedAccessException) { }
        }
    }
}
