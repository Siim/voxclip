using System.Text.Json;
using System.Text.RegularExpressions;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Services.Project;

namespace VoxClip.Core.Services.Models;

/// <summary>Reads only the bundled, commit-pinned catalogue; transcription §12.1.</summary>
public sealed class ModelCatalog : IModelCatalog
{
    private readonly string path;
    private readonly SemaphoreSlim gate = new(1, 1);
    private JsonElement? root;
    private IReadOnlyList<TranscriptionModel>? models;

    /// <summary>Use the canonical shared-resource resolver without accessing the network.</summary>
    public ModelCatalog() : this(SharedResources.ResolveRoot()) { }

    /// <summary>Read catalog/transcription-models.json beneath the bundled shared root; plan W5.</summary>
    public ModelCatalog(string sharedRoot) : this(new FileInfo(Path.Combine(sharedRoot, "catalog", "transcription-models.json"))) { }

    private ModelCatalog(FileInfo catalogFile) => path = catalogFile.FullName;

    internal static ModelCatalog FromFile(string catalogPath) => new(new FileInfo(catalogPath));

    /// <inheritdoc />
    public async Task<IReadOnlyList<TranscriptionModel>> GetModelsAsync(CancellationToken ct)
    {
        await gate.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            if (models is not null) return models;
            await using var stream = File.OpenRead(path);
            using var document = await JsonDocument.ParseAsync(stream, cancellationToken: ct).ConfigureAwait(false);
            var data = document.RootElement;
            if (data.GetProperty("schema").GetString() != "voxclip.transcription-catalog" || data.GetProperty("schemaVersion").GetInt32() != 1)
                throw new InvalidDataException("Unsupported transcription catalogue.");
            var entries = data.GetProperty("models").EnumerateArray().Select(ParseModel).ToArray();
            Validate(data, entries);
            root = data.Clone();
            models = entries;
            return entries;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or InvalidDataException or
            JsonException or InvalidOperationException or KeyNotFoundException or FormatException or OverflowException or ArgumentException)
        {
            throw new VoxClipException(VoxClipErrorCode.SharedResourcesMissing, "VoxClip is missing some of its files. Reinstall VoxClip.");
        }
        finally { gate.Release(); }
    }

    /// <inheritdoc />
    public async Task<TranscriptionModel?> GetModelAsync(string id, CancellationToken ct) =>
        (await GetModelsAsync(ct).ConfigureAwait(false)).FirstOrDefault(model => model.Id == id);

    /// <summary>Read the validated, bundled catalogue metadata for native adapters.</summary>
    public async Task<JsonElement> RootAsync(CancellationToken ct)
    {
        await GetModelsAsync(ct).ConfigureAwait(false);
        return root!.Value;
    }

    /// <summary>Normalize a language code using the bundled ISO 639 mapping.</summary>
    public async Task<string> NormalizeLanguageAsync(string code, CancellationToken ct)
    {
        var data = await RootAsync(ct).ConfigureAwait(false);
        var primary = code.Split('-')[0].ToLowerInvariant();
        return data.GetProperty("languageCodes").GetProperty("iso639_3").TryGetProperty(primary, out var normalized)
            ? normalized.GetString()! : primary;
    }

    /// <summary>Map a Whisper language code back to the bundled canonical language code.</summary>
    public async Task<string> FromWhisperLanguageAsync(string code, CancellationToken ct)
    {
        var data = await RootAsync(ct).ConfigureAwait(false);
        foreach (var mapping in data.GetProperty("languageCodes").GetProperty("whisperCodeFor").EnumerateObject())
            if (string.Equals(mapping.Value.GetString(), code, StringComparison.OrdinalIgnoreCase))
                return await NormalizeLanguageAsync(mapping.Name, ct).ConfigureAwait(false);
        return await NormalizeLanguageAsync(code, ct).ConfigureAwait(false);
    }

    private static TranscriptionModel ParseModel(JsonElement data)
    {
        var files = data.GetProperty("files").EnumerateArray().Select(file => new ModelFile(
            file.GetProperty("role").GetString()!, file.GetProperty("name").GetString()!, new Uri(file.GetProperty("url").GetString()!),
            file.GetProperty("bytes").GetInt64(), file.GetProperty("sha256").GetString()!)).ToArray();
        var engine = data.GetProperty("engine").GetString() switch
        {
            "whispercpp" => TranscriptEngine.Whispercpp,
            "elevenlabs" => TranscriptEngine.Elevenlabs,
            "apple-speech" => TranscriptEngine.AppleSpeech,
            _ => throw new InvalidDataException("Unknown catalogue engine.")
        };
        var timing = (data.TryGetProperty("timing", out var timingValue) ? timingValue.GetString() : "tokenGrouped") switch
        {
            "dtw" => TimingSource.Dtw, "tokenGrouped" => TimingSource.TokenGrouped,
            "native" => TimingSource.Native, "runGrouped" => TimingSource.RunGrouped,
            _ => throw new InvalidDataException("Unknown catalogue timing.")
        };
        return new(data.GetProperty("id").GetString()!, engine, data.GetProperty("kind").GetString()!, Strings(data.GetProperty("languages")),
            data.TryGetProperty("forcedLanguage", out var language) ? language.GetString() : null,
            data.TryGetProperty("verbatim", out var verbatim) && verbatim.GetBoolean(), timing, files, data.GetProperty("totalBytes").GetInt64(),
            Strings(data.GetProperty("requires")), data.GetProperty("license").GetString()!, new Uri(data.GetProperty("licenseUrl").GetString()!),
            data.GetProperty("attribution").GetString()!, data.GetProperty("listed").GetBoolean(), data.Clone());
    }

    private static string[] Strings(JsonElement array) => array.EnumerateArray().Select(item =>
        item.ValueKind == JsonValueKind.String && !string.IsNullOrEmpty(item.GetString()) ? item.GetString()! :
        throw new InvalidDataException("Invalid catalogue string.")).ToArray();

    private static void StringMap(JsonElement map)
    {
        foreach (var property in map.EnumerateObject())
            if (property.Value.ValueKind != JsonValueKind.String)
                throw new InvalidDataException("Invalid catalogue string map.");
    }

    private static double FiniteNumber(JsonElement data, string name)
    {
        var value = data.GetProperty(name);
        return value.ValueKind == JsonValueKind.Number && value.TryGetDouble(out var number) && double.IsFinite(number)
            ? number : throw new InvalidDataException("Invalid catalogue number.");
    }

    private static void Validate(JsonElement root, TranscriptionModel[] models)
    {
        var ids = models.Select(model => model.Id).ToHashSet(StringComparer.Ordinal);
        if (ids.Count != models.Length) throw new InvalidDataException("Duplicate catalogue model.");
        foreach (var engine in root.GetProperty("engines").EnumerateArray())
            if (engine.GetProperty("id").GetString() is not ("whispercpp" or "elevenlabs" or "apple-speech"))
                throw new InvalidDataException("Unknown catalogue engine.");
        var limits = root.GetProperty("engines").EnumerateArray().Single(engine => engine.GetProperty("id").GetString() == "elevenlabs").GetProperty("limits");
        var minimum = FiniteNumber(limits, "minDurationSeconds");
        if (minimum < 0 || FiniteNumber(limits, "maxDurationSeconds") < minimum || FiniteNumber(limits, "maxUploadBytes") <= 0)
            throw new InvalidDataException("Invalid cloud limits.");
        var codes = root.GetProperty("languageCodes");
        StringMap(codes.GetProperty("iso639_3"));
        StringMap(codes.GetProperty("whisperCodeFor"));
        foreach (var model in models)
        {
            ModelPaths.ValidateId(model.Id);
            if (model.License is not ("MIT" or "Apache-2.0" or "BSD-2-Clause" or "BSD-3-Clause" or "ISC" or "CC-BY-4.0"))
                throw new InvalidDataException("The model licence is not approved for redistribution.");
            if (model.Files.Count == 0 || model.Files.Select(file => file.Name).Distinct(StringComparer.OrdinalIgnoreCase).Count() != model.Files.Count)
                throw new InvalidDataException("Invalid model files.");
            if (model.TotalBytes != model.Files.Sum(file => file.Bytes) || model.Requires.Any(id => !ids.Contains(id)))
                throw new InvalidDataException("Invalid catalogue sizes or dependencies.");
            var repo = model.RawMetadata.GetProperty("repo");
            var revision = repo.GetProperty("revision").GetString()!;
            if (!Regex.IsMatch(revision, "^[a-f0-9]{40}$", RegexOptions.CultureInvariant)) throw new InvalidDataException("Unpinned model revision.");
            var prefix = "https://huggingface.co/" + repo.GetProperty("id").GetString() + "/resolve/" + revision + "/";
            foreach (var file in model.Files)
            {
                ModelPaths.ValidateFileName(file.Name);
                if (file.Bytes <= 0 || !Regex.IsMatch(file.Sha256, "^[a-f0-9]{64}$", RegexOptions.CultureInvariant) ||
                    !file.Url.AbsoluteUri.StartsWith(prefix, StringComparison.Ordinal) || file.Url.Query.Length != 0)
                    throw new InvalidDataException("Unpinned model file.");
            }
            if (model.Engine == TranscriptEngine.Whispercpp && model.Kind == "asr")
            {
                var whisper = model.RawMetadata.GetProperty("whisper");
                _ = whisper.GetProperty("multilingual").GetBoolean();
                if (whisper.GetProperty("dtwAheadsPreset").GetString() is not ("LARGE_V3_TURBO" or "SMALL_EN" or "BASE_EN"))
                    throw new InvalidDataException("Invalid alignment preset.");
                if (whisper.TryGetProperty("dtwDefault", out var dtw)) _ = dtw.GetBoolean();
                StringMap(whisper.GetProperty("initialPromptByLanguage"));
                var vadId = whisper.GetProperty("vadModel").GetString();
                if (!models.Any(entry => entry.Id == vadId && entry.Files.Count(file => file.Role == "vad") == 1) ||
                    model.Files.Count(file => file.Role == "model") != 1)
                    throw new InvalidDataException("Invalid whisper dependencies.");
            }
        }
        var defaults = root.GetProperty("defaults");
        if (defaults.GetProperty("lowMemoryThresholdBytes").GetInt64() <= 0) throw new InvalidDataException("Invalid memory threshold.");
        var byLanguage = defaults.GetProperty("byLanguage");
        _ = byLanguage.GetProperty("*");
        _ = byLanguage.GetProperty("auto");
        foreach (var language in byLanguage.EnumerateObject())
            foreach (var platform in new[] { "macos", "windows" })
            {
                var choices = language.Value.GetProperty(platform);
                if (Strings(choices.GetProperty("local")).Any(id => !ids.Contains(id)))
                    throw new InvalidDataException("Unknown default model.");
                if (!ids.Contains(choices.GetProperty("recommendedDownload").GetString()!))
                    throw new InvalidDataException("Unknown default download.");
                if (choices.GetProperty("cloud").GetString() != "elevenlabs" ||
                    choices.GetProperty("system").ValueKind != JsonValueKind.Null && choices.GetProperty("system").GetString() != "apple-speech")
                    throw new InvalidDataException("Invalid default engine.");
                if (choices.TryGetProperty("lowMemoryDownload", out var low) &&
                    (low.ValueKind != JsonValueKind.String || !ids.Contains(low.GetString()!)))
                {
                    throw new InvalidDataException("Unknown low-memory download.");
                }
            }
        var visiting = new HashSet<string>(StringComparer.Ordinal);
        var visited = new HashSet<string>(StringComparer.Ordinal);
        foreach (var model in models) Visit(model);
        void Visit(TranscriptionModel model)
        {
            if (visited.Contains(model.Id)) return;
            if (!visiting.Add(model.Id)) throw new InvalidDataException("Cyclic model dependency.");
            foreach (var dependency in model.Requires) Visit(models.Single(entry => entry.Id == dependency));
            visiting.Remove(model.Id);
            visited.Add(model.Id);
        }
    }
}

internal static class ModelPaths
{
    internal static bool ValidId(string id) =>
        Regex.IsMatch(id, "\\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\\z", RegexOptions.CultureInvariant) && !id.Contains("..", StringComparison.Ordinal);

    internal static void ValidateId(string id)
    {
        if (!ValidId(id)) throw new InvalidDataException("Unsafe model id.");
    }

    internal static void ValidateFileName(string name)
    {
        if (string.IsNullOrEmpty(name) || name is "." or ".." || name.IndexOfAny(['/', '\\', ':', '\0']) >= 0 ||
            name.Any(character => char.IsControl(character) || "<>\"|?*".Contains(character)) ||
            name.EndsWith('.') || name.EndsWith(' ') || name.Equals("installed.json", StringComparison.OrdinalIgnoreCase) ||
            Regex.IsMatch(name, "^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\\.|$)", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant))
            throw new InvalidDataException("Unsafe model file name.");
    }

    internal static string DirectoryFor(string root, string id)
    {
        ValidateId(id);
        return Path.Combine(root, "Models", "whispercpp", id);
    }
}
