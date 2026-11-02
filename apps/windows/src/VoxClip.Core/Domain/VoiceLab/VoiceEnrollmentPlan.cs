using System.Globalization;
using System.Text.Json.Serialization;
using VoxClip.Core.Services.LLM;
using VoxClip.Core.Services.VoiceLab;
#pragma warning disable CS1591

namespace VoxClip.Core.Domain.VoiceLab;

/// <summary>The consent evidence and ordered training upload bound to one enrollment approval.</summary>
public sealed record EnrollmentQuote(VoiceLabPreparedAction? Verify, VoiceLabPreparedAction Create, string Binding,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] VoiceConsentMethod? ConsentMethod = null)
{
    [JsonIgnore] public VoiceConsentMethod Method => ConsentMethod ?? VoiceConsentMethod.RecordedStatement;
    [JsonIgnore] public Guid Id => Create.Token;
    [JsonIgnore] public IReadOnlyList<VoiceLabPreparedAction> Actions => Verify is { } verify ? [verify, Create] : [Create];
    [JsonIgnore] public CostEstimate Estimate => Verify is null ? Create.Estimate.ToCostEstimate() : new("elevenlabs", "enrollment", 1, "enrollment",
        Verify.Estimate.Usd is { } a && Create.Estimate.Usd is { } b ? a + b : null, null, "Consent statement check and own-voice creation");
    public static EnrollmentQuote Prepare(VoiceLabPreparedAction? verify, VoiceLabPreparedAction create, VoiceLabCloneRequest request, VoiceConsentStatement statement)
    {
        var result = new EnrollmentQuote(verify, create, Fingerprint(request, statement));
        result.Validate(request, statement); return result;
    }
    public void Validate(VoiceLabCloneRequest request, VoiceConsentStatement statement)
    {
        if (Method != VoiceConsentMethod.RecordedStatement || Verify is { } verify && (verify.Review.Operation != VoiceLabOperation.SpeechToText || verify.Review.Region != Create.Review.Region ||
            verify.Review.LanguageMode != new VoiceLabLanguageMode(VoiceLabLanguageModeKind.Explicit, statement.Language)) ||
            Create.Review.Operation != VoiceLabOperation.CreateClone || Binding != Fingerprint(request, statement))
            throw new VoiceLabException(VoiceLabErrorKind.ConsentRequired);
    }
    public static EnrollmentQuote Prepare(VoiceLabPreparedAction create, VoiceLabCloneRequest request, VoiceProjectConsent consent, VoiceConsentAttestations attestations)
    {
        var result = new EnrollmentQuote(null, create, Fingerprint(request, consent, attestations), VoiceConsentMethod.ProjectAttestation);
        result.Validate(request, consent, attestations); return result;
    }
    public void Validate(VoiceLabCloneRequest request, VoiceProjectConsent consent, VoiceConsentAttestations attestations)
    {
        if (Method != VoiceConsentMethod.ProjectAttestation || Verify is not null || Create.Review.Operation != VoiceLabOperation.CreateClone ||
            Create.Review.ConsentPolicy is not { ConsentMethod: VoiceConsentMethod.ProjectAttestation, StatementVerified: false } ||
            Create.Review.ContentSha256 != consent.AudioSha256 || Create.Review.ConsentRecordId != request.RecoveryNonce ||
            Binding != Fingerprint(request, consent, attestations)) throw new VoiceLabException(VoiceLabErrorKind.ConsentRequired);
    }
    private static string Fingerprint(VoiceLabCloneRequest request, VoiceProjectConsent consent, VoiceConsentAttestations attestations)
    {
        consent.Validate();
        if (!attestations.Complete || request.Samples.Count is < 1 or > 24 || request.Samples.Any(sample => sample.Role != VoiceLabCloneSampleRole.Training) ||
            VoiceConsentStore.Hash(request.Samples[0].Wav) != consent.AudioSha256 || request.Language != consent.Language ||
            !Guid.TryParseExact(request.RecoveryNonce, "D", out _)) throw new VoiceLabException(VoiceLabErrorKind.ConsentRequired);
        var fields = new List<string> { "projectAttestation", VoiceConsentText.DisplayName(request.DisplayName), request.Language,
            request.CreatedAt.ToString("O", CultureInfo.InvariantCulture), request.RemoveBackgroundNoise.ToString(), request.RecoveryNonce!,
            consent.ConsentText, consent.AudioFile, consent.AudioSha256, attestations.OwnVoice.ToString(), attestations.Adult.ToString(),
            attestations.OwnVideosOnly.ToString(), attestations.AcceptedAt.ToString("O", CultureInfo.InvariantCulture) };
        foreach (var (sample, index) in request.Samples.Select((sample, index) => (sample, index)))
            fields.AddRange([index.ToString(CultureInfo.InvariantCulture), sample.Role.ToString(), VoiceConsentStore.Hash(sample.Wav)]);
        return VoiceLabActionGate.Fingerprint(fields.ToArray());
    }
    private static string Fingerprint(VoiceLabCloneRequest request, VoiceConsentStatement statement)
    {
        if (request.Samples.Count == 0 || request.Samples[0].Role != VoiceLabCloneSampleRole.ConsentStatement ||
            request.Samples.Count(sample => sample.Role == VoiceLabCloneSampleRole.ConsentStatement) != 1 || request.Language != statement.Language)
            throw new VoiceLabException(VoiceLabErrorKind.ConsentRequired);
        var fields = new List<string> { VoiceConsentText.DisplayName(request.DisplayName), request.Language, request.CreatedAt.ToString("O", CultureInfo.InvariantCulture),
            request.RemoveBackgroundNoise.ToString(), request.RecoveryNonce ?? "", statement.Text };
        fields.AddRange(statement.Nonce);
        foreach (var (sample, index) in request.Samples.Select((sample, index) => (sample, index)))
            fields.AddRange([index.ToString(CultureInfo.InvariantCulture), sample.Role.ToString(), VoiceConsentStore.Hash(sample.Wav)]);
        return VoiceLabActionGate.Fingerprint(fields.ToArray());
    }
}
public sealed record VoiceEnrollmentPlan(string RecordId, EnrollmentQuote Quote, long TrainingMilliseconds, bool VerificationPassed)
{
    public VoiceConsentMethod ConsentMethod => Quote.Method;
    public bool IsRecovery { get; init; }
}
/// <summary>An evidence-checked, unsent creation journal, never an authorization to dispatch.</summary>
public sealed record VoiceEnrollmentRecovery(EnrollmentQuote Quote, VoiceLabCloneRequest Request, VoiceConsentRecord Record, long TrainingMilliseconds)
{
    [JsonIgnore] public string SnapshotFingerprint => VoiceConsentStore.Hash(
        System.Text.Json.JsonSerializer.SerializeToUtf8Bytes(this, VoiceConsentJson.Default.VoiceEnrollmentRecovery));
}
