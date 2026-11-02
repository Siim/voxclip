using VoxClip.Core.Domain.Editing;

namespace VoxClip.App.ViewModels;

internal readonly record struct TimelineThumbnailSlot(double X, double Width, double SourceTime);

internal static class TimelineFilmstrip
{
    internal const int Limit = 24;
    internal static int Fill(Span<TimelineThumbnailSlot> slots, TimelinePieces pieces, TimelineWindow view, double width, TimelineAxis axis)
    {
        if (width <= 0 || !double.IsFinite(width) || slots.Length == 0) return 0;
        var count = 0;
        var indices = pieces.Indices(new(view.Start, view.End), axis);
        var cell = Math.Max(56, width / Math.Min(Limit, slots.Length));
        for (var index = indices.Start.Value; index < indices.End.Value && count < Math.Min(Limit, slots.Length); index++)
        {
            var piece = pieces.Pieces[index];
            if (piece.Kind == TimelinePieceKind.Ai) continue;
            var range = piece.Range(axis);
            var left = Math.Clamp(view.X(range.Start, width), 0, width);
            var right = Math.Clamp(view.X(range.End, width), 0, width);
            for (var position = left; position < right && count < Math.Min(Limit, slots.Length); position += cell)
            {
                var tileWidth = Math.Min(cell, right - position);
                if (tileWidth < 2) continue;
                var fraction = Math.Clamp((view.Time(position + tileWidth / 2, width) - range.Start) / Math.Max(double.Epsilon, range.End - range.Start), 0, 1);
                var source = piece.Source.Start + fraction * (piece.Source.End - piece.Source.Start);
                var bucket = cell / width * view.Duration;
                source = Math.Clamp((Math.Floor(source / bucket) + .5) * bucket, piece.Source.Start, Math.Max(piece.Source.Start, Math.BitDecrement(piece.Source.End)));
                slots[count++] = new(position, tileWidth, source);
            }
        }
        return count;
    }
}
