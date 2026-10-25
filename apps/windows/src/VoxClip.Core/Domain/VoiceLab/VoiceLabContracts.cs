using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.LLM;
using VoxClip.Core.Services.Speech;
#pragma warning disable CS1591

namespace VoxClip.Core.Domain.VoiceLab;

public enum VoiceLabOperation { CreateClone, DeleteClone, TextToSpeech, VoiceChange, VoiceRewrite }
public enum VoiceLabErrorKind
{
    InvalidInput, ConsentRequired, SpeakerMismatch, PlanUnavailable, NoVoiceSlots, MissingKey,
    PermissionMissing, Unauthorized, QuotaExceeded, RateLimited, UnsupportedModel,
    UnsupportedEndpoint, UnsupportedFormat, MalformedResponse, InvalidAudio, InvalidAlignment,
    ResponseTooLarge, Cancelled, ProviderFailure, Network
}
public sealed class VoiceLabException(VoiceLabErrorKind kind, string? detail = null) : Exception(kind.ToString())
{
    public VoiceLabErrorKind Kind { get; } = kind;
    // Only an enumerated permission or HTTP status belongs here; never provider text or a key.
    public string? Detail { get; } = detail;
}

/// <summary>Unknown provider price and credits stay unknown. Each preparation creates a fresh estimate.</summary>
public sealed record VoiceLabEstimate(string Provider, VoiceLabOperation Operation, double Units, string Unit,
    decimal? Usd, int? Credits, string Basis);
public enum VoiceLabLanguageModeKind { Explicit, AutoDetected }
public sealed record VoiceLabLanguageMode(VoiceLabLanguageModeKind Kind, string ExpectedLanguage);
/// <summary>The exact destination and input the caller reviews before approving a paid action.</summary>
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
    bool RequiresVerification, bool IsVerified);
public enum VoiceLabVoiceKind { Own, Stock }
public sealed record VoiceLabVoiceChoice(string Id, VoiceLabVoiceKind Kind, OwnVoicePolicy? Policy)
{
    public static VoiceLabVoiceChoice Own(string id, OwnVoicePolicy policy) => new(id, VoiceLabVoiceKind.Own, policy);
    public static VoiceLabVoiceChoice Stock(string id) => new(id, VoiceLabVoiceKind.Stock, null);
}
public sealed record VoiceLabReceipt(string Provider, ElevenLabsRegion Region, string Endpoint, string? ModelId,
    string? VoiceId, Guid ActionId, string? ProviderRequestId);
public sealed record VoiceLabCharacterTiming(string Character, double Start, double End);
/// <summary>Signed PCM16LE, mono at 24 kHz; alignment exists only for timestamped TTS.</summary>
public sealed record VoiceLabAudioResult(byte[] Pcm, int SampleRate,
    IReadOnlyList<VoiceLabCharacterTiming>? Alignment, VoiceLabReceipt Receipt);
public sealed record VoiceLabCloneResult(string VoiceId, bool RequiresVerification, string ConsentRecordId,
    VoiceLabReceipt Receipt);

public enum VoiceRewriteScope { Passage, FullTake }
public sealed record VoiceRewriteRequest(Guid RequestId, VoiceRewriteScope Scope, IReadOnlyList<TimedWord> SourceWords,
    string Instruction, string Language);
/// <summary>Review data cannot synthesize audio or change the original timed words.</summary>
public sealed record VoiceRewriteProposal(Guid Id, VoiceRewriteScope Scope, IReadOnlyList<TimedWord> SourceWords,
    string SourceText, string ProposedText, ConnectorId Connector, string Model, string? ProviderRequestId);
