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
    [Fact]
    public async Task UnreadableSpendAtTransportKeepsReviewAndExposesPreparationRetry()
    {
        await using var fixture = new Fixture();
        await fixture.Prepare();
        var session = new VoiceLabGenerationSession(fixture.Run);
        await session.UpdateInputsAsync(fixture.Input, ct: Token); await session.ContinueAsync(Token);
        var previous = session.Rows;
        var scratch = fixture.Run.Scratch(previous[0].Id)!;
        await session.UpdateInputsAsync(fixture.Input, new(0.10m, 0), Token);
        fixture.Keys.Suspension = _ => { fixture.Keys.Suspension = null; File.WriteAllText(fixture.Ledger.FilePath, "not json"); return Task.CompletedTask; };
        await Assert.ThrowsAsync<VoiceLabException>(() => session.ContinueAsync(Token));
        Assert.Same(previous, session.Rows); Assert.True(scratch.IsValid);
        Assert.Single(fixture.Remote.Seeds);
        Assert.Null(session.PendingQuote); Assert.NotNull(session.PreparationFailure);
        File.Delete(fixture.Ledger.FilePath);
        await session.UpdateInputsAsync(fixture.Input, new(0.10m, 0), Token);
        Assert.NotNull(session.PendingQuote); Assert.NotNull(session.Cost); Assert.Null(session.PreparationFailure);
    }
    [Fact]
    public async Task CancellationDuringFirstTransportConfirmationWaitsAndKeepsPlayingReview()
    {
        await using var fixture = new Fixture();
        await fixture.Prepare();
        var session = new VoiceLabGenerationSession(fixture.Run);
        await session.UpdateInputsAsync(fixture.Input, ct: Token); await session.ContinueAsync(Token);
        var previous = session.Rows;
        var scratch = fixture.Run.Scratch(previous[0].Id)!;
        var playing = true;
        using var consumer = scratch.AttachConsumer(() => { playing = false; return Task.CompletedTask; });
        session.SelectTake(previous[0].Id); session.AuditionTake(previous[0].Id);
        var confirm = typeof(VoiceLabGenerationSession).GetProperty("ConfirmCostAsync");
        var cancel = typeof(VoiceLabGenerationSession).GetMethod("CancelAsync", Type.EmptyTypes);
        Assert.NotNull(confirm); Assert.NotNull(cancel);
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var resume = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        confirm.SetValue(session, (Func<string, CancellationToken, Task<bool>>)((_, _) => { entered.SetResult(); return resume.Task; }));
        var quote = await session.UpdateInputsAsync(fixture.Input, new(0.10m, 0), Token);
        fixture.Keys.Suspension = async _ =>
        {
            fixture.Keys.Suspension = null;
            var total = await fixture.Ledger.TotalAsync("elevenlabs", DateTimeOffset.UnixEpoch, Token);
            await fixture.Ledger.RecordAsync(new("elevenlabs", "fixture", 1, "call", 0.10m - quote.Estimate.Usd!.Value / 2 - total!.Usd, null, "fixture"), DateTimeOffset.UnixEpoch, Token);
        };
        var execution = session.ContinueAsync(Token);
        await entered.Task.WaitAsync(Token);
        var cleanup = cancel.CreateDelegate<Func<Task>>(session)();
        Assert.False(cleanup.IsCompleted);
        resume.SetResult(true);
        var error = await Record.ExceptionAsync(async () => await execution);
        Assert.True(error is OperationCanceledException or VoiceLabException { Kind: VoiceLabErrorKind.Cancelled });
        await cleanup;
        Assert.Same(previous, session.Rows); Assert.True(scratch.IsValid); Assert.True(playing);
        Assert.Equal(previous[0].Id, session.SelectedTakeId); Assert.Equal(previous[0].Id, session.AuditionedTakeId);
        Assert.Single(fixture.Remote.Seeds);
        Assert.NotNull(session.PendingQuote); Assert.NotNull(session.Cost);
        Assert.Equal(VoiceLabGenerationAction.ConfirmationRequired, await session.ContinueAsync(Token));
    }
    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task FirstTransportCapDecisionKeepsReviewedScratchUntilPaidStart(bool approve)
    {
        await using var fixture = new Fixture();
        await fixture.Prepare();
        var session = new VoiceLabGenerationSession(fixture.Run);
        await session.UpdateInputsAsync(fixture.Input, ct: Token);
        await session.ContinueAsync(Token);
        var previous = session.Rows;
        var prior = previous[0];
        session.SelectTake(prior.Id); session.AuditionTake(prior.Id);
        var scratch = fixture.Run.Scratch(prior.Id)!;
        var playing = true;
        using var consumer = scratch.AttachConsumer(() => { playing = false; return Task.CompletedTask; });
        var quote = await session.UpdateInputsAsync(fixture.Input, new(0.10m, 0), Token);
        fixture.Keys.Suspension = async _ =>
        {
            fixture.Keys.Suspension = null;
            var total = await fixture.Ledger.TotalAsync("elevenlabs", DateTimeOffset.UnixEpoch, Token);
            await fixture.Ledger.RecordAsync(new("elevenlabs", "fixture", 1, "call", 0.10m - quote.Estimate.Usd!.Value / 2 - total!.Usd, null, "fixture"), DateTimeOffset.UnixEpoch, Token);
        };
        var confirmations = 0;
        var confirm = typeof(VoiceLabGenerationSession).GetProperty("ConfirmCostAsync");
        Assert.NotNull(confirm);
        confirm.SetValue(session, (Func<string, CancellationToken, Task<bool>>)((_, _) =>
        {
            confirmations++;
            Assert.Same(previous, session.Rows);
            Assert.Equal(prior.Id, session.SelectedTakeId); Assert.Equal(prior.Id, session.AuditionedTakeId);
            Assert.True(scratch.IsValid); Assert.True(playing);
            Assert.Single(fixture.Remote.Seeds);
            return Task.FromResult(approve);
        }));
        var outcome = await session.ContinueAsync(Token);
        Assert.Equal(1, confirmations);
        if (approve)
        {
            Assert.Equal(VoiceLabGenerationAction.Completed, outcome);
            Assert.False(scratch.IsValid); Assert.False(playing);
            Assert.DoesNotContain(session.Rows, row => row.Id == prior.Id);
            Assert.Equal(2, fixture.Remote.Seeds.Count);
        }
        else
        {
            Assert.Equal(VoiceLabGenerationAction.ConfirmationRequired, outcome);
            Assert.Same(previous, session.Rows); Assert.True(scratch.IsValid); Assert.True(playing);
            Assert.Same(quote, session.PendingQuote); Assert.NotNull(session.Cost);
            Assert.Equal(VoiceLabGenerationAction.ConfirmationRequired, await session.ContinueAsync(Token));
            Assert.Single(fixture.Remote.Seeds);
            await fixture.Run.PublishForAcceptanceAsync(prior.Id, DateTimeOffset.UnixEpoch, Token);
        }
    }
    [Theory]
    [InlineData("approval")]
    [InlineData("launch")]
    [InlineData("authorization")]
    public async Task CancelledReplacementRequotesWithoutRetiringReviewedAudition(string point)
    {
        await using var fixture = new Fixture();
        await fixture.Prepare();
        var session = new VoiceLabGenerationSession(fixture.Run);
        await session.UpdateInputsAsync(fixture.Input, ct: Token);
        await session.ContinueAsync(Token);
        var previous = session.Rows;
        var prior = previous[0];
        session.SelectTake(prior.Id); session.AuditionTake(prior.Id);
        var scratch = fixture.Run.Scratch(prior.Id)!;
        var playing = true;
        using var consumer = scratch.AttachConsumer(() => { playing = false; return Task.CompletedTask; });
        var old = session.PendingQuote!;
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var resume = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        fixture.Run.Suspension = async stage => { if (stage == point) { fixture.Run.Suspension = null; entered.SetResult(); await resume.Task; } };
        using var cancellation = CancellationTokenSource.CreateLinkedTokenSource(Token);
        var execution = session.ContinueAsync(cancellation.Token);
        await entered.Task.WaitAsync(Token);
        cancellation.Cancel(); resume.SetResult();
        _ = await Record.ExceptionAsync(async () => await execution);
        Assert.Same(previous, session.Rows);
        Assert.Equal(prior.Id, session.SelectedTakeId); Assert.Equal(prior.Id, session.AuditionedTakeId);
        Assert.True(scratch.IsValid); Assert.True(playing);
        Assert.NotNull(session.PendingQuote); Assert.NotEqual(old.Id, session.PendingQuote.Id);
        Assert.NotNull(session.Cost); Assert.False(session.IsPreparing);
        Assert.Single(fixture.Remote.Seeds);
        await fixture.Run.PublishForAcceptanceAsync(prior.Id, DateTimeOffset.UnixEpoch, Token);
    }
    [Fact]
    public async Task SessionCancelKeepsPlayingScratchUntilExplicitInvalidation()
    {
        await using var fixture = new Fixture();
        await fixture.Prepare();
        var session = new VoiceLabGenerationSession(fixture.Run);
        await session.UpdateInputsAsync(fixture.Input, ct: Token); await session.ContinueAsync(Token);
        var prior = session.Rows[0];
        session.SelectTake(prior.Id); session.AuditionTake(prior.Id);
        var scratch = fixture.Run.Scratch(prior.Id)!;
        var playing = true;
        using var consumer = scratch.AttachConsumer(() => { playing = false; return Task.CompletedTask; });
        var cancel = typeof(VoiceLabGenerationSession).GetMethod("CancelAsync", Type.EmptyTypes);
        var invalidate = typeof(VoiceLabGenerationSession).GetMethod("InvalidateAsync", Type.EmptyTypes);
        Assert.NotNull(cancel); Assert.NotNull(invalidate);
        await cancel.CreateDelegate<Func<Task>>(session)();
        Assert.True(scratch.IsValid); Assert.True(playing);
        Assert.Equal(prior.Id, session.SelectedTakeId); Assert.Equal(prior.Id, session.AuditionedTakeId);
        Assert.NotNull(session.PendingQuote); Assert.NotNull(session.Cost);
        await invalidate.CreateDelegate<Func<Task>>(session)();
        Assert.False(scratch.IsValid); Assert.False(playing); Assert.Empty(session.Rows);
    }
    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task CancellationRacingFirstTransportPreservesOnlyUnlaunchedTakes(bool afterTransport)
    {
        await using var fixture = new Fixture();
        await fixture.Prepare();
        var session = new VoiceLabGenerationSession(fixture.Run);
        await session.UpdateInputsAsync(fixture.Input, ct: Token); await session.ContinueAsync(Token);
        var previous = session.Rows;
        var scratch = fixture.Run.Scratch(previous[0].Id)!;
        using var cancellation = CancellationTokenSource.CreateLinkedTokenSource(Token);
        var reviewPresentAtTransport = false;
        if (afterTransport) fixture.Remote.OnTts = () => { reviewPresentAtTransport = scratch.IsValid; cancellation.Cancel(); };
        else fixture.Keys.Suspension = _ => { fixture.Keys.Suspension = null; cancellation.Cancel(); return Task.CompletedTask; };
        _ = await Record.ExceptionAsync(async () => await session.ContinueAsync(cancellation.Token));
        Assert.Equal(afterTransport ? 2 : 1, fixture.Remote.Seeds.Count);
        Assert.Equal(!afterTransport, scratch.IsValid);
        if (afterTransport) Assert.True(reviewPresentAtTransport);
        if (!afterTransport) Assert.Same(previous, session.Rows);
        Assert.NotNull(session.PendingQuote); Assert.NotNull(session.Cost);
    }
    [Fact]
    public async Task ExpiredQuoteAtFirstTransportKeepsPriorAuditionAndAutomaticallyRequotes()
    {
        await using var fixture = new Fixture();
        await fixture.Prepare();
        var session = new VoiceLabGenerationSession(fixture.Run);
        await session.UpdateInputsAsync(fixture.Input, ct: Token); await session.ContinueAsync(Token);
        var previous = session.Rows;
        var scratch = fixture.Run.Scratch(previous[0].Id)!;
        var old = session.PendingQuote!;
        fixture.Keys.Suspension = _ => { fixture.Keys.Suspension = null; fixture.Clock.Advance(300); return Task.CompletedTask; };
        await Assert.ThrowsAsync<VoiceLabException>(() => session.ContinueAsync(Token));
        Assert.True(scratch.IsValid); Assert.Same(previous, session.Rows);
        Assert.NotNull(session.PendingQuote); Assert.NotEqual(old.Id, session.PendingQuote.Id);
        Assert.Single(fixture.Remote.Seeds);
    }
    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task TransportRechecksTheRealLedgerForTtsAndScribe(bool atScribe)
    {
        await using var fixture = new Fixture();
        await fixture.Prepare();
        var session = new VoiceLabGenerationSession(fixture.Run);
        var quote = await session.UpdateInputsAsync(fixture.Input, new(0.10m, 0), Token);
        var additional = 0.10m - quote.Estimate.Usd!.Value / 2;
        async Task CrossCap() => await fixture.Ledger.RecordAsync(new("elevenlabs", "fixture", 1, "call", additional, null, "fixture"), DateTimeOffset.UnixEpoch, Token);
        if (atScribe) fixture.Run.Suspension = async stage => { if (stage == "qaAuthorization") { fixture.Run.Suspension = null; await CrossCap(); } };
        else fixture.Keys.Suspension = async _ => { fixture.Keys.Suspension = null; await CrossCap(); };
        if (atScribe)
            await Assert.ThrowsAsync<VoiceLabConfirmationRequiredException>(() => session.ContinueAsync(Token));
        else
            Assert.Equal(VoiceLabGenerationAction.ConfirmationRequired, await session.ContinueAsync(Token));
        Assert.Equal(atScribe ? 1 : 0, fixture.Remote.Seeds.Count);
        Assert.Empty(fixture.Remote.QaWavs);
    }
    [Fact]
    public async Task SuspendedConfirmationRechecksCurrentCapAndRepeatsOnlyChangedCopy()
    {
        await using var fixture = new Fixture();
        await fixture.Prepare();
        var session = new VoiceLabGenerationSession(fixture.Run);
        decimal? limit = 0.10m;
        var read = typeof(VoiceLabGenerationSession).GetProperty("ReadMonthlyCapAsync");
        var confirm = typeof(VoiceLabGenerationSession).GetProperty("ConfirmCostAsync");
        Assert.NotNull(read); Assert.NotNull(confirm);
        read.SetValue(session, (Func<CancellationToken, Task<decimal?>>)(_ => Task.FromResult(limit)));
        var copies = new List<string>();
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var resume = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        confirm.SetValue(session, (Func<string, CancellationToken, Task<bool>>)(async (copy, token) =>
        {
            copies.Add(copy);
            if (copies.Count == 1) { entered.SetResult(); return await resume.Task.WaitAsync(token); }
            return false;
        }));
        var quote = await session.UpdateInputsAsync(fixture.Input, new(0.10m, 0), Token);
        var amount = 0.10m - quote.Estimate.Usd!.Value / 2;
        fixture.Keys.Suspension = async _ => { fixture.Keys.Suspension = null; await fixture.Ledger.RecordAsync(new("elevenlabs", "fixture", 1, "call", amount, null, "fixture"), DateTimeOffset.UnixEpoch, Token); };
        var execution = session.ContinueAsync(Token);
        await entered.Task.WaitAsync(Token);
        limit = 0.10m - quote.Estimate.Usd.Value / 4;
        resume.SetResult(true);
        Assert.Equal(VoiceLabGenerationAction.ConfirmationRequired, await execution);
        Assert.Equal(2, copies.Count);
        Assert.NotEqual(copies[0], copies[1]);
        Assert.Empty(fixture.Remote.Seeds); Assert.Empty(fixture.Remote.QaWavs);
        Assert.Same(quote, session.PendingQuote);
    }
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
        internal Action? OnTts;
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
                OnTts?.Invoke();
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
        internal readonly float[] Samples;
        internal readonly VoiceConsentRecord Record;
        /// <summary>The source speech each authorization was asked about.</summary>
        internal readonly List<float[]> Speech = [];
        internal bool SpeakerFailure;
        internal bool Current = true;
        internal Fixture(Func<VoiceLabTakeInput, VoiceLabTakeInput>? input = null)
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
            var checks = new VoiceLabTakeRunChecks(_ => { }, (record, speech, request, binding, model, ct) =>
            {
                ct.ThrowIfCancellationRequested(); Store.ValidateUse(record);
                lock (Speech) Speech.Add(speech);
                return Task.FromResult(new OwnVoicePolicy(record.RecordId, record.VoiceId, true, true, true, true, true)
                {
                    DispatchPermit = new(Store, record.RecordId, request, () => Store.ValidateUse(record), binding),
                    ValidateDispatch = _ => Task.CompletedTask, ModelRevision = model
                });
            }, (_, _, ct) => { ct.ThrowIfCancellationRequested(); return Task.FromResult(SpeakerFailure ? new float[] { 0, 1 } : [1f, 0f]); });
            Run = new(Client, Store, new(Guid.NewGuid().ToString("D"), Path.Combine(Root, "Paid"), Path.Combine(Root, "scratch")), Gate,
                _ => Task.FromResult(Current), checks);
            var source = Samples = Enumerable.Range(0, 24000 * 8).Select(index =>
            {
                var seconds = index / 24000.0;
                return seconds is >= 1.9 and < 2.1 or >= 5.9 and < 6.1 or >= 6.5 and < 7.1 ? 0.001f : (float)(0.1 * Math.Sin(2 * Math.PI * 100 * seconds));
            }).ToArray();
            TimedWord Word(string id, double start, double end) => new(id, id, WordKind.Word, start, end, null, null, 1, "one", TimingSource.Native);
            var window = new VoiceLabWindow("old", "old", [], [], 2, 6, 48000, 144000, new(VoiceLabSeamKind.Hard, 2, 48000, 288), new(VoiceLabSeamKind.Hard, 6, 144000, 288));
            Input = new("Hello", "eleven_v3", Record.RecordId, "en", uint.MaxValue, "synthetic-source", source, 24000,
                [Word("before", 0, 1.9), Word("old", 2.1, 5.9), Word("after", 6.1, 6.5), Word("last", 7.1, 7.9)], new HashSet<string>(), window, null, null, false, true);
            if (input is not null) Input = input(Input);
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
        // The input copied the samples it was built from, so changing them cannot reach the prepared run.
        Array.Fill(fixture.Samples, float.NaN);
        Assert.Equal(VoiceLabTakeRunEnd.EarlyStop, (await fixture.Run.ExecuteAsync(quote, true, ct: Token)).End);
    }
    /// <summary>A take run on a track past the old 30,000,000-frame cap (11 min 20 s at 44.1 kHz) from the regions
    /// VoiceLabSourceAudio.RewriteSourceAsync decodes stages, uploads for QA and ranks exactly what the same run does from the
    /// whole decoded track: the same level, room tone, speaker-check span and 24 kHz frames around the window.</summary>
    [Fact]
    public async Task TakesFromALongSourcesRegionsEqualTakesFromTheWholeSource()
    {
        const int rate = 44_100;
        const long frames = 30_000_001;
        // A 100 Hz tone with quiet gaps: the room-tone pause at 100.0–100.6 s and the window's seams at 402 s and 406 s, as in the
        // fixture's 8 s source.
        static short Pcm(long frame)
        {
            var seconds = frame / (double)rate;
            return seconds is >= 100 and < 100.6 or >= 401.9 and < 402.1 or >= 405.9 and < 406.1 ? (short)33
                : (short)Math.Round(3_277 * Math.Sin(2 * Math.PI * 100 * seconds), MidpointRounding.AwayFromZero);
        }
        static TimedWord Word(string id, double start, double end) => new(id, id, WordKind.Word, start, end, null, null, 1, "one", TimingSource.Native);
        TimedWord[] items = [Word("intro", 0, 100), Word("before", 100.6, 401.9), Word("old", 402.1, 405.9), Word("after", 406.1, 680)];
        const long first = 402L * rate, last = 406L * rate;
        var window = new VoiceLabWindow("old", "old", [], [], 402, 406, first, last,
            new(VoiceLabSeamKind.Hard, 402, first, 529), new(VoiceLabSeamKind.Hard, 406, last, 529));
        var spans = new List<(long Start, long End)>();
        var read = await VoiceLabSourceAudio.RewriteSourceAsync("long-source", frames, rate, window, null, null, items,
            SourceConversion.Fake(frames, Pcm, spans), Token);
        // Three envelope chunks, then two regions: 2.5 s around the room-tone run at 100 s and 16 s around the window.
        Assert.Equal(5, spans.Count);
        Assert.Equal(new long[] { 4_365_900, 396L * rate }, read.Excerpt.Regions.Select(region => region.Start));
        Assert.Equal(new long[] { 4_476_150, 412L * rate }, read.Excerpt.Regions.Select(region => region.End));
        var whole = new float[frames];
        for (var frame = 0; frame < whole.Length; frame++) whole[frame] = Pcm(frame) / 32768f;
        VoiceLabTakeInput Bind(VoiceLabTakeInput input, VoiceLabSourceExcerpt source, AudioEnvelope envelope) =>
            input with { Source = source, SourceEnvelope = envelope, SourceSampleRate = rate, Items = items, Window = window };
        await using var wholeRun = new Fixture(input => Bind(input, VoiceLabSourceExcerpt.Whole(whole), VoiceLabTakeProcessing.Envelope(whole, rate)));
        await using var regionRun = new Fixture(input => Bind(input, read.Excerpt, read.Envelope));
        Assert.Equal(VoiceLabTakeProcessing.Preflight(wholeRun.Input), VoiceLabTakeProcessing.Preflight(regionRun.Input));
        var expected = await wholeRun.Run.ExecuteAsync(await wholeRun.Prepare(), true, ct: Token);
        var actual = await regionRun.Run.ExecuteAsync(await regionRun.Prepare(), true, ct: Token);
        Assert.Equal(expected.End, actual.End);
        Assert.Equal(expected.Rows.Count, actual.Rows.Count);
        Assert.Contains(actual.Rows, row => row.Audio is { RoomTone: not null } && row.Qa is not null);
        foreach (var (before, after) in expected.Rows.Zip(actual.Rows))
        {
            Assert.Equal(before.Failure?.GetType(), after.Failure?.GetType());
            Assert.Equal(before.Audio is null, after.Audio is null);
            if (before.Audio is { } audio && after.Audio is { } staged)
            {
                Assert.Equal(audio.RoomTone, staged.RoomTone);
                Assert.Equal(audio.GainDb, staged.GainDb);
                Assert.Equal(audio.Trimmed, staged.Trimmed);
                Assert.Equal(audio.Mixed, staged.Mixed);
                Assert.Equal(audio.Seams, staged.Seams);
                Assert.Equal((audio.PatchStart, audio.PatchEnd), (staged.PatchStart, staged.PatchEnd));
            }
            Assert.Equal(before.Qa is null, after.Qa is null);
            if (before.Qa is { } qa && after.Qa is { } measured)
            {
                Assert.Equal(qa.Failures, measured.Failures);
                Assert.Equal((qa.TranscriptMatch, qa.LufsJumpLu, qa.PeakDbfs, qa.SpeakerScore),
                    (measured.TranscriptMatch, measured.LufsJumpLu, measured.PeakDbfs, measured.SpeakerScore));
            }
            Assert.Equal(before.Score, after.Score);
        }
        // The QA uploads and the speaker-check speech are the same bytes and samples.
        Assert.NotEmpty(regionRun.Remote.QaWavs);
        Assert.Equal(wholeRun.Remote.QaWavs, regionRun.Remote.QaWavs);
        Assert.NotEmpty(regionRun.Speech);
        Assert.Equal(wholeRun.Speech, regionRun.Speech);
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
        var stopped = await fixture.Run.ExecuteAsync(second, true, rows =>
        {
            if (rows.Count > 0) { fixture.Current = false; fixture.Gate.Invalidate(); }
            return Task.CompletedTask;
        }, Token);
        Assert.Equal(VoiceLabTakeRunEnd.Invalidated, stopped.End);
        Assert.Equal(3, fixture.Remote.Seeds.Count);
        Assert.False(fixture.Client.QuotesAreFresh(second.Actions));
    }
    [Fact]
    public async Task SessionAutomaticRequoteReadsActualAcceptedSpendForTheMonthlyCap()
    {
        await using var fixture = new Fixture();
        var initial = await fixture.Prepare();
        var total = Assert.IsType<decimal>(initial.Estimate.Usd);
        var first = initial.Takes[0].Synthesis.Estimate.Usd!.Value + initial.Takes[0].Qa.Estimate.Usd!.Value;
        Assert.True(first > 0);
        var session = new VoiceLabGenerationSession(fixture.Run);
        await session.UpdateInputsAsync(fixture.Input, new(total + first / 2, 99), Token);
        Assert.Equal(VoiceLabCostPresentationKind.Inline, session.Cost!.Kind);
        await session.ApproveAsync(session.PendingQuote!, true, Token);
        Assert.Single(session.Rows);
        Assert.Equal(first, (await fixture.Ledger.TotalAsync("elevenlabs", DateTimeOffset.UnixEpoch, Token))!.Usd);
        Assert.Equal(VoiceLabCostPresentationKind.Confirm, session.Cost!.Kind);
        Assert.Equal(VoiceLabGenerationAction.ConfirmationRequired, await session.TryAnotherAsync(Token));
        Assert.Single(fixture.Remote.Seeds);
    }

    [Fact]
    public async Task SessionAutomaticRequoteKeepsPriorScratchAuditionAndAcceptance()
    {
        await using var fixture = new Fixture();
        await fixture.Prepare();
        var session = new VoiceLabGenerationSession(fixture.Run);
        await session.UpdateInputsAsync(fixture.Input, ct: Token);
        await session.ApproveAsync(session.PendingQuote!, true, Token);
        var row = Assert.Single(session.Rows);
        var scratch = Assert.IsType<VoiceLabTakeScratch>(fixture.Run.Scratch(row.Id));
        Assert.NotNull(session.PendingQuote); Assert.NotNull(session.Cost);
        Assert.True(scratch.IsValid);
        await fixture.Run.PublishForAcceptanceAsync(row.Id, DateTimeOffset.UnixEpoch, Token);
        session.SelectTake(row.Id); session.AuditionTake(row.Id);
        var old = session.PendingQuote!;
        await session.UpdateInputsAsync(fixture.Input with { Seed = 100 }, ct: Token);
        Assert.False(fixture.Run.IsQuoteFresh(old));
        Assert.Equal(row.Id, session.SelectedTakeId); Assert.Equal(row.Id, session.AuditionedTakeId);
        await session.ApproveAsync(session.PendingQuote!, false, Token);
        Assert.True(scratch.IsValid);
        await fixture.Run.PublishForAcceptanceAsync(row.Id, DateTimeOffset.UnixEpoch, Token);
        Assert.Single(fixture.Remote.Seeds);
    }

    [Fact]
    public async Task SessionInputChangeAfterApprovalBeforeLaunchSendsNothingAndKeepsPriorScratch()
    {
        await using var fixture = new Fixture();
        await fixture.Prepare();
        var session = new VoiceLabGenerationSession(fixture.Run);
        await session.UpdateInputsAsync(fixture.Input, ct: Token);
        await session.ApproveAsync(session.PendingQuote!, true, Token);
        var prior = Assert.Single(session.Rows);
        var scratch = fixture.Run.Scratch(prior.Id)!;
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var resume = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        fixture.Run.Suspension = async point => { if (point == "launch") { entered.TrySetResult(); await resume.Task.WaitAsync(Token); } };
        var run = session.ApproveAsync(session.PendingQuote!, true, Token);
        await entered.Task.WaitAsync(Token);
        var changed = session.UpdateInputsAsync(fixture.Input with { Text = "Changed" }, ct: Token);
        resume.SetResult();
        Assert.NotNull(await Record.ExceptionAsync(() => run));
        await changed;
        Assert.Single(fixture.Remote.Seeds);
        Assert.True(scratch.IsValid);
        Assert.Equal(prior.Id, Assert.Single(session.Rows).Id);
        Assert.NotNull(session.PendingQuote);
    }

    [Fact]
    public async Task RegenerationQuoteAndCancelledApprovalKeepPriorScratchAndAcceptance()
    {
        await using var fixture = new Fixture();
        var first = await fixture.Run.ExecuteAsync(await fixture.Prepare(), true, ct: Token);
        var row = Assert.Single(first.Rows);
        Assert.True(row.Selectable);
        var scratch = Assert.IsType<VoiceLabTakeScratch>(fixture.Run.Scratch(row.Id));
        var second = await fixture.Run.PrepareAsync(fixture.Input, Token);
        Assert.True(scratch.IsValid);
        Assert.Same(scratch, fixture.Run.Scratch(row.Id));
        await fixture.Run.PublishForAcceptanceAsync(row.Id, DateTimeOffset.UnixEpoch, Token);
        await fixture.Run.DiscardPendingAsync();
        Assert.True(scratch.IsValid);
        await fixture.Run.PublishForAcceptanceAsync(row.Id, DateTimeOffset.UnixEpoch, Token);
        Assert.False(fixture.Client.QuotesAreFresh(second.Actions));
        Assert.Single(fixture.Remote.Seeds);
    }
    [Fact]
    public async Task WholeRunLaunchRetiresPriorRowsAndRestartsAtTakeOne()
    {
        await using var fixture = new Fixture();
        var first = await fixture.Run.ExecuteAsync(await fixture.Prepare(), true, ct: Token);
        var prior = Assert.Single(first.Rows);
        var scratch = Assert.IsType<VoiceLabTakeScratch>(fixture.Run.Scratch(prior.Id));
        var second = await fixture.Run.PrepareAsync(fixture.Input with { Seed = 100 }, Token);
        Assert.True(scratch.IsValid);
        Assert.Equal(3, second.Takes.Count);
        fixture.Remote.Mismatches = 100;
        var started = false;
        var result = await fixture.Run.ExecuteAsync(second, true, rows =>
        {
            if (rows.Count == 0) { started = true; Assert.False(scratch.IsValid); Assert.Null(fixture.Run.Scratch(prior.Id)); }
            return Task.CompletedTask;
        }, Token);
        Assert.True(started);
        Assert.Equal(new[] { "Take 1", "Take 2", "Take 3" }, result.Rows.Select(row => row.DisplayName));
        Assert.Equal(new uint[] { uint.MaxValue, 100, 101, 102 }, fixture.Remote.Seeds);
        await Assert.ThrowsAsync<VoiceLabException>(() => fixture.Run.PublishForAcceptanceAsync(prior.Id, DateTimeOffset.UnixEpoch, Token));
    }
    [Fact]
    public async Task ExpiredRegenerationQuoteDoesNotDestroyPreviousTake()
    {
        await using var fixture = new Fixture();
        var first = await fixture.Run.ExecuteAsync(await fixture.Prepare(), true, ct: Token);
        var prior = Assert.Single(first.Rows);
        var second = await fixture.Run.PrepareAsync(fixture.Input, Token);
        fixture.Clock.Advance(300);
        await Assert.ThrowsAsync<VoiceLabException>(() => fixture.Run.ExecuteAsync(second, true, ct: Token));
        Assert.True(fixture.Run.Scratch(prior.Id)!.IsValid);
        await fixture.Run.PublishForAcceptanceAsync(prior.Id, DateTimeOffset.UnixEpoch, Token);
        Assert.Single(fixture.Remote.Seeds);
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
