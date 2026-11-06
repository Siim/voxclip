using System.Buffers.Binary;
using System.Text;
using VoxClip.Core.Domain.VoiceLab;
#pragma warning disable CS1591

namespace VoxClip.Core.Services.VoiceLab;

public sealed class VoiceUseGuard(VoiceConsentStore store, VoiceSpeakerCheck? check = null)
{
    private readonly VoiceSpeakerCheck check = check ?? VoiceSpeakerCheck.Unavailable;
    private readonly SemaphoreSlim gate = new(1, 1);
    private readonly HashSet<string> cache = [];
    public async Task<OwnVoicePolicy> AuthorizeAsync(string contentKey, string recordId, float[] speech16k, VoiceLabPreparedAction quote,
        bool approved, bool voiceChanger = false, CancellationToken ct = default, VoiceLabDispatchBinding? binding = null, long? modelRevision = null)
    {
        var requestId = quote.Review.RequestId;
        if (!approved) throw new VoiceLabException(VoiceLabErrorKind.ConsentRequired);
        if (contentKey.Length == 0 || requestId == Guid.Empty || speech16k.Any(sample => !float.IsFinite(sample))) throw new VoiceLabException(VoiceLabErrorKind.InvalidInput);
        var samples = speech16k.ToArray();
        await gate.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            ct.ThrowIfCancellationRequested();
            var record = store.Load(recordId);
            var review = quote.Review;
            var selectsVoice = review.Operation is VoiceLabOperation.TextToSpeech or VoiceLabOperation.VoiceChange;
            if (review.ConsentRecordId != record.RecordId ||
                (selectsVoice ? review.VoiceId != record.VoiceId : review.Operation != VoiceLabOperation.SpeechToText))
                throw new VoiceLabException(VoiceLabErrorKind.ConsentRequired);
            store.ValidateUse(record);
            if (!this.check.Supports(record.Language) || this.check.ModelId != record.Speaker.Model || this.check.Threshold != record.Speaker.Threshold ||
                VoiceConsentRecord.DecodeEmbedding(record.Speaker.Embedding) is null) throw new VoiceConsentException(VoiceConsentError.SpeakerUnavailable);
            this.check.ValidateAvailability();
            var bytes = new byte[samples.Length * 4];
            for (var index = 0; index < samples.Length; index++) BinaryPrimitives.WriteSingleLittleEndian(bytes.AsSpan(index * 4), samples[index]);
            var key = string.Join("\n", contentKey, recordId, voiceChanger, record.ConsentMethod, record.Speaker.Embedding, record.ReferenceAudioSha256, VoiceConsentStore.Hash(bytes),
                ReferencesKey(record));
            if (!cache.Contains(key))
            {
                var candidate = await this.check.EmbeddingAsync(samples.Take(voiceChanger ? 480000 : 160000).ToArray(), ct).ConfigureAwait(false);
                ct.ThrowIfCancellationRequested();
                // The record's own embedding, or a reference learned from the owner's own videos (ADR-R41), at the same τ.
                if (VoiceSpeakerReferences.Match(candidate, record.Speaker) is null) throw new VoiceConsentException(VoiceConsentError.VoiceOwnerMismatch);
                store.ValidateUse(record);
                if (cache.Count >= 256) cache.Clear();
                cache.Add(key);
            }
            return store.CreateUsePolicy(record, requestId,
                token => { token.ThrowIfCancellationRequested(); this.check.ValidateAvailability(); store.ValidateUse(record); return Task.CompletedTask; }, binding) with { ModelRevision = modelRevision };
        }
        finally { gate.Release(); }
    }

    /// <summary>The learned references a cached verdict depended on: forgetting or learning one judges the phrase afresh.</summary>
    private static string ReferencesKey(VoiceConsentRecord record) =>
        VoiceConsentStore.Hash(Encoding.UTF8.GetBytes(string.Join("\n", (record.Speaker.References ?? []).Select(reference => reference.ContentKey + ":" + reference.Embedding))));

    /// <summary>The guard's verdict on every phrase of a Rewrite before anything is priced (voice-lab.md §6.9, ADR-R41; Mac
    /// <c>VoiceUseGuard.screen</c>), on this PC and free:
    /// 1. each phrase's speech is embedded; the best that passes against the record's own embedding teaches this project's reference (one hop);
    /// 2. every phrase is checked against the record's own embedding and the usable references;
    /// 3. what still fails is blocked, for the plan to settle before pricing.
    /// A check that can't run is unchecked: the run's own guard decides at dispatch. Inert while
    /// <see cref="VoiceSpeakerCheck.WindowsNativeParityVerified"/> is false (every phrase is unchecked).</summary>
    public async Task<IReadOnlyList<VoiceGuardVerdict>> ScreenAsync(string contentKey, string recordId, IReadOnlyList<float[]> speech, CancellationToken ct = default)
    {
        var none = speech.Select(_ => VoiceGuardVerdict.Unchecked).ToArray();
        await gate.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            VoiceConsentRecord record;
            string model;
            try
            {
                if (!VoiceSpeakerReferences.ContentKeyValid(contentKey)) return none;
                record = store.Load(recordId);
                store.ValidateUse(record);
                if (!check.Supports(record.Language) || check.ModelId is not { } id || id != record.Speaker.Model || check.Threshold != record.Speaker.Threshold ||
                    VoiceConsentRecord.DecodeEmbedding(record.Speaker.Embedding) is null) return none;
                check.ValidateAvailability();
                model = id;
            }
            catch (Exception error) when (error is VoiceConsentException or VoiceLabException or IOException) { return none; }
            var embedded = new (float[]? Vector, VoiceConsentError? Error)[speech.Count];
            for (var index = 0; index < speech.Count; index++)
            {
                // No speech could be read for this phrase: the run's own guard decides.
                if (speech[index].Length == 0) continue;
                try { embedded[index] = (await check.EmbeddingAsync(speech[index].Take(160_000).ToArray(), ct).ConfigureAwait(false), null); }
                catch (VoiceConsentException error) { embedded[index] = (null, error.Kind); }
                catch (Exception error) when (error is not OperationCanceledException) { }
            }
            // 1. The best phrase that passes on its own teaches this project's reference.
            var current = record;
            var passing = embedded.Where(item => item.Vector is not null)
                .Select(item => (Match: Matched(item.Vector!, record.Speaker), item.Vector))
                .Where(item => item.Match is { ViaReference: false }).MaxBy(item => item.Match!.Score);
            if (passing.Vector is { } best)
                try { current = store.LearnReference(recordId, best, contentKey, model); }
                catch (Exception error) when (error is VoiceReferenceRefusedException or VoiceConsentException or VoiceLabException or IOException) { }
            // 2–3. Every phrase against the statement and the references; too little speech settles as blocked.
            return embedded.Select(item => item switch
            {
                { Vector: { } vector } => Matched(vector, current.Speaker) is { } match ? VoiceGuardVerdict.Passes(match) : VoiceGuardVerdict.Blocked(VoiceConsentError.VoiceOwnerMismatch),
                { Error: VoiceConsentError.SpeakerMismatch } => VoiceGuardVerdict.Blocked(VoiceConsentError.SpeakerMismatch),
                _ => VoiceGuardVerdict.Unchecked
            }).ToArray();
        }
        finally { gate.Release(); }
    }

    private static VoiceSpeakerMatch? Matched(float[] vector, VoiceConsentSpeaker speaker)
    {
        try { return VoiceSpeakerReferences.Match(vector, speaker); }
        catch (VoiceConsentException) { return null; }
    }
}

/// <summary>The guard's free local verdict on one phrase before pricing (<see cref="VoiceUseGuard.ScreenAsync"/>): it passes (with how), is
/// blocked (not the voice owner, or too little speech to check: settled for the Rewrite, never priced), or is unchecked (the check couldn't
/// run here; the run's own guard decides before anything is sent).</summary>
public sealed record VoiceGuardVerdict(VoiceSpeakerMatch? Match, VoiceConsentError? Blocker)
{
    public static VoiceGuardVerdict Unchecked { get; } = new(null, null);
    public static VoiceGuardVerdict Passes(VoiceSpeakerMatch match) => new(match, null);
    public static VoiceGuardVerdict Blocked(VoiceConsentError reason) => new(null, reason);
}
