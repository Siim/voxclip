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

    /// <summary>Seven services share private queues: one local and two cloud jobs run together, the others wait, and
    /// each finished job lets exactly one waiter of its kind in (transcription §13.4). Jobs stay in their engines until
    /// the test finishes them, so no step races a clock, and parallel test classes cannot take the slots.</summary>
    [Fact(Timeout = 60_000)]
    public async Task AppWideQueuesBoundCloudAndLocalConcurrency()
    {
        using var files = new SpeechFiles();
        var queues = new SpeechJobQueues();
        var held = new HeldJobs();
        var ct = TestContext.Current.CancellationToken;
        var keys = Enumerable.Range(0, 7).Select(index => new string((char)('0' + index), 64)).ToArray();
        static bool IsLocal(string key) => key[0] < '3';
        var jobs = keys.Select(key => StartHeldJob(files, queues, held, key, IsLocal(key), ct)).ToArray();
        var left = keys.ToHashSet();
        while (left.Count > 0)
        {
            // Settled: finished jobs have left, each kind runs as many jobs as its limit and the remaining jobs allow,
            // only those hold slots, and every other job waits in its kind's queue.
            var (localLeft, cloudLeft) = (left.Count(IsLocal), left.Count(key => !IsLocal(key)));
            string[] running = [];
            await Until(() =>
            {
                running = held.Running;
                var (local, cloud) = (running.Count(IsLocal), running.Count(key => !IsLocal(key)));
                return running.All(left.Contains) && local == Math.Min(1, localLeft) && cloud == Math.Min(2, cloudLeft) &&
                    queues.Running == (local, cloud) && queues.Waiting == (localLeft - local, cloudLeft - cloud);
            }, ct, jobs);
            left.Remove(running[0]);
            held.Finish(running[0]);
        }
        await Task.WhenAll(jobs);
        Assert.Equal((1, 2), (held.MaximumLocal, held.MaximumCloud));
        Assert.Equal(((0, 0), (0, 0)), (queues.Running, queues.Waiting));
        Assert.Same(SpeechJobQueues.Shared, new TranscriptionService([new StubEngine()], dataRoot: files.Root).Queues);
    }

    /// <summary>A local job queued for the local slot holds nothing else, so a cloud job for the same source reaches its
    /// engine at once; only an identical job waits for another (transcription §13.4).</summary>
    [Fact(Timeout = 60_000)]
    public async Task QueuedLocalJobLetsACloudJobForTheSameSourceRun()
    {
        using var files = new SpeechFiles();
        var queues = new SpeechJobQueues();
        var held = new HeldJobs();
        var ct = TestContext.Current.CancellationToken;
        string other = new('0', 64), source = new('a', 64);
        var first = StartHeldJob(files, queues, held, other, local: true, ct);
        await Until(() => held.Running.SequenceEqual([other]), ct, first);
        var queued = StartHeldJob(files, queues, held, source, local: true, ct);
        await Until(() => queues.Waiting == (1, 0), ct, first, queued);
        var cloud = StartHeldJob(files, queues, held, source, local: false, ct);
        await Until(() => held.Running.SequenceEqual([other, source]), ct, first, queued, cloud);
        Assert.Equal(((1, 1), (1, 0)), (queues.Running, queues.Waiting));
        held.Finish(source);
        await cloud;
        held.Finish(other);
        await first;
        await Until(() => held.Running.SequenceEqual([source]), ct, queued);
        held.Finish(source);
        await queued;
        Assert.Equal(((0, 0), (0, 0)), (queues.Running, queues.Waiting));
    }

    /// <summary>A runs locally on source 1 and B queues locally on source 2; then C (cloud, source 2) and D (cloud,
    /// source 3) ask in that order. C must not wait behind B while D, which asked later, runs (transcription §13.4).</summary>
    [Fact(Timeout = 60_000)]
    public async Task CloudJobForASourceWithAQueuedLocalJobRunsWithALaterOne()
    {
        using var files = new SpeechFiles();
        var queues = new SpeechJobQueues();
        var held = new HeldJobs();
        var ct = TestContext.Current.CancellationToken;
        string one = new('1', 64), two = new('2', 64), three = new('3', 64);
        var a = StartHeldJob(files, queues, held, one, local: true, ct);
        await Until(() => held.Running.SequenceEqual([one]), ct, a);
        var b = StartHeldJob(files, queues, held, two, local: true, ct);
        await Until(() => queues.Waiting == (1, 0), ct, a, b);
        var c = StartHeldJob(files, queues, held, two, local: false, ct);
        var d = StartHeldJob(files, queues, held, three, local: false, ct);
        await Until(() => held.Running.Order(StringComparer.Ordinal).SequenceEqual([one, two, three]), ct, a, b, c, d);
        Assert.Equal((1, 0), queues.Waiting);
        Assert.False(b.IsCompleted);
        held.Finish(two);
        await c;
        held.Finish(three);
        await d;
        held.Finish(one);
        await a;
        await Until(() => held.Running.SequenceEqual([two]), ct, b);
        held.Finish(two);
        await b;
        Assert.Equal(((0, 0), (0, 0)), (queues.Running, queues.Waiting));
    }

    /// <summary>A release goes to the oldest waiter, never to a later caller (transcription §13.4).</summary>
    [Fact(Timeout = 60_000)]
    public async Task AppWideQueuesHandEachReleaseToTheOldestWaiter()
    {
        var queues = new SpeechJobQueues();
        var ct = TestContext.Current.CancellationToken;
        await queues.EnterAsync(true, "running", ct);
        var first = queues.EnterAsync(true, "first", ct);
        var second = queues.EnterAsync(true, "second", ct);
        queues.Release(true, "running");
        await first;
        var later = queues.EnterAsync(true, "later", ct);
        Assert.False(second.IsCompleted);
        queues.Release(true, "first");
        await second;
        Assert.False(later.IsCompleted);
        queues.Release(true, "second");
        await later;
        queues.Release(true, "later");
        Assert.Equal(((0, 0), (0, 0)), (queues.Running, queues.Waiting));
    }

    /// <summary>A release passes over a waiter whose identical job still runs and keeps the arrival order of the rest;
    /// once the identical job ends, its duplicate is the oldest waiter that can start (transcription §13.4).</summary>
    [Fact(Timeout = 60_000)]
    public async Task AppWideQueuesSkipAWaiterWhoseIdenticalJobRuns()
    {
        var queues = new SpeechJobQueues();
        var ct = TestContext.Current.CancellationToken;
        await queues.EnterAsync(false, "a", ct);
        await queues.EnterAsync(false, "b", ct);
        var duplicate = queues.EnterAsync(false, "a", ct);
        var first = queues.EnterAsync(false, "c", ct);
        var second = queues.EnterAsync(false, "d", ct);
        Assert.Equal(((0, 2), (0, 3)), (queues.Running, queues.Waiting));
        // "b" ends while "a" still runs: its place passes over the duplicate to the oldest job that can start.
        queues.Release(false, "b");
        Assert.Same(first, await Task.WhenAny(duplicate, first, second));
        var later = queues.EnterAsync(false, "e", ct);
        // Once "a" ends, its duplicate is the oldest job that can start, and a later caller never goes first.
        queues.Release(false, "a");
        Assert.Same(duplicate, await Task.WhenAny(duplicate, second, later));
        queues.Release(false, "c");
        Assert.Same(second, await Task.WhenAny(second, later));
        queues.Release(false, "a");
        await later;
        queues.Release(false, "d");
        queues.Release(false, "e");
        Assert.Equal(((0, 0), (0, 0)), (queues.Running, queues.Waiting));
    }

    /// <summary>A cancelled caller leaves the queue holding nothing, and a slot handed over just before a cancellation
    /// stays with its job until the job gives it back (transcription §13.2 and §13.4).</summary>
    [Fact(Timeout = 60_000)]
    public async Task AppWideQueuesDropACancelledWaiter()
    {
        var queues = new SpeechJobQueues();
        var ct = TestContext.Current.CancellationToken;
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => queues.EnterAsync(true, "early", new CancellationToken(canceled: true)));
        await queues.EnterAsync(true, "running", ct);
        using var dropped = CancellationTokenSource.CreateLinkedTokenSource(ct);
        using var kept = CancellationTokenSource.CreateLinkedTokenSource(ct);
        var cancelled = queues.EnterAsync(true, "cancelled", dropped.Token);
        var granted = queues.EnterAsync(true, "granted", kept.Token);
        Assert.Equal(((1, 0), (2, 0)), (queues.Running, queues.Waiting));
        await dropped.CancelAsync();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => cancelled);
        Assert.Equal(((1, 0), (1, 0)), (queues.Running, queues.Waiting));
        // The release hands the slot over before the cancellation arrives, so the slot stays with its job.
        queues.Release(true, "running");
        await kept.CancelAsync();
        await granted;
        Assert.Equal(((1, 0), (0, 0)), (queues.Running, queues.Waiting));
        queues.Release(true, "granted");
        Assert.Equal(((0, 0), (0, 0)), (queues.Running, queues.Waiting));
    }

    /// <summary>The review's first order, on the two cloud slots: L0 and K0 run, then J1, its identical J2 and J3 queue.
    /// L0 ends and J1 starts; K0 ends while J1 runs, so J2 keeps waiting and J3 starts; J4 queues. J1 is cancelled
    /// after it started, and J2 takes its place before J4, which asked later (transcription §13.4).</summary>
    [Fact(Timeout = 60_000)]
    public async Task QueuedDuplicateTakesThePlaceOfItsCancelledTwin()
    {
        using var files = new SpeechFiles();
        var queues = new SpeechJobQueues();
        var held = new HeldJobs();
        var ct = TestContext.Current.CancellationToken;
        using var cancel = CancellationTokenSource.CreateLinkedTokenSource(ct);
        string l0 = new('0', 64), k0 = new('1', 64), twin = new('a', 64), j3 = new('b', 64), j4 = new('c', 64);
        var first = StartHeldJob(files, queues, held, l0, local: false, ct);
        await Until(() => held.Running.SequenceEqual([l0]), ct, first);
        var second = StartHeldJob(files, queues, held, k0, local: false, ct);
        await Until(() => held.Running.Length == 2, ct, first, second);
        var j1 = StartHeldJob(files, queues, held, twin, local: false, cancel.Token);
        await Until(() => queues.Waiting == (0, 1), ct, first, second, j1);
        var j2 = StartHeldJob(files, queues, held, twin, local: false, ct);
        await Until(() => queues.Waiting == (0, 2), ct, first, second, j1, j2);
        var third = StartHeldJob(files, queues, held, j3, local: false, ct);
        await Until(() => queues.Waiting == (0, 3), ct, first, second, j1, j2, third);
        held.Finish(l0);
        await first;
        await Until(() => held.Running.Length == 2, ct, second, j1, j2, third);
        Assert.Equal([k0, twin], held.Running);
        held.Finish(k0);
        await second;
        await Until(() => held.Running.Length == 2, ct, j1, j2, third);
        Assert.Equal([twin, j3], held.Running);
        var fourth = StartHeldJob(files, queues, held, j4, local: false, ct);
        await Until(() => queues.Waiting == (0, 2), ct, j1, j2, third, fourth);
        await cancel.CancelAsync();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => j1);
        await Until(() => held.Running.Length == 2, ct, j2, third, fourth);
        Assert.Equal([j3, twin], held.Running);
        held.Finish(j3);
        await third;
        await Until(() => held.Running.Length == 2, ct, j2, fourth);
        held.Finish(twin);
        held.Finish(j4);
        await Task.WhenAll(j2, fourth);
        Assert.Equal([l0, k0, twin, j3, twin, j4], held.Started);
        Assert.Equal(((0, 0), (0, 0)), (queues.Running, queues.Waiting));
    }

    /// <summary>The review's second order, on the two cloud slots: A and B run, then A's identical C, D and E queue. B
    /// ends while A runs, so C keeps waiting and D starts. A is then cancelled, or its engine fails, without leaving a
    /// cache entry: C takes its place before E, which asked later, and E starts when D ends (transcription §13.4).</summary>
    [Theory(Timeout = 60_000)]
    [InlineData(false)]
    [InlineData(true)]
    public async Task DuplicateRunsBeforeALaterJobWhenItsTwinEndsWithoutAnEntry(bool engineFails)
    {
        using var files = new SpeechFiles();
        var queues = new SpeechJobQueues();
        var held = new HeldJobs();
        var ct = TestContext.Current.CancellationToken;
        using var cancel = CancellationTokenSource.CreateLinkedTokenSource(ct);
        string one = new('1', 64), nine = new('9', 64), two = new('2', 64), three = new('3', 64);
        var a = StartHeldJob(files, queues, held, one, local: false, cancel.Token);
        await Until(() => held.Running.SequenceEqual([one]), ct, a);
        var b = StartHeldJob(files, queues, held, nine, local: false, ct);
        await Until(() => held.Running.Length == 2, ct, a, b);
        var c = StartHeldJob(files, queues, held, one, local: false, ct);
        await Until(() => queues.Waiting == (0, 1), ct, a, b, c);
        var d = StartHeldJob(files, queues, held, two, local: false, ct);
        await Until(() => queues.Waiting == (0, 2), ct, a, b, c, d);
        var e = StartHeldJob(files, queues, held, three, local: false, ct);
        await Until(() => queues.Waiting == (0, 3), ct, a, b, c, d, e);
        held.Finish(nine);
        await b;
        await Until(() => held.Running.Length == 2, ct, a, c, d, e);
        Assert.Equal([one, two], held.Running);
        if (engineFails)
        {
            held.Fail(one);
            await Assert.ThrowsAsync<InvalidOperationException>(() => a);
        }
        else
        {
            await cancel.CancelAsync();
            await Assert.ThrowsAnyAsync<OperationCanceledException>(() => a);
        }
        await Until(() => held.Running.Length == 2, ct, c, d, e);
        Assert.Equal([two, one], held.Running);
        held.Finish(two);
        await d;
        await Until(() => held.Running.Length == 2, ct, c, e);
        held.Finish(one);
        held.Finish(three);
        await Task.WhenAll(c, e);
        Assert.Equal([one, nine, two, one, three], held.Started);
        Assert.Equal(((0, 0), (0, 0)), (queues.Running, queues.Waiting));
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

    /// <summary>Starts a whisper or ElevenLabs job for <paramref name="key"/> on its own service, as another project
    /// would, sharing the test's private queues.</summary>
    private static Task<Transcript> StartHeldJob(SpeechFiles files, SpeechJobQueues queues, HeldJobs held, string key, bool local, CancellationToken ct)
    {
        var request = files.Request();
        request = request with { ContentKey = key, Plan = request.Plan with
        {
            Engine = local ? TranscriptEngine.Whispercpp : TranscriptEngine.Elevenlabs, Model = local ? "whisper-base.en-q5_1" : null
        } };
        ITranscriber[] engines = [new HeldEngine(TranscriptEngine.Whispercpp, held), new HeldEngine(TranscriptEngine.Elevenlabs, held)];
        return new TranscriptionService(engines, queues, dataRoot: files.Root).TranscribeAsync(request, new CaptureProgress<TranscriptionProgress>(), ct);
    }

    /// <summary>Waits for the condition with no deadline of its own (the test's timeout bounds it) and fails at once
    /// when a job faults.</summary>
    private static async Task Until(Func<bool> condition, CancellationToken ct, params Task[] jobs)
    {
        while (true)
        {
            if (jobs.FirstOrDefault(job => job.IsFaulted) is { } failed) await failed;
            if (condition()) return;
            await Task.Delay(1, ct);
        }
    }

    /// <summary>Jobs inside the engines by content key, oldest first; each stays until the test finishes or fails it.
    /// Two identical jobs (same kind and source) inside at once would break transcription §13.4, so the second one
    /// fails at once and the test with it.</summary>
    private sealed class HeldJobs
    {
        private readonly List<string> running = [], started = [];
        private readonly HashSet<(bool, string)> inside = [];
        private readonly Dictionary<string, TaskCompletionSource> gates = [];
        private int local, cloud;
        internal int MaximumLocal { get; private set; }
        internal int MaximumCloud { get; private set; }
        internal string[] Running { get { lock (running) return [.. running]; } }
        /// <summary>Every job that reached an engine, in order.</summary>
        internal string[] Started { get { lock (running) return [.. started]; } }
        internal Task Enter(bool isLocal, string key)
        {
            lock (running)
            {
                if (!inside.Add((isLocal, key))) throw new InvalidOperationException("Two identical jobs ran at once for " + key);
                running.Add(key);
                started.Add(key);
                if (isLocal) MaximumLocal = Math.Max(MaximumLocal, ++local); else MaximumCloud = Math.Max(MaximumCloud, ++cloud);
                return (gates[key] = new(TaskCreationOptions.RunContinuationsAsynchronously)).Task;
            }
        }
        internal void Leave(bool isLocal, string key)
        {
            lock (running) { running.Remove(key); inside.Remove((isLocal, key)); if (isLocal) local--; else cloud--; }
        }
        internal void Finish(string key) => Gate(key).SetResult();
        internal void Fail(string key) => Gate(key).SetException(new InvalidOperationException("Synthetic engine failure"));
        private TaskCompletionSource Gate(string key) { lock (running) return gates[key]; }
    }

    private sealed class HeldEngine(TranscriptEngine engine, HeldJobs held) : ITranscriber
    {
        public TranscriptEngine Engine => engine;
        public TranscriberCapabilities Capabilities(string? model) => new(TimingSource.Native, true, true, null, null, Engine == TranscriptEngine.Whispercpp);
        public Task<bool> SupportsAsync(LanguageChoice language, string? model, CancellationToken ct) => Task.FromResult(true);
        public Task<Readiness> ReadinessAsync(TranscriptionPlan plan, CancellationToken ct) => Task.FromResult<Readiness>(new Readiness.Ready());
        public Task PrepareAsync(TranscriptionPlan plan, IProgress<double>? progress, CancellationToken ct) => Task.CompletedTask;
        public async Task<RawTranscript> TranscribeAsync(TranscriptionRequest request, IProgress<TranscriptionProgress> progress, CancellationToken ct)
        {
            var isLocal = Engine == TranscriptEngine.Whispercpp;
            var entered = held.Enter(isLocal, request.ContentKey);
            try
            {
                await entered.WaitAsync(ct);
                return new(new(Engine, request.Plan.Model, null, "test-engine", null), 1, new(GroupingEnd.LastToken, GroupingConfidence.Single, false),
                    [new("hello", false, 0.1, 0.4, null, null, null, 0)], "en", null, true, TimingSource.Native, null);
            }
            finally { held.Leave(isLocal, request.ContentKey); }
        }
    }
}
