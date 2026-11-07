using System.Buffers.Binary;
using System.Text;
using VoxClip.Core.Domain.Loudness;
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
internal static class WaveLoudness
{
    /// <summary>Runs a finished Float32 WAV through the export's gain and limiter in place: the CLI's <c>--audio-out</c> carries
    /// the same gain and the same limiter as the export, run over its own samples (without music, the export's PCM; ADR-R47;
    /// Mac PCMFile.applyLoudness).</summary>
    internal static void Apply(string path, SocialLoudnessDecision decision, CancellationToken ct = default)
    {
        if (decision.GainDb == 0 && !decision.Limiting) return;
        using var stream = new FileStream(path, FileMode.Open, FileAccess.ReadWrite, FileShare.None);
        Span<byte> header = stackalloc byte[12];
        if (stream.Read(header) != 12 || !header[..4].SequenceEqual("RIFF"u8) || !header[8..].SequenceEqual("WAVE"u8))
            throw Invalid("is not RIFF WAVE");
        long offset = 12;
        var isFloat = false;
        var channels = 0;
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
                channels = BinaryPrimitives.ReadUInt16LittleEndian(format[2..]);
            }
            else if (chunk[..4].SequenceEqual("data"u8))
            {
                if (!isFloat || channels is < 1 or > 8) throw Invalid("is not Float32");
                Process(stream, offset + 8, size, new SocialLimiter(decision.GainDb, decision.Limiting, 48_000, channels), ct);
                stream.Flush(true);
                return;
            }
            offset += 8 + size + size % 2;
        }
    }

    // Reads ahead of where it writes: output lags input by the limiter's latency, so nothing is overwritten unread.
    private static void Process(FileStream stream, long start, long bytes, SocialLimiter limiter, CancellationToken ct)
    {
        var frameBytes = limiter.Channels * 4;
        var total = bytes - bytes % frameBytes;
        var buffer = new byte[(1 << 20) - (1 << 20) % frameBytes];
        var input = new float[buffer.Length / 4];
        var output = new float[Math.Max(input.Length, limiter.Latency * limiter.Channels)];
        long read = 0, written = 0;
        void Write(int frames)
        {
            if (frames == 0) return;
            var count = frames * limiter.Channels;
            for (var index = 0; index < count; index++) BinaryPrimitives.WriteSingleLittleEndian(buffer.AsSpan(index * 4), output[index]);
            stream.Position = start + written;
            stream.Write(buffer, 0, count * 4);
            written += count * 4;
        }
        while (read < total)
        {
            ct.ThrowIfCancellationRequested();
            var length = (int)Math.Min(buffer.Length, total - read);
            stream.Position = start + read;
            stream.ReadExactly(buffer, 0, length);
            read += length;
            for (var index = 0; index < length / 4; index++) input[index] = BinaryPrimitives.ReadSingleLittleEndian(buffer.AsSpan(index * 4));
            Write(limiter.Process(input.AsSpan(0, length / 4), output));
        }
        Write(limiter.Finish(output));
    }

    private static VoxClipException Invalid(string reason) =>
        new(VoxClipErrorCode.ExportFailed, $"Export stopped: the edited WAV {reason}. Your edits are saved.");
}
