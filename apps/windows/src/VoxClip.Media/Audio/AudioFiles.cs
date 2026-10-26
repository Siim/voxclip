using System.Text;

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
