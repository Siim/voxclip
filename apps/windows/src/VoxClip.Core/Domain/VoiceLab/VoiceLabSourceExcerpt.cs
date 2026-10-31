namespace VoxClip.Core.Domain.VoiceLab;

/// <summary>The frames of a source track that a Rewrite take run reads (voice-lab.md §8.7–8.9): the window's neighbourhood,
/// the speaker-check span, the seam handles and the room-tone run. They are held as a few regions at absolute frame
/// positions, so a long recording never sits in memory whole. A region copies the samples it is given, so an excerpt never
/// changes as long as no caller writes an array it handed to <see cref="Region.Owning"/>.</summary>
public sealed class VoiceLabSourceExcerpt
{
    /// <summary>A run of consecutive frames of the track.</summary>
    public sealed class Region
    {
        private readonly float[] samples;
        /// <summary>A copy of <paramref name="samples"/>, whose first frame is the track's frame <paramref name="start"/>.</summary>
        public Region(long start, ReadOnlySpan<float> samples) : this(start, samples.ToArray()) { }
        private Region(long start, float[] samples)
        {
            ArgumentOutOfRangeException.ThrowIfNegative(start);
            ArgumentNullException.ThrowIfNull(samples);
            Start = start;
            this.samples = samples;
        }
        /// <summary>A region that takes <paramref name="samples"/> itself, without a copy, as the Mac's region keeps its array. The
        /// caller hands over an array it has just filled and must not write it or hand it out again; the source decode and its
        /// resample do so, so no decoded region is held twice.</summary>
        public static Region Owning(long start, float[] samples) => new(start, samples);
        /// <summary>The absolute frame of <see cref="Samples"/>[0].</summary>
        public long Start { get; }
        /// <summary>The region's frames.</summary>
        public ReadOnlyMemory<float> Samples => samples;
        /// <summary>The absolute frame after the region's last frame.</summary>
        public long End => Start + samples.LongLength;
    }

    /// <summary>Regions sorted by start, of a track of <paramref name="totalFrames"/> frames. Regions must not overlap.</summary>
    public VoiceLabSourceExcerpt(long totalFrames, IEnumerable<Region> regions)
    {
        ArgumentOutOfRangeException.ThrowIfNegative(totalFrames);
        TotalFrames = totalFrames;
        Regions = Array.AsReadOnly(regions.OrderBy(region => region.Start).ToArray());
    }

    /// <summary>A track held whole, as short sources and tests pass it.</summary>
    public static VoiceLabSourceExcerpt Whole(ReadOnlySpan<float> samples) => new(samples.Length, [new Region(0, samples)]);

    /// <summary>The frame count of the whole track.</summary>
    public long TotalFrames { get; }
    /// <summary>Sorted by <see cref="Region.Start"/>; regions do not overlap.</summary>
    public IReadOnlyList<Region> Regions { get; }

    /// <summary>The track's frames [<paramref name="start"/>, <paramref name="end"/>), or null when they are outside the track
    /// or no single region holds all of them.</summary>
    public ReadOnlyMemory<float>? Samples(long start, long end)
    {
        if (start < 0 || end < start || end > TotalFrames) return null;
        foreach (var region in Regions)
            if (region.Start <= start && end <= region.End)
                return region.Samples.Slice((int)(start - region.Start), (int)(end - start));
        return null;
    }

    /// <summary>True when every held sample is finite.</summary>
    public bool IsFinite => Regions.All(region => AllFinite(region.Samples.Span));

    private static bool AllFinite(ReadOnlySpan<float> samples)
    {
        foreach (var sample in samples) if (!float.IsFinite(sample)) return false;
        return true;
    }
}
