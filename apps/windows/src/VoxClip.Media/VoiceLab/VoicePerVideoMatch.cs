using VoxClip.Core.Domain.VoiceLab;

namespace VoxClip.Media.VoiceLab;

/// <summary>"Did matching help" (voice-lab.md §6.13; Mac <c>VoicePerVideoMatch</c>): how close a take's voice is to the creator's own speech
/// right beside it, with the production speaker model, on this PC. The original speech is the use-time guard's (§6.9): the transcript words
/// nearest the patch, in the patch speaker's turns. Nothing is sent. With no speaker check (the closed parity gate) there is no score.</summary>
public static class VoicePerVideoMatch
{
    /// <summary>The cosine between the take's trimmed speech and that original speech, or null when there is no speaker check or either has
    /// too little speech to embed.</summary>
    public static async Task<double?> ScoreAsync(VoiceLabTakeAudio take, VoiceLabTakeInput input, VoiceSpeakerProbe? probe, CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(take);
        ArgumentNullException.ThrowIfNull(input);
        if (probe is null || take.SampleRate <= 0 || take.Trimmed.Length == 0) return null;
        try
        {
            var original = VoiceLabTakeRun.GuardSpeech(input);
            if (original.Length == 0) return null;
            var speech = take.SampleRate == 16_000 ? take.Trimmed : VoiceConsentAudio.Resample(take.Trimmed, take.SampleRate, 16_000);
            var generated = await probe.Embedding(speech, ct).ConfigureAwait(false);
            var beside = await probe.Embedding(original, ct).ConfigureAwait(false);
            return SpeakerAudio.Cosine(generated, beside);
        }
        catch (Exception error) when (error is VoiceConsentException or VoiceLabException or ArgumentException) { return null; }
    }
}
