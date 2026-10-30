using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.LLM;
using VoxClip.Core.Services.Speech;
using VoxClip.Core.Services.VoiceLab;
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
    /// <summary>Returns the owner vector for the statement, then one scripted result per training sample in call order.</summary>
    private sealed class Embedder(params Func<float[]>[] results)
    {
        private int calls;
        internal int Calls => calls;
        internal Task<float[]> EmbedAsync(float[] pcm16k, CancellationToken ct)
        {
            ct.ThrowIfCancellationRequested();
            var index = calls++;
            return Task.FromResult(index == 0 ? [1f, 0f] : results[index - 1]());
        }
    }
    private static Func<float[]> Score(double cosine) => () => [(float)cosine, (float)Math.Sqrt(1 - cosine * cosine)];
    private static Func<float[]> TooLittleSpeech => () => throw new VoiceConsentException(VoiceConsentError.SpeakerMismatch);

    private static async Task<VoiceEnrollment.PreparedTraining> PrepareAsync(Transport transport, Embedder embedder, params VoiceTrainingSample[] samples)
    {
        using var client = ElevenLabsVoiceLab.ForTesting(new Keys(), transport, ElevenLabsRegion.Default);
        var statement = VoiceTrainingAudio.Wav(Tone(16000, 6), 16000);
        return await VoiceEnrollment.PrepareTrainingAsync(client, Guid.NewGuid().ToString("D"), " Example ", new("en", Statement, ["alpha", "beta", "gamma", "delta"]),
            statement, samples, 0.45, embedder.EmbedAsync, DateTimeOffset.UnixEpoch, Token);
    }

    [Fact]
    public void FrameLevelsFollowTheIntegerGridAndCountOnlyWholeFrames()
    {
        foreach (var rate in new[] { 8_000, 11_025, 22_050, 44_100, 48_000 })
        {
            var samples = Enumerable.Range(0, rate / 3 + 7).Select(index => (float)(0.25 * Math.Sin(index * 0.37) * (index % 997 == 0 ? 0 : 1))).ToArray();
            var levels = new VoiceTrainingLevels(rate);
            for (var start = 0; start < samples.Length; start += 333) levels.Append(samples.AsSpan(start, Math.Min(333, samples.Length - start)));
            var take = levels.Finish();
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
        Assert.Empty(silent.Finish().FrameDb);
        silent.Append(new float[221]);
        Assert.Equal(new[] { -180.0, -180.0 }, silent.Finish().FrameDb);
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
        Assert.Equal(frames, take.Samples); Assert.Equal(expected.Finish().FrameDb, take.FrameDb);
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
