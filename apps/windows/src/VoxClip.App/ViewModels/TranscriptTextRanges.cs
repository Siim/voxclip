namespace VoxClip.App.ViewModels;

/// <summary>Plain UTF-16 offsets for RichTextBlock TextHighlighter ranges.</summary>
public static class TranscriptTextRanges
{
    public static int[] Starts(IReadOnlyList<string> wordRuns, IReadOnlyList<string?> pauseRunsAfter)
    {
        if (wordRuns.Count != pauseRunsAfter.Count) throw new ArgumentException("Word and pause counts must match.", nameof(pauseRunsAfter));
        var starts = new int[wordRuns.Count];
        var offset = 0;
        for (var index = 0; index < starts.Length; index++)
        {
            starts[index] = offset;
            offset = checked(offset + wordRuns[index].Length + (pauseRunsAfter[index]?.Length ?? 0));
        }
        return starts;
    }
}
