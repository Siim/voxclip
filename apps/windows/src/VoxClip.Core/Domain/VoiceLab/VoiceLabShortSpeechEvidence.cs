#pragma warning disable CS1591
using System.Text.Json.Serialization;

namespace VoxClip.Core.Domain.VoiceLab;

[JsonConverter(typeof(JsonStringEnumConverter<VoiceLabShortSpeechMode>))]
public enum VoiceLabShortSpeechMode
{
    [JsonStringEnumMemberName("pooled")] Pooled,
    [JsonStringEnumMemberName("unmeasured")] Unmeasured
}

public sealed record VoiceLabShortSpeechEvidence(VoiceLabShortSpeechMode Mode,
    [property: JsonPropertyName("recordId")] string RecordId, VoiceConsentMethod ConsentMethod, int VoicedFrames, int TakeCount)
{
    internal bool IsValid => !string.IsNullOrEmpty(RecordId) && Enum.IsDefined(ConsentMethod) && VoicedFrames >= 0 && TakeCount > 0 &&
        (Mode == VoiceLabShortSpeechMode.Pooled ? VoicedFrames >= 48000 && TakeCount >= 2 :
            Mode == VoiceLabShortSpeechMode.Unmeasured && VoicedFrames < 48000);
}
