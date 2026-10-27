#pragma warning disable CS1591 // Public wire records are documented together in ADR-R24 and voice-lab.md §10.
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Editing;

namespace VoxClip.Core.Domain.VoiceLab;

/// <summary>Schema-v2 source-preserving synthetic asset; ADR-R24.</summary>
public sealed record VoiceLabAsset(string Id, string Kind, string File, string Sha256, double DurationSeconds, int SampleRate, DateTimeOffset CreatedAt);
[JsonConverter(typeof(JsonStringEnumConverter<VoiceLabSegmentKind>))]
public enum VoiceLabSegmentKind
{
    [JsonStringEnumMemberName("tts")] Tts,
    [JsonStringEnumMemberName("voiceChanger")] VoiceChanger
}
public sealed record VoiceLabReplacement(double Start, double End, string FirstWordId, string LastWordId);
public sealed record VoiceLabAudio(string AssetId, double TrimStart, double TrimEnd, double Stretch, double GainDb);
public sealed record VoiceLabText(string Original, string New);
public sealed record VoiceLabWord(string Text, double Start, double End, bool Synthetic);
public sealed record VoiceLabCandidate(string? AssetId, double? Score, string? Rejected)
{
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] public VoiceLabRenderRecipe? Recipe { get; init; }
}
public sealed record VoiceLabProvenance(string Provider, string Endpoint, string Model, string VoiceId,
    string? ConsentRecordId, string? RequestId, uint? Seed, DateTimeOffset CreatedAt)
{
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] public string? Region { get; init; }
}
public sealed record VoiceLabQa(double? TranscriptMatch, double? LufsJumpLu, double? PeakDbfs, double? SpeakerScore);
public sealed record VoiceLabSegment(string Id, VoiceLabSegmentKind Kind, bool Enabled, VoiceLabReplacement Replace,
    double OutDuration, VoiceLabAudio Audio, VoiceLabText? Text, IReadOnlyList<VoiceLabWord>? Words,
    VoiceLabProvenance Provenance, VoiceLabQa Qa, IReadOnlyList<VoiceLabCandidate> Candidates, int SelectedCandidateIndex)
{
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] public VoiceLabSegmentScope? Scope { get; init; }
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] public string? GroupId { get; init; }
}
public enum VoiceLabProjectErrorCode
{
    InvalidAsset, UnsafePath, InvalidSegment, InvalidRange, InvalidWords, DanglingAsset,
    OverlappingReplacement, MissingSegment, InvalidCandidate, UnsupportedRendering, InvalidScope,
    MissingRenderPolicy, NeedsVoiceLabUpgrade, VideoModeUnsupported, AlignmentUnavailable, ConsentUnverified,
    QaRejected, InvalidFadeHandles, OverlappingFades, UnsupportedAssetFormat, CleanAudioUnsupported, StaleRenderContract, EndpointUnsupported,
    LegacySegmentsNeedReview, RequiresVersion3, InvalidVoice, MissingVoice
}
public sealed class VoiceLabProjectException(VoiceLabProjectErrorCode code) : Exception(code.ToString())
{
    public VoiceLabProjectErrorCode Code { get; } = code;
}

/// <summary>The §10.1 paid-asset file rule, shared by Core validation (also for §10.5 video assets) and the Media writers that name new assets.</summary>
public static class VoiceLabAssetNaming
{
    /// <summary>Returns the relative <c>projectId/assetId.wav</c> or <c>.flac</c> name under the caller's paid Voice Lab store.</summary>
    public static string File(string projectId, string assetId, string fileExtension)
        => SafeFile(projectId, assetId, fileExtension) ?? throw new VoiceLabProjectException(VoiceLabProjectErrorCode.InvalidAsset);
    internal static bool IsSafeProjectId(string projectId) => VoiceLabProject.Matches(projectId, "[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}");
    internal static string? SafeFile(string projectId, string assetId, string fileExtension)
        => fileExtension is "wav" or "flac" ? SafeName(projectId, assetId, fileExtension) : null;
    /// <summary>A §10.5 video asset follows the same rule, always with the <c>mp4</c> extension.</summary>
    internal static string? SafeVideoFile(string projectId, string assetId) => SafeName(projectId, assetId, "mp4");
    static string? SafeName(string projectId, string assetId, string fileExtension)
        => IsSafeProjectId(projectId) && VoiceLabProject.Matches(assetId, "[a-z0-9][a-z0-9_-]{0,63}") &&
            !VoiceLabProject.Matches(assetId, "con|prn|aux|nul|com[1-9]|lpt[1-9]") ? projectId + "/" + assetId + "." + fileExtension : null;
}

/// <summary>Pure validation and immutable project transitions; does not delete paid assets.</summary>
public static class VoiceLabProject
{
    private const string Id = "[A-Za-z0-9][A-Za-z0-9._:-]{0,63}";
    /// <summary>The ElevenLabs client's path-safe ID rule, anchored so a trailing newline is refused.</summary>
    private const string ProviderVoiceId = "[A-Za-z0-9_-]{1,128}";
    internal static bool Matches(string value, string pattern) => Regex.IsMatch(value, "\\A(?:" + pattern + ")\\z", RegexOptions.CultureInvariant);
    private static void Require(bool condition, VoiceLabProjectErrorCode code)
    {
        if (!condition) throw new VoiceLabProjectException(code);
    }
    public static void Validate(Project project)
    {
        if (project.SchemaVersion == 1)
        {
            Require(project.VoiceLab.Segments.Count == 0 && project.VoiceLab.Assets is null && project.VoiceLab.CleanAudio is null && project.VoiceLab.Voices is null && project.VoiceLab.VideoAssets is null, VoiceLabProjectErrorCode.InvalidSegment);
            return;
        }
        Require(project.SchemaVersion is 2 or 3 && project.VoiceLab.Assets is not null, VoiceLabProjectErrorCode.InvalidSegment);
        if (project.SchemaVersion == 2) Require(project.VoiceLab.CleanAudio is null && project.VoiceLab.Voices is null && project.VoiceLab.VideoAssets is null &&
            project.VoiceLab.Segments.All(segment => segment.Scope is null && segment.GroupId is null && segment.Provenance.Region is null && segment.Candidates.All(candidate => candidate.Recipe is null)), VoiceLabProjectErrorCode.InvalidSegment);
        Require(VoiceLabAssetNaming.IsSafeProjectId(project.Id), VoiceLabProjectErrorCode.UnsafePath);
        var assets = project.VoiceLab.Assets!;
        var assetIds = assets.Select(asset => asset.Id).ToHashSet(StringComparer.Ordinal);
        Require(assetIds.Count == assets.Count, VoiceLabProjectErrorCode.InvalidAsset);
        foreach (var asset in assets)
        {
            Require(Matches(asset.Id, Id) && asset.Kind == "audio" && Matches(asset.Sha256, "[0-9a-f]{64}") &&
                double.IsFinite(asset.DurationSeconds) && asset.DurationSeconds > 0 && asset.SampleRate > 0, VoiceLabProjectErrorCode.InvalidAsset);
            // A stored file must be exactly the §10.1 name for its own asset ID.
            Require(VoiceLabAssetNaming.SafeFile(project.Id, asset.Id, asset.File[(asset.File.LastIndexOf('.') + 1)..]) == asset.File,
                VoiceLabProjectErrorCode.UnsafePath);
        }
        var words = project.Transcript?.Words ?? [];
        var sourceRate = (double)(project.Media.Source.Audio?.SampleRate ?? 48000);
        Require(sourceRate > 0 && double.IsFinite(project.Media.Source.DurationSeconds) &&
            project.Media.Source.DurationSeconds * sourceRate < long.MaxValue, VoiceLabProjectErrorCode.InvalidRange);
        var sourceWordIds = new HashSet<string>(StringComparer.Ordinal);
        Require(words.All(word => Matches(word.Id, Id) && sourceWordIds.Add(word.Id)), VoiceLabProjectErrorCode.InvalidRange);
        var indices = words.Select((word, index) => (word.Id, index)).ToDictionary(pair => pair.Id, pair => pair.index, StringComparer.Ordinal);
        var ids = new HashSet<string>(StringComparer.Ordinal);
        var enabled = new List<(double start, double end)>();
        foreach (var segment in project.VoiceLab.Segments)
        {
            Require(Matches(segment.Id, Id) && ids.Add(segment.Id) && double.IsFinite(segment.OutDuration) && segment.OutDuration > 0 &&
                double.IsFinite(segment.OutDuration * sourceRate) && segment.OutDuration * sourceRate < long.MaxValue,
                VoiceLabProjectErrorCode.InvalidSegment);
            var range = segment.Replace;
            Require(double.IsFinite(range.Start) && double.IsFinite(range.End) && range.Start >= 0 && range.End > range.Start &&
                range.End <= project.Media.Source.DurationSeconds && indices.TryGetValue(range.FirstWordId, out var first) &&
                indices.TryGetValue(range.LastWordId, out var last) && first <= last && words[first].Start >= range.Start &&
                words[last].End <= range.End && words.FirstOrDefault(word => word.Start >= range.Start && word.End <= range.End)?.Id == range.FirstWordId &&
                words.LastOrDefault(word => word.Start >= range.Start && word.End <= range.End)?.Id == range.LastWordId &&
                !words.Any(word => word.Start < range.Start && word.End > range.Start ||
                    word.Start < range.End && word.End > range.End), VoiceLabProjectErrorCode.InvalidRange);
            var asset = assets.FirstOrDefault(item => item.Id == segment.Audio.AssetId);
            Require(asset is not null, VoiceLabProjectErrorCode.DanglingAsset);
            var audio = segment.Audio;
            Require(double.IsFinite(audio.TrimStart) && double.IsFinite(audio.TrimEnd) && double.IsFinite(audio.Stretch) &&
                double.IsFinite(audio.GainDb) && audio.TrimStart >= 0 && audio.TrimEnd > audio.TrimStart &&
                audio.TrimEnd <= asset!.DurationSeconds && audio.Stretch > 0 &&
                Math.Abs((audio.TrimEnd - audio.TrimStart) * audio.Stretch - segment.OutDuration) <= 1.0 / asset.SampleRate,
                VoiceLabProjectErrorCode.InvalidSegment);
            Require(segment.Candidates.Count > 0 && segment.SelectedCandidateIndex >= 0 && segment.SelectedCandidateIndex < segment.Candidates.Count &&
                segment.Candidates[segment.SelectedCandidateIndex].AssetId == audio.AssetId &&
                segment.Candidates[segment.SelectedCandidateIndex].Rejected is null, VoiceLabProjectErrorCode.InvalidCandidate);
            foreach (var candidate in segment.Candidates)
            {
                if (candidate.AssetId is { } candidateId) Require(assetIds.Contains(candidateId), VoiceLabProjectErrorCode.DanglingAsset);
                if (candidate.Score is { } score) Require(double.IsFinite(score) && score >= 0 && score <= 1, VoiceLabProjectErrorCode.InvalidCandidate);
                if (candidate.Rejected is null) Require(candidate.AssetId is not null && candidate.Score is not null, VoiceLabProjectErrorCode.InvalidCandidate);
            }
            var provenance = segment.Provenance;
            Require(Matches(provenance.Provider, "[a-z0-9-]+") && !string.IsNullOrEmpty(provenance.Endpoint) &&
                !provenance.Endpoint.Contains("://", StringComparison.Ordinal) && !string.IsNullOrEmpty(provenance.Model) &&
                !string.IsNullOrEmpty(provenance.VoiceId) && (provenance.ConsentRecordId is null || Matches(provenance.ConsentRecordId, Id)) &&
                (provenance.RequestId is null || Matches(provenance.RequestId, Id)), VoiceLabProjectErrorCode.InvalidSegment);
            foreach (var value in new[] { segment.Qa.TranscriptMatch, segment.Qa.LufsJumpLu, segment.Qa.PeakDbfs, segment.Qa.SpeakerScore })
                if (value is { } number) Require(double.IsFinite(number), VoiceLabProjectErrorCode.InvalidSegment);
            if (segment.Qa.TranscriptMatch is { } match) Require(match >= 0 && match <= 1, VoiceLabProjectErrorCode.InvalidSegment);
            if (segment.Qa.SpeakerScore is { } speaker) Require(speaker >= 0 && speaker <= 1, VoiceLabProjectErrorCode.InvalidSegment);
            if (segment.Kind == VoiceLabSegmentKind.Tts)
            {
                Require(segment.Text is { New.Length: > 0 } && segment.Words is { Count: > 0 }, VoiceLabProjectErrorCode.InvalidWords);
                var previous = 0.0;
                foreach (var word in segment.Words!)
                {
                    Require(!string.IsNullOrEmpty(word.Text) && double.IsFinite(word.Start) && double.IsFinite(word.End) &&
                        word.Start >= previous && word.End > word.Start && word.End <= segment.OutDuration, VoiceLabProjectErrorCode.InvalidWords);
                    Require(EditingMath.Round(word.End * sourceRate) > EditingMath.Round(word.Start * sourceRate), VoiceLabProjectErrorCode.InvalidWords);
                    previous = word.End;
                }
            }
            else if (segment.Kind == VoiceLabSegmentKind.VoiceChanger)
                Require(segment.Text is null && segment.Words is null, VoiceLabProjectErrorCode.InvalidWords);
            else throw new VoiceLabProjectException(VoiceLabProjectErrorCode.InvalidSegment);
            if (segment.Enabled) enabled.Add((range.Start, range.End));
        }
        enabled.Sort((left, right) => left.start.CompareTo(right.start));
        for (var i = 1; i < enabled.Count; i++)
            Require(enabled[i].start >= enabled[i - 1].end, VoiceLabProjectErrorCode.OverlappingReplacement);
        if (project.SchemaVersion == 3) VoiceLabRenderValidation.Validate(project);
    }
    /// <summary>The only v1/v2 to v3 promotion (§10.1, §10.5); loading and saving never call it. A v2 segment needs explicit review.</summary>
    public static Project UpgradeToV3(Project project)
    {
        Validate(project);
        if (project.SchemaVersion == 3) return project;
        Require(project.VoiceLab.Segments.Count == 0, VoiceLabProjectErrorCode.LegacySegmentsNeedReview);
        var result = project with { SchemaVersion = 3, VoiceLab = new VoiceLabPlaceholder([]) { Assets = project.VoiceLab.Assets ?? [],
            CleanAudio = new(VoiceLabCleanAudioMode.Off, null, null), Voices = [], VideoAssets = [] } };
        Validate(result); return result;
    }
    /// <summary>Appends a reviewed v3 segment; v1 and segment-free v2 projects are upgraded first, so accept never writes v2.</summary>
    public static Project Accept(Project project, IReadOnlyList<VoiceLabAsset> newAssets, VoiceLabSegment segment)
    {
        if (project.SchemaVersion != 3) project = UpgradeToV3(project);
        Require(segment.Candidates is { Count: > 0 } && segment.SelectedCandidateIndex >= 0 &&
            segment.SelectedCandidateIndex < segment.Candidates.Count, VoiceLabProjectErrorCode.InvalidCandidate);
        var assets = project.VoiceLab.Assets?.ToList() ?? [];
        Require(newAssets.Select(item => item.Id).Distinct(StringComparer.Ordinal).Count() == newAssets.Count &&
            newAssets.All(item => !assets.Any(existing => existing.Id == item.Id)), VoiceLabProjectErrorCode.InvalidAsset);
        assets.AddRange(newAssets);
        Require(!project.VoiceLab.Segments.Any(item => item.Id == segment.Id), VoiceLabProjectErrorCode.InvalidSegment);
        // Every unrejected own-voice candidate is a new take, selected or not, so each needs an active consent reference (§6.10, §10.5).
        foreach (var candidate in segment.Candidates.Where(item => item.Rejected is null))
            if (candidate.Recipe is { VoiceSource: VoiceLabVoiceSource.Own } recipe)
                Require(project.VoiceLab.Voices?.FirstOrDefault(v => v.Id == recipe.VoiceRefId)?.Status == VoiceLabVoiceStatus.Active, VoiceLabProjectErrorCode.ConsentUnverified);
        var result = project with { VoiceLab = project.VoiceLab with { Segments = project.VoiceLab.Segments.Append(segment).ToArray(), Assets = assets } };
        Validate(result); return result;
    }
    /// <summary>Adds an own-voice consent reference (§6.8, §10.5). The project stores only IDs and the trimmed display name.</summary>
    public static Project AddVoiceReference(Project project, VoiceLabVoiceReference reference)
    {
        Require(project.SchemaVersion == 3, VoiceLabProjectErrorCode.RequiresVersion3);
        // §6.1: the name counts 1–60 Unicode scalars after trimming whitespace, and the trimmed name is stored.
        var voice = reference with { DisplayName = reference.DisplayName.Trim() };
        var voices = project.VoiceLab.Voices ?? [];
        Require(Matches(voice.Id, Id) && voices.All(item => item.Id != voice.Id) && Matches(voice.ConsentRecordId, Id) &&
            voice.Provider == "elevenlabs" && Matches(voice.VoiceId, ProviderVoiceId) && voice.Status == VoiceLabVoiceStatus.Active &&
            voice.DisplayName.EnumerateRunes().Count() is >= 1 and <= 60 &&
            !voices.Any(item => item.Status == VoiceLabVoiceStatus.Active && item.Provider == voice.Provider && item.VoiceId == voice.VoiceId),
            VoiceLabProjectErrorCode.InvalidVoice);
        var result = project with { VoiceLab = project.VoiceLab with { Voices = [.. voices, voice] } };
        Validate(result); return result;
    }
    /// <summary>Records provider deletion (§6.10). The reference, segments and paid assets stay; new own-voice accepts are refused.</summary>
    public static Project MarkVoiceDeleted(Project project, string id)
    {
        // §10.5: only version 3 holds voice references, so versions 1 and 2 report RequiresVersion3.
        Require(project.SchemaVersion == 3, VoiceLabProjectErrorCode.RequiresVersion3);
        var voice = project.VoiceLab.Voices?.FirstOrDefault(item => item.Id == id);
        Require(voice is not null, VoiceLabProjectErrorCode.MissingVoice);
        var result = voice!.Status == VoiceLabVoiceStatus.Deleted ? project : project with { VoiceLab = project.VoiceLab with {
            Voices = project.VoiceLab.Voices!.Select(item => item.Id == id ? item with { Status = VoiceLabVoiceStatus.Deleted } : item).ToArray() } };
        Validate(result); return result;
    }
    public static Project SetEnabled(Project project, string id, bool enabled)
    {
        Require(project.VoiceLab.Segments.Any(item => item.Id == id), VoiceLabProjectErrorCode.MissingSegment);
        var result = project with { VoiceLab = project.VoiceLab with { Segments = project.VoiceLab.Segments.Select(item => item.Id == id ? item with { Enabled = enabled } : item).ToArray() } };
        Validate(result); return result;
    }
    public static Project Delete(Project project, string id)
    {
        Require(project.VoiceLab.Segments.Any(item => item.Id == id), VoiceLabProjectErrorCode.MissingSegment);
        var result = project with { VoiceLab = project.VoiceLab with { Segments = project.VoiceLab.Segments.Where(item => item.Id != id).ToArray() } };
        Validate(result); return result;
    }
    /// <summary>Voice status is not checked: accept verified consent for every unrejected candidate, and its stored evidence keeps the take renderable (§10.5).</summary>
    public static Project SelectCandidate(Project project, string id, int index)
    {
        var segment = project.VoiceLab.Segments.FirstOrDefault(item => item.Id == id);
        Require(segment is not null, VoiceLabProjectErrorCode.MissingSegment);
        Require(index >= 0 && index < segment!.Candidates.Count && segment.Candidates[index].Rejected is null &&
            segment.Candidates[index].AssetId is not null, VoiceLabProjectErrorCode.InvalidCandidate);
        var assetId = segment!.Candidates[index].AssetId!;
        var asset = project.VoiceLab.Assets?.FirstOrDefault(item => item.Id == assetId);
        Require(asset is not null, VoiceLabProjectErrorCode.DanglingAsset);
        if (project.SchemaVersion == 3)
        {
            var recipe = segment.Candidates[index].Recipe ?? throw new VoiceLabProjectException(VoiceLabProjectErrorCode.MissingRenderPolicy);
            var updated = segment with { SelectedCandidateIndex = index, OutDuration = recipe.OutDuration, Audio = recipe.Audio, Words = recipe.Words,
                Provenance = recipe.Provenance, Qa = new(recipe.Qa.TranscriptMatch, recipe.Qa.LufsJumpLu, recipe.Qa.PeakDbfs, recipe.Qa.SpeakerScore) };
            var v3 = project with { VoiceLab = project.VoiceLab with { Segments = project.VoiceLab.Segments.Select(item => item.Id == id ? updated : item).ToArray() } };
            Validate(v3); return v3;
        }
        var selected = segment with { SelectedCandidateIndex = index,
            Audio = segment.Audio with { AssetId = assetId, TrimStart = 0, TrimEnd = asset!.DurationSeconds, Stretch = segment.OutDuration / asset.DurationSeconds } };
        var result = project with { VoiceLab = project.VoiceLab with { Segments = project.VoiceLab.Segments.Select(item => item.Id == id ? selected : item).ToArray() } };
        Validate(result); return result;
    }
    public static void RequireLegacyRendering(Project project)
    {
        if (project.VoiceLab.Segments.Any(segment => segment.Enabled)) throw new VoiceLabProjectException(VoiceLabProjectErrorCode.UnsupportedRendering);
    }
    public static void RequireLegacyRendering(Project project, VoiceLabOutputScope scope)
    {
        if (!project.VoiceLab.Segments.Any(segment => segment.Enabled)) return;
        VoiceLabOutputPlanner.Build(project, scope).RequireLegacyRendering();
    }
}
