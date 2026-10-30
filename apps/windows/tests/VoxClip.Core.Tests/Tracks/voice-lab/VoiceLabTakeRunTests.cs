using System.Text.Json;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.Speech;
using VoxClip.Core.Services.VoiceLab;
using VoxClip.Core.Tests.Tracks.WinAi;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.VoiceLab;

public sealed class VoiceLabTakeRunTests
{
    private sealed class Clock : TimeProvider
    {
        internal long Elapsed;
        internal DateTimeOffset Wall = DateTimeOffset.UnixEpoch;
        public override long TimestampFrequency => TimeSpan.TicksPerSecond;
        public override long GetTimestamp() => Elapsed;
        public override DateTimeOffset GetUtcNow() => Wall;
        internal void Advance(double seconds) => Elapsed += TimeSpan.FromSeconds(seconds).Ticks;
    }
    private static VoiceLabPreparedAction Prepare(VoiceLabActionGate gate, VoiceLabOperation operation, string fingerprint, Guid? id = null) =>
        gate.Prepare(fingerprint, new("elevenlabs", operation, 1, "call", 0.1m, null, "fixture"),
            new(operation, id ?? Guid.NewGuid(), "elevenlabs", ElevenLabsRegion.Default, "/fixture", null, null, null, null, "record"));
    private static VoiceLabTakeRunQuote Quote(VoiceLabActionGate gate) => new(Guid.NewGuid(), Enumerable.Range(0, 3).Select(index =>
        new VoiceLabTakeQuote(index, unchecked(uint.MaxValue + (uint)index), Prepare(gate, VoiceLabOperation.TextToSpeech, "speech" + index),
            Prepare(gate, VoiceLabOperation.SpeechToText, "qa" + index))).ToArray());
    [Fact]
    public void UnapprovedExpiresAtExactlyFiveElapsedMinutesDespiteWallClockChanges()
    {
        var clock = new Clock();
        var gate = new VoiceLabActionGate(clock);
        var quote = Quote(gate);
        clock.Wall = clock.Wall.AddDays(100);
        clock.Advance(299.999);
        Assert.True(gate.QuotesAreFresh(quote.Actions));
        clock.Wall = clock.Wall.AddDays(-200);
        clock.Advance(0.001);
        Assert.False(gate.QuotesAreFresh(quote.Actions));
        Assert.Throws<VoiceLabException>(() => gate.ApproveRun(quote.Id, quote.Actions, true));
    }
    [Fact]
    public void ApprovalBindsEveryQuoteAndDiscardsUnsentRemainderWithoutReusingIt()
    {
        var clock = new Clock();
        var gate = new VoiceLabActionGate(clock);
        var quote = Quote(gate);
        Assert.Equal(0.6m, quote.Estimate.Usd);
        Assert.Equal(new uint[] { uint.MaxValue, 0, 1 }, quote.Takes.Select(take => take.Seed));
        Assert.Throws<VoiceLabException>(() => gate.ApproveRun(quote.Id, quote.Actions, false));
        var authorizations = gate.ApproveRun(quote.Id, quote.Actions, true);
        clock.Advance(3600);
        Assert.Equal(quote.Takes[0].Synthesis.Review.RequestId, gate.Claim(authorizations[0], "speech0", VoiceLabOperation.TextToSpeech));
        Assert.Equal(quote.Takes[0].Qa.Review.RequestId, gate.Claim(authorizations[1], "qa0", VoiceLabOperation.SpeechToText));
        Assert.Throws<VoiceLabException>(() => gate.Claim(authorizations[0], "speech0", VoiceLabOperation.TextToSpeech));
        gate.DiscardRun(quote.Id, quote.Actions);
        Assert.Throws<VoiceLabException>(() => gate.Claim(authorizations[2], "speech1", VoiceLabOperation.TextToSpeech));
        Assert.Throws<VoiceLabException>(() => gate.ApproveRun(quote.Id, quote.Actions, true));
    }
    [Fact]
    public void RunRejectsDuplicateAndNonScribePairs()
    {
        var gate = new VoiceLabActionGate();
        var quote = Quote(gate);
        Assert.Throws<VoiceLabException>(() => gate.ApproveRun(Guid.NewGuid(), [quote.Actions[0], quote.Actions[0]], true));
        Assert.Throws<VoiceLabException>(() => gate.ApproveRun(Guid.NewGuid(), [quote.Actions[0], quote.Actions[2]], true));
    }
    [Fact]
    public void DispatchBindingInvalidatesTheAtomicStartBoundary()
    {
        var gate = new VoiceLabDispatchGate();
        var binding = gate.Capture();
        binding.Validate();
        gate.Invalidate();
        var started = false;
        Assert.Throws<VoiceLabRunInvalidatedException>(() => binding.Start(() => started = true));
        Assert.False(started);
    }
    [Fact]
    public void ScribeStatementPriceIsExposedThroughTheOperationApi()
    {
        using var client = ElevenLabsVoiceLab.ForTesting(new MemoryKeys(), new HttpClientHandler(), ElevenLabsRegion.Default);
        var price = client.Estimate(VoiceLabOperation.SpeechToText, "scribe_v2", 30);
        Assert.Equal("speechToText", price.Operation);
        Assert.Equal(0.0018333333m, price.Usd);
        Assert.True(price.Usd < 0.01m);
        var quote = client.PrepareQa("en", "record", Guid.NewGuid());
        Assert.Equal(290, quote.Estimate.Units);
        Assert.Equal("scribe_v2", quote.Review.ModelId);
        Assert.Equal("/v1/speech-to-text", quote.Review.Endpoint);
    }
    [Fact]
    public void SharedTakeRunQualityAndRankingReplay()
    {
        using var document = JsonDocument.Parse(FixtureLoader.ReadText("fixtures/voice-lab/take-run-cases.json"));
        var root = document.RootElement;
        Assert.Equal("voxclip-take-run-cases/1", root.GetProperty("schema").GetString());
        foreach (var row in root.GetProperty("ranking").EnumerateArray())
        {
            var window = row.GetProperty("window").GetDouble();
            var residual = row.GetProperty("residual").GetDouble();
            var plan = new VoiceLabFitPlan([], new(0, 0), new(0, 0), 0, (long)((window + residual) * 24000), 0, window, 0, (long)(window * 24000),
                (long)((window + residual) * 24000), []);
            VoiceLabFitResult fit = residual == 0 ? new VoiceLabFitResult.Exact(plan) : new VoiceLabFitResult.ChangedDuration(plan, window + residual, residual);
            Assert.Equal(row.GetProperty("score").GetDouble(), VoiceLabTakeQuality.Rank(fit, window, row.GetProperty("match").GetDouble(), row.GetProperty("flatness").GetDouble()), 12);
        }
        foreach (var row in root.GetProperty("qa").EnumerateArray())
        {
            var amplitude = row.GetProperty("amplitude").GetDouble();
            var hasJump = row.TryGetProperty("afterAmplitude", out var after);
            var samples = Enumerable.Range(0, 16000).Select(index => (float)((index >= 8000 && hasJump ? after.GetDouble() : amplitude) * Math.Sin(2 * Math.PI * 220 * index / 16000))).ToArray();
            var result = VoiceLabTakeQuality.Evaluate(row.GetProperty("expected").GetString()!, row.GetProperty("recognized").EnumerateArray().Select(token => token.GetString()!).ToArray(),
                samples, 16000, hasJump ? [8000] : [], row.GetProperty("speaker").GetDouble(), 0.45);
            Assert.Equal(row.GetProperty("failures").EnumerateArray().Select(value => value.GetString()), result.Failures.Select(value => value.ToString().ToLowerInvariant()));
        }
        Assert.Equal(3, root.GetProperty("run").GetProperty("candidates").GetInt32());
        Assert.Equal(VoiceLabTakeProcessing.MaximumQaSeconds, root.GetProperty("run").GetProperty("qaMaximumSeconds").GetInt32());
    }
}
