using System.Collections.Frozen;
using System.Collections.ObjectModel;
using System.Text.Json;
using System.Text.Json.Serialization;
using VoxClip.Core.Domain.Shared;
#pragma warning disable CS1591

namespace VoxClip.Core.Domain.VoiceLab;

public sealed record VoiceLabRetentionObservation(string Session, double MonotonicSeconds);
public sealed record VoiceLabRetainedFile(string File, string Identity, long Size, long ModifiedTicks);
public sealed record VoiceLabRetentionEntry(DateTimeOffset Discovered, DateTimeOffset LastObservedAt,
    VoiceLabRetentionObservation Observation, VoiceLabRetainedFile File);
public sealed record VoiceLabRetentionLedger(IReadOnlySet<string> Protected, IReadOnlyDictionary<string, VoiceLabRetentionEntry> Unreferenced)
{
    public static VoiceLabRetentionLedger Empty => new(FrozenSet<string>.Empty, new ReadOnlyDictionary<string, VoiceLabRetentionEntry>(new Dictionary<string, VoiceLabRetentionEntry>()));
}
public sealed record VoiceLabRetentionDecision(VoiceLabRetentionLedger Ledger, IReadOnlyList<VoiceLabRetainedFile> Eligible)
{
    public bool CanDelete(VoiceLabRetainedFile current, IReadOnlySet<string> currentReferences) =>
        !currentReferences.Contains(current.File) && !Ledger.Protected.Contains(current.File) && Eligible.Contains(current);
}

/// <summary>Pure seven-day policy. Persist the returned ledger before deletion; under the store lock recheck identity and all open-project references with CanDelete.</summary>
public static class VoiceLabAssetRetention
{
    public static string Serialize(VoiceLabRetentionLedger ledger) => JsonSerializer.Serialize(new VoiceLabRetentionDocument("voxclip-asset-retention/1",
        ledger.Protected.Order(StringComparer.Ordinal).ToArray(), new(ledger.Unreferenced, StringComparer.Ordinal)), VoiceLabRetentionJson.Default.VoiceLabRetentionDocument);
    public static VoiceLabRetentionLedger Deserialize(string json)
    {
        if (json.Length > 4 * 1024 * 1024) throw new VoiceLabException(VoiceLabErrorKind.InvalidInput);
        var document = JsonSerializer.Deserialize(json, VoiceLabRetentionJson.Default.VoiceLabRetentionDocument);
        if (document is not { Schema: "voxclip-asset-retention/1", Protected: not null, Unreferenced: not null })
            throw new VoiceLabException(VoiceLabErrorKind.InvalidInput);
        return new(document.Protected.ToFrozenSet(StringComparer.Ordinal), new ReadOnlyDictionary<string, VoiceLabRetentionEntry>(document.Unreferenced));
    }
    public static IReadOnlySet<string> References(Project project) => (project.VoiceLab.Assets ?? []).Select(asset => asset.File)
        .Concat((project.VoiceLab.VideoAssets ?? []).Select(asset => asset.File)).ToFrozenSet(StringComparer.Ordinal);
    public static VoiceLabRetentionDecision Observe(VoiceLabRetentionLedger ledger, string projectId, IReadOnlyList<VoiceLabRetainedFile> files,
        IReadOnlySet<string> references, DateTimeOffset now, VoiceLabRetentionObservation observation, bool allowDeletion = true, bool preserveUnlisted = false)
    {
        _ = VoiceLabAssetNaming.File(projectId, "probe", "wav");
        Validate(observation);
        var protectedFiles = ledger.Protected.ToHashSet(StringComparer.Ordinal);
        protectedFiles.UnionWith(references);
        var entries = new Dictionary<string, VoiceLabRetentionEntry>(ledger.Unreferenced, StringComparer.Ordinal);
        foreach (var entry in entries.Values)
        {
            Validate(entry.Observation);
            if (!SafeFile(projectId, entry.File) || entry.Discovered > entry.LastObservedAt || entries.GetValueOrDefault(entry.File.File) != entry)
                throw new VoiceLabException(VoiceLabErrorKind.InvalidInput);
        }
        var backward = entries.Values.Any(entry => now < entry.Discovered || now < entry.LastObservedAt);
        var eligible = new List<VoiceLabRetainedFile>();
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var file in files)
        {
            if (!SafeFile(projectId, file) || !seen.Add(file.File)) throw new VoiceLabException(VoiceLabErrorKind.InvalidInput);
            if (preserveUnlisted) protectedFiles.Add(file.File);
            if (protectedFiles.Contains(file.File)) { entries.Remove(file.File); continue; }
            if (entries.TryGetValue(file.File, out var previous) && previous.File == file)
            {
                var elapsed = observation.MonotonicSeconds - previous.Observation.MonotonicSeconds;
                var jumped = (now - previous.LastObservedAt).TotalSeconds - elapsed > TimeSpan.FromDays(1).TotalSeconds;
                var reset = backward || previous.Observation.Session != observation.Session || elapsed < 0 || jumped;
                var entry = previous with { Discovered = reset ? now : previous.Discovered, LastObservedAt = now, Observation = observation };
                entries[file.File] = entry;
                if (allowDeletion && now - entry.Discovered >= TimeSpan.FromDays(7)) eligible.Add(file);
            }
            else entries[file.File] = new(now, now, observation, file);
        }
        return new(new(protectedFiles.ToFrozenSet(StringComparer.Ordinal), new ReadOnlyDictionary<string, VoiceLabRetentionEntry>(entries)),
            Array.AsReadOnly(eligible.OrderBy(file => file.File, StringComparer.Ordinal).ToArray()));
    }
    private static void Validate(VoiceLabRetentionObservation value)
    {
        if (string.IsNullOrWhiteSpace(value.Session) || !double.IsFinite(value.MonotonicSeconds) || value.MonotonicSeconds < 0)
            throw new VoiceLabException(VoiceLabErrorKind.InvalidInput);
    }
    private static bool SafeFile(string projectId, VoiceLabRetainedFile file)
    {
        var components = file.File.Split('/');
        if (components.Length != 2 || components[0] != projectId || string.IsNullOrEmpty(file.Identity) || file.Size < 0) return false;
        var extension = Path.GetExtension(components[1]);
        var id = Path.GetFileNameWithoutExtension(components[1]);
        return extension is ".wav" or ".flac" ? VoiceLabAssetNaming.SafeFile(projectId, id, extension[1..]) == file.File :
            extension == ".mp4" && VoiceLabAssetNaming.SafeVideoFile(projectId, id) == file.File;
    }
}

internal sealed record VoiceLabRetentionDocument(string Schema, string[] Protected, Dictionary<string, VoiceLabRetentionEntry> Unreferenced);
[JsonSourceGenerationOptions(PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase, UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow)]
[JsonSerializable(typeof(VoiceLabRetentionDocument))]
internal sealed partial class VoiceLabRetentionJson : JsonSerializerContext;
