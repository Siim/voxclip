#pragma warning disable CS1591
using System.Text.Json.Serialization;

namespace VoxClip.Core.Domain.VoiceLab;

[JsonConverter(typeof(JsonStringEnumConverter<VoiceLabShortSpeechMode>))]
public enum VoiceLabShortSpeechMode
{
    [JsonStringEnumMemberName("pooled")] Pooled,
    [JsonStringEnumMemberName("unmeasured")] Unmeasured
}

/// <summary>ADR-R37 evidence: a pooled voice check across short takes, or a pool still under three seconds of voiced speech
/// (unmeasured, with no invented score).</summary>
public sealed record VoiceLabShortSpeechEvidence(VoiceLabShortSpeechMode Mode,
    [property: JsonPropertyName("recordId")] string RecordId, VoiceConsentMethod ConsentMethod, int VoicedFrames, int TakeCount)
{
    internal bool IsValid => !string.IsNullOrEmpty(RecordId) && Enum.IsDefined(ConsentMethod) && VoicedFrames >= 0 && TakeCount > 0 &&
        (Mode == VoiceLabShortSpeechMode.Pooled ? VoicedFrames >= 48000 && TakeCount >= 2 :
            Mode == VoiceLabShortSpeechMode.Unmeasured && VoicedFrames < 48000);
    /// <summary>An active own clone's consent: the only record whose unmeasured takes may be chosen (ADR-R37).</summary>
    [JsonIgnore] public bool OwnClone => ConsentMethod is VoiceConsentMethod.RecordedStatement or VoiceConsentMethod.ProjectAttestation;
    /// <summary>Mac <c>valid</c>: an unmeasured pool counts only for an own clone.</summary>
    [JsonIgnore] public bool Usable => IsValid && (Mode == VoiceLabShortSpeechMode.Pooled || OwnClone);
}

/// <summary>How a take's voice was checked (ADR-R37, Mac <c>VoiceLabTakeVoiceCheck</c>): on its own speech, waiting for its run's
/// pooled check, or by the pooled check's evidence.</summary>
public abstract record VoiceLabTakeVoiceCheck
{
    private VoiceLabTakeVoiceCheck() { }
    public sealed record PerTakeCheck : VoiceLabTakeVoiceCheck;
    public sealed record WaitingCheck : VoiceLabTakeVoiceCheck;
    public sealed record ShortSpeechCheck(VoiceLabShortSpeechEvidence Pool) : VoiceLabTakeVoiceCheck;
    public static VoiceLabTakeVoiceCheck PerTake { get; } = new PerTakeCheck();
    public static VoiceLabTakeVoiceCheck Waiting { get; } = new WaitingCheck();
    public static VoiceLabTakeVoiceCheck ShortSpeech(VoiceLabShortSpeechEvidence evidence) => new ShortSpeechCheck(evidence);
    public VoiceLabShortSpeechEvidence? Evidence => this is ShortSpeechCheck check ? check.Pool : null;
    /// <summary>A waiting take can't be chosen; an unmeasured one only for an own clone.</summary>
    public bool Complete => this switch
    {
        PerTakeCheck => true,
        ShortSpeechCheck check => check.Pool.Usable,
        _ => false
    };
}
