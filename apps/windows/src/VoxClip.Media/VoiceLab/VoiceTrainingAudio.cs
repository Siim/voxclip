using System.Buffers.Binary;
using VoxClip.Core.Domain.VoiceLab;
#pragma warning disable CS1591

namespace VoxClip.Media.VoiceLab;

public sealed class VoiceTrainingSample
{
    internal byte[] Wav { get; }
    public double Seconds { get; }
    public string Source { get; }
    public double SnrDb { get; }
    public bool CleanAudioApplied { get; }
    internal VoiceTrainingSample(byte[] wav, double seconds, string source, double snrDb, bool cleanAudioApplied = false)
    { Wav = wav; Seconds = seconds; Source = source; SnrDb = snrDb; CleanAudioApplied = cleanAudioApplied; }
}

public static class VoiceTrainingAudio
{
    public static byte[] Wav(float[] samples, int rate = 48000)
    {
        if (rate is < 8000 or > 96000 || samples.Length == 0 || samples.Length > rate * 120 || samples.Any(sample => !float.IsFinite(sample)) ||
            VoiceLabLoudness.VoicedRmsDb(samples, rate) is not { } level) throw Invalid();
        var peak = VoiceLabLoudness.TruePeakDbtp(samples, rate);
        var gain = Math.Pow(10, Math.Min(-20 - level, -3 - peak) / 20);
        var wav = new byte[44 + samples.Length * 2];
        "RIFF"u8.CopyTo(wav); BinaryPrimitives.WriteInt32LittleEndian(wav.AsSpan(4), wav.Length - 8);
        "WAVEfmt "u8.CopyTo(wav.AsSpan(8)); BinaryPrimitives.WriteInt32LittleEndian(wav.AsSpan(16), 16);
        BinaryPrimitives.WriteInt16LittleEndian(wav.AsSpan(20), 1); BinaryPrimitives.WriteInt16LittleEndian(wav.AsSpan(22), 1);
        BinaryPrimitives.WriteInt32LittleEndian(wav.AsSpan(24), rate); BinaryPrimitives.WriteInt32LittleEndian(wav.AsSpan(28), rate * 2);
        BinaryPrimitives.WriteInt16LittleEndian(wav.AsSpan(32), 2); BinaryPrimitives.WriteInt16LittleEndian(wav.AsSpan(34), 16);
        "data"u8.CopyTo(wav.AsSpan(36)); BinaryPrimitives.WriteInt32LittleEndian(wav.AsSpan(40), samples.Length * 2);
        for (var index = 0; index < samples.Length; index++)
            BinaryPrimitives.WriteInt16LittleEndian(wav.AsSpan(44 + index * 2), (short)Math.Round(Math.Clamp(samples[index] * gain, -1, 1) * 32767, MidpointRounding.AwayFromZero));
        return wav;
    }
    public static IReadOnlyList<VoiceTrainingSample> ReadAloud(float[] samples48k)
    {
        if (samples48k.Length is < 60 * 48000 or > 120 * 48000 || samples48k.Any(sample => !float.IsFinite(sample))) throw Invalid();
        var result = new List<VoiceTrainingSample>();
        for (var start = 0; start < samples48k.Length;)
        {
            var remaining = samples48k.Length - start;
            var length = Math.Min(15 * 48000, remaining);
            if (remaining > 18 * 48000)
            {
                var best = double.PositiveInfinity;
                for (var offset = 12 * 48000; offset <= Math.Min(18 * 48000, remaining - 480); offset += 480)
                {
                    var energy = 0.0;
                    for (var index = 0; index < 480; index++) energy += (double)samples48k[start + offset + index] * samples48k[start + offset + index];
                    if (energy < best) { best = energy; length = offset; }
                }
            }
            else length = remaining;
            if (remaining - length < 5 * 48000) length = remaining;
            var chunk = samples48k[start..(start + length)];
            result.Add(new(Wav(chunk), length / 48000.0, "readAloud", SnrDb(chunk, 48000)));
            start += length;
        }
        return result;
    }
    /// <summary>The take's §6.5.1 frame levels: one streamed decode of the first audio track's mono mix on the source timeline that
    /// transcript times use, never the whole take in memory. Missing media, a decode failure or a rate outside 8–96 kHz throws
    /// <see cref="VoiceLabSourceAudioException"/>.</summary>
    public static async Task<VoiceTrainingTake> AnalyzeAsync(string source, int rate, CancellationToken ct = default)
    {
        var levels = new VoiceTrainingLevels(rate);
        await VoiceLabSourceAudio.TrainingMixAsync(source, rate, (samples, _) => levels.Append(samples), null, ct).ConfigureAwait(false);
        return levels.Finish();
    }
    /// <summary>Cuts the selected spans from the same mono mix in one streamed pass that stops after the last span, as normalised
    /// project training samples in the given order.</summary>
    public static async Task<IReadOnlyList<VoiceTrainingSample>> ProjectSpansAsync(string source, int rate, IReadOnlyList<VoiceTrainingSpan> spans,
        CancellationToken ct = default)
    {
        var cut = new VoiceTrainingCut(spans, rate);
        await VoiceLabSourceAudio.TrainingMixAsync(source, rate, cut.Append, next => next < cut.End, ct).ConfigureAwait(false);
        return cut.Finish();
    }
    /// <summary>A span's source samples [floor((startMs × rate + 500) / 1000), floor((endMs × rate + 500) / 1000)) in integer
    /// arithmetic, so a 5–30 s span always cuts 5–30 s of samples.</summary>
    internal static (long Start, long End) SpanSamples(VoiceTrainingSpan span, int rate)
    {
        if (rate is < 8000 or > 96000 || span.StartMs < 0 || span.EndMs - span.StartMs is < VoiceTrainingSpans.SpanMinMs or > VoiceTrainingSpans.SpanMaxMs ||
            span.EndMs > long.MaxValue / 96000 || !double.IsFinite(span.SnrDb) || span.SnrDb < VoiceTrainingSpans.MinSnrDb) throw Invalid();
        return ((span.StartMs * rate + 500) / 1000, (span.EndMs * rate + 500) / 1000);
    }
    /// <summary>One cut span as a project sample: normalised like every training WAV, lasting its sample count over the rate, with the
    /// selection's take-relative SNR. Project spans always clear 20 dB, so they never ask for background-noise removal.</summary>
    internal static VoiceTrainingSample ProjectSpan(float[] samples, int rate, VoiceTrainingSpan span)
    {
        var (start, end) = SpanSamples(span, rate);
        if (samples.LongLength != end - start) throw Invalid();
        return new(Wav(samples, rate), samples.Length / (double)rate, "project", span.SnrDb);
    }
    public static double SnrDb(float[] samples, int rate)
    {
        var frame = rate / 100;
        if (frame <= 0 || samples.Length < frame || samples.Any(sample => !float.IsFinite(sample))) throw Invalid();
        var levels = new List<double>();
        for (var start = 0; start <= samples.Length - frame; start += frame)
        {
            var power = 0.0;
            for (var index = 0; index < frame; index++) power += (double)samples[start + index] * samples[start + index];
            levels.Add(Math.Sqrt(power / frame));
        }
        levels.Sort();
        var speech = levels.Where(level => level > Math.Pow(10, -45.0 / 20)).ToArray();
        if (speech.Length == 0) throw Invalid();
        return 20 * Math.Log10(Math.Max(speech[speech.Length / 2], 1e-9) / Math.Max(levels[levels.Count / 10], 1e-9));
    }
    private static VoiceLabException Invalid() => new(VoiceLabErrorKind.InvalidAudio);
}

/// <summary>A take's 10 ms levels in dBFS and its length on the source timeline (§6.5.1).</summary>
public sealed record VoiceTrainingTake(int Rate, long Samples, IReadOnlyList<double> FrameDb)
{
    /// <summary>The placed length floored to whole milliseconds, so every selected span ends inside the decoded samples.</summary>
    public double Duration => Samples * 1000 / Rate / 1000.0;
}

/// <summary>Turns decoded blocks at their source-grid positions into one gapless stream from sample 0, the way transcription
/// extraction (AudioDecoder) lays them out, so the levels and cuts match transcript times: silence before a late start and across a
/// timestamp gap, and samples before 0 or already placed are dropped.</summary>
internal sealed class VoiceTrainingTimeline(VoiceLabSourceAudio.SampleBlock consume)
{
    private static readonly float[] Silence = new float[65_536];
    /// <summary>The next sample index of the stream: everything before it has been placed.</summary>
    internal long Next { get; private set; }
    internal void Append(ReadOnlySpan<float> block, long first)
    {
        if (first + block.Length <= Next) return;
        while (Next < first)
        {
            var count = (int)Math.Min(first - Next, Silence.Length);
            consume(Silence.AsSpan(0, count), Next); Next += count;
        }
        var skip = (int)(Next - first);
        consume(block[skip..], Next); Next += block.Length - skip;
    }
}

/// <summary>Streaming §6.5.1 levels: frame i covers mono samples floor(i × rate / 100) up to floor((i + 1) × rate / 100), its level is
/// 20 × log10(max(rms, 1e-9)) with the RMS in binary64, and the take has floor(samples × 100 / rate) frames.</summary>
internal sealed class VoiceTrainingLevels(int rate)
{
    private readonly List<double> levels = [];
    private long samples;
    private long frameEnd = rate / 100;
    private double power;
    private long count;
    internal void Append(ReadOnlySpan<float> mono)
    {
        foreach (var value in mono)
        {
            power += (double)value * value; count++; samples++;
            if (samples < frameEnd) continue;
            levels.Add(20 * Math.Log10(Math.Max(Math.Sqrt(power / count), 1e-9)));
            power = 0; count = 0;
            frameEnd = (levels.Count + 1L) * rate / 100;
        }
    }
    internal VoiceTrainingTake Finish() => new(rate, samples, levels.Take((int)(samples * 100 / rate)).ToArray());
}

/// <summary>Collects the selected spans' samples from sequential mono blocks; the take must reach the last span.</summary>
internal sealed class VoiceTrainingCut
{
    private readonly int rate;
    private readonly VoiceTrainingSpan[] spans;
    private readonly (long Start, long End)[] bounds;
    private readonly float[][] samples;
    private long consumed;
    internal VoiceTrainingCut(IReadOnlyList<VoiceTrainingSpan> spans, int rate)
    {
        if (spans.Count is < 1 or > 24) throw new VoiceLabException(VoiceLabErrorKind.InvalidInput);
        this.rate = rate; this.spans = spans.ToArray();
        bounds = this.spans.Select(span => VoiceTrainingAudio.SpanSamples(span, rate)).ToArray();
        samples = bounds.Select(bound => new float[bound.End - bound.Start]).ToArray();
        End = bounds.Max(bound => bound.End);
    }
    internal long End { get; }
    internal void Append(ReadOnlySpan<float> block, long first)
    {
        for (var index = 0; index < bounds.Length; index++)
        {
            var from = Math.Max(first, bounds[index].Start);
            var to = Math.Min(first + block.Length, bounds[index].End);
            if (to > from) block[(int)(from - first)..(int)(to - first)].CopyTo(samples[index].AsSpan((int)(from - bounds[index].Start)));
        }
        consumed = Math.Max(consumed, first + block.Length);
    }
    internal IReadOnlyList<VoiceTrainingSample> Finish()
    {
        try
        {
            if (consumed < End) throw new VoiceLabSourceAudioException(VoiceLabSourceAudioErrorCode.RangeOutsideMedia);
            return spans.Select((span, index) => VoiceTrainingAudio.ProjectSpan(samples[index], rate, span)).ToArray();
        }
        finally { foreach (var span in samples) Array.Clear(span); }
    }
}
