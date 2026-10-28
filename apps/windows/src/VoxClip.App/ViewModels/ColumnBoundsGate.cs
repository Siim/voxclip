namespace VoxClip.App.ViewModels;

internal enum ColumnFitState { Captions, FineTune, Rewrite }

internal readonly record struct ColumnRect(double X, double Y, double Width, double Height)
{
    internal double Right => X + Width;
    internal double Bottom => Y + Height;
    internal bool Measurable => double.IsFinite(X) && double.IsFinite(Y) && double.IsFinite(Right) &&
        double.IsFinite(Bottom) && Width > 0 && Height > 0;
    internal bool Contains(ColumnRect other) => Measurable && other.Measurable &&
        other.X >= X - 1 && other.Right <= Right + 1 && other.Y >= Y - 1 && other.Bottom <= Bottom + 1;
}

internal sealed record ColumnScrollRegion(string Id, ColumnRect Viewport, double VerticalOffset, double ExtentHeight, bool Onscreen = true);
internal sealed record ColumnPeer(string Id, string Name, string Role, ColumnRect Bounds, bool Offscreen, ColumnScrollRegion? Scroll = null);
internal sealed record ColumnBoundsDecision(bool Accepted, string Classification);

internal static class ColumnBoundsGate
{
    internal static readonly string[] Common = ["PreviewStage", "TransportBack", "TransportPlay", "TransportForward", "TransportTime",
        "Frame.9:16", "Frame.1:1", "Frame.16:9", "Frame.Original"];
    internal static readonly string[] Captions = ["Captions.Toggle", "Captions.StyleName", "Captions.Summary", "Captions.Gallery"];
    internal static readonly string[] FineTune = ["FineTune.Size", "FineTune.Case", "FineTune.Words on screen",
        "FineTune.Punctuation", "FineTune.Position", "FineTune.Reset"];
    internal static readonly string[] Rewrite = ["Rewrite.Header", "Rewrite.Instruction", "Rewrite.Words", "Rewrite.Close", "Rewrite.Propose"];

    internal static IReadOnlyList<string> RequiredIds(ColumnFitState state, IReadOnlyList<string> galleryChoices,
        bool apply = false, bool settings = false)
    {
        var required = new List<string>(Common);
        if (state == ColumnFitState.Rewrite)
        {
            required.AddRange(Rewrite);
            if (apply) required.Add("Rewrite.Apply");
            if (settings) required.Add("Rewrite.Settings");
        }
        else
        {
            required.AddRange(Captions);
            required.AddRange(galleryChoices.Count == 0 ? ["Captions.Gallery.VisibleChoice"] : galleryChoices);
            if (state == ColumnFitState.FineTune)
            {
                required.AddRange(FineTune);
                required.AddRange(CaptionFineTune.Colors.Select(color => "FineTune.Colour." + color.Name));
            }
        }
        return required;
    }

    internal static ColumnBoundsDecision Assess(ColumnPeer peer, ColumnRect column, ColumnRect client, bool required = false)
    {
        if (!peer.Bounds.Measurable) return new(false, "unmeasurable");
        if (!peer.Offscreen)
            return column.Contains(peer.Bounds) && client.Contains(peer.Bounds) ? new(true, "onscreen") : new(false, "overflow");
        if (required) return new(false, "required peer is offscreen");
        if (peer.Scroll is { Onscreen: true } scroll && column.Contains(scroll.Viewport) && client.Contains(scroll.Viewport) &&
            double.IsFinite(scroll.VerticalOffset) && double.IsFinite(scroll.ExtentHeight) &&
            scroll.ExtentHeight > scroll.Viewport.Height && scroll.VerticalOffset >= 0 &&
            scroll.VerticalOffset <= scroll.ExtentHeight - scroll.Viewport.Height + 1 &&
            peer.Bounds.X >= scroll.Viewport.X - 1 && peer.Bounds.Right <= scroll.Viewport.Right + 1 &&
            (peer.Bounds.Y < scroll.Viewport.Y || peer.Bounds.Bottom > scroll.Viewport.Bottom) &&
            peer.Bounds.Y >= scroll.Viewport.Y - scroll.VerticalOffset - 1 &&
            peer.Bounds.Bottom <= scroll.Viewport.Y - scroll.VerticalOffset + scroll.ExtentHeight + 1)
            return new(true, "scrolled out");
        return new(false, "offscreen outside an owned scroll region");
    }

    internal static IReadOnlyList<string> RequiredFailures(IEnumerable<string> requiredIds, IReadOnlyList<ColumnPeer> peers,
        ColumnRect column, ColumnRect client)
    {
        var failures = new List<string>();
        foreach (var id in requiredIds)
        {
            var matches = peers.Where(peer => peer.Id == id).ToArray();
            if (matches.Length == 0) { failures.Add(id + ": missing or unrealized"); continue; }
            foreach (var peer in matches)
            {
                var decision = Assess(peer, column, client, required: true);
                if (!decision.Accepted) failures.Add(id + ": " + decision.Classification);
            }
        }
        return failures;
    }
}
