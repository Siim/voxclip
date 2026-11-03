using System.Text.Json.Serialization;
#pragma warning disable CS1591
namespace VoxClip.Core.Domain.VoiceLab;

public sealed record VoiceLabMicroPause(double WordStartSeconds, double WordEndSeconds);
public sealed record VoiceLabEdgeGainWord(double GainDb, VoiceLabMicroPause WordSeconds);
public sealed record VoiceLabEdgeGain(
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] VoiceLabEdgeGainWord? In = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] VoiceLabEdgeGainWord? Out = null);

public static class VoiceLabHardJoin
{
    public const double PauseSeconds = 0.140;
    public const double GeneratedFadeSeconds = 0.025;
    public const double SourceFadeSeconds = 0.020;
    public const double GainRampSeconds = 0.020;
    public const double AcousticSearchSeconds = 0.120;
    public const double MaximumGainDb = 6;
    public const double ToleranceLu = 2;
    public const double RoomToneMaximumGainDb = 48;

    public static (long left, long right) FadeExtent(VoiceLabSeam seam, bool incoming, double sampleRate)
    {
        if (seam.MicroPause is not null)
        {
            var frames = (long)Math.Floor(SourceFadeSeconds * sampleRate + 0.5);
            return incoming ? (frames, 0) : (0, frames);
        }
        var left = seam.FadeSamples / 2;
        return (left, seam.FadeSamples - left);
    }

    public static VoiceLabMicroPause? Pause(IReadOnlyList<VoiceLabWord> words, double duration, bool incoming)
    {
        if (words.Count == 0) return null;
        var word = incoming ? words[0] : words[^1];
        var join = incoming ? 0 : duration;
        return new(word.Start - join, word.End - join);
    }

    public static double GeneratedWeight(double seconds, double duration, VoiceLabMicroPause? incoming, VoiceLabMicroPause? outgoing)
    {
        var weight = 1.0;
        if (incoming is not null)
            weight *= Math.Sin(Math.PI * Math.Clamp((seconds - incoming.WordStartSeconds + GeneratedFadeSeconds) / GeneratedFadeSeconds, 0, 1) / 2);
        if (outgoing is not null)
        {
            var fraction = Math.Clamp((seconds - duration - outgoing.WordEndSeconds + GeneratedFadeSeconds) / GeneratedFadeSeconds, 0, 1);
            weight *= fraction >= 1 ? 0 : Math.Cos(Math.PI * fraction / 2);
        }
        return weight;
    }

    public static double SourceWeight(double secondsFromJoin, bool incoming) =>
        Math.Sin(Math.PI * Math.Clamp(incoming ? -secondsFromJoin / SourceFadeSeconds : secondsFromJoin / SourceFadeSeconds, 0, 1) / 2);

    public static double EdgeGainDb(double seconds, double duration, VoiceLabEdgeGain? edgeGain)
    {
        double Value(VoiceLabEdgeGainWord? edge, bool incoming)
        {
            if (edge is null) return 0;
            var time = seconds - (incoming ? 0 : duration);
            var start = edge.WordSeconds.WordStartSeconds;
            var end = edge.WordSeconds.WordEndSeconds;
            if (time < start - 1e-9 || time > end + 1e-9) return 0;
            var fraction = incoming ? (end - time) / GainRampSeconds : (time - start) / GainRampSeconds;
            return edge.GainDb * Math.Clamp(fraction, 0, 1);
        }
        return Math.Max(Value(edgeGain?.In, true), Value(edgeGain?.Out, false));
    }

    public static double BedWeight(double seconds, double duration, IReadOnlyList<VoiceLabWord> words, VoiceLabMicroPause? incoming, VoiceLabMicroPause? outgoing)
    {
        var voice = GeneratedWeight(seconds, duration, incoming, outgoing);
        if (incoming is not null && seconds < incoming.WordStartSeconds || outgoing is not null && seconds >= duration + outgoing.WordEndSeconds - GeneratedFadeSeconds)
            return Math.Sqrt(Math.Max(0, 1 - voice * voice));
        var distance = SourceFadeSeconds;
        var lower = 0;
        var upper = words.Count;
        while (lower < upper)
        {
            var middle = lower + (upper - lower) / 2;
            if (words[middle].End < seconds) lower = middle + 1;
            else upper = middle;
        }
        double Near(int index) => index < 0 || index >= words.Count ? SourceFadeSeconds : Math.Max(0, Math.Max(words[index].Start - seconds, seconds - words[index].End));
        distance = Math.Min(distance, Math.Min(Near(lower - 1), Near(lower)));
        var pause = Math.Sin(Math.PI * Math.Min(1, distance / SourceFadeSeconds) / 2);
        return Math.Max(pause, Math.Sqrt(Math.Max(0, 1 - voice * voice)));
    }

    public static void Validate(VoiceLabSeams seams, VoiceLabEdgeGain? edgeGain, double duration)
    {
        if (seams.In.MicroPause is null && seams.Out.MicroPause is null && edgeGain is null) return;
        if (!double.IsFinite(duration) || duration is <= 0 or > 290 || edgeGain is { In: null, Out: null })
            throw new VoiceLabProjectException(VoiceLabProjectErrorCode.InvalidFadeHandles);
        bool Valid(VoiceLabMicroPause word, bool incoming) => double.IsFinite(word.WordStartSeconds) && double.IsFinite(word.WordEndSeconds) &&
            word.WordEndSeconds > word.WordStartSeconds && (incoming
                ? word.WordStartSeconds >= PauseSeconds - 0.001 && word.WordEndSeconds <= duration
                : word.WordStartSeconds >= -duration && word.WordEndSeconds <= -PauseSeconds + 0.001);
        foreach (var incoming in new[] { true, false })
        {
            var seam = incoming ? seams.In : seams.Out;
            if (seam.MicroPause is { } pause && (seam.Kind != VoiceLabSeamKind.Hard || !Valid(pause, incoming)))
                throw new VoiceLabProjectException(VoiceLabProjectErrorCode.InvalidFadeHandles);
            if ((incoming ? edgeGain?.In : edgeGain?.Out) is { } gain &&
                (seam.MicroPause is null || gain.WordSeconds != seam.MicroPause || !double.IsFinite(gain.GainDb) || gain.GainDb is < 0 or > MaximumGainDb))
                throw new VoiceLabProjectException(VoiceLabProjectErrorCode.InvalidFadeHandles);
        }
    }

    public static VoiceLabWord[] Refine(IReadOnlyList<VoiceLabWord> words, float[] samples, int sampleRate, bool refineIncoming = true, bool refineOutgoing = true)
    {
        var refined = words.ToArray();
        if (words.Count == 0) return refined;
        var frame = Math.Max(1, sampleRate / 200);
        foreach (var incoming in new[] { true, false })
        {
            if (incoming ? !refineIncoming : !refineOutgoing) continue;
            var index = incoming ? 0 : words.Count - 1;
            var word = refined[index];
            var boundary = incoming ? word.Start : word.End;
            var lower = Math.Max(0, (int)Math.Floor((incoming ? boundary - AcousticSearchSeconds : word.Start) * sampleRate));
            var upper = Math.Min(samples.Length, (int)Math.Ceiling((incoming ? word.End : boundary + AcousticSearchSeconds) * sampleRate));
            if (upper <= lower) continue;
            var levels = new List<(int start, int end, double power)>();
            for (var start = lower; start < upper; start += frame)
            {
                var end = Math.Min(upper, start + frame);
                double power = 0;
                for (var offset = start; offset < end; offset++) power += (double)samples[offset] * samples[offset];
                levels.Add((start, end, power / (end - start)));
            }
            var threshold = Math.Max(0.00000001, levels.Max(level => level.power) * 0.001);
            var active = levels.Where(level => level.power > threshold).ToArray();
            if (active.Length == 0) continue;
            if (incoming) refined[index] = word with { Start = Math.Min(word.Start, active[0].start / (double)sampleRate) };
            else
            {
                var limit = index + 1 < words.Count ? words[index + 1].Start : samples.Length / (double)sampleRate;
                refined[index] = word with { End = Math.Min(limit, Math.Max(word.End, active[^1].end / (double)sampleRate)) };
            }
        }
        return refined;
    }

    public static double? VoicedLevel(float[] samples, int sampleRate, int start, int end)
    {
        if (start < 0 || end > samples.Length || end <= start) throw new VoiceLabAudioMathException(VoiceLabAudioMathErrorCode.InvalidInput);
        return VoiceLabLoudness.VoicedRmsDb(samples.AsSpan(start, end - start), sampleRate);
    }

    public static double SpeechStep(float[] samples, int sampleRate, int seam, VoiceLabMicroPause pause, bool incoming)
    {
        var start = seam + (int)Math.Floor(pause.WordStartSeconds * sampleRate + 0.5);
        var end = seam + (int)Math.Floor(pause.WordEndSeconds * sampleRate + 0.5);
        var count = (int)Math.Floor(0.4 * sampleRate + 0.5);
        var edge = incoming ? VoicedLevel(samples, sampleRate, start, Math.Min(end, start + count)) : VoicedLevel(samples, sampleRate, Math.Max(start, end - count), end);
        var source = incoming ? VoicedLevel(samples, sampleRate, Math.Max(0, seam - count), seam) : VoicedLevel(samples, sampleRate, seam, Math.Min(samples.Length, seam + count));
        if (edge is not { } edgeLevel || source is not { } sourceLevel) throw new VoiceLabAudioMathException(VoiceLabAudioMathErrorCode.NoVoicedAudio);
        return incoming ? edgeLevel - sourceLevel : sourceLevel - edgeLevel;
    }

    public static double SourceStep(float[] samples, int sampleRate, int seam)
    {
        var count = (int)Math.Floor(0.4 * sampleRate + 0.5);
        var left = VoicedLevel(samples, sampleRate, Math.Max(0, seam - count), seam);
        var right = VoicedLevel(samples, sampleRate, seam, Math.Min(samples.Length, seam + count));
        if (left is not { } before || right is not { } after) throw new VoiceLabAudioMathException(VoiceLabAudioMathErrorCode.NoVoicedAudio);
        return after - before;
    }

    public static double Excess(double mixed, double source) => mixed >= 0 ? Math.Max(0, mixed - Math.Max(0, source)) : Math.Max(0, -mixed - Math.Max(0, -source));

    public static double MatchingGain(float[] edge, float[] source, int sampleRate, bool incoming = false)
    {
        var count = Math.Min(edge.Length, (int)Math.Floor(0.4 * sampleRate + 0.5));
        var speech = incoming ? edge.AsSpan(0, count) : edge.AsSpan(edge.Length - count, count);
        if (VoiceLabLoudness.VoicedRmsDb(speech, sampleRate) is not { } from || VoiceLabLoudness.VoicedRmsDb(source, sampleRate) is not { } to) return 0;
        var peak = VoiceLabLoudness.TruePeakDbtp(edge, sampleRate);
        return Math.Max(0, Math.Min(MaximumGainDb, Math.Min(to - from, -1 - peak)));
    }

    public static VoiceLabRoomTone MatchedRoomTone(VoiceLabRoomTone room, VoiceLabTakeInput input, double speechLevel)
    {
        var rate = input.SourceSampleRate;
        var size = Math.Max(1, (int)Math.Floor(rate * 0.01 + 0.5));
        var count = size * 10;
        if (input.Source.Samples(room.SourceStartSample, room.SourceEndSample) is not { } run) throw new VoiceLabException(VoiceLabErrorKind.InvalidInput);
        double Level(float[] samples) => VoiceLabLoudness.Loudness(VoiceLabLoudness.KWeighted(samples, rate), 0, samples.Length);
        var runLevel = Level(run.ToArray());
        if (!double.IsFinite(runLevel)) throw new VoiceLabGeometryException(VoiceLabGeometryErrorCode.RoomToneUnavailable);
        double? Target(long seam)
        {
            var lower = Math.Max(0, seam - 3 * rate);
            var upper = Math.Min(input.Source.TotalFrames - count, seam + 3 * rate);
            (long distance, double level)? best = null;
            for (var start = lower / size * size; start <= upper; start += size)
            {
                var end = start + count;
                if (input.Items.Any(word => word.Kind == Shared.WordKind.Word && word.End > start / (double)rate && word.Start < end / (double)rate) ||
                    input.Source.Samples(start, end) is not { } samples) continue;
                if (end / size > input.SourceEnvelope.Rms.Count || Enumerable.Range((int)(start / size), count / size).Any(index => input.SourceEnvelope.Rms[index] > VoiceLabPatchConstants.VOICED_FRAME_LEVEL)) continue;
                var distance = Math.Abs(start + count / 2 - seam);
                if (best is null || distance < best.Value.distance)
                {
                    var measured = Level(samples.ToArray());
                    if (double.IsFinite(measured)) best = (distance, Math.Min(measured, speechLevel - 12));
                }
            }
            return best?.level;
        }
        var left = Target(input.Window.StartSample);
        var right = Target(input.Window.EndSample);
        double Gain(double? target) => Math.Clamp(Math.Min(target ?? runLevel, speechLevel - 12) - runLevel, -RoomToneMaximumGainDb, RoomToneMaximumGainDb);
        var first = Gain(left ?? right);
        var last = Gain(right ?? left);
        return room with { GainDb = first, EndGainDb = Math.Abs(last - first) >= 1 ? last : null };
    }
}
