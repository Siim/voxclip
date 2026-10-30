using System.Buffers.Binary;
using VoxClip.Core.Domain.Shared;
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
    public static VoiceTrainingSample ProjectSpan(float[] take, int rate, double start, double end, IReadOnlyList<TimedWord> transcript, bool diarization,
        bool cleanAudioApplied = false)
    {
        if (rate is < 8000 or > 96000 || !double.IsFinite(start) || !double.IsFinite(end) || start < 0 || end - start is < 5 or > 30 || end * rate > take.Length) throw Invalid();
        var items = transcript.Where(word => word.End > start && word.Start < end).ToArray();
        if (items.Length == 0 || items.Any(word => word.Kind != WordKind.Word || word.Conf is { } confidence && (!double.IsFinite(confidence) || confidence < 0.8) ||
            !double.IsFinite(word.Start) || !double.IsFinite(word.End) || word.End <= word.Start || word.Start < start || word.End > end) ||
            diarization && (items.Any(word => string.IsNullOrWhiteSpace(word.Speaker)) || items.Select(word => word.Speaker).Distinct().Count() != 1)) throw Invalid();
        var chunk = take[(int)Math.Ceiling(start * rate)..(int)Math.Floor(end * rate)];
        var snr = SnrDb(chunk, rate);
        if (snr < 20) throw Invalid();
        return new(Wav(chunk, rate), chunk.Length / (double)rate, "project", snr, cleanAudioApplied);
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
