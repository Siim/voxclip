using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using ProjectDocument = VoxClip.Core.Domain.Shared.Project;

namespace VoxClip.Core.Services.VoiceLab;

/// <summary>A proposal change, with its review metadata and how the creator left it.</summary>
public sealed record SavedRewriteChange(VoiceLabDiffHunk Hunk, [property: JsonPropertyName("insertionAfterItemID")] string? InsertionAfterItemId,
    bool CheckThis, IReadOnlyList<string> Lines, IReadOnlyList<string> Reasons, string State);

/// <summary>The review and references to its unused paid work; audio and provider credentials never go here.</summary>
public sealed record SavedRewriteProposal(string Inputs, string Instruction, IReadOnlyList<SavedRewriteChange> Changes,
    IReadOnlyList<int> Kept, IReadOnlyList<int> PricedAnyway, [property: JsonPropertyName("voiceRecordID")] string? VoiceRecordId,
    int PatchTakes, [property: JsonPropertyName("patchUSD")] decimal PatchUsd, IReadOnlyList<Guid> PatchRequests, string? NewWords = null,
    IReadOnlyDictionary<int, string>? OwnWords = null)
{
    /// <summary>The app-owned proposal sidecar format.</summary>
    [JsonRequired] public string Schema { get; init; } = SavedRewriteProposalStore.Schema;
    /// <summary>The project whose Voice Lab folder owns the sidecar.</summary>
    public string ProjectId { get; init; } = "";
    /// <summary>The full take, a clip, or a selection with its enclosing clip.</summary>
    public string Scope { get; init; } = "";
    /// <summary>When the creator last changed the saved review or its paid work.</summary>
    public DateTimeOffset SavedAt { get; init; }
}

/// <summary>The local, per-scope Rewrite checkpoint. Mismatched inputs are left intact so Undo can make them current again.</summary>
public sealed class SavedRewriteProposalStore(string paidRoot, string projectId, RewriteScope scope, string? enclosingClipId)
{
    internal const string Schema = "voxclip-rewrite-proposal/1";
    private const string Folder = "rewrite";
    private static readonly TimeSpan Lifetime = TimeSpan.FromDays(60);
    private static readonly SavedRewriteProposalJsonContext Context = new(new JsonSerializerOptions
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        Converters = { new JsonStringEnumConverter<VoiceLabDiffHunkKind>(JsonNamingPolicy.CamelCase, allowIntegerValues: false) },
    });
    private string? lastShape;
    private string Scope => scope.ClipId is { } clip ? "clip:" + clip : scope.First is { } first && scope.Last is { } last
        ? FormattableString.Invariant($"selection:{first}-{last}:{enclosingClipId}") : "full";
    private string? PathFor => ValidId(projectId) ? Path.Combine(paidRoot, projectId, Folder, Hash(Scope) + ".json") : null;

    /// <summary>Hashes the existing shared Rewrite identity after the project has gone through its save/load wire form.</summary>
    public string Inputs(ProjectDocument project)
    {
        try { project = ProjectSerialization.Deserialize(ProjectSerialization.Serialize(project)); }
        catch (Exception error) when (error is VoxClipException or JsonException) { }
        return Hash(ProjectVoiceTakeIdentity.RewriteInputsKey(project, scope, enclosingClipId));
    }

    /// <summary>Reads a still-current review. An out-of-date scope or edit does not consume the sidecar.</summary>
    public SavedRewriteProposal? Load(ProjectDocument project, DateTimeOffset now)
    {
        if (PathFor is not { } path || project.Id != projectId || Read(path, now) is not { } record || record.ProjectId != projectId ||
            record.Scope != Scope || record.Inputs != Inputs(project)) return null;
        lastShape = Encode(record with { SavedAt = default });
        return record;
    }

    /// <summary>Flushes and atomically replaces the sidecar, without extending an unchanged record's lifetime.</summary>
    public void Save(SavedRewriteProposal proposal, DateTimeOffset now)
    {
        if (PathFor is not { } path) return;
        var record = proposal with { Schema = Schema, ProjectId = projectId, Scope = Scope, SavedAt = default };
        var shape = Encode(record);
        if (shape == lastShape) return;
        var folder = Path.GetDirectoryName(path)!;
        if (Links(folder) || IsLink(path)) throw new IOException("The Rewrite folder or record is a link.");
        VoiceConsentPrivacy.CreateDirectory(folder);
        if (!OperatingSystem.IsWindows()) File.SetUnixFileMode(folder, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
        var temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        var options = new FileStreamOptions { Mode = FileMode.CreateNew, Access = FileAccess.Write, Share = FileShare.None, Options = FileOptions.WriteThrough };
        if (!OperatingSystem.IsWindows()) options.UnixCreateMode = UnixFileMode.UserRead | UnixFileMode.UserWrite;
        try
        {
            using (var stream = new FileStream(temporary, options))
            {
                stream.Write(Encoding.UTF8.GetBytes(Encode(record with { SavedAt = DateTimeOffset.FromUnixTimeSeconds(now.ToUnixTimeSeconds()) })));
                stream.Flush(true);
            }
            File.Move(temporary, path, true);
        }
        finally { File.Delete(temporary); }
        lastShape = shape;
    }

    /// <summary>Removes this review only, leaving take journal entries and paid assets alone.</summary>
    public void Remove()
    {
        lastShape = null;
        if (PathFor is { } path && !Links(Path.GetDirectoryName(path)!) && !IsLink(path)) File.Delete(path);
    }

    /// <summary>Expires old or invalid sidecars and old temporary files from interrupted writes.</summary>
    public static void SweepStale(string paidRoot, DateTimeOffset now)
    {
        if (!Directory.Exists(paidRoot) || Links(paidRoot)) return;
        try
        {
            foreach (var project in Directory.EnumerateDirectories(paidRoot))
            {
                var folder = Path.Combine(project, Folder);
                if (!Directory.Exists(folder) || Links(folder)) continue;
                try
                {
                    foreach (var file in Directory.EnumerateFiles(folder))
                    {
                        if (IsLink(file)) continue;
                        if (file.EndsWith(".json", StringComparison.Ordinal)) Read(file, now);
                        else if (Path.GetFileName(file).StartsWith('.') && (file.EndsWith(".tmp", StringComparison.Ordinal) || file.EndsWith(".tmp.bak", StringComparison.Ordinal)) &&
                            now - File.GetLastWriteTimeUtc(file) >= TimeSpan.FromHours(1)) File.Delete(file);
                    }
                }
                catch (Exception error) when (IoFailure(error)) { }
            }
        }
        catch (Exception error) when (IoFailure(error)) { }
    }

    private static SavedRewriteProposal? Read(string path, DateTimeOffset now)
    {
        try
        {
            if (!File.Exists(path) || IsLink(path) || Links(Path.GetDirectoryName(path)!)) return null;
            VoiceConsentPrivacy.Validate(Path.GetDirectoryName(path)!, true);
            VoiceConsentPrivacy.Validate(path, false);
            try
            {
                using var stream = File.OpenRead(path);
                var record = JsonSerializer.Deserialize(stream, Context.SavedRewriteProposal);
                if (record is { Schema: Schema, Instruction: not null, Changes.Count: > 0, PatchTakes: > 0, PatchRequests: not null, Kept: not null, PricedAnyway: not null } &&
                    now - record.SavedAt < Lifetime && record.Changes.All(change => change is
                    { Hunk.SourceWordIds: not null, Hunk.NewTokens: not null, Hunk.CorrectedTexts: not null, Hunk.AbsorbedItemIds: not null,
                        Hunk.BridgeWordIds: not null, Hunk.AudioTags: not null, Lines: not null, Reasons: not null, State: "pending" or "kept" or "excluded" })) return record;
            }
            catch (JsonException) { }
            File.Delete(path);
        }
        catch (Exception error) when (IoFailure(error)) { }
        return null;
    }

    private static bool IoFailure(Exception error) => error is IOException or UnauthorizedAccessException or VoiceLabException or VoiceConsentException;
    private static string Encode(SavedRewriteProposal record) => JsonSerializer.Serialize(record, Context.SavedRewriteProposal);
    private static bool ValidId(string value) => value.Length > 0 && value is not ("." or "..") &&
        !value.EndsWith(' ') && !value.EndsWith('.') && value.IndexOfAny(['/', '\\', ':']) < 0 && value.IndexOfAny(Path.GetInvalidFileNameChars()) < 0;
    private static string Hash(string text) => Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(text)));
    private static bool IsLink(string path) => (File.Exists(path) || Directory.Exists(path)) && (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0;
    private static bool Links(string path)
    {
        var folder = new DirectoryInfo(path);
        for (var depth = 0; folder is not null && depth < 3; folder = folder.Parent, depth++)
            if (IsLink(folder.FullName)) return true;
        return false;
    }
}

[JsonSerializable(typeof(SavedRewriteProposal))]
internal sealed partial class SavedRewriteProposalJsonContext : JsonSerializerContext;
