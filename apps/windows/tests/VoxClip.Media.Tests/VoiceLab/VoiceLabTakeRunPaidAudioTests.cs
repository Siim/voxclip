using System.Text.Json.Nodes;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Media.Audio;
using VoxClip.Media.VoiceLab;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Media.Tests.VoiceLab;

public sealed partial class VoiceLabTakeRunTests
{
    [Theory]
    [InlineData("eleven_v4", "alignment_null", VoiceLabErrorKind.InvalidAlignment, true)]
    [InlineData("eleven_v4", "segments_wrong_voice", VoiceLabErrorKind.MalformedResponse, true)]
    [InlineData("eleven_v3", "alignment_null", VoiceLabErrorKind.InvalidAlignment, true)]
    [InlineData("eleven_v4", "alignment_null", VoiceLabErrorKind.InvalidAudio, false)]
    [InlineData("eleven_v3", "alignment_null", VoiceLabErrorKind.InvalidAudio, false)]
    public async Task FailedSynthesisPreservesOnlyValidatedPaidPcm(string model, string name, VoiceLabErrorKind kind, bool validPcm)
    {
        var cases = JsonNode.Parse(FixtureLoader.ReadText("fixtures/voice-lab/dialogue-cases.json"))!;
        var response = cases["responses"]!.AsArray().Single(row => row!["case"]!.GetValue<string>() == name)!["response"]!.DeepClone();
        if (!validPcm) response["audio_base64"] = Convert.ToBase64String(new byte[1]);
        var pcm = Convert.FromBase64String(response["audio_base64"]!.GetValue<string>());
        await using var fixture = new Fixture(input => input with { ModelId = model, Text = "Hi" });
        fixture.Remote.SynthesisResponse = response;
        fixture.Remote.SynthesisText = "Hi";
        var quote = await fixture.Prepare();
        using var cancellation = CancellationTokenSource.CreateLinkedTokenSource(Token);
        // Stop after this independently approved candidate; do not send the next two candidates.
        var result = await fixture.Run.ExecuteAsync(quote, true, rows =>
        {
            if (rows.Count > 0)
            {
                Assert.Single(rows);
                cancellation.Cancel();
            }
            return Task.CompletedTask;
        }, cancellation.Token);
        var row = Assert.Single(result.Rows);
        Assert.Equal(kind, Assert.IsType<VoiceLabException>(row.Failure).Kind);
        Assert.False(row.Selectable);
        Assert.Empty(result.Ranked);
        Assert.Null(result.Best);
        Assert.Null(row.Audio);
        Assert.Null(row.Qa);
        Assert.Null(fixture.Run.Scratch(row.Id));
        var refusal = await Assert.ThrowsAsync<VoiceLabException>(() => fixture.Run.PublishForAcceptanceAsync(row.Id, DateTimeOffset.UtcNow, Token));
        Assert.Equal(VoiceLabErrorKind.ConsentRequired, refusal.Kind);
        Assert.Equal(row.Id, Assert.Single(row.AcceptedRequestIds));
        Assert.Equal(quote.Takes[0].Synthesis.Estimate.Usd,
            (await fixture.Ledger.TotalAsync("elevenlabs", DateTimeOffset.UnixEpoch, Token))!.Usd);
        Assert.Single(fixture.Remote.Seeds);
        Assert.Equal(0, fixture.Remote.Qa);
        var paidRoot = Path.Combine(fixture.Root, "Paid");
        var files = Directory.Exists(paidRoot) ? Directory.GetFiles(paidRoot, "*.wav", SearchOption.AllDirectories) : [];
        if (!validPcm)
        {
            Assert.Null(fixture.Run.PaidAsset(row.Id));
            Assert.Null(row.Generated);
            Assert.Null(row.Receipt);
            Assert.Empty(files);
            return;
        }
        Assert.NotNull(fixture.Run.PaidAsset(row.Id));
        var wav = await File.ReadAllBytesAsync(Assert.Single(files), Token);
        Assert.Equal(pcm, wav[44..]);
        Assert.NotNull(row.Generated);
        Assert.Equal(pcm, row.Generated.Pcm);
        Assert.Null(row.Generated.Alignment);
        Assert.Equal(24000, row.Generated.SampleRate);
        Assert.Equal(row.Generated.Receipt, row.Receipt);
        Assert.Equal(row.Id, row.Receipt!.ActionId);
        Assert.Equal(model, row.Receipt.ModelId);
        Assert.Equal("paid-speech-request", row.Receipt.ProviderRequestId);
        Assert.Equal(model == "eleven_v4" ? "/v1/text-to-dialogue/with-timestamps" : "/v1/text-to-speech/fixtureOwnVoice/with-timestamps", row.Receipt.Endpoint);
        var paid = fixture.Run.PaidAsset(row.Id)!;
        var snapshot = await VoiceLabAssets.PreparePaidAsync(paid, paid.File.Split('/')[0], paidRoot, Path.Combine(fixture.Root, "audition"), Token);
        var endpoint = new PaidEndpoint();
        await using var audition = new VoiceLabAudition(() => endpoint, _ => Task.CompletedTask);
        Assert.True(await audition.PlayAsync(snapshot, row.Id, "phrase", Token));
        Assert.Equal(snapshot.Path, endpoint.Path);
        Assert.Equal(pcm, (await File.ReadAllBytesAsync(endpoint.Path!, Token))[44..]);
        Assert.False(row.Selectable); Assert.Null(result.Best); Assert.Null(fixture.Run.Scratch(row.Id));
        refusal = await Assert.ThrowsAsync<VoiceLabException>(() => fixture.Run.PublishForAcceptanceAsync(row.Id, DateTimeOffset.UtcNow, Token));
        Assert.Equal(VoiceLabErrorKind.ConsentRequired, refusal.Kind);
        await audition.StopAsync();
        Assert.False(snapshot.IsValid); Assert.False(File.Exists(snapshot.Path)); Assert.True(File.Exists(files[0]));
        Assert.Single(fixture.Remote.Seeds); Assert.Equal(0, fixture.Remote.Qa);
    }

    [Fact]
    public async Task FailedCheckedMixPlaysButPublicationStillRefusesIt()
    {
        await using var fixture = new Fixture(); fixture.Remote.Mismatches = 3;
        var result = await fixture.Run.ExecuteAsync(await fixture.Prepare(), true, ct: Token);
        var row = result.Rows[0]; var scratch = fixture.Run.Scratch(row.Id)!;
        Assert.False(row.Selectable); Assert.Null(result.Best);
        var endpoint = new PaidEndpoint();
        await using var audition = new VoiceLabAudition(() => endpoint, _ => Task.CompletedTask);
        Assert.True(await audition.PlayAsync(scratch, row.Id, "phrase", Token));
        Assert.Equal(scratch.MixedAudioPath, endpoint.Path);
        var refusal = await Assert.ThrowsAsync<VoiceLabException>(() => fixture.Run.PublishForAcceptanceAsync(row.Id, DateTimeOffset.UtcNow, Token));
        Assert.Equal(VoiceLabErrorKind.ConsentRequired, refusal.Kind);
        Assert.False(row.Selectable); Assert.Null(result.Best);
        await audition.StopAsync(); Assert.True(scratch.IsValid);
    }

    private sealed class PaidEndpoint : IVoiceLabRenderEndpoint
    {
        private readonly TaskCompletionSource done = new(TaskCreationOptions.RunContinuationsAsynchronously);
        internal string? Path;
        public Task<string?> CheckAvailabilityAsync(CancellationToken ct) => Task.FromResult<string?>(null);
        public Task OpenAsync(string path, CancellationToken ct) { Path = path; return Task.CompletedTask; }
        public Task PlayAsync(CancellationToken ct) => Task.CompletedTask;
        public Task Completion => done.Task;
        public TimeSpan Position => TimeSpan.Zero;
        public ValueTask DisposeAsync() { done.TrySetResult(); return ValueTask.CompletedTask; }
    }
}
