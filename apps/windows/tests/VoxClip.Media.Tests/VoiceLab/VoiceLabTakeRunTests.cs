using System.Buffers.Binary;
using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.LLM;
using VoxClip.Core.Services.Project;
using VoxClip.Core.Services.Speech;
using VoxClip.Core.Services.VoiceLab;
using VoxClip.Media.VoiceLab;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Media.Tests.VoiceLab;

public sealed class VoiceLabTakeRunTests
{
    private static CancellationToken Token => TestContext.Current.CancellationToken;
    private sealed class Clock : TimeProvider
    {
        internal long Elapsed;
        public override long TimestampFrequency => TimeSpan.TicksPerSecond;
        public override long GetTimestamp() => Elapsed;
        public override DateTimeOffset GetUtcNow() => DateTimeOffset.UnixEpoch;
        internal void Advance(double seconds) => Elapsed += TimeSpan.FromSeconds(seconds).Ticks;
    }
    private sealed class Keys : IKeyProvider
    {
        internal Func<CancellationToken, Task>? Suspension;
        public async Task<string?> GetKeyAsync(string account, CancellationToken ct)
        {
            if (Suspension is { } pause) await pause(ct);
            return "synthetic-take-key";
        }
    }
    private sealed class Remote : HttpMessageHandler
    {
        internal readonly List<uint> Seeds = [];
        internal readonly List<byte[]> QaWavs = [];
        internal int Qa;
        internal int FirstStatus = 200;
        internal int Mismatches;
        internal double Duration = 4;
        internal bool MissingAlignment;
        private static HttpResponseMessage Json(object value, int status = 200) => new((HttpStatusCode)status) { Content = new StringContent(JsonSerializer.Serialize(value), Encoding.UTF8, "application/json") };
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            var path = request.RequestUri!.AbsolutePath;
            if (path == "/v1/models") return Json(new[] { new { model_id = "eleven_v3", name = "Fixture", can_do_text_to_speech = true,
                can_do_voice_conversion = false, languages = new[] { new { language_id = "en" } }, model_rates = new { character_cost_multiplier = 1 } } });
            if (path == "/v2/voices") return Json(new { voices = new[] { new { voice_id = "fixtureOwnVoice", name = "Fixture", category = "cloned", is_owner = true } }, has_more = false });
            var bytes = await request.Content!.ReadAsByteArrayAsync(ct);
            if (path.StartsWith("/v1/text-to-speech/", StringComparison.Ordinal))
            {
                var body = JsonNode.Parse(bytes)!;
                Seeds.Add(body["seed"]!.GetValue<uint>());
                Assert.Null(body["previous_text"]);
                Assert.Null(body["next_text"]);
                if (Seeds.Count == 1 && FirstStatus != 200) return Json(new { }, FirstStatus);
                var pcm = new byte[(int)(Duration * 24000) * 2];
                for (var index = 0; index < pcm.Length / 2; index++) BinaryPrimitives.WriteInt16LittleEndian(pcm.AsSpan(index * 2), (short)Math.Round(Math.Sin(2 * Math.PI * 100 * index / 24000) * 3200));
                var characters = "Hello".Select(character => character.ToString()).ToArray();
                return Json(new { audio_base64 = Convert.ToBase64String(pcm), alignment = MissingAlignment ? null : new
                {
                    characters, character_start_times_seconds = Enumerable.Range(0, 5).Select(index => 0.1 + index * (Duration - 0.2) / 5).ToArray(),
                    character_end_times_seconds = Enumerable.Range(0, 5).Select(index => 0.1 + (index + 1) * (Duration - 0.2) / 5).ToArray()
                } });
            }
            Assert.Equal("/v1/speech-to-text", path);
            Qa++;
            var text = Encoding.Latin1.GetString(bytes);
            foreach (var field in new[] { ("model_id", "scribe_v2"), ("language_code", "en"), ("diarize", "false"), ("tag_audio_events", "false"), ("timestamps_granularity", "word") })
                Assert.Contains("name=\"" + field.Item1 + "\"\r\n\r\n" + field.Item2 + "\r\n", text);
            var offset = bytes.AsSpan().IndexOf("RIFF"u8);
            Assert.True(offset >= 0);
            var size = BinaryPrimitives.ReadInt32LittleEndian(bytes.AsSpan(offset + 4)) + 8;
            QaWavs.Add(bytes.AsSpan(offset, size).ToArray());
            return Json(new { language_code = "eng", words = new[] { new { type = "word", text = Qa <= Mismatches ? "different" : "Hello", start = 0.65, end = Duration + 0.35 } } });
        }
    }
    private sealed class Fixture : IAsyncDisposable
    {
        internal readonly string Root = Path.Combine(Path.GetTempPath(), "voxclip-takes-" + Guid.NewGuid().ToString("N"));
        internal readonly Remote Remote = new();
        internal readonly Keys Keys = new();
        internal readonly Clock Clock = new();
        internal readonly VoiceLabDispatchGate Gate = new();
        internal readonly VoiceConsentStore Store;
        internal readonly ElevenLabsVoiceLab Client;
        internal readonly VoiceLabSpendLedger Ledger;
        internal readonly VoiceLabTakeRun Run;
        internal readonly VoiceLabTakeInput Input;
        internal readonly VoiceConsentRecord Record;
        internal bool SpeakerFailure;
        internal bool Current = true;
        internal Fixture()
        {
            Directory.CreateDirectory(Root);
            var locations = new DataLocations(Root, Path.Combine(Root, "settings.json"), Path.Combine(Root, "Models"), Path.Combine(Root, "Cache"),
                Path.Combine(Root, "Autosave"), Path.Combine(Root, "Secrets"), Path.Combine(Root, "Logs"));
            Store = new(locations);
            var wav = VoiceTrainingAudio.Wav(Enumerable.Range(0, 48000 * 6).Select(index => (float)(0.1 * Math.Sin(2 * Math.PI * 100 * index / 48000))).ToArray());
            Record = JsonSerializer.Deserialize(FixtureLoader.ReadText("fixtures/voice-lab/consent-record.json"), VoiceConsentJson.Default.VoiceConsentRecord)!;
            Record = Record with { RecordId = Guid.NewGuid().ToString("D"), Speaker = Record.Speaker with { Embedding = VoiceConsentRecord.EncodeEmbedding([1f, 0f]), Threshold = 0.45 },
                Statement = Record.Statement with { AudioSha256 = VoiceConsentStore.Hash(wav) } };
            Store.SaveStatement(wav, Record.RecordId); Store.Save(Record);
            Ledger = new(locations);
            Client = ElevenLabsVoiceLab.ForTesting(Keys, Remote, ElevenLabsRegion.Default, clock: Clock, spend: Ledger);
            var checks = new VoiceLabTakeRunChecks(_ => { }, (record, _, request, binding, model, ct) =>
            {
                ct.ThrowIfCancellationRequested(); Store.ValidateUse(record);
                return Task.FromResult(new OwnVoicePolicy(record.RecordId, record.VoiceId, true, true, true, true, true)
                {
                    DispatchPermit = new(Store, record.RecordId, request, () => Store.ValidateUse(record), binding),
                    ValidateDispatch = _ => Task.CompletedTask, ModelRevision = model
                });
            }, (_, _, ct) => { ct.ThrowIfCancellationRequested(); return Task.FromResult(SpeakerFailure ? new float[] { 0, 1 } : [1f, 0f]); });
            Run = new(Client, Store, new(Guid.NewGuid().ToString("D"), Path.Combine(Root, "Paid"), Path.Combine(Root, "scratch")), Gate,
                _ => Task.FromResult(Current), checks);
            var source = Enumerable.Range(0, 24000 * 8).Select(index =>
            {
                var seconds = index / 24000.0;
                return seconds is >= 1.9 and < 2.1 or >= 5.9 and < 6.1 or >= 6.5 and < 7.1 ? 0.001f : (float)(0.1 * Math.Sin(2 * Math.PI * 100 * seconds));
            }).ToArray();
            TimedWord Word(string id, double start, double end) => new(id, id, WordKind.Word, start, end, null, null, 1, "one", TimingSource.Native);
            var window = new VoiceLabWindow("old", "old", [], [], 2, 6, 48000, 144000, new(VoiceLabSeamKind.Hard, 2, 48000, 288), new(VoiceLabSeamKind.Hard, 6, 144000, 288));
            Input = new("Hello", "eleven_v3", Record.RecordId, "en", uint.MaxValue, "synthetic-source", source, 24000,
                [Word("before", 0, 1.9), Word("old", 2.1, 5.9), Word("after", 6.1, 6.5), Word("last", 7.1, 7.9)], new HashSet<string>(), window, null, null, false, true);
        }
        internal async Task<VoiceLabTakeRunQuote> Prepare()
        {
            await Client.DiscoverModelsAsync(Token); await Client.DiscoverVoicesAsync(Token);
            return await Run.PrepareAsync(Input, Token);
        }
        public async ValueTask DisposeAsync() { await Run.CancelAsync(); Client.Dispose(); Remote.Dispose(); Directory.Delete(Root, true); }
    }
    [Fact]
    public async Task OneApprovalStopsAtFirstPassingExactFitAndLedgersOnlySentQuotes()
    {
        await using var fixture = new Fixture();
        var quote = await fixture.Prepare();
        var result = await fixture.Run.ExecuteAsync(quote, true, ct: Token);
        Assert.Equal(VoiceLabTakeRunEnd.EarlyStop, result.End);
        var row = Assert.Single(result.Rows);
        Assert.True(row.Selectable, row.Failure?.ToString());
        Assert.True(row.Fits);
        Assert.Equal(new uint[] { uint.MaxValue }, fixture.Remote.Seeds);
        Assert.Equal(1, fixture.Remote.Qa);
        Assert.Equal(93360, row.Audio!.Trimmed.Length);
        Assert.Equal(96000, row.Audio.Fit.Plan.OutputFrames);
        var total = await fixture.Ledger.TotalAsync("elevenlabs", DateTimeOffset.UnixEpoch, Token);
        Assert.Equal(quote.Takes[0].Synthesis.Estimate.Usd + quote.Takes[0].Qa.Estimate.Usd, total!.Usd);
        Assert.False(fixture.Client.QuotesAreFresh(quote.Actions));
        await Assert.ThrowsAsync<VoiceLabException>(() => fixture.Run.ExecuteAsync(quote, true, ct: Token));
        var paid = fixture.Run.PaidAsset(row.Id)!;
        var scratch = fixture.Run.Scratch(row.Id)!;
        await fixture.Run.RejectAsync(row.Id);
        Assert.False(scratch.IsValid);
        Assert.NotNull(paid);
        Assert.NotEmpty(Directory.GetFiles(Path.Combine(fixture.Root, "Paid"), "*.wav", SearchOption.AllDirectories));
    }
    [Theory]
    [InlineData("clock")]
    [InlineData("inputs")]
    [InlineData("model")]
    [InlineData("speaker")]
    [InlineData("consent")]
    [InlineData("record")]
    [InlineData("validation")]
    [InlineData("approval")]
    [InlineData("launch")]
    [InlineData("authorization")]
    public async Task CancelAtEverySuspensionNeverStartsAnUnsentRequest(string point)
    {
        await using var fixture = new Fixture();
        var quote = await fixture.Prepare();
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var resume = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        fixture.Run.Suspension = async name => { if (name == point) { entered.TrySetResult(); await resume.Task; } };
        var sending = fixture.Run.ExecuteAsync(quote, true, ct: Token);
        await entered.Task.WaitAsync(Token);
        await fixture.Run.CancelAsync();
        resume.SetResult();
        _ = await Record.ExceptionAsync(async () => await sending);
        Assert.Empty(fixture.Remote.Seeds);
        Assert.Equal(0, fixture.Remote.Qa);
        Assert.False(fixture.Client.QuotesAreFresh(quote.Actions));
    }
    [Theory]
    [InlineData("clock")]
    [InlineData("approval")]
    public async Task ConcurrentExecutionCannotDiscardOwnerQuotes(string point)
    {
        await using var fixture = new Fixture();
        var quote = await fixture.Prepare();
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var resume = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var visited = 0;
        fixture.Run.Suspension = async name => { if (name == point && Interlocked.Increment(ref visited) == 1) { entered.SetResult(); await resume.Task; } };
        var first = fixture.Run.ExecuteAsync(quote, true, ct: Token);
        await entered.Task.WaitAsync(Token);
        await Assert.ThrowsAsync<VoiceLabException>(() => fixture.Run.ExecuteAsync(quote, true, ct: Token));
        Assert.True(fixture.Client.QuotesAreFresh(quote.Actions));
        resume.SetResult();
        Assert.Equal(VoiceLabTakeRunEnd.EarlyStop, (await first).End);
    }
    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task InputRevisionAndWithdrawalWinAtActualTransportBoundary(bool withdraw)
    {
        await using var fixture = new Fixture();
        var quote = await fixture.Prepare();
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var resume = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        fixture.Keys.Suspension = async _ => { entered.TrySetResult(); await resume.Task; };
        var sending = fixture.Run.ExecuteAsync(quote, true, ct: Token);
        await entered.Task.WaitAsync(Token);
        if (withdraw) fixture.Store.BeginDeletion(fixture.Record.RecordId, ElevenLabsRegion.Default, DateTimeOffset.UtcNow);
        else fixture.Gate.Invalidate();
        resume.SetResult();
        var result = await sending;
        Assert.Empty(fixture.Remote.Seeds);
        Assert.NotEqual(VoiceLabTakeRunEnd.EarlyStop, result.End);
        Assert.Empty((await fixture.Ledger.ReadAsync(Token))!.Months);
    }
    [Fact]
    public async Task CompletedPaidResponseSurvivesCancellationBeforeQa()
    {
        await using var fixture = new Fixture();
        fixture.Run.Suspension = name => name == "synthesis" ? fixture.Run.CancelAsync() : Task.CompletedTask;
        var result = await fixture.Run.ExecuteAsync(await fixture.Prepare(), true, ct: Token);
        Assert.Equal(VoiceLabTakeRunEnd.Cancelled, result.End);
        Assert.Single(fixture.Remote.Seeds);
        Assert.Equal(0, fixture.Remote.Qa);
        Assert.Single(Directory.GetFiles(Path.Combine(fixture.Root, "Paid"), "*.wav", SearchOption.AllDirectories));
    }
    [Fact]
    public async Task WithdrawalAfterScratchPreventsScribeDispatch()
    {
        await using var fixture = new Fixture();
        fixture.Run.Suspension = name =>
        {
            if (name == "qaAuthorization") fixture.Store.BeginDeletion(fixture.Record.RecordId, ElevenLabsRegion.Default, DateTimeOffset.UtcNow);
            return Task.CompletedTask;
        };
        var result = await fixture.Run.ExecuteAsync(await fixture.Prepare(), true, ct: Token);
        Assert.Single(fixture.Remote.Seeds);
        Assert.Equal(0, fixture.Remote.Qa);
        Assert.False(Assert.Single(result.Rows).Selectable);
    }
    [Fact]
    public async Task ModelDiscoveryChangeWinsWhileTransportIsSuspended()
    {
        await using var fixture = new Fixture();
        var quote = await fixture.Prepare();
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var resume = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        fixture.Keys.Suspension = async _ => { entered.TrySetResult(); await resume.Task; };
        var sending = fixture.Run.ExecuteAsync(quote, true, ct: Token);
        await entered.Task.WaitAsync(Token);
        fixture.Keys.Suspension = null;
        await fixture.Client.DiscoverModelsAsync(Token);
        resume.SetResult();
        Assert.Equal(VoiceLabTakeRunEnd.Invalidated, (await sending).End);
        Assert.Empty(fixture.Remote.Seeds);
    }
    [Fact]
    public async Task PreparedInputOwnsItsAudioSnapshot()
    {
        await using var fixture = new Fixture();
        var quote = await fixture.Prepare();
        Array.Fill(fixture.Input.Source, float.NaN);
        Assert.Equal(VoiceLabTakeRunEnd.EarlyStop, (await fixture.Run.ExecuteAsync(quote, true, ct: Token)).End);
    }
    [Fact]
    public async Task InvalidPreflightNeverPreparesAPaidRun()
    {
        await using var fixture = new Fixture();
        await fixture.Client.DiscoverModelsAsync(Token); await fixture.Client.DiscoverVoicesAsync(Token);
        await Assert.ThrowsAsync<VoiceLabException>(() => fixture.Run.PrepareAsync(fixture.Input with { ProviderConsent = false }, Token));
        Assert.Empty(fixture.Remote.Seeds);
        Assert.Equal(0, fixture.Remote.Qa);
    }
    [Fact]
    public async Task UnapprovedRunExpiresWithoutSendingOrSpending()
    {
        await using var fixture = new Fixture();
        var quote = await fixture.Prepare();
        fixture.Clock.Advance(300);
        await Assert.ThrowsAsync<VoiceLabException>(() => fixture.Run.ExecuteAsync(quote, true, ct: Token));
        Assert.Empty(fixture.Remote.Seeds);
        Assert.Empty((await fixture.Ledger.ReadAsync(Token))!.Months);
    }
    [Theory]
    [InlineData(401, 1)]
    [InlineData(500, 2)]
    public async Task FatalVersusNonfatalProviderFailureRemainsARow(int status, int sent)
    {
        await using var fixture = new Fixture();
        fixture.Remote.FirstStatus = status;
        var result = await fixture.Run.ExecuteAsync(await fixture.Prepare(), true, ct: Token);
        Assert.Equal(sent, fixture.Remote.Seeds.Count);
        Assert.NotNull(result.Rows[0].Failure);
        Assert.False(result.Rows[0].Selectable);
        Assert.Equal(status == 401 ? VoiceLabTakeRunEnd.Fatal : VoiceLabTakeRunEnd.EarlyStop, result.End);
    }
    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task SpeakerAndScribeFailuresCannotBeSelected(bool speaker)
    {
        await using var fixture = new Fixture();
        fixture.SpeakerFailure = speaker; fixture.Remote.Mismatches = 3;
        var result = await fixture.Run.ExecuteAsync(await fixture.Prepare(), true, ct: Token);
        Assert.Equal(3, result.Rows.Count);
        Assert.All(result.Rows, row => Assert.False(row.Selectable));
        Assert.Null(result.Best);
    }
    [Fact]
    public async Task ApprovedRemainderSurvivesExpiryButChangedInputsStopAndDiscardIt()
    {
        await using var fixture = new Fixture();
        fixture.Remote.Mismatches = 1;
        var quote = await fixture.Prepare();
        var result = await fixture.Run.ExecuteAsync(quote, true, rows => { fixture.Clock.Advance(3600); return Task.CompletedTask; }, Token);
        Assert.Equal(VoiceLabTakeRunEnd.EarlyStop, result.End);
        Assert.Equal(new uint[] { uint.MaxValue, 0 }, fixture.Remote.Seeds);
        Assert.Equal(2, fixture.Remote.Qa);
        var second = await fixture.Run.PrepareAsync(fixture.Input, Token);
        fixture.Remote.Mismatches = 100;
        var stopped = await fixture.Run.ExecuteAsync(second, true, rows => { fixture.Current = false; fixture.Gate.Invalidate(); return Task.CompletedTask; }, Token);
        Assert.Equal(VoiceLabTakeRunEnd.Invalidated, stopped.End);
        Assert.Equal(3, fixture.Remote.Seeds.Count);
        Assert.False(fixture.Client.QuotesAreFresh(second.Actions));
    }
    [Theory]
    [InlineData(2.0, false)]
    [InlineData(4.5, false)]
    [InlineData(4.0, true)]
    public async Task ShortChangedDurationAndMissingAlignmentNeverPretendToFit(double seconds, bool missing)
    {
        await using var fixture = new Fixture();
        fixture.Remote.Duration = seconds; fixture.Remote.MissingAlignment = missing;
        var result = await fixture.Run.ExecuteAsync(await fixture.Prepare(), true, ct: Token);
        Assert.Equal(3, result.Rows.Count);
        if (seconds == 4.5) Assert.All(result.Rows, row => { Assert.True(row.Selectable); Assert.False(row.Fits); });
        else Assert.All(result.Rows, row => Assert.False(row.Selectable));
        if (seconds == 2 || missing) Assert.Equal(0, fixture.Remote.Qa);
    }
}
