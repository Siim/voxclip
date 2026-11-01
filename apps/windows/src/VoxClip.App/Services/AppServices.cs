using System.Reflection;
using System.Text.Json;
using Microsoft.UI.Xaml;
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.Logging;
using VoxClip.Core.Services.Project;
using VoxClip.Core.Services.Settings;
using VoxClip.Core.Services.Share;
using VoxClip.Core.Services.Media;
using VoxClip.Core.Services.Models;
using VoxClip.Core.Services.Speech;
using VoxClip.Core.Services.LLM;
using VoxClip.Core.Services.Updates;
using VoxClip.Media.Pipeline;
using VoxClip.Media.Speech;
using Microsoft.UI.Dispatching;
using VoxClip.Core.Domain.VoiceLab;

namespace VoxClip.App.Services;

internal sealed class AppServices : IAsyncDisposable
{
    internal DataLocations Data { get; } = DataLocations.Resolve();
    internal ILog Log { get; }
    internal SecretStore Keys { get; }
    internal IProjectStore Projects { get; } = new ProjectStore();
    /// <summary>The user's settings file. A development build outside the harness reads an unset Voice Lab switch and beta notice as
    /// on and never saves that overlay; an explicit value wins (doc/spec/voice-lab.md §5).</summary>
    internal ISettingsStore SettingsStore { get; } = new SettingsStore { UnsetDefaults = VoiceLabBeta.DevelopmentDefaults(RewriteEntryPolicy.DevelopmentDefaults(Program.Arguments)) };
    internal AppSettings Settings => settingsWrites.Current;
    internal IMediaProbe Probe { get; } = new FfmpegMediaProbe();
    internal IAudioExtractor Audio { get; } = new FfmpegAudioExtractor();
    internal IExporter Exporter { get; } = new Exporter();
    internal ExportLedger ExportLedger { get; }
    internal IModelCatalog Models { get; } = new ModelCatalog();
    internal IModelDownloader Downloads { get; }
    internal ITranscriptionService Transcription { get; private set; } = null!;
    internal LocalRuntimeGuard LocalRuntime { get; } = new(LocalRuntimeFiles.ReadVersion);
    internal IClipFinder ClipFinder { get; private set; } = null!;
    internal IEncoderProbe Encoders { get; } = new EncoderProbe();
    internal IUpdateChecker Updates { get; }
    /// <summary>Home and sidebar poster frames in each source's content-key cache entry (design §5.4.7).</summary>
    internal Thumbnails Thumbnails { get; }
    internal Waveform Waveform { get; }
    /// <summary>The data folder's cache entries (architecture §8.2), shared by extraction, editors and eviction.</summary>
    internal CacheIndex Cache { get; }
    /// <summary>The content keys in use in the cache, across every window: open projects, extraction, transcription and
    /// language detection, waveform reads and thumbnail posters (architecture §8.2).</summary>
    internal CacheKeyRegistry CacheKeys => Cache.Keys;
    /// <summary>Background eviction under the cache size limit, Clear cache and Clear everything (architecture §8.2).</summary>
    internal CacheUpkeep CacheUpkeep { get; }
    /// <summary>Caption cards for media with no frame (design §5.4); null when the caption resources are missing.</summary>
    internal CaptionCards? Cards { get; private set; }
    internal string? SharedRoot { get; private set; }
    internal string StartupNotice { get; private set; } = "";
    internal bool IsBusy => BusyOperations > 0;
    private int busyOperations;
    internal int BusyOperations { get => busyOperations; set { busyOperations = Math.Max(0, value); BusyChanged?.Invoke(this, EventArgs.Empty); } }
    internal event EventHandler? BusyChanged;
    internal static string Version => Assembly.GetEntryAssembly()?.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion.Split('+')[0] ?? "unknown";
    internal event EventHandler? SettingsChanged;
    private readonly SettingsWriteQueue settingsWrites;
#if DEBUG
    internal SettingsWriteQueue DebugSettingsWrites => settingsWrites;
#endif
    private WhisperNetTranscriber? localSpeech;
    private readonly List<ElevenLabsTranscriber> cloudSpeechInstances = [];
    private VoiceLabSession? voiceLab;
    private CreateVoiceSession? voiceEnrollment;
#if DEBUG
    private DebugVoiceLabBackend? debugVoiceLab;
    internal int? DebugVoiceLabHttpCalls => debugVoiceLab?.HttpCalls;
#endif
    private readonly DispatcherQueue dispatcher = DispatcherQueue.GetForCurrentThread();
    internal bool VoiceLabEnabled => RewriteEntryPolicy.Available(Settings.GetBool("voiceLab.enabled") == true,
        Settings.GetBool("voiceLab.betaNoticeAccepted") == true);
    internal VoiceLabSession VoiceLab
    {
        get
        {
            if (voiceLab is not null) return voiceLab;
            async Task Consent(CancellationToken ct)
            {
                Task? save = null;
                await OnUiAsync(() => save = SetAsync("voiceLab.providerConsent.elevenlabs", true, ct));
                await save!;
            }
            IVoiceLabBackend backend = new VoiceLabBackend(Data, Keys, Log, () => VoiceLabEnabled,
                () => ElevenLabsRegions.FromSettings(Settings, Log), Consent);
#if DEBUG
            var fixtures = Environment.GetEnvironmentVariable("VOXCLIP_DEBUG_VOICELAB");
            if (fixtures?.StartsWith("fixtures:", StringComparison.Ordinal) == true)
                backend = debugVoiceLab = DebugVoiceLabBackend.FromFixtures(fixtures[9..], () => VoiceLabEnabled, Consent);
#endif
            voiceLab = new(backend, OnUiAsync);
            return voiceLab;
        }
    }
    internal async Task<CreateVoiceSession> CreateVoiceEnrollmentAsync(CancellationToken ct)
    {
        async Task Consent(CancellationToken cancellation)
        {
            Task? save = null;
            await OnUiAsync(() => save = SetAsync("voiceLab.providerConsent.elevenlabs", true, cancellation));
            await save!;
        }
        var selectedRegion = ElevenLabsRegions.FromSettings(Settings, Log);
        Func<bool>? speaker = null;
        Func<VoiceConsentStatement, VoxClip.Core.Domain.Transcript.TranscriptionRequest, CancellationToken, Task<VoxClip.Core.Domain.Transcript.RawTranscript>>? scribe = null;
#if DEBUG
        var fixtures = Environment.GetEnvironmentVariable("VOXCLIP_DEBUG_VOICELAB");
        if (fixtures?.StartsWith("fixtures:", StringComparison.Ordinal) == true)
        {
            speaker = () => DebugAvailableSpeakerCheck.Available;
            var fake = new DebugConsentScribe(fixtures[9..]);
            scribe = async (statement, request, cancellation) =>
            {
                var result = await fake.TranscribeAsync(statement, request, cancellation);
                Directory.CreateDirectory(Data.Cache);
                await File.WriteAllTextAsync(Path.Combine(Data.Cache, "consent-scribe-result.json"),
                    System.Text.Json.JsonSerializer.Serialize(new { fixture = "consent-scribe.json", calls = fake.Calls, httpCalls = 0 }), cancellation);
                return result;
            };
        }
#endif
        var backend = await Task.Run(() => new VoiceStatementBackend(Data, Keys, Log, selectedRegion,
            () => VoiceLabEnabled, () => VoiceLab.PlanMessage, Consent, speakerAvailable: speaker, transcribe: scribe), ct);
        if (ct.IsCancellationRequested) { backend.Dispose(); ct.ThrowIfCancellationRequested(); }
        IVoiceStatementBackend selected = backend;
#if DEBUG
        if (fixtures?.StartsWith("fixtures:", StringComparison.Ordinal) == true && debugVoiceLab is not null)
            selected = new DebugVoiceCreationBackend(backend, debugVoiceLab, Data, fixtures[9..]);
#endif
        return voiceEnrollment = new(selected, new VoiceStatementCapture(new VoxClip.Media.Audio.VoiceMicrophoneRecorder(Log)), OnUiAsync);
    }
#if DEBUG
    internal string? DebugMicrophoneSettingsUri { get; set; }
#endif
    private Task OnUiAsync(Action action)
    {
        if (dispatcher.HasThreadAccess) { action(); return Task.CompletedTask; }
        var completion = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        if (!dispatcher.TryEnqueue(() =>
        {
            try { action(); completion.SetResult(); }
            catch (Exception exception) { completion.SetException(exception); }
        })) completion.SetException(new InvalidOperationException("The UI dispatcher is closed."));
        return completion.Task;
    }

    internal AppServices()
    {
        Log = StartupDiagnostics.Log;
        settingsWrites = new(SettingsStore);
        settingsWrites.Changed += key =>
        {
            if (key == "transcription.elevenlabs.region" && localSpeech is not null) ConfigureCloudSpeech();
            // Window layout (ui.*, such as the splitter's width) changes nothing the listeners show.
            if (!key.StartsWith("ui.", StringComparison.Ordinal)) SettingsChanged?.Invoke(this, EventArgs.Empty);
            if (key is "voiceLab.enabled" or "voiceLab.betaNoticeAccepted")
                _ = VoiceLab.RefreshEnabledStateAsync();
        };
        Keys = new(Data.Secrets, Log);
        Downloads = new ModelStore(Models, Data.Root);
        Updates = new UpdateChecker(new VelopackUpdates(this));
        Thumbnails = new(Data.Cache, message => Log.Write(LogLevel.Warn, "thumbnails", message));
        Waveform = new(Audio, Data.Cache);
        Cache = new(Data.Cache);
        CacheUpkeep = new(new CacheEvictionScheduler(Cache, () => CacheUpkeep.LimitBytes(Settings), message => Log.Write(LogLevel.Warn, "cache", message)),
            () => Settings);
        // A lower cache limit is enforced at once (architecture §8.2).
        settingsWrites.Changed += key => CacheUpkeep.SettingChanged(key);
        ExportLedger = new(Path.Combine(Data.Root, "exports.json"));
    }

    internal async Task InitializeAsync(CancellationToken ct)
    {
        try { await ExportLedger.LoadAsync(ct); }
        catch (Exception exception) { StartupNotice = UiError.Message(exception, "Export history"); }
        // Share-text rules load now, so an invalid shared/data/share-text.json fails at launch, not in the Export dialog.
        try { SharedRoot = SharedResources.ResolveRoot(); SharePostText.Preflight(); }
        catch (Exception exception) { StartupNotice = UiError.Message(exception, "Startup"); }
        if (SharedRoot is not null) Cards = new(SharedRoot);
        try { settingsWrites.Initialize(await SettingsStore.LoadAsync(ct)); }
        catch (Exception exception) { StartupNotice = UiError.Message(exception, "Settings"); }
        // The cache size limit is kept in the background, first 30 s after launch (architecture §8.2).
        CacheUpkeep.Started();
        localSpeech = new WhisperNetTranscriber(Models, Downloads, Data.Root, Log);
        ConfigureCloudSpeech();
        ClipFinder = new ClipFinder(new LlmCatalog(), Keys, new Redactor(), id => Connector(id));
        await Task.Run(() => VoiceLabBackend.ReconcileLocalStatements(Data), ct);
        await VoiceLab.ReconcileStartupAsync();
    }

    internal LlmConnector Connector(ConnectorId id)
    {
        var wireId = id switch { ConnectorId.OpenAI => "openai", ConnectorId.LmStudio => "lmstudio", ConnectorId.ClaudeCode => "claude-code", _ => id.ToString().ToLowerInvariant() };
        return new(id, Keys, new LlmCatalog(), new Redactor(),
            Get("llm.baseUrl." + wireId, ""), Get("llm.cliPath." + wireId, ""));
    }

    internal IModelDownloader Installer(Func<TranscriptionModel, IReadOnlyList<TranscriptionModel>, CancellationToken, Task<bool>> confirm) =>
        new ModelStore(Models, Data.Root, confirmDownload: confirm);

    /// <summary>Raised on the UI thread after a model is installed or removed, so open model lists (the Transcribe dialog) follow.</summary>
    internal event EventHandler? ModelsChanged;
    internal void NotifyModelsChanged() => ModelsChanged?.Invoke(this, EventArgs.Empty);

    /// <summary>Detect the spoken language with an installed multilingual model before routing; transcription §9.8 and §11.2.</summary>
    internal async Task<(string Language, double Probability)> DetectLanguageAsync(VoxClip.Core.Domain.Transcript.TranscriptionRequest request, CancellationToken ct)
    {
        var speech = localSpeech ?? throw new InvalidOperationException("Local transcription is not ready.");
        // Detection reads the source's cache entry, so eviction leaves it alone meanwhile (architecture §8.2).
        using var lease = await CacheKeys.LeaseAsync(request.ContentKey, ct);
        return await speech.DetectLanguageAsync(request, ct);
    }

    internal T Get<T>(string key, T fallback)
    {
        if (!Settings.Values.TryGetValue(key, out var value)) return fallback;
        try { return value.Deserialize<T>() ?? fallback; }
        catch (JsonException) { return fallback; }
    }

    internal Task SetAsync<T>(string key, T value, CancellationToken ct = default) => settingsWrites.SetAsync(key, value, ct);

    /// <summary>Settings → General → "Show transcript words on placeholders" (design §5.4.2), from the Core settings with
    /// their schema default.</summary>
    internal bool ShowPlaceholderWords => Settings.GetBool("general.showPlaceholderWords") ?? true;

    internal void FreezeSettings() => settingsWrites.Freeze();
    internal Task DrainSettingsAsync(CancellationToken ct) => settingsWrites.DrainAsync(ct);
    internal Task FlushSettingsAsync(CancellationToken ct) => settingsWrites.FlushAsync(ct);
    internal void ResumeSettings() => settingsWrites.Resume();

    internal void ApplyTheme(FrameworkElement root) => root.RequestedTheme = Get("general.appearance", "system") switch
    {
        "light" => ElementTheme.Light, "dark" => ElementTheme.Dark, _ => ElementTheme.Default
    };

    private void ConfigureCloudSpeech()
    {
        var cloudSpeech = ElevenLabsTranscriber.FromSettings(Keys, Settings, Log, Models as ModelCatalog);
        cloudSpeechInstances.Add(cloudSpeech);
        Transcription = new TranscriptionService([localSpeech!, cloudSpeech], Models, Data.Root);
    }

    internal Task<IReadOnlyList<CaptionStyle>> ReadStylesAsync(CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        if (SharedRoot is null) return Task.FromResult<IReadOnlyList<CaptionStyle>>([]);
        return Task.FromResult(CaptionStyleLibrary.Load(SharedRoot).Styles);
    }

    internal async Task RememberAsync(string path, CancellationToken ct)
    {
        var recent = Get<string[]>("general.recentProjects", []);
        await SetAsync("general.recentProjects", new[] { path }.Concat(recent.Where(item => !item.Equals(path, StringComparison.OrdinalIgnoreCase))).Take(20).ToArray(), ct);
    }

    public async ValueTask DisposeAsync()
    {
        if (voiceEnrollment is not null) await voiceEnrollment.DisposeAsync();
        voiceLab?.Dispose();
        try { await SettingsStore.FlushAsync(CancellationToken.None); }
        catch (Exception) { Log.Write(LogLevel.Warn, "settings", "flush failed"); }
        if (localSpeech is not null) await localSpeech.DisposeAsync();
        foreach (var instance in cloudSpeechInstances) instance.Dispose();
        await Log.DisposeAsync();
    }
}
