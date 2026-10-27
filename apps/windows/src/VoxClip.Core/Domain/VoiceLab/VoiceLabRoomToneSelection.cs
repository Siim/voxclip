using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;

namespace VoxClip.Core.Domain.VoiceLab;

/// <summary>§8.7 item 3: the quietest ROOM_TONE_MIN_RUN of source audio, chosen on the 10 ms envelope.</summary>
public static class VoiceLabRoomToneSelection
{
    /// <summary>ROOM_TONE_MIN_RUN in 10 ms frames.</summary>
    const int RunFrames = 50;

    /// <summary>The run of 50 whole frames with the lowest mean power (summed in frame order, in binary64) inside a gap of at least
    /// 0.5 s between transcript items of any kind; leading and trailing silence are gaps. Ties go to the earliest run.</summary>
    public static VoiceLabRoomTone Select(IReadOnlyList<TimedWord> items, AudioEnvelope envelope, double sourceSampleRate, long totalSamples)
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
                for (var frame = (int)index; frame < index + RunFrames; frame++)
                {
                    var value = (double)levels[frame];
                    power += value * value;
                }
                if (best is not { } current || power < current.Power) best = (power, begin);
            }
        }
        // No fallback run: v3 needs room tone for passage TTS with Clean audio off, so the UI offers Clean audio instead.
        if (best is not { } chosen) throw VoiceLabGeometry.Error(VoiceLabGeometryErrorCode.RoomToneUnavailable);
        return new(chosen.Start, chosen.Start + length, 0);
    }
}
