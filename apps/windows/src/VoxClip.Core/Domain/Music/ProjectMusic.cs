using System.Diagnostics.CodeAnalysis;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using VoxClip.Core.Domain.ContextDemo;
using VoxClip.Core.Domain.Shared;

namespace VoxClip.Core.Domain.Music;

/// <summary>Where a background track came from; doc/spec/music.md §2.</summary>
[JsonConverter(typeof(JsonStringEnumConverter<MusicSource>))]
public enum MusicSource
{
    /// <summary>A free library track (Openverse).</summary>
    [JsonStringEnumMemberName("library")] Library,
    /// <summary>Composed by Eleven Music.</summary>
    [JsonStringEnumMemberName("generated")] Generated,
    /// <summary>The user's own file.</summary>
    [JsonStringEnumMemberName("file")] File
}

/// <summary>The terms a track is used under; library tracks are cc0, by or pdm, never nc, nd or sa.</summary>
[JsonConverter(typeof(JsonStringEnumConverter<MusicLicense>))]
public enum MusicLicense
{
    /// <summary>CC0.</summary>
    [JsonStringEnumMemberName("cc0")] Cc0,
    /// <summary>CC BY.</summary>
    [JsonStringEnumMemberName("by")] By,
    /// <summary>Public Domain Mark.</summary>
    [JsonStringEnumMemberName("pdm")] Pdm,
    /// <summary>Eleven Music output.</summary>
    [JsonStringEnumMemberName("generated")] Generated,
    /// <summary>The user's own file.</summary>
    [JsonStringEnumMemberName("own")] Own
}

/// <summary>The track file under the Mac data folder's Music root; Windows keeps the reference and never reads the file.</summary>
public sealed record MusicAsset(string File, string Sha256, double DurationSeconds);

/// <summary>One background track under a clip, or the full video when ClipId is null; schema v4, doc/spec/music.md §2.
/// Every key is written, null included, as the Mac Core writes it.</summary>
public sealed record ProjectMusic(string Id, string? ClipId, MusicAsset Asset, MusicSource Source, string Title, string? Creator,
    MusicLicense License, string? Attribution, string? SourceUrl, string? Prompt, double GainDb, bool Ducking,
    double FadeInSeconds, double FadeOutSeconds, double StartOffsetSeconds);

/// <summary>Validation, pruning and the export refusal for the v4 music field. Windows opens, validates and saves music
/// unchanged; mixing it is Mac-only for now, so Windows export refuses with a reason.</summary>
public static class MusicProject
{
    /// <summary>The reason a Windows render or export of a project with music stops.</summary>
    public const string ExportUnsupportedMessage =
        "Windows cannot mix background music into exports yet. Export this project on a Mac, or remove its music there. Your music and edits are unchanged.";

    private const string Identifier = "[A-Za-z0-9][A-Za-z0-9._:-]{0,63}";
    private const string File = "[0-9a-f-]{36}/music-[a-z0-9][a-z0-9_-]{0,57}\\.(mp3|m4a|wav|aif|aiff|flac)";

    private static bool Matches(string? value, string pattern) => value is not null &&
        Regex.IsMatch(value, "\\A(?:" + pattern + ")\\z", RegexOptions.CultureInvariant, TimeSpan.FromSeconds(1));

    /// <summary>The typed rules: v4 only, clip identity, the project's own folder, one track per clip, offsets inside tracks.</summary>
    public static void Validate(Project project)
    {
        if (project.Music.Count == 0) return;
        Require(project.SchemaVersion == 4 && project.Music.Count <= 65);
        var clips = project.Edits.Clips.Select(clip => clip.Id).ToHashSet(StringComparer.Ordinal);
        var identities = new HashSet<string>(StringComparer.Ordinal);
        var scopes = new HashSet<string>(StringComparer.Ordinal);
        foreach (var entry in project.Music)
        {
            Require(entry is not null && entry.Asset is not null);
            Validate(entry!, project.Id);
            Require(identities.Add(entry!.Id) && (entry.ClipId is null || clips.Contains(entry.ClipId)) && scopes.Add(entry.ClipId ?? ""));
        }
    }

    private static void Validate(ProjectMusic entry, string projectId)
    {
        static bool Text(string? value, int maximum) => value is null || (value.Length is >= 1 && value.Length <= maximum && !value.Contains('\0'));
        var allowed = entry.Source switch
        {
            MusicSource.Library => entry.License is MusicLicense.Cc0 or MusicLicense.By or MusicLicense.Pdm,
            MusicSource.Generated => entry.License == MusicLicense.Generated,
            MusicSource.File => entry.License == MusicLicense.Own,
            _ => false
        };
        var duration = entry.Asset.DurationSeconds;
        Require(Matches(entry.Id, Identifier) && (entry.ClipId is null || Matches(entry.ClipId, Identifier)));
        Require(Matches(entry.Asset.File, File) && entry.Asset.File.StartsWith(projectId + "/", StringComparison.Ordinal));
        Require(Matches(entry.Asset.Sha256, "[0-9a-f]{64}") && double.IsFinite(duration) && duration is > 0 and <= 1800);
        Require(entry.Title is not null && Text(entry.Title, 200) && Text(entry.Creator, 200) && allowed);
        Require(Text(entry.Attribution, 1000) && (entry.License != MusicLicense.By || entry.Attribution is not null));
        Require(entry.SourceUrl is null || (entry.SourceUrl.Length <= 2048 && Matches(entry.SourceUrl, "https://[^\\s]+")));
        Require(entry.Source != MusicSource.Library || entry.SourceUrl is not null);
        Require(Text(entry.Prompt, 2000) && (entry.Source == MusicSource.Generated) == (entry.Prompt is not null));
        Require(double.IsFinite(entry.GainDb) && entry.GainDb is >= -40 and <= 0);
        Require(double.IsFinite(entry.FadeInSeconds) && entry.FadeInSeconds is >= 0 and <= 10);
        Require(double.IsFinite(entry.FadeOutSeconds) && entry.FadeOutSeconds is >= 0 and <= 10);
        Require(double.IsFinite(entry.StartOffsetSeconds) && entry.StartOffsetSeconds >= 0 && entry.StartOffsetSeconds < duration);
    }

    /// <summary>Strict wire shape: exact keys and JSON types, a non-empty list (absent when empty).</summary>
    internal static void ValidateWire(JsonElement value)
    {
        Require(value.ValueKind == JsonValueKind.Array && value.GetArrayLength() is >= 1 and <= 65);
        foreach (var entry in value.EnumerateArray())
        {
            Object(entry, "id clipId asset source title creator license attribution sourceUrl prompt gainDb ducking fadeInSeconds fadeOutSeconds startOffsetSeconds");
            var asset = entry.GetProperty("asset");
            Object(asset, "file sha256 durationSeconds");
            foreach (var key in new[] { "id", "source", "title", "license" }) Require(entry.GetProperty(key).ValueKind == JsonValueKind.String);
            foreach (var key in new[] { "clipId", "creator", "attribution", "sourceUrl", "prompt" })
                Require(entry.GetProperty(key).ValueKind is JsonValueKind.String or JsonValueKind.Null);
            foreach (var key in new[] { "gainDb", "fadeInSeconds", "fadeOutSeconds", "startOffsetSeconds" }) Number(entry.GetProperty(key));
            Require(entry.GetProperty("ducking").ValueKind is JsonValueKind.True or JsonValueKind.False);
            Require(asset.GetProperty("file").ValueKind == JsonValueKind.String && asset.GetProperty("sha256").ValueKind == JsonValueKind.String);
            Number(asset.GetProperty("durationSeconds"));
            var source = entry.GetProperty("source").GetString();
            var license = entry.GetProperty("license").GetString();
            Require(source is "library" or "generated" or "file" && license is "cc0" or "by" or "pdm" or "generated" or "own");
        }
    }

    /// <summary>Sets (or with null removes) the track under clipId, promoting the project to v4 on its first track.</summary>
    public static Project Setting(ProjectMusic? entry, string? clipId, Project project)
    {
        var kept = project.Music.Where(item => item.ClipId != clipId).ToList();
        var result = project with { Music = kept };
        if (entry is not null)
        {
            Require(entry.ClipId == clipId);
            result = ContextDemoProject.UpgradeToV4(result);
            result = result with { Music = kept.Append(entry).ToArray() };
        }
        Validate(result);
        return result;
    }

    /// <summary>Keeps tracks whose clip still exists and every full-video track.</summary>
    public static IReadOnlyList<ProjectMusic> Pruned(IReadOnlyList<ProjectMusic> music, IEnumerable<string> clipIds)
    {
        var identities = clipIds.ToHashSet(StringComparer.Ordinal);
        return music.Where(entry => entry.ClipId is null || identities.Contains(entry.ClipId)).ToArray();
    }

    private static void Object(JsonElement value, string keys)
    {
        Require(value.ValueKind == JsonValueKind.Object);
        Require(value.EnumerateObject().Select(property => property.Name).ToHashSet(StringComparer.Ordinal)
            .SetEquals(keys.Split(' ').ToHashSet(StringComparer.Ordinal)));
    }

    private static void Number(JsonElement value) =>
        Require(value.ValueKind == JsonValueKind.Number && value.TryGetDouble(out var number) && double.IsFinite(number));

    private static void Require([DoesNotReturnIf(false)] bool condition)
    {
        if (!condition) throw new VoxClipException(VoxClipErrorCode.ProjectUnreadable, "Invalid background music.");
    }
}
