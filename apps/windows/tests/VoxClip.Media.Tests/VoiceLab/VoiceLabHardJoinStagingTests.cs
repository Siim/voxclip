using System.Buffers.Binary;
using System.Text.Json;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Media.VoiceLab;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Media.Tests.VoiceLab;

public sealed class VoiceLabHardJoinStagingTests
{
    [Theory]
    [InlineData(0.1)]
    [InlineData(0.07)]
    [InlineData(0.01)]
    public async Task GainIsGatedAndNeverBaked(double amplitude)
    {
        using var document = JsonDocument.Parse(FixtureLoader.ReadText("fixtures/voice-lab/hard-join-cases.json"));
        var row = document.RootElement.GetProperty("gating").EnumerateArray().Single(item => item.GetProperty("amplitude").GetDouble() == amplitude);
        var root = Path.Combine(Path.GetTempPath(), "voxclip-hardjoin-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            const int rate = 24000;
            var window = new VoiceLabWindow("w", "w", [], [], 2, 3, 48000, 72000,
                new(VoiceLabSeamKind.Hard, 2, 48000, 288), new(VoiceLabSeamKind.Hard, 3, 72000, 288));
            if (amplitude == 0.07)
                window = window with { End = 3 + 1.0 / 48000, EndSample = 72001,
                    RightSeam = window.RightSeam with { Time = 3 + 1.0 / 48000, Sample = 72001 } };
            var samples = Enumerable.Range(0, rate).Select(index => (float)(amplitude * Math.Sin(2 * Math.PI * 1000 * index / rate))).ToArray();
            var source = Enumerable.Range(0, rate * 5).Select(index => (float)(0.1 * Math.Sin(2 * Math.PI * 1000 * index / rate))).ToArray();
            VoiceLabWord[] words = [new("new", 0.14, 0.4, true), new("words", 0.6, 0.86, true)];
            var take = new VoiceLabFitTake(rate, rate, 0, 1, words, VoiceLabTakeProcessing.Envelope(samples, rate));
            var fit = VoiceLabFitPlanner.Plan(window, null, null, take, ["new", "words"], rate, true);
            var pcm = new byte[rate * 4];
            for (var index = 0; index < rate; index++) BinaryPrimitives.WriteSingleLittleEndian(pcm.AsSpan(index * 4), samples[index]);
            const string project = "5b7e0f7a-3c1d-4b8e-9a51-2f6d0c8e4a11";
            var paid = VoiceLabAssetStore.WriteWave(pcm, rate, 1, 32, true, project, "paid", root, DateTimeOffset.UnixEpoch, TestContext.Current.CancellationToken);
            var snapshot = await VoiceLabAssets.PreparePaidAsync(paid, project, root, root, TestContext.Current.CancellationToken);
            var fitted = VoiceLabSilenceFit.Prepare(snapshot, paid, fit, window, rate, TestContext.Current.CancellationToken);
            var before = fitted.Wave.Bytes();
            var input = new VoiceLabTakeInput("new words", "fixture", "fixture", "en", 1, "fixture", source, rate, [], new HashSet<string>(), window, null, null, true, true);
            var analysis = new VoiceLabTakeAnalysis(rate, samples, 0, null, fit);
            await using var scratch = VoiceLabTakeRenderer.Stage(fitted, analysis, input, VoiceLabSourceExcerpt.Whole(source), root, TestContext.Current.CancellationToken);
            Assert.Equal(before, fitted.Wave.Bytes());
            Assert.NotNull(scratch.Audio.MicroPauseIn);
            Assert.NotNull(scratch.Audio.MicroPauseOut);
            Assert.Equal(VoiceLabHardJoin.Pause(fit.Plan.Words, fitted.OutDuration, false), scratch.Audio.MicroPauseOut);
            Assert.Equal(row.GetProperty("gain").GetBoolean(), scratch.Audio.EdgeGain is not null);
            if (scratch.Audio.EdgeGain is { } gain)
            {
                Assert.InRange(gain.In!.GainDb, 0, 6);
                Assert.InRange(gain.Out!.GainDb, 0, 6);
            }
            var audio = scratch.Audio;
            var qa = VoiceLabTakeQuality.Evaluate("new words", ["new", "words"], audio.Mixed, rate, audio.Seams, 1, 0.5, seamExcesses: audio.SeamExcesses);
            Assert.DoesNotContain(qa.Failures, failure => failure != VoiceLabTakeQaFailure.Loudness);
            Assert.Equal(row.GetProperty("advisory").GetBoolean(), qa.Failures.Contains(VoiceLabTakeQaFailure.Loudness));
            var failed = VoiceLabTakeQuality.Evaluate("new words", ["wrong"], audio.Mixed, rate, audio.Seams, 0, 0.5, seamExcesses: audio.SeamExcesses);
            Assert.Equal(VoiceLabTakeQaVerdict.Failed, failed.Verdict);
        }
        finally { Directory.Delete(root, true); }
    }
}
