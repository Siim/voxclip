using System.Diagnostics;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Services.Models;
using VoxClip.Core.Services.Speech;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.Speech;

public sealed class RoutingAndCacheTests
{
    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task ExplicitEnvelopeNeverResolvesTheCompatibilityEnvelope(bool hasEnvelope)
    {
        using var files = new SpeechFiles();
        var resolutions = 0;
        ITranscriptionService service = new TranscriptionService([new StubEngine()], dataRoot: files.Root,
            analysisEnvelope: (_, _) => { resolutions++; return Task.FromResult<AudioEnvelope?>(null); });
        var result = await service.TranscribeAsync(files.Request(), hasEnvelope ? new(16000, 0.01, [0.1f]) : null,
            null, TestContext.Current.CancellationToken);
        Assert.Single(result.Words);
        Assert.Equal(0, resolutions);
        await service.TranscribeAsync(files.Request(), new CaptureProgress<TranscriptionProgress>(), TestContext.Current.CancellationToken);
        Assert.Equal(1, resolutions);
    }

    [Fact]
    public async Task CompositionConstructorUsesTheSuppliedDataRoot()
    {
        using var files = new SpeechFiles();
        var locations = new VoxClip.Core.Services.Project.DataLocations(files.Root, "unused", "unused", "unused", "unused", "unused", "unused");
        var service = new TranscriptionService([new StubEngine()], locations);
        await service.TranscribeAsync(files.Request(), null, null, TestContext.Current.CancellationToken);
        Assert.Single(Directory.EnumerateFiles(Path.Combine(files.Root, "Cache"), "*.json", SearchOption.AllDirectories));
    }

    [Theory]
    [InlineData("est", "et")]
    [InlineData("eng", "en")]
    [InlineData("cmn", "zh")]
    [InlineData("xyz", "xyz")]
    [InlineData("EN-US", "en")]
    public async Task CatalogueNormalizesLanguageWithoutInventingUnknownMappings(string input, string expected)
        => Assert.Equal(expected, await new ModelCatalog().NormalizeLanguageAsync(input, TestContext.Current.CancellationToken));

    [Fact]
    public async Task CatalogueHasPinnedFilesValidReferencesAndApprovedLicences()
    {
        var models = await new ModelCatalog().GetModelsAsync(TestContext.Current.CancellationToken);
        Assert.Equal(9, models.Count);
        foreach (var model in models)
        {
            Assert.Equal(model.TotalBytes, model.Files.Sum(file => file.Bytes));
            Assert.All(model.Requires, id => Assert.Contains(models, entry => entry.Id == id));
            Assert.All(model.Files, file => Assert.Matches("^[a-f0-9]{64}$", file.Sha256));
            Assert.All(model.Files, file => Assert.Contains("/resolve/" + model.RawMetadata.GetProperty("repo").GetProperty("revision").GetString() + "/", file.Url.AbsoluteUri));
        }
    }

    [Theory]
    [InlineData("license", "CC-BY-NC-4.0")]
    [InlineData("fileName", "../escape.bin")]
    [InlineData("fileName", "CON.bin")]
    [InlineData("sha256", "incorrect")]
    [InlineData("licenseUrl", null)]
    [InlineData("url", null)]
    [InlineData("id", null)]
    public async Task CatalogueRejectsUnsafeOrNonCommercialEntries(string field, string? value)
    {
        using var files = new SpeechFiles();
        await files.CatalogueAsync(Encoding.UTF8.GetBytes("model"));
        var path = Path.Combine(files.Root, "catalog.json");
        var node = JsonNode.Parse(await File.ReadAllTextAsync(path, TestContext.Current.CancellationToken))!;
        var model = node["models"]![0]!;
        if (field is "license" or "licenseUrl" or "id") model[field] = value; else model["files"]![0]![field == "fileName" ? "name" : field] = value;
        await File.WriteAllTextAsync(path, node.ToJsonString(), TestContext.Current.CancellationToken);
        var error = await Assert.ThrowsAsync<VoxClipException>(() => ModelCatalog.FromFile(path).GetModelsAsync(TestContext.Current.CancellationToken));
        Assert.Equal(VoxClipErrorCode.SharedResourcesMissing, error.Code);
    }

    [Theory]
    [InlineData("et", "taltech-et-verbatim-2604-q4_0")]
    [InlineData("en", "whisper-small.en-q5_1")]
    public async Task LowMemoryRoutingOffersSmallerLocalDownloadWithoutCloudFallback(string language, string expected)
    {
        var router = new TranscriptionRouter(new ModelCatalog(), new InstalledOnly([]));
        var decision = await router.RouteAsync("local", new LanguageChoice.Forced(language), 4L << 30, true, null, TestContext.Current.CancellationToken);
        Assert.Null(decision.Plan);
        Assert.Contains(expected, Assert.IsType<Readiness.NeedsModels>(decision.Readiness).Ids);
        Assert.True(decision.OfferCloud);
    }

    [Fact]
    public async Task InstalledEnglishSpecificModelWinsOverMultilingual()
    {
        var router = new TranscriptionRouter(new ModelCatalog(), new InstalledOnly(["whisper-small.en-q5_1", "whisper-large-v3-turbo-q5_0"]));
        var decision = await router.RouteAsync("local", new LanguageChoice.Forced("eng"), 16L << 30, true, null, TestContext.Current.CancellationToken);
        Assert.Equal("whisper-small.en-q5_1", decision.Plan!.Model);
        Assert.Equal(TranscriptEngine.Whispercpp, decision.Plan.Engine);
    }

    [Fact]
    public async Task AutoNeverUploadsForLanguageDetection()
    {
        var router = new TranscriptionRouter(new ModelCatalog(), new InstalledOnly(["taltech-et-verbatim-2604-q8_0"]));
        var decision = await router.RouteAsync("local", new LanguageChoice.Auto(), 16L << 30, true,
            _ => throw new InvalidOperationException("Must not detect using a TalTech model."), TestContext.Current.CancellationToken);
        Assert.Null(decision.Plan);
        Assert.Equal("chooseLanguage", decision.Prompt);
        Assert.False(decision.OfferCloud);
    }

    [Theory]
    [InlineData(0.49, false)]
    [InlineData(0.5, true)]
    public async Task DetectionThresholdControlsLocalRerouting(double probability, bool routed)
    {
        var router = new TranscriptionRouter(new ModelCatalog(), new InstalledOnly(["whisper-large-v3-turbo-q5_0"]));
        var decision = await router.RouteAsync("local", new LanguageChoice.Auto(), 16L << 30, true,
            _ => Task.FromResult<(string, double)?>( ("en", probability) ), TestContext.Current.CancellationToken);
        Assert.Equal(routed, decision.Plan is not null);
        if (routed) Assert.Equal(TranscriptEngine.Whispercpp, decision.Plan!.Engine);
    }

    [Fact]
    public void CacheKeySortsKeytermsAndContainsAllOptionsWithoutContentPath()
    {
        using var files = new SpeechFiles();
        var first = TranscriptionService.CacheKey(files.Request(new(Keyterms: ["õhtu", "hello"])), null);
        var second = TranscriptionService.CacheKey(files.Request(new(Keyterms: ["hello", "õhtu"])), null);
        Assert.Equal(first, second);
        using var document = JsonDocument.Parse(first);
        var names = document.RootElement.EnumerateObject().Select(property => property.Name).ToArray();
        Assert.Equal(names.Order(StringComparer.Ordinal), names);
        Assert.Equal(11, names.Length);
        Assert.DoesNotContain(files.Root, Encoding.UTF8.GetString(first));
        Assert.Equal(JsonValueKind.Null, document.RootElement.GetProperty("language").ValueKind);
    }

    [Fact]
    public async Task OrchestratorReusesRawCacheAcrossInstancesAndNormalizesForcedLanguage()
    {
        using var files = new SpeechFiles();
        var engine = new StubEngine();
        var first = new TranscriptionService([engine], dataRoot: files.Root);
        var request = files.Request(language: new LanguageChoice.Forced("eng"));
        request = request with { Audio = request.Audio with { TimelineStart = 0.5 } };
        var transcript = await first.TranscribeAsync(request, new CaptureProgress<TranscriptionProgress>(), TestContext.Current.CancellationToken);
        var second = await new TranscriptionService([engine], dataRoot: files.Root)
            .TranscribeAsync(request, new CaptureProgress<TranscriptionProgress>(), TestContext.Current.CancellationToken);
        Assert.Equal(1, engine.Calls);
        Assert.Equal("en", engine.LastLanguage);
        Assert.Equal(transcript.RawKey, second.RawKey);
        Assert.Equal(0.6, Assert.Single(second.Words).Start);
        var cache = Assert.Single(Directory.EnumerateFiles(Path.Combine(files.Root, "Cache"), "*.json", SearchOption.AllDirectories));
        await VoxClip.Core.Tests.Tracks.WinCoreNative.TextOutputTests.AssertFileAsync(cache);
        using var raw = JsonDocument.Parse(await File.ReadAllTextAsync(cache, TestContext.Current.CancellationToken));
        Assert.Equal(0.1, raw.RootElement.GetProperty("raw").GetProperty("tokens")[0].GetProperty("start").GetDouble());
        Assert.Equal(JsonValueKind.Null, raw.RootElement.GetProperty("providerResponse").ValueKind);
        await File.WriteAllTextAsync(cache, "{invalid", TestContext.Current.CancellationToken);
        await first.TranscribeAsync(request, new CaptureProgress<TranscriptionProgress>(), TestContext.Current.CancellationToken);
        Assert.Equal(2, engine.Calls);
    }

    [Fact]
    public async Task RealElevenLabsAdapterCachesProviderJsonAndSecondImportMakesNoPaidCall()
    {
        using var files = new SpeechFiles();
        using var handler = new StubHttp((_, _) => Task.FromResult(StubHttp.Json(ElevenLabsTests.Response)));
        var engine = ElevenLabsTranscriber.ForTesting(new TestKeys(), handler, region: ElevenLabsRegion.Default);
        var service = new TranscriptionService([engine], dataRoot: files.Root);
        var fresh = await service.TranscribeAsync(files.Request(), new CaptureProgress<TranscriptionProgress>(), TestContext.Current.CancellationToken);
        var cached = await service.TranscribeAsync(files.Request(), new CaptureProgress<TranscriptionProgress>(), TestContext.Current.CancellationToken);
        Assert.False(fresh.FromCache);
        Assert.True(cached.FromCache);
        Assert.DoesNotContain("fromCache", JsonSerializer.Serialize(cached, ProjectJsonContext.Default.Transcript));
        Assert.Equal(1, handler.Calls);
        using var cache = JsonDocument.Parse(await File.ReadAllTextAsync(Assert.Single(Directory.EnumerateFiles(Path.Combine(files.Root, "Cache"), "*.json", SearchOption.AllDirectories)), TestContext.Current.CancellationToken));
        Assert.Equal("est", cache.RootElement.GetProperty("providerResponse").GetProperty("language_code").GetString());
    }

    [Fact]
    public async Task ProgressIsThrottledAndEndsWithAlignmentCompletion()
    {
        var ticks = new List<long>();
        var progress = new CaptureProgress<int>(_ => ticks.Add(Stopwatch.GetTimestamp()));
        var throttled = new SpeechProgress<int>(progress);
        for (var index = 0; index < 100; index++) throttled.Report(index);
        await throttled.CompleteAsync(100, TestContext.Current.CancellationToken);
        Assert.Equal(new[] { 0, 100 }, progress.Values);
        Assert.True(Stopwatch.GetElapsedTime(ticks[0], ticks[1]).TotalMilliseconds >= 95);
    }

    [Theory]
    [InlineData(TranscriptionStage.Uploading, TranscriptEngine.Elevenlabs, 0, 0.10)]
    [InlineData(TranscriptionStage.Uploading, TranscriptEngine.Elevenlabs, 0.5, 0.30)]
    [InlineData(TranscriptionStage.Uploading, TranscriptEngine.Elevenlabs, 1, 0.50)]
    [InlineData(TranscriptionStage.Transcribing, TranscriptEngine.Whispercpp, 0, 0.10)]
    [InlineData(TranscriptionStage.Transcribing, TranscriptEngine.Whispercpp, 0.5, 0.525)]
    [InlineData(TranscriptionStage.Transcribing, TranscriptEngine.Whispercpp, 1, 0.95)]
    [InlineData(TranscriptionStage.Aligning, TranscriptEngine.Elevenlabs, 0, 0.95)]
    [InlineData(TranscriptionStage.Aligning, TranscriptEngine.Elevenlabs, 1, 1.00)]
    [InlineData(TranscriptionStage.Uploading, TranscriptEngine.Elevenlabs, -1, 0.10)]
    [InlineData(TranscriptionStage.Uploading, TranscriptEngine.Elevenlabs, 2, 0.50)]
    [InlineData(TranscriptionStage.Preparing, TranscriptEngine.Whispercpp, 0.5, 0.50)]
    public void ImportProgressUsesSpecRanges(TranscriptionStage stage, TranscriptEngine engine, double fraction, double expected)
    {
        Assert.Equal(expected, ImportProgress.Overall(stage, engine, fraction)!.Value, 12);
    }

    [Fact]
    public async Task CloudImportCompletesStageLocalUploadBeforeIndeterminateTranscription()
    {
        using var files = new SpeechFiles();
        var captured = new CaptureProgress<TranscriptionProgress>();
        using var handler = new StubHttp(async (request, ct) =>
        {
            await request.Content!.CopyToAsync(Stream.Null, ct);
            Assert.Equal(new(TranscriptionStage.Uploading, 1), captured.Values[^2]);
            Assert.Equal(new(TranscriptionStage.Transcribing, null), captured.Values[^1]);
            return StubHttp.Json(ElevenLabsTests.Response);
        });
        var service = new TranscriptionService([ElevenLabsTranscriber.ForTesting(new TestKeys(), handler, region: ElevenLabsRegion.Default)], dataRoot: files.Root);
        await service.TranscribeAsync(files.Request(), captured, TestContext.Current.CancellationToken);
        Assert.Contains(new(TranscriptionStage.Uploading, 0), captured.Values);
        Assert.Contains(new(TranscriptionStage.Aligning, 0), captured.Values);
        Assert.Equal(new(TranscriptionStage.Aligning, 1), captured.Values[^1]);
        Assert.Equal((0.50, 0.95), ImportProgress.Range(TranscriptionStage.Transcribing, TranscriptEngine.Elevenlabs));
        Assert.Null(ImportProgress.Overall(TranscriptionStage.Transcribing, TranscriptEngine.Elevenlabs, null));
        Assert.Null(ImportProgress.Overall(TranscriptionStage.Transcribing, TranscriptEngine.Elevenlabs, double.NaN));
    }

    [Fact]
    public async Task CompletePaidResultIsCachedBeforeHonoringCancellation()
    {
        using var files = new SpeechFiles();
        using var cancel = new CancellationTokenSource();
        var engine = new StubEngine(cancel.Cancel);
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => new TranscriptionService([engine], dataRoot: files.Root)
            .TranscribeAsync(files.Request(), new CaptureProgress<TranscriptionProgress>(), cancel.Token));
        Assert.Single(Directory.EnumerateFiles(Path.Combine(files.Root, "Cache"), "*.json", SearchOption.AllDirectories));
        var reused = await new TranscriptionService([engine], dataRoot: files.Root)
            .TranscribeAsync(files.Request(), new CaptureProgress<TranscriptionProgress>(), TestContext.Current.CancellationToken);
        Assert.True(reused.FromCache);
        Assert.Equal(1, engine.Calls);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task UnavailableEngineUsesExactTranscriptionFailureCopy(bool missingAdapter)
    {
        using var files = new SpeechFiles();
        var engine = new StubEngine(readiness: new Readiness.Unavailable("Unavailable."));
        var service = new TranscriptionService(missingAdapter ? [] : [engine], dataRoot: files.Root);
        var error = await Assert.ThrowsAsync<VoxClipException>(() => service.TranscribeAsync(files.Request(),
            new CaptureProgress<TranscriptionProgress>(), TestContext.Current.CancellationToken));
        Assert.Equal(VoxClipErrorCode.TranscriptionFailed, error.Code);
        Assert.Equal("Transcription stopped: this transcription engine is unavailable. Your video is still here.", error.Message);
        Assert.Equal(0, engine.Calls);
    }

    [Theory]
    [InlineData("{\"language_code\":\"en\",\"words\":[]}", VoxClipErrorCode.NoSpeech)]
    [InlineData("{\"language_code\":\"en\",\"words\":[{\"text\":\"(laughs)\",\"type\":\"audio_event\",\"start\":0,\"end\":1}]}", VoxClipErrorCode.NoSpeech)]
    [InlineData("{\"language_code\":\"en\",\"words\":[4]}", VoxClipErrorCode.ProviderError)]
    [InlineData("{\"transcripts\":[]}", VoxClipErrorCode.ProviderError)]
    public async Task PaidResponseIsDurableBeforeMappingAndNeverRebilled(string response, VoxClipErrorCode code)
    {
        using var files = new SpeechFiles();
        using var handler = new StubHttp((_, _) => Task.FromResult(StubHttp.Json(response)));
        var engine = ElevenLabsTranscriber.ForTesting(new TestKeys(), handler, region: ElevenLabsRegion.Default);
        for (var attempt = 0; attempt < 2; attempt++)
        {
            var service = new TranscriptionService([engine], dataRoot: files.Root);
            var error = await Assert.ThrowsAsync<VoxClipException>(() => service.TranscribeAsync(files.Request(),
                new CaptureProgress<TranscriptionProgress>(), TestContext.Current.CancellationToken));
            Assert.Equal(code, error.Code);
        }
        Assert.Equal(1, handler.Calls);
        var path = Assert.Single(Directory.EnumerateFiles(Path.Combine(files.Root, "Cache"), "*.json", SearchOption.AllDirectories));
        using var cache = JsonDocument.Parse(await File.ReadAllTextAsync(path, TestContext.Current.CancellationToken));
        Assert.True(cache.RootElement.TryGetProperty("providerResponse", out var saved));
        Assert.Equal(JsonNode.Parse(response)!.ToJsonString(), JsonNode.Parse(saved.GetRawText())!.ToJsonString());
    }

    [Theory]
    [InlineData(TranscriptEngine.Elevenlabs, 2)]
    [InlineData(TranscriptEngine.Whispercpp, 1)]
    public async Task AppWideQueuesBoundCloudAndLocalConcurrency(TranscriptEngine engineId, int expectedParallelism)
    {
        using var files = new SpeechFiles();
        var engine = new QueueEngine(engineId);
        var jobs = Enumerable.Range(0, 4).Select(index =>
        {
            var request = files.Request();
            request = request with { ContentKey = new string((char)('a' + index), 64),
                Plan = request.Plan with { Engine = engineId, Model = engineId == TranscriptEngine.Whispercpp ? "whisper-base.en-q5_1" : null } };
            return new TranscriptionService([engine], dataRoot: files.Root).TranscribeAsync(request,
                new CaptureProgress<TranscriptionProgress>(), TestContext.Current.CancellationToken);
        });
        await Task.WhenAll(jobs);
        Assert.Equal(expectedParallelism, engine.Maximum);
    }

    private sealed class InstalledOnly(string[] ids) : IModelDownloader
    {
        public Task<IReadOnlyList<InstalledModel>> ListInstalledAsync(CancellationToken ct) => Task.FromResult<IReadOnlyList<InstalledModel>>(ids.Select(id => new InstalledModel(id, "unused", true, null)).ToArray());
        public Task<InstalledModel> InstallAsync(string id, IProgress<ModelDownloadProgress>? progress, CancellationToken ct) => throw new NotSupportedException();
        public Task<bool> VerifyAsync(string id, IProgress<ModelDownloadProgress>? progress, CancellationToken ct) => Task.FromResult(true);
        public Task RemoveAsync(string id, CancellationToken ct) => throw new NotSupportedException();
    }

    private sealed class StubEngine(Action? onCall = null, Readiness? readiness = null) : ITranscriber
    {
        internal int Calls { get; private set; }
        internal string? LastLanguage { get; private set; }
        public TranscriptEngine Engine => TranscriptEngine.Elevenlabs;
        public TranscriberCapabilities Capabilities(string? model) => new(TimingSource.Native, true, true, null, null, false);
        public Task<bool> SupportsAsync(LanguageChoice language, string? model, CancellationToken ct) => Task.FromResult(true);
        public Task<Readiness> ReadinessAsync(TranscriptionPlan plan, CancellationToken ct) => Task.FromResult<Readiness>(readiness ?? new Readiness.Ready());
        public Task PrepareAsync(TranscriptionPlan plan, IProgress<double>? progress, CancellationToken ct) => Task.CompletedTask;
        public Task<RawTranscript> TranscribeAsync(TranscriptionRequest request, IProgress<TranscriptionProgress> progress, CancellationToken ct)
        {
            Calls++;
            onCall?.Invoke();
            LastLanguage = (request.Plan.Language as LanguageChoice.Forced)?.Code;
            return Task.FromResult(new RawTranscript(new(Engine, "scribe_v2", null, "scribe_v2", null), 1,
                new(GroupingEnd.LastToken, GroupingConfidence.Single, false), [new("hello", false, 0.1, 0.4, 0.9, null, null, 0)],
                LastLanguage ?? "en", null, true, TimingSource.Native, null));
        }
    }

    private sealed class QueueEngine(TranscriptEngine engine) : ITranscriber
    {
        private int active;
        internal int Maximum { get; private set; }
        public TranscriptEngine Engine => engine;
        public TranscriberCapabilities Capabilities(string? model) => new(TimingSource.Native, true, true, null, null, Engine == TranscriptEngine.Whispercpp);
        public Task<bool> SupportsAsync(LanguageChoice language, string? model, CancellationToken ct) => Task.FromResult(true);
        public Task<Readiness> ReadinessAsync(TranscriptionPlan plan, CancellationToken ct) => Task.FromResult<Readiness>(new Readiness.Ready());
        public Task PrepareAsync(TranscriptionPlan plan, IProgress<double>? progress, CancellationToken ct) => Task.CompletedTask;
        public async Task<RawTranscript> TranscribeAsync(TranscriptionRequest request, IProgress<TranscriptionProgress> progress, CancellationToken ct)
        {
            var current = Interlocked.Increment(ref active);
            lock (this) Maximum = Math.Max(Maximum, current);
            try
            {
                await Task.Delay(120, ct);
                return new(new(Engine, request.Plan.Model, null, "test-engine", null), 1, new(GroupingEnd.LastToken, GroupingConfidence.Single, false),
                    [new("hello", false, 0.1, 0.4, null, null, null, 0)], "en", null, true, TimingSource.Native, null);
            }
            finally { Interlocked.Decrement(ref active); }
        }
    }
}
