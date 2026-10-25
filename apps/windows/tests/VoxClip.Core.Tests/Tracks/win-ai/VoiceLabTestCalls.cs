using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.VoiceLab;

namespace VoxClip.Core.Tests.Tracks.WinAi;

/// <summary>Short test calls still carry the quote's explicit request identity through dispatch.</summary>
internal static class VoiceLabTestCalls
{
    internal static VoiceLabPreparedAction PrepareSynthesis(this ElevenLabsVoiceLab service, string text, string model,
        VoiceLabVoiceChoice voice, string language) => service.PrepareSynthesis(text, model, voice, language, Guid.NewGuid());
    internal static VoiceLabPreparedAction PrepareConversion(this ElevenLabsVoiceLab service, byte[] audio, string model,
        VoiceLabVoiceChoice voice, string language) => service.PrepareConversion(audio, model, voice, language, Guid.NewGuid());
    internal static VoiceLabPreparedAction PrepareDeletion(this ElevenLabsVoiceLab service, string voiceId,
        OwnVoicePolicy policy) => service.PrepareDeletion(voiceId, policy, Guid.NewGuid());
    internal static VoiceLabPreparedAction PrepareClone(this ElevenLabsVoiceLab service, string name, byte[] sample,
        string mime, OwnVoicePolicy policy) => service.PrepareClone(name, sample, mime, policy, Guid.NewGuid());
    internal static Task<VoiceLabPreparedAction> PrepareCloneAsync(this ElevenLabsVoiceLab service, string name, byte[] sample,
        OwnVoicePolicy policy, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        return Task.FromResult(service.PrepareClone(name, sample, "audio/wav", policy, Guid.NewGuid()));
    }
    internal static Task<VoiceLabCloneResult> CreateOwnCloneAsync(this ElevenLabsVoiceLab service, string name, byte[] sample,
        OwnVoicePolicy policy, VoiceLabAuthorization approval, CancellationToken ct) =>
        service.CreateOwnCloneAsync(name, sample, "audio/wav", policy, approval, ct, approval.Review.RequestId);
    internal static Task<VoiceLabCloneResult> CreateOwnCloneAsync(this ElevenLabsVoiceLab service, string name, byte[] sample,
        string mime, OwnVoicePolicy policy, VoiceLabAuthorization approval, CancellationToken ct) =>
        service.CreateOwnCloneAsync(name, sample, mime, policy, approval, ct, approval.Review.RequestId);
    internal static Task<VoiceLabReceipt> DeleteOwnCloneAsync(this ElevenLabsVoiceLab service, string voiceId,
        OwnVoicePolicy policy, VoiceLabAuthorization approval, CancellationToken ct) =>
        service.DeleteOwnCloneAsync(voiceId, policy, approval, ct, approval.Review.RequestId);
    internal static Task<VoiceLabAudioResult> SynthesizeAsync(this ElevenLabsVoiceLab service, string text, string model,
        VoiceLabVoiceChoice voice, string language, VoiceLabAuthorization approval, CancellationToken ct) =>
        service.SynthesizeAsync(text, model, voice, language, approval, ct, approval.Review.RequestId);
    internal static Task<VoiceLabAudioResult> ConvertAsync(this ElevenLabsVoiceLab service, byte[] audio, string model,
        VoiceLabVoiceChoice voice, string language, VoiceLabAuthorization approval, CancellationToken ct) =>
        service.ConvertAsync(audio, model, voice, language, approval, ct, approval.Review.RequestId);
}
