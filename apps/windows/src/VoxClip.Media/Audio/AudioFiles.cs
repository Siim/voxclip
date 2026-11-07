using System.Buffers.Binary;
using System.Text;
using VoxClip.Core.Domain.Shared;

namespace VoxClip.Media.Audio;

internal sealed class WaveWriter : IDisposable
{
    private readonly FileStream stream;
    private readonly BinaryWriter writer;
    private readonly int sampleRate;
    private readonly short channels;
    private readonly short bits;
    private readonly short format;
    internal long Samples { get; private set; }

    internal WaveWriter(string path, int sampleRate, int channels, bool floating)
        : this(new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.None), sampleRate, channels, floating) { }

    internal WaveWriter(FileStream ownedStream, int sampleRate, int channels, bool floating)
    {
        this.sampleRate = sampleRate; this.channels = checked((short)channels);
        bits = (short)(floating ? 32 : 16); format = (short)(floating ? 3 : 1);
        stream = ownedStream;
        writer = new(stream, Encoding.UTF8, true);
        Header(0);
    }

    internal void Write(ReadOnlySpan<float> samples)
    {
        foreach (var sample in samples)
            if (bits == 32) writer.Write(sample);
            else writer.Write((short)Math.Round(Math.Clamp((double)sample, -1, 1) * 32767, MidpointRounding.AwayFromZero));
        Samples += samples.Length / channels;
    }

    private void Header(uint length)
    {
        writer.Write("RIFF"u8); writer.Write(checked(length + 36)); writer.Write("WAVEfmt "u8);
        writer.Write(16); writer.Write(format); writer.Write(channels); writer.Write(sampleRate);
        writer.Write(sampleRate * channels * bits / 8); writer.Write((short)(channels * bits / 8)); writer.Write(bits);
        writer.Write("data"u8); writer.Write(length);
    }

    public void Dispose()
    {
        stream.Position = 0; Header(checked((uint)(Samples * channels * bits / 8)));
        writer.Dispose(); stream.Dispose();
    }
}

/// <summary>Float32 WAV helpers for the edited-audio sidecar.</summary>
internal static class WaveGain
{
    /// <summary>Multiplies every sample of a finished Float32 WAV in place: the CLI's <c>--audio-out</c> carries the export's
    /// loudness gain (ADR-R47; Mac PCMFile.applyGain).</summary>
    internal static void Apply(string path, float gain, CancellationToken ct = default)
    {
        if (gain == 1) return;
        using var stream = new FileStream(path, FileMode.Open, FileAccess.ReadWrite, FileShare.None);
        Span<byte> header = stackalloc byte[12];
        if (stream.Read(header) != 12 || !header[..4].SequenceEqual("RIFF"u8) || !header[8..].SequenceEqual("WAVE"u8))
            throw Invalid("is not RIFF WAVE");
        long offset = 12;
        var isFloat = false;
        Span<byte> chunk = stackalloc byte[8];
        Span<byte> format = stackalloc byte[16];
        while (true)
        {
            stream.Position = offset;
            if (stream.Read(chunk) != 8) throw Invalid("has no data");
            var size = BinaryPrimitives.ReadUInt32LittleEndian(chunk[4..]);
            if (chunk[..4].SequenceEqual("fmt "u8))
            {
                if (stream.Read(format) != 16) throw Invalid("has no format");
                isFloat = BinaryPrimitives.ReadUInt16LittleEndian(format) == 3 && BinaryPrimitives.ReadUInt16LittleEndian(format[14..]) == 32;
            }
            else if (chunk[..4].SequenceEqual("data"u8))
            {
                if (!isFloat) throw Invalid("is not Float32");
                Scale(stream, offset + 8, size, gain, ct);
                stream.Flush(true);
                return;
            }
            offset += 8 + size + size % 2;
        }
    }

    private static void Scale(FileStream stream, long start, long bytes, float gain, CancellationToken ct)
    {
        var buffer = new byte[1 << 20];
        for (long position = 0; position < bytes;)
        {
            ct.ThrowIfCancellationRequested();
            var length = (int)Math.Min(buffer.Length, bytes - position);
            stream.Position = start + position;
            stream.ReadExactly(buffer, 0, length);
            for (var index = 0; index + 4 <= length; index += 4)
            {
                var value = BinaryPrimitives.ReadSingleLittleEndian(buffer.AsSpan(index)) * gain;
                BinaryPrimitives.WriteSingleLittleEndian(buffer.AsSpan(index), value);
            }
            stream.Position = start + position;
            stream.Write(buffer, 0, length);
            position += length;
        }
    }

    private static VoxClipException Invalid(string reason) =>
        new(VoxClipErrorCode.ExportFailed, $"Export stopped: the edited WAV {reason}. Your edits are saved.");
}
