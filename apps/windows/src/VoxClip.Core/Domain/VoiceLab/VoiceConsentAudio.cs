using System.Buffers.Binary;
using VoxClip.Core.Domain.Shared;
#pragma warning disable CS1591

namespace VoxClip.Core.Domain.VoiceLab;

public static class VoiceConsentAudio
{
    public static (int Rate, int Frames, int Offset) ValidateWav(ReadOnlySpan<byte> wav)
    {
        if (wav.Length is < 44 or > 16 * 1024 * 1024 || !wav[..4].SequenceEqual("RIFF"u8) ||
            !wav.Slice(8, 4).SequenceEqual("WAVE"u8) || BinaryPrimitives.ReadUInt32LittleEndian(wav[4..]) != wav.Length - 8) throw Invalid();
        int? rate = null;
        int? frames = null;
        var dataOffset = 0;
        for (var offset = 12; offset < wav.Length;)
        {
            if (wav.Length - offset < 8) throw Invalid();
            var count = BinaryPrimitives.ReadUInt32LittleEndian(wav[(offset + 4)..]);
            var start = offset + 8;
            if (count > wav.Length - start || (count & 1) > wav.Length - start - count) throw Invalid();
            if (wav.Slice(offset, 4).SequenceEqual("fmt "u8))
            {
                if (rate is not null || count is not (16 or 18) || BinaryPrimitives.ReadUInt16LittleEndian(wav[start..]) != 1 ||
                    BinaryPrimitives.ReadUInt16LittleEndian(wav[(start + 2)..]) != 1 || BinaryPrimitives.ReadUInt16LittleEndian(wav[(start + 14)..]) != 16 ||
                    count == 18 && BinaryPrimitives.ReadUInt16LittleEndian(wav[(start + 16)..]) != 0) throw Invalid();
                var parsed = BinaryPrimitives.ReadUInt32LittleEndian(wav[(start + 4)..]);
                if (parsed is < 8000 or > 96000 || BinaryPrimitives.ReadUInt32LittleEndian(wav[(start + 8)..]) != parsed * 2 ||
                    BinaryPrimitives.ReadUInt16LittleEndian(wav[(start + 12)..]) != 2) throw Invalid();
                rate = (int)parsed;
            }
            else if (wav.Slice(offset, 4).SequenceEqual("data"u8))
            {
                if (frames is not null || count == 0 || count % 2 != 0) throw Invalid();
                frames = (int)count / 2;
                dataOffset = start;
            }
            offset = checked(start + (int)count + (int)(count & 1));
        }
        if (rate is null || frames is null || frames < (rate + 49) / 50 || frames > rate * 290) throw Invalid();
        return (rate.Value, frames.Value, dataOffset);
    }
    public static float[] Pcm16k(ReadOnlySpan<byte> wav)
    {
        var format = ValidateWav(wav);
        var samples = new float[format.Frames];
        for (var index = 0; index < samples.Length; index++) samples[index] = BinaryPrimitives.ReadInt16LittleEndian(wav[(format.Offset + index * 2)..]) / 32768f;
        return Resample(samples, format.Rate);
    }
    public static float[] Resample(float[] samples, int rate) => Resample(samples.AsSpan(), rate, 16000);
    public static float[] Resample(ReadOnlySpan<float> mono, int rate, int targetRate)
    {
        if (rate is < 8000 or > 192000 || targetRate is < 8000 or > 192000) throw Invalid();
        foreach (var sample in mono) if (!float.IsFinite(sample)) throw Invalid();
        if (rate == targetRate) return mono.ToArray();
        var resampler = new SincResampler(rate, targetRate);
        var output = new float[checked((int)((long)mono.Length * targetRate / rate))];
        var head = resampler.Process(mono);
        head.CopyTo(output);
        resampler.Finish().CopyTo(output.AsSpan(head.Length));
        return output;
    }
    private static VoiceLabException Invalid() => new(VoiceLabErrorKind.InvalidAudio);
}
