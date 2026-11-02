// Compile the production enrollment source in tests with synthetic speaker evidence.
// The shipping Media assembly contains only the native speaker adapter and its closed parity gate.
global using VoiceEnrollment = VoxClip.Tests.Enrollment.VoiceEnrollment;
global using VoiceConsentSaveException = VoxClip.Tests.Enrollment.VoiceConsentSaveException;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Media.VoiceLab;

namespace VoxClip.Tests.Enrollment;

public sealed partial class VoiceEnrollment
{
    internal sealed record TestSpeaker(Func<float[], CancellationToken, Task<float[]>> Embed,
        Func<float[], CancellationToken, Task<(float[] Whole, float[][] Parts)>> Parts, double Threshold = 0.8, string Model = "fixture-calibrated");
    internal TestSpeaker? SpeakerForTests { get; set; }
    public bool SpeakerAvailable => SpeakerForTests is not null || speaker.Available;
    private bool Supports(string language) => SpeakerForTests is not null ? language == "en" : speaker.Supports(language);
    private double Threshold => SpeakerForTests?.Threshold ?? speaker.Threshold ?? throw new VoiceConsentException(VoiceConsentError.SpeakerUnavailable);
    private string Model => SpeakerForTests?.Model ?? speaker.ModelId ?? throw new VoiceConsentException(VoiceConsentError.SpeakerUnavailable);
    private void ValidateSpeaker() { if (SpeakerForTests is null) speaker.ValidateAvailability(); }
    private Task<float[]> Embed(float[] pcm, CancellationToken ct) => SpeakerForTests is { } test ? test.Embed(pcm, ct) : speaker.EmbeddingAsync(pcm, ct);
    private Task<(float[] Whole, float[][] Parts)> Parts(float[] pcm, CancellationToken ct) => SpeakerForTests is { } test ? test.Parts(pcm, ct) : speaker.PartEmbeddingsAsync(pcm, ct);
    private static byte[] TrainingWav(VoiceTrainingSample sample) => (byte[])typeof(VoiceTrainingSample)
        .GetProperty("Wav", System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Instance)!.GetValue(sample)!;
}
