using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.VoiceLab;
using VoxClip.Media.VoiceLab;
using Xunit;

namespace VoxClip.Media.Tests.VoiceLab;

public sealed partial class VoiceEnrollmentPlanTests
{
    private static Task<VoiceEnrollmentPlan> PrepareProject(Fixture fixture, VoiceConsentAttestations? attestations = null,
        IReadOnlyList<VoiceTrainingSample>? samples = null) => fixture.Service.PrepareProjectPlanAsync(fixture.Id, "en",
        attestations ?? new(true, true, true, fixture.Clock.Now), "Example", samples ?? fixture.Samples(source: "project"), true, ct: Token);
    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task ProjectConsentCreatesOnlyAfterApprovalAndNeverSendsScribe(bool verificationRequired)
    {
        using var fixture = new Fixture(); fixture.Remote.VerificationRequired = verificationRequired;
        var plan = await PrepareProject(fixture);
        Assert.Equal(VoiceConsentMethod.ProjectAttestation, plan.ConsentMethod);
        Assert.False(plan.VerificationPassed); Assert.False(plan.IsRecovery);
        Assert.Null(plan.Quote.Verify); Assert.Single(plan.Quote.Actions);
        Assert.Equal(plan.Quote.Create.Estimate.ToCostEstimate(), plan.Quote.Estimate);
        Assert.Empty(fixture.Remote.Events);
        Assert.False(plan.Quote.Create.Review.ConsentPolicy!.StatementVerified);
        Assert.Equal(VoiceConsentMethod.ProjectAttestation, plan.Quote.Create.Review.ConsentPolicy.ConsentMethod);
        await Assert.ThrowsAsync<VoiceLabException>(() => fixture.Service.ExecuteAsync(plan, false, true, "test", Token));
        Assert.Empty(fixture.Remote.Events);
        var record = await fixture.Service.ExecuteAsync(plan, true, true, "test", Token);
        Assert.Equal(new[] { "plan", "create" }, fixture.Remote.Events);
        Assert.Equal("voxclip-consent/2", record.Schema); Assert.Null(record.Statement);
        Assert.Equal(VoiceProjectConsent.Text, record.ProjectConsent!.ConsentText);
        Assert.Equal(record.Samples[0].Sha256, record.ReferenceAudioSha256);
        Assert.Equal(verificationRequired ? VoiceConsentStatus.VerificationRequired : VoiceConsentStatus.Active, record.Status);
        Assert.Equal(fixture.Store.ReferenceAudio(record.RecordId), Wav(15, 0.06f));
        Assert.Contains("sample-01.wav", fixture.Remote.CreationBody!);
        Assert.Contains("Consent: checkbox project attestation. Reference sha256:" + record.ReferenceAudioSha256, fixture.Remote.CreationBody!);
        Assert.DoesNotContain("consent-statement.wav", fixture.Remote.CreationBody!);
        Assert.DoesNotContain("Consent sha256:", fixture.Remote.CreationBody!);
        await Assert.ThrowsAsync<VoiceLabException>(() => fixture.Service.ExecuteAsync(plan, true, true, "test", Token));
        Assert.Equal(1, fixture.Remote.Events.Count(value => value == "create"));
    }
    [Theory]
    [InlineData("text")]
    [InlineData("acceptedAt")]
    [InlineData("attestations")]
    [InlineData("order")]
    [InlineData("bytes")]
    [InlineData("roles")]
    [InlineData("name")]
    [InlineData("language")]
    [InlineData("createdAt")]
    [InlineData("nonce")]
    [InlineData("noise")]
    public async Task ProjectQuoteBindsExactEvidenceAndOrderedTrainingFiles(string mutation)
    {
        using var fixture = new Fixture { CrashAfterVerify = true };
        var plan = await PrepareProject(fixture);
        await Assert.ThrowsAsync<Crash>(() => fixture.Service.ExecuteAsync(plan, true, true, "test", Token));
        var recovery = fixture.Store.EnrollmentRecovery(fixture.Id)!;
        var request = recovery.Request; var files = request.Samples.ToArray();
        var consent = recovery.Record.ProjectConsent!; var attestations = recovery.Record.Attestations;
        plan.Quote.Validate(request, consent, attestations);
        switch (mutation)
        {
            case "text": consent = consent with { ConsentText = consent.ConsentText + " changed" }; break;
            case "acceptedAt": attestations = attestations with { AcceptedAt = attestations.AcceptedAt.AddSeconds(1) }; break;
            case "attestations": attestations = attestations with { Adult = false }; break;
            case "order": (files[1], files[2]) = (files[2], files[1]); break;
            case "bytes": files[1] = files[1] with { Wav = Wav(15, 0.3f) }; break;
            case "roles": files[0] = files[0] with { Role = VoiceLabCloneSampleRole.ConsentStatement }; break;
            case "name": request = request with { DisplayName = "Different" }; break;
            case "language": request = request with { Language = "et" }; break;
            case "createdAt": request = request with { CreatedAt = request.CreatedAt.AddSeconds(1) }; break;
            case "nonce": request = request with { RecoveryNonce = Guid.NewGuid().ToString("D") }; break;
            case "noise": request = request with { RemoveBackgroundNoise = true }; break;
            default: throw new InvalidOperationException(mutation);
        }
        request = request with { Samples = files };
        if (mutation == "text") Assert.Equal(VoiceConsentError.InvalidRecord,
            Assert.Throws<VoiceConsentException>(() => plan.Quote.Validate(request, consent, attestations)).Kind);
        else Assert.Equal(VoiceLabErrorKind.ConsentRequired, Assert.Throws<VoiceLabException>(() => plan.Quote.Validate(request, consent, attestations)).Kind);
        Assert.Equal(new[] { "plan" }, fixture.Remote.Events);
    }
    [Theory]
    [InlineData(1, true)]
    [InlineData(300, false)]
    public async Task ProjectRecoveryReusesOrRefreshesOnlyCreationQuote(int elapsedSeconds, bool sameQuote)
    {
        using var fixture = new Fixture { CrashAfterVerify = true }; var plan = await PrepareProject(fixture);
        await Assert.ThrowsAsync<Crash>(() => fixture.Service.ExecuteAsync(plan, true, true, "test", Token));
        fixture.Clock.Advance(elapsedSeconds); fixture.Remote.Events.Clear();
        var store = new VoiceConsentStore(fixture.Locations, fixture.Clock);
        using var client = fixture.NewClient(); var service = fixture.NewService(store, client);
        store.ReconcileAbandonedEnrollments(); Assert.Equal(new[] { fixture.Id }, store.RecoverableEnrollments());
        var recovered = await service.RecoverPlanAsync(fixture.Id, true, Token);
        Assert.True(recovered.IsRecovery); Assert.False(recovered.VerificationPassed);
        Assert.Equal(VoiceConsentMethod.ProjectAttestation, recovered.ConsentMethod);
        Assert.Null(recovered.Quote.Verify); Assert.Single(recovered.Quote.Actions);
        Assert.Equal(sameQuote, recovered.Quote.Create.Id == plan.Quote.Create.Id); Assert.Empty(fixture.Remote.Events);
        var record = await service.ExecuteAsync(recovered, true, true, "test", Token);
        Assert.Null(record.Statement); Assert.Equal(new[] { "plan", "create" }, fixture.Remote.Events);
        Assert.Empty(store.RecoverableEnrollments());
    }
    [Theory]
    [InlineData("key")]
    [InlineData("reference")]
    [InlineData("cancel")]
    [InlineData("expired")]
    [InlineData("duration")]
    [InlineData("journal")]
    public async Task ProjectRecoveryRefusesChangedOrExpiredEvidence(string mutation)
    {
        using var fixture = new Fixture { CrashAfterVerify = true }; var plan = await PrepareProject(fixture);
        await Assert.ThrowsAsync<Crash>(() => fixture.Service.ExecuteAsync(plan, true, true, "test", Token));
        switch (mutation)
        {
            case "key": fixture.Keys.Key = "synthetic-other-key"; break;
            case "reference": fixture.Store.SaveReferenceAudio(Wav(15, 0.3f), fixture.Id); break;
            case "cancel": fixture.Service.Cancel(fixture.Id); break;
            case "expired": fixture.Clock.Advance(86400); break;
            case "duration":
                var recovery = fixture.Store.EnrollmentRecovery(fixture.Id)!;
                Assert.Throws<VoiceConsentException>(() => fixture.Store.SaveEnrollmentRecovery(recovery with { TrainingMilliseconds = 59999 }));
                return;
            case "journal":
                var path = Path.Combine(fixture.Store.Root, fixture.Id, "enrollment.json");
                File.WriteAllText(path, "{}"); break;
            default: throw new InvalidOperationException(mutation);
        }
        fixture.Remote.Events.Clear();
        var store = new VoiceConsentStore(fixture.Locations, fixture.Clock);
        using var client = fixture.NewClient(); var service = fixture.NewService(store, client);
        if (mutation == "key") await Assert.ThrowsAsync<VoiceCreatorMismatchException>(() => service.RecoverPlanAsync(fixture.Id, true, Token));
        else Assert.Equal(VoiceConsentError.InvalidRecord, (await Assert.ThrowsAsync<VoiceConsentException>(() => service.RecoverPlanAsync(fixture.Id, true, Token))).Kind);
        Assert.Empty(fixture.Remote.Events);
        if (mutation is "expired" or "journal" or "reference") Assert.False(File.Exists(Path.Combine(store.Root, fixture.Id, "reference.wav")));
    }
    [Fact]
    public async Task ProjectRetainedMinimumAndPerPartChecksCannotBeBypassed()
    {
        using var fixture = new Fixture(); var samples = fixture.Samples(source: "project");
        fixture.Service.SpeakerForTests = new((_, _) => throw new InvalidOperationException("Project matching must inspect every part."),
            (_, ct) => { ct.ThrowIfCancellationRequested(); fixture.Remote.Embeddings++; return Task.FromResult((new float[] { 1, 0 }, new float[][] { [0, 1] })); });
        Assert.Equal(VoiceConsentError.SpeakerMismatch, (await Assert.ThrowsAsync<VoiceConsentException>(() => PrepareProject(fixture, samples: samples))).Kind);
        Assert.Empty(fixture.Remote.Events);
        Assert.False(File.Exists(Path.Combine(fixture.Store.Root, fixture.Id, "reference.wav")));
        Assert.Equal(VoiceLabErrorKind.InvalidInput, (await Assert.ThrowsAsync<VoiceLabException>(() =>
            PrepareProject(fixture, samples: samples[..1]))).Kind);
        Assert.Equal(VoiceConsentError.AttestationsRequired, (await Assert.ThrowsAsync<VoiceConsentException>(() =>
            PrepareProject(fixture, new(true, false, true, fixture.Clock.Now)))).Kind);
    }
    [Fact]
    public async Task RecoveredProjectSnapshotMustRemainCurrentUntilApproval()
    {
        using var fixture = new Fixture { CrashAfterVerify = true }; var plan = await PrepareProject(fixture);
        await Assert.ThrowsAsync<Crash>(() => fixture.Service.ExecuteAsync(plan, true, true, "test", Token));
        var store = new VoiceConsentStore(fixture.Locations, fixture.Clock);
        using var client = fixture.NewClient(); var service = fixture.NewService(store, client);
        var recovered = await service.RecoverPlanAsync(fixture.Id, true, Token);
        var snapshot = store.EnrollmentRecovery(fixture.Id)!;
        store.SaveEnrollmentRecovery(snapshot with { Record = snapshot.Record with { App = snapshot.Record.App with { Version = "changed" } } });
        fixture.Remote.Events.Clear();
        Assert.Equal(VoiceConsentError.InvalidRecord, (await Assert.ThrowsAsync<VoiceConsentException>(() =>
            service.ExecuteAsync(recovered, true, true, "test", Token))).Kind);
        Assert.Equal(new[] { "plan" }, fixture.Remote.Events);
    }
    [Fact]
    public async Task FirstAcceptedProjectSpanBecomesReferenceWithoutReplacingRejectedParts()
    {
        using var fixture = new Fixture(); var samples = fixture.Samples(source: "project");
        var calls = 0;
        fixture.Service.SpeakerForTests = new((_, _) => throw new InvalidOperationException("Project matching must inspect every part."),
            (_, ct) =>
            {
                ct.ThrowIfCancellationRequested(); fixture.Remote.Embeddings++;
                return Task.FromResult((new float[] { 1, 0 }, new float[][] { calls++ == 0 ? [0, 1] : [1, 0] }));
            });
        var plan = await PrepareProject(fixture, samples: samples);
        Assert.Equal(45000, plan.TrainingMilliseconds); Assert.Equal(4, calls); Assert.Empty(fixture.Remote.Events);
        var record = await fixture.Service.ExecuteAsync(plan, true, true, "test", Token);
        Assert.Equal(3, record.Samples.Length);
        Assert.Equal(VoiceConsentStore.Hash(samples[1].Wav), record.ReferenceAudioSha256);
        Assert.Equal(samples[1].Wav, fixture.Store.ReferenceAudio(record.RecordId));
        Assert.DoesNotContain(record.Samples, sample => sample.Sha256 == VoiceConsentStore.Hash(samples[0].Wav));
        Assert.Equal(new[] { "plan", "create" }, fixture.Remote.Events);
    }
    [Fact]
    public async Task ShippingProjectPreparationRemainsClosedBeforeDiskOrProviderAccess()
    {
        using var fixture = new Fixture();
        var shipping = new VoxClip.Media.VoiceLab.VoiceEnrollment(fixture.Store, fixture.Client, clock: fixture.Clock);
        Assert.False(shipping.SpeakerAvailable);
        var failure = await Assert.ThrowsAsync<VoiceConsentException>(() => shipping.PrepareProjectPlanAsync(fixture.Id, "en",
            new(true, true, true, fixture.Clock.Now), "Example", fixture.Samples(source: "project"), true, ct: Token));
        Assert.Equal(VoiceConsentError.SpeakerUnavailable, failure.Kind);
        Assert.Empty(fixture.Remote.Events); Assert.False(Directory.Exists(Path.Combine(fixture.Store.Root, fixture.Id)));
    }
}
