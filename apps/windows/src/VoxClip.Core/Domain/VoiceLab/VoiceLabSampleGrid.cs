using VoxClip.Core.Domain.Editing;

namespace VoxClip.Core.Domain.VoiceLab;

/// <summary>Words meet a replace range on the source sample grid (voice-lab §10.1, 2026-11-10). The fit and the recipe
/// store a range's edges as their sample over the source rate (§8.9.2), so a touching word boundary off the grid would
/// otherwise sit under a sample inside or outside a stored edge. Every time here is rounded with the JavaScript half-up rule
/// the fit uses, <c>jsRound(seconds × rate)</c>. Samples stay binary64 so a time outside the take never overflows. The
/// Mac twin is <c>VoiceLabSampleGrid</c> in VoxClipCore.</summary>
public readonly record struct VoiceLabSampleGrid(double Rate)
{
    /// <summary>The sample a time rounds to.</summary>
    public double Sample(double seconds) => EditingMath.Round(seconds * Rate);

    /// <summary>Whether an item from <paramref name="start"/> to <paramref name="end"/> lies wholly inside the range from
    /// <paramref name="lower"/> to <paramref name="upper"/>. A stored edge that rounds to the same sample as a touching
    /// boundary meets it.</summary>
    public bool Contains(double lower, double upper, double start, double end) => Sample(start) >= Sample(lower) && Sample(end) <= Sample(upper);

    /// <summary>Whether an item crosses the edge at <paramref name="edge"/> seconds: the edge's sample lies strictly between
    /// the item's rounded boundaries.</summary>
    public bool Crosses(double start, double end, double edge) => CrossesSample(start, end, Sample(edge));

    /// <summary>Whether an item crosses the edge at source sample <paramref name="edgeSample"/>.</summary>
    public bool CrossesSample(double start, double end, double edgeSample) => Sample(start) < edgeSample && edgeSample < Sample(end);

    /// <summary>Whether an item shares at least one sample with the range from <paramref name="lower"/> to
    /// <paramref name="upper"/>.</summary>
    public bool Overlaps(double lower, double upper, double start, double end) => Sample(end) > Sample(lower) && Sample(start) < Sample(upper);
}
