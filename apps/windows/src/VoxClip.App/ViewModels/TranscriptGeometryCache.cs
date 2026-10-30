namespace VoxClip.App.ViewModels;

internal sealed class TranscriptGeometryCache<TInline, TRectangle> where TInline : notnull
{
    private readonly Dictionary<TInline, IReadOnlyList<TRectangle>> bounds = [];
    internal bool NeedsLayout { get; private set; } = true;
    internal void Invalidate() { bounds.Clear(); NeedsLayout = true; }
    internal void BeginDraw() => NeedsLayout = false;
    internal IReadOnlyList<TRectangle> Get(TInline inline, bool hasContent, Func<TInline, IReadOnlyList<TRectangle>> measure)
    {
        if (bounds.TryGetValue(inline, out var cached)) return cached;
        var measured = measure(inline);
        if (measured.Count > 0) bounds[inline] = measured;
        else if (hasContent) NeedsLayout = true;
        return measured;
    }
}
