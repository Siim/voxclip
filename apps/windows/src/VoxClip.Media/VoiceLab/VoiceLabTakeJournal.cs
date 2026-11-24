using System.Globalization;
using System.Security.Cryptography;
using System.Text.Json;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.Speech;

namespace VoxClip.Media.VoiceLab;

/// <summary>What a paid take was made from, as the journal matches it (voice-lab §3 "Paid takes are kept"; Mac
/// <c>VoiceLabTakeJournalKey</c>): the consent record and its clone, the model and language, the words as sent with their audio
/// tags, the words before and after the window, and the pace sent, rounded as the request rounds it. The seed is left out: a
/// new run picks its own.</summary>
internal sealed record VoiceLabTakeJournalKey
{
    internal VoiceLabTakeJournalKey(string recordId, string voiceId, string modelId, string language, string requestText,
        string previousText, string nextText, double? pace)
    {
        RecordId = recordId; VoiceId = voiceId; ModelId = modelId; Language = language; RequestText = requestText;
        PreviousText = previousText; NextText = nextText;
        Pace = Math.Round((pace ?? VoiceLabPace.DefaultValue) * 100, MidpointRounding.AwayFromZero) / 100;
    }
    internal string RecordId { get; }
    internal string VoiceId { get; }
    internal string ModelId { get; }
    internal string Language { get; }
    internal string RequestText { get; }
    internal string PreviousText { get; }
    internal string NextText { get; }
    internal double Pace { get; }

    /// <summary>The key of <paramref name="input"/>'s take <paramref name="take"/> in the clone <paramref name="voiceId"/>.</summary>
    internal static VoiceLabTakeJournalKey Of(VoiceLabTakeInput input, string voiceId, int take = 0)
    {
        var options = input.Options(take);
        return new(input.RecordId, voiceId, input.ModelId, input.Language, input.RequestText, options.PreviousText ?? "", options.NextText ?? "", options.Pace);
    }
}

internal sealed record VoiceLabTakeJournalTiming(string Character, double Start, double End);
/// <summary>The take's character timing: the provider's, or recovered from its word check or on device (voice-lab §8.5).</summary>
internal sealed record VoiceLabTakeJournalAlignment(bool Recovered, IReadOnlyList<VoiceLabTakeJournalTiming> Characters);
internal sealed record VoiceLabTakeJournalReceipt(string Provider, string Region, string Endpoint);
internal enum VoiceLabTakeJournalOutcome { Passed, Failed }
/// <summary>How the take did in its own checks, written when each settles (Mac <c>VoiceLabTakeJournalEntry.Checks</c>). The same audio
/// fails them the same way, so an entry with a hard failure is never adopted: adopting it would buy its word check again only to fail
/// again. <paramref name="Speaker"/> is null when the take was not measured alone (a short take's check is pooled, a verdict on the
/// group); <paramref name="Words"/> is null when its word check never ran. <paramref name="HardFailures"/> holds the
/// <see cref="VoiceLabTakeQaFailure"/> names other than <c>loudness</c>, and <c>timing</c> when its timing could not be recovered
/// from what its word check heard.</summary>
internal sealed record VoiceLabTakeJournalChecks(VoiceLabTakeJournalOutcome? Speaker, VoiceLabTakeJournalOutcome? Words, IReadOnlyList<string> HardFailures)
{
    /// <summary>The take's own speaker check failed before its word check was sent.</summary>
    internal static VoiceLabTakeJournalChecks SpeakerFailed { get; } = new(VoiceLabTakeJournalOutcome.Failed, null, ["speaker"]);
    /// <summary>Its word check heard words that could not be lined up with the text, here or on device.</summary>
    internal static VoiceLabTakeJournalChecks TimingUnrecovered { get; } = new(null, VoiceLabTakeJournalOutcome.Failed, ["timing"]);
    /// <summary>The verdict of the take's word check and acoustics (<see cref="VoiceLabTakeQuality.Evaluate"/>).</summary>
    internal static VoiceLabTakeJournalChecks Of(VoiceLabTakeQaResult qa, double threshold) => new(
        qa.SpeakerScore is { } score ? score >= threshold ? VoiceLabTakeJournalOutcome.Passed : VoiceLabTakeJournalOutcome.Failed : null,
        qa.Failures.Contains(VoiceLabTakeQaFailure.Transcript) ? VoiceLabTakeJournalOutcome.Failed : VoiceLabTakeJournalOutcome.Passed,
        Array.AsReadOnly(qa.Failures.Where(failure => failure != VoiceLabTakeQaFailure.Loudness).Distinct().Select(Name).ToArray()));
    private static string Name(VoiceLabTakeQaFailure failure) => failure switch
    {
        VoiceLabTakeQaFailure.Transcript => "transcript", VoiceLabTakeQaFailure.Clipping => "clipping", VoiceLabTakeQaFailure.Loudness => "loudness",
        VoiceLabTakeQaFailure.Speaker => "speaker", _ => "insufficientGeneratedSpeech"
    };
}

/// <summary>One paid ElevenLabs take as it arrived, written beside its PCM the moment it is stored (voice-lab §3 "Paid takes are
/// kept"; Mac <c>VoiceLabTakeJournalEntry</c>), with its timing once known and its checks once they settle.
/// <c>shared/fixtures/voice-lab/take-journal-cases.json</c> pins the shape on both platforms.</summary>
internal sealed record VoiceLabTakeJournalEntry(string Schema, string AssetFile, string AssetSha256, string RequestId, string? ProviderRequestId,
    string RecordId, string VoiceId, string ModelId, string Language, string RequestText, string PreviousText, string NextText, double Pace,
    uint Seed, int SampleRate, long Frames, VoiceLabTakeJournalAlignment? Alignment, VoiceLabTakeJournalReceipt Receipt, string? EstimateUsd,
    DateTimeOffset CreatedAt)
{
    internal const string CurrentSchema = "voxclip-take-journal/1";
    /// <summary>Null until the take's checks settle, and for a take whose run stopped before they did: such a take is adopted.</summary>
    internal VoiceLabTakeJournalChecks? Checks { get; init; }
    internal VoiceLabTakeJournalKey Key => new(RecordId, VoiceId, ModelId, Language, RequestText, PreviousText, NextText, Pace);
    internal string AssetId => Path.GetFileNameWithoutExtension(AssetFile.Split('/')[^1]);
    /// <summary>False once a check failed in a way the same audio repeats (<see cref="VoiceLabTakeJournalChecks.HardFailures"/>).</summary>
    internal bool Adoptable => Checks is null || Checks.HardFailures.Count == 0;
}

/// <summary>The App's settle of the take journals (Mac <c>VoiceLabAssetRetention</c>). At a project's open and close the entries of the
/// assets it now uses (after Use; <c>projectId/assetId.wav</c>) go, as do entries whose asset is gone or that are 60 days old and
/// unused; at launch every project's journal lets go of the last two, so the 60-day rule holds for a project never reopened and after
/// a crash before its close. Their assets stay.</summary>
public static class VoiceLabTakeJournalSettlement
{
    /// <summary>Unused audio requests still eligible for adoption, before the take run rechecks its input and consent.</summary>
    public static IReadOnlySet<Guid> RecoverableRequests(string projectId, string paidRoot, DateTimeOffset now) =>
        VoiceLabTakeJournal.List(projectId, paidRoot).Where(entry => entry.Adoptable && now - entry.CreatedAt < VoiceLabTakeJournal.UnusedLifetime &&
            File.Exists(Path.Combine(paidRoot, projectId, entry.AssetId + ".wav")))
            .Select(entry => Guid.Parse(entry.RequestId)).ToHashSet();

    /// <summary>Returns how many entries went.</summary>
    public static int Settle(string projectId, string paidRoot, IEnumerable<string> referencedFiles) =>
        VoiceLabTakeJournal.Settle(projectId, paidRoot, referencedFiles.ToHashSet(StringComparer.Ordinal), DateTimeOffset.UtcNow);

    /// <summary>The launch sweep: every project folder under <paramref name="paidRoot"/> with a journal drops its entries whose asset is
    /// gone or that are 60 days old and unused (Mac <c>VoiceLabAssetRetention</c> at launch). A folder that is a link, or that can't be
    /// read, is left as it is. Returns how many entries went.</summary>
    public static int SweepStale(string paidRoot, DateTimeOffset now)
    {
        string[] folders;
        try
        {
            if (!Directory.Exists(paidRoot)) return 0;
            folders = Directory.GetDirectories(paidRoot);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return 0; }
        var removed = 0;
        var none = new HashSet<string>(StringComparer.Ordinal);
        foreach (var folder in folders.Order(StringComparer.Ordinal))
        {
            try
            {
                if (new DirectoryInfo(folder).Attributes.HasFlag(FileAttributes.ReparsePoint)) continue;
                if (!Directory.Exists(Path.Combine(folder, VoiceLabTakeJournal.Folder))) continue;
                removed += VoiceLabTakeJournal.Settle(Path.GetFileName(folder), paidRoot, none, now);
            }
            // Launch goes on whatever one folder holds.
            catch (Exception error) when (error is IOException or UnauthorizedAccessException or ArgumentException or VoiceLabException) { }
        }
        return removed;
    }
}

/// <summary>The journal of one project's paid takes (Mac <c>VoiceLabTakeJournal</c>), under <c>&lt;paid root&gt;/&lt;projectId&gt;/takes/</c>:
/// <c>&lt;assetId&gt;.json</c>, each written to a temporary file, flushed and moved into place, so a crash leaves the old entry or the
/// new one and at most a <c>.partial</c> file that nothing reads. A take run adopts an entry over the same words, voice and model
/// for free unless a check failed it (<see cref="Match"/>), and <see cref="Settle"/> drops the entries that are done. No
/// project-format change.</summary>
internal static class VoiceLabTakeJournal
{
    internal const string Folder = "takes";
    /// <summary>How long an entry the project never used stays adoptable (Mac <c>VoiceLabTakeJournal.unusedLifetime</c>).</summary>
    internal static readonly TimeSpan UnusedLifetime = TimeSpan.FromDays(60);
    private const int MaximumEntryBytes = 4 * 1024 * 1024;

    internal static VoiceLabTakeJournalEntry Create(VoiceLabAsset asset, VoiceLabAudioResult result, VoiceLabTakeJournalKey key, uint seed, decimal? estimateUsd)
    {
        var alignment = result.Alignment is { } timing
            ? new VoiceLabTakeJournalAlignment(false, Array.AsReadOnly(timing.Select(item => new VoiceLabTakeJournalTiming(item.Character, item.Start, item.End)).ToArray()))
            : null;
        return new(VoiceLabTakeJournalEntry.CurrentSchema, asset.File, asset.Sha256, result.Receipt.ActionId.ToString("D"), result.Receipt.ProviderRequestId,
            key.RecordId, key.VoiceId, key.ModelId, key.Language, key.RequestText, key.PreviousText, key.NextText, key.Pace, seed, result.SampleRate,
            result.Pcm.Length / 2, alignment, new(result.Receipt.Provider, RegionName(result.Receipt.Region), result.Receipt.Endpoint),
            estimateUsd?.ToString(CultureInfo.InvariantCulture), Seconds(asset.CreatedAt));
    }

    internal static void Write(VoiceLabTakeJournalEntry entry, string projectId, string paidRoot)
    {
        Validate(entry, projectId);
        Store(entry, TakesFolder(paidRoot, projectId, create: true));
    }

    /// <summary>The entry of <paramref name="assetFile"/> with its character timing, after the take's timing was recovered.</summary>
    internal static void UpdateTiming(string assetFile, IReadOnlyList<VoiceLabCharacterTiming> timing, bool recovered, string projectId, string paidRoot) =>
        Update(assetFile, projectId, paidRoot, entry => entry with
            { Alignment = new(recovered, Array.AsReadOnly(timing.Select(item => new VoiceLabTakeJournalTiming(item.Character, item.Start, item.End)).ToArray())) });

    /// <summary>The entry of <paramref name="assetFile"/> with how the take did in its checks, once they settle; a later run's verdict
    /// replaces it.</summary>
    internal static void UpdateChecks(string assetFile, VoiceLabTakeJournalChecks checks, string projectId, string paidRoot) =>
        Update(assetFile, projectId, paidRoot, entry => entry with { Checks = checks });

    private static void Update(string assetFile, string projectId, string paidRoot, Func<VoiceLabTakeJournalEntry, VoiceLabTakeJournalEntry> change)
    {
        var folder = TakesFolder(paidRoot, projectId, create: false);
        var id = Path.GetFileNameWithoutExtension(assetFile.Split('/')[^1]);
        if (Read(Path.Combine(folder, id + ".json"), projectId) is not { } entry || entry.AssetFile != assetFile) throw new VoiceLabException(VoiceLabErrorKind.InvalidInput);
        var changed = change(entry);
        Validate(changed, projectId);
        Store(changed, folder);
    }

    /// <summary>Every valid entry, in no particular order. Partial files, foreign names and malformed entries are left out.</summary>
    internal static IReadOnlyList<VoiceLabTakeJournalEntry> List(string projectId, string paidRoot)
    {
        string folder;
        try { folder = TakesFolder(paidRoot, projectId, create: false); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or VoiceLabException) { return []; }
        if (!Directory.Exists(folder)) return [];
        return Directory.EnumerateFiles(folder, "*.json").Where(path => !Path.GetFileName(path).StartsWith('.')).Order(StringComparer.Ordinal)
            .Select(path => Read(path, projectId)).OfType<VoiceLabTakeJournalEntry>().ToArray();
    }

    /// <summary>The newest adoptable entry over <paramref name="key"/> (no check failed it) whose asset is still there with its frame
    /// count and SHA-256, leaving out the asset files in <paramref name="claimed"/> (already taken by a live run); null when none.</summary>
    internal static VoiceLabTakeJournalEntry? Match(VoiceLabTakeJournalKey key, string projectId, string paidRoot, IReadOnlySet<string>? claimed = null) =>
        List(projectId, paidRoot).Where(entry => entry.Key == key && entry.Adoptable && entry.SampleRate == 24000 && claimed?.Contains(entry.AssetFile) != true)
            .OrderByDescending(entry => entry.CreatedAt).ThenByDescending(entry => entry.AssetFile, StringComparer.Ordinal)
            .FirstOrDefault(entry => TryPcm(entry, projectId, paidRoot) is not null);

    /// <summary>Drops the entries that are done (Mac <c>VoiceLabAssetRetention</c> at a project's close): the project uses the asset
    /// (<paramref name="references"/>, after Use), the asset is gone, or the entry is older than <see cref="UnusedLifetime"/>. Their
    /// assets stay. Returns how many went. A take run settles its project's journal before its first adoption, with no references.</summary>
    internal static int Settle(string projectId, string paidRoot, IReadOnlySet<string> references, DateTimeOffset now)
    {
        var removed = 0;
        foreach (var entry in List(projectId, paidRoot))
        {
            bool present;
            try { present = File.Exists(Path.Combine(Path.GetFullPath(paidRoot), projectId, entry.AssetId + ".wav")); }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { continue; }
            if (!references.Contains(entry.AssetFile) && present && now - entry.CreatedAt < UnusedLifetime) continue;
            Remove(entry.AssetId, projectId, paidRoot);
            removed++;
        }
        return removed;
    }

    /// <summary>Drops the entry of <paramref name="assetId"/>; its asset stays.</summary>
    internal static void Remove(string assetId, string projectId, string paidRoot)
    {
        try { File.Delete(Path.Combine(TakesFolder(paidRoot, projectId, create: false), assetId + ".json")); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or VoiceLabException) { }
    }

    /// <summary>The take an entry describes, from its stored PCM, for a run that adopts it: the PCM after its exact canonical header
    /// and SHA-256, the timing and the receipt as they were, and the asset. Nothing is sent.</summary>
    internal static (VoiceLabAudioResult Result, VoiceLabAsset Asset) Adopt(VoiceLabTakeJournalEntry entry, string projectId, string paidRoot)
    {
        Validate(entry, projectId);
        var pcm = TryPcm(entry, projectId, paidRoot) ?? throw new VoiceLabException(VoiceLabErrorKind.InvalidAudio);
        var receipt = new VoiceLabReceipt(entry.Receipt.Provider, Region(entry.Receipt.Region)!.Value, entry.Receipt.Endpoint, entry.ModelId, entry.VoiceId,
            Guid.ParseExact(entry.RequestId, "D"), entry.ProviderRequestId, null, entry.Pace);
        var timing = entry.Alignment?.Characters.Select(item => new VoiceLabCharacterTiming(item.Character, item.Start, item.End)).ToArray();
        return (new(pcm, entry.SampleRate, timing is null ? null : Array.AsReadOnly(timing), receipt),
            new(entry.AssetId, "audio", entry.AssetFile, entry.AssetSha256, entry.Frames / (double)entry.SampleRate, entry.SampleRate, entry.CreatedAt));
    }

    internal static void Validate(VoiceLabTakeJournalEntry entry, string projectId)
    {
        string? expected = null;
        try { expected = VoiceLabAssetNaming.File(projectId, entry.AssetId, "wav"); }
        catch (VoiceLabProjectException) { }
        if (entry.Schema != VoiceLabTakeJournalEntry.CurrentSchema || expected is null || expected != entry.AssetFile ||
            entry.AssetSha256.Length != 64 || !entry.AssetSha256.All(c => c is >= '0' and <= '9' or >= 'a' and <= 'f') ||
            !Guid.TryParseExact(entry.RequestId, "D", out var request) || request.ToString("D") != entry.RequestId ||
            Region(entry.Receipt.Region) is null || entry.Receipt.Endpoint.Length == 0 || entry.Receipt.Provider.Length == 0 ||
            entry.RecordId.Length == 0 || entry.VoiceId.Length == 0 || entry.ModelId.Length == 0 || entry.Language.Length == 0 || entry.RequestText.Length == 0 ||
            !double.IsFinite(entry.Pace) || entry.Pace <= 0 || entry.SampleRate is < 8000 or > 192000 || entry.Frames < 1 || entry.Frames > VoiceLabAssetStore.MaxFrames ||
            entry.EstimateUsd is { } usd && !decimal.TryParse(usd, NumberStyles.Number, CultureInfo.InvariantCulture, out _) ||
            entry.Alignment?.Characters.Any(item => !double.IsFinite(item.Start) || !double.IsFinite(item.End) || item.Start < 0 || item.End < item.Start) == true ||
            entry.Checks?.HardFailures.Any(name => name.Length is < 1 or > 64) == true)
            throw new VoiceLabException(VoiceLabErrorKind.InvalidInput);
    }

    internal static byte[] Encode(VoiceLabTakeJournalEntry entry)
    {
        using var buffer = new MemoryStream();
        using (var writer = new Utf8JsonWriter(buffer))
        {
            writer.WriteStartObject();
            if (entry.Alignment is { } alignment)
            {
                writer.WriteStartObject("alignment");
                writer.WriteStartArray("characters");
                foreach (var item in alignment.Characters)
                {
                    writer.WriteStartObject();
                    writer.WriteString("character", item.Character); writer.WriteNumber("end", item.End); writer.WriteNumber("start", item.Start);
                    writer.WriteEndObject();
                }
                writer.WriteEndArray();
                writer.WriteBoolean("recovered", alignment.Recovered);
                writer.WriteEndObject();
            }
            writer.WriteString("assetFile", entry.AssetFile);
            writer.WriteString("assetSha256", entry.AssetSha256);
            if (entry.Checks is { } checks)
            {
                writer.WriteStartObject("checks");
                writer.WriteStartArray("hardFailures");
                foreach (var name in checks.HardFailures) writer.WriteStringValue(name);
                writer.WriteEndArray();
                if (checks.Speaker is { } speaker) writer.WriteString("speaker", OutcomeName(speaker));
                if (checks.Words is { } words) writer.WriteString("words", OutcomeName(words));
                writer.WriteEndObject();
            }
            writer.WriteString("createdAt", Seconds(entry.CreatedAt).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture));
            if (entry.EstimateUsd is { } usd) writer.WriteString("estimateUSD", usd);
            writer.WriteNumber("frames", entry.Frames);
            writer.WriteString("language", entry.Language);
            writer.WriteString("modelID", entry.ModelId);
            writer.WriteString("nextText", entry.NextText);
            writer.WriteNumber("pace", entry.Pace);
            writer.WriteString("previousText", entry.PreviousText);
            if (entry.ProviderRequestId is { } provider) writer.WriteString("providerRequestID", provider);
            writer.WriteStartObject("receipt");
            writer.WriteString("endpoint", entry.Receipt.Endpoint); writer.WriteString("provider", entry.Receipt.Provider); writer.WriteString("region", entry.Receipt.Region);
            writer.WriteEndObject();
            writer.WriteString("recordID", entry.RecordId);
            writer.WriteString("requestID", entry.RequestId);
            writer.WriteString("requestText", entry.RequestText);
            writer.WriteNumber("sampleRate", entry.SampleRate);
            writer.WriteString("schema", entry.Schema);
            writer.WriteNumber("seed", entry.Seed);
            writer.WriteString("voiceID", entry.VoiceId);
            writer.WriteEndObject();
        }
        return buffer.ToArray();
    }

    /// <summary>An entry from its JSON, or null for anything malformed; <see cref="Validate"/> checks its values.</summary>
    internal static VoiceLabTakeJournalEntry? Decode(ReadOnlySpan<byte> json)
    {
        try
        {
            var reader = new Utf8JsonReader(json);
            using var document = JsonDocument.ParseValue(ref reader);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object) return null;
            static string Text(JsonElement element, string name) => element.GetProperty(name).GetString() ?? throw new FormatException();
            static string? Optional(JsonElement element, string name) =>
                element.TryGetProperty(name, out var value) && value.ValueKind != JsonValueKind.Null ? value.GetString() ?? throw new FormatException() : null;
            VoiceLabTakeJournalAlignment? alignment = null;
            if (root.TryGetProperty("alignment", out var timing) && timing.ValueKind != JsonValueKind.Null)
                alignment = new(timing.GetProperty("recovered").GetBoolean(), Array.AsReadOnly(timing.GetProperty("characters").EnumerateArray()
                    .Select(item => new VoiceLabTakeJournalTiming(Text(item, "character"), item.GetProperty("start").GetDouble(), item.GetProperty("end").GetDouble())).ToArray()));
            VoiceLabTakeJournalChecks? checks = null;
            if (root.TryGetProperty("checks", out var verdict) && verdict.ValueKind != JsonValueKind.Null)
            {
                static VoiceLabTakeJournalOutcome? Outcome(JsonElement element, string name) => Optional(element, name) switch
                {
                    null => null, "passed" => VoiceLabTakeJournalOutcome.Passed, "failed" => VoiceLabTakeJournalOutcome.Failed, _ => throw new FormatException()
                };
                checks = new(Outcome(verdict, "speaker"), Outcome(verdict, "words"),
                    Array.AsReadOnly(verdict.GetProperty("hardFailures").EnumerateArray().Select(item => item.GetString() ?? throw new FormatException()).ToArray()));
            }
            var receipt = root.GetProperty("receipt");
            var created = Text(root, "createdAt");
            if (!DateTimeOffset.TryParseExact(created, "yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var createdAt)) return null;
            return new(Text(root, "schema"), Text(root, "assetFile"), Text(root, "assetSha256"), Text(root, "requestID"), Optional(root, "providerRequestID"),
                Text(root, "recordID"), Text(root, "voiceID"), Text(root, "modelID"), Text(root, "language"), Text(root, "requestText"),
                Text(root, "previousText"), Text(root, "nextText"), root.GetProperty("pace").GetDouble(), root.GetProperty("seed").GetUInt32(),
                root.GetProperty("sampleRate").GetInt32(), root.GetProperty("frames").GetInt64(), alignment,
                new(Text(receipt, "provider"), Text(receipt, "region"), Text(receipt, "endpoint")), Optional(root, "estimateUSD"), createdAt) { Checks = checks };
        }
        catch (Exception error) when (error is JsonException or KeyNotFoundException or InvalidOperationException or FormatException) { return null; }
    }

    /// <summary>The asset's PCM, when the file holds exactly the canonical mono PCM16 header for the entry's frames and rate, then the
    /// frames, and its SHA-256 is the entry's; null otherwise.</summary>
    private static byte[]? TryPcm(VoiceLabTakeJournalEntry entry, string projectId, string paidRoot)
    {
        try
        {
            var path = Path.Combine(Path.GetFullPath(paidRoot), projectId, entry.AssetId + ".wav");
            var info = new FileInfo(path);
            if (!info.Exists || info.LinkTarget is not null || (info.Attributes & FileAttributes.ReparsePoint) != 0 || info.Length != 44 + 2 * entry.Frames) return null;
            var bytes = File.ReadAllBytes(path);
            if (bytes.LongLength != 44 + 2 * entry.Frames || Convert.ToHexStringLower(SHA256.HashData(bytes)) != entry.AssetSha256 ||
                !bytes.AsSpan(0, 44).SequenceEqual(VoiceLabAssetStore.WavHeader(entry.Frames, entry.SampleRate))) return null;
            return bytes[44..];
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return null; }
    }

    private static VoiceLabTakeJournalEntry? Read(string path, string projectId)
    {
        try
        {
            var info = new FileInfo(path);
            if (!info.Exists || info.LinkTarget is not null || info.Length is < 1 or > MaximumEntryBytes) return null;
            if (Decode(File.ReadAllBytes(path)) is not { } entry || entry.AssetId + ".json" != Path.GetFileName(path)) return null;
            Validate(entry, projectId);
            return entry;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or VoiceLabException) { return null; }
    }

    private static void Store(VoiceLabTakeJournalEntry entry, string folder)
    {
        var final = Path.Combine(folder, entry.AssetId + ".json");
        var partial = Path.Combine(folder, "." + entry.AssetId + ".json.partial");
        File.Delete(partial);
        var options = new FileStreamOptions { Mode = FileMode.CreateNew, Access = FileAccess.Write, Share = FileShare.None, Options = FileOptions.WriteThrough };
        if (!OperatingSystem.IsWindows()) options.UnixCreateMode = UnixFileMode.UserRead | UnixFileMode.UserWrite;
        try
        {
            using (var stream = new FileStream(partial, options)) { stream.Write(Encode(entry)); stream.Flush(true); }
            File.Move(partial, final, overwrite: true);
        }
        catch { try { File.Delete(partial); } catch (IOException) { } throw; }
    }

    private static string TakesFolder(string paidRoot, string projectId, bool create)
    {
        var project = Path.Combine(Path.GetFullPath(paidRoot), projectId);
        _ = VoiceLabAssetNaming.File(projectId, "probe", "wav");
        var folder = Path.Combine(project, Folder);
        if (!create) return folder;
        foreach (var directory in new[] { Path.GetFullPath(paidRoot), project, folder })
            VoiceLabAssetStore.RequireDirectory(directory, Folder, create: true);
        return folder;
    }

    private static string OutcomeName(VoiceLabTakeJournalOutcome outcome) => outcome == VoiceLabTakeJournalOutcome.Passed ? "passed" : "failed";
    private static DateTimeOffset Seconds(DateTimeOffset value) => new(value.UtcTicks - value.UtcTicks % TimeSpan.TicksPerSecond, TimeSpan.Zero);
    private static string RegionName(ElevenLabsRegion region) => region switch
    {
        ElevenLabsRegion.Us => "us", ElevenLabsRegion.Eu => "eu", ElevenLabsRegion.In => "in", ElevenLabsRegion.Sg => "sg", _ => "default"
    };
    private static ElevenLabsRegion? Region(string name) => name switch
    {
        "default" => ElevenLabsRegion.Default, "us" => ElevenLabsRegion.Us, "eu" => ElevenLabsRegion.Eu, "in" => ElevenLabsRegion.In,
        "sg" => ElevenLabsRegion.Sg, _ => null
    };
}

/// <summary>The journal assets live take runs hold in this process (Mac <c>VoiceLabTakeJournalClaims</c>), so one paid take is never
/// adopted by two runs, and a run never adopts a take it made or adopted itself. A run's claims go when it is invalidated or
/// collected; a relaunch starts with none.</summary>
internal static class VoiceLabTakeJournalClaims
{
    private static readonly object Sync = new();
    private static readonly Dictionary<string, Guid> Owners = new(StringComparer.Ordinal);
    internal static string Key(string assetFile, string paidRoot) => Path.GetFullPath(paidRoot) + "|" + assetFile;
    /// <summary>True when <paramref name="key"/> is now <paramref name="owner"/>'s, newly or already.</summary>
    internal static bool Claim(string key, Guid owner)
    {
        lock (Sync)
        {
            if (Owners.TryGetValue(key, out var held)) return held == owner;
            Owners[key] = owner;
            return true;
        }
    }
    internal static void Release(string key, Guid owner)
    {
        lock (Sync) if (Owners.TryGetValue(key, out var held) && held == owner) Owners.Remove(key);
    }
    internal static void ReleaseAll(Guid owner)
    {
        lock (Sync) foreach (var key in Owners.Where(pair => pair.Value == owner).Select(pair => pair.Key).ToArray()) Owners.Remove(key);
    }
    /// <summary>The asset files under <paramref name="paidRoot"/> that runs other than <paramref name="owner"/> hold.</summary>
    internal static HashSet<string> Claimed(string paidRoot, Guid owner)
    {
        var prefix = Path.GetFullPath(paidRoot) + "|";
        lock (Sync)
            return Owners.Where(pair => pair.Value != owner && pair.Key.StartsWith(prefix, StringComparison.Ordinal))
                .Select(pair => pair.Key[prefix.Length..]).ToHashSet(StringComparer.Ordinal);
    }
}
