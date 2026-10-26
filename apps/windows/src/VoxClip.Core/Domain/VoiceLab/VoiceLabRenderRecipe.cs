#pragma warning disable CS1591
using System.Text.Json.Serialization;

namespace VoxClip.Core.Domain.VoiceLab;

[JsonConverter(typeof(JsonStringEnumConverter<VoiceLabSegmentScope>))]
public enum VoiceLabSegmentScope { [JsonStringEnumMemberName("passage")] Passage, [JsonStringEnumMemberName("fullTake")] FullTake }
[JsonConverter(typeof(JsonStringEnumConverter<VoiceLabCleanAudioMode>))]
public enum VoiceLabCleanAudioMode { [JsonStringEnumMemberName("off")] Off, [JsonStringEnumMemberName("on")] On }
public sealed record VoiceLabCleanAudio(VoiceLabCleanAudioMode Mode, string? AssetId, double? Mix);
[JsonConverter(typeof(JsonStringEnumConverter<VoiceLabVoiceStatus>))]
public enum VoiceLabVoiceStatus { [JsonStringEnumMemberName("active")] Active, [JsonStringEnumMemberName("deleted")] Deleted }
public sealed record VoiceLabVoiceReference(string Id, string Provider, string VoiceId, string ConsentRecordId, string DisplayName, VoiceLabVoiceStatus Status);
public sealed record VoiceLabRoomTone(long SourceStartSample, long SourceEndSample, double GainDb);
public sealed record VoiceLabVideoAsset(string Id, string File, string Sha256, double DurationSeconds, double FrameRate, int Width, int Height);
[JsonConverter(typeof(JsonStringEnumConverter<VoiceLabSeamKind>))]
public enum VoiceLabSeamKind { [JsonStringEnumMemberName("none")] None, [JsonStringEnumMemberName("gap")] Gap, [JsonStringEnumMemberName("hard")] Hard, [JsonStringEnumMemberName("synthToSynth")] SynthToSynth }
public sealed record VoiceLabSeam(VoiceLabSeamKind Kind, long FadeSamples, long SourceHandleSamples, long AssetHandleFrames);
public sealed record VoiceLabSeams(VoiceLabSeam In, VoiceLabSeam Out);
public sealed record VoiceLabChunk(long SourceStartSample, long SourceEndSample, string RequestId, uint Seed, string AssetId, string AssetSha256, long AssembledStartFrame, long AssembledEndFrame);
[JsonConverter(typeof(JsonStringEnumConverter<VoiceLabVideoMode>))]
public enum VoiceLabVideoMode { [JsonStringEnumMemberName("source")] Source, [JsonStringEnumMemberName("retimed")] Retimed, [JsonStringEnumMemberName("zoomCover")] ZoomCover, [JsonStringEnumMemberName("lipsync")] Lipsync }
public sealed record VoiceLabVideoRecipe(VoiceLabVideoMode Mode, long SourceStartSample, long SourceEndSample, long OutputSamples,
    double? RetimeFactor, double? Zoom, double? FaceX, double? FaceY, string? AssetId, string? Provider, string? Model,
    string? RequestId, long? WindowStartSample, long? WindowEndSample, string? SyncMode);
[JsonConverter(typeof(JsonStringEnumConverter<VoiceLabVoiceSource>))]
public enum VoiceLabVoiceSource { [JsonStringEnumMemberName("own")] Own, [JsonStringEnumMemberName("stock")] Stock }
public sealed record VoiceLabRenderQa(int? TranscriptTokens, bool? TranscriptExact, double? TranscriptMatch, double LufsJumpLu,
    double PeakDbfs, double? SpeakerScore, double? SpeakerThreshold, string? SpeakerModel, bool? SpeakerPassed);
public sealed record VoiceLabCost(string QuoteId, double? Usd);
public sealed record VoiceLabRenderRecipe(VoiceLabAudio Audio, IReadOnlyList<VoiceLabWord>? Words, double OutDuration, uint Seed, IReadOnlyList<VoiceLabChunk> Chunks,
    VoiceLabRoomTone? RoomTone, VoiceLabSeams Seams, VoiceLabVideoRecipe Video, VoiceLabRenderQa Qa,
    VoiceLabProvenance Provenance, VoiceLabCost Cost, VoiceLabVoiceSource VoiceSource, string? VoiceRefId, DateTimeOffset? ConsentVerifiedAt);
