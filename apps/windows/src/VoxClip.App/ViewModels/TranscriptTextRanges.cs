namespace VoxClip.App.ViewModels;

/// <summary>Native TextPointer offset spans, including display-only text and inline gaps.</summary>
public static class TranscriptTextRanges
{
    internal static TranscriptTextSpan? Hit(IReadOnlyList<TranscriptTextSpan> spans, int offset)
    {
        var low = 0;
        var high = spans.Count - 1;
        while (low <= high)
        {
            var middle = low + (high - low) / 2;
            var span = spans[middle];
            if (offset < span.Start) high = middle - 1;
            else if (offset >= span.End) low = middle + 1;
            else return span;
        }
        return null;
    }

}

internal readonly record struct TranscriptTextSpan(int Start, int End, int SourceIndex, int LastSourceIndex, int ChangeOrdinal = 0);
