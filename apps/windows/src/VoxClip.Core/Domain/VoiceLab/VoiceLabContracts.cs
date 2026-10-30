using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.LLM;
using VoxClip.Core.Services.Speech;
using VoxClip.Core.Services.VoiceLab;
#pragma warning disable CS1591

namespace VoxClip.Core.Domain.VoiceLab;

public enum VoiceLabOperation { CreateClone, DeleteClone, TextToSpeech, VoiceChange, VoiceRewrite, PatchRewrite }
public enum VoiceLabErrorKind
{
    InvalidInput, ConsentRequired, SpeakerMismatch, PlanUnavailable, NoVoiceSlots, MissingKey,
    PermissionMissing, Unauthorized, QuotaExceeded, RateLimited, UnsupportedModel,
    UnsupportedEndpoint, UnsupportedFormat, MalformedResponse, InvalidAudio, InvalidAlignment,
    ResponseTooLarge, Cancelled, ProviderFailure, Network, FeatureUnavailable, VoiceAccessDenied, ModelAccessDenied
}
public sealed class VoiceLabException(VoiceLabErrorKind kind, string? detail = null) : Exception(kind.ToString())
{
    public VoiceLabErrorKind Kind { get; } = kind;
    // Only an enumerated permission or HTTP status belongs here; never provider text or a key.
    public string? Detail { get; } = detail;
}

/// <summary>Unknown provider price and credits stay unknown. Each preparation creates a fresh estimate.</summary>
public sealed record VoiceLabEstimate(string Provider, VoiceLabOperation Operation, double Units, string Unit,
    decimal? Usd, int? Credits, string Basis)
{
    /// <summary>The same estimate as a shared <see cref="CostEstimate"/>, with the camel-case operation name, for
    /// <see cref="VoiceLabCostPresentation"/> and the spend ledger; Voice Lab §3.1.</summary>
    public CostEstimate ToCostEstimate()
    {
        var name = Operation.ToString();
        return new(Provider, char.ToLowerInvariant(name[0]) + name[1..], Units, Unit, Usd, Credits, Basis);
    }
}
public enum VoiceLabLanguageModeKind { Explicit, AutoDetected }
public sealed record VoiceLabLanguageMode(VoiceLabLanguageModeKind Kind, string ExpectedLanguage);
/// <summary>The exact destination and input the caller reviews before approving a paid action. For a clone, <c>ContentSha256</c>
/// is the consent statement sample; the prepared action binds every sample.</summary>
public sealed record VoiceLabReview(VoiceLabOperation Operation, Guid RequestId, string Provider,
    ElevenLabsRegion? Region, string Endpoint, string? ModelId, string? VoiceId,
    VoiceLabLanguageMode? LanguageMode, string? ContentSha256, string? ConsentRecordId,
    string? DisplayName = null, string? MimeType = null, OwnVoicePolicy? ConsentPolicy = null);

/// <summary>Claimed once by the service before dispatch. Construction is reserved to Core.</summary>
public sealed record VoiceLabPreparedAction
{
    internal VoiceLabPreparedAction(Guid token, string fingerprint, DateTimeOffset expiresAt, VoiceLabEstimate estimate, VoiceLabReview review)
    { Token = token; Fingerprint = fingerprint; ExpiresAt = expiresAt; Estimate = estimate; Review = review; }
    internal Guid Token { get; }
    internal string Fingerprint { get; }
    public DateTimeOffset ExpiresAt { get; }
    public VoiceLabEstimate Estimate { get; }
    public VoiceLabReview Review { get; }
}
public sealed record VoiceLabAuthorization
{
    internal VoiceLabAuthorization(Guid token, string fingerprint, VoiceLabEstimate estimate, VoiceLabReview review)
    { Token = token; Fingerprint = fingerprint; Estimate = estimate; Review = review; }
    internal Guid Token { get; }
    internal string Fingerprint { get; }
    public VoiceLabEstimate Estimate { get; }
    public VoiceLabReview Review { get; }
}

/// <summary>Assertions supplied by the later consent recorder and calibrated speaker matcher. This value does not perform either check.</summary>
public sealed record OwnVoicePolicy(string RecordId, string? CloneVoiceId, bool RecordActive, bool ProviderConsentGranted,
    bool StatementVerified, bool SpeakerMatched, bool OwnerConfirmed)
{
    internal VoiceDispatchPermit? DispatchPermit { get; init; }
    internal Func<CancellationToken, Task>? ValidateDispatch { get; init; }
    public void Validate(string? selectedVoiceId = null)
    {
        if (string.IsNullOrWhiteSpace(RecordId) || !RecordActive || !ProviderConsentGranted || !StatementVerified || !OwnerConfirmed ||
            selectedVoiceId is not null && CloneVoiceId != selectedVoiceId)
            throw new VoiceLabException(VoiceLabErrorKind.ConsentRequired);
        if (!SpeakerMatched) throw new VoiceLabException(VoiceLabErrorKind.SpeakerMismatch);
    }
}

public sealed record VoiceLabModel(string Id, string Name, IReadOnlyList<string> Languages, bool CanSpeak,
    bool CanConvert, int? MaximumTextLength, double? CharacterCostMultiplier)
{
    public bool SupportsTimestampedTts => CanSpeak && Id is not ("eleven_v4" or "eleven_v4_turbo");
}
public sealed record VoiceLabSubscription(string Tier, string Status, int CharacterCount, int CharacterLimit,
    long? NextResetUnix, bool CanClone, int VoiceSlotsUsed, int VoiceLimit)
{
    public bool IsNonCommercial => Tier == "free" || Status == "free";
}
public sealed record VoiceLabVoice(string Id, string Name, string Category, bool IsOwner,
    bool RequiresVerification, bool IsVerified, string? ConsentRecordId = null, DateTimeOffset? CreatedAt = null);
public enum VoiceLabVoiceKind { Own, Stock }
public sealed record VoiceLabVoiceChoice(string Id, VoiceLabVoiceKind Kind, OwnVoicePolicy? Policy)
{
    public static VoiceLabVoiceChoice Own(string id, OwnVoicePolicy policy) => new(id, VoiceLabVoiceKind.Own, policy);
    public static VoiceLabVoiceChoice Stock(string id) => new(id, VoiceLabVoiceKind.Stock, null);
}
/// <summary>Per-request TTS inputs (voice-lab §8.5). Core keeps the 300 Unicode scalars of context nearest the window and drops a cut word.</summary>
public sealed record VoiceLabSpeechOptions(uint Seed, string? PreviousText = null, string? NextText = null);
/// <summary><c>SpendWarning</c> is set when the spend ledger could not record this accepted action as asked; Voice Lab §3.1. The action
/// still succeeded, so the caller shows it as a notice, never as a failure.</summary>
public sealed record VoiceLabReceipt(string Provider, ElevenLabsRegion Region, string Endpoint, string? ModelId,
    string? VoiceId, Guid ActionId, string? ProviderRequestId, VoiceLabSpendWarning? SpendWarning);
public sealed record VoiceLabCharacterTiming(string Character, double Start, double End);
/// <summary>Signed PCM16LE, mono at 24 kHz; alignment exists only for timestamped TTS.</summary>
public sealed record VoiceLabAudioResult(byte[] Pcm, int SampleRate,
    IReadOnlyList<VoiceLabCharacterTiming>? Alignment, VoiceLabReceipt Receipt)
{
    public VoiceLabSpendWarning? SpendWarning => Receipt.SpendWarning;
}
public sealed record VoiceLabCloneResult(string VoiceId, bool RequiresVerification, string ConsentRecordId,
    VoiceLabReceipt Receipt)
{
    public VoiceLabSpendWarning? SpendWarning => Receipt.SpendWarning;
}
public enum VoiceLabCloneSampleRole { ConsentStatement, Training }
/// <summary>A complete mono PCM16 WAV file. Other upload formats wait for spike S5 (voice-lab §6.5).</summary>
public sealed record VoiceLabCloneSample(VoiceLabCloneSampleRole Role, byte[] Wav);
/// <summary>One own-voice clone upload (voice-lab §6.5, §6.7). The single consent statement is sent first, then training samples in caller order.
/// <c>Language</c> is <c>[a-z]{2,3}</c>; <c>CreatedAt</c> is sent as RFC 3339 UTC in whole seconds.</summary>
public sealed record VoiceLabCloneRequest(string DisplayName, string Language, IReadOnlyList<VoiceLabCloneSample> Samples,
    DateTimeOffset CreatedAt, bool RemoveBackgroundNoise, string? RecoveryNonce = null);

public enum VoiceRewriteScope { Passage, FullTake }
/// <summary>One passage or full-take rewrite with its length budget (voice-lab §8.9.1), computed by the caller and bound by the quote.
/// <c>TargetSeconds</c> is <c>w</c>, the part of the window the take must fill: finite, above 0 and at most 600. <c>MinChars</c> and
/// <c>MaxChars</c> bound the new words' <see cref="VoiceLabTextLength"/>, with 1 ≤ MinChars ≤ MaxChars ≤ 5,000.</summary>
public sealed record VoiceRewriteRequest(Guid RequestId, VoiceRewriteScope Scope, IReadOnlyList<TimedWord> SourceWords,
    string Instruction, string Language, double TargetSeconds, int MinChars, int MaxChars);
/// <summary>Review data cannot synthesize audio or change the original timed words. <c>ProposedLength</c> is Core's own
/// <see cref="VoiceLabTextLength"/> of the proposed text, and <c>InRange</c> says whether it lies in the request's range; a proposal
/// outside the range is still returned, as it is (§8.9.1).</summary>
public sealed record VoiceRewriteProposal(Guid Id, VoiceRewriteScope Scope, IReadOnlyList<TimedWord> SourceWords,
    string SourceText, string ProposedText, ConnectorId Connector, string Model, string? ProviderRequestId, int ProposedLength, bool InRange);
