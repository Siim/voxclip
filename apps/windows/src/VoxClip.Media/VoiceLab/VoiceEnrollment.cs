using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.Speech;
using VoxClip.Core.Services.VoiceLab;
#pragma warning disable CS1591

#if VOXCLIP_ENROLLMENT_TESTS
using VoxClip.Media.VoiceLab;
namespace VoxClip.Tests.Enrollment;
#else
namespace VoxClip.Media.VoiceLab;
#endif

public sealed class VoiceConsentSaveException(VoiceConsentRecord record) : Exception("Voice creation completed; finish the local consent save before use.")
{
    public VoiceConsentRecord Record { get; } = record;
}

public sealed partial class VoiceEnrollment
{
    private readonly VoiceConsentStore store;
    private readonly ElevenLabsVoiceLab client;
    private VoiceSpeakerCheck speaker;
    private readonly VoiceOperationReconciler reconciler;
    private readonly Func<byte[], string, CancellationToken, Task<RawTranscript>>? scribe;
    private readonly TimeProvider clock;
    private readonly Dictionary<string, long> attempts = [];
    private readonly Dictionary<Guid, VoiceEnrollmentPlan> plans = [];
    private readonly Dictionary<string, Verified> verified = [];
    private readonly Dictionary<VoiceLabPreparedAction, Pending> pending = [];
    private int busy;
    private sealed record Verified(VoiceConsentStatement? Statement, VoiceStatementMatch? Match, string Hash, VoiceConsentAttestations Attestations,
        VoiceConsentCreator? Creator = null, VoiceProjectConsent? ProjectConsent = null)
    {
        internal string Language => ProjectConsent?.Language ?? Statement?.Language ?? "";
    }
    private sealed record Pending(VoiceLabCloneRequest Request, OwnVoicePolicy Policy, Verified Verified, VoiceConsentSample[] Samples, float[] Embedding,
        long TrainingMs, string? RecoveryFingerprint = null);
    public VoiceEnrollment(VoiceConsentStore store, ElevenLabsVoiceLab client, Func<byte[], string, CancellationToken, Task<RawTranscript>>? scribe = null,
        VoiceSpeakerCheck? speaker = null, VoiceOperationReconciler? reconciler = null, TimeProvider? clock = null)
    {
        this.store = store;
        this.client = client;
        this.scribe = scribe;
        this.speaker = speaker ?? VoiceSpeakerCheck.Unavailable;
        this.clock = clock ?? TimeProvider.System;
        this.reconciler = reconciler ?? new(store, region => region == client.Region ? client : throw new VoiceConsentException(VoiceConsentError.InvalidRecord), this.clock);
    }
#if !VOXCLIP_ENROLLMENT_TESTS
    public bool SpeakerAvailable => speaker.Available;
    private bool Supports(string language) => speaker.Supports(language);
    private double Threshold => speaker.Threshold ?? throw new VoiceConsentException(VoiceConsentError.SpeakerUnavailable);
    private string Model => speaker.ModelId ?? throw new VoiceConsentException(VoiceConsentError.SpeakerUnavailable);
    private void ValidateSpeaker() => speaker.ValidateAvailability();
    private Task<float[]> Embed(float[] pcm, CancellationToken ct) => speaker.EmbeddingAsync(pcm, ct);
    private Task<(float[] Whole, float[][] Parts)> Parts(float[] pcm, CancellationToken ct) => speaker.PartEmbeddingsAsync(pcm, ct);
    private static byte[] TrainingWav(VoiceTrainingSample sample) => sample.Wav;
#endif
    public void SetSpeakerCheck(VoiceSpeakerCheck check)
    {
        Reserve();
        try { pending.Clear(); plans.Clear(); speaker = check; }
        finally { Release(); }
    }
    private string StatementAttempt(VoiceConsentStatement statement, byte[] wav)
    {
        foreach (var key in attempts.Where(pair => clock.GetElapsedTime(pair.Value) >= TimeSpan.FromMinutes(10)).Select(pair => pair.Key).ToArray()) attempts.Remove(key);
        var identity = VoiceConsentStore.Hash(System.Text.Encoding.UTF8.GetBytes(string.Join("\0", new[] { VoiceConsentStore.Hash(wav) }.Concat(statement.Nonce))));
        if (!attempts.ContainsKey(identity) && attempts.Count >= 3) throw new VoiceConsentException(VoiceConsentError.TooManyAttempts);
        return identity;
    }
    private Verified SaveStatement(string recordId, VoiceConsentStatement statement, byte[] wav, VoiceConsentAttestations attestations)
    {
        if (!attestations.Complete) throw new VoiceConsentException(VoiceConsentError.AttestationsRequired);
        if (!Supports(statement.Language)) throw new VoiceConsentException(VoiceConsentError.SpeakerUnavailable);
        var identity = StatementAttempt(statement, wav);
        verified.Remove(recordId); pending.Clear(); plans.Clear();
        store.ValidateEnrollmentStart(recordId);
        store.ClearEnrollmentRecovery(recordId);
        store.SaveStatement(wav, recordId);
        attempts.TryAdd(identity, clock.GetTimestamp());
        return new(statement with { Nonce = Array.AsReadOnly(statement.Nonce.ToArray()) }, null, VoiceConsentStore.Hash(wav), attestations);
    }
    /// <summary>Shared Scribe boundary for legacy Verify and the single enrollment approval. Speaker embedding precedes Scribe.</summary>
    private async Task<Verified> VerifyStatementAsync(Verified draft, byte[] wav, VoiceLabPreparedAction quote, VoiceLabAuthorization? authorization, CancellationToken ct)
    {
        var statement = draft.Statement ?? throw new VoiceConsentException(VoiceConsentError.InvalidRecord);
        await Embed(VoiceConsentAudio.Pcm16k(wav), ct).ConfigureAwait(false);
        var creator = await client.GetCreatorIdentityAsync(ct).ConfigureAwait(false);
        var approval = authorization ?? client.Approve(quote, true);
        var transcript = scribe is { } test ? await test(wav.ToArray(), statement.Language, ct).ConfigureAwait(false)
            : await client.TranscribeConsentStatementAsync(wav, statement.Language, approval, ct).ConfigureAwait(false);
        ct.ThrowIfCancellationRequested();
        var match = VoiceStatementMatch.Verify(transcript, statement);
        await client.ValidateCreatorAsync(creator, ct).ConfigureAwait(false);
        return draft with { Match = match, Creator = creator };
    }
    public async Task VerifyAsync(string recordId, VoiceConsentStatement statement, byte[] wav, VoiceConsentAttestations attestations,
        bool approved, bool enabled, CancellationToken ct = default, VoiceLabPreparedAction? verificationQuote = null)
    {
        RequireApproval(approved, enabled);
        Reserve();
        try
        {
            ct.ThrowIfCancellationRequested();
            var draft = SaveStatement(recordId, statement, wav, attestations);
            var quote = verificationQuote ?? client.PrepareConsentVerification(wav, statement.Language, Guid.NewGuid());
            verified[recordId] = await VerifyStatementAsync(draft, wav, quote, null, ct).ConfigureAwait(false);
        }
        finally { Release(); }
    }
    private async Task<VoiceLabPreparedAction> PrepareDraftAsync(string recordId, string displayName, IReadOnlyList<VoiceTrainingSample> samples, Verified verification, CancellationToken ct)
    {
        var statement = verification.Statement ?? throw new VoiceConsentException(VoiceConsentError.InvalidRecord);
        if (!Supports(statement.Language)) throw new VoiceConsentException(VoiceConsentError.SpeakerUnavailable);
        var statementWav = store.Statement(recordId);
        if (VoiceConsentStore.Hash(statementWav) != verification.Hash) throw new VoiceConsentException(VoiceConsentError.InvalidRecord);
        var training = await PrepareTrainingAsync(client, recordId, displayName, statement, statementWav, samples.ToArray(), Threshold, Embed, Parts, clock.GetUtcNow(), ct).ConfigureAwait(false);
        pending.Clear();
        pending.Add(training.Quote, new(training.Request, training.Policy, verification, training.Samples, training.Owner, training.TrainingMs));
        return training.Quote;
    }
    public async Task<VoiceEnrollmentPlan> PreparePlanAsync(string recordId, VoiceConsentStatement statement, byte[] wav, VoiceConsentAttestations attestations,
        string displayName, IReadOnlyList<VoiceTrainingSample> samples, bool enabled, CancellationToken ct = default)
    {
        if (!enabled) throw new VoiceLabException(VoiceLabErrorKind.ConsentRequired);
        Reserve();
        try
        {
            ct.ThrowIfCancellationRequested();
            var verification = SaveStatement(recordId, statement, wav, attestations);
            var create = await PrepareDraftAsync(recordId, displayName, samples, verification, ct).ConfigureAwait(false);
            var verify = client.PrepareConsentVerification(wav, statement.Language, Guid.NewGuid());
            var draft = pending[create];
            var quote = EnrollmentQuote.Prepare(verify, create, draft.Request, statement);
            var plan = new VoiceEnrollmentPlan(recordId, quote, draft.TrainingMs, false);
            plans[quote.Id] = plan; return plan;
        }
        finally { Release(); }
    }
    public async Task<VoiceLabPreparedAction> PrepareAsync(string recordId, string displayName, IReadOnlyList<VoiceTrainingSample> samples,
        bool enabled, CancellationToken ct = default)
    {
        if (!enabled) throw new VoiceLabException(VoiceLabErrorKind.ConsentRequired);
        Reserve();
        try
        {
            if (!verified.TryGetValue(recordId, out var verification) || verification.Match is null) throw new VoiceLabException(VoiceLabErrorKind.ConsentRequired);
            var create = await PrepareDraftAsync(recordId, displayName, samples, verification, ct).ConfigureAwait(false);
            var draft = pending[create];
            var quote = EnrollmentQuote.Prepare(null, create, draft.Request, verification.Statement ?? throw new VoiceConsentException(VoiceConsentError.InvalidRecord));
            plans[quote.Id] = new(recordId, quote, draft.TrainingMs, true);
            return create;
        }
        finally { Release(); }
    }
    public async Task<VoiceEnrollmentPlan> PrepareProjectPlanAsync(string recordId, string language, VoiceConsentAttestations attestations,
        string displayName, IReadOnlyList<VoiceTrainingSample> samples, bool enabled, CancellationToken ct = default)
    {
        if (!enabled) throw new VoiceLabException(VoiceLabErrorKind.ConsentRequired);
        if (!attestations.Complete) throw new VoiceConsentException(VoiceConsentError.AttestationsRequired);
        if (!Supports(language)) throw new VoiceConsentException(VoiceConsentError.SpeakerUnavailable);
        Reserve();
        try
        {
            ct.ThrowIfCancellationRequested();
            ValidateSpeaker();
            pending.Clear(); plans.Clear(); verified.Remove(recordId);
            store.ValidateEnrollmentStart(recordId);
            var name = VoiceConsentText.DisplayName(displayName);
            var inputs = samples.ToArray();
            if (TrainingSource(inputs) != "project") throw new VoiceLabException(VoiceLabErrorKind.InvalidInput);
            var accepted = new List<VoiceLabCloneSample>();
            var audits = new List<VoiceConsentSample>();
            float[]? owner = null;
            foreach (var sample in inputs)
            {
                ct.ThrowIfCancellationRequested();
                var wav = TrainingWav(sample).ToArray();
                var format = VoiceConsentAudio.ValidateWav(wav);
                if (Math.Abs(format.Frames / (double)format.Rate - sample.Seconds) >= 0.001) throw new VoiceLabException(VoiceLabErrorKind.InvalidAudio);
                (float[] Whole, float[][] Parts) candidate;
                try { candidate = await Parts(VoiceConsentAudio.Pcm16k(wav), ct).ConfigureAwait(false); }
                catch (VoiceConsentException error) when (error.Kind == VoiceConsentError.SpeakerMismatch) { continue; }
                var reference = owner ?? candidate.Whole;
                var score = candidate.Parts.Aggregate(SpeakerAudio.Cosine(reference, candidate.Whole),
                    (lowest, part) => Math.Min(lowest, SpeakerAudio.Cosine(reference, part)));
                if (score < Threshold) continue;
                owner ??= candidate.Whole.ToArray();
                accepted.Add(new(VoiceLabCloneSampleRole.Training, wav));
                audits.Add(new(VoiceConsentStore.Hash(wav), sample.Seconds, "project", score));
            }
            var milliseconds = audits.Sum(sample => (long)Math.Floor(sample.Seconds * 1000 + 0.5));
            if (owner is null || accepted.Count == 0 || milliseconds < 30000) throw new VoiceConsentException(VoiceConsentError.SpeakerMismatch);
            store.ClearEnrollmentRecovery(recordId);
            store.SaveReferenceAudio(accepted[0].Wav, recordId);
            var consent = new VoiceProjectConsent(language, VoiceConsentStore.Hash(accepted[0].Wav));
            var creator = await client.GetCreatorIdentityAsync(ct).ConfigureAwait(false);
            var verification = new Verified(null, null, consent.AudioSha256, attestations, creator, consent);
            var request = new VoiceLabCloneRequest(name, language, accepted.ToArray(), clock.GetUtcNow(), false, recordId);
            var policy = new OwnVoicePolicy(recordId, null, true, true, false, true, true) { ConsentMethod = VoiceConsentMethod.ProjectAttestation };
            ValidateSpeaker();
            var create = client.PrepareEnrollmentClone(request, policy, Guid.NewGuid());
            var quote = EnrollmentQuote.Prepare(create, request, consent, attestations);
            pending[create] = new(request, policy, verification, audits.ToArray(), owner, milliseconds);
            var plan = new VoiceEnrollmentPlan(recordId, quote, milliseconds, false);
            plans[quote.Id] = plan; return plan;
        }
        finally { Release(); }
    }
    public async Task<VoiceEnrollmentPlan> RecoverPlanAsync(string recordId, bool enabled, CancellationToken ct = default)
    {
        if (!enabled) throw new VoiceLabException(VoiceLabErrorKind.ConsentRequired);
        Reserve();
        try
        {
            var recovery = store.EnrollmentRecovery(recordId) ?? throw new VoiceConsentException(VoiceConsentError.InvalidRecord);
            var record = recovery.Record;
            await client.ValidateCreatorAsync(record.CreatorIdentity, ct).ConfigureAwait(false);
            if (!Supports(record.Language) || Model != record.Speaker.Model || Threshold != record.Speaker.Threshold ||
                VoiceConsentRecord.DecodeEmbedding(record.Speaker.Embedding) is not { } embedding) throw new VoiceConsentException(VoiceConsentError.SpeakerUnavailable);
            store.DiscardUnsentEnrollmentOperations(recordId);
            var statement = record.Statement is { } recorded ? new VoiceConsentStatement(recorded.Language, recorded.Text, recorded.Nonce) : null;
            var policy = new OwnVoicePolicy(recordId, null, true, true, record.ConsentMethod == VoiceConsentMethod.RecordedStatement, true, true)
                { ConsentMethod = record.ConsentMethod };
            var create = client.RestoreEnrollmentCreation(recovery.Quote.Create, recovery.Request, policy) ? recovery.Quote.Create
                : client.PrepareEnrollmentClone(recovery.Request, policy, Guid.NewGuid());
            var quote = record.ProjectConsent is { } consent ? EnrollmentQuote.Prepare(create, recovery.Request, consent, record.Attestations)
                : EnrollmentQuote.Prepare(null, create, recovery.Request, statement ?? throw new VoiceConsentException(VoiceConsentError.InvalidRecord));
            var currentRecovery = recovery with { Quote = quote };
            store.SaveEnrollmentRecovery(currentRecovery);
            var verification = new Verified(statement, record.Statement?.Stt, record.ReferenceAudioSha256, record.Attestations, record.CreatorIdentity, record.ProjectConsent);
            pending.Clear(); plans.Clear();
            pending[create] = new(recovery.Request, policy, verification, record.Samples, embedding, recovery.TrainingMilliseconds,
                currentRecovery.SnapshotFingerprint);
            var plan = new VoiceEnrollmentPlan(recordId, quote, recovery.TrainingMilliseconds, record.ConsentMethod == VoiceConsentMethod.RecordedStatement) { IsRecovery = true };
            plans[quote.Id] = plan; return plan;
        }
        finally { Release(); }
    }
    /// <summary>Whole milliseconds of training audio a prepared quote sends after the speaker match, for the confirmation.</summary>
    public long TrainingMilliseconds(VoiceLabPreparedAction quote)
    {
        Reserve();
        try { return pending.TryGetValue(quote, out var draft) ? draft.TrainingMs : throw new VoiceLabException(VoiceLabErrorKind.ConsentRequired); }
        finally { Release(); }
    }
    internal sealed record PreparedTraining(VoiceLabPreparedAction Quote, VoiceLabCloneRequest Request, OwnVoicePolicy Policy,
        VoiceConsentSample[] Samples, float[] Owner, long TrainingMs);
    /// <summary>All samples share one source (§6.5). A read-aloud lasts 60–120 s; project spans number 1–24 and last 30–120 s,
    /// counted in whole milliseconds so they match the §6.5.1 selection exactly.</summary>
    internal static string TrainingSource(IReadOnlyList<VoiceTrainingSample> inputs)
    {
        var source = inputs.Count is >= 1 and <= 24 ? inputs[0].Source : null;
        if (source is not ("readAloud" or "project") || inputs.Any(sample => sample.Source != source || !double.IsFinite(sample.Seconds) ||
            sample.Seconds is < 5 or > 30 || !double.IsFinite(sample.SnrDb)) ||
            (source == "readAloud" ? inputs.Sum(sample => sample.Seconds) is < 60 or > 120 : Milliseconds(inputs) is < VoiceTrainingSpans.TotalMinMs or > VoiceTrainingSpans.TotalMaxMs))
            throw new VoiceLabException(VoiceLabErrorKind.InvalidInput);
        return source;
    }
    /// <summary>The §6.6 speaker match on every sample, on device and before any request: a sample whose embedding fails or scores
    /// below τ is dropped and never replaced. A read-aloud scores on its mean; a project span scores as the lowest of its mean and
    /// its parts (<see cref="SpeakerAudio.PartEmbeddings"/>). Fewer than 10 s of read-aloud or 30 s of project spans left is a
    /// speaker mismatch. The quote sends the consent statement first, then the kept samples in caller order.</summary>
    internal static async Task<PreparedTraining> PrepareTrainingAsync(ElevenLabsVoiceLab client, string recordId, string displayName,
        VoiceConsentStatement statement, byte[] statementWav, IReadOnlyList<VoiceTrainingSample> inputs, double threshold,
        Func<float[], CancellationToken, Task<float[]>> embed, Func<float[], CancellationToken, Task<(float[] Whole, float[][] Parts)>> parts,
        DateTimeOffset created, CancellationToken ct)
    {
        var source = TrainingSource(inputs);
        var owner = await embed(VoiceConsentAudio.Pcm16k(statementWav), ct).ConfigureAwait(false);
        ct.ThrowIfCancellationRequested();
        var accepted = new List<VoiceTrainingSample>();
        var hashes = new List<VoiceConsentSample>();
        foreach (var sample in inputs)
        {
            ct.ThrowIfCancellationRequested();
            var format = VoiceConsentAudio.ValidateWav(TrainingWav(sample));
            if (Math.Abs(format.Frames / (double)format.Rate - sample.Seconds) >= 0.001) throw new VoiceLabException(VoiceLabErrorKind.InvalidAudio);
            (float[] Whole, float[][] Parts) candidate;
            try
            {
                var pcm = VoiceConsentAudio.Pcm16k(TrainingWav(sample));
                candidate = source == "project" ? await parts(pcm, ct).ConfigureAwait(false) : (await embed(pcm, ct).ConfigureAwait(false), []);
            }
            catch (VoiceConsentException error) when (error.Kind == VoiceConsentError.SpeakerMismatch) { continue; }
            ct.ThrowIfCancellationRequested();
            // Without speaker labels a project span can hold another voice beside the user's, and the mean of its windows can
            // still pass. Each part must pass on its own, and the span scores as its lowest part.
            var score = candidate.Parts.Aggregate(SpeakerAudio.Cosine(owner, candidate.Whole), (lowest, part) => Math.Min(lowest, SpeakerAudio.Cosine(owner, part)));
            if (score < threshold) continue;
            accepted.Add(sample);
            hashes.Add(new(VoiceConsentStore.Hash(TrainingWav(sample)), sample.Seconds, sample.Source, score));
        }
        if (source == "readAloud" ? accepted.Count == 0 || accepted.Sum(sample => sample.Seconds) < 10 : Milliseconds(accepted) < VoiceTrainingSpans.TotalMinMs)
            throw new VoiceConsentException(VoiceConsentError.SpeakerMismatch);
        var name = VoiceConsentText.DisplayName(displayName);
        var prefix = statement.Language == "et" ? "Minu nimi on " + name + ". Täna on " : "My name is " + name + ". Today is ";
        if (!statement.Text.StartsWith(prefix, StringComparison.Ordinal)) throw new VoiceLabException(VoiceLabErrorKind.ConsentRequired);
        var request = new VoiceLabCloneRequest(name, statement.Language,
            new[] { new VoiceLabCloneSample(VoiceLabCloneSampleRole.ConsentStatement, statementWav) }
                .Concat(accepted.Select(sample => new VoiceLabCloneSample(VoiceLabCloneSampleRole.Training, TrainingWav(sample).ToArray()))).ToArray(),
            created, source == "readAloud" && accepted.Any(sample => sample.SnrDb < 20 && !sample.CleanAudioApplied), recordId);
        var policy = new OwnVoicePolicy(recordId, null, true, true, true, true, true);
        return new(client.PrepareEnrollmentClone(request, policy, Guid.NewGuid()), request, policy, hashes.ToArray(), owner, Milliseconds(accepted));
    }
    private static long Milliseconds(IEnumerable<VoiceTrainingSample> samples) =>
        samples.Sum(sample => (long)Math.Round(sample.Seconds * 1000, MidpointRounding.AwayFromZero));
    public Task<VoiceConsentRecord> CreateAsync(VoiceLabPreparedAction quote, bool approved, bool enabled, string appVersion, CancellationToken ct = default)
    {
        if (!plans.TryGetValue(quote.Id, out var plan) || !ReferenceEquals(plan.Quote.Create, quote)) throw new VoiceLabException(VoiceLabErrorKind.ConsentRequired);
        return ExecuteAsync(plan, approved, enabled, appVersion, ct);
    }
    public async Task<VoiceConsentRecord> ExecuteAsync(VoiceEnrollmentPlan plan, bool approved, bool enabled, string appVersion, CancellationToken ct = default)
    {
        RequireApproval(approved, enabled);
        Reserve();
        VoiceCreationClaim? claim = null;
        try
        {
            ct.ThrowIfCancellationRequested();
            if (!plans.TryGetValue(plan.Quote.Id, out var issued) || !ReferenceEquals(issued, plan) || !pending.TryGetValue(plan.Quote.Create, out var draft))
                throw new VoiceLabException(VoiceLabErrorKind.ConsentRequired);
            if (draft.Verified.ProjectConsent is { } consent) plan.Quote.Validate(draft.Request, consent, draft.Verified.Attestations);
            else plan.Quote.Validate(draft.Request, draft.Verified.Statement ?? throw new VoiceConsentException(VoiceConsentError.InvalidRecord));
            if (!Supports(draft.Verified.Language)) throw new VoiceConsentException(VoiceConsentError.SpeakerUnavailable);
            ValidateSpeaker();
            if (VoiceConsentStore.Hash(store.ReferenceAudio(plan.RecordId)) != draft.Verified.Hash) throw new VoiceConsentException(VoiceConsentError.InvalidRecord);
            if (!client.QuotesAreFresh(plan.Quote.Actions)) throw new VoiceLabException(VoiceLabErrorKind.ConsentRequired);
            var creator = await client.ValidateCreationQuoteAsync(plan.Quote.Create, ct).ConfigureAwait(false);
            if (draft.Verified.Creator is { } boundCreator && boundCreator != creator) throw new VoiceCreatorMismatchException();
            if (plan.IsRecovery)
            {
                var recovery = store.EnrollmentRecovery(plan.RecordId) ?? throw new VoiceConsentException(VoiceConsentError.InvalidRecord);
                if (recovery.Quote.Id != plan.Quote.Id || recovery.Quote.Binding != plan.Quote.Binding || recovery.Record.CreatorIdentity != creator)
                    throw new VoiceCreatorMismatchException();
                if (recovery.SnapshotFingerprint != draft.RecoveryFingerprint) throw new VoiceConsentException(VoiceConsentError.InvalidRecord);
            }
            if (plan.VerificationPassed && (draft.Verified.Match is null || draft.Verified.Creator != creator)) throw new VoiceCreatorMismatchException();
            var authorizations = client.ApproveEnrollment(plan.Quote, true);
            plans.Remove(plan.Quote.Id); pending.Remove(plan.Quote.Create); verified.Remove(plan.RecordId);
            if (plan.ConsentMethod == VoiceConsentMethod.RecordedStatement && !plan.VerificationPassed)
                draft = draft with { Verified = await VerifyStatementAsync(draft.Verified, draft.Request.Samples[0].Wav, plan.Quote.Verify!, authorizations[0], ct).ConfigureAwait(false) };
            var authorization = authorizations[^1];
            var statement = draft.Verified.Statement;
            var record = new VoiceConsentRecord(draft.Verified.ProjectConsent is null ? "voxclip-consent/1" : "voxclip-consent/2",
                draft.Policy.RecordId, "elevenlabs", "ivc", "pending", draft.Request.DisplayName + " (VoxClip)",
                VoiceConsentStatus.VerificationRequired, draft.Request.CreatedAt, null,
                statement is null ? null : new(statement.Language, statement.Text, statement.Nonce.ToArray(), "statement.wav", draft.Verified.Hash,
                    draft.Verified.Match ?? throw new VoiceConsentException(VoiceConsentError.InvalidRecord)),
                draft.Verified.Attestations, draft.Samples, new(Model, Threshold, VoiceConsentRecord.EncodeEmbedding(draft.Embedding)), new(appVersion, "windows"), creator,
                ProjectConsent: draft.Verified.ProjectConsent);
            var recoveryQuote = record.ProjectConsent is { } project ? EnrollmentQuote.Prepare(plan.Quote.Create, draft.Request, project, record.Attestations)
                : EnrollmentQuote.Prepare(null, plan.Quote.Create, draft.Request, statement ?? throw new VoiceConsentException(VoiceConsentError.InvalidRecord));
            store.SaveEnrollmentRecovery(new(recoveryQuote, draft.Request, record, draft.TrainingMs));
            ct.ThrowIfCancellationRequested();
            await client.ValidateCreatorAsync(creator, ct).ConfigureAwait(false);
            claim = store.ClaimCreation(record, plan.Quote.Create.Review.RequestId, client.Region, clock.GetUtcNow());
            var operation = claim.Operation;
            var policy = claim.DispatchPolicy(token => { token.ThrowIfCancellationRequested(); ValidateSpeaker(); return Task.CompletedTask; });
            VoiceLabCloneResult result;
            try { result = await client.CreateOwnCloneAsync(draft.Request, policy, authorization, ct, operation.Id).ConfigureAwait(false); }
            catch
            {
                if (await ResolveCreationFailureAsync(claim, reconciler, clock.GetUtcNow()).ConfigureAwait(false))
                {
                    claim = null;
                    throw;
                }
                throw new VoiceConsentException(VoiceConsentError.CreationPending);
            }
            record = record with { VoiceId = result.VoiceId, Status = result.RequiresVerification ? VoiceConsentStatus.VerificationRequired : VoiceConsentStatus.Active };
            verified.Remove(record.RecordId);
            var latest = claim.Operation;
            try
            {
                claim.RecordRemoteResult(result, clock.GetUtcNow());
            }
            catch { throw new VoiceConsentSaveException(record); }
            claim.Dispose();
            claim = null;
            try { await reconciler.ReconcileAsync(operation.Id, true, CancellationToken.None).ConfigureAwait(false); }
            catch { throw new VoiceConsentSaveException(record); }
            if (latest.State == VoiceOperationState.Withdrawing) throw new VoiceConsentException(VoiceConsentError.Inactive);
            store.ClearEnrollmentRecovery(record.RecordId);
            client.DiscardEnrollment(plan.Quote);
            return record;
        }
        catch { client.ReleaseEnrollment(plan.Quote); throw; }
        finally
        {
            claim?.Dispose();
            Release();
        }
    }
    public async Task DeleteAsync(string recordId, bool approved, bool enabled, CancellationToken ct = default)
    {
        RequireApproval(approved, enabled);
        Reserve();
        try
        {
            ct.ThrowIfCancellationRequested();
            await client.ValidateCreatorAsync(store.Load(recordId).CreatorIdentity, ct).ConfigureAwait(false);
            ct.ThrowIfCancellationRequested();
            var operation = store.BeginDeletion(recordId, client.Region, clock.GetUtcNow());
            await reconciler.ReconcileAsync(operation.Id, true, ct).ConfigureAwait(false);
        }
        finally { Release(); }
    }
    public async Task RemoveFromVoxClipOnlyAsync(string recordId, bool approved, bool enabled, CancellationToken ct = default)
    {
        RequireApproval(approved, enabled);
        Reserve();
        try
        {
            ct.ThrowIfCancellationRequested();
            var operation = store.BeginLocalRemoval(recordId, approved, clock.GetUtcNow());
            await reconciler.ReconcileAsync(operation.Id, true, ct).ConfigureAwait(false);
        }
        finally { Release(); }
    }
    public void Cancel(string recordId)
    {
        Reserve();
        try { verified.Remove(recordId); pending.Clear(); plans.Clear(); store.ClearEnrollmentRecovery(recordId); store.WithdrawCreation(recordId, clock.GetUtcNow()); }
        finally { Release(); }
    }
    private void Reserve()
    {
        if (Interlocked.CompareExchange(ref busy, 1, 0) != 0) throw new VoiceLabException(VoiceLabErrorKind.InvalidInput);
    }
    private void Release() => Volatile.Write(ref busy, 0);
    internal static Task<bool> ResolveCreationFailureAsync(VoiceCreationClaim claim, VoiceOperationReconciler reconciler, DateTimeOffset now)
    {
        if (claim.Operation.State == VoiceOperationState.Intent)
        {
            claim.RollbackUndispatched();
            return Task.FromResult(true);
        }
        claim.PreserveAmbiguousDispatch(now);
        return Task.FromResult(false);
    }
    private static void RequireApproval(bool approved, bool enabled)
    {
        if (!approved || !enabled) throw new VoiceLabException(VoiceLabErrorKind.ConsentRequired);
    }
}
