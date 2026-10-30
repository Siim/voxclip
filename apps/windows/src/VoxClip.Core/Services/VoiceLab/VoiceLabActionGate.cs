using System.Security.Cryptography;
using System.Text;
using VoxClip.Core.Domain.VoiceLab;

namespace VoxClip.Core.Services.VoiceLab;

/// <summary>Service-local, bounded pending actions. A claim is removed before the first await that can send.</summary>
internal sealed class VoiceLabActionGate
{
    private readonly object gate = new();
    private readonly Dictionary<Guid, VoiceLabPreparedAction> pending = new();
    private readonly Dictionary<Guid, long> preparedAt = new();
    private readonly Dictionary<Guid, Guid> approvedByRun = new();
    private readonly HashSet<Guid> runs = [];
    private readonly HashSet<Guid> claimedRunActions = [];
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
            foreach (var old in pending.Where(entry => !approvedByRun.ContainsKey(entry.Key) && !Fresh(entry.Value)).Select(entry => entry.Key).ToArray()) Remove(old);
            if (pending.Count >= 32) throw new VoiceLabException(VoiceLabErrorKind.InvalidInput);
            var action = new VoiceLabPreparedAction(Guid.NewGuid(), fingerprint, now.AddMinutes(5), estimate, review);
            pending.Add(action.Token, action);
            preparedAt.Add(action.Token, clock.GetTimestamp());
            return action;
        }
    }

    internal VoiceLabAuthorization Approve(VoiceLabPreparedAction action, bool affirmative)
    {
        if (!affirmative) throw new VoiceLabException(VoiceLabErrorKind.ConsentRequired);
        lock (gate)
        {
            if (!pending.TryGetValue(action.Token, out var issued) || !ReferenceEquals(issued, action) ||
                !Fresh(issued)) throw new VoiceLabException(VoiceLabErrorKind.ConsentRequired);
            return new(action.Token, action.Fingerprint, action.Estimate, action.Review);
        }
    }

    internal Guid Claim(VoiceLabAuthorization approval, string fingerprint, VoiceLabOperation operation, Guid? requestId = null)
    {
        lock (gate)
        {
            var issued = VerifyLocked(approval, fingerprint, operation, requestId);
            if (approvedByRun.ContainsKey(approval.Token))
            {
                if (!claimedRunActions.Add(approval.Token)) throw new VoiceLabException(VoiceLabErrorKind.ConsentRequired);
            }
            else Remove(approval.Token);
            return issued.Review.RequestId;
        }
    }

    internal void Verify(VoiceLabAuthorization approval, string fingerprint, VoiceLabOperation operation, Guid? requestId = null)
    {
        lock (gate) _ = VerifyLocked(approval, fingerprint, operation, requestId);
    }

    private VoiceLabPreparedAction VerifyLocked(VoiceLabAuthorization approval, string fingerprint, VoiceLabOperation operation, Guid? requestId)
    {
        if (!pending.TryGetValue(approval.Token, out var issued) || !Fresh(issued) && !approvedByRun.ContainsKey(issued.Token) ||
            issued.Fingerprint != BoundFingerprint(fingerprint, issued.Estimate, issued.Review) || approval.Fingerprint != issued.Fingerprint ||
            issued.Estimate != approval.Estimate || issued.Review != approval.Review || issued.Estimate.Operation != operation ||
            requestId is { } callerId && issued.Review.RequestId != callerId)
            throw new VoiceLabException(VoiceLabErrorKind.ConsentRequired);
        return issued;
    }
    internal bool QuotesAreFresh(IReadOnlyList<VoiceLabPreparedAction> quotes)
    {
        lock (gate) return quotes.Count > 0 && quotes.All(Fresh);
    }
    internal IReadOnlyList<VoiceLabAuthorization> ApproveRun(Guid id, IReadOnlyList<VoiceLabPreparedAction> quotes, bool affirmative, VoiceLabRunDispatch? dispatch = null)
    {
        lock (gate)
        {
            if (!affirmative || id == Guid.Empty || runs.Contains(id) || quotes.Count is not (2 or 4 or 6) ||
                quotes.Select(quote => quote.Token).Distinct().Count() != quotes.Count ||
                quotes.Select(quote => quote.Review.RequestId).Distinct().Count() != quotes.Count ||
                !quotes.All(Fresh) || quotes.Any(quote => approvedByRun.ContainsKey(quote.Token))) throw new VoiceLabException(VoiceLabErrorKind.ConsentRequired);
            for (var index = 0; index < quotes.Count; index += 2)
                if (quotes[index].Review.Operation != VoiceLabOperation.TextToSpeech || quotes[index + 1].Review.Operation != VoiceLabOperation.SpeechToText)
                    throw new VoiceLabException(VoiceLabErrorKind.InvalidInput);
            runs.Add(id);
            foreach (var quote in quotes) approvedByRun.Add(quote.Token, id);
            return Array.AsReadOnly(quotes.Select(quote => new VoiceLabAuthorization(quote.Token, quote.Fingerprint, quote.Estimate, quote.Review) { RunDispatch = dispatch, IsRunAuthorization = true }).ToArray());
        }
    }
    internal Task<T> StartRunAction<T>(VoiceLabAuthorization approval, Func<Task<T>> transport)
    {
        lock (gate)
        {
            if (!approvedByRun.ContainsKey(approval.Token) || !claimedRunActions.Contains(approval.Token) || !pending.ContainsKey(approval.Token)) throw new VoiceLabException(VoiceLabErrorKind.ConsentRequired);
            Remove(approval.Token);
            return transport();
        }
    }
    internal void ReleaseRun(Guid id, IReadOnlyList<VoiceLabPreparedAction> quotes)
    {
        lock (gate)
        {
            foreach (var quote in quotes)
                if (approvedByRun.GetValueOrDefault(quote.Token) == id) { approvedByRun.Remove(quote.Token); claimedRunActions.Remove(quote.Token); }
            runs.Remove(id);
        }
    }
    internal void DiscardRun(Guid id, IReadOnlyList<VoiceLabPreparedAction> quotes)
    {
        lock (gate)
        {
            foreach (var quote in quotes)
                if (!approvedByRun.TryGetValue(quote.Token, out var owner) || owner == id) Remove(quote.Token);
            runs.Remove(id);
        }
    }
    private bool Fresh(VoiceLabPreparedAction quote) => pending.TryGetValue(quote.Token, out var issued) && ReferenceEquals(issued, quote) &&
        preparedAt.TryGetValue(quote.Token, out var stamp) && clock.GetElapsedTime(stamp) < TimeSpan.FromMinutes(5);
    private void Remove(Guid token)
    {
        pending.Remove(token);
        preparedAt.Remove(token);
        approvedByRun.Remove(token);
        claimedRunActions.Remove(token);
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
