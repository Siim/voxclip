using System.Runtime.InteropServices;
using System.Diagnostics;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Services.Logging;
using VoxClip.Core.Services.Models;
using VoxClip.Core.Services.Project;
using VoxClip.Core.Services.Speech;
using Whisper.net;
using Whisper.net.LibraryLoader;
using Whisper.net.Logger;

namespace VoxClip.Media.Speech;

/// <summary>CPU Whisper.net adapter with independent VAD units and source-aligned tokens; transcription §9.</summary>
public sealed class WhisperNetTranscriber : ITranscriber, IAsyncDisposable
{
    private static readonly object RuntimeGate = new();
    private static readonly SemaphoreSlim NativeJobs = new(1, 1);
    private static bool runtimeConfigured;
    private readonly IModelCatalog catalog;
    private readonly IModelDownloader store;
    private readonly ILog log;
    private readonly SemaphoreSlim operation = new(1, 1);
    private readonly Timer idle;
    private WhisperFactory? factory;
    private string? factoryKey;
    private bool disposed;
    internal WhisperRunMetrics? LastRunMetrics { get; private set; }

    /// <summary>Use bundled catalogue and standard model storage without loading native code at startup.</summary>
    public WhisperNetTranscriber() : this(new ModelCatalog()) { }

    /// <summary>Compose explicit model storage with the bundled catalogue; plan W5.</summary>
    public WhisperNetTranscriber(IModelDownloader models) : this(new ModelCatalog(), models) { }

    /// <summary>Inject model storage, isolated data root and metadata-only diagnostics.</summary>
    public WhisperNetTranscriber(IModelCatalog modelCatalog, IModelDownloader? modelStore = null, string? dataRoot = null, ILog? logger = null)
    {
        catalog = modelCatalog;
        store = modelStore ?? new ModelStore(modelCatalog, dataRoot ?? DataLocations.Resolve().Root);
        log = logger ?? new Log();
        idle = new Timer(_ => _ = ReleaseIdleAsync(), null, Timeout.InfiniteTimeSpan, Timeout.InfiniteTimeSpan);
    }

    /// <inheritdoc />
    public TranscriptEngine Engine => TranscriptEngine.Whispercpp;
    /// <inheritdoc />
    public TranscriberCapabilities Capabilities(string? model)
    {
        var entry = model is null ? null : catalog.GetModelAsync(model, CancellationToken.None).ConfigureAwait(false).GetAwaiter().GetResult();
        var dtw = entry is null || !entry.RawMetadata.GetProperty("whisper").TryGetProperty("dtwDefault", out var value) || value.GetBoolean();
        return new(dtw ? TimingSource.Dtw : TimingSource.TokenGrouped, entry?.Verbatim ?? false,
            entry is not null && IsDetectionModel(entry), null, null, true);
    }

    /// <inheritdoc />
    public async Task<bool> SupportsAsync(LanguageChoice language, string? model, CancellationToken ct)
    {
        var entry = model is null ? null : await catalog.GetModelAsync(model, ct).ConfigureAwait(false);
        if (entry is null || entry.Kind != "asr" || entry.Engine != Engine) return false;
        if (language is LanguageChoice.Auto) return IsDetectionModel(entry);
        var code = await NormalizeAsync(((LanguageChoice.Forced)language).Code, ct).ConfigureAwait(false);
        return (entry.ForcedLanguage is null || entry.ForcedLanguage == code) &&
            (entry.Languages.Contains(code, StringComparer.Ordinal) || entry.Languages.Contains("*", StringComparer.Ordinal));
    }

    /// <inheritdoc />
    public async Task<Readiness> ReadinessAsync(TranscriptionPlan plan, CancellationToken ct)
    {
        if (disposed) return new Readiness.Unavailable("The speech engine was disposed.");
        var model = plan.Model is null ? null : await catalog.GetModelAsync(plan.Model, ct).ConfigureAwait(false);
        if (model is null) return new Readiness.NeedsModels(plan.Model is null ? [] : [plan.Model], 0);
        if (!await SupportsAsync(plan.Language, plan.Model, ct).ConfigureAwait(false))
            return new Readiness.UnsupportedLanguage(plan.Language is LanguageChoice.Forced forced ? forced.Code : "auto");
        var installed = (await store.ListInstalledAsync(ct).ConfigureAwait(false)).Where(entry => entry.Verified).Select(entry => entry.Id).ToHashSet(StringComparer.Ordinal);
        var required = await RequiredAsync(model, ct).ConfigureAwait(false);
        var missing = required.Where(entry => !installed.Contains(entry.Id)).ToArray();
        return missing.Length == 0 ? new Readiness.Ready() : new Readiness.NeedsModels(missing.Select(entry => entry.Id).ToArray(), missing.Sum(entry => entry.TotalBytes));
    }

    /// <inheritdoc />
    public Task PrepareAsync(TranscriptionPlan plan, IProgress<double>? progress, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        return Task.CompletedTask;
    }

    /// <inheritdoc />
    public async Task<RawTranscript> TranscribeAsync(TranscriptionRequest request, IProgress<TranscriptionProgress> progress, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        SpeechCopy.ValidateIdentifiers(request.Plan);
        if (request.Plan.Engine != Engine) throw new ArgumentException("Wrong transcription engine.", nameof(request));
        await TraceAsync("queued").ConfigureAwait(false);
        await operation.WaitAsync(ct).ConfigureAwait(false);
        var handedOff = false;
        try
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            idle.Change(Timeout.InfiniteTimeSpan, Timeout.InfiniteTimeSpan);
            await TraceAsync("readiness").ConfigureAwait(false);
            var readiness = await ReadinessAsync(request.Plan, ct).ConfigureAwait(false);
            if (readiness is Readiness.UnsupportedLanguage)
                throw request.Plan.Language is LanguageChoice.Forced chosen ? SpeechCopy.Unsupported(Engine, chosen.Code) : SpeechCopy.ChooseLanguage();
            if (readiness is not Readiness.Ready)
                throw SpeechCopy.ModelMissing(request.Plan.Model is { } id ? await catalog.GetModelAsync(id, ct).ConfigureAwait(false) : null,
                    request.Plan.Model, readiness is Readiness.NeedsModels missing ? missing.Bytes : 0);
            await NativeJobs.WaitAsync(ct).ConfigureAwait(false);
            handedOff = true;
            return await NativeWork.RunAsync(() => RunOwnedAsync(() => RunAsync(request, progress, ct)), () =>
            {
                if (!disposed) idle.Change(TimeSpan.FromSeconds(120), Timeout.InfiniteTimeSpan);
                NativeJobs.Release();
                operation.Release();
            }, ct).ConfigureAwait(false);
        }
        finally
        {
            if (!handedOff) operation.Release();
        }
    }

    private async Task<T> RunOwnedAsync<T>(Func<Task<T>> run)
    {
        try
        {
            await TraceAsync("native-slot").ConfigureAwait(false);
            return await run().ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            factory?.Dispose(); factory = null; factoryKey = null;
            log.Write(LogLevel.Info, "transcribe", "whispercpp transcription cancelled.");
            throw;
        }
        catch (VoxClipException) { throw; }
        catch (Exception error) when (error is not OutOfMemoryException)
        {
            log.Write(LogLevel.Error, "transcribe", $"whispercpp failure type={error.GetType().FullName} hresult=0x{error.HResult:X8}");
            factory?.Dispose(); factory = null; factoryKey = null;
            throw new VoxClipException(VoxClipErrorCode.TranscriptionFailed, "Transcription stopped: the local speech runtime failed. Your video is still here.");
        }
    }

    private async Task<RawTranscript> RunAsync(TranscriptionRequest request, IProgress<TranscriptionProgress> progress, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        LastRunMetrics = null;
        var model = (await catalog.GetModelAsync(request.Plan.Model!, ct).ConfigureAwait(false))!;
        var required = await RequiredAsync(model, ct).ConfigureAwait(false);
        var installed = (await store.ListInstalledAsync(ct).ConfigureAwait(false)).Where(entry => entry.Verified).ToDictionary(entry => entry.Id, StringComparer.Ordinal);
        if (required.Any(entry => !installed.ContainsKey(entry.Id))) throw SpeechCopy.ModelMissing(model, model.Id, required.Sum(entry => entry.TotalBytes));
        var metadata = model.RawMetadata.GetProperty("whisper");
        var vadModel = required.Single(entry => entry.Id == metadata.GetProperty("vadModel").GetString());
        var vadPath = Path.Combine(installed[vadModel.Id].Directory, vadModel.Files.Single(file => file.Role == "vad").Name);
        var modelFile = model.Files.Single(file => file.Role == "model");
        var modelPath = Path.Combine(installed[model.Id].Directory, modelFile.Name);
        var reporting = new SpeechProgress<TranscriptionProgress>(progress);
        reporting.Report(new(TranscriptionStage.Preparing, 0));
        await TraceAsync("read-audio").ConfigureAwait(false);
        var samples = await WhisperAudio.ReadAsync(request.Audio, ct).ConfigureAwait(false);
        if (samples.Length == 0) throw new VoxClipException(VoxClipErrorCode.NoSpeech, "We didn't hear any words. Check the audio track or choose the language.");
        await Task.Run(() => WhisperAudio.Normalize(samples, ct), ct).ConfigureAwait(false);
        await TraceAsync("audio-normalized").ConfigureAwait(false);
        ct.ThrowIfCancellationRequested();
        ConfigureRuntime();
        ct.ThrowIfCancellationRequested();
        var warningReported = 0;
        using var diagnostics = LogProvider.AddLogger((level, _) =>
        {
            if (level <= WhisperLogLevel.Warning && Interlocked.Exchange(ref warningReported, 1) == 0)
                log.Write(LogLevel.Warn, "transcribe", "whisper.cpp reported a native diagnostic; raw native text was suppressed.");
        });
        var vadTime = Stopwatch.StartNew();
        log.Write(LogLevel.Info, "transcribe", "whispercpp stage vad");
        await TraceAsync("vad-factory").ConfigureAwait(false);
        ct.ThrowIfCancellationRequested();
        IReadOnlyList<VadSegmentData> regions;
        using (var vadFactory = WhisperVadFactory.FromPath(vadPath))
        {
            await TraceAsync("vad-build").ConfigureAwait(false);
            ct.ThrowIfCancellationRequested();
            await using var vad = BuildVad(vadFactory);
            await TraceAsync("vad-detect").ConfigureAwait(false);
            ct.ThrowIfCancellationRequested();
            regions = await vad.DetectSpeechAsync(samples, ct).ConfigureAwait(false);
            ct.ThrowIfCancellationRequested();
        }
        vadTime.Stop();
        await TraceAsync("vad-complete").ConfigureAwait(false);
        ct.ThrowIfCancellationRequested();
        var units = WhisperAudio.MergeRegions(regions, samples.Length);
        if (units.Count == 0) throw new VoxClipException(VoxClipErrorCode.NoSpeech, "We didn't hear any words. Check the audio track or choose the language.");
        var dtw = request.Plan.Options.Dtw;
        var loadTime = Stopwatch.StartNew();
        log.Write(LogLevel.Info, "transcribe", "whispercpp stage model-load");
        await TraceAsync("model-load").ConfigureAwait(false);
        ct.ThrowIfCancellationRequested();
        var contextKey = modelPath + ":" + modelFile.Sha256 + ":" + dtw;
        if (factoryKey != contextKey)
        {
            factory?.Dispose(); factory = null; factoryKey = null;
            factory = await Task.Run(() => CreateFactory(modelPath, metadata, dtw), ct).ConfigureAwait(false);
            factoryKey = contextKey;
        }
        ct.ThrowIfCancellationRequested();
        loadTime.Stop();
        await TraceAsync("model-ready").ConfigureAwait(false);
        log.Write(LogLevel.Info, "transcribe", $"whispercpp model {model.Id}; runtime {RuntimeOptions.LoadedLibrary}; samples {samples.Length}");
        var detectionTime = new Stopwatch();
        return await WithRoutedLanguageAsync(request.Plan, model.ForcedLanguage, async () =>
        {
            detectionTime.Start();
            ct.ThrowIfCancellationRequested();
            using var detector = factory!.CreateBuilder().WithThreads(Threads).Build();
            ct.ThrowIfCancellationRequested();
            var first = units[0];
            var detectionSamples = samples.AsSpan(first.Start, Math.Min(30 * 16000, first.End - first.Start)).ToArray();
            var detection = await Task.Run(() => detector.DetectLanguageWithProbability(detectionSamples), ct).ConfigureAwait(false);
            ct.ThrowIfCancellationRequested();
            detectionTime.Stop();
            return (detection.language, (double)detection.probability);
        }, DecodeAsync, ct).ConfigureAwait(false);

        async Task<RawTranscript> DecodeAsync(string language, double? languageProbability)
        {
            var whisperCode = language;
            if (catalog is ModelCatalog bundled)
            {
                var codes = (await bundled.RootAsync(ct).ConfigureAwait(false)).GetProperty("languageCodes").GetProperty("whisperCodeFor");
                if (codes.TryGetProperty(language, out var alias)) whisperCode = alias.GetString()!;
            }
            var total = units.Sum(unit => (long)unit.End - unit.Start);
            long finished = 0;
            var currentLength = 0;
            var builder = factory!.CreateBuilder().WithLanguage(whisperCode).WithNoContext().WithTokenTimestamps().WithProbabilities()
                .WithThreads(Threads).WithGreedySamplingStrategy(strategy => strategy.WithBestOf(5))
                .WithTokenTimestampsThreshold(0.01f).WithTokenTimestampsSumThreshold(0.01f)
                .WithMaxSegmentLength(0).WithMaxTokensPerSegment(0).WithTemperature(0).WithTemperatureInc(0.2f)
                .WithEntropyThreshold(2.4f).WithLogProbThreshold(-1).WithNoSpeechThreshold(0.6f)
                .WithoutStringPool().WithProgressHandler(percent =>
                {
                    if (!ct.IsCancellationRequested) reporting.Report(new(TranscriptionStage.Transcribing,
                        Math.Clamp((finished + currentLength * (percent / 100.0)) / total, 0, 1)));
                });
            if (metadata.GetProperty("initialPromptByLanguage").TryGetProperty(language, out var prompt))
                builder.WithPrompt(prompt.GetString()!).WithCarryInitialPrompt();
            ct.ThrowIfCancellationRequested();
            loadTime.Start();
            await TraceAsync("processor-build").ConfigureAwait(false);
            await using var processor = builder.Build();
            loadTime.Stop();
            ct.ThrowIfCancellationRequested();
            var tokens = new List<RawToken>();
            var group = 0;
            var dtwTokens = 0;
            var decodeTime = Stopwatch.StartNew();
            log.Write(LogLevel.Info, "transcribe", "whispercpp stage decode");
            ct.ThrowIfCancellationRequested();
            foreach (var unit in units)
            {
                ct.ThrowIfCancellationRequested();
                currentLength = unit.End - unit.Start;
                await foreach (var segment in processor.ProcessAsync(samples.AsMemory(unit.Start, currentLength), ct).ConfigureAwait(false))
                {
                    if (group == 0) await TraceAsync("first-segment").ConfigureAwait(false);
                    tokens.AddRange(WhisperTokens.Map(segment, unit.Start / 16000.0, unit.End / 16000.0, group++,
                        dtw, metadata.GetProperty("multilingual").GetBoolean(), log, () => dtwTokens++));
                }
                finished += currentLength;
            }
            ct.ThrowIfCancellationRequested();
            decodeTime.Stop();
            LastRunMetrics = new(vadTime.Elapsed.TotalSeconds, loadTime.Elapsed.TotalSeconds, detectionTime.Elapsed.TotalSeconds, decodeTime.Elapsed.TotalSeconds);
            if (dtw && dtwTokens == 0) log.Write(LogLevel.Warn, "transcribe", "Whisper returned no DTW timestamps; timing is tokenGrouped.");
            if (!WordAssembler.Group(tokens, new(GroupingEnd.NextWordStart, GroupingConfidence.Mean, true), 0).Any(word => word.Kind == WordKind.Word))
                throw new VoxClipException(VoxClipErrorCode.NoSpeech, "We didn't hear any words. Check the audio track or choose the language.");
            await reporting.CompleteAsync(new(TranscriptionStage.Transcribing, 1), ct).ConfigureAwait(false);
            ct.ThrowIfCancellationRequested();
            return new(new(Engine, model.Id, modelFile.Sha256, "Whisper.net 1.9.1 (whisper.cpp 1.8.5)", null), 1,
                new(GroupingEnd.NextWordStart, GroupingConfidence.Mean, true), tokens, language, languageProbability,
                model.Verbatim, dtw && dtwTokens > 0 ? TimingSource.Dtw : TimingSource.TokenGrouped, null);
        }
    }

    internal async Task<T> WithRoutedLanguageAsync<T>(TranscriptionPlan plan, string? forcedModelLanguage,
        Func<Task<(string? Language, double Probability)>> detect, Func<string, double?, Task<T>> decode, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        var language = forcedModelLanguage ?? (plan.Language is LanguageChoice.Forced forced
            ? await NormalizeAsync(forced.Code, ct).ConfigureAwait(false) : null);
        double? probability = null;
        if (language is null)
        {
            var detected = await detect().ConfigureAwait(false);
            ct.ThrowIfCancellationRequested();
            language = await NormalizeDetectedLanguageAsync(RequireDetectedLanguage(detected.Language, detected.Probability), ct).ConfigureAwait(false);
            probability = detected.Probability;
            var root = await (catalog as ModelCatalog ?? new ModelCatalog()).RootAsync(ct).ConfigureAwait(false);
            var defaults = root.GetProperty("defaults").GetProperty("byLanguage");
            var candidates = (defaults.TryGetProperty(language, out var chosen) ? chosen : defaults.GetProperty("*")).GetProperty("windows").GetProperty("local");
            if (!candidates.EnumerateArray().Any(candidate => candidate.GetString() == plan.Model))
                throw SpeechCopy.Unsupported(Engine, language);
        }
        ct.ThrowIfCancellationRequested();
        return await decode(language, probability).ConfigureAwait(false);
    }

    /// <summary>Detect the spoken language before routing; transcription §9.8 and §11.2. The plan names an installed OpenAI
    /// multilingual model with <see cref="LanguageChoice.Auto"/>. Uses the first 30 s of the first speech unit of the normalized
    /// audio, exactly as an automatic transcription would, and returns the BCP 47 code with its probability; the caller applies
    /// the 0.5 threshold. The loaded model stays warm for the transcription that follows. Nothing is decoded or uploaded.</summary>
    public async Task<(string Language, double Probability)> DetectLanguageAsync(TranscriptionRequest request, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        SpeechCopy.ValidateIdentifiers(request.Plan);
        if (request.Plan.Engine != Engine || request.Plan.Language is not LanguageChoice.Auto)
            throw new ArgumentException("Language detection needs an automatic-language Whisper plan.", nameof(request));
        await TraceAsync("detect-queued").ConfigureAwait(false);
        await operation.WaitAsync(ct).ConfigureAwait(false);
        var handedOff = false;
        try
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            idle.Change(Timeout.InfiniteTimeSpan, Timeout.InfiniteTimeSpan);
            var readiness = await ReadinessAsync(request.Plan, ct).ConfigureAwait(false);
            if (readiness is Readiness.UnsupportedLanguage) throw SpeechCopy.ChooseLanguage();
            if (readiness is not Readiness.Ready)
                throw SpeechCopy.ModelMissing(request.Plan.Model is { } id ? await catalog.GetModelAsync(id, ct).ConfigureAwait(false) : null,
                    request.Plan.Model, readiness is Readiness.NeedsModels missing ? missing.Bytes : 0);
            await NativeJobs.WaitAsync(ct).ConfigureAwait(false);
            handedOff = true;
            return await NativeWork.RunAsync(() => RunOwnedAsync(() => DetectAsync(request, ct)), () =>
            {
                if (!disposed) idle.Change(TimeSpan.FromSeconds(120), Timeout.InfiniteTimeSpan);
                NativeJobs.Release();
                operation.Release();
            }, ct).ConfigureAwait(false);
        }
        finally
        {
            if (!handedOff) operation.Release();
        }
    }

    private async Task<(string Language, double Probability)> DetectAsync(TranscriptionRequest request, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        var model = (await catalog.GetModelAsync(request.Plan.Model!, ct).ConfigureAwait(false))!;
        var required = await RequiredAsync(model, ct).ConfigureAwait(false);
        var installed = (await store.ListInstalledAsync(ct).ConfigureAwait(false)).Where(entry => entry.Verified).ToDictionary(entry => entry.Id, StringComparer.Ordinal);
        if (required.Any(entry => !installed.ContainsKey(entry.Id))) throw SpeechCopy.ModelMissing(model, model.Id, required.Sum(entry => entry.TotalBytes));
        var metadata = model.RawMetadata.GetProperty("whisper");
        var vadModel = required.Single(entry => entry.Id == metadata.GetProperty("vadModel").GetString());
        var vadPath = Path.Combine(installed[vadModel.Id].Directory, vadModel.Files.Single(file => file.Role == "vad").Name);
        var modelFile = model.Files.Single(file => file.Role == "model");
        var modelPath = Path.Combine(installed[model.Id].Directory, modelFile.Name);
        var samples = await WhisperAudio.ReadAsync(request.Audio, ct).ConfigureAwait(false);
        if (samples.Length == 0) throw new VoxClipException(VoxClipErrorCode.NoSpeech, "We didn't hear any words. Check the audio track or choose the language.");
        await Task.Run(() => WhisperAudio.Normalize(samples, ct), ct).ConfigureAwait(false);
        ct.ThrowIfCancellationRequested();
        ConfigureRuntime();
        var warningReported = 0;
        using var diagnostics = LogProvider.AddLogger((level, _) =>
        {
            if (level <= WhisperLogLevel.Warning && Interlocked.Exchange(ref warningReported, 1) == 0)
                log.Write(LogLevel.Warn, "transcribe", "whisper.cpp reported a native diagnostic; raw native text was suppressed.");
        });
        await TraceAsync("detect-vad").ConfigureAwait(false);
        IReadOnlyList<VadSegmentData> regions;
        using (var vadFactory = WhisperVadFactory.FromPath(vadPath))
        {
            ct.ThrowIfCancellationRequested();
            await using var vad = BuildVad(vadFactory);
            regions = await vad.DetectSpeechAsync(samples, ct).ConfigureAwait(false);
        }
        ct.ThrowIfCancellationRequested();
        var units = WhisperAudio.MergeRegions(regions, samples.Length);
        if (units.Count == 0) throw new VoxClipException(VoxClipErrorCode.NoSpeech, "We didn't hear any words. Check the audio track or choose the language.");
        var dtw = request.Plan.Options.Dtw;
        var contextKey = modelPath + ":" + modelFile.Sha256 + ":" + dtw;
        await TraceAsync("detect-model-load").ConfigureAwait(false);
        if (factoryKey != contextKey)
        {
            factory?.Dispose(); factory = null; factoryKey = null;
            factory = await Task.Run(() => CreateFactory(modelPath, metadata, dtw), ct).ConfigureAwait(false);
            factoryKey = contextKey;
        }
        ct.ThrowIfCancellationRequested();
        using var detector = factory!.CreateBuilder().WithThreads(Threads).Build();
        var first = units[0];
        var detectionSamples = samples.AsSpan(first.Start, Math.Min(30 * 16000, first.End - first.Start)).ToArray();
        var detection = await Task.Run(() => detector.DetectLanguageWithProbability(detectionSamples), ct).ConfigureAwait(false);
        ct.ThrowIfCancellationRequested();
        await TraceAsync("detect-complete").ConfigureAwait(false);
        var probability = (double)detection.probability;
        return string.IsNullOrWhiteSpace(detection.language) || !double.IsFinite(probability) ? ("", 0)
            : (await NormalizeDetectedLanguageAsync(detection.language, ct).ConfigureAwait(false), probability);
    }

    private static WhisperVadProcessor BuildVad(WhisperVadFactory vadFactory) => vadFactory.CreateBuilder().WithUseGpu(false).WithThreads(Threads)
        .WithThreshold(0.30f).WithMinSpeechDuration(TimeSpan.FromMilliseconds(250))
        .WithMinSilenceDuration(TimeSpan.FromMilliseconds(2000)).WithSpeechPadding(TimeSpan.FromMilliseconds(400))
        .WithSamplesOverlap(TimeSpan.FromMilliseconds(100)).Build();

    private static WhisperFactory CreateFactory(string modelPath, System.Text.Json.JsonElement metadata, bool dtw) => WhisperFactory.FromPath(modelPath, new WhisperFactoryOptions
    {
        UseGpu = false, UseFlashAttention = !dtw, UseDtwTimeStamps = dtw,
        HeadsPreset = Preset(metadata.GetProperty("dtwAheadsPreset").GetString()!)
    });

    private static int Threads => Math.Min(8, Math.Max(2, Environment.ProcessorCount / 2));
    private async Task TraceAsync(string stage)
    {
        log.Write(LogLevel.Info, "transcribe", $"whispercpp stage={stage}");
        await log.FlushAsync(CancellationToken.None).ConfigureAwait(false);
    }
    internal static string RequireDetectedLanguage(string? language, double probability) =>
        !string.IsNullOrWhiteSpace(language) && probability >= 0.5 ? language : throw SpeechCopy.ChooseLanguage();
    private static bool IsDetectionModel(TranscriptionModel model) => model.Id.StartsWith("whisper-large-v3-turbo-", StringComparison.Ordinal) &&
        model.RawMetadata.GetProperty("whisper").GetProperty("multilingual").GetBoolean();
    private Task<string> NormalizeAsync(string code, CancellationToken ct) => catalog is ModelCatalog bundled
        ? bundled.NormalizeLanguageAsync(code, ct) : Task.FromResult(code.Split('-')[0].ToLowerInvariant());
    internal Task<string> NormalizeDetectedLanguageAsync(string code, CancellationToken ct) => catalog is ModelCatalog bundled
        ? bundled.FromWhisperLanguageAsync(code, ct) : NormalizeAsync(code, ct);
    private async Task<IReadOnlyList<TranscriptionModel>> RequiredAsync(TranscriptionModel model, CancellationToken ct)
    {
        var result = new List<TranscriptionModel> { model };
        for (var index = 0; index < result.Count; index++)
            foreach (var id in result[index].Requires)
                if (result.All(entry => entry.Id != id)) result.Add(await catalog.GetModelAsync(id, ct).ConfigureAwait(false)
                    ?? throw SpeechCopy.ModelMissing(null, id, 0));
        return result;
    }

    private static WhisperAlignmentHeadsPreset Preset(string preset) => preset switch
    {
        "LARGE_V3_TURBO" => WhisperAlignmentHeadsPreset.LargeV3Turbo,
        "SMALL_EN" => WhisperAlignmentHeadsPreset.SmallEn,
        "BASE_EN" => WhisperAlignmentHeadsPreset.BaseEn,
        _ => throw new InvalidDataException("Unknown alignment-head preset.")
    };

    private static void ConfigureRuntime()
    {
        lock (RuntimeGate)
        {
            if (runtimeConfigured) return;
            RuntimeOptions.RuntimeLibraryOrder = RuntimeInformation.ProcessArchitecture == Architecture.X64
                ? [RuntimeLibrary.Cpu, RuntimeLibrary.CpuNoAvx] : [RuntimeLibrary.Cpu];
            runtimeConfigured = true;
        }
    }

    private async Task ReleaseIdleAsync()
    {
        await operation.WaitAsync().ConfigureAwait(false);
        try { factory?.Dispose(); factory = null; factoryKey = null; }
        finally { operation.Release(); }
    }

    /// <summary>Release a warm context after active decoding has stopped.</summary>
    public async ValueTask DisposeAsync()
    {
        await operation.WaitAsync().ConfigureAwait(false);
        try
        {
            if (disposed) return;
            disposed = true;
            idle.Dispose(); factory?.Dispose(); factory = null; factoryKey = null;
        }
        finally { operation.Release(); }
    }
}

internal sealed record WhisperRunMetrics(double VadSeconds, double ModelLoadSeconds, double DetectionSeconds, double DecodeSeconds);
