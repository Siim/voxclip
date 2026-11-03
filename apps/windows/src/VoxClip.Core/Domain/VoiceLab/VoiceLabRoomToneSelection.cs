using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
#pragma warning disable CS1591

namespace VoxClip.Core.Domain.VoiceLab;

/// <summary>§8.7 item 3: the quietest ROOM_TONE_MIN_RUN of source audio, chosen on the 10 ms envelope.</summary>
public static class VoiceLabRoomToneSelection
{
    /// <summary>ROOM_TONE_MIN_RUN in 10 ms frames.</summary>
    const int RunFrames = 50;

    public static (long Start, long End)? NeighbouringPause(IReadOnlyList<TimedWord> items, AudioEnvelope envelope,
        double sampleRate, long totalSamples, long seam)
    {
        var size = VoiceLabGeometry.FrameSize(sampleRate);
        var count = size * 10;
        var lower = Math.Max(0, seam - (long)(3 * sampleRate));
        var upper = Math.Min(totalSamples - count, seam + (long)(3 * sampleRate));
        (long Start, long End)? best = null;
        var distance = long.MaxValue;
        for (var start = (lower + size - 1) / size * size; start <= upper; start += size)
        {
            var end = start + count;
            if (items.Any(word => word.Kind == WordKind.Word && word.End > start / sampleRate && word.Start < end / sampleRate) ||
                end / size > envelope.Rms.Count) continue;
            var quiet = true;
            for (var index = start / size; index < end / size; index++)
                if (envelope.Rms[(int)index] > VoiceLabPatchConstants.VOICED_FRAME_LEVEL) { quiet = false; break; }
            var candidate = Math.Abs(start + count / 2 - seam);
            if (quiet && candidate < distance) { best = (start, end); distance = candidate; }
        }
        return best;
    }

    public static bool ExcludeDigitalSilence(IReadOnlyList<TimedWord> items, AudioEnvelope envelope, double sampleRate,
        long totalSamples, VoiceLabWindow window, bool hardJoinSmoothing)
    {
        if (!hardJoinSmoothing || window.LeftSeam.Kind != VoiceLabSeamKind.Hard && window.RightSeam.Kind != VoiceLabSeamKind.Hard) return false;
        var size = VoiceLabGeometry.FrameSize(sampleRate);
        foreach (var seam in new[] { window.StartSample, window.EndSample })
            if (NeighbouringPause(items, envelope, sampleRate, totalSamples, seam) is { } pause)
                for (var index = pause.Start / size; index < pause.End / size; index++)
                    if (envelope.Rms[(int)index] > 0) return true;
        return false;
    }

    /// <summary>The run of 50 whole frames with the lowest mean power (summed in frame order, in binary64) inside a gap of at least
    /// 0.5 s between transcript items of any kind; leading and trailing silence are gaps. Ties go to the earliest run.</summary>
    public static VoiceLabRoomTone Select(IReadOnlyList<TimedWord> items, AudioEnvelope envelope, double sourceSampleRate, long totalSamples, bool excludeDigitalSilence = false)
    {
        var rate = sourceSampleRate;
        var total = totalSamples;
        VoiceLabGeometry.Check(rate, total, envelope, items);
        var size = VoiceLabGeometry.FrameSize(rate);
        var length = VoiceLabGeometry.Samples(VoiceLabPatchConstants.ROOM_TONE_MIN_RUN, rate);
        var levels = envelope.Rms;
        var gaps = new List<(long Start, long End)>();
        long cursor = 0;
        foreach (var (start, end) in items.Select(item => (Start: VoiceLabGeometry.Samples(item.Start, rate), End: VoiceLabGeometry.Samples(item.End, rate)))
                     .OrderBy(bound => bound.Start))
        {
            if (Math.Min(start, total) > cursor) gaps.Add((cursor, Math.Min(start, total)));
            cursor = Math.Max(cursor, end);
        }
        if (total > cursor) gaps.Add((cursor, total));
        (double Power, long Start)? best = null;
        foreach (var gap in gaps.Where(gap => gap.End - gap.Start >= length))
        {
            for (var index = (gap.Start + size - 1) / size; index + RunFrames <= levels.Count; index++)
            {
                var begin = index * size;
                if (Math.Max(begin + RunFrames * size, begin + length) > gap.End) break;
                var power = 0.0;
                var containsDigitalSilence = false;
                for (var frame = (int)index; frame < index + RunFrames; frame++)
                {
                    var value = (double)levels[frame];
                    power += value * value;
                    if (value == 0) containsDigitalSilence = true;
                }
                if ((!excludeDigitalSilence || !containsDigitalSilence) && (best is not { } current || power < current.Power)) best = (power, begin);
            }
        }
        // No fallback run: v3 needs room tone for passage TTS with Clean audio off, so the UI offers Clean audio instead.
        if (best is not { } chosen) throw VoiceLabGeometry.Error(VoiceLabGeometryErrorCode.RoomToneUnavailable);
        return new(chosen.Start, chosen.Start + length, 0);
    }
}
