using System.Text.Json;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.Project;
using VoxClip.Core.Services.Speech;
using VoxClip.Core.Services.VoiceLab;
using VoxClip.Core.Tests.Tracks.WinAi;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.VoiceLab;

public sealed class VoiceProjectConsentTests
{
    private static readonly DateTimeOffset Now = new(2026, 11, 2, 0, 0, 0, TimeSpan.Zero);
    private static CancellationToken Token => TestContext.Current.CancellationToken;
    private static VoiceConsentRecord Legacy() => JsonSerializer.Deserialize(FixtureLoader.ReadText("fixtures/voice-lab/consent-record.json"),
        VoiceConsentJson.Default.VoiceConsentRecord)!;
    private static byte[] Wav(int seconds = 30, short value = 2000) => VoiceLabTestCalls.SyntheticWav(16000, seconds * 16000, value);
    private static VoiceConsentRecord Project(byte[] wav) => Legacy() with
    {
        Schema = "voxclip-consent/2", RecordId = Guid.NewGuid().ToString("D"), VoiceId = "pending", Statement = null,
        ProjectConsent = new("en", VoiceConsentStore.Hash(wav)),
        Samples = [new(VoiceConsentStore.Hash(wav), 30, "project", 1)],
        CreatedAt = Now, Attestations = new(true, true, true, Now),
        Creator = new(ElevenLabsRegion.Eu, "0123456789abcdef"), Region = null
    };
    private sealed class Storage : IDisposable
    {
        internal readonly string Root = Path.Combine(Path.GetTempPath(), "voxclip-project-consent-" + Guid.NewGuid().ToString("N"));
        internal DataLocations Locations => new(Root, Path.Combine(Root, "settings.json"), Path.Combine(Root, "Models"), Path.Combine(Root, "Cache"),
            Path.Combine(Root, "Autosave"), Path.Combine(Root, "Secrets"), Path.Combine(Root, "Logs"));
        public void Dispose() { if (Directory.Exists(Root)) Directory.Delete(Root, true); }
    }
    [Fact]
    public void SharedProjectFixtureRoundTripsWithoutInventingStatementEvidence()
    {
        var original = FixtureLoader.ReadText("fixtures/voice-lab/consent-record-project.json");
        var record = JsonSerializer.Deserialize(original, VoiceConsentJson.Default.VoiceConsentRecord)!;
        record.Validate();
        Assert.Equal("voxclip-consent/2", record.Schema);
        Assert.Equal(VoiceConsentMethod.ProjectAttestation, record.ConsentMethod);
        Assert.Null(record.Statement);
        Assert.Equal(VoiceProjectConsent.Text, record.ProjectConsent!.ConsentText);
        Assert.Equal("reference.wav", record.ReferenceAudioFile);
        Assert.Equal(record.Samples[0].Sha256, record.ReferenceAudioSha256);
        Assert.Equal(30, Assert.Single(record.Samples).Seconds);
        Assert.Equal(ElevenLabsRegion.Eu, record.CreatorIdentity.Region);
        Assert.Equal("macos", record.App.Platform);
        var bytes = JsonSerializer.SerializeToUtf8Bytes(record, VoiceConsentJson.Default.VoiceConsentRecord);
        var json = JsonNode.Parse(bytes)!;
        Assert.False(json.AsObject().ContainsKey("statement"));
        Assert.Equal(VoiceProjectConsent.Text, json["projectConsent"]!["text"]!.GetValue<string>());
        Assert.Equal(JsonNode.Parse(original)!.AsObject().Select(pair => pair.Key).Order(), json.AsObject().Select(pair => pair.Key).Order());
        Assert.Equal(bytes, JsonSerializer.SerializeToUtf8Bytes(JsonSerializer.Deserialize(bytes, VoiceConsentJson.Default.VoiceConsentRecord)!,
            VoiceConsentJson.Default.VoiceConsentRecord));
    }
    [Fact]
    public void SharedSchemaKeepsTheTwoEvidenceShapesExclusive()
    {
        using var schema = FixtureLoader.ReadJson("schemas/consent.schema.json");
        var variants = schema.RootElement.GetProperty("oneOf").EnumerateArray().ToArray();
        Assert.Equal(2, variants.Length);
        Assert.Equal("voxclip-consent/1", variants[0].GetProperty("properties").GetProperty("schema").GetProperty("const").GetString());
        Assert.Equal("statement", Assert.Single(variants[0].GetProperty("required").EnumerateArray()).GetString());
        Assert.Equal("projectConsent", Assert.Single(variants[0].GetProperty("not").GetProperty("required").EnumerateArray()).GetString());
        Assert.Equal("voxclip-consent/2", variants[1].GetProperty("properties").GetProperty("schema").GetProperty("const").GetString());
        Assert.Equal("projectConsent", Assert.Single(variants[1].GetProperty("required").EnumerateArray()).GetString());
        Assert.Equal("statement", Assert.Single(variants[1].GetProperty("not").GetProperty("required").EnumerateArray()).GetString());
        Assert.Equal(VoiceProjectConsent.Text, schema.RootElement.GetProperty("properties").GetProperty("projectConsent").GetProperty("properties").GetProperty("text").GetProperty("const").GetString());
    }
    [Fact]
    public void LegacyEncodingAndPolicyRemainRecordedStatementOnly()
    {
        var record = Legacy(); record.Validate();
        Assert.Equal(VoiceConsentMethod.RecordedStatement, record.ConsentMethod);
        Assert.NotNull(record.Statement); Assert.Null(record.ProjectConsent);
        var json = JsonNode.Parse(JsonSerializer.SerializeToUtf8Bytes(record, VoiceConsentJson.Default.VoiceConsentRecord))!.AsObject();
        Assert.True(json.ContainsKey("statement")); Assert.False(json.ContainsKey("projectConsent"));
        Assert.False(json.ContainsKey("consentMethod"));
        var policy = new OwnVoicePolicy(record.RecordId, null, true, true, false, true, true);
        Assert.Equal(VoiceLabErrorKind.ConsentRequired, Assert.Throws<VoiceLabException>(() => policy.Validate()).Kind);
        (policy with { ConsentMethod = VoiceConsentMethod.ProjectAttestation }).Validate();
        Assert.Throws<VoiceLabException>(() => (policy with { ConsentMethod = (VoiceConsentMethod)9 }).Validate());
        Assert.Throws<VoiceConsentException>(() => (record with { ProjectConsent = new("en", record.ReferenceAudioSha256) }).Validate());
    }
    [Theory]
    [InlineData("statement")]
    [InlineData("schema")]
    [InlineData("text")]
    [InlineData("file")]
    [InlineData("hash")]
    [InlineData("language")]
    [InlineData("sample")]
    [InlineData("source")]
    [InlineData("attestation")]
    [InlineData("duration")]
    [InlineData("score")]
    [InlineData("creator")]
    public void TamperedProjectEvidenceIsRefused(string mutation)
    {
        var record = Project(Wav()); var consent = record.ProjectConsent!;
        record = mutation switch
        {
            "statement" => record with { Statement = Legacy().Statement },
            "schema" => record with { Schema = "voxclip-consent/1" },
            "text" => record with { ProjectConsent = consent with { ConsentText = VoiceProjectConsent.Text + " altered" } },
            "file" => record with { ProjectConsent = consent with { AudioFile = "statement.wav" } },
            "hash" => record with { ProjectConsent = consent with { AudioSha256 = new string('A', 64) } },
            "language" => record with { ProjectConsent = consent with { Language = "de" } },
            "sample" => record with { Samples = [record.Samples[0] with { Sha256 = new string('1', 64) }] },
            "source" => record with { Samples = [record.Samples[0] with { Source = "readAloud" }] },
            "attestation" => record with { Attestations = record.Attestations with { OwnVoice = false } },
            "duration" => record with { Samples = [record.Samples[0] with { Seconds = 29.999 }] },
            "score" => record with { Samples = [record.Samples[0] with { SpeakerScore = 0 }] },
            "creator" => record with { Region = ElevenLabsRegion.Default },
            _ => throw new InvalidOperationException(mutation)
        };
        Assert.Equal(VoiceConsentError.InvalidRecord, Assert.Throws<VoiceConsentException>(() => record.Validate()).Kind);
    }
    [Fact]
    public void SavingDeletedConsentRevokesAnAlreadyPreparedDispatch()
    {
        using var storage = new Storage();
        var store = new VoiceConsentStore(storage.Locations);
        var wav = Wav();
        var record = Project(wav) with { VoiceId = "projectVoice", Status = VoiceConsentStatus.Active };
        store.SaveReferenceAudio(wav, record.RecordId);
        store.Save(record);
        var permit = store.UsePermit(record, Guid.NewGuid());
        store.Save(record with { Status = VoiceConsentStatus.Deleted, DeletedAt = Now });
        var dispatched = false;
        var error = Assert.Throws<VoiceConsentException>(() =>
        {
            _ = permit.Start(() => { dispatched = true; return Task.FromResult(1); }, Token);
        });
        Assert.Equal(VoiceConsentError.Inactive, error.Kind);
        Assert.False(dispatched);
    }

    [Fact]
    public async Task StoreUsesPrivateReferenceAndStillRefusesNativeUse()
    {
        using var storage = new Storage(); var store = new VoiceConsentStore(storage.Locations);
        var wav = Wav(); var record = Project(wav) with { VoiceId = "projectVoice", Status = VoiceConsentStatus.Active };
        store.SaveReferenceAudio(wav, record.RecordId); store.Save(record);
        Assert.Equal(wav, store.ReferenceAudio(record.RecordId));
        Assert.Equal(record, store.Load(record.RecordId) with { Samples = record.Samples });
        Assert.Throws<VoiceConsentException>(() => store.SaveStatement(Wav(5), record.RecordId));
        Assert.False(File.Exists(Path.Combine(store.Root, record.RecordId, "statement.wav")));
        if (!OperatingSystem.IsWindows()) Assert.Equal(UnixFileMode.UserRead | UnixFileMode.UserWrite,
            File.GetUnixFileMode(Path.Combine(store.Root, record.RecordId, "reference.wav")));
        var policy = store.CreateDeletionPolicy(record.RecordId);
        Assert.Equal(VoiceConsentMethod.ProjectAttestation, policy.ConsentMethod); Assert.False(policy.StatementVerified);
        Assert.False(VoiceSpeakerCheck.WindowsNativeParityVerified);
        Assert.Equal(VoiceConsentError.SpeakerUnavailable, Assert.Throws<VoiceConsentException>(() => store.CreateUsePolicy(record, Guid.NewGuid(), _ => Task.CompletedTask)).Kind);
        Assert.Equal(VoiceConsentError.SpeakerUnavailable, (await Assert.ThrowsAsync<VoiceConsentException>(() => new VoiceUseGuard(store)
            .AuthorizeAsync("clip", record.RecordId, new float[48000], VoiceLabTestCalls.ConsentUseQuote(record), true, ct: Token))).Kind);
        File.WriteAllBytes(Path.Combine(store.Root, record.RecordId, "reference.wav"), Wav(30, 3000));
        Assert.Throws<VoiceConsentException>(() => store.Load(record.RecordId));
    }
    [Fact]
    public void AuditAndWithdrawalNeverClaimAStatementOrRetainReferenceAudio()
    {
        using var storage = new Storage(); var store = new VoiceConsentStore(storage.Locations);
        var wav = Wav(); var record = Project(wav);
        store.SaveReferenceAudio(wav, record.RecordId);
        var operation = store.BeginClaimedCreation(record, Guid.NewGuid(), ElevenLabsRegion.Eu, Now);
        store.Release(operation.Id);
        var audit = operation.Audit!;
        Assert.Equal(VoiceConsentMethod.ProjectAttestation, audit.Method);
        Assert.Null(audit.StatementSha256); Assert.Equal(record.ReferenceAudioSha256, audit.ReferenceAudioSha256);
        var json = JsonNode.Parse(JsonSerializer.SerializeToUtf8Bytes(audit, VoiceConsentJson.Default.VoiceConsentAudit))!;
        Assert.False(json.AsObject().ContainsKey("statementSha256"));
        Assert.Equal("projectAttestation", json["consentMethod"]!.GetValue<string>());
        Assert.Throws<VoiceConsentException>(() => (audit with { StatementSha256 = record.ReferenceAudioSha256 }).Validate(record.RecordId));
        store.WithdrawCreation(record.RecordId, Now);
        Assert.False(File.Exists(Path.Combine(store.Root, record.RecordId, "reference.wav")));
        Assert.Equal(record.ReferenceAudioSha256, store.Operation(operation.Id).Audit!.ReferenceAudioSha256);
    }
    [Fact]
    public void ProjectReferenceCannotFollowASymlinkOrMixEvidenceKinds()
    {
        using var storage = new Storage(); var store = new VoiceConsentStore(storage.Locations);
        var wav = Wav(); var record = Project(wav);
        store.SaveReferenceAudio(wav, record.RecordId);
        var reference = Path.Combine(store.Root, record.RecordId, "reference.wav");
        var target = Path.Combine(storage.Root, "untouched.wav");
        File.WriteAllBytes(target, wav);
        File.Delete(reference); File.CreateSymbolicLink(reference, target);
        Assert.Throws<VoiceConsentException>(() => store.ReferenceAudio(record.RecordId));
        Assert.Throws<VoiceConsentException>(() => store.Save(record));
        Assert.Equal(wav, File.ReadAllBytes(target));
        File.Delete(reference); store.SaveReferenceAudio(wav, record.RecordId);
        Assert.Throws<VoiceConsentException>(() => store.SaveStatement(Wav(5), record.RecordId));
        Assert.Equal(wav, store.ReferenceAudio(record.RecordId));
    }
    [Theory]
    [InlineData(0)]
    [InlineData(47999)]
    public void CanonicalVadNeedsAnActualCalibratedWindow(int retained)
    {
        Assert.Throws<VoiceInsufficientGeneratedSpeechException>(() => SpeakerAudio.GeneratedWindows(new float[retained]));
        Assert.Single(SpeakerAudio.GeneratedWindows(new float[48000]));
        Assert.Throws<VoiceConsentException>(() => SpeakerAudio.GeneratedWindows([float.NaN]));
        var result = new VoiceLabTakeQaResult(null, null, null, null, [VoiceLabTakeQaFailure.InsufficientGeneratedSpeech]);
        Assert.False(result.Passed); Assert.Null(result.SpeakerScore); Assert.Null(result.TranscriptMatch);
        Assert.False((result with { Failures = [] }).Passed);
        Assert.Equal("\"insufficientGeneratedSpeech\"", JsonSerializer.Serialize(VoiceLabTakeQaFailure.InsufficientGeneratedSpeech));
    }
    [Fact]
    public async Task GeneratedDurationRefusalDoesNotClaimMeasuredMismatchOrEnableNative()
    {
        await Assert.ThrowsAsync<VoiceInsufficientGeneratedSpeechException>(() => VoiceSpeakerCheck.Unavailable.GeneratedEmbeddingAsync(new float[71999], 24000, Token));
        Assert.Equal(VoiceConsentError.SpeakerUnavailable, (await Assert.ThrowsAsync<VoiceConsentException>(() =>
            VoiceSpeakerCheck.Unavailable.GeneratedEmbeddingAsync(new float[72000], 24000, Token))).Kind);
        Assert.Equal(VoiceLabErrorKind.InvalidAudio, (await Assert.ThrowsAsync<VoiceLabException>(() =>
            VoiceSpeakerCheck.Unavailable.GeneratedEmbeddingAsync([float.NaN], 24000, Token))).Kind);
    }
}
