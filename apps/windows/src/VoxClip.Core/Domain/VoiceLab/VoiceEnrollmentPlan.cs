using System.Globalization;
using System.Text.Json.Serialization;
using VoxClip.Core.Services.LLM;
using VoxClip.Core.Services.VoiceLab;
#pragma warning disable CS1591

namespace VoxClip.Core.Domain.VoiceLab;

/// <summary>The statement and ordered training upload bound to one enrollment approval.</summary>
public sealed record EnrollmentQuote(VoiceLabPreparedAction? Verify, VoiceLabPreparedAction Create, string Binding)
{
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
        if (Verify is { } verify && (verify.Review.Operation != VoiceLabOperation.SpeechToText || verify.Review.Region != Create.Review.Region ||
            verify.Review.LanguageMode != new VoiceLabLanguageMode(VoiceLabLanguageModeKind.Explicit, statement.Language)) ||
            Create.Review.Operation != VoiceLabOperation.CreateClone || Binding != Fingerprint(request, statement))
            throw new VoiceLabException(VoiceLabErrorKind.ConsentRequired);
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
public sealed record VoiceEnrollmentPlan(string RecordId, EnrollmentQuote Quote, long TrainingMilliseconds, bool VerificationPassed);
/// <summary>A verified, unsent creation journal, never an authorization to dispatch.</summary>
public sealed record VoiceEnrollmentRecovery(EnrollmentQuote Quote, VoiceLabCloneRequest Request, VoiceConsentRecord Record, long TrainingMilliseconds);
