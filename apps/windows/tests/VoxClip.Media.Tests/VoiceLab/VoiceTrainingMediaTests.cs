using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.LLM;
using VoxClip.Core.Services.Speech;
using VoxClip.Core.Services.VoiceLab;
using VoxClip.Media.Ffmpeg;
using VoxClip.Media.Pipeline;
using VoxClip.Media.VoiceLab;
using Xunit;

namespace VoxClip.Media.Tests.VoiceLab;

/// <summary>Own-voice training from the open project's audio (Voice Lab §6.5 a, §6.5.1 and §6.6): frame levels, span cuts and the
/// speaker match before any request, with a fake embedder and a transport that fails the test if it is ever called.</summary>
public sealed class VoiceTrainingMediaTests
{
    private static CancellationToken Token => TestContext.Current.CancellationToken;
    private const string Statement = "My name is Example. Today is 31 October 2026. This is my own voice, and I agree to an AI copy of it being made with ElevenLabs for editing my own videos. alpha beta gamma delta.";
    private static float[] Tone(int rate, double seconds, double frequency = 220) => Enumerable.Range(0, (int)Math.Round(rate * seconds))
        .Select(index => (float)(0.1 * Math.Sin(2 * Math.PI * frequency * index / rate))).ToArray();
    private static VoiceTrainingSample Sample(double seconds, string source = "project", double snr = 30, int rate = 16000) =>
        new(VoiceTrainingAudio.Wav(Tone(rate, seconds, 100 + seconds), rate), Math.Round(rate * seconds) / rate, source, snr);

    private sealed class Keys : IKeyProvider
    {
        public Task<string?> GetKeyAsync(string account, CancellationToken ct) => throw new InvalidOperationException("Preparing a clone reads no key.");
    }
    private sealed class Transport : HttpMessageHandler
    {
        internal int Sends;
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            Sends++;
            throw new InvalidOperationException("Training preparation must not reach a provider.");
        }
    }
    /// <summary>Returns the owner vector for the statement, then one scripted result per training sample in call order. A result
    /// lists the sample's window embeddings, which <see cref="SpeakerAudio"/> combines into its mean or its project-span parts as the
    /// ONNX embedder does.</summary>
    private sealed class Embedder(params Func<float[][]>[] results)
    {
        private int calls;
        internal int Calls => calls;
        internal int PartCalls { get; private set; }
        private float[][] Windows()
        {
            var index = calls++;
            return index == 0 ? [[1f, 0f]] : results[index - 1]();
        }
        internal Task<float[]> EmbedAsync(float[] pcm16k, CancellationToken ct)
        {
            ct.ThrowIfCancellationRequested();
            return Task.FromResult(SpeakerAudio.Embedding(Windows()));
        }
        internal Task<(float[] Whole, float[][] Parts)> PartsAsync(float[] pcm16k, CancellationToken ct)
        {
            ct.ThrowIfCancellationRequested();
            PartCalls++;
            return Task.FromResult(SpeakerAudio.PartEmbeddings(Windows()));
        }
    }
    private static float[] Vector(double cosine) => [(float)cosine, (float)Math.Sqrt(1 - cosine * cosine)];
    private static Func<float[][]> Score(double cosine) => () => [Vector(cosine)];
    private static Func<float[][]> TooLittleSpeech => () => throw new VoiceConsentException(VoiceConsentError.SpeakerMismatch);

    private static async Task<VoiceEnrollment.PreparedTraining> PrepareAsync(Transport transport, Embedder embedder, params VoiceTrainingSample[] samples)
    {
        using var client = ElevenLabsVoiceLab.ForTesting(new Keys(), transport, ElevenLabsRegion.Default);
        var statement = VoiceTrainingAudio.Wav(Tone(16000, 6), 16000);
        return await VoiceEnrollment.PrepareTrainingAsync(client, Guid.NewGuid().ToString("D"), " Example ", new("en", Statement, ["alpha", "beta", "gamma", "delta"]),
            statement, samples, 0.45, embedder.EmbedAsync, embedder.PartsAsync, DateTimeOffset.UnixEpoch, Token);
    }

    [Fact]
    public void FrameLevelsFollowTheIntegerGridAndCountOnlyWholeFrames()
    {
        foreach (var rate in new[] { 8_000, 11_025, 22_050, 44_100, 48_000 })
        {
            var samples = Enumerable.Range(0, rate / 3 + 7).Select(index => (float)(0.25 * Math.Sin(index * 0.37) * (index % 997 == 0 ? 0 : 1))).ToArray();
            var levels = new VoiceTrainingLevels(rate);
            for (var start = 0; start < samples.Length; start += 333) levels.Append(samples.AsSpan(start, Math.Min(333, samples.Length - start)));
            var take = levels.Finish(long.MaxValue);
            var count = (int)(samples.LongLength * 100 / rate);
            Assert.Equal(rate, take.Rate); Assert.Equal(samples.Length, take.Samples); Assert.Equal(count, take.FrameDb.Count);
            for (var frame = 0; frame < count; frame++)
            {
                var first = (int)((long)frame * rate / 100);
                var end = (int)((frame + 1L) * rate / 100);
                var power = 0.0;
                for (var index = first; index < end; index++) power += (double)samples[index] * samples[index];
                Assert.Equal(20 * Math.Log10(Math.Max(Math.Sqrt(power / (end - first)), 1e-9)), take.FrameDb[frame]);
            }
            Assert.Equal(samples.LongLength * 1000 / rate / 1000.0, take.Duration);
        }
        var silent = new VoiceTrainingLevels(22_050);
        silent.Append(new float[220]);
        Assert.Empty(silent.Finish(long.MaxValue).FrameDb);
        silent.Append(new float[221]);
        Assert.Equal(new[] { -180.0, -180.0 }, silent.Finish(long.MaxValue).FrameDb);
    }

    [Fact]
    public void TimelineFillsLateStartsAndGapsWithSilenceAndDropsOverlaps()
    {
        var blocks = new List<(long First, float[] Samples)>();
        // The last block starts before the media's limit, so it is kept whole although it ends past it.
        var timeline = new VoiceTrainingTimeline((samples, first) => blocks.Add((first, samples.ToArray())), 70_010);
        timeline.Append([1, 2, 3], -2);
        timeline.Append([4, 5], 3);
        timeline.Append([6, 7, 8], 4);
        timeline.Append([9], 2);
        timeline.Append([10, 11], 7);
        timeline.Append([12, 12, 12], 70_009);
        Assert.Equal(70_012, timeline.Next);
        var expected = new float[70_012];
        new float[] { 3, 0, 0, 4, 5, 7, 8, 10, 11 }.CopyTo(expected, 0);
        expected.AsSpan(70_009).Fill(12);
        Assert.Equal(expected, blocks.SelectMany(block => block.Samples));
        long next = 0;
        foreach (var block in blocks)
        {
            Assert.Equal(next, block.First); Assert.InRange(block.Samples.Length, 1, 65_536);
            next += block.Samples.Length;
        }
    }

    /// <summary>§6.5.1: the media's duration bounds the placed stream. A block placed at or after ceil(duration × rate) is dropped with no
    /// silence up to it, a block placed before it is kept whole, and the take lasts the smaller of the placed and media lengths in whole
    /// milliseconds (Mac 04ce651c).</summary>
    [Fact]
    public void TimelineStopsAtTheMediaDurationAndTheTakeLastsTheShorterLength()
    {
        const int rate = 8_000;
        // 125,063 µs is 1,000.504 samples: blocks placed from sample 1,001 on are dropped, and the media lasts 125 ms.
        const long duration = 125_063;
        Assert.Equal(1_001, VoiceTrainingTimeline.Limit(duration, rate));
        Assert.Equal(1_000, VoiceTrainingTimeline.Limit(125_000, rate));
        Assert.Equal(1, VoiceTrainingTimeline.Limit(1, rate));
        Assert.Equal(96_000L * 3_600 * 24 * 365, VoiceTrainingTimeline.Limit(3_600L * 24 * 365 * 1_000_000, 96_000));
        float[] Block(int index, int count) => Enumerable.Range(0, count).Select(sample => (float)(0.05 * (index + 1) * Math.Sin(sample * 0.3 + index))).ToArray();
        (long First, float[] Samples, bool Placed)[] rows =
        [
            (0, Block(0, 100), true),
            (400, Block(1, 100), true),              // a timestamp gap: silence across it
            (1_000, Block(2, 50), true),             // placed before the limit, so kept whole
            (1_050, Block(3, 50), false),            // sequential, but at the limit or after it: dropped
            (800_000, Block(4, 50), false),          // a corrupt far timestamp: dropped, with no silence up to it
            (long.MaxValue / 4, Block(5, 50), false), // beyond any decodable length: dropped, not refused as too large
        ];
        var expected = new List<float>();
        foreach (var row in rows.Where(row => row.Placed))
        {
            expected.AddRange(new float[row.First - expected.Count]);
            expected.AddRange(row.Samples);
        }
        Assert.Equal(1_050, expected.Count);
        var reference = new VoiceTrainingLevels(rate);
        reference.Append(expected.ToArray());
        var levels = new VoiceTrainingLevels(rate);
        var timeline = new VoiceTrainingTimeline((samples, _) => levels.Append(samples), VoiceTrainingTimeline.Limit(duration, rate));
        foreach (var row in rows) timeline.Append(row.Samples, row.First);
        Assert.Equal(1_050, timeline.Next);
        var take = levels.Finish(duration / 1_000);
        Assert.Equal(1_050, take.Samples); Assert.Equal(125, take.MediaMilliseconds);
        Assert.Equal(13, take.FrameDb.Count); Assert.Equal(reference.Finish(long.MaxValue).FrameDb, take.FrameDb);
        Assert.Equal(0.125, take.Duration);
        // A placed take shorter than the media sets the duration.
        var head = new VoiceTrainingLevels(rate);
        var headTimeline = new VoiceTrainingTimeline((samples, _) => head.Append(samples), VoiceTrainingTimeline.Limit(1_000_000, rate));
        headTimeline.Append(rows[0].Samples, rows[0].First);
        var partial = head.Finish(1_000);
        Assert.Equal(reference.Finish(long.MaxValue).FrameDb.Take(1), partial.FrameDb);
        Assert.Equal(0.012, partial.Duration);
        // With only a far block nothing is placed, and TrainingMixAsync refuses the take as unreadable.
        var far = new VoiceTrainingTimeline((_, _) => Assert.Fail("A block past the media's duration was placed."), VoiceTrainingTimeline.Limit(duration, rate));
        far.Append(rows[4].Samples, rows[4].First);
        Assert.Equal(0, far.Next);
        // Below the limit the stream keeps its size bound, before any silence is placed.
        var unbounded = new VoiceTrainingTimeline((_, _) => Assert.Fail("An oversized block was placed."), long.MaxValue);
        Assert.Equal(VoiceLabSourceAudioErrorCode.TooLarge, Assert.Throws<VoiceLabSourceAudioException>(() => unbounded.Append(new float[2], Array.MaxLength - 1)).Code);
        Assert.Equal(0, unbounded.Next);
    }

    /// <summary>A timestamp gap that runs past a span's end is the silence the levels read there: the one-pass cut reads on to the
    /// block after the gap (TrainingMixAsync continues while the placed stream is short of <see cref="VoiceTrainingCut.End"/>) and
    /// never refuses the span (Mac 04ce651c).</summary>
    [Fact]
    public void CutTakesTheSilenceOfAGapThatRunsPastItsEnd()
    {
        const int rate = 8_000;
        var cut = new VoiceTrainingCut([new(1_000, 6_000, 30)], rate);
        var timeline = new VoiceTrainingTimeline(cut.Append, VoiceTrainingTimeline.Limit(10_000_000, rate));
        var voiced = Tone(rate, 4, 240);
        timeline.Append(voiced, 0);
        Assert.True(timeline.Next < cut.End);
        timeline.Append(Tone(rate, 1, 240), 7 * rate);
        Assert.True(timeline.Next >= cut.End);
        var expected = new float[5 * rate];
        voiced.AsSpan(rate).CopyTo(expected);
        Assert.Equal(VoiceTrainingAudio.Wav(expected, rate), Assert.Single(cut.Finish()).Wav);
    }

    [Fact, Trait("Category", "RequiresFFmpeg"), Trait("Category", "RequiresWindows")]
    public async Task LateAndGappedAudioIsPlacedOnTheTimelineTranscriptionExtractionUses()
    {
        await NativeTest.RequireAsync(windows: true);
        // Stereo f32 audio that starts 1.5 s after the video, with a 0.75 s timestamp gap 4 s into the audio (generate-fixtures.sh).
        var path = NativeTest.Fixture("late-audio.mkv");
        const int rate = 48_000;
        var info = await new FfmpegMediaProbe().ProbeAsync(path, Token);
        Assert.Equal(1.5, info.AudioTimelineStart, 3);
        var take = await VoiceTrainingAudio.AnalyzeAsync(path, rate, Token);
        Assert.InRange(take.Samples, 588_000 - 48, 588_000 + 48);
        // AudioDecoder lays out the transcription audio, so its mono mix is the timeline transcript times refer to.
        using var reference = new AudioDecoder(path);
        var values = new float[take.Samples * reference.Channels];
        Assert.Equal(take.Samples, reference.Read(values, (int)take.Samples, Token));
        var mono = new float[take.Samples];
        for (var index = 0; index < mono.Length; index++)
        {
            double sum = 0;
            for (var channel = 0; channel < reference.Channels; channel++) sum += values[index * reference.Channels + channel];
            mono[index] = (float)(sum / reference.Channels);
        }
        var expected = new VoiceTrainingLevels(rate);
        expected.Append(mono);
        Assert.Equal(expected.Finish(long.MaxValue).FrameDb, take.FrameDb);
        // The container lasts until the audio ends 12.25 s in, so nothing placed is dropped.
        Assert.InRange(take.MediaMilliseconds, 12_249, 12_251); Assert.InRange(take.Duration, 12.249, 12.251);
        Assert.All(take.FrameDb.Take(150), level => Assert.True(level < -170));
        Assert.True(take.FrameDb[151] > -40);
        Assert.All(take.FrameDb.Skip(555).Take(65), level => Assert.True(level < -170));
        VoiceTrainingSpan[] spans = [new(1_000, 7_000, 30), new(6_500, 12_000, 30)];
        var samples = await VoiceTrainingAudio.ProjectSpansAsync(path, rate, spans, Token);
        for (var index = 0; index < spans.Length; index++)
        {
            var (first, last) = VoiceTrainingAudio.SpanSamples(spans[index], rate);
            Assert.Equal(VoiceTrainingAudio.Wav(mono[(int)first..(int)last], rate), samples[index].Wav);
        }
        // A span alone that ends inside the 5.5–6.25 s gap: its pass reads on to the frame after the gap and holds the silence the
        // levels read there, never RangeOutsideMedia.
        VoiceTrainingSpan gapped = new(500, 5_900, 30);
        var (gapFirst, gapLast) = VoiceTrainingAudio.SpanSamples(gapped, rate);
        Assert.Equal(VoiceTrainingAudio.Wav(mono[(int)gapFirst..(int)gapLast], rate),
            Assert.Single(await VoiceTrainingAudio.ProjectSpansAsync(path, rate, [gapped], Token)).Wav);
    }

    [Theory]
    [InlineData(8_000)]
    [InlineData(11_025)]
    [InlineData(22_050)]
    [InlineData(44_100)]
    [InlineData(48_000)]
    [InlineData(96_000)]
    public void SpanCutsUseRoundedIntegerBoundsAndAlwaysLastFiveToThirtySeconds(int rate)
    {
        foreach (var (start, end) in new[] { (0L, 5_000L), (1L, 5_001L), (123L, 30_123L), (3_599_987L, 3_629_987L), (7L, 17_013L) })
        {
            var (first, last) = VoiceTrainingAudio.SpanSamples(new(start, end, 20), rate);
            Assert.Equal((start * rate + 500) / 1000, first); Assert.Equal((end * rate + 500) / 1000, last);
            Assert.InRange(last - first, 5L * rate, 30L * rate);
        }
        foreach (var span in new VoiceTrainingSpan[] { new(0, 4_999, 30), new(0, 30_001, 30), new(-1, 5_000, 30), new(0, 5_000, 19.999), new(0, 5_000, double.NaN) })
            Assert.Throws<VoiceLabException>(() => VoiceTrainingAudio.SpanSamples(span, rate));
        Assert.Throws<VoiceLabException>(() => VoiceTrainingAudio.SpanSamples(new(0, 5_000, 30), 7_999));
        Assert.Throws<VoiceLabException>(() => VoiceTrainingAudio.SpanSamples(new(0, 5_000, 30), 96_001));
    }

    [Fact]
    public void CutCollectsSelectedSpansAcrossBlocksAsProjectSamples()
    {
        const int rate = 22_050;
        var take = Tone(rate, 50, 180);
        VoiceTrainingSpan[] spans = [new(30_001, 41_000, 44.5), new(1_234, 6_234, 21)];
        var cut = new VoiceTrainingCut(spans, rate);
        Assert.Equal((41_000L * rate + 500) / 1000, cut.End);
        for (var start = 0; start < cut.End; start += 4_097) cut.Append(take.AsSpan(start, Math.Min(4_097, take.Length - start)), start);
        var samples = cut.Finish();
        Assert.Equal(2, samples.Count);
        for (var index = 0; index < spans.Length; index++)
        {
            var (first, last) = VoiceTrainingAudio.SpanSamples(spans[index], rate);
            var sample = samples[index];
            Assert.Equal("project", sample.Source); Assert.Equal(spans[index].SnrDb, sample.SnrDb); Assert.False(sample.CleanAudioApplied);
            Assert.Equal((last - first) / (double)rate, sample.Seconds);
            var format = VoiceConsentAudio.ValidateWav(sample.Wav);
            Assert.Equal(rate, format.Rate); Assert.Equal(last - first, format.Frames);
            Assert.Equal(VoiceTrainingAudio.Wav(take[(int)first..(int)last], rate), sample.Wav);
        }
        var early = new VoiceTrainingCut(spans, rate);
        early.Append(take.AsSpan(0, (int)early.End - 1), 0);
        Assert.Equal(VoiceLabSourceAudioErrorCode.RangeOutsideMedia, Assert.Throws<VoiceLabSourceAudioException>(() => early.Finish()).Code);
        Assert.Throws<VoiceLabException>(() => new VoiceTrainingCut([], rate));
        Assert.Throws<VoiceLabException>(() => new VoiceTrainingCut(Enumerable.Repeat(new VoiceTrainingSpan(0, 5_000, 30), 25).ToArray(), rate));
        Assert.Throws<VoiceLabException>(() => VoiceTrainingAudio.ProjectSpan(new float[5 * rate - 1], rate, new(0, 5_000, 30)));
    }

    [Fact]
    public void TrainingSamplesShareOneSourceWithinItsLimits()
    {
        string Source(params VoiceTrainingSample[] samples) => VoiceEnrollment.TrainingSource(samples);
        void Refused(params VoiceTrainingSample[] samples) =>
            Assert.Equal(VoiceLabErrorKind.InvalidInput, Assert.Throws<VoiceLabException>(() => VoiceEnrollment.TrainingSource(samples)).Kind);
        Assert.Equal("project", Source(Sample(10), Sample(10), Sample(10)));
        Assert.Equal("project", Source(Enumerable.Range(0, 4).Select(_ => Sample(30)).ToArray()));
        Assert.Equal("readAloud", Source(Sample(30, "readAloud"), Sample(30, "readAloud")));
        Refused(Sample(15), Sample(15, "readAloud"), Sample(30));
        Refused(Sample(30, "readAloud"), Sample(30));
        Refused(Sample(10), Sample(10), Sample(9.999));
        Refused(Enumerable.Range(0, 4).Select(_ => Sample(30)).Append(Sample(5)).ToArray());
        Refused(Enumerable.Range(0, 25).Select(_ => Sample(5)).ToArray());
        Refused(Sample(4.999), Sample(30));
        Refused(Sample(10, "upload"), Sample(10, "upload"), Sample(10, "upload"));
        Refused(Sample(30, "readAloud"), Sample(29, "readAloud"));
        Refused();
    }

    [Fact]
    public async Task ProjectSpansBelowTauOrWithoutSpeechAreDroppedAndTheRestFollowTheStatement()
    {
        var transport = new Transport();
        VoiceTrainingSample[] spans = [Sample(10), Sample(11), Sample(10.5), Sample(12), Sample(9.5)];
        var embedder = new Embedder(Score(0.46), Score(0.44), Score(0.9), TooLittleSpeech, Score(0.6));
        var prepared = await PrepareAsync(transport, embedder, spans);
        Assert.Equal(6, embedder.Calls); Assert.Equal(0, transport.Sends);
        Assert.Equal("Example", prepared.Request.DisplayName); Assert.Equal("en", prepared.Request.Language);
        Assert.False(prepared.Request.RemoveBackgroundNoise);
        Assert.Equal(new[] { VoiceLabCloneSampleRole.ConsentStatement, VoiceLabCloneSampleRole.Training, VoiceLabCloneSampleRole.Training, VoiceLabCloneSampleRole.Training },
            prepared.Request.Samples.Select(sample => sample.Role));
        Assert.Equal(new[] { spans[0], spans[2], spans[4] }.Select(span => span.Wav), prepared.Request.Samples.Skip(1).Select(sample => sample.Wav));
        Assert.Equal(new[] { "project", "project", "project" }, prepared.Samples.Select(sample => sample.Source));
        Assert.Equal(new[] { 10, 10.5, 9.5 }, prepared.Samples.Select(sample => sample.Seconds));
        Assert.Equal(new[] { spans[0], spans[2], spans[4] }.Select(span => VoiceConsentStore.Hash(span.Wav)), prepared.Samples.Select(sample => sample.Sha256));
        Assert.Equal(30_000, prepared.TrainingMs);
        Assert.Equal(new[] { 1f, 0f }, prepared.Owner);
        Assert.NotNull(prepared.Quote);
    }

    [Fact]
    public async Task FewerThanThirtySecondsOfMatchingProjectSpeechIsAMismatchBeforeAnyRequest()
    {
        var transport = new Transport();
        var embedder = new Embedder(Score(0.9), Score(0.1), Score(0.9), TooLittleSpeech);
        var error = await Assert.ThrowsAsync<VoiceConsentException>(() => PrepareAsync(transport, embedder, Sample(10), Sample(10), Sample(9.999), Sample(10)));
        Assert.Equal(VoiceConsentError.SpeakerMismatch, error.Kind);
        Assert.Equal(5, embedder.Calls); Assert.Equal(0, transport.Sends);
    }

    /// <summary>§6.6 project span parts: a 30 s span whose 12–18 s stretch is another voice passes on its mean, but the part holding
    /// that voice does not, so the span is dropped and never sent. A kept span scores as its lowest part. A read-aloud of the same
    /// audio is scored on its mean.</summary>
    [Fact]
    public async Task ProjectSpansMustMatchInEveryPart()
    {
        // 19 windows of 3 s at a 1.5 s hop. Windows 8–10 lie in 12–18 s; the parts are windows 0–2, 3–5, 6–8, 9–11, 12–14 and 15–18.
        Func<float[][]> mixed = () => Enumerable.Range(0, 19).Select(window => Vector(window is >= 8 and <= 10 ? 0.1 : 0.9)).ToArray();
        var mean = SpeakerAudio.Cosine(Vector(1), SpeakerAudio.Embedding(mixed()));
        var parts = SpeakerAudio.PartEmbeddings(mixed()).Parts;
        Assert.InRange(mean, 0.8, 0.85); Assert.Equal(6, parts.Length);
        Assert.InRange(SpeakerAudio.Cosine(Vector(1), parts[3]), 0.4, 0.44);
        var transport = new Transport();
        var mixedSpan = Sample(30);
        var refused = new Embedder(mixed, Score(0.9));
        Assert.Equal(VoiceConsentError.SpeakerMismatch, (await Assert.ThrowsAsync<VoiceConsentException>(() => PrepareAsync(transport, refused, mixedSpan, Sample(25)))).Kind);
        Assert.Equal(2, refused.PartCalls);
        var embedder = new Embedder(mixed, () => [Vector(0.9), Vector(0.9), Vector(0.9), Vector(0.6), Vector(0.6), Vector(0.6)], Score(0.9));
        var prepared = await PrepareAsync(transport, embedder, mixedSpan, Sample(15), Sample(15.5));
        Assert.Equal(3, embedder.PartCalls); Assert.Equal(30_500, prepared.TrainingMs);
        Assert.Equal(new[] { 15, 15.5 }, prepared.Samples.Select(sample => sample.Seconds));
        Assert.Equal(0.6, prepared.Samples[0].SpeakerScore, 5); Assert.Equal(0.9, prepared.Samples[1].SpeakerScore, 5);
        Assert.DoesNotContain(prepared.Request.Samples, sample => sample.Wav.AsSpan().SequenceEqual(mixedSpan.Wav));
        var readAloud = new Embedder(mixed, mixed);
        var kept = await PrepareAsync(transport, readAloud, Sample(30, "readAloud"), Sample(30, "readAloud"));
        Assert.Equal(0, readAloud.PartCalls); Assert.Equal(60_000, kept.TrainingMs);
        Assert.All(kept.Samples, sample => Assert.Equal(mean, sample.SpeakerScore, 5));
        Assert.Equal(0, transport.Sends);
    }

    [Fact]
    public async Task MixedSourcesAreRefusedBeforeTheSpeakerMatch()
    {
        var transport = new Transport();
        var embedder = new Embedder();
        var error = await Assert.ThrowsAsync<VoiceLabException>(() => PrepareAsync(transport, embedder, Sample(30), Sample(30, "readAloud"), Sample(30)));
        Assert.Equal(VoiceLabErrorKind.InvalidInput, error.Kind);
        Assert.Equal(0, embedder.Calls); Assert.Equal(0, transport.Sends);
    }

    [Fact]
    public async Task OnlyANoisyReadAloudAsksForBackgroundNoiseRemovalAndKeepsItsTenSecondFloor()
    {
        var readAloud = await PrepareAsync(new Transport(), new Embedder(Score(0.9), Score(0.9)), Sample(30, "readAloud", 15), Sample(30, "readAloud"));
        Assert.True(readAloud.Request.RemoveBackgroundNoise);
        Assert.Equal(new[] { "readAloud", "readAloud" }, readAloud.Samples.Select(sample => sample.Source));
        var project = await PrepareAsync(new Transport(), new Embedder(Score(0.9), Score(0.9)), Sample(15, snr: 15), Sample(15));
        Assert.False(project.Request.RemoveBackgroundNoise);
        var kept = await PrepareAsync(new Transport(), new Embedder(Score(0.2), Score(0.9)), Sample(30, "readAloud"), Sample(30, "readAloud"));
        Assert.Equal(30_000, kept.TrainingMs);
        var transport = new Transport();
        Assert.Equal(VoiceConsentError.SpeakerMismatch, (await Assert.ThrowsAsync<VoiceConsentException>(() => PrepareAsync(transport,
            new Embedder(Score(0.2), Score(0.2)), Sample(30, "readAloud"), Sample(30, "readAloud")))).Kind);
        Assert.Equal(0, transport.Sends);
    }

    [Fact, Trait("Category", "RequiresFFmpeg"), Trait("Category", "RequiresWindows")]
    public async Task OneStreamedDecodeGivesTheMonoMixLevelsAndTheSameMixCutsTheSpans()
    {
        using var storage = new VoiceLabTestStorage();
        await NativeTest.RequireAsync(windows: true);
        const int rate = 22_050;
        static float Left(int frame) => (float)(0.3 * Math.Sin(2 * Math.PI * 200 * frame / rate) * (frame / rate % 7 == 0 ? 0.001 : 1));
        static float Right(int frame) => (float)(0.2 * Math.Sin(2 * Math.PI * 330 * frame / rate));
        var frames = rate * 40 + 123;
        var path = Path.Combine(storage.Root, "take.wav");
        using (var writer = new BinaryWriter(File.Create(path)))
        {
            writer.Write("RIFF"u8); writer.Write(36 + frames * 8); writer.Write("WAVEfmt "u8); writer.Write(16);
            writer.Write((short)3); writer.Write((short)2); writer.Write(rate); writer.Write(rate * 8); writer.Write((short)8); writer.Write((short)32);
            writer.Write("data"u8); writer.Write(frames * 8);
            for (var frame = 0; frame < frames; frame++) { writer.Write(Left(frame)); writer.Write(Right(frame)); }
        }
        var mono = Enumerable.Range(0, frames).Select(frame => (float)(((double)Left(frame) + Right(frame)) / 2)).ToArray();
        var expected = new VoiceTrainingLevels(rate);
        expected.Append(mono);
        var take = await VoiceTrainingAudio.AnalyzeAsync(path, rate, Token);
        Assert.Equal(frames, take.Samples); Assert.Equal(expected.Finish(long.MaxValue).FrameDb, take.FrameDb);
        Assert.Equal(40_005, take.MediaMilliseconds); Assert.Equal(40.005, take.Duration);
        VoiceTrainingSpan[] spans = [new(20_000, 39_999, 33), new(1_001, 6_500, 25)];
        var samples = await VoiceTrainingAudio.ProjectSpansAsync(path, rate, spans, Token);
        for (var index = 0; index < spans.Length; index++)
        {
            var (first, last) = VoiceTrainingAudio.SpanSamples(spans[index], rate);
            Assert.Equal(VoiceTrainingAudio.Wav(mono[(int)first..(int)last], rate), samples[index].Wav);
            Assert.Equal((last - first) / (double)rate, samples[index].Seconds);
        }
        Assert.Equal(VoiceLabSourceAudioErrorCode.RangeOutsideMedia, (await Assert.ThrowsAsync<VoiceLabSourceAudioException>(() =>
            VoiceTrainingAudio.ProjectSpansAsync(path, rate, [new(15_000, 41_000, 30)], Token))).Code);
        Assert.Equal(VoiceLabSourceAudioErrorCode.RateMismatch, (await Assert.ThrowsAsync<VoiceLabSourceAudioException>(() =>
            VoiceTrainingAudio.AnalyzeAsync(path, 44_100, Token))).Code);
        Assert.Equal(VoiceLabSourceAudioErrorCode.UnsupportedRate, (await Assert.ThrowsAsync<VoiceLabSourceAudioException>(() =>
            VoiceTrainingAudio.AnalyzeAsync(path, 192_000, Token))).Code);
        await Assert.ThrowsAsync<VoiceLabSourceAudioException>(() => VoiceTrainingAudio.AnalyzeAsync(Path.Combine(storage.Root, "missing.wav"), rate, Token));
    }
}
