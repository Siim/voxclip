using System.Buffers.Binary;
using System.Net;
using System.Text;
using System.Text.Json;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Runtime.Versioning;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.Project;
using VoxClip.Core.Services.Speech;
using VoxClip.Core.Services.VoiceLab;
using VoxClip.Core.Tests.Tracks.WinAi;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.VoiceLab;

public sealed class VoiceConsentTests
{
    public static bool IsWindows => OperatingSystem.IsWindows();
    [Fact(Skip = "Native Windows DACL verification requires Windows; owed to the VM.", SkipUnless = nameof(IsWindows))]
    [Trait("Category", "RequiresWindows")]
    public void ReviewProbe_ConsentAndOperationsHaveProtectedPrivateDacls()
    {
        if (OperatingSystem.IsWindows()) VerifyWindowsPrivacy();
    }
    [SupportedOSPlatform("windows")]
    private static void VerifyWindowsPrivacy()
    {
        using var storage = new Storage();
        var store = new VoiceConsentStore(storage.Locations);
        var record = Draft(store);
        using var claim = store.ClaimCreation(record, Guid.NewGuid(), ElevenLabsRegion.Default, Now);
        foreach (var directory in new[] { store.Root, Path.Combine(store.Root, record.RecordId), store.OperationsRoot })
        {
            var security = new DirectoryInfo(directory).GetAccessControl();
            Assert.True(security.AreAccessRulesProtected);
            var rules = security.GetAccessRules(true, true, typeof(SecurityIdentifier)).Cast<FileSystemAccessRule>().ToArray();
            Assert.Equal(2, rules.Length);
            Assert.All(rules, rule => Assert.False(rule.IsInherited));
        }
        var folder = new DirectoryInfo(store.Root);
        var original = folder.GetAccessControl();
        var insecure = folder.GetAccessControl();
        insecure.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(WellKnownSidType.WorldSid, null), FileSystemRights.Read, AccessControlType.Allow));
        try
        {
            folder.SetAccessControl(insecure);
            Assert.Throws<VoiceConsentException>(() => new VoiceConsentStore(storage.Locations));
            Assert.Throws<VoiceConsentException>(() => store.Statement(record.RecordId));
        }
        finally { folder.SetAccessControl(original); }
    }
    private static CancellationToken Token => TestContext.Current.CancellationToken;
    private static readonly DateTimeOffset Now = new(2026, 10, 29, 12, 0, 0, TimeSpan.Zero);
    private sealed class Clock : TimeProvider
    {
        internal DateTimeOffset Now = VoiceConsentTests.Now;
        public override DateTimeOffset GetUtcNow() => Now;
    }
    private sealed class Storage : IDisposable
    {
        internal readonly string Root = Path.Combine(Path.GetTempPath(), "voxclip-consent-tests-" + Guid.NewGuid().ToString("N"));
        internal DataLocations Locations => new(Root, Path.Combine(Root, "settings.json"), Path.Combine(Root, "Models"), Path.Combine(Root, "Cache"),
            Path.Combine(Root, "Autosave"), Path.Combine(Root, "Secrets"), Path.Combine(Root, "Logs"));
        internal Storage() => Directory.CreateDirectory(Root);
        public void Dispose() => Directory.Delete(Root, true);
    }
    private sealed class Remote(Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> respond) : HttpMessageHandler
    {
        internal int Calls;
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        { Interlocked.Increment(ref Calls); return respond(request, cancellationToken); }
    }
    private static HttpResponseMessage Json(int status, string body) => new((HttpStatusCode)status) { Content = new StringContent(body, Encoding.UTF8, "application/json") };
    private static VoiceConsentRecord Fixture() => JsonSerializer.Deserialize(FixtureLoader.ReadText("fixtures/voice-lab/consent-record.json"), VoiceConsentJson.Default.VoiceConsentRecord)!;
    [Fact]
    public void ReviewProbe_CreatorRegionMatchesMacWireShape()
    {
        var record = Fixture() with { Creator = new(ElevenLabsRegion.Eu, "0123456789abcdef") };
        using var json = JsonDocument.Parse(JsonSerializer.Serialize(record, VoiceConsentJson.Default.VoiceConsentRecord));
        Assert.Equal("""{"region":"eu","keyFingerprint":"0123456789abcdef"}""", JsonSerializer.Serialize(json.RootElement.GetProperty("creator")));
    }

    [Fact]
    public void ReviewPersistedCreatorUsesNumericRegion()
    {
        using var storage = new Storage();
        var store = new VoiceConsentStore(storage.Locations);
        var record = Draft(store, voice: "active-voice") with { Creator = new(ElevenLabsRegion.Eu, "0123456789abcdef") };
        store.Save(record);
        using var json = JsonDocument.Parse(File.ReadAllBytes(Path.Combine(store.Root, record.RecordId, "record.json")));
        var creator = json.RootElement.GetProperty("creator");
        Assert.Equal(JsonValueKind.String, creator.GetProperty("region").ValueKind);
        Assert.Equal("""{"region":"eu","keyFingerprint":"0123456789abcdef"}""", JsonSerializer.Serialize(creator));
    }

    [Theory]
    [InlineData(ElevenLabsRegion.Default, "default")]
    [InlineData(ElevenLabsRegion.Us, "us")]
    [InlineData(ElevenLabsRegion.Eu, "eu")]
    [InlineData(ElevenLabsRegion.In, "in")]
    [InlineData(ElevenLabsRegion.Sg, "sg")]
    public void CreatorAndEveryJournalRegionRoundTripAndMigrate(ElevenLabsRegion region, string raw)
    {
        using var storage = new Storage();
        var store = new VoiceConsentStore(storage.Locations);
        var record = Draft(store, voice: "active-voice");
        var node = System.Text.Json.Nodes.JsonNode.Parse(JsonSerializer.Serialize(record, VoiceConsentJson.Default.VoiceConsentRecord))!;
        var macCreator = "{\"region\":\"" + raw + "\",\"keyFingerprint\":\"0123456789abcdef\"}";
        node["creator"] = System.Text.Json.Nodes.JsonNode.Parse(macCreator);
        record = JsonSerializer.Deserialize(node.ToJsonString(), VoiceConsentJson.Default.VoiceConsentRecord)!;
        record.Validate();
        Assert.Equal(new VoiceConsentCreator(region, "0123456789abcdef"), record.Creator);
        store.Save(record);
        var recordPath = Path.Combine(store.Root, record.RecordId, "record.json");
        node["creator"]!["region"] = (int)region;
        File.WriteAllText(recordPath, node.ToJsonString());
        Assert.Equal(region, store.Load(record.RecordId).Creator!.Region);
        store.Save(store.Load(record.RecordId));
        using (var saved = JsonDocument.Parse(File.ReadAllBytes(recordPath)))
            Assert.Equal(macCreator, JsonSerializer.Serialize(saved.RootElement.GetProperty("creator")));

        var operation = store.BeginDeletion(record.RecordId, region, Now);
        var operationPath = Path.Combine(store.OperationsRoot, operation.Id.ToString("D") + ".json");
        var journal = System.Text.Json.Nodes.JsonNode.Parse(File.ReadAllBytes(operationPath))!;
        Assert.Equal(raw, journal["region"]!.GetValue<string>());
        Assert.Equal(raw, journal["audit"]!["creator"]!["region"]!.GetValue<string>());
        journal["region"] = (int)region;
        journal["audit"]!["creator"]!["region"] = (int)region;
        File.WriteAllText(operationPath, journal.ToJsonString());
        Assert.Equal(region, store.Operation(operation.Id).Region);
        _ = store.Transition(operation.Id, VoiceOperationState.RemoteDeleted, Now);
        using var migrated = JsonDocument.Parse(File.ReadAllBytes(operationPath));
        Assert.Equal(raw, migrated.RootElement.GetProperty("region").GetString());
        Assert.Equal(macCreator, JsonSerializer.Serialize(migrated.RootElement.GetProperty("audit").GetProperty("creator")));
        using var audit = JsonDocument.Parse(JsonSerializer.Serialize(VoiceConsentAudit.From(record), VoiceConsentJson.Default.VoiceConsentAudit));
        Assert.Equal(macCreator, JsonSerializer.Serialize(audit.RootElement.GetProperty("creator")));
    }

    [Theory]
    [InlineData("\"EU\"")]
    [InlineData("\" eu\"")]
    [InlineData("\"eu \"")]
    [InlineData("\"2\"")]
    [InlineData("\"unknown\"")]
    [InlineData("-1")]
    [InlineData("5")]
    [InlineData("2.0")]
    [InlineData("2.5")]
    [InlineData("2e0")]
    [InlineData("2147483648")]
    [InlineData("null")]
    [InlineData("true")]
    [InlineData("{}")]
    [InlineData("[]")]
    public void RegionConverterRefusesAnythingOutsideTheExactContract(string json)
    {
        Assert.Throws<JsonException>(() => JsonSerializer.Deserialize(json, VoiceConsentJson.Default.ElevenLabsRegion));
        Assert.Throws<JsonException>(() => JsonSerializer.Serialize((ElevenLabsRegion)5, VoiceConsentJson.Default.ElevenLabsRegion));
        var record = System.Text.Json.Nodes.JsonNode.Parse(JsonSerializer.Serialize(Fixture(), VoiceConsentJson.Default.VoiceConsentRecord))!;
        record["creator"] = System.Text.Json.Nodes.JsonNode.Parse("{\"region\":" + json + ",\"keyFingerprint\":\"0123456789abcdef\"}");
        Assert.Throws<JsonException>(() => JsonSerializer.Deserialize(record.ToJsonString(), VoiceConsentJson.Default.VoiceConsentRecord));
    }
    [Fact]
    public async Task ReviewProbe_WrongCreatorRegionCannotConfirmRemote404()
    {
        using var storage = new Storage();
        var store = new VoiceConsentStore(storage.Locations);
        var record = Draft(store, voice: "active-voice");
        store.Save(record);
        using var remote = new Remote((_, _) => Task.FromResult(Json(404, "{}")));
        using var client = ElevenLabsVoiceLab.ForTesting(new MemoryKeys(), remote, ElevenLabsRegion.Eu);
        var error = await Record.ExceptionAsync(async () =>
        {
            store.BeginDeletion(record.RecordId, client.Region, Now);
            await new VoiceOperationReconciler(store, _ => client).ReconcileAsync(ct: Token);
        });
        Assert.NotNull(error);
        Assert.Equal(0, remote.Calls);
        Assert.Equal(VoiceConsentStatus.Active, store.Load(record.RecordId).Status);
    }
    [Theory]
    [InlineData(false, true)]
    [InlineData(false, false)]
    [InlineData(true, true)]
    public async Task DeletionChecksCreatorKeyBeforeAccepting404(bool legacy, bool matching)
    {
        using var storage = new Storage();
        var store = new VoiceConsentStore(storage.Locations);
        const string creatorKey = "synthetic-creator-identity";
        var creator = new VoiceConsentCreator(ElevenLabsRegion.Default, legacy ? null : VoiceConsentCreator.Fingerprint(creatorKey));
        var record = Draft(store, voice: "active-voice") with { Creator = creator };
        store.Save(record);
        using var remote = new Remote((_, _) => Task.FromResult(Json(404, "{}")));
        using var client = ElevenLabsVoiceLab.ForTesting(new MemoryKeys(matching ? creatorKey : "different-synthetic-key"), remote, ElevenLabsRegion.Default);
        store.BeginDeletion(record.RecordId, client.Region, Now);
        var reconcile = new VoiceOperationReconciler(store, _ => client).ReconcileAsync(ct: Token);
        if (!legacy && !matching)
        {
            var error = await Assert.ThrowsAsync<VoiceCreatorMismatchException>(() => reconcile);
            Assert.Equal(VoiceCreatorMismatchException.Explanation, error.Message);
            Assert.Equal(0, remote.Calls);
            Assert.Equal(VoiceConsentStatus.Active, store.Load(record.RecordId).Status);
            Assert.NotEmpty(store.Statement(record.RecordId));
        }
        else
        {
            await reconcile;
            Assert.Equal(1, remote.Calls);
            Assert.False(store.AuditTombstone(record.RecordId)!.RemoteStateUnknown);
        }
    }
    [Fact]
    public async Task LocalOnlyRemovalDurablyRecordsUnknownRemoteStateWithoutSending()
    {
        using var storage = new Storage();
        var store = new VoiceConsentStore(storage.Locations);
        var record = Draft(store, voice: "active-voice") with { Creator = new(ElevenLabsRegion.Eu, VoiceConsentCreator.Fingerprint("synthetic-key")) };
        store.Save(record);
        Assert.Throws<VoiceLabException>(() => store.BeginLocalRemoval(record.RecordId, false, Now));
        store.BeginLocalRemoval(record.RecordId, true, Now);
        await new VoiceOperationReconciler(store, _ => throw new InvalidOperationException("No remote call allowed")).ReconcileAsync(ct: Token);
        var audit = store.AuditTombstone(record.RecordId)!;
        Assert.True(audit.RemoteStateUnknown);
        Assert.Equal(record.Creator, audit.Creator);
        Assert.Equal(16, audit.Creator!.KeyFingerprint!.Length);
        Assert.Equal(VoiceConsentStatus.Deleted, store.Load(record.RecordId).Status);
        Assert.Empty(store.Operations());
    }
    [Fact]
    public void ReviewProbe_CancelAfterSavedKeepsStatementAndDeletionAvailable()
    {
        using var storage = new Storage();
        var store = new VoiceConsentStore(storage.Locations);
        var record = Draft(store, voice: "active-voice");
        store.Save(record);
        var audio = store.Statement(record.RecordId);
        store.WithdrawCreation(record.RecordId, Now);
        Assert.Equal(audio, store.Statement(record.RecordId));
        Assert.Equal(record.VoiceId, store.Load(record.RecordId).VoiceId);
        Assert.Equal("active-voice", store.BeginDeletion(record.RecordId, ElevenLabsRegion.Default, Now).RemoteVoiceId);
    }
    [Fact]
    public async Task ReviewProbe_PublicPermitCannotBypassSpeakerGate()
    {
        using var storage = new Storage();
        var store = new VoiceConsentStore(storage.Locations);
        var record = Draft(store, voice: "voice123");
        store.Save(record);
        Assert.Null(typeof(VoiceConsentStore).GetMethod("CreateUsePolicy"));
        Assert.False(VoiceSpeakerCheck.WindowsNativeParityVerified);
        var error = Assert.Throws<VoiceConsentException>(() => store.CreateUsePolicy(record, Guid.NewGuid(), _ => Task.CompletedTask));
        Assert.Equal(VoiceConsentError.SpeakerUnavailable, error.Kind);
        await Assert.ThrowsAsync<VoiceConsentException>(() => new VoiceUseGuard(store).AuthorizeAsync("content", record.RecordId,
            new float[48000], Guid.NewGuid(), true, ct: Token));
    }
    private static VoiceConsentRecord Draft(VoiceConsentStore store, string? id = null, string voice = "pending")
    {
        var wav = VoiceLabTestCalls.SyntheticWav(16000, 16000 * 6, 2000);
        id ??= Guid.NewGuid().ToString("D");
        store.SaveStatement(wav, id);
        var record = Fixture();
        return record with { RecordId = id, VoiceId = voice, Statement = record.Statement with { AudioSha256 = VoiceConsentStore.Hash(wav) } };
    }
    [Theory]
    [InlineData("legacyOperation")]
    [InlineData("legacyCreationRemoved")]
    public async Task LegacyAdjacentJournalMigratesDurablyBeforeAudioCleanup(string checkpoint)
    {
        using var storage = new Storage();
        var fail = false;
        var store = new VoiceConsentStore(storage.Locations, step => { if (fail && step == checkpoint) throw new IOException("injected"); });
        var record = Draft(store);
        var id = Guid.NewGuid();
        var legacy = new System.Text.Json.Nodes.JsonObject
        {
            ["requestID"] = id.ToString("D"), ["region"] = "default", ["startedAt"] = Now.ToString("O"),
            ["record"] = System.Text.Json.Nodes.JsonNode.Parse(JsonSerializer.Serialize(record, VoiceConsentJson.Default.VoiceConsentRecord))
        };
        var path = Path.Combine(store.Root, record.RecordId, "creation.json");
        File.WriteAllText(path, legacy.ToJsonString());
        fail = true;
        Assert.Throws<IOException>(() => store.Operations());
        Assert.True(File.Exists(path));
        Assert.True(File.Exists(Path.Combine(store.Root, record.RecordId, "statement.wav")));
        fail = false;
        Assert.Equal(id, Assert.Single(store.Operations()).Id);
        Assert.False(File.Exists(path));
        using var remote = new Remote((request, _) =>
        {
            Assert.Equal(HttpMethod.Get, request.Method);
            return Task.FromResult(Json(200, "{\"voices\":[],\"has_more\":false}"));
        });
        using var client = ElevenLabsVoiceLab.ForTesting(new MemoryKeys(), remote, ElevenLabsRegion.Default);
        await new VoiceOperationReconciler(store, _ => client, new Clock()).ReconcileAsync(ct: Token);
        Assert.False(File.Exists(Path.Combine(store.Root, record.RecordId, "statement.wav")));
        Assert.NotNull(store.Operation(id).Audit);
        Assert.Equal(1, remote.Calls);
    }
    [Theory]
    [InlineData(1, true, true)]
    [InlineData(2, true, false)]
    [InlineData(1, false, false)]
    public async Task RecoveryFallsBackToExactNameAndWindowButNeverDeletesAmbiguity(int count, bool timestamp, bool deleted)
    {
        using var storage = new Storage();
        var clock = new Clock { Now = Now.AddHours(30) };
        var store = new VoiceConsentStore(storage.Locations, clock);
        var record = Draft(store);
        var operation = store.BeginClaimedCreation(record, Guid.NewGuid(), ElevenLabsRegion.Default, Now);
        store.Transition(operation.Id, VoiceOperationState.Dispatched, Now);
        store.Release(operation.Id);
        var deletions = 0;
        using var remote = new Remote((request, _) =>
        {
            if (request.Method == HttpMethod.Delete) { deletions++; return Task.FromResult(Json(404, "{}")); }
            Assert.Equal("?page_size=100", request.RequestUri!.Query);
            var rows = Enumerable.Range(0, count).Select(index => new Dictionary<string, object?>
            {
                ["voice_id"] = "remote" + index, ["name"] = record.VoiceName, ["category"] = "cloned", ["is_owner"] = true,
                ["created_at_unix"] = timestamp ? Now.AddMinutes(1).ToUnixTimeSeconds() : null
            });
            return Task.FromResult(Json(200, JsonSerializer.Serialize(new { voices = rows, has_more = false })));
        });
        using var client = ElevenLabsVoiceLab.ForTesting(new MemoryKeys(), remote, ElevenLabsRegion.Default);
        var reconcile = new VoiceOperationReconciler(store, _ => client, clock).ReconcileAsync(ct: Token);
        if (count > 1) await Assert.ThrowsAsync<VoiceConsentException>(() => reconcile);
        else await reconcile;
        Assert.Equal(deleted ? 1 : 0, deletions);
        if (!deleted)
        {
            Assert.False(store.Operation(operation.Id).Finished);
            Assert.NotNull(store.Operation(operation.Id).NextAttemptAt);
            Assert.Contains("Checking", store.Operation(operation.Id).DisplayState);
        }
    }
    [Fact]
    public async Task ReviewProbe_ConflictingNonceNeverDeletesAndReviewSurvivesEmptyListing()
    {
        using var storage = new Storage();
        var clock = new Clock { Now = Now.AddHours(30) };
        var store = new VoiceConsentStore(storage.Locations, clock);
        var record = Draft(store);
        var operation = store.BeginClaimedCreation(record, Guid.NewGuid(), ElevenLabsRegion.Default, Now);
        store.Transition(operation.Id, VoiceOperationState.Dispatched, Now);
        store.Release(operation.Id);
        var deletions = 0;
        var empty = false;
        using var remote = new Remote((request, _) =>
        {
            if (request.Method == HttpMethod.Delete) { deletions++; return Task.FromResult(Json(404, "{}")); }
            var rows = empty ? Array.Empty<object>() : [new { voice_id = "other", name = record.VoiceName,
                category = "cloned", is_owner = true, created_at_unix = Now.AddMinutes(1).ToUnixTimeSeconds(),
                labels = new { voxclip_record_id = "another-request" } }];
            return Task.FromResult(Json(200, JsonSerializer.Serialize(new { voices = rows, has_more = false })));
        });
        using var client = ElevenLabsVoiceLab.ForTesting(new MemoryKeys(), remote, ElevenLabsRegion.Default);
        var reconciler = new VoiceOperationReconciler(store, _ => client, clock);
        await reconciler.ReconcileAsync(force: true, ct: Token);
        Assert.Equal(0, deletions);
        empty = true;
        await reconciler.ReconcileAsync(force: true, ct: Token);
        Assert.False(store.Operation(operation.Id).Finished);
        Assert.Contains("Checking", store.Operation(operation.Id).DisplayState);
    }
    [Theory]
    [InlineData("subscription_required", VoiceLabErrorKind.PlanUnavailable)]
    [InlineData("feature_not_available", VoiceLabErrorKind.FeatureUnavailable)]
    [InlineData("voice_access_denied", VoiceLabErrorKind.VoiceAccessDenied)]
    [InlineData("model_access_denied", VoiceLabErrorKind.ModelAccessDenied)]
    [InlineData("insufficient_permissions", VoiceLabErrorKind.PermissionMissing)]
    [InlineData("missing_permissions", VoiceLabErrorKind.PermissionMissing)]
    [InlineData("workspace_access_denied", VoiceLabErrorKind.ProviderFailure)]
    public async Task Provider403MapsTheCodeNotEveryResponseToKeyPermissions(string code, VoiceLabErrorKind kind)
    {
        using var remote = new Remote((_, _) => Task.FromResult(Json(403, "{\"detail\":{\"code\":\"" + code + "\"}}")));
        using var client = ElevenLabsVoiceLab.ForTesting(new MemoryKeys(), remote, ElevenLabsRegion.Default);
        Assert.Equal(kind, (await Assert.ThrowsAsync<VoiceLabException>(() => client.DiscoverVoicesAsync(Token))).Kind);
    }
    [Fact]
    public async Task OptionalVoiceMetadataIsSkippedAndOwnClonesAreFiltered()
    {
        using var remote = new Remote((_, _) => Task.FromResult(Json(200,
            "{\"voices\":[{\"voice_id\":\"missingName\",\"category\":\"cloned\"},{\"voice_id\":\"missingCategory\",\"name\":\"Mine\"}," +
            "{\"voice_id\":\"own\",\"name\":\"Mine\",\"category\":\"cloned\",\"is_owner\":true,\"labels\":{\"voxclip_record_id\":\"nonce\"}}," +
            "{\"voice_id\":\"stock\",\"name\":\"Stock\",\"category\":\"premade\"}],\"has_more\":false}")));
        using var client = ElevenLabsVoiceLab.ForTesting(new MemoryKeys(), remote, ElevenLabsRegion.Default);
        var voice = Assert.Single(await client.ListOwnClonesAsync(Token));
        Assert.Equal("own", voice.Id);
        Assert.Equal("nonce", voice.ConsentRecordId);
    }
    [Fact]
    public void SharedRecordAndScribeReplay()
    {
        var record = Fixture();
        record.Validate();
        Assert.DoesNotContain("\"creator\"", JsonSerializer.Serialize(record, VoiceConsentJson.Default.VoiceConsentRecord));
        using var scribe = FixtureLoader.ReadJson("fixtures/voice-lab/consent-scribe.json");
        var words = scribe.RootElement.GetProperty("words").EnumerateArray().Select(word => new RawToken(word.GetProperty("text").GetString()!, false,
            word.GetProperty("start").GetDouble(), word.GetProperty("end").GetDouble(), null, "speaker_0", WordKind.Word, 0)).ToArray();
        var raw = new RawTranscript(new(TranscriptEngine.Elevenlabs, "scribe_v2", null, "x", null), 1,
            new(GroupingEnd.LastToken, GroupingConfidence.Single, false), words, "en", null, true, TimingSource.Native, "fixture-consent-response");
        var statement = new VoiceConsentStatement("en", record.Statement.Text, record.Statement.Nonce);
        Assert.Equal(record.Statement.Stt, VoiceStatementMatch.Verify(raw, statement));
        Assert.Throws<VoiceConsentException>(() => VoiceStatementMatch.Verify(raw with { Language = "et" }, statement));
        Assert.Throws<VoiceConsentException>(() => VoiceStatementMatch.Verify(raw with { Tokens = words[..^1] }, statement));
        Assert.Throws<VoiceConsentException>(() => VoiceStatementMatch.Verify(raw with { Tokens = words.Take(10).ToArray() }, statement));
    }
    [Fact]
    public void SharedStatementUsesFixedMonthsAndDistinctCsprngWords()
    {
        var text = JsonSerializer.Deserialize(FixtureLoader.ReadText("voice-lab/statements.json"), VoiceConsentJson.Default.VoiceConsentText)!;
        foreach (var language in new[] { "en", "et" })
        {
            var words = FixtureLoader.ReadText("voice-lab/nonce-words-" + language + ".txt").Split('\n', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries);
            var statement = text.Statement("  Example\u0085", language, new(2026, 10, 29), words);
            Assert.Equal(4, statement.Nonce.Distinct().Count());
            Assert.Contains(language == "en" ? "29 October 2026" : "29. oktoober 2026", statement.Text);
            Assert.All(statement.Nonce, word => Assert.Contains(word, words));
        }
        Assert.Throws<VoiceConsentException>(() => VoiceConsentText.DisplayName(string.Concat(Enumerable.Repeat("o\u0303", 31))));
        Assert.Throws<VoiceConsentException>(() => VoiceConsentText.DisplayName("Ex\nample"));
        Assert.Equal("\u200bExample", VoiceConsentText.DisplayName(" \u200bExample "));
    }
    [Fact]
    public void EmbeddingEncodingAndWavValidationAreBounded()
    {
        Assert.Equal(new[] { 1f, 0f }, VoiceConsentRecord.DecodeEmbedding("AACAPwAAAAA="));
        Assert.Null(VoiceConsentRecord.DecodeEmbedding("AAAAAA=="));
        Assert.Null(VoiceConsentRecord.DecodeEmbedding("not base64"));
        var wav = VoiceLabTestCalls.SyntheticWav(44100, 44100 * 6, 8000, junkBytes: 3);
        Assert.Equal(44100, VoiceConsentAudio.ValidateWav(wav).Rate);
        Assert.Equal(96000, VoiceConsentAudio.Pcm16k(wav).Length);
        BinaryPrimitives.WriteUInt32LittleEndian(wav.AsSpan(4), 0);
        Assert.Throws<VoiceLabException>(() => VoiceConsentAudio.Pcm16k(wav));
    }
    [Fact]
    public async Task AtomicWriteAndClaimHidesLiveIntentFromAllReconcilers()
    {
        using var storage = new Storage();
        var store = new VoiceConsentStore(storage.Locations);
        var record = Draft(store);
        var id = Guid.NewGuid();
        store.BeginClaimedCreation(record, id, ElevenLabsRegion.Default, Now);
        using var remote = new Remote((_, _) => throw new InvalidOperationException("An intent must not call a provider."));
        using var client = ElevenLabsVoiceLab.ForTesting(new MemoryKeys(), remote, ElevenLabsRegion.Default);
        var other = new VoiceConsentStore(storage.Locations);
        await new VoiceOperationReconciler(other, _ => client).ReconcileAsync(ct: Token);
        Assert.Equal(VoiceOperationState.Intent, store.Operation(id).State);
        Assert.Empty(store.ActiveVoices());
        Assert.False(store.Claim(id));
        store.Release(id);
        await new VoiceOperationReconciler(other, _ => client).ReconcileAsync(ct: Token);
        Assert.Empty(store.Operations());
        Assert.False(File.Exists(Path.Combine(store.Root, record.RecordId, "statement.wav")));
        Assert.False(File.Exists(Path.Combine(store.Root, record.RecordId, "record.json")));
        Assert.Equal(0, remote.Calls);
    }
    [Fact]
    public async Task FailedListingAfterDeadlineKeepsBackoffButDoesNotBlockCreation()
    {
        using var storage = new Storage();
        var clock = new Clock { Now = Now.AddHours(25) };
        var store = new VoiceConsentStore(storage.Locations, clock);
        var record = Draft(store);
        var operation = store.BeginClaimedCreation(record, Guid.NewGuid(), ElevenLabsRegion.Default, Now);
        store.Transition(operation.Id, VoiceOperationState.Dispatched, Now);
        store.Release(operation.Id);
        using var remote = new Remote((_, _) => Task.FromResult(Json(503, "{}")));
        using var client = ElevenLabsVoiceLab.ForTesting(new MemoryKeys(), remote, ElevenLabsRegion.Default);
        var reconciler = new VoiceOperationReconciler(store, _ => client, clock);
        await Assert.ThrowsAsync<VoiceLabException>(() => reconciler.ReconcileAsync(ct: Token));
        var current = store.Operation(operation.Id);
        Assert.False(current.BlocksCreation(clock.Now));
        Assert.False(current.Finished);
        Assert.Equal(clock.Now.AddSeconds(30), current.NextAttemptAt);
        Assert.False(File.Exists(Path.Combine(store.Root, record.RecordId, "statement.wav")));
        Assert.False(File.Exists(Path.Combine(store.Root, record.RecordId, "record.json")));
        Assert.Equal(record.Statement.AudioSha256, current.Audit!.StatementSha256);
        var second = store.BeginClaimedCreation(Draft(store), Guid.NewGuid(), ElevenLabsRegion.Default, clock.Now);
        store.Release(second.Id);
        await reconciler.ReconcileAsync(operation.Id, ct: Token);
        Assert.Equal(1, remote.Calls);
    }
    [Fact]
    public async Task SuccessfulEmptyListingAloneAbandonsAtDeadline()
    {
        using var storage = new Storage();
        var clock = new Clock();
        var store = new VoiceConsentStore(storage.Locations, clock);
        var operation = store.BeginClaimedCreation(Draft(store), Guid.NewGuid(), ElevenLabsRegion.Default, Now);
        store.Transition(operation.Id, VoiceOperationState.Dispatched, Now);
        store.Release(operation.Id);
        using var remote = new Remote((_, _) => Task.FromResult(Json(200, "{\"voices\":[],\"has_more\":false}")));
        using var client = ElevenLabsVoiceLab.ForTesting(new MemoryKeys(), remote, ElevenLabsRegion.Default);
        var reconciler = new VoiceOperationReconciler(store, _ => client, clock);
        await reconciler.ReconcileAsync(ct: Token);
        Assert.Equal(Now.AddSeconds(30), store.Operation(operation.Id).NextAttemptAt);
        clock.Now = Now.AddHours(24);
        await reconciler.ReconcileAsync(ct: Token);
        Assert.Equal(VoiceOperationState.Abandoned, store.Operation(operation.Id).State);
        Assert.Equal(2, remote.Calls);
    }
    [Fact]
    public async Task LateVoiceAndRemote404LeaveMinimalNonAuthorizingAudit()
    {
        using var storage = new Storage();
        var clock = new Clock { Now = Now.AddHours(30) };
        var store = new VoiceConsentStore(storage.Locations, clock);
        var record = Draft(store);
        var operation = store.BeginClaimedCreation(record, Guid.NewGuid(), ElevenLabsRegion.Default, Now);
        store.Transition(operation.Id, VoiceOperationState.Dispatched, Now);
        store.Release(operation.Id);
        using var remote = new Remote((request, _) => Task.FromResult(request.Method == HttpMethod.Delete ? Json(404, "{}") : Json(200,
            "{\"voices\":[{\"voice_id\":\"late\",\"name\":\"Mine\",\"category\":\"cloned\",\"is_owner\":true,\"labels\":{\"voxclip_record_id\":\"" + record.RecordId + "\"}}],\"has_more\":false}")));
        using var client = ElevenLabsVoiceLab.ForTesting(new MemoryKeys(), remote, ElevenLabsRegion.Default);
        await new VoiceOperationReconciler(store, _ => client, clock).ReconcileAsync(ct: Token);
        Assert.Empty(store.Operations());
        var audit = store.AuditTombstone(record.RecordId)!;
        Assert.Equal(record.Statement.AudioSha256, audit.StatementSha256);
        Assert.Equal("late", audit.RemoteVoiceId);
        Assert.NotNull(audit.DeletedAt);
        Assert.Empty(store.ActiveVoices());
        store.State.Live.Clear();
        store.ReconcileAbandonedEnrollments();
        var bytes = File.ReadAllText(Path.Combine(store.Root, record.RecordId, "audit.json"));
        Assert.DoesNotContain(record.Statement.Text, bytes);
        Assert.DoesNotContain(record.Speaker.Embedding, bytes);
        Assert.Equal(audit.StatementSha256, store.AuditTombstone(record.RecordId)!.StatementSha256);
        Assert.Equal(2, remote.Calls);
    }
    [Theory]
    [InlineData("RemoteDeleted")]
    [InlineData("removeStatement")]
    [InlineData("AudioRemoved")]
    [InlineData("tombstoneRecord")]
    [InlineData("Tombstoned")]
    [InlineData("clearOperation")]
    public async Task EachDeletionBoundaryRecoversEvenWithoutFullRecord(string checkpoint)
    {
        using var storage = new Storage();
        var fail = false;
        var store = new VoiceConsentStore(storage.Locations, step => { if (fail && step == checkpoint) throw new IOException("injected"); });
        var record = Draft(store, voice: "own");
        store.Save(record);
        var operation = store.BeginDeletion(record.RecordId, ElevenLabsRegion.Default, Now);
        File.Delete(Path.Combine(store.Root, record.RecordId, "record.json"));
        using var remote = new Remote((_, _) => Task.FromResult(Json(404, "{}")));
        using var client = ElevenLabsVoiceLab.ForTesting(new MemoryKeys(), remote, ElevenLabsRegion.Default);
        var reconciler = new VoiceOperationReconciler(store, _ => client);
        fail = true;
        await Assert.ThrowsAsync<IOException>(() => reconciler.ReconcileAsync(operation.Id, true, Token));
        fail = false;
        await reconciler.ReconcileAsync(operation.Id, true, Token);
        Assert.Empty(store.Operations());
        Assert.NotNull(store.AuditTombstone(record.RecordId));
        Assert.False(File.Exists(Path.Combine(store.Root, record.RecordId, "statement.wav")));
    }
    [Fact]
    public async Task WithdrawalBeforeTransportAndFailedWithdrawalBothBlockDispatch()
    {
        using var storage = new Storage();
        var fail = false;
        var store = new VoiceConsentStore(storage.Locations, step => { if (fail && step == "deletionIntent") throw new IOException("injected"); });
        var record = Draft(store, voice: "own");
        store.Save(record);
        var requestId = Guid.NewGuid();
        var permit = store.UsePermit(record, requestId);
        var ready = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var resume = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var calls = 0;
        var sending = Task.Run(async () =>
        {
            store.ValidateUse(record);
            ready.SetResult();
            await resume.Task;
            return await permit.Start(() => { calls++; return Task.FromResult(1); }, Token);
        }, Token);
        await ready.Task;
        fail = true;
        Assert.Throws<IOException>(() => store.BeginDeletion(record.RecordId, ElevenLabsRegion.Default, Now));
        resume.SetResult();
        Assert.Equal(VoiceConsentError.Inactive, (await Assert.ThrowsAsync<VoiceConsentException>(async () => await sending)).Kind);
        Assert.Equal(0, calls);
        Assert.Empty(store.Operations());
        fail = false;
        store.BeginDeletion(record.RecordId, ElevenLabsRegion.Default, Now);
        Assert.Throws<VoiceConsentException>(() => store.ValidateUse(record));
    }
    [Fact]
    public async Task StartedTransportIsRecordedAsAmbiguousAndPermitIsSingleUse()
    {
        using var storage = new Storage();
        var store = new VoiceConsentStore(storage.Locations);
        var record = Draft(store, voice: "own");
        store.Save(record);
        var requestId = Guid.NewGuid();
        var permit = store.UsePermit(record, requestId);
        var completed = new TaskCompletionSource<int>(TaskCreationOptions.RunContinuationsAsynchronously);
        var sending = permit.Start(() => completed.Task, Token);
        var operation = store.BeginDeletion(record.RecordId, ElevenLabsRegion.Default, Now);
        Assert.Contains(requestId, operation.AmbiguousDispatchIds!);
        completed.SetResult(7);
        Assert.Equal(7, await sending);
        permit.Finish();
        Assert.Throws<VoiceConsentException>(() => { _ = permit.Start(() => Task.FromResult(1), Token); });
    }
    [Fact]
    public async Task CreateTransitionIsDurableBeforeTransportAndCreateIsNeverReplayed()
    {
        using var storage = new Storage();
        var store = new VoiceConsentStore(storage.Locations);
        var record = Draft(store);
        var id = Guid.NewGuid();
        store.BeginClaimedCreation(record, id, ElevenLabsRegion.Default, Now);
        var permit = store.CreationPermit(record.RecordId, id, record.Statement.AudioSha256);
        await permit.Start(() => { Assert.Equal(VoiceOperationState.Dispatched, store.Operation(id).State); return Task.FromResult(0); }, Token);
        permit.Finish();
        store.Release(id);
        using var remote = new Remote((request, _) =>
        {
            Assert.Equal(HttpMethod.Get, request.Method);
            return Task.FromResult(Json(200, "{\"voices\":[],\"has_more\":false}"));
        });
        using var client = ElevenLabsVoiceLab.ForTesting(new MemoryKeys(), remote, ElevenLabsRegion.Default);
        await new VoiceOperationReconciler(store, _ => client).ReconcileAsync(force: true, ct: Token);
        Assert.Throws<VoiceConsentException>(() => { _ = permit.Start(() => Task.FromResult(1), Token); });
    }
    [Fact]
    public void FailedIntentWriteCannotClaimOrAuthorizeAndAudioHashIsChecked()
    {
        using var storage = new Storage();
        var store = new VoiceConsentStore(storage.Locations, step => { if (step == "creationIntent") throw new IOException("injected"); });
        var record = Draft(store);
        var id = Guid.NewGuid();
        Assert.Throws<IOException>(() => store.BeginClaimedCreation(record, id, ElevenLabsRegion.Default, Now));
        Assert.True(store.Claim(id));
        store.Release(id);
        File.WriteAllBytes(Path.Combine(store.Root, record.RecordId, "statement.wav"), [0, 1]);
        Assert.Throws<VoiceConsentException>(() => store.Load(record.RecordId));
    }
    [Theory]
    [InlineData("saveRecord")]
    [InlineData("Saved")]
    [InlineData("clearOperation")]
    public async Task KnownCreateResponseSurvivesEveryLocalSaveBoundaryWithoutRepeatingPost(string checkpoint)
    {
        using var storage = new Storage();
        var fail = false;
        var store = new VoiceConsentStore(storage.Locations, step => { if (fail && step == checkpoint) throw new IOException("injected"); });
        var record = Draft(store);
        var operation = store.BeginClaimedCreation(record, Guid.NewGuid(), ElevenLabsRegion.Default, Now);
        store.Transition(operation.Id, VoiceOperationState.Dispatched, Now);
        store.Transition(operation.Id, VoiceOperationState.Created, Now, "created", false);
        store.Release(operation.Id);
        using var remote = new Remote((_, _) => throw new InvalidOperationException("Known creation recovery is local only."));
        using var client = ElevenLabsVoiceLab.ForTesting(new MemoryKeys(), remote, ElevenLabsRegion.Default);
        var reconciler = new VoiceOperationReconciler(store, _ => client);
        fail = true;
        await Assert.ThrowsAsync<IOException>(() => reconciler.ReconcileAsync(ct: Token));
        if (checkpoint != "clearOperation") Assert.Empty(store.ActiveVoices());
        fail = false;
        await new VoiceOperationReconciler(new VoiceConsentStore(storage.Locations), _ => client).ReconcileAsync(force: true, ct: Token);
        Assert.Equal("created", Assert.Single(store.ActiveVoices()).VoiceId);
        Assert.Empty(store.Operations());
        Assert.Equal(0, remote.Calls);
    }
}
