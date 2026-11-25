using System.Globalization;
using System.Security.Cryptography;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Autopilot;
using VoxClip.Core.Domain.Music;
using VoxClip.Core.Domain.Shared;
using VoxClip.Media.Pipeline;

namespace VoxClip.Cli;

internal static class CliMusic
{
    internal static MusicRenderInput Saved(string trackId, Project? project, string dataRoot)
    {
        var entry = project?.Music.FirstOrDefault(item => item.Id == trackId)
            ?? throw new CliUsageException("The requested music track does not exist in the project.");
        var path = MusicRenderInput.PathFor(entry.Asset, dataRoot);
        if (!File.Exists(path)) throw new CliUsageException("The requested music track's file is missing.");
        return new(entry, path);
    }

    internal static async Task<MusicRenderInput> LocalAsync(string path, CancellationToken ct)
    {
        var file = new FileInfo(OutputSafety.Resolve(path));
        if (file.Extension.ToLowerInvariant() is not (".mp3" or ".m4a" or ".wav" or ".aif" or ".aiff" or ".flac") ||
            !file.Exists || (file.Attributes & FileAttributes.Device) != 0 || file.Length is <= 0 or > 200 * 1024 * 1024)
            throw new CliUsageException("--music-file needs a local MP3, M4A, WAV, AIFF or FLAC audio file up to 200 MB.");
        MediaInfo media;
        try { media = await new FfmpegMediaProbe().ProbeAsync(file.FullName, ct).ConfigureAwait(false); }
        catch (VoxClipException exception) when (exception.Code == VoxClipErrorCode.DecodeFailed)
        { throw new CliUsageException("--music-file needs a playable audio track up to 30 minutes long."); }
        if (media.Audio is null || media.DurationSeconds is <= 0 or > 1800)
            throw new CliUsageException("--music-file needs a playable audio track up to 30 minutes long.");
        using var stream = file.OpenRead();
        var hash = Convert.ToHexStringLower(await SHA256.HashDataAsync(stream, ct).ConfigureAwait(false));
        return new(new("file-" + hash[..16], null, new(file.Name, hash, media.DurationSeconds), MusicSource.File,
            Path.GetFileNameWithoutExtension(path), null, MusicLicense.Own, null, null, null, -20, true, 0.5, 1.5, 0), file.FullName);
    }

    internal static JsonObject? Json(ProjectMusic? entry) => entry is null ? null : new()
    {
        ["trackId"] = entry.Id, ["title"] = entry.Title, ["gainDb"] = entry.GainDb, ["ducking"] = entry.Ducking
    };

    internal static ProjectMusic? AutopilotTrack(ClipAutopilotPlan plan, string clipId, Project project,
        IReadOnlyList<ProjectMusic> saved, string dataRoot)
    {
        if (plan.PickedMusic is not { } picked || project.Music.Count >= 65) return null;
        var available = saved.Where(entry => File.Exists(MusicRenderInput.PathFor(entry.Asset, dataRoot))).ToArray();
        foreach (var cue in plan.MusicChoices.Where(item => item != picked).Prepend(picked))
        {
            var title = MusicWords.Split(cue.Title).ToArray();
            var mood = MusicWords.Split(cue.Mood).Where(word => word.Length >= 3).ToArray();
            var match = available.FirstOrDefault(entry => title.Length > 0 && title.SequenceEqual(MusicWords.Split(entry.Title)))
                ?? available.FirstOrDefault(entry => mood.Length > 0 &&
                    mood.All(MusicWords.Split(entry.Title + " " + entry.Prompt).ToHashSet(StringComparer.Ordinal).Contains));
            if (match is null) continue;
            var taken = project.Music.Select(entry => entry.Id).ToHashSet(StringComparer.Ordinal);
            var id = match.Id;
            for (var index = 2; taken.Contains(id); index++)
            {
                var suffix = "-" + index.ToString(CultureInfo.InvariantCulture);
                id = match.Id[..Math.Min(match.Id.Length, 64 - suffix.Length)] + suffix;
            }
            return match with { Id = id, ClipId = clipId };
        }
        return null;
    }
}
