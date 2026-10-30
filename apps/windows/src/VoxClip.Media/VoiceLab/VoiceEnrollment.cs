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
    private sealed record Pending(VoiceLabCloneRequest Request, OwnVoicePolicy Policy, Verified Verified, VoiceConsentSample[] Samples, float[] Embedding);
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
            if (inputs.Length is < 1 or > 24 || inputs.Sum(sample => sample.Seconds) is < 60 or > 120 ||
                inputs.Any(sample => !double.IsFinite(sample.Seconds) || sample.Seconds is < 5 or > 30 || !double.IsFinite(sample.SnrDb)))
                throw new VoiceLabException(VoiceLabErrorKind.InvalidInput);
            var statementWav = store.Statement(recordId);
            if (VoiceConsentStore.Hash(statementWav) != verification.Hash) throw new VoiceConsentException(VoiceConsentError.InvalidRecord);
            var owner = await speaker.EmbeddingAsync(VoiceConsentAudio.Pcm16k(statementWav), ct).ConfigureAwait(false);
            ct.ThrowIfCancellationRequested();
            var accepted = new List<VoiceTrainingSample>();
            var hashes = new List<VoiceConsentSample>();
            foreach (var sample in inputs)
            {
                ct.ThrowIfCancellationRequested();
                var format = VoiceConsentAudio.ValidateWav(sample.Wav);
                if (Math.Abs(format.Frames / (double)format.Rate - sample.Seconds) >= 0.001) throw new VoiceLabException(VoiceLabErrorKind.InvalidAudio);
                float[] candidate;
                try { candidate = await speaker.EmbeddingAsync(VoiceConsentAudio.Pcm16k(sample.Wav), ct).ConfigureAwait(false); }
                catch (VoiceConsentException error) when (error.Kind == VoiceConsentError.SpeakerMismatch) { continue; }
                ct.ThrowIfCancellationRequested();
                var score = SpeakerAudio.Cosine(owner, candidate);
                if (score < threshold) continue;
                accepted.Add(sample);
                hashes.Add(new(VoiceConsentStore.Hash(sample.Wav), sample.Seconds, sample.Source, score));
            }
            if (accepted.Count == 0 || accepted.Sum(sample => sample.Seconds) < 10) throw new VoiceConsentException(VoiceConsentError.SpeakerMismatch);
            var name = VoiceConsentText.DisplayName(displayName);
            var prefix = verification.Statement.Language == "et" ? "Minu nimi on " + name + ". Täna on " : "My name is " + name + ". Today is ";
            if (!verification.Statement.Text.StartsWith(prefix, StringComparison.Ordinal)) throw new VoiceLabException(VoiceLabErrorKind.ConsentRequired);
            var request = new VoiceLabCloneRequest(name, verification.Statement.Language,
                new[] { new VoiceLabCloneSample(VoiceLabCloneSampleRole.ConsentStatement, statementWav) }
                    .Concat(accepted.Select(sample => new VoiceLabCloneSample(VoiceLabCloneSampleRole.Training, sample.Wav.ToArray()))).ToArray(),
                clock.GetUtcNow(), accepted.Any(sample => sample.SnrDb < 20 && !sample.CleanAudioApplied), recordId);
            var policy = new OwnVoicePolicy(recordId, null, true, true, true, true, true);
            var quote = client.PrepareClone(request, policy, Guid.NewGuid());
            pending.Clear();
            pending.Add(quote, new(request, policy, verification, hashes.ToArray(), owner));
            return quote;
        }
        finally { Release(); }
    }
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
            var statement = draft.Verified.Statement;
            var record = new VoiceConsentRecord("voxclip-consent/1", draft.Policy.RecordId, "elevenlabs", "ivc", "pending", draft.Request.DisplayName + " (VoxClip)",
                VoiceConsentStatus.VerificationRequired, draft.Request.CreatedAt, null,
                new(statement.Language, statement.Text, statement.Nonce.ToArray(), "statement.wav", draft.Verified.Hash, draft.Verified.Match),
                draft.Verified.Attestations, draft.Samples, new(model, threshold, VoiceConsentRecord.EncodeEmbedding(draft.Embedding)), new(appVersion, "windows"));
            claim = store.ClaimCreation(record, quote.Review.RequestId, client.Region, clock.GetUtcNow());
            var operation = claim.Operation;
            var policy = claim.DispatchPolicy(token => { token.ThrowIfCancellationRequested(); speaker.ValidateAvailability(); return Task.CompletedTask; });
            VoiceLabCloneResult result;
            try { result = await client.CreateOwnCloneAsync(draft.Request, policy, authorization, ct, operation.Id).ConfigureAwait(false); }
            catch
            {
                var current = claim.Operation;
                if (current.State == VoiceOperationState.Intent)
                {
                    claim.Dispose();
                    claim = null;
                    await reconciler.ReconcileAsync(operation.Id, true, CancellationToken.None).ConfigureAwait(false);
                    throw;
                }
                claim.PreserveAmbiguousDispatch(clock.GetUtcNow());
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
            var operation = store.BeginDeletion(recordId, client.Region, clock.GetUtcNow());
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
    private static void RequireApproval(bool approved, bool enabled)
    {
        if (!approved || !enabled) throw new VoiceLabException(VoiceLabErrorKind.ConsentRequired);
    }
}
