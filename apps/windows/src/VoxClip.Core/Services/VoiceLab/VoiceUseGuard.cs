using System.Buffers.Binary;
using VoxClip.Core.Domain.VoiceLab;
#pragma warning disable CS1591

namespace VoxClip.Core.Services.VoiceLab;

public sealed class VoiceUseGuard(VoiceConsentStore store, VoiceSpeakerCheck? check = null)
{
    private readonly VoiceSpeakerCheck check = check ?? VoiceSpeakerCheck.Unavailable;
    private readonly SemaphoreSlim gate = new(1, 1);
    private readonly HashSet<string> cache = [];
    public async Task<OwnVoicePolicy> AuthorizeAsync(string contentKey, string recordId, float[] speech16k, Guid requestId,
        bool approved, bool voiceChanger = false, CancellationToken ct = default, VoiceLabDispatchBinding? binding = null, long? modelRevision = null)
    {
        if (!approved) throw new VoiceLabException(VoiceLabErrorKind.ConsentRequired);
        if (contentKey.Length == 0 || requestId == Guid.Empty || speech16k.Any(sample => !float.IsFinite(sample))) throw new VoiceLabException(VoiceLabErrorKind.InvalidInput);
        var samples = speech16k.ToArray();
        await gate.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            ct.ThrowIfCancellationRequested();
            var record = store.Load(recordId);
            store.ValidateUse(record);
            if (!this.check.Supports(record.Statement.Language) || this.check.ModelId != record.Speaker.Model || this.check.Threshold != record.Speaker.Threshold ||
                VoiceConsentRecord.DecodeEmbedding(record.Speaker.Embedding) is not { } owner) throw new VoiceConsentException(VoiceConsentError.SpeakerUnavailable);
            this.check.ValidateAvailability();
            var bytes = new byte[samples.Length * 4];
            for (var index = 0; index < samples.Length; index++) BinaryPrimitives.WriteSingleLittleEndian(bytes.AsSpan(index * 4), samples[index]);
            var key = string.Join("\n", contentKey, recordId, voiceChanger, record.Speaker.Embedding, record.Statement.AudioSha256, VoiceConsentStore.Hash(bytes));
            if (!cache.Contains(key))
            {
                var candidate = await this.check.EmbeddingAsync(samples.Take(voiceChanger ? 480000 : 160000).ToArray(), ct).ConfigureAwait(false);
                ct.ThrowIfCancellationRequested();
                if (SpeakerAudio.Cosine(owner, candidate) < record.Speaker.Threshold) throw new VoiceConsentException(VoiceConsentError.VoiceOwnerMismatch);
                store.ValidateUse(record);
                if (cache.Count >= 256) cache.Clear();
                cache.Add(key);
            }
            return store.CreateUsePolicy(record, requestId,
                token => { token.ThrowIfCancellationRequested(); this.check.ValidateAvailability(); store.ValidateUse(record); return Task.CompletedTask; }, binding) with { ModelRevision = modelRevision };
        }
        finally { gate.Release(); }
    }
}
