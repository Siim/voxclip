using VoxClip.Core.Domain.Transcript;
using CoreCache = VoxClip.Core.Services.Project.RecordingTranscriptCache;

namespace VoxClip.App.Services;

internal static class RecordingTranscriptCache
{
    internal static async Task<Transcript?> ReadAsync(string key, CancellationToken token)
    {
        try
        {
            using var lease = await App.Services.CacheKeys.LeaseAsync(key, token);
            var cache = App.Services.Data.Cache;
            if (await Task.Run(() => CoreCache.Read(key, cache), token) is { } cached) return cached;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException) { }
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
        var cache = App.Services.Data.Cache;
        await Task.Run(() => CoreCache.Write(key, cache, transcript));
    }
}
