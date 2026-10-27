using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.VoiceLab;

namespace VoxClip.Core.Tests.Tracks.WinAi;

/// <summary>Short test calls still carry the quote's explicit request identity through dispatch.</summary>
internal static class VoiceLabTestCalls
{
    /// <summary>The seed short synthesis calls send, without context.</summary>
    internal static readonly VoiceLabSpeechOptions Speech = new(7);
    internal static VoiceLabPreparedAction PrepareSynthesis(this ElevenLabsVoiceLab service, string text, string model,
        VoiceLabVoiceChoice voice, string language, VoiceLabSpeechOptions? options = null) =>
        service.PrepareSynthesis(text, model, voice, language, options ?? Speech, Guid.NewGuid());
    internal static VoiceLabPreparedAction PrepareConversion(this ElevenLabsVoiceLab service, byte[] audio, string model,
        VoiceLabVoiceChoice voice, string language, uint seed = 7, bool cleanAudioOn = false) =>
        service.PrepareConversion(audio, model, voice, language, seed, cleanAudioOn, Guid.NewGuid());
    internal static VoiceLabPreparedAction PrepareDeletion(this ElevenLabsVoiceLab service, string voiceId,
        OwnVoicePolicy policy) => service.PrepareDeletion(voiceId, policy, Guid.NewGuid());
    internal static VoiceLabPreparedAction PrepareClone(this ElevenLabsVoiceLab service, VoiceLabCloneRequest request,
        OwnVoicePolicy policy) => service.PrepareClone(request, policy, Guid.NewGuid());
    internal static Task<VoiceLabCloneResult> CreateOwnCloneAsync(this ElevenLabsVoiceLab service, VoiceLabCloneRequest request,
        OwnVoicePolicy policy, VoiceLabAuthorization approval, CancellationToken ct) =>
        service.CreateOwnCloneAsync(request, policy, approval, ct, approval.Review.RequestId);
    /// <summary>A valid two-file upload: a five-second consent statement and a five-second training sample at 8 kHz.</summary>
    internal static VoiceLabCloneRequest CloneRequest(string name = "Mine", short trainingFill = 1) =>
        new(name, "en", [new(VoiceLabCloneSampleRole.ConsentStatement, SyntheticWav(8000, 40000)),
            new(VoiceLabCloneSampleRole.Training, SyntheticWav(8000, 40000, trainingFill))],
            new DateTimeOffset(2026, 10, 26, 9, 15, 42, TimeSpan.Zero), false);
    /// <summary>Synthetic mono PCM16 WAV as shared/fixtures/voice-lab/request-cases-README.md defines it.</summary>
    internal static byte[] SyntheticWav(int rate, int frames, short fill = 0, int junkBytes = 0, short channels = 1)
    {
        using var stream = new MemoryStream();
        using var writer = new BinaryWriter(stream);
        writer.Write("RIFF"u8); writer.Write(0); writer.Write("WAVE"u8);
        if (junkBytes > 0) { writer.Write("JUNK"u8); writer.Write(junkBytes); writer.Write(new byte[junkBytes + junkBytes % 2]); }
        writer.Write("fmt "u8); writer.Write(16); writer.Write((short)1); writer.Write(channels);
        writer.Write(rate); writer.Write(rate * 2); writer.Write((short)2); writer.Write((short)16);
        writer.Write("data"u8); writer.Write(frames * 2);
        for (var i = 0; i < frames; i++) writer.Write(fill);
        writer.Flush();
        var bytes = stream.ToArray();
        BitConverter.TryWriteBytes(bytes.AsSpan(4), bytes.Length - 8);
        return bytes;
    }
    internal static Task<VoiceLabReceipt> DeleteOwnCloneAsync(this ElevenLabsVoiceLab service, string voiceId,
        OwnVoicePolicy policy, VoiceLabAuthorization approval, CancellationToken ct) =>
        service.DeleteOwnCloneAsync(voiceId, policy, approval, ct, approval.Review.RequestId);
    internal static Task<VoiceLabAudioResult> SynthesizeAsync(this ElevenLabsVoiceLab service, string text, string model,
        VoiceLabVoiceChoice voice, string language, VoiceLabAuthorization approval, CancellationToken ct, VoiceLabSpeechOptions? options = null) =>
        service.SynthesizeAsync(text, model, voice, language, options ?? Speech, approval, ct, approval.Review.RequestId);
    internal static Task<VoiceLabAudioResult> ConvertAsync(this ElevenLabsVoiceLab service, byte[] audio, string model,
        VoiceLabVoiceChoice voice, string language, VoiceLabAuthorization approval, CancellationToken ct, uint seed = 7, bool cleanAudioOn = false) =>
        service.ConvertAsync(audio, model, voice, language, seed, cleanAudioOn, approval, ct, approval.Review.RequestId);
}
