using System.Buffers.Binary;
using VoxClip.Core.Domain.VoiceLab;

namespace VoxClip.Media.VoiceLab;

internal sealed class VoiceLabWavePcm
{
    internal int Rate { get; }
    internal int Channels { get; }
    internal int Bits { get; }
    internal bool Floating { get; }
    internal byte[] Pcm { get; }
    internal int Stride => Channels * (Bits / 8);
    internal int Frames => Pcm.Length / Stride;
    internal VoiceLabWavePcm(int rate, int channels, int bits, bool floating, byte[] pcm)
    {
        if (rate is < 8000 or > 192000 || channels is < 1 or > 2 || (floating ? bits is not (32 or 64) : bits is not (16 or 24 or 32)) ||
            pcm.Length == 0 || pcm.Length % (channels * (bits / 8)) != 0 || pcm.Length > 256 * 1024 * 1024) throw Invalid();
        Rate = rate; Channels = channels; Bits = bits; Floating = floating; Pcm = pcm;
        if (floating)
            for (var frame = 0; frame < Frames; frame++)
                for (var channel = 0; channel < channels; channel++)
                    if (!double.IsFinite(Sample(frame, channel))) throw Invalid();
    }
    internal static VoiceLabWavePcm Parse(byte[] bytes)
    {
        if (bytes.Length < 44 || !bytes.AsSpan(0, 4).SequenceEqual("RIFF"u8) || !bytes.AsSpan(8, 4).SequenceEqual("WAVE"u8) ||
            BinaryPrimitives.ReadUInt32LittleEndian(bytes.AsSpan(4)) != bytes.Length - 8) throw Invalid();
        int rate = 0, channels = 0, bits = 0, format = 0;
        byte[]? pcm = null;
        var foundFormat = false;
        for (long offset = 12; offset < bytes.Length;)
        {
            if (offset + 8 > bytes.Length) throw Invalid();
            var size = BinaryPrimitives.ReadUInt32LittleEndian(bytes.AsSpan((int)offset + 4));
            var begin = offset + 8;
            if (begin + size + size % 2 > bytes.Length) throw Invalid();
            var chunk = bytes.AsSpan((int)offset, 4);
            if (chunk.SequenceEqual("fmt "u8))
            {
                if (foundFormat || size < 16) throw Invalid();
                var data = bytes.AsSpan((int)begin, (int)size);
                format = BinaryPrimitives.ReadUInt16LittleEndian(data);
                channels = BinaryPrimitives.ReadUInt16LittleEndian(data[2..]);
                rate = BinaryPrimitives.ReadInt32LittleEndian(data[4..]);
                bits = BinaryPrimitives.ReadUInt16LittleEndian(data[14..]);
                if (format is not (1 or 3) || BinaryPrimitives.ReadUInt16LittleEndian(data[12..]) != channels * bits / 8 ||
                    BinaryPrimitives.ReadInt32LittleEndian(data[8..]) != (long)rate * channels * bits / 8) throw Invalid();
                foundFormat = true;
            }
            else if (chunk.SequenceEqual("data"u8))
            {
                if (pcm is not null || size > 256 * 1024 * 1024) throw Invalid();
                pcm = bytes.AsSpan((int)begin, (int)size).ToArray();
            }
            offset = begin + size + size % 2;
        }
        if (!foundFormat || pcm is null) throw Invalid();
        return new(rate, channels, bits, format == 3, pcm);
    }
    internal byte[] Header()
    {
        var bytes = new byte[44];
        "RIFF"u8.CopyTo(bytes);
        BinaryPrimitives.WriteInt32LittleEndian(bytes.AsSpan(4), 36 + Pcm.Length + Pcm.Length % 2);
        "WAVEfmt "u8.CopyTo(bytes.AsSpan(8));
        BinaryPrimitives.WriteInt32LittleEndian(bytes.AsSpan(16), 16);
        BinaryPrimitives.WriteInt16LittleEndian(bytes.AsSpan(20), (short)(Floating ? 3 : 1));
        BinaryPrimitives.WriteInt16LittleEndian(bytes.AsSpan(22), (short)Channels);
        BinaryPrimitives.WriteInt32LittleEndian(bytes.AsSpan(24), Rate);
        BinaryPrimitives.WriteInt32LittleEndian(bytes.AsSpan(28), Rate * Stride);
        BinaryPrimitives.WriteInt16LittleEndian(bytes.AsSpan(32), (short)Stride);
        BinaryPrimitives.WriteInt16LittleEndian(bytes.AsSpan(34), (short)Bits);
        "data"u8.CopyTo(bytes.AsSpan(36));
        BinaryPrimitives.WriteInt32LittleEndian(bytes.AsSpan(40), Pcm.Length);
        return bytes;
    }
    internal byte[] Bytes()
    {
        var bytes = new byte[44 + Pcm.Length + Pcm.Length % 2];
        Header().CopyTo(bytes, 0);
        Pcm.CopyTo(bytes, 44);
        return bytes;
    }
    internal double Sample(long frame, int channel)
    {
        if (frame < 0 || frame >= Frames || channel < 0 || channel >= Channels) throw Invalid();
        var bytes = Pcm.AsSpan(checked((int)(frame * Stride + channel * (Bits / 8))));
        if (Floating) return Bits == 32 ? BinaryPrimitives.ReadSingleLittleEndian(bytes) : BinaryPrimitives.ReadDoubleLittleEndian(bytes);
        return Bits switch
        {
            16 => BinaryPrimitives.ReadInt16LittleEndian(bytes) / 32768.0,
            24 => ((bytes[0] | bytes[1] << 8 | bytes[2] << 16) << 8 >> 8) / 8388608.0,
            _ => BinaryPrimitives.ReadInt32LittleEndian(bytes) / 2147483648.0
        };
    }
    internal void SetSample(double sample, long frame, int channel)
    {
        if (!double.IsFinite(sample) || Floating && Bits == 32 && !float.IsFinite((float)sample) || frame < 0 || frame >= Frames) throw Invalid();
        var bytes = Pcm.AsSpan(checked((int)(frame * Stride + channel * (Bits / 8))));
        if (Floating)
        {
            if (Bits == 32) BinaryPrimitives.WriteSingleLittleEndian(bytes, (float)sample);
            else BinaryPrimitives.WriteDoubleLittleEndian(bytes, sample);
        }
        else
        {
            var scale = Math.Pow(2, Bits - 1);
            var value = (long)Math.Clamp(Math.Round(sample * scale, MidpointRounding.ToEven), -scale, scale - 1);
            for (var offset = 0; offset < Bits / 8; offset++) bytes[offset] = unchecked((byte)(value >> (8 * offset)));
        }
    }
    private static VoiceLabException Invalid() => new(VoiceLabErrorKind.InvalidAudio);
}
