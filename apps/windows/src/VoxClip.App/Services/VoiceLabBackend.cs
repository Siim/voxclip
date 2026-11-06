using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.LLM;
using VoxClip.Core.Services.Logging;
using VoxClip.Core.Services.Project;
using VoxClip.Core.Services.Speech;
using VoxClip.Core.Services.VoiceLab;
using VoxClip.Media.VoiceLab;

namespace VoxClip.App.Services;

internal interface IVoiceLabAccount : IDisposable
{
    Task<VoiceLabSubscription> DiscoverSubscriptionAsync(CancellationToken ct);
    Task<IReadOnlyList<VoiceLabVoice>> DiscoverVoicesAsync(CancellationToken ct);
    Task DeleteAsync(string recordId, CancellationToken ct);
}

internal sealed class VoiceLabBackend(DataLocations data, IKeyProvider keys, ILog log,
    Func<bool> enabled, Func<ElevenLabsRegion> region, Func<CancellationToken, Task> persistConsent,
    TimeProvider? timeProvider = null, Func<ElevenLabsRegion, IVoiceLabAccount>? accountFactory = null,
    Func<IReadOnlyList<string>>? learningProjects = null, Func<string, CancellationToken, Task<VoiceLabProjectSource?>>? readProject = null,
    Func<string, VoiceSpeakerProbe?>? speaker = null, Func<string, CancellationToken, Task>? setRewriteVoice = null, Func<string?>? rewriteVoice = null,
    Func<float[], int, CancellationToken, Task>? play = null, Func<bool?>? matchEachVideo = null,
    Func<bool?, CancellationToken, Task>? setMatchEachVideo = null, Action<string, string>? seedCalibration = null) : IVoiceLabBackend, IDisposable
{
    private readonly TimeProvider clock = timeProvider ?? TimeProvider.System;
    private readonly VoiceConsentStore store = new(data, timeProvider);
    /// <summary>The speaker check for a language. The App makes no speaker check while the parity gate is closed, so this is null and
    /// every free local step (learning, the rebuild and per-video finders) says it is unavailable.</summary>
    private VoiceSpeakerProbe? Speaker(string language) => (speaker ?? (_ => VoiceSpeakerProbe.From(VoiceSpeakerCheck.Unavailable)))(language);
    public IReadOnlyList<string> LearningProjects() => learningProjects?.Invoke() ?? [];
    public bool LearningAvailable(string language) => Enabled && Speaker(language) is not null;
    public async Task<VoiceLabProjectSource?> ReadProjectAsync(string projectPath, CancellationToken ct)
    {
        RequireEnabled(ct);
        return readProject is null ? null : await readProject(projectPath, ct).ConfigureAwait(false);
    }
    public async Task<VoiceReferenceLearnerOutcome> LearnAsync(VoiceLabProjectSource source, string recordId, CancellationToken ct)
    {
        RequireEnabled(ct);
        var record = store.Load(recordId);
        if (Speaker(record.Language) is not { } probe) return VoiceReferenceLearnerOutcome.Unavailable;
        return (await new VoiceReferenceLearner(store, probe, clock).LearnAsync(source.Project, source.Media, recordId, ct).ConfigureAwait(false)).Outcome;
    }
    public Task ForgetReferencesAsync(string recordId, CancellationToken ct)
    {
        RequireEnabled(ct);
        store.ForgetReferences(recordId);
        return Task.CompletedTask;
    }
    /// <summary>The attested creation a rebuild runs through (§6.12): one enrollment per backend, so a prepared plan is still there at the
    /// priced click. It has no speaker check while the parity gate is closed, so its preparation refuses with SpeakerUnavailable.</summary>
    private (ElevenLabsRegion Region, ElevenLabsVoiceLab Client, VoiceEnrollment Enrollment)? rebuildCreation;
    private (ElevenLabsVoiceLab Client, VoiceEnrollment Enrollment) RebuildCreation(CancellationToken ct)
    {
        RequireEnabled(ct);
        var selected = region();
        if (rebuildCreation is { } current && current.Region == selected) return (current.Client, current.Enrollment);
        rebuildCreation?.Client.Dispose();
        var client = new ElevenLabsVoiceLab(keys, selected, log, VoiceLabPrices.Load());
        var enrollment = new VoiceEnrollment(store, client, clock: clock);
        rebuildCreation = (selected, client, enrollment);
        return (client, enrollment);
    }
    public async Task<VoiceRebuildFind> FindRebuildAsync(string recordId, IReadOnlyList<string> projects, Func<int, int, Task> progress, CancellationToken ct)
    {
        RequireEnabled(ct);
        var record = store.Load(recordId);
        var probe = Speaker(record.Language) ?? throw new VoiceRebuildFailedException(VoiceRebuildFailureKind.Unavailable);
        List<VoiceRebuildFinder.Source> sources = [];
        foreach (var path in projects)
            if (readProject is not null && await readProject(path, ct).ConfigureAwait(false) is { } source) sources.Add(new(source.Project, source.Media));
        RequireEnabled(ct);
        try
        {
            var found = await new VoiceRebuildFinder(store, probe).FindAsync(recordId, sources, VoiceRebuildFinder.Rules.Rebuild, progress, ct).ConfigureAwait(false);
            return new(VoiceRebuild.Summary(found.Plan), found.Samples.Select(sample => sample.Seconds).ToArray(), found);
        }
        catch (VoiceRebuildFailedException error) when (error.Kind == VoiceRebuildFailureKind.NotEnough)
        { throw new VoiceRebuildNotEnoughException(error.Milliseconds, error.Noisy); }
    }
    public async Task<VoiceRebuildQuote> PrepareRebuildAsync(VoiceConsentRecord old, VoiceRebuildFind found, VoiceConsentAttestations attestations,
        string displayName, CancellationToken ct)
    {
        var (client, enrollment) = RebuildCreation(ct);
        // The new voice goes to the account that holds the old one.
        await client.ValidateCreatorAsync(old.CreatorIdentity, ct).ConfigureAwait(false);
        var id = Guid.NewGuid().ToString("D");
        var plan = await enrollment.PrepareProjectPlanAsync(id, old.Language, attestations, displayName, ((VoiceRebuildFinder.Found)found.Ticket).Samples,
            Enabled, ct: ct).ConfigureAwait(false);
        return new(id, plan.Quote.Estimate.Usd, plan.TrainingMilliseconds, plan);
    }
    public Task CancelRebuildAsync(VoiceRebuildQuote quote, CancellationToken ct)
    {
        if (rebuildCreation is { } current && quote.Ticket is VoiceEnrollmentPlan plan)
        {
            current.Client.ReleaseEnrollment(plan.Quote);
            try { current.Enrollment.Cancel(quote.RecordId); }
            catch (Exception error) when (error is VoiceConsentException or VoiceLabException or IOException) { }
        }
        return Task.CompletedTask;
    }
    public async Task<VoiceRebuildCreated> ApproveRebuildAsync(string oldRecordId, VoiceRebuildQuote quote, CancellationToken ct)
    {
        var (_, enrollment) = RebuildCreation(ct);
        await persistConsent(ct).ConfigureAwait(false);
        RequireEnabled(ct);
        VoiceConsentRecord record;
        try
        {
            record = await enrollment.ExecuteAsync((VoiceEnrollmentPlan)quote.Ticket, approved: true, enabled: Enabled,
                typeof(VoiceLabBackend).Assembly.GetName().Version?.ToString() ?? "unknown", ct).ConfigureAwait(false);
        }
        catch (VoiceConsentSaveException error) { throw new VoiceLabRebuildSaveException(error.Record); }
        int carried;
        try { carried = store.CarryReferences(oldRecordId, record.RecordId, clock.GetUtcNow()); }
        catch (Exception error) when (error is VoiceConsentException or VoiceLabException or IOException) { carried = 0; }
        return new(record, carried);
    }
    public Task SetRewriteVoiceAsync(string recordId, CancellationToken ct)
    {
        RequireEnabled(ct);
        return setRewriteVoice?.Invoke(recordId, ct) ?? throw new VoiceLabException(VoiceLabErrorKind.InvalidInput);
    }
    public string? RewriteVoice() => rewriteVoice?.Invoke();
    public Task PlayRebuildPieceAsync(VoiceRebuildFind found, int index, CancellationToken ct)
    {
        RequireEnabled(ct);
        var sample = ((VoiceRebuildFinder.Found)found.Ticket).Samples[index];
        var (samples, rate) = sample.Pcm();
        return play?.Invoke(samples, rate, ct) ?? Task.CompletedTask;
    }
    /// <summary>The per-video book (voice-lab.md §6.13), in app data.</summary>
    public VoicePerVideoStore? PerVideoStore { get; } = new(data);
    public bool? MatchEachVideo() => matchEachVideo?.Invoke();
    public Task SetMatchEachVideoAsync(bool? value, CancellationToken ct)
    {
        RequireEnabled(ct);
        return setMatchEachVideo?.Invoke(value, ct) ?? throw new VoiceLabException(VoiceLabErrorKind.InvalidInput);
    }
    public string? VideoVoicePrice()
    {
        try { return VoicePerVideo.PriceLabel(VoiceLabPrices.Load()); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or VoiceLabException) { return null; }
    }
    /// <summary>One video's own speech under the per-video rules (8 dB, 30 s of its own). Behind the closed parity gate there is no speaker
    /// check, so this refuses before reading any media.</summary>
    public async Task<VoiceRebuildFind> FindVideoVoiceAsync(string anchorId, VoiceLabProjectSource source, CancellationToken ct)
    {
        RequireEnabled(ct);
        var record = store.Load(anchorId);
        var probe = Speaker(record.Language) ?? throw new VoiceRebuildFailedException(VoiceRebuildFailureKind.Unavailable);
        try
        {
            var found = await new VoiceRebuildFinder(store, probe).FindAsync(anchorId, [new(source.Project, source.Media)], VoiceRebuildFinder.Rules.PerVideo,
                ct: ct).ConfigureAwait(false);
            return new(VoiceRebuild.Summary(found.Plan), found.Samples.Select(sample => sample.Seconds).ToArray(), found,
                VoicePerVideo.RemovesBackgroundNoise(found.Plan), VoicePerVideo.VideoMs(found.Plan));
        }
        catch (VoiceRebuildFailedException error) when (error.Kind == VoiceRebuildFailureKind.NotEnough)
        { throw new VoiceRebuildNotEnoughException(error.Milliseconds, error.Noisy); }
    }
    /// <summary>A video's voice through the attested creation (§6.13): the anchor's creator checked first, its attestations, the found
    /// speech with the anchor's consent clip first and the noise flag, one journaled creation, then the anchor's references carried one hop.
    /// The shipping enrollment has no speaker check, so preparation refuses with SpeakerUnavailable before any provider access.</summary>
    public async Task<VoiceRebuildCreated> CreateVideoVoiceAsync(VoiceConsentRecord anchor, VoiceRebuildFind found, string displayName, CancellationToken ct)
    {
        // The closed parity gate: no speaker check, so nothing is created, sent or paid for.
        RequireEnabled(ct);
        if (Speaker(anchor.Language) is null) throw new VoiceConsentException(VoiceConsentError.SpeakerUnavailable);
        var (client, enrollment) = RebuildCreation(ct);
        await client.ValidateCreatorAsync(anchor.CreatorIdentity, ct).ConfigureAwait(false);
        var plan = await enrollment.PrepareProjectPlanAsync(Guid.NewGuid().ToString("D"), anchor.Language, anchor.Attestations, displayName,
            ((VoiceRebuildFinder.Found)found.Ticket).Samples, Enabled, removeBackgroundNoise: found.RemovesBackgroundNoise, ct: ct).ConfigureAwait(false);
        var quote = new VoiceRebuildQuote(plan.RecordId, plan.Quote.Estimate.Usd, plan.TrainingMilliseconds, plan);
        return await ApproveRebuildAsync(anchor.RecordId, quote, ct).ConfigureAwait(false);
    }
    public void SeedRateCalibration(string fromRecordId, string toRecordId) => seedCalibration?.Invoke(fromRecordId, toRecordId);
    public async Task<double?> ScoreTakeMatchAsync(VoiceLabTakeAudio take, VoiceLabTakeInput input, CancellationToken ct)
    {
        RequireEnabled(ct);
        return Speaker(input.Language) is { } probe ? await VoicePerVideoMatch.ScoreAsync(take, input, probe, ct).ConfigureAwait(false) : null;
    }
    public void Log(string message) => log.Write(LogLevel.Info, "voice-lab", message);
    public void Dispose() { rebuildCreation?.Client.Dispose(); rebuildCreation = null; }
    internal static void ReconcileLocalStatements(DataLocations data) => new VoiceConsentStore(data).ReconcileAbandonedEnrollments();
    public bool Enabled => enabled();
    private void RequireEnabled(CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        if (!Enabled) throw new VoiceLabException(VoiceLabErrorKind.ConsentRequired);
    }
    public Task<VoiceLabSnapshot> ReadAsync(CancellationToken ct)
    {
        RequireEnabled(ct);
        var installed = false;
        try { new SpeakerModelCatalog().Entry.VerifiedFiles(SpeakerDirectory()); installed = true; }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or VoiceConsentException) { }
        return Task.FromResult(new VoiceLabSnapshot(store.Records(), store.Operations(), installed));
    }
    private string SpeakerDirectory() => Path.Combine(data.Models, new SpeakerModelCatalog().Entry.Id);
    public Task PersistProviderConsentAsync(CancellationToken ct)
    {
        RequireEnabled(ct);
        return persistConsent(ct);
    }
    private ElevenLabsVoiceLab Client(ElevenLabsRegion selected, CancellationToken ct)
    {
        RequireEnabled(ct);
        return new(keys, selected, log);
    }
    private IVoiceLabAccount Account(CancellationToken ct)
    {
        RequireEnabled(ct);
        return accountFactory?.Invoke(region()) ?? new AccountClient(Client(region(), ct), store, clock, () => RequireEnabled(ct));
    }
    public async Task<VoiceLabSubscription> DiscoverSubscriptionAsync(bool refreshVerification, CancellationToken ct)
    {
        using var client = Account(ct);
        var subscription = await client.DiscoverSubscriptionAsync(ct).ConfigureAwait(false);
        if (refreshVerification)
        {
            RequireEnabled(ct);
            var voices = await client.DiscoverVoicesAsync(ct).ConfigureAwait(false);
            store.RefreshVerification(voices);
        }
        return subscription;
    }
    public async Task DeleteAsync(string recordId, CancellationToken ct)
    {
        using var client = Account(ct);
        await client.DiscoverVoicesAsync(ct).ConfigureAwait(false);
        RequireEnabled(ct);
        await client.DeleteAsync(recordId, ct).ConfigureAwait(false);
    }
    public async Task RemoveLocalAsync(string recordId, CancellationToken ct)
    {
        RequireEnabled(ct);
        var operation = store.BeginLocalRemoval(recordId, true, clock.GetUtcNow());
        var reconciler = new VoiceOperationReconciler(store, _ => throw new InvalidOperationException("Local removal must not use a client."), clock);
        await reconciler.ReconcileAsync(operation.Id, true, ct).ConfigureAwait(false);
    }
    public async Task WithdrawAsync(string recordId, CancellationToken ct)
    {
        RequireEnabled(ct);
        store.WithdrawCreation(recordId, clock.GetUtcNow());
        await ReconcileAsync(true, ct).ConfigureAwait(false);
    }
    public Task StopLookingAsync(Guid operationId, CancellationToken ct)
    {
        RequireEnabled(ct);
        store.StopLookingForCreation(operationId, clock.GetUtcNow());
        return Task.CompletedTask;
    }
    public async Task SaveAsync(VoiceConsentRecord record, CancellationToken ct)
    {
        RequireEnabled(ct); store.Save(record);
        await ReconcileAsync(true, ct).ConfigureAwait(false);
    }
    public Task RemoveSpeakerAsync(CancellationToken ct)
    {
        RequireEnabled(ct);
        var directory = SpeakerDirectory();
        if (Directory.Exists(directory))
        {
            if ((File.GetAttributes(directory) & FileAttributes.ReparsePoint) != 0) throw new IOException("The model directory is a link.");
            Directory.Delete(directory, true);
        }
        return Task.CompletedTask;
    }
    public async Task ReconcileAsync(bool force, CancellationToken ct)
    {
        RequireEnabled(ct);
        store.ReconcileAbandonedEnrollments();
        if (!store.Operations().Any(operation => !operation.Finished)) return;
        var clients = new Dictionary<ElevenLabsRegion, ElevenLabsVoiceLab>();
        try
        {
            var reconciler = new VoiceOperationReconciler(store, selected =>
            {
                RequireEnabled(ct);
                if (!clients.TryGetValue(selected, out var client)) clients.Add(selected, client = Client(selected, ct));
                return client;
            }, clock);
            await reconciler.ReconcileAsync(force: force, ct: ct).ConfigureAwait(false);
        }
        finally { foreach (var client in clients.Values) client.Dispose(); }
    }
    private sealed class AccountClient(ElevenLabsVoiceLab client, VoiceConsentStore store, TimeProvider clock, Action guard) : IVoiceLabAccount
    {
        public Task<VoiceLabSubscription> DiscoverSubscriptionAsync(CancellationToken ct) => client.DiscoverSubscriptionAsync(ct);
        public Task<IReadOnlyList<VoiceLabVoice>> DiscoverVoicesAsync(CancellationToken ct) => client.DiscoverVoicesAsync(ct);
        public Task DeleteAsync(string recordId, CancellationToken ct)
        {
            guard();
            var enrollment = new VoiceEnrollment(store, client, (_, _, _) => throw new InvalidOperationException(), clock: clock);
            return enrollment.DeleteAsync(recordId, approved: true, enabled: true, ct);
        }
        public void Dispose() => client.Dispose();
    }
}
