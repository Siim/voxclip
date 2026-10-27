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

namespace VoxClip.App.Services;

internal sealed class AppServices : IAsyncDisposable
{
    internal DataLocations Data { get; } = DataLocations.Resolve();
    internal ILog Log { get; }
    internal SecretStore Keys { get; }
    internal IProjectStore Projects { get; } = new ProjectStore();
    internal ISettingsStore SettingsStore { get; } = new SettingsStore();
    internal AppSettings Settings => settingsWrites.Current;
    internal IMediaProbe Probe { get; } = new FfmpegMediaProbe();
    internal IAudioExtractor Audio { get; } = new FfmpegAudioExtractor();
    internal IExporter Exporter { get; } = new Exporter();
    internal IModelCatalog Models { get; } = new ModelCatalog();
    internal IModelDownloader Downloads { get; }
    internal ITranscriptionService Transcription { get; private set; } = null!;
    internal IClipFinder ClipFinder { get; private set; } = null!;
    internal IEncoderProbe Encoders { get; } = new EncoderProbe();
    internal IUpdateChecker Updates { get; }
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

    internal AppServices()
    {
        Log = StartupDiagnostics.Log;
        settingsWrites = new(SettingsStore);
        settingsWrites.Changed += key =>
        {
            if (key == "transcription.elevenlabs.region" && localSpeech is not null) ConfigureCloudSpeech();
            SettingsChanged?.Invoke(this, EventArgs.Empty);
        };
        Keys = new(Data.Secrets, Log);
        Downloads = new ModelStore(Models, Data.Root);
        Updates = new UpdateChecker(new VelopackUpdates(this));
    }

    internal async Task InitializeAsync(CancellationToken ct)
    {
        // Share-text rules load now, so an invalid shared/data/share-text.json fails at launch, not in the Export dialog.
        try { SharedRoot = SharedResources.ResolveRoot(); SharePostText.Preflight(); }
        catch (Exception exception) { StartupNotice = UiError.Message(exception, "Startup"); }
        try { settingsWrites.Initialize(await SettingsStore.LoadAsync(ct)); }
        catch (Exception exception) { StartupNotice = UiError.Message(exception, "Settings"); }
        localSpeech = new WhisperNetTranscriber(Models, Downloads, Data.Root, Log);
        ConfigureCloudSpeech();
        ClipFinder = new ClipFinder(new LlmCatalog(), Keys, new Redactor(), id => Connector(id));
    }

    internal LlmConnector Connector(ConnectorId id)
    {
        var wireId = id switch { ConnectorId.OpenAI => "openai", ConnectorId.LmStudio => "lmstudio", ConnectorId.ClaudeCode => "claude-code", _ => id.ToString().ToLowerInvariant() };
        return new(id, Keys, new LlmCatalog(), new Redactor(),
            Get("llm.baseUrl." + wireId, ""), Get("llm.cliPath." + wireId, ""));
    }

    internal T Get<T>(string key, T fallback)
    {
        if (!Settings.Values.TryGetValue(key, out var value)) return fallback;
        try { return value.Deserialize<T>() ?? fallback; }
        catch (JsonException) { return fallback; }
    }

    internal Task SetAsync<T>(string key, T value, CancellationToken ct = default) => settingsWrites.SetAsync(key, value, ct);

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
        try { await SettingsStore.FlushAsync(CancellationToken.None); }
        catch (Exception) { Log.Write(LogLevel.Warn, "settings", "flush failed"); }
        if (localSpeech is not null) await localSpeech.DisposeAsync();
        foreach (var instance in cloudSpeechInstances) instance.Dispose();
        await Log.DisposeAsync();
    }
}
