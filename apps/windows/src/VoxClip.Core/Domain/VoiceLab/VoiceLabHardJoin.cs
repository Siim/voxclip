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
    public const double WindowPauseFraction = 0.20;
    public static double PauseForWindow(double windowDuration) =>
        double.IsFinite(windowDuration) && windowDuration > 0 ? Math.Min(PauseSeconds, windowDuration * WindowPauseFraction) : 0;
    public const double GeneratedFadeSeconds = 0.025;
    public const double SourceFadeSeconds = 0.020;
    public const double GainRampSeconds = 0.020;
    public const double AcousticSearchSeconds = 0.120;
    public const double MaximumGainDb = 6;
    public const double ToleranceLu = 2;
    public const double RoomToneMaximumGainDb = 48;

    public static (long left, long right) FadeExtent(VoiceLabSeam seam, bool incoming, double sampleRate, long? availableSourceSamples = null)
    {
        if (seam.MicroPause is not null)
        {
            var frames = SourceFadeFrames(sampleRate, availableSourceSamples ?? (long)sampleRate);
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

    public static long SourceFadeFrames(double sampleRate, long availableSourceSamples) =>
        Math.Min((long)Math.Floor(SourceFadeSeconds * sampleRate + 0.5), availableSourceSamples / 2);

    public static double PauseExcess(float[] samples, int sampleRate, int seam, VoiceLabMicroPause pause, bool incoming, VoiceLabTakeInput input)
    {
        var sourceSeam = incoming ? input.Window.StartSample : input.Window.EndSample;
        if (VoiceLabRoomToneSelection.NeighbouringPause(input.Items, input.SourceEnvelope, input.SourceSampleRate, input.Source.TotalFrames, sourceSeam) is not { } target ||
            input.Source.Samples(target.Start, target.End) is not { } source) return 0;
        var first = incoming ? seam : seam + (int)Math.Floor(pause.WordEndSeconds * sampleRate + 0.5);
        var last = incoming ? seam + (int)Math.Floor((pause.WordStartSeconds - GeneratedFadeSeconds) * sampleRate + 0.5) : seam;
        var generated = VoiceLabLoudness.GeneratedPauseLufs(samples, sampleRate, first, last);
        var level = VoiceLabLoudness.GeneratedPauseLufs(source.Span, input.SourceSampleRate, 0, source.Length);
        return Math.Abs(generated - level);
    }

    public static double SourceWeight(double secondsFromJoin, bool incoming, double fadeSeconds = SourceFadeSeconds) =>
        Math.Sin(Math.PI * Math.Clamp((incoming ? -secondsFromJoin : secondsFromJoin) / fadeSeconds, 0, 1) / 2);

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
        return 1;
    }

    public static void Validate(VoiceLabSeams seams, VoiceLabEdgeGain? edgeGain, double duration, double? windowDuration = null)
    {
        if (seams.In.MicroPause is null && seams.Out.MicroPause is null && edgeGain is null) return;
        if (!double.IsFinite(duration) || duration is <= 0 or > 290 || edgeGain is { In: null, Out: null })
            throw new VoiceLabProjectException(VoiceLabProjectErrorCode.InvalidFadeHandles);
        bool Valid(VoiceLabMicroPause word, bool incoming) => double.IsFinite(word.WordStartSeconds) && double.IsFinite(word.WordEndSeconds) &&
            word.WordEndSeconds > word.WordStartSeconds && (incoming
                ? word.WordStartSeconds >= PauseForWindow(windowDuration ?? duration) - 0.001 && word.WordEndSeconds <= duration
                : word.WordStartSeconds >= -duration && word.WordEndSeconds <= -PauseForWindow(windowDuration ?? duration) + 0.001);
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

    public static VoiceLabWord[] Refine(IReadOnlyList<VoiceLabWord> words, float[] samples, int sampleRate, bool refineIncoming = true, bool refineOutgoing = true,
        double searchSeconds = AcousticSearchSeconds)
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
            var lower = Math.Max(0, (int)Math.Floor((incoming ? boundary - searchSeconds : word.Start) * sampleRate));
            var upper = Math.Min(samples.Length, (int)Math.Ceiling((incoming ? word.End : boundary + searchSeconds) * sampleRate));
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
        if (input.Source.Samples(room.SourceStartSample, room.SourceEndSample) is not { } run) throw new VoiceLabException(VoiceLabErrorKind.InvalidInput);
        double Level(float[] samples) => VoiceLabLoudness.Loudness(VoiceLabLoudness.KWeighted(samples, rate), 0, samples.Length);
        var runLevel = Level(run.ToArray());
        if (!double.IsFinite(runLevel))
        {
            if (run.Span.ContainsAnyExcept(0f)) throw new VoiceLabException(VoiceLabErrorKind.InvalidAudio);
            return room with { GainDb = 0, EndGainDb = null };
        }
        double? Target(long seam)
        {
            if (VoiceLabRoomToneSelection.NeighbouringPause(input.Items, input.SourceEnvelope, rate, input.Source.TotalFrames, seam) is not { } pause ||
                input.Source.Samples(pause.Start, pause.End) is not { } samples) return null;
            var measured = Level(samples.ToArray());
            return double.IsFinite(measured) ? Math.Min(measured, speechLevel - 12) : null;
        }
        var left = Target(input.Window.StartSample);
        var right = Target(input.Window.EndSample);
        double Gain(double? target) => Math.Clamp(Math.Min(target ?? runLevel, speechLevel - 12) - runLevel, -RoomToneMaximumGainDb, RoomToneMaximumGainDb);
        var first = Gain(left ?? right);
        var last = Gain(right ?? left);
        return room with { GainDb = first, EndGainDb = Math.Abs(last - first) >= 1 ? last : null };
    }
}
