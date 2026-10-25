using VoxClip.Core.Domain.Transcript;

namespace VoxClip.Core.Domain.Editing;

/// <summary>Streaming native-rate, all-channel RMS analysis, editing §5.1 and plan W2.</summary>
public sealed class AudioEnvelopeBuilder
{
    private readonly int sampleRate;
    private readonly int channels;
    private readonly int frameSize;
    private readonly float[] frameValues;
    private readonly List<float> levels = [];
    private int buffered;

    /// <summary>Create 10 ms analysis frames at the native rate.</summary>
    public AudioEnvelopeBuilder(int sampleRate, int channels)
    {
        if (sampleRate <= 0) throw new ArgumentOutOfRangeException(nameof(sampleRate));
        frameSize = Math.Max(1, (int)EditingMath.Round(sampleRate * 0.01));
        if (channels <= 0 || channels > int.MaxValue / frameSize) throw new ArgumentOutOfRangeException(nameof(channels));
        this.sampleRate = sampleRate;
        this.channels = channels;
        frameValues = new float[frameSize * channels];
    }

    /// <summary>Append any number of interleaved values, including partial channel or analysis frames.</summary>
    public void Append(ReadOnlySpan<float> interleaved)
    {
        while (!interleaved.IsEmpty)
        {
            var count = Math.Min(interleaved.Length, frameValues.Length - buffered);
            interleaved[..count].CopyTo(frameValues.AsSpan(buffered));
            buffered += count;
            interleaved = interleaved[count..];
            if (buffered != frameValues.Length) continue;
            var sum = 0.0;
            for (var channel = 0; channel < channels; channel++)
                for (var sample = 0; sample < frameSize; sample++)
                {
                    var value = (double)frameValues[sample * channels + channel];
                    sum += value * value;
                }
            levels.Add((float)Math.Sqrt(sum / frameValues.Length));
            buffered = 0;
        }
    }

    /// <summary>Return an independent level snapshot, omitting any incomplete final analysis frame.</summary>
    public AudioEnvelope Finish() => new(sampleRate, 0.01, levels.ToArray());
}
