using System.Security.Cryptography;
using System.Text;
using VoxClip.Core.Domain.VoiceLab;

namespace VoxClip.Core.Services.VoiceLab;

/// <summary>Service-local, bounded pending actions. A claim is removed before the first await that can send.</summary>
internal sealed class VoiceLabActionGate
{
    private readonly object gate = new();
    private readonly Dictionary<Guid, VoiceLabPreparedAction> pending = new();
    private readonly TimeProvider clock;
    internal VoiceLabActionGate(TimeProvider? clock = null) => this.clock = clock ?? TimeProvider.System;

    internal VoiceLabPreparedAction Prepare(string fingerprint, VoiceLabEstimate estimate, VoiceLabReview review)
    {
        if (!double.IsFinite(estimate.Units) || estimate.Units <= 0 || estimate.Usd is < 0 || estimate.Credits is < 0)
            throw new VoiceLabException(VoiceLabErrorKind.InvalidInput);
        if (review.RequestId == Guid.Empty || review.Operation != estimate.Operation || review.Provider != estimate.Provider)
            throw new VoiceLabException(VoiceLabErrorKind.InvalidInput);
        fingerprint = BoundFingerprint(fingerprint, estimate, review);
        lock (gate)
        {
            var now = clock.GetUtcNow();
            foreach (var old in pending.Where(entry => entry.Value.ExpiresAt <= now).Select(entry => entry.Key).ToArray()) pending.Remove(old);
            if (pending.Count >= 32) pending.Remove(pending.MinBy(entry => entry.Value.ExpiresAt).Key);
            var action = new VoiceLabPreparedAction(Guid.NewGuid(), fingerprint, now.AddMinutes(5), estimate, review);
            pending.Add(action.Token, action);
            return action;
        }
    }

    internal VoiceLabAuthorization Approve(VoiceLabPreparedAction action, bool affirmative)
    {
        if (!affirmative) throw new VoiceLabException(VoiceLabErrorKind.ConsentRequired);
        lock (gate)
        {
            if (!pending.TryGetValue(action.Token, out var issued) || !ReferenceEquals(issued, action) ||
                issued.ExpiresAt <= clock.GetUtcNow()) throw new VoiceLabException(VoiceLabErrorKind.ConsentRequired);
            return new(action.Token, action.Fingerprint, action.Estimate, action.Review);
        }
    }

    internal Guid Claim(VoiceLabAuthorization approval, string fingerprint, VoiceLabOperation operation, Guid? requestId = null)
    {
        lock (gate)
        {
            var issued = VerifyLocked(approval, fingerprint, operation, requestId);
            pending.Remove(approval.Token);
            return issued.Review.RequestId;
        }
    }

    internal void Verify(VoiceLabAuthorization approval, string fingerprint, VoiceLabOperation operation, Guid? requestId = null)
    {
        lock (gate) _ = VerifyLocked(approval, fingerprint, operation, requestId);
    }

    private VoiceLabPreparedAction VerifyLocked(VoiceLabAuthorization approval, string fingerprint, VoiceLabOperation operation, Guid? requestId)
    {
        if (!pending.TryGetValue(approval.Token, out var issued) || issued.ExpiresAt <= clock.GetUtcNow() ||
            issued.Fingerprint != BoundFingerprint(fingerprint, issued.Estimate, issued.Review) || approval.Fingerprint != issued.Fingerprint ||
            issued.Estimate != approval.Estimate || issued.Review != approval.Review || issued.Estimate.Operation != operation ||
            requestId is { } callerId && issued.Review.RequestId != callerId)
            throw new VoiceLabException(VoiceLabErrorKind.ConsentRequired);
        return issued;
    }

    private static string BoundFingerprint(string fingerprint, VoiceLabEstimate estimate, VoiceLabReview review) =>
        Fingerprint(fingerprint, review.Operation.ToString(), review.RequestId.ToString("D"), review.Provider,
            review.Region?.ToString(), review.Endpoint, review.ModelId, review.VoiceId, review.LanguageMode?.Kind.ToString(),
            review.LanguageMode?.ExpectedLanguage, review.ContentSha256, review.ConsentRecordId, review.DisplayName, review.MimeType,
            review.ConsentPolicy?.RecordId, review.ConsentPolicy?.CloneVoiceId, review.ConsentPolicy?.RecordActive.ToString(),
            review.ConsentPolicy?.ProviderConsentGranted.ToString(), review.ConsentPolicy?.StatementVerified.ToString(),
            review.ConsentPolicy?.SpeakerMatched.ToString(), review.ConsentPolicy?.OwnerConfirmed.ToString(),
            estimate.Units.ToString("R", System.Globalization.CultureInfo.InvariantCulture), estimate.Unit,
            estimate.Usd?.ToString(System.Globalization.CultureInfo.InvariantCulture), estimate.Credits?.ToString(), estimate.Basis);

    internal static string Fingerprint(params string?[] parts)
    {
        using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        foreach (var part in parts)
        {
            var bytes = Encoding.UTF8.GetBytes(part ?? "<null>");
            hash.AppendData(BitConverter.GetBytes(bytes.Length));
            hash.AppendData(bytes);
        }
        return Convert.ToHexStringLower(hash.GetHashAndReset());
    }
    internal static string ContentHash(ReadOnlySpan<byte> data) => Convert.ToHexStringLower(SHA256.HashData(data));
}
