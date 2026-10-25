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
public sealed record VoiceLabCandidate(string? AssetId, double? Score, string? Rejected);
public sealed record VoiceLabProvenance(string Provider, string Endpoint, string Model, string VoiceId,
    string? ConsentRecordId, string? RequestId, uint? Seed, DateTimeOffset CreatedAt);
public sealed record VoiceLabQa(double? TranscriptMatch, double? LufsJumpLu, double? PeakDbfs, double? SpeakerScore);
public sealed record VoiceLabSegment(string Id, VoiceLabSegmentKind Kind, bool Enabled, VoiceLabReplacement Replace,
    double OutDuration, VoiceLabAudio Audio, VoiceLabText? Text, IReadOnlyList<VoiceLabWord>? Words,
    VoiceLabProvenance Provenance, VoiceLabQa Qa, IReadOnlyList<VoiceLabCandidate> Candidates, int SelectedCandidateIndex);
public enum VoiceLabProjectErrorCode
{
    InvalidAsset, UnsafePath, InvalidSegment, InvalidRange, InvalidWords, DanglingAsset,
    OverlappingReplacement, MissingSegment, InvalidCandidate, UnsupportedRendering, InvalidScope
}
public sealed class VoiceLabProjectException(VoiceLabProjectErrorCode code) : Exception(code.ToString())
{
    public VoiceLabProjectErrorCode Code { get; } = code;
}

/// <summary>Pure validation and immutable project transitions; does not delete paid assets.</summary>
public static class VoiceLabProject
{
    private const string Id = "[A-Za-z0-9][A-Za-z0-9._:-]{0,63}";
    private static bool Matches(string value, string pattern) => Regex.IsMatch(value, "\\A(?:" + pattern + ")\\z", RegexOptions.CultureInvariant);
    private static void Require(bool condition, VoiceLabProjectErrorCode code)
    {
        if (!condition) throw new VoiceLabProjectException(code);
    }
    public static void Validate(Project project)
    {
        if (project.SchemaVersion == 1)
        {
            Require(project.VoiceLab.Segments.Count == 0 && project.VoiceLab.Assets is null, VoiceLabProjectErrorCode.InvalidSegment);
            return;
        }
        Require(project.SchemaVersion == 2 && project.VoiceLab.Assets is not null, VoiceLabProjectErrorCode.InvalidSegment);
        Require(Matches(project.Id, "[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}"), VoiceLabProjectErrorCode.UnsafePath);
        var assets = project.VoiceLab.Assets!;
        var assetIds = assets.Select(asset => asset.Id).ToHashSet(StringComparer.Ordinal);
        Require(assetIds.Count == assets.Count, VoiceLabProjectErrorCode.InvalidAsset);
        foreach (var asset in assets)
        {
            Require(Matches(asset.Id, Id) && asset.Kind == "audio" && Matches(asset.Sha256, "[0-9a-f]{64}") &&
                double.IsFinite(asset.DurationSeconds) && asset.DurationSeconds > 0 && asset.SampleRate > 0, VoiceLabProjectErrorCode.InvalidAsset);
            Require(Matches(asset.Id, "[a-z0-9][a-z0-9_-]{0,63}") &&
                !Matches(asset.Id, "(?:con|prn|aux|nul|com[1-9]|lpt[1-9])") &&
                (asset.File == project.Id + "/" + asset.Id + ".wav" || asset.File == project.Id + "/" + asset.Id + ".flac"),
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
    }
    public static Project Accept(Project project, IReadOnlyList<VoiceLabAsset> newAssets, VoiceLabSegment segment)
    {
        var assets = project.VoiceLab.Assets?.ToList() ?? [];
        Require(newAssets.Select(item => item.Id).Distinct(StringComparer.Ordinal).Count() == newAssets.Count &&
            newAssets.All(item => !assets.Any(existing => existing.Id == item.Id)), VoiceLabProjectErrorCode.InvalidAsset);
        assets.AddRange(newAssets);
        Require(!project.VoiceLab.Segments.Any(item => item.Id == segment.Id), VoiceLabProjectErrorCode.InvalidSegment);
        var result = project with { SchemaVersion = 2, VoiceLab = new(project.VoiceLab.Segments.Append(segment).ToArray()) { Assets = assets } };
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
    public static Project SelectCandidate(Project project, string id, int index)
    {
        var segment = project.VoiceLab.Segments.FirstOrDefault(item => item.Id == id);
        Require(segment is not null, VoiceLabProjectErrorCode.MissingSegment);
        Require(index >= 0 && index < segment!.Candidates.Count && segment.Candidates[index].Rejected is null &&
            segment.Candidates[index].AssetId is not null, VoiceLabProjectErrorCode.InvalidCandidate);
        var assetId = segment!.Candidates[index].AssetId!;
        var asset = project.VoiceLab.Assets?.FirstOrDefault(item => item.Id == assetId);
        Require(asset is not null, VoiceLabProjectErrorCode.DanglingAsset);
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
