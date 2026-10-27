using System.Text.Json;
using System.Text.Json.Serialization;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.VoiceLab;
using TranscriptModel = VoxClip.Core.Domain.Transcript.Transcript;
namespace VoxClip.Core.Domain.Shared;

/// <summary>Portable project document; architecture §3, editing §10 and shared/schemas/project.schema.json.</summary>
[JsonUnmappedMemberHandling(JsonUnmappedMemberHandling.Disallow)]
public sealed record Project(string Format, int SchemaVersion, string Id, DateTimeOffset CreatedAt,
    DateTimeOffset ModifiedAt, SavedBy SavedBy, ProjectMedia Media, TranscriptModel? Transcript,
    ProjectEdits Edits, ProjectCaptions Captions, ProjectExport Export, ProjectShare Share, ProjectAi Ai, VoiceLabPlaceholder VoiceLab)
{
    /// <summary>Optional project title, absent rather than null; project schema.</summary>
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? Title { get; init; }
    /// <summary>Unknown reverse-DNS fork entries preserved unchanged; editing §10.7.</summary>
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public IReadOnlyDictionary<string, JsonElement>? Extensions { get; init; }
}

/// <summary>Writer identity; runtime release version or schema-valid 0.0.0 fallback. Editing §10.2.</summary>
public sealed record SavedBy(string App, string Version, string Platform);

/// <summary>Source media wrapper; project schema $defs/mediaReference.</summary>
public sealed record ProjectMedia(MediaReference Source);

/// <summary>Relinkable media reference; editing §10.3. Source content key does not change after a move.</summary>
public sealed record MediaReference(string AbsolutePath, string? RelativePath, long SizeBytes,
    double DurationSeconds, string ContentKey, VideoTrackInfo? Video, AudioTrackInfo? Audio);

/// <summary>Stored source video facts, before display rotation; project schema.</summary>
public sealed record VideoTrackInfo(int Width, int Height, double FrameRate, int RotationDegrees);

/// <summary>Stored native audio rate and channel count; project schema.</summary>
public sealed record AudioTrackInfo(int SampleRate, int Channels);

/// <summary>Persisted edit layer; editing §2.5. Derived pauses and transcript are deliberately not serialized twice.</summary>
public sealed record ProjectEdits(double PauseThresholdSeconds, double PauseKeepSeconds,
    IReadOnlyList<string> CutWordIds, IReadOnlyList<string> CutPauseIds, IReadOnlyDictionary<string, string> Corrections,
    IReadOnlyList<ClipRange> Clips, string? ActiveClipId);

/// <summary>Caption choices and merge patch; project schema $defs/captions.</summary>
public sealed record ProjectCaptions(string StyleId, JsonElement Overrides, CaptionPosition? Position,
    IReadOnlyDictionary<string, CaptionPosition> PositionByAspect);

/// <summary>Stored export choices only; project schema $defs/export. Dimensions, frame rate and bitrate are derived.</summary>
public sealed record ProjectExport(ExportAspect Aspect, ExportQuality Quality, bool Srt, string? Folder);

/// <summary>Share text keyed by full or an existing clip id; project schema $defs/share and editing §10.</summary>
public sealed record ProjectShare(IReadOnlyDictionary<string, string> Captions);

/// <summary>Cached clip-finding runs; editing §10.6.</summary>
public sealed record ProjectAi(IReadOnlyList<AiResult> Results);

/// <summary>Version 1 has only empty segments; version 2 adds typed paid assets and replacements.</summary>
public sealed record VoiceLabPlaceholder(IReadOnlyList<VoiceLabSegment> Segments)
{
    /// <summary>Absent in version 1 and required in version 2.</summary>
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public IReadOnlyList<VoiceLabAsset>? Assets { get; init; }
    /// <summary>Explicit clean-audio policy for schema v3; absent in older projects.</summary>
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] public VoiceLabCleanAudio? CleanAudio { get; init; }
    /// <summary>Owned voice references and consent identities, without recordings or embeddings.</summary>
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] public IReadOnlyList<VoiceLabVoiceReference>? Voices { get; init; }
    /// <summary>Generated video assets used only by explicit future video modes.</summary>
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] public IReadOnlyList<VoiceLabVideoAsset>? VideoAssets { get; init; }
}
