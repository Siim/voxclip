using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Services.Logging;
using VoxClip.Core.Services.Models;
using VoxClip.Core.Services.Project;
using VoxClip.Media.Speech;
using Whisper.net;
using Xunit;

namespace VoxClip.Media.Tests.Speech;

public sealed class WhisperTests(ITestOutputHelper output)
{
    [Theory]
    [InlineData("../en", "whisper-base.en-q5_1")]
    [InlineData("en/x", "whisper-base.en-q5_1")]
    [InlineData("english", "whisper-base.en-q5_1")]
    [InlineData("en\n", "whisper-base.en-q5_1")]
    [InlineData("en", "../private-model")]
    [InlineData("en", "whisper/private-model")]
    [InlineData("en", "private-model\n")]
    [InlineData("en", "")]
    public async Task InvalidIdentifiersUseFixedCopyBeforeReadinessOrNativeWork(string language, string model)
    {
        using var files = new WaveFiles();
        await using var engine = new WhisperNetTranscriber(new ModelCatalog(), dataRoot: files.Root);
        var request = new TranscriptionRequest(new(TranscriptEngine.Whispercpp, model, new LanguageChoice.Forced(language), new()),
            new(files.Wav, 16000, 0, 0, 0), new string('a', 64));
        var service = new Core.Services.Speech.TranscriptionService([engine], dataRoot: files.Root);
        var direct = await Assert.ThrowsAsync<VoxClipException>(() => engine.TranscribeAsync(request,
            new Progress<TranscriptionProgress>(), TestContext.Current.CancellationToken));
        var orchestrated = await Assert.ThrowsAsync<VoxClipException>(() => service.TranscribeAsync(request, null, null, TestContext.Current.CancellationToken));
        foreach (var error in new[] { direct, orchestrated })
        {
            Assert.Equal(VoxClipErrorCode.TranscriptionLanguageUnsupported, error.Code);
            Assert.Equal("Whisper can't transcribe the selected model or language identifier.", error.Message);
        }
        Assert.False(Directory.Exists(Path.Combine(files.Root, "Cache")));
    }

    [Fact]
    public void CompositionConstructorMatchesW5() =>
        Assert.NotNull(typeof(WhisperNetTranscriber).GetConstructor([typeof(IModelDownloader)]));

    [Theory]
    [InlineData("jw", "jv")]
    [InlineData("eng", "en")]
    [InlineData("cmn", "zh")]
    [InlineData("xyz", "xyz")]
    public async Task DetectedWhisperAliasesBecomeBcp47LanguageCodes(string detected, string expected)
    {
        using var files = new WaveFiles();
        await using var engine = new WhisperNetTranscriber(new ModelCatalog(), dataRoot: files.Root);
        Assert.Equal(expected, await engine.NormalizeDetectedLanguageAsync(detected, TestContext.Current.CancellationToken));
    }

    [Theory]
    [InlineData("et")]
    [InlineData("est")]
    public async Task DetectedEstonianOnTurboReroutesBeforeAnyDecode(string detected)
    {
        using var files = new WaveFiles();
        await using var engine = new WhisperNetTranscriber(new ModelCatalog(), dataRoot: files.Root);
        var plan = new TranscriptionPlan(TranscriptEngine.Whispercpp, "whisper-large-v3-turbo-q5_0", new LanguageChoice.Auto(), new());
        var decoded = false;
        var error = await Assert.ThrowsAsync<VoxClipException>(() => engine.WithRoutedLanguageAsync(plan, null,
            () => Task.FromResult<(string?, double)>((detected, 0.5)), (language, _) => { decoded = true; return Task.FromResult(language); },
            TestContext.Current.CancellationToken));
        Assert.False(decoded);
        Assert.Equal(VoxClipErrorCode.TranscriptionLanguageUnsupported, error.Code);
        Assert.Equal("Whisper can't transcribe et.", error.Message);
    }

    [Theory]
    [InlineData("en")]
    [InlineData("de")]
    public async Task DetectedTurboLanguagesReachDecode(string detected)
    {
        using var files = new WaveFiles();
        await using var engine = new WhisperNetTranscriber(new ModelCatalog(), dataRoot: files.Root);
        var plan = new TranscriptionPlan(TranscriptEngine.Whispercpp, "whisper-large-v3-turbo-q5_0", new LanguageChoice.Auto(), new());
        var decoded = false;
        var result = await engine.WithRoutedLanguageAsync(plan, null, () => Task.FromResult<(string?, double)>((detected, 0.8)),
            (language, probability) =>
            {
                decoded = true;
                Assert.Equal(0.8, probability);
                return Task.FromResult(language);
            }, TestContext.Current.CancellationToken);
        Assert.True(decoded);
        Assert.Equal(detected, result);
    }

    [Theory]
    [InlineData(null, 0.9)]
    [InlineData("", 0.9)]
    [InlineData("en", 0.49)]
    [InlineData("en", double.NaN)]
    public void FailedDetectionAsksForTheSpokenLanguage(string? language, double probability)
    {
        var error = Assert.Throws<VoxClipException>(() => WhisperNetTranscriber.RequireDetectedLanguage(language, probability));
        Assert.Equal(VoxClipErrorCode.TranscriptionLanguageUnsupported, error.Code);
        Assert.Equal("Which language is spoken?", error.Message);
        Assert.Equal("en", WhisperNetTranscriber.RequireDetectedLanguage("en", 0.5));
    }

    [Fact]
    public async Task AutoOnANonDetectionModelAsksForLanguageWithoutLoadingNativeCode()
    {
        using var files = new WaveFiles();
        await using var engine = new WhisperNetTranscriber(new ModelCatalog(), dataRoot: files.Root);
        var request = new TranscriptionRequest(new(TranscriptEngine.Whispercpp, "whisper-base.en-q5_1", new LanguageChoice.Auto(), new()),
            new(files.Wav, 16000, 1, 0, 0), new string('a', 64));
        var direct = await Assert.ThrowsAsync<VoxClipException>(() => engine.TranscribeAsync(request, new Progress<TranscriptionProgress>(), TestContext.Current.CancellationToken));
        var service = new VoxClip.Core.Services.Speech.TranscriptionService([engine], dataRoot: files.Root);
        var orchestrated = await Assert.ThrowsAsync<VoxClipException>(() => service.TranscribeAsync(request, null, null, TestContext.Current.CancellationToken));
        foreach (var error in new[] { direct, orchestrated })
        {
            Assert.Equal(VoxClipErrorCode.TranscriptionLanguageUnsupported, error.Code);
            Assert.Equal("Which language is spoken?", error.Message);
        }
        Assert.False(Directory.Exists(Path.Combine(files.Root, "Models")));
    }

    [Fact]
    public async Task DetectionBeforeRoutingRefusesWithoutLoadingNativeCode()
    {
        using var files = new WaveFiles();
        await using var engine = new WhisperNetTranscriber(new ModelCatalog(), dataRoot: files.Root);
        ExtractedAudio audio = new(files.Wav, 16000, 1, 0, 0);
        var key = new string('a', 64);
        var ct = TestContext.Current.CancellationToken;
        // Only an OpenAI multilingual model detects (transcription §9.8): a TalTech or English-only model asks for the language.
        var english = await Assert.ThrowsAsync<VoxClipException>(() => engine.DetectLanguageAsync(
            new(new(TranscriptEngine.Whispercpp, "whisper-base.en-q5_1", new LanguageChoice.Auto(), new()), audio, key), ct));
        Assert.Equal("Which language is spoken?", english.Message);
        var taltech = await Assert.ThrowsAsync<VoxClipException>(() => engine.DetectLanguageAsync(
            new(new(TranscriptEngine.Whispercpp, "taltech-et-verbatim-2604-q8_0", new LanguageChoice.Auto(), new()), audio, key), ct));
        Assert.Equal("Which language is spoken?", taltech.Message);
        // A missing turbo is a download, not a native load.
        var missing = await Assert.ThrowsAsync<VoxClipException>(() => engine.DetectLanguageAsync(
            new(new(TranscriptEngine.Whispercpp, "whisper-large-v3-turbo-q5_0", new LanguageChoice.Auto(), new()), audio, key), ct));
        Assert.Equal(VoxClipErrorCode.ModelMissing, missing.Code);
        Assert.StartsWith("Download the Multilingual · Whisper large-v3-turbo (Q5_0) model", missing.Message);
        // Detection never decodes a forced plan.
        await Assert.ThrowsAsync<ArgumentException>(() => engine.DetectLanguageAsync(
            new(new(TranscriptEngine.Whispercpp, "whisper-large-v3-turbo-q5_0", new LanguageChoice.Forced("en"), new()), audio, key), ct));
        Assert.False(Directory.Exists(Path.Combine(files.Root, "Models")));
    }

    public static bool ModelsEnabled => DownloadTestsEnabled(Environment.GetEnvironmentVariable("VOXCLIP_TEST_DOWNLOAD"), Environment.GetEnvironmentVariable("VOXCLIP_LIVE_TESTS"));
    internal static bool DownloadTestsEnabled(string? download, string? live) => download == "1" || live == "1";

    [Theory]
    [InlineData(null, null, false)]
    [InlineData("0", "0", false)]
    [InlineData("1", null, true)]
    [InlineData(null, "1", true)]
    [InlineData("0", "1", true)]
    [InlineData("1", "0", true)]
    public void EitherOptInSwitchEnablesTheModelSmoke(string? download, string? live, bool expected) =>
        Assert.Equal(expected, DownloadTestsEnabled(download, live));

    [Fact]
    public void RepairsSplitUtf8UsingSegmentTextWithoutMovingTiming()
    {
        var tokens = WhisperTokens.Map(Segment("õhtu täna", [Token(" \ufffd", 0, 10), Token("\ufffdhtu", 10, 20), Token(" täna", 25, 50)]),
            2, 3, 7, true, true, new Log());
        Assert.Equal(new[] { "õhtu", "", "täna" }, tokens.Select(token => token.Text));
        Assert.False(tokens[0].JoinsPrevious); Assert.True(tokens[1].JoinsPrevious);
        Assert.Equal(2.01, tokens[0].Start);
        Assert.Equal(2.2, tokens[1].End);
        Assert.All(tokens, token => Assert.Equal(7, token.Group));
        var words = WordAssembler.Group(tokens, new(GroupingEnd.NextWordStart, GroupingConfidence.Mean, true), 0);
        Assert.Equal("õhtu", words[0].Text);
        Assert.Equal(2.26, words[0].End);
    }

    [Fact]
    public void SkipsSpecialTokensAndUsesTokenTimestampsWhenDtwIsOff()
    {
        var source = new[] { Token("[_BEG_]", 0, 1), Token("<|en|>", 0, 1), Token("skip", 0, 1, id: 50257), Token(" hello", 20, 50) };
        var tokens = WhisperTokens.Map(Segment("hello", source), 1, 2, 0, false, true, new Log());
        var token = Assert.Single(tokens);
        Assert.Equal("hello", token.Text);
        Assert.Equal(1.2, token.Start);
        Assert.Equal(1.5, token.End);
    }

    [Fact]
    public void EnglishEotDiffersFromMultilingualAndTimesAreClamped()
    {
        var segment = Segment("hello", [Token("drop", 0, 1, id: 50256), Token(" hello", -10, 100, dtw: -1)]);
        var token = Assert.Single(WhisperTokens.Map(segment, 2, 2.5, 0, true, false, new Log()));
        Assert.Equal(2, token.Start);
        Assert.Equal(2.5, token.End);
    }

    [Fact]
    public void MismatchedUtf8RepairRemovesReplacementCharacters()
    {
        var token = Assert.Single(WhisperTokens.Map(Segment("two words", [Token("\ufffdone", 0, 30)]), 0, 1, 0, true, false, new Log()));
        Assert.Equal("one", token.Text);
    }

    [Fact]
    public void VadUnitsClampSortAndMergeTouchingRegions()
    {
        var units = WhisperAudio.MergeRegions([new(TimeSpan.FromSeconds(1), TimeSpan.FromSeconds(2)),
            new(TimeSpan.FromSeconds(-1), TimeSpan.FromSeconds(1)), new(TimeSpan.FromSeconds(3), TimeSpan.FromSeconds(5))], 4 * 16000);
        Assert.Equal(new[] { new SpeechUnit(0, 32000), new SpeechUnit(48000, 64000) }, units);
    }

    [Fact]
    public void NormalizationTargetsMinusTwentyDbAndPreservesSilence()
    {
        var samples = Enumerable.Repeat(0.01f, 1600).Concat(new float[1600]).ToArray();
        WhisperAudio.Normalize(samples, TestContext.Current.CancellationToken);
        Assert.Equal(0.1, samples[0], 6);
        Assert.Equal(0, samples[^1]);
        var silence = new float[1600];
        WhisperAudio.Normalize(silence, TestContext.Current.CancellationToken);
        Assert.All(silence, sample => Assert.Equal(0, sample));
    }

    [Fact]
    public async Task ReadsPcm16WavWithoutUsingMediaTrackExtractor()
    {
        using var files = new WaveFiles();
        WaveFiles.Write(files.Wav, [short.MinValue, 0, short.MaxValue]);
        var audio = WaveFiles.Describe(files.Wav);
        var samples = await WhisperAudio.ReadAsync(audio, TestContext.Current.CancellationToken);
        Assert.Equal(-1, samples[0]);
        Assert.Equal(0, samples[1]);
        Assert.Equal(32767 / 32768f, samples[2]);
    }

    [Fact]
    public async Task RejectsNonMonoOrWrongSampleCount()
    {
        using var files = new WaveFiles();
        WaveFiles.Write(files.Wav, [1, 2, 3]);
        var audio = WaveFiles.Describe(files.Wav);
        var error = await Assert.ThrowsAsync<VoxClipException>(() => WhisperAudio.ReadAsync(audio with { SampleCount = 5 }, TestContext.Current.CancellationToken));
        Assert.Equal(VoxClipErrorCode.DecodeFailed, error.Code);
        Assert.Equal("VoxClip couldn't decode this video: the extracted audio must be 16 kHz mono PCM16 WAV. Your edits are saved.", error.Message);
    }

    [Fact]
    public async Task ReadinessNeverLoadsNativeCodeOrDownloadsModels()
    {
        using var files = new WaveFiles();
        await using var engine = new WhisperNetTranscriber(new ModelCatalog(), dataRoot: files.Root);
        var plan = new TranscriptionPlan(TranscriptEngine.Whispercpp, "whisper-base.en-q5_1", new LanguageChoice.Forced("en"), new());
        Assert.True(await engine.SupportsAsync(plan.Language, plan.Model, TestContext.Current.CancellationToken));
        Assert.False(await engine.SupportsAsync(new LanguageChoice.Forced("et"), plan.Model, TestContext.Current.CancellationToken));
        Assert.False(await engine.SupportsAsync(new LanguageChoice.Auto(), plan.Model, TestContext.Current.CancellationToken));
        var missing = Assert.IsType<Readiness.NeedsModels>(await engine.ReadinessAsync(plan, TestContext.Current.CancellationToken));
        Assert.Equal(2, missing.Ids.Count);
        Assert.False(engine.Capabilities(plan.Model).Verbatim);
        Assert.False(Directory.Exists(Path.Combine(files.Root, "Models")));
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task NativeCancellationReturnsPromptlyButRetainsOwnershipUntilDrain(bool failAfterCancellation)
    {
        using var cancel = CancellationTokenSource.CreateLinkedTokenSource(TestContext.Current.CancellationToken);
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var finished = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var cleanupCount = 0;
        var native = NativeWork.RunAsync(async () =>
        {
            entered.SetResult();
            await release.Task;
            if (failAfterCancellation) throw new InvalidOperationException("Native work failed after the caller cancelled.");
            return 42;
        }, () => { Interlocked.Increment(ref cleanupCount); finished.SetResult(); }, cancel.Token);
        try
        {
            await entered.Task.WaitAsync(TimeSpan.FromSeconds(2), TestContext.Current.CancellationToken);
            var timer = Stopwatch.StartNew();
            cancel.Cancel();
            await Assert.ThrowsAnyAsync<OperationCanceledException>(() => native);
            Assert.True(timer.Elapsed.TotalSeconds < 1);
            Assert.False(finished.Task.IsCompleted);
        }
        finally
        {
            release.TrySetResult();
            await finished.Task.WaitAsync(TimeSpan.FromSeconds(2), TestContext.Current.CancellationToken);
        }
        Assert.Equal(1, cleanupCount);
    }

    [Fact]
    public async Task CapabilitiesHonorCatalogueDtwDefaultBeforeNativeLoading()
    {
        using var files = new WaveFiles();
        var data = JsonNode.Parse(await File.ReadAllTextAsync(Path.Combine(SharedResources.ResolveRoot(), "catalog", "transcription-models.json"), TestContext.Current.CancellationToken))!;
        data["models"]!.AsArray().Single(model => model!["id"]!.GetValue<string>() == "whisper-base.en-q5_1")!["whisper"]!["dtwDefault"] = false;
        var path = Path.Combine(files.Root, "catalog", "transcription-models.json");
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        await File.WriteAllTextAsync(path, data.ToJsonString(), TestContext.Current.CancellationToken);
        await using var engine = new WhisperNetTranscriber(new ModelCatalog(files.Root), dataRoot: files.Root);
        Assert.Equal(TimingSource.TokenGrouped, engine.Capabilities("whisper-base.en-q5_1").Timing);
    }

    [Fact]
    public void CountsOnlyActualDtwTimestamps()
    {
        var count = 0;
        WhisperTokens.Map(Segment("hello", [Token(" hello", 10, 20, dtw: -1)]), 0, 1, 0, true, false, new Log(), () => count++);
        Assert.Equal(0, count);
        WhisperTokens.Map(Segment("hello", [Token(" hello", 10, 20)]), 0, 1, 0, true, false, new Log(), () => count++);
        Assert.Equal(1, count);
    }

    [Fact(Skip = "Set VOXCLIP_TEST_DOWNLOAD=1 or VOXCLIP_LIVE_TESTS=1 to download the 59.7 MB English GGML model into VOXCLIP_DATA_DIR (or a temporary directory).", SkipUnless = nameof(ModelsEnabled))]
    [Trait("Category", "Models")]
    public async Task LiveCpuTranscriptionWithAndWithoutDtw()
    {
        using var files = new WaveFiles();
        if (OperatingSystem.IsMacOS())
        {
            await RunAsync("/usr/bin/say", ["-r", "155", "-o", Path.Combine(files.Root, "speech.aiff"), "Hello, um, today we are testing VoxClip. We keep every word so editing video is simple."]);
            await RunAsync("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", Path.Combine(files.Root, "speech.aiff"), files.Wav]);
        }
        else
        {
            var source = Environment.GetEnvironmentVariable("VOXCLIP_TEST_WAV");
            Assert.SkipUnless(!string.IsNullOrWhiteSpace(source) && File.Exists(source), "Provide VOXCLIP_TEST_WAV on non-macOS hosts.");
            File.Copy(source!, files.Wav);
        }
        var catalog = new ModelCatalog();
        var dataRoot = Environment.GetEnvironmentVariable("VOXCLIP_DATA_DIR") ?? files.Root;
        var store = new ModelStore(catalog, dataRoot, confirmDownload: (_, _, _) => Task.FromResult(true));
        var download = Stopwatch.StartNew();
        var model = (await catalog.GetModelAsync("whisper-base.en-q5_1", TestContext.Current.CancellationToken))!;
        Assert.True(model.TotalBytes <= 150_000_000);
        await store.InstallAsync(model.Id, null, TestContext.Current.CancellationToken);
        Assert.True(await store.VerifyAsync(model.Id, null, TestContext.Current.CancellationToken));
        output.WriteLine($"Model and VAD installed and SHA-256 verified in {download.Elapsed.TotalSeconds:F2}s.");
        var audio = WaveFiles.Describe(files.Wav);
        var diagnostics = new DecodeSignalLog();
        var installedOnly = new InstalledOnlyStore(store);
        await using var engine = new WhisperNetTranscriber(catalog, installedOnly, dataRoot, diagnostics);
        var baseRequest = new TranscriptionRequest(new(TranscriptEngine.Whispercpp, model.Id, new LanguageChoice.Forced("en"), new()),
            audio, Convert.ToHexStringLower(SHA256.HashData(await File.ReadAllBytesAsync(files.Wav, TestContext.Current.CancellationToken))));
        await engine.TranscribeAsync(baseRequest, new SynchronousProgress<TranscriptionProgress>(), TestContext.Current.CancellationToken);
        output.WriteLine("Untimed warm-up completed; subsequent measurements exclude first native initialization.");
        var measured = new List<(bool Dtw, RawTranscript Raw, WhisperRunMetrics Metrics)>();
        foreach (var dtw in new[] { true, false, false, true })
        {
            var plan = new TranscriptionPlan(TranscriptEngine.Whispercpp, model.Id, new LanguageChoice.Forced("en"), new(Dtw: dtw));
            var request = new TranscriptionRequest(plan, audio, Convert.ToHexStringLower(SHA256.HashData(await File.ReadAllBytesAsync(files.Wav, TestContext.Current.CancellationToken))));
            var timer = Stopwatch.StartNew();
            var raw = await engine.TranscribeAsync(request, new SynchronousProgress<TranscriptionProgress>(), TestContext.Current.CancellationToken);
            Assert.Equal(dtw ? TimingSource.Dtw : TimingSource.TokenGrouped, raw.Timing);
            Assert.Equal("Whisper.net 1.9.1 (whisper.cpp 1.8.5)", raw.Engine.EngineVersion);
            var words = WordAssembler.Group(raw.Tokens, raw.Grouping, 0);
            Assert.Contains(words, word => word.Text.Contains("Hello", StringComparison.OrdinalIgnoreCase));
            Assert.Contains(words, word => word.Text.Contains("today", StringComparison.OrdinalIgnoreCase));
            Assert.Contains(words, word => Regex.IsMatch(word.Text, "^(um+|uh+|erm+|hmm+)[,.!?]?$", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant));
            Assert.All(words, word => Assert.True(word.Start >= 0 && word.End > word.Start && word.End <= audio.DurationSeconds));
            Assert.True(words.Zip(words.Skip(1)).All(pair => pair.First.Start <= pair.Second.Start && pair.First.End <= pair.Second.End));
            var metrics = Assert.IsType<WhisperRunMetrics>(engine.LastRunMetrics);
            measured.Add((dtw, raw, metrics));
            output.WriteLine($"CPU DTW={dtw}: audio={audio.DurationSeconds:F3}s; total={timer.Elapsed.TotalSeconds:F3}s; VAD={metrics.VadSeconds:F3}s; model-load={metrics.ModelLoadSeconds:F3}s; decode={metrics.DecodeSeconds:F3}s; tokens={raw.Tokens.Count}; words={words.Count}; decode-RTF={metrics.DecodeSeconds / audio.DurationSeconds:F3}");
        }
        var aligned = WordAssembler.Group(measured.First(run => run.Dtw).Raw.Tokens, measured[0].Raw.Grouping, 0);
        var unaligned = WordAssembler.Group(measured.First(run => !run.Dtw).Raw.Tokens, measured[0].Raw.Grouping, 0);
        Assert.Equal(aligned.Count, unaligned.Count);
        Assert.Contains(aligned.Zip(unaligned), pair => Math.Abs(pair.First.Start!.Value - pair.Second.Start!.Value) > 0.001);
        Assert.All(measured, run => Assert.Equal(aligned.Count, WordAssembler.Group(run.Raw.Tokens, run.Raw.Grouping, 0).Count));
        foreach (var dtw in new[] { true, false })
            output.WriteLine($"Warm DTW={dtw} mean: VAD={measured.Where(run => run.Dtw == dtw).Average(run => run.Metrics.VadSeconds):F3}s; model-load={measured.Where(run => run.Dtw == dtw).Average(run => run.Metrics.ModelLoadSeconds):F3}s; decode={measured.Where(run => run.Dtw == dtw).Average(run => run.Metrics.DecodeSeconds):F3}s.");
        using var cancel = CancellationTokenSource.CreateLinkedTokenSource(TestContext.Current.CancellationToken);
        long cancelledAt = 0;
        var decodingStarted = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        diagnostics.OnDecode = () => decodingStarted.TrySetResult();
        var cancellationRequest = new TranscriptionRequest(new(TranscriptEngine.Whispercpp, model.Id, new LanguageChoice.Forced("en"), new(Dtw: false)),
            audio, new string('b', 64));
        var pendingDecode = engine.TranscribeAsync(cancellationRequest, new SynchronousProgress<TranscriptionProgress>(), cancel.Token);
        try
        {
            await decodingStarted.Task.WaitAsync(TimeSpan.FromSeconds(30), TestContext.Current.CancellationToken);
            await Task.Delay(100, TestContext.Current.CancellationToken);
            cancelledAt = Stopwatch.GetTimestamp();
            cancel.Cancel();
            await Assert.ThrowsAnyAsync<OperationCanceledException>(() => pendingDecode);
        }
        finally
        {
            cancel.Cancel();
            try { await pendingDecode; }
            catch (OperationCanceledException) { }
        }
        Assert.NotEqual(0, cancelledAt);
        var cancellationSeconds = Stopwatch.GetElapsedTime(cancelledAt).TotalSeconds;
        Assert.True(cancellationSeconds < 1, $"Decoder cancellation took {cancellationSeconds:F3}s.");
        output.WriteLine($"Warm decoder cancellation stopped after {cancellationSeconds:F3}s; no partial transcript returned.");
        diagnostics.OnDecode = null;
        foreach (var stage in new[] { "vad", "model-load" })
        {
            using var stageCancel = CancellationTokenSource.CreateLinkedTokenSource(TestContext.Current.CancellationToken);
            var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            var stageLog = new DecodeSignalLog { OnStage = current => { if (current == stage) entered.TrySetResult(); } };
            await using var fresh = new WhisperNetTranscriber(catalog, installedOnly, dataRoot, stageLog);
            var pending = fresh.TranscribeAsync(baseRequest, new SynchronousProgress<TranscriptionProgress>(), stageCancel.Token);
            try
            {
                await entered.Task.WaitAsync(TimeSpan.FromSeconds(30), TestContext.Current.CancellationToken);
                await Task.Delay(1, TestContext.Current.CancellationToken);
                var stopped = Stopwatch.StartNew();
                stageCancel.Cancel();
                await Assert.ThrowsAnyAsync<OperationCanceledException>(() => pending);
                Assert.True(stopped.Elapsed.TotalSeconds < 1);
                output.WriteLine($"First {stage} caller-visible cancellation returned after {stopped.Elapsed.TotalSeconds:F3}s; disposal waits for safe native drain.");
            }
            finally { stageCancel.Cancel(); }
        }
        WaveFiles.Write(files.Wav, new short[16000]);
        var silentRequest = cancellationRequest with { Audio = WaveFiles.Describe(files.Wav) };
        var silentError = await Assert.ThrowsAsync<VoxClipException>(() => engine.TranscribeAsync(silentRequest,
            new SynchronousProgress<TranscriptionProgress>(), TestContext.Current.CancellationToken));
        Assert.Equal(VoxClipErrorCode.NoSpeech, silentError.Code);
        output.WriteLine("Silero VAD rejected a one-second silent WAV with noSpeech.");
    }

    private static WhisperToken Token(string text, long start, long end, int id = 100, long? dtw = null) => new()
    {
        Id = id, Text = text, Start = start, End = end, DtwTimestamp = dtw ?? start + 1, Probability = 0.8f
    };
    private static SegmentData Segment(string text, WhisperToken[] tokens) => new(text, TimeSpan.Zero, TimeSpan.FromSeconds(1), 0.8f, 0.8f, 0.8f, 0, "en", tokens);
    private static async Task RunAsync(string executable, string[] arguments)
    {
        var info = new ProcessStartInfo(executable) { RedirectStandardError = true, RedirectStandardOutput = true };
        foreach (var argument in arguments) info.ArgumentList.Add(argument);
        using var process = Process.Start(info)!;
        await process.WaitForExitAsync(TestContext.Current.CancellationToken);
        Assert.Equal(0, process.ExitCode);
    }
}

internal sealed class SynchronousProgress<T>(Action<T>? report = null) : IProgress<T>
{
    public void Report(T value) => report?.Invoke(value);
}

internal sealed class InstalledOnlyStore(IModelDownloader store) : IModelDownloader
{
    public Task<IReadOnlyList<InstalledModel>> ListInstalledAsync(CancellationToken ct) => store.ListInstalledAsync(ct);
    public Task<InstalledModel> InstallAsync(string id, IProgress<ModelDownloadProgress>? progress, CancellationToken ct) =>
        throw new InvalidOperationException("Transcription must not install models.");
    public Task<bool> VerifyAsync(string id, IProgress<ModelDownloadProgress>? progress, CancellationToken ct) =>
        throw new InvalidOperationException("Transcription must not hash installed models.");
    public Task RemoveAsync(string id, CancellationToken ct) =>
        throw new InvalidOperationException("Transcription must not remove models.");
}

internal sealed class DecodeSignalLog : ILog
{
    internal Action? OnDecode { get; set; }
    internal Action<string>? OnStage { get; set; }
    public void RegisterSecret(string secret) { }
    public void Write(LogLevel level, string category, string message)
    {
        if (message == "whispercpp stage decode") OnDecode?.Invoke();
        if (message.StartsWith("whispercpp stage ", StringComparison.Ordinal)) OnStage?.Invoke(message[17..]);
    }
    public Task<IReadOnlyList<string>> ReadRecentAsync(int count, CancellationToken ct) => Task.FromResult<IReadOnlyList<string>>([]);
    public Task FlushAsync(CancellationToken ct) => Task.CompletedTask;
    public ValueTask DisposeAsync() => ValueTask.CompletedTask;
}

internal sealed class WaveFiles : IDisposable
{
    internal string Root { get; } = Path.Combine(Path.GetTempPath(), "voxclip-native-speech-" + Guid.NewGuid().ToString("N"));
    internal string Wav => Path.Combine(Root, "speech.wav");
    internal WaveFiles() => Directory.CreateDirectory(Root);
    internal static void Write(string path, short[] samples)
    {
        using var writer = new BinaryWriter(File.Create(path));
        writer.Write(Encoding.ASCII.GetBytes("RIFF")); writer.Write(36 + samples.Length * 2); writer.Write(Encoding.ASCII.GetBytes("WAVEfmt "));
        writer.Write(16); writer.Write((short)1); writer.Write((short)1); writer.Write(16000); writer.Write(32000); writer.Write((short)2); writer.Write((short)16);
        writer.Write(Encoding.ASCII.GetBytes("data")); writer.Write(samples.Length * 2);
        foreach (var sample in samples) writer.Write(sample);
    }
    internal static ExtractedAudio Describe(string path)
    {
        using var stream = File.OpenRead(path);
        using var reader = new BinaryReader(stream);
        Assert.Equal("RIFF", Encoding.ASCII.GetString(reader.ReadBytes(4)));
        reader.ReadUInt32();
        Assert.Equal("WAVE", Encoding.ASCII.GetString(reader.ReadBytes(4)));
        var rate = 0;
        while (stream.Position + 8 <= stream.Length)
        {
            var tag = Encoding.ASCII.GetString(reader.ReadBytes(4));
            var size = reader.ReadUInt32();
            var end = stream.Position + size;
            if (tag == "fmt ")
            {
                Assert.Equal(1, reader.ReadInt16()); Assert.Equal(1, reader.ReadInt16()); rate = reader.ReadInt32();
            }
            if (tag == "data")
            {
                Assert.Equal(16000, rate);
                return new(path, size / 2, (size / 2.0) / rate, 0, 0);
            }
            stream.Position = end + (size & 1);
        }
        throw new InvalidDataException("Missing WAV samples.");
    }
    public void Dispose() => Directory.Delete(Root, true);
}
