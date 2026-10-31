using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.Speech;
using VoxClip.Core.Services.VoiceLab;
#pragma warning disable CS1591

namespace VoxClip.Media.VoiceLab;

public sealed class VoiceConsentSaveException(VoiceConsentRecord record) : Exception("Voice creation completed; finish the local consent save before use.")
{
    public VoiceConsentRecord Record { get; } = record;
}

public sealed class VoiceEnrollment
{
    private readonly VoiceConsentStore store;
    private readonly ElevenLabsVoiceLab client;
    private VoiceSpeakerCheck speaker;
    private readonly VoiceOperationReconciler reconciler;
    private readonly Func<byte[], string, CancellationToken, Task<RawTranscript>> scribe;
    private readonly TimeProvider clock;
    private readonly List<long> attempts = [];
    private readonly Dictionary<string, Verified> verified = [];
    private readonly Dictionary<VoiceLabPreparedAction, Pending> pending = [];
    private int busy;
    private sealed record Verified(VoiceConsentStatement Statement, VoiceStatementMatch Match, string Hash, VoiceConsentAttestations Attestations);
    private sealed record Pending(VoiceLabCloneRequest Request, OwnVoicePolicy Policy, Verified Verified, VoiceConsentSample[] Samples, float[] Embedding, long TrainingMs);
    public VoiceEnrollment(VoiceConsentStore store, ElevenLabsVoiceLab client, Func<byte[], string, CancellationToken, Task<RawTranscript>> scribe,
        VoiceSpeakerCheck? speaker = null, VoiceOperationReconciler? reconciler = null, TimeProvider? clock = null)
    {
        this.store = store;
        this.client = client;
        this.scribe = scribe;
        this.speaker = speaker ?? VoiceSpeakerCheck.Unavailable;
        this.clock = clock ?? TimeProvider.System;
        this.reconciler = reconciler ?? new(store, region => region == client.Region ? client : throw new VoiceConsentException(VoiceConsentError.InvalidRecord), this.clock);
    }
    public bool SpeakerAvailable => speaker.Available;
    public void SetSpeakerCheck(VoiceSpeakerCheck check)
    {
        Reserve();
        try { pending.Clear(); speaker = check; }
        finally { Release(); }
    }
    public async Task VerifyAsync(string recordId, VoiceConsentStatement statement, byte[] wav, VoiceConsentAttestations attestations,
        bool approved, bool enabled, CancellationToken ct = default)
    {
        RequireApproval(approved, enabled);
        if (!attestations.Complete) throw new VoiceConsentException(VoiceConsentError.AttestationsRequired);
        Reserve();
        try
        {
            ct.ThrowIfCancellationRequested();
            attempts.RemoveAll(start => clock.GetElapsedTime(start) >= TimeSpan.FromMinutes(10));
            if (attempts.Count >= 3) throw new VoiceConsentException(VoiceConsentError.TooManyAttempts);
            verified.Remove(recordId);
            pending.Clear();
            var snapshot = wav.ToArray();
            var immutableStatement = statement with { Nonce = Array.AsReadOnly(statement.Nonce.ToArray()) };
            store.SaveStatement(snapshot, recordId);
            attempts.Add(clock.GetTimestamp());
            var transcript = await scribe(snapshot.ToArray(), statement.Language, ct).ConfigureAwait(false);
            ct.ThrowIfCancellationRequested();
            var match = VoiceStatementMatch.Verify(transcript, immutableStatement);
            verified[recordId] = new(immutableStatement, match, VoiceConsentStore.Hash(snapshot), attestations);
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
            ct.ThrowIfCancellationRequested();
            var inputs = samples.ToArray();
            if (!speaker.Available || speaker.Threshold is not { } threshold || speaker.ModelId is null) throw new VoiceConsentException(VoiceConsentError.SpeakerUnavailable);
            if (!verified.TryGetValue(recordId, out var verification)) throw new VoiceLabException(VoiceLabErrorKind.ConsentRequired);
            if (!speaker.Supports(verification.Statement.Language)) throw new VoiceConsentException(VoiceConsentError.SpeakerUnavailable);
            TrainingSource(inputs);
            var statementWav = store.Statement(recordId);
            if (VoiceConsentStore.Hash(statementWav) != verification.Hash) throw new VoiceConsentException(VoiceConsentError.InvalidRecord);
            var training = await PrepareTrainingAsync(client, recordId, displayName, verification.Statement, statementWav, inputs, threshold,
                speaker.EmbeddingAsync, speaker.PartEmbeddingsAsync, clock.GetUtcNow(), ct).ConfigureAwait(false);
            pending.Clear();
            pending.Add(training.Quote, new(training.Request, training.Policy, verification, training.Samples, training.Owner, training.TrainingMs));
            return training.Quote;
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
            var format = VoiceConsentAudio.ValidateWav(sample.Wav);
            if (Math.Abs(format.Frames / (double)format.Rate - sample.Seconds) >= 0.001) throw new VoiceLabException(VoiceLabErrorKind.InvalidAudio);
            (float[] Whole, float[][] Parts) candidate;
            try
            {
                var pcm = VoiceConsentAudio.Pcm16k(sample.Wav);
                candidate = source == "project" ? await parts(pcm, ct).ConfigureAwait(false) : (await embed(pcm, ct).ConfigureAwait(false), []);
            }
            catch (VoiceConsentException error) when (error.Kind == VoiceConsentError.SpeakerMismatch) { continue; }
            ct.ThrowIfCancellationRequested();
            // Without speaker labels a project span can hold another voice beside the user's, and the mean of its windows can
            // still pass. Each part must pass on its own, and the span scores as its lowest part.
            var score = candidate.Parts.Aggregate(SpeakerAudio.Cosine(owner, candidate.Whole), (lowest, part) => Math.Min(lowest, SpeakerAudio.Cosine(owner, part)));
            if (score < threshold) continue;
            accepted.Add(sample);
            hashes.Add(new(VoiceConsentStore.Hash(sample.Wav), sample.Seconds, sample.Source, score));
        }
        if (source == "readAloud" ? accepted.Count == 0 || accepted.Sum(sample => sample.Seconds) < 10 : Milliseconds(accepted) < VoiceTrainingSpans.TotalMinMs)
            throw new VoiceConsentException(VoiceConsentError.SpeakerMismatch);
        var name = VoiceConsentText.DisplayName(displayName);
        var prefix = statement.Language == "et" ? "Minu nimi on " + name + ". Täna on " : "My name is " + name + ". Today is ";
        if (!statement.Text.StartsWith(prefix, StringComparison.Ordinal)) throw new VoiceLabException(VoiceLabErrorKind.ConsentRequired);
        var request = new VoiceLabCloneRequest(name, statement.Language,
            new[] { new VoiceLabCloneSample(VoiceLabCloneSampleRole.ConsentStatement, statementWav) }
                .Concat(accepted.Select(sample => new VoiceLabCloneSample(VoiceLabCloneSampleRole.Training, sample.Wav.ToArray()))).ToArray(),
            created, source == "readAloud" && accepted.Any(sample => sample.SnrDb < 20 && !sample.CleanAudioApplied), recordId);
        var policy = new OwnVoicePolicy(recordId, null, true, true, true, true, true);
        return new(client.PrepareClone(request, policy, Guid.NewGuid()), request, policy, hashes.ToArray(), owner, Milliseconds(accepted));
    }
    private static long Milliseconds(IEnumerable<VoiceTrainingSample> samples) =>
        samples.Sum(sample => (long)Math.Round(sample.Seconds * 1000, MidpointRounding.AwayFromZero));
    public async Task<VoiceConsentRecord> CreateAsync(VoiceLabPreparedAction quote, bool approved, bool enabled, string appVersion, CancellationToken ct = default)
    {
        RequireApproval(approved, enabled);
        Reserve();
        VoiceCreationClaim? claim = null;
        try
        {
            ct.ThrowIfCancellationRequested();
            if (!pending.Remove(quote, out var draft)) throw new VoiceLabException(VoiceLabErrorKind.ConsentRequired);
            if (!speaker.Supports(draft.Verified.Statement.Language) || speaker.Threshold is not { } threshold || speaker.ModelId is not { } model)
                throw new VoiceConsentException(VoiceConsentError.SpeakerUnavailable);
            speaker.ValidateAvailability();
            if (VoiceConsentStore.Hash(store.Statement(draft.Policy.RecordId)) != draft.Verified.Hash) throw new VoiceConsentException(VoiceConsentError.InvalidRecord);
            var authorization = client.Approve(quote, true);
            var creator = await client.GetCreatorIdentityAsync(ct).ConfigureAwait(false);
            ct.ThrowIfCancellationRequested();
            var statement = draft.Verified.Statement;
            var record = new VoiceConsentRecord("voxclip-consent/1", draft.Policy.RecordId, "elevenlabs", "ivc", "pending", draft.Request.DisplayName + " (VoxClip)",
                VoiceConsentStatus.VerificationRequired, draft.Request.CreatedAt, null,
                new(statement.Language, statement.Text, statement.Nonce.ToArray(), "statement.wav", draft.Verified.Hash, draft.Verified.Match),
                draft.Verified.Attestations, draft.Samples, new(model, threshold, VoiceConsentRecord.EncodeEmbedding(draft.Embedding)), new(appVersion, "windows"), creator);
            claim = store.ClaimCreation(record, quote.Review.RequestId, client.Region, clock.GetUtcNow());
            var operation = claim.Operation;
            var policy = claim.DispatchPolicy(token => { token.ThrowIfCancellationRequested(); speaker.ValidateAvailability(); return Task.CompletedTask; });
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
            return record;
        }
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
        try { verified.Remove(recordId); pending.Clear(); store.WithdrawCreation(recordId, clock.GetUtcNow()); }
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
