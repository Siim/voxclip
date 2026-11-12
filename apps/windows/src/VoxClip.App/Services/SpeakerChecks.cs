using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.Project;
using VoxClip.Core.Services.VoiceLab;

namespace VoxClip.App.Services;

/// <summary>The App's own-voice check (ADR-R41): one ONNX embedder over the catalogue's speaker model in <c>Models/&lt;id&gt;</c>,
/// loaded on first use and kept for the process. <see cref="VoiceSpeakerCheck.Unavailable"/> while the parity gate is closed, the
/// model files are missing or fail their hashes, or the language has no calibrated threshold. A missing model is looked for again on
/// the next call, so installing it needs no restart.</summary>
internal static class SpeakerChecks
{
    private static readonly object Sync = new();
    private static ONNXSpeakerEmbedder? embedder;
    internal static VoiceSpeakerCheck For(DataLocations data, string language)
    {
        if (!VoiceSpeakerCheck.WindowsNativeParityVerified) return VoiceSpeakerCheck.Unavailable;
        try
        {
            lock (Sync)
            {
                embedder ??= new ONNXSpeakerEmbedder(Path.Combine(data.Models, new SpeakerModelCatalog().Entry.Id));
                return embedder.SpeakerCheck(language);
            }
        }
        catch (Exception error) when (error is VoiceConsentException or IOException or UnauthorizedAccessException or Microsoft.ML.OnnxRuntime.OnnxRuntimeException)
        {
            return VoiceSpeakerCheck.Unavailable;
        }
    }
}
