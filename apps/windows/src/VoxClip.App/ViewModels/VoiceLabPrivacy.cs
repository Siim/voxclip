namespace VoxClip.App.ViewModels;

internal sealed record VoiceLabPrivacyRow(string Data, string LeavesDevice, string Storage);
internal static class VoiceLabPrivacy
{
    internal const string Heading = "Voice Lab (only when you turn it on; each provider action requires your approval):";
    internal static IReadOnlyList<VoiceLabPrivacyRow> Rows { get; } = Array.AsReadOnly<VoiceLabPrivacyRow>([
        new("Source audio for Clean audio", "to ElevenLabs, only on the user's click", "cache input WAV (evictable); result in <data>/VoiceLab/<contentKey>/"),
        new("Consent statement audio", "to ElevenLabs STT (check) and IVC (one sample)", "<data>/VoiceLab/consent/<recordId>/ until the voice is deleted"),
        new("Training samples (project spans or a read-aloud)", "to ElevenLabs IVC", "temporary; deleted locally after upload or when the sheet closes; hashes kept"),
        new("Patch text and context text", "to ElevenLabs TTS (previous_text / future_text, ≤ 100 or 300 characters)", "in the project segment"),
        new("Lip-sync window video and audio", "to fal.ai or sync.so", "deleted remotely where the API allows; result in <data>/VoiceLab/<projectId>/"),
        new("Speaker embeddings", "never", "in the consent record")
    ]);
}
