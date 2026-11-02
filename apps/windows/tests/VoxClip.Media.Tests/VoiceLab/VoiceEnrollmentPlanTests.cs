using System.Net;
using System.Text.Json;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.LLM;
using VoxClip.Core.Services.Project;
using VoxClip.Core.Services.Speech;
using VoxClip.Core.Services.VoiceLab;
using VoxClip.Media.VoiceLab;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Media.Tests.VoiceLab;

public sealed partial class VoiceEnrollmentPlanTests
{
    private static CancellationToken Token => TestContext.Current.CancellationToken;
    private static JsonNode Vectors() => JsonNode.Parse(FixtureLoader.ReadText("fixtures/voice-lab/enrollment-cases.json"))!;
    private static IEnumerable<JsonNode> Rows(JsonNode node) => node.AsArray().Select(item => item!);
    private static string S(JsonNode node, string key) => node[key]!.GetValue<string>();
    private static byte[] Wav(int seconds = 5, float fill = 0.12f)
    {
        var wav = VoiceTrainingAudio.Wav(Enumerable.Repeat(fill, seconds * 16000).ToArray(), 16000);
        for (var offset = 44; offset < wav.Length; offset += 2)
            System.Buffers.Binary.BinaryPrimitives.WriteInt16LittleEndian(wav.AsSpan(offset), (short)(fill * 30000));
        return wav;
    }
    private sealed class Crash : Exception;
    private sealed class Clock : TimeProvider
    {
        internal DateTimeOffset Now = new(2026, 11, 1, 0, 0, 0, TimeSpan.Zero);
        internal long Ticks;
        internal void Advance(int seconds) { Now = Now.AddSeconds(seconds); Ticks += TimeSpan.FromSeconds(seconds).Ticks; }
        public override DateTimeOffset GetUtcNow() => Now;
        public override long GetTimestamp() => Ticks;
        public override long TimestampFrequency => TimeSpan.TicksPerSecond;
    }
    private sealed class Keys : IKeyProvider
    {
        internal string Key = "synthetic-enrollment-key";
        public Task<string?> GetKeyAsync(string account, CancellationToken ct) => Task.FromResult<string?>(Key);
    }
    private sealed class Remote : HttpMessageHandler
    {
        internal string Flow = "success";
        internal int Embeddings;
        internal string? CreationBody;
        internal bool VerificationRequired;
        internal readonly List<string> Events = [];
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            Assert.True(Embeddings > 0);
            string json; var status = HttpStatusCode.OK;
            switch (request.RequestUri!.AbsolutePath)
            {
                case "/v1/user/subscription":
                    Events.Add("plan");
                    json = "{\"tier\":\"starter\",\"status\":\"active\",\"character_count\":0,\"character_limit\":1000,\"can_use_instant_voice_cloning\":" +
                        (Flow == "plan-denied" ? "false" : "true") + ",\"voice_slots_used\":" + (Flow == "no-slots" ? "3" : "0") + ",\"voice_limit\":3}";
                    break;
                case "/v1/speech-to-text":
                    Events.Add("verify"); json = Flow == "verify-fail" ? "{\"language_code\":\"eng\",\"text\":\"wrong\",\"words\":[{\"text\":\"wrong\",\"type\":\"word\",\"start\":0,\"end\":1}]}"
                        : FixtureLoader.ReadText("fixtures/voice-lab/consent-scribe.json"); break;
                case "/v1/voices/add":
                    CreationBody = request.Content!.ReadAsStringAsync(ct).GetAwaiter().GetResult();
                    Events.Add("create"); json = "{\"voice_id\":\"fixtureOwnVoice\",\"requires_verification\":" + (VerificationRequired ? "true" : "false") + "}";
                    if (Flow == "create-fail") status = HttpStatusCode.InternalServerError; break;
                default: throw new InvalidOperationException(request.RequestUri.AbsolutePath);
            }
            return Task.FromResult(new HttpResponseMessage(status) { Content = new StringContent(json, System.Text.Encoding.UTF8, "application/json") });
        }
    }
    private sealed class Fixture : IDisposable
    {
        internal readonly string Root = Path.Combine(Path.GetTempPath(), "voxclip-w4-" + Guid.NewGuid().ToString("N"));
        internal readonly Clock Clock = new(); internal readonly Keys Keys = new(); internal readonly Remote Remote = new();
        internal readonly VoiceConsentStore Store; internal readonly ElevenLabsVoiceLab Client; internal readonly VoiceEnrollment Service;
        internal string Id = Guid.NewGuid().ToString("D");
        internal bool CrashAfterVerify;
        internal readonly VoiceConsentStatement Statement;
        internal DataLocations Locations => new(Root, Path.Combine(Root, "settings.json"), Path.Combine(Root, "Models"), Path.Combine(Root, "Cache"),
            Path.Combine(Root, "Autosave"), Path.Combine(Root, "Secrets"), Path.Combine(Root, "Logs"));
        internal Fixture()
        {
            Directory.CreateDirectory(Root);
            var record = JsonSerializer.Deserialize(FixtureLoader.ReadText("fixtures/voice-lab/consent-record.json"), VoiceConsentJson.Default.VoiceConsentRecord)!;
            Statement = new(record.Statement!.Language, record.Statement!.Text, record.Statement!.Nonce);
            Store = new(Locations, point => { if (CrashAfterVerify && point == "enrollmentVerified") throw new Crash(); }, Clock);
            Client = NewClient(); Service = NewService(Store, Client);
        }
        internal ElevenLabsVoiceLab NewClient() => ElevenLabsVoiceLab.ForTesting(Keys, Remote, ElevenLabsRegion.Default, clock: Clock);
        internal VoiceEnrollment NewService(VoiceConsentStore store, ElevenLabsVoiceLab client) => new(store, client, clock: Clock)
        {
            SpeakerForTests = new(Embed, async (pcm, ct) => { var value = await Embed(pcm, ct); return (value, [value]); })
        };
        private Task<float[]> Embed(float[] pcm, CancellationToken ct) { ct.ThrowIfCancellationRequested(); Remote.Embeddings++; return Task.FromResult(pcm[0] > 0 ? new float[] { 1, 0 } : [0, 1]); }
        internal VoiceTrainingSample[] Samples(bool mismatch = false, string source = "readAloud") => Enumerable.Range(0, 4)
            .Select(index => new VoiceTrainingSample(Wav(15, mismatch ? -0.12f : 0.06f + index * 0.01f), 15, source, 25)).ToArray();
        internal Task<VoiceEnrollmentPlan> Prepare(bool mismatch = false, VoiceConsentStatement? statement = null, string source = "readAloud") => Service.PreparePlanAsync(Id,
            statement ?? Statement, Wav(), new(true, true, true, Clock.Now), "Example", Samples(mismatch, source), true, Token);
        public void Dispose() { Client.Dispose(); Remote.Dispose(); Directory.Delete(Root, true); }
    }
    private static string ErrorName(Exception error) => error switch
    {
        VoiceConsentException consent => Lower(consent.Kind.ToString()), VoiceLabException lab => Lower(lab.Kind.ToString()), _ => error.GetType().Name
    };
    private static string Lower(string value) => char.ToLowerInvariant(value[0]) + value[1..];
    [Fact]
    public async Task EveryEnrollmentFlowReplaysExactly()
    {
        var vectors = Vectors(); Assert.Equal("voxclip-enrollment-cases/1", S(vectors, "schema"));
        Assert.Equal(36, new[] { "flows", "mutations", "recoveries", "retries", "journals" }.Sum(key => vectors[key]!.AsArray().Count));
        foreach (var row in Rows(vectors["flows"]!))
        {
            using var f = new Fixture(); var id = S(row, "id"); f.Remote.Flow = id;
            var outcome = "created";
            try
            {
                var plan = await f.Prepare(id == "speaker-mismatch"); Assert.Empty(f.Remote.Events);
                Assert.Equal(plan.Quote.Verify!.Estimate.Usd + plan.Quote.Create.Estimate.Usd, plan.Quote.Estimate.Usd);
                var record = await f.Service.ExecuteAsync(plan, id != "declined", id != "disabled", "test", Token);
                Assert.Equal(f.Statement.Text, record.Statement!.Text); Assert.Equal(VoiceConsentStore.Hash(Wav()), record.Statement!.AudioSha256);
                Assert.Equal(0, record.Statement!.Stt.Wer); Assert.NotEmpty(record.Statement!.Stt.TranscriptionId);
                Assert.Equal(JsonSerializer.Serialize(record, VoiceConsentJson.Default.VoiceConsentRecord), JsonSerializer.Serialize(f.Store.Load(f.Id), VoiceConsentJson.Default.VoiceConsentRecord)); Assert.Empty(f.Store.RecoverableEnrollments());
                await Assert.ThrowsAsync<VoiceLabException>(() => f.Service.ExecuteAsync(plan, true, true, "test", Token));
            }
            catch (Exception error) when (error is VoiceLabException or VoiceConsentException) { outcome = ErrorName(error); }
            Assert.Equal(S(row, "outcome"), outcome); Assert.Equal(Rows(row["events"]!).Select(item => item.GetValue<string>()), f.Remote.Events);
            if (id == "create-fail") { Assert.Null(f.Store.EnrollmentRecovery(f.Id)); Assert.False(File.Exists(Path.Combine(f.Store.Root, f.Id, "statement.wav"))); }
        }
    }
    [Fact]
    public async Task CombinedQuoteBindsAll13MutationRows()
    {
        using var f = new Fixture(); var plan = await f.Prepare();
        var original = new VoiceLabCloneRequest("Example", "en", new[] { new VoiceLabCloneSample(VoiceLabCloneSampleRole.ConsentStatement, Wav()) }
            .Concat(f.Samples().Select(sample => new VoiceLabCloneSample(VoiceLabCloneSampleRole.Training, sample.Wav))).ToArray(), f.Clock.Now, false, f.Id);
        foreach (var node in Rows(Vectors()["mutations"]!))
        {
            var mutation = node.GetValue<string>(); var request = original; var files = original.Samples.ToArray(); var statement = f.Statement;
            switch (mutation)
            {
                case "same": break;
                case "statementBytes": files[0] = files[0] with { Wav = Wav(fill: 0.2f) }; break;
                case "statementText": statement = statement with { Text = statement.Text + " changed" }; break;
                case "nonce": statement = statement with { Nonce = statement.Nonce.Reverse().ToArray() }; break;
                case "files": files = files[..^1]; break;
                case "fileBytes": files[1] = files[1] with { Wav = Wav() }; break;
                case "order": (files[1], files[2]) = (files[2], files[1]); break;
                case "roles": files[1] = files[1] with { Role = VoiceLabCloneSampleRole.ConsentStatement }; break;
                case "name": request = request with { DisplayName = "Other" }; break;
                case "language": request = request with { Language = "et" }; break;
                case "createdAt": request = request with { CreatedAt = request.CreatedAt.AddSeconds(1) }; break;
                case "noiseRemoval": request = request with { RemoveBackgroundNoise = true }; break;
                case "recordID": request = request with { RecoveryNonce = Guid.NewGuid().ToString("D") }; break;
                default: Assert.Fail(mutation); break;
            }
            request = request with { Samples = files };
            if (mutation == "same") plan.Quote.Validate(request, statement);
            else Assert.Throws<VoiceLabException>(() => plan.Quote.Validate(request, statement));
        }
        Assert.Empty(f.Remote.Events);
    }
    [Fact]
    public async Task AttemptBoundariesAndSameStatementRetriesReplayExactly()
    {
        using var f = new Fixture(); var row = Vectors()["attempts"]!;
        for (var index = 0; index < row["limit"]!.GetValue<int>(); index++)
            await f.Prepare(statement: f.Statement with { Nonce = f.Statement.Nonce.Append(index.ToString()).ToArray() });
        f.Clock.Advance(row["blockedAtSeconds"]!.GetValue<int>());
        Assert.Equal(VoiceConsentError.TooManyAttempts, (await Assert.ThrowsAsync<VoiceConsentException>(() => f.Prepare())).Kind);
        f.Clock.Advance(row["allowedAtSeconds"]!.GetValue<int>() - row["blockedAtSeconds"]!.GetValue<int>()); await f.Prepare();
        Assert.Empty(f.Remote.Events);
        foreach (var retry in Rows(Vectors()["retries"]!))
        {
            using var r = new Fixture();
            for (var index = 0; index < retry["localPrepares"]!.GetValue<int>(); index++)
                Assert.Equal(VoiceConsentError.SpeakerMismatch, (await Assert.ThrowsAsync<VoiceConsentException>(() => r.Prepare(true, source: "project"))).Kind);
            for (var index = 0; index < retry["expiredReprepares"]!.GetValue<int>(); index++) { await r.Prepare(); r.Clock.Advance(300); }
            var plan = await r.Prepare(); await r.Service.ExecuteAsync(plan, true, true, "test", Token);
            Assert.Equal(Rows(retry["expectedSends"]!).Select(item => item.GetValue<string>()), r.Remote.Events);
        }
    }
    [Fact]
    public async Task AllEightRecoveryRowsReplayWithoutAnotherVerificationQuoteOrSend()
    {
        foreach (var row in Rows(Vectors()["recoveries"]!))
        {
            using var f = new Fixture { CrashAfterVerify = true }; var plan = await f.Prepare();
            await Assert.ThrowsAsync<Crash>(() => f.Service.ExecuteAsync(plan, true, true, "test", Token));
            Assert.Equal(new[] { "plan", "verify" }, f.Remote.Events);
            var store = new VoiceConsentStore(f.Locations, f.Clock); var id = S(row, "id");
            if (id is "unsent-intent" or "dispatched")
            {
                var snapshot = store.EnrollmentRecovery(f.Id)!;
                using var claim = store.ClaimCreation(snapshot.Record, plan.Quote.Create.Review.RequestId, ElevenLabsRegion.Default, f.Clock.Now);
                if (id == "dispatched") store.Transition(claim.Operation.Id, VoiceOperationState.Dispatched, f.Clock.Now);
            }
            if (id == "cancelled") f.Service.Cancel(f.Id);
            if (id == "changed-statement") store.SaveStatement(Wav(fill: 0.2f), f.Id);
            if (id == "different-creator") f.Keys.Key = "synthetic-other-key";
            f.Clock.Advance(row["elapsedSeconds"]!.GetValue<int>()); f.Remote.Events.Clear();
            using var client = f.NewClient(); var service = f.NewService(store, client);
            if (S(row, "action") == "reject") await Assert.ThrowsAnyAsync<Exception>(() => service.RecoverPlanAsync(f.Id, true, Token));
            else
            {
                store.ReconcileAbandonedEnrollments(); Assert.Equal(new[] { f.Id }, store.RecoverableEnrollments());
                var recovered = await service.RecoverPlanAsync(f.Id, true, Token);
                Assert.True(recovered.VerificationPassed); Assert.Null(recovered.Quote.Verify);
                Assert.Equal(recovered.Quote.Create.Estimate.ToCostEstimate(), recovered.Quote.Estimate);
                Assert.Equal(row["sameQuote"]!.GetValue<bool>(), recovered.Quote.Create.Id == plan.Quote.Create.Id);
                Assert.Empty(f.Remote.Events);
                if (S(row, "action") == "decline") await Assert.ThrowsAsync<VoiceLabException>(() => service.ExecuteAsync(recovered, false, true, "test", Token));
                else { var record = await service.ExecuteAsync(recovered, true, true, "test", Token); Assert.Equal(f.Statement.Text, record.Statement!.Text); Assert.Empty(store.RecoverableEnrollments()); }
            }
            Assert.Equal(Rows(row["events"]!).Select(item => item.GetValue<string>()), f.Remote.Events);
        }
    }
    [Fact]
    public async Task AllSixJournalRowsExpireOrAbandonWithoutHidingOtherVoices()
    {
        foreach (var row in Rows(Vectors()["journals"]!))
        {
            using var f = new Fixture { CrashAfterVerify = true }; var plan = await f.Prepare();
            await Assert.ThrowsAsync<Crash>(() => f.Service.ExecuteAsync(plan, true, true, "test", Token));
            var path = Path.Combine(f.Store.Root, f.Id, "enrollment.json");
            switch (S(row, "corruption"))
            {
                case "json": File.WriteAllText(path, "broken"); break;
                case "binding": var node = JsonNode.Parse(File.ReadAllText(path))!; node["request"]!["displayName"] = "Other"; File.WriteAllText(path, node.ToJsonString()); break;
                case "statement": File.Delete(Path.Combine(f.Store.Root, f.Id, "statement.wav")); break;
            }
            f.Clock.Advance(row["ageSeconds"]!.GetValue<int>());
            var originalId = f.Id; f.Id = Guid.NewGuid().ToString("D");
            var valid = await f.Prepare();
            await Assert.ThrowsAsync<Crash>(() => f.Service.ExecuteAsync(valid, true, true, "test", Token));
            var restarted = new VoiceConsentStore(f.Locations, f.Clock); restarted.ReconcileAbandonedEnrollments();
            var retained = row["retained"]!.GetValue<bool>();
            Assert.Equal(retained, restarted.EnrollmentRecovery(originalId) is not null);
            Assert.Equal(retained, File.Exists(path)); Assert.Equal(retained, File.Exists(Path.Combine(f.Store.Root, originalId, "statement.wav")));
            if (!retained) Assert.Contains(originalId, restarted.AbandonedEnrollmentIds);
            Assert.Contains(f.Id, restarted.RecoverableEnrollments());
            Assert.Equal(retained ? 2 : 1, restarted.RecoverableEnrollments().Count);
        }
    }
    [Fact]
    public async Task LegacyVerifySendsOnceAndCreateOnlyChecksPlanThenCreates()
    {
        using var f = new Fixture();
        var quote = f.Client.PrepareConsentVerification(Wav(), "en", Guid.NewGuid());
        await f.Service.VerifyAsync(f.Id, f.Statement, Wav(), new(true, true, true, f.Clock.Now), true, true, Token, quote);
        Assert.Equal(new[] { "verify" }, f.Remote.Events);
        await Assert.ThrowsAsync<VoiceLabException>(() => f.Client.TranscribeConsentStatementAsync(Wav(), "en", f.Client.Approve(quote, true), Token));
        var create = await f.Service.PrepareAsync(f.Id, "Example", f.Samples(), true, Token);
        await f.Service.CreateAsync(create, true, true, "test", Token);
        Assert.Equal(new[] { "verify", "plan", "create" }, f.Remote.Events);
        using var mismatch = new Fixture(); mismatch.Remote.Flow = "verify-fail";
        await Assert.ThrowsAsync<VoiceConsentException>(() => mismatch.Service.VerifyAsync(mismatch.Id, mismatch.Statement, Wav(), new(true, true, true, mismatch.Clock.Now), true, true, Token));
        await Assert.ThrowsAsync<VoiceLabException>(() => mismatch.Service.PrepareAsync(mismatch.Id, "Example", mismatch.Samples(), true, Token));
        mismatch.Service.Cancel(mismatch.Id); mismatch.Id = Guid.NewGuid().ToString("D"); mismatch.Remote.Flow = "success";
        await mismatch.Service.VerifyAsync(mismatch.Id, mismatch.Statement, Wav(), new(true, true, true, mismatch.Clock.Now), true, true, Token);
        Assert.Equal(new[] { "verify", "verify" }, mismatch.Remote.Events);
    }
}
