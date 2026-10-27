using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.Project;
namespace VoxClip.Core.Services.Settings;

/// <summary>Flat dotted-key settings; architecture §2.5 and settings.schema.json. Never contains credentials.</summary>
public sealed record AppSettings
{
    internal const string DefaultJson = """
        {"schema":"voxclip-settings/1","general.appearance":"system","general.transcriptTextSize":null,"ui.rightColumnWidth":null,
        "general.showLowConfidence":false,"general.showPlaceholderWords":true,"general.openLastProject":false,"general.recentProjects":[],"onboarding.completed":false,
        "editing.pauseBreath":"natural","captions.defaultStyleId":"vox-highlight","cache.limitGB":5,
        "transcription.engineMode":"local","transcription.language":"auto","transcription.recentLanguages":[],
        "transcription.elevenlabs.region":"default","transcription.cloudConsent.elevenlabs":false,
        "export.defaultAspect":"source","export.quality":"standard","export.srt":false,"export.folder":null,
        "export.fileNamePattern":"{project}-{clip}-{aspect}","export.openFolderAfter":false,
        "update.autoCheck":true,"update.lastCheckAt":null,"update.latestVersion":null,"update.htmlURL":null,
        "llm.connector":"","llm.cliPath.claude-code":"","llm.cliPath.codex":"","llm.clips.snapToLines":true,
        "llm.clips.lastPreset":"best","llm.tighten.strength":"normal","voiceLab.enabled":false}
        """;

    /// <summary>Hand-coded schema defaults; verified against settings.schema.json, plan W8.</summary>
    public static IReadOnlyDictionary<string, JsonElement> Defaults { get; } = ReadDefaults();

    private static IReadOnlyDictionary<string, JsonElement> ReadDefaults()
    {
        using var document = JsonDocument.Parse(DefaultJson);
        return new System.Collections.ObjectModel.ReadOnlyDictionary<string, JsonElement>(document.RootElement.EnumerateObject()
            .Where(property => property.Name != "schema").ToDictionary(property => property.Name, property => property.Value.Clone(), StringComparer.Ordinal));
    }

    private JsonElement? Lookup(string key) => Values.TryGetValue(key, out var value) ? value : Defaults.TryGetValue(key, out value) ? value : null;

    /// <summary>Read a boolean preference or its schema default; missing/wrong-type values return null.</summary>
    public bool? GetBool(string key)
    {
        var value = Lookup(key);
        return value?.ValueKind == JsonValueKind.True ? true : value?.ValueKind == JsonValueKind.False ? false : null;
    }

    /// <summary>Read a numeric preference or its schema default; missing/wrong-type values return null.</summary>
    public double? GetDouble(string key) => Lookup(key) is { ValueKind: JsonValueKind.Number } value && value.TryGetDouble(out var number) ? number : null;

    /// <summary>Read a string preference or its schema default; missing/wrong-type values return null.</summary>
    public string? GetString(string key) => Lookup(key) is { ValueKind: JsonValueKind.String } value ? value.GetString() : null;

    /// <summary>Set an independent JSON value; a null argument removes the stored override, plan W8.</summary>
    public void Set(string key, JsonElement? value)
    {
        ImplicitDefaults?.Remove(key);
        if (value is { } element)
        {
            Values[key] = element.Clone();
            RemovedKeys.Remove(key);
        }
        else
        {
            Values.Remove(key);
            RemovedKeys.Add(key);
        }
    }

    [JsonIgnore]
    internal HashSet<string> RemovedKeys { get; } = new(StringComparer.Ordinal);
    /// <summary>Construct the schema envelope; unknown dotted keys are retained by extension data.</summary>
    [JsonConstructor]
    public AppSettings(string schema) => Schema = schema;
    /// <summary>Required voxclip-settings/1 discriminator.</summary>
    public string Schema { get; init; }
    /// <summary>Flat settings entries, including unknown keys and per-connector models. Treat each loaded instance as a snapshot.</summary>
    [JsonExtensionData]
    public Dictionary<string, JsonElement> Values { get; set; } = [];
    [JsonIgnore]
    internal Dictionary<string, JsonElement>? ImplicitDefaults { get; init; }
}
/// <summary>Atomic, 500ms-debounced settings persistence; architecture §2.5 and §7.2. Never stores keys.</summary>
public interface ISettingsStore
{
    /// <summary>Static recovery diagnostic, without paths or settings values.</summary>
    string? LastLoadError => null;
    /// <summary>Static pending-write diagnostic, cleared after a successful retry.</summary>
    string? LastWriteError => null;
    /// <summary>Read or return documented defaults for a missing settings file.</summary>
    Task<AppSettings> LoadAsync(CancellationToken ct);
    /// <summary>Schedule an atomic write after the debounce.</summary>
    Task SaveAsync(AppSettings settings, CancellationToken ct);
    /// <summary>Flush the pending snapshot on orderly close.</summary>
    Task FlushAsync(CancellationToken ct);
}
/// <summary>Atomic snapshot persistence with a trailing 500ms debounce, architecture §2.5.</summary>
public sealed class SettingsStore : ISettingsStore
{
    private readonly string path;
    private readonly Action<string>? onWarning;
    private readonly AtomicFileOperations fileOperations;
    private readonly object sync = new();
    private readonly SemaphoreSlim writer = new(1, 1);
    private CancellationTokenSource? debounce;
    private string? pending;
    private AppSettings? current;
    private string? lastLoadError;
    private string? lastWriteError;
    private long revision;

    /// <summary>Use VOXCLIP_DATA_DIR or the platform data root, or an explicit settings file.</summary>
    public SettingsStore(string? path = null, Action<string>? onWarning = null) : this(path, onWarning, new AtomicFileOperations()) { }

    /// <summary>Use explicit per-user data locations, architecture §2.5 and plan W8.</summary>
    public SettingsStore(DataLocations locations, Action<string>? onWarning = null) : this(locations.Settings, onWarning) { }

    internal SettingsStore(string? path, Action<string>? onWarning, AtomicFileOperations fileOperations)
    {
        this.path = Path.GetFullPath(path ?? DataLocations.Resolve().Settings);
        this.onWarning = onWarning;
        this.fileOperations = fileOperations;
    }

    /// <inheritdoc />
    public string? LastLoadError { get { lock (sync) return lastLoadError; } }
    /// <inheritdoc />
    public string? LastWriteError { get { lock (sync) return lastWriteError; } }

    /// <inheritdoc />
    public async Task<AppSettings> LoadAsync(CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        lock (sync) { if (current is not null) return Resolve(current); }
        await writer.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            lock (sync) { if (current is not null) return Resolve(current); }
            var settings = new AppSettings("voxclip-settings/1");
            // Existence is only a hint for an exhausted read: ReplaceFile can briefly hide the name.
            var existed = File.Exists(path);
            var json = "";
            var missing = false;
            try
            {
                try
                {
                    json = await AtomicFile.ReadAllTextAsync(path, new UTF8Encoding(false, true), ct, fileOperations).ConfigureAwait(false);
                }
                catch (FileNotFoundException) when (!existed) { missing = true; }
                catch (DirectoryNotFoundException) when (!existed) { missing = true; }
                catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
                {
                    lock (sync) lastLoadError = "Could not read settings.";
                    onWarning?.Invoke("Could not read settings.");
                    throw new VoxClipException(VoxClipErrorCode.ProjectUnreadable, LastLoadError!, exception);
                }
                if (!missing)
                {
                    SettingsValidation.ValidateJson(json);
                    settings = JsonSerializer.Deserialize(json, SettingsJsonContext.Default.AppSettings) ?? throw new JsonException("Missing settings.");
                    SettingsValidation.Validate(settings);
                }
            }
            catch (Exception damaged) when (damaged is JsonException or DecoderFallbackException)
            {
                settings = Recover(json);
                try
                {
                    File.Copy(path, DamagedPath());
                }
                catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
                {
                    throw new VoxClipException(VoxClipErrorCode.ProjectUnreadable, "Could not preserve damaged settings.", exception);
                }
                lock (sync)
                {
                    current = settings;
                    pending = Serialize(settings);
                    revision++;
                    lastLoadError = "Damaged settings were set aside; valid preferences were recovered.";
                }
                onWarning?.Invoke("Damaged settings were set aside; valid preferences were recovered.");
                try { await WritePendingUnderGateAsync(ct).ConfigureAwait(false); }
                catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
                {
                    lock (sync) lastLoadError = "Recovered settings could not be saved; valid preferences remain pending.";
                    throw new VoxClipException(VoxClipErrorCode.ProjectUnreadable, LastLoadError!, exception);
                }
            }
            SettingsValidation.Validate(settings);
            lock (sync) { current ??= settings; return Resolve(current); }
        }
        finally { writer.Release(); }
    }
    /// <inheritdoc />
    public async Task SaveAsync(AppSettings settings, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        SettingsValidation.Validate(settings);
        await LoadAsync(ct).ConfigureAwait(false);
        ct.ThrowIfCancellationRequested();
        lock (sync)
        {
            var values = current!.Values.Where(pair => !SettingsValidation.KnownKey(pair.Key) && !settings.RemovedKeys.Contains(pair.Key)).ToDictionary(pair => pair.Key, pair => pair.Value.Clone(), StringComparer.Ordinal);
            foreach (var pair in settings.Values)
                if (settings.ImplicitDefaults is null || !settings.ImplicitDefaults.TryGetValue(pair.Key, out var original) || !JsonElement.DeepEquals(original, pair.Value))
                    values[pair.Key] = pair.Value.Clone();
            var snapshot = new AppSettings(settings.Schema) { Values = values };
            pending = Serialize(snapshot);
            current = snapshot;
            revision++;
            debounce?.Cancel();
            debounce = new CancellationTokenSource();
            _ = DebounceAsync(debounce);
        }
    }
    /// <inheritdoc />
    public async Task FlushAsync(CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        lock (sync) debounce?.Cancel();
        await WritePendingAsync(ct).ConfigureAwait(false);
    }

    private async Task DebounceAsync(CancellationTokenSource source)
    {
        try
        {
            await Task.Delay(500, source.Token).ConfigureAwait(false);
            await WritePendingAsync(source.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (source.IsCancellationRequested) { }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException) { }
        finally
        {
            lock (sync) { if (ReferenceEquals(debounce, source)) debounce = null; }
            source.Dispose();
        }
    }

    private async Task WritePendingAsync(CancellationToken ct)
    {
        await writer.WaitAsync(ct).ConfigureAwait(false);
        try { await WritePendingUnderGateAsync(ct).ConfigureAwait(false); }
        finally { writer.Release(); }
    }

    private async Task WritePendingUnderGateAsync(CancellationToken ct)
    {
        try
        {
            while (true)
            {
                string? snapshot;
                long version;
                lock (sync) { snapshot = pending; version = revision; }
                if (snapshot is null) return;
                await AtomicFile.WriteAsync(path, snapshot, ct, fileOperations).ConfigureAwait(false);
                lock (sync) { lastWriteError = null; if (version == revision) { pending = null; return; } }
            }
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            lock (sync) lastWriteError = "Settings could not be saved; the latest changes remain pending.";
            onWarning?.Invoke("Settings could not be saved; the latest changes remain pending.");
            throw;
        }
    }

    private static string Serialize(AppSettings settings)
        => JsonSerializer.Serialize(settings with { Values = settings.Values.OrderBy(pair => pair.Key, StringComparer.Ordinal).ToDictionary(pair => pair.Key, pair => pair.Value) }, SettingsJsonContext.Default.AppSettings) + "\n";

    private static AppSettings Resolve(AppSettings settings)
    {
        var defaults = SettingsValidation.Defaults();
        var implicitDefaults = defaults.Values.Where(pair => !settings.Values.ContainsKey(pair.Key)).ToDictionary(pair => pair.Key, pair => pair.Value.Clone(), StringComparer.Ordinal);
        foreach (var pair in settings.Values) defaults.Values[pair.Key] = pair.Value.Clone();
        if (OperatingSystem.IsWindows() && defaults.Values["transcription.engineMode"].GetString() == "apple")
            defaults.Values["transcription.engineMode"] = JsonSerializer.SerializeToElement("local", SettingsJsonContext.Default.String);
        return defaults with { ImplicitDefaults = implicitDefaults };
    }

    private static AppSettings Recover(string json)
    {
        var recovered = new AppSettings("voxclip-settings/1");
        try
        {
            using var document = JsonDocument.Parse(json);
            if (document.RootElement.ValueKind != JsonValueKind.Object) return recovered;
            foreach (var property in document.RootElement.EnumerateObject())
            {
                if (property.Name == "schema") continue;
                var candidate = new AppSettings("voxclip-settings/1") { Values = new() { [property.Name] = property.Value.Clone() } };
                try { SettingsValidation.Validate(candidate); recovered.Values[property.Name] = property.Value.Clone(); }
                catch (JsonException) { }
            }
        }
        catch (JsonException) { }
        return recovered;
    }

    private string DamagedPath()
    {
        var basis = path + ".damaged-" + DateTimeOffset.UtcNow.ToUnixTimeMilliseconds().ToString(System.Globalization.CultureInfo.InvariantCulture);
        var destination = basis;
        for (var suffix = 1; File.Exists(destination) || Directory.Exists(destination); suffix++)
            destination = basis + "-" + suffix.ToString(System.Globalization.CultureInfo.InvariantCulture);
        return destination;
    }
}
