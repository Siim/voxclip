namespace VoxClip.App.ViewModels;

internal enum ColumnFitState { Captions, FineTune, Rewrite }

internal readonly record struct ColumnRect(double X, double Y, double Width, double Height)
{
    internal double Right => X + Width;
    internal double Bottom => Y + Height;
    internal ColumnRect ToScreen(double clientX, double clientY) => this with { X = X + clientX, Y = Y + clientY };
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
        bool apply = false, bool settings = false, bool accent = true)
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
                if (accent) required.AddRange(CaptionFineTune.Colors.Select(color => "FineTune.Colour." + color.Name));
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

    internal static IReadOnlyList<ColumnPeer> ResolveVirtualizedAliases(IReadOnlyList<ColumnPeer> peers,
        IReadOnlySet<ColumnPeer> parkedCopies, bool scrollProven, ColumnRect column, ColumnRect client) =>
        peers.Where(peer => !scrollProven || !parkedCopies.Contains(peer) ||
            !peers.Any(realized => !parkedCopies.Contains(realized) && realized.Id == peer.Id &&
                realized.Scroll is { } scroll && scroll.Viewport.Contains(realized.Bounds) &&
                Assess(realized, column, client, required: true).Accepted)).ToArray();

    /// <summary>The viewer bar (design §5.1, §15), in epx relative to the bar. Back 32, a 40 round Play and Forward 32 keep
    /// their sizes and lead on one line. The AI modified tag, when shown, and then the time follow Forward on that line or,
    /// only when they don't fit beside it with the gap, sit together on a second line under it. The time ends at the
    /// trailing edge and nothing leaves the bar, so nothing is shrunk or truncated to fit a 300 column.</summary>
    internal static IReadOnlyList<string> TransportFailures(ColumnRect bar, ColumnRect back, ColumnRect play, ColumnRect forward,
        ColumnRect? tag, ColumnRect time, bool stacked, double gap)
    {
        var failures = new List<string>();
        foreach (var (id, bounds, size) in new[] { ("TransportBack", back, 32.0), ("TransportPlay", play, 40.0), ("TransportForward", forward, 32.0) })
            if (Math.Abs(bounds.Width - size) > 0.5 || Math.Abs(bounds.Height - size) > 0.5)
                failures.Add(id + ": " + bounds.Width + "x" + bounds.Height + ", not " + size + "x" + size);
        var parts = new List<(string Id, ColumnRect Bounds)> { ("TransportBack", back), ("TransportPlay", play), ("TransportForward", forward) };
        if (tag is { } shown) parts.Add(("AiModified", shown));
        parts.Add(("TransportTime", time));
        foreach (var (id, bounds) in parts)
            if (!bar.Contains(bounds)) failures.Add(id + ": outside the viewer bar");
        static double Middle(ColumnRect bounds) => bounds.Y + bounds.Height / 2;
        if (back.Right > play.X + 1 || play.Right > forward.X + 1 || Math.Abs(Middle(back) - Middle(play)) > 1 || Math.Abs(Middle(forward) - Middle(play)) > 1)
            failures.Add("Transport: Back, Play and Forward are not one leading line");
        var controlsBottom = Math.Max(play.Bottom, Math.Max(back.Bottom, forward.Bottom));
        if (stacked && forward.Right + gap + time.Right - (tag ?? time).X < bar.Right - 1)
            failures.Add("Transport: the tag and time moved under the controls although they fit beside them");
        foreach (var (id, bounds) in parts.Skip(3))
        {
            if (stacked && bounds.Y < controlsBottom - 1) failures.Add(id + ": not under the transport");
            if (!stacked && (bounds.X < forward.Right - 1 || bounds.Y < play.Y - 1 || bounds.Bottom > play.Bottom + 1))
                failures.Add(id + ": not after Forward on the transport's line");
        }
        if (tag is { } ai && (time.X < ai.Right - 1 || time.Y > ai.Bottom || time.Bottom < ai.Y))
            failures.Add("TransportTime: does not follow AI modified on its line");
        if (Math.Abs(time.Right - bar.Right) > 1) failures.Add("TransportTime: does not end at the bar's trailing edge");
        return failures;
    }
}
