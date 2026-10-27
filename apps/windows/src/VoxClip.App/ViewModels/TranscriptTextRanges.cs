namespace VoxClip.App.ViewModels;

/// <summary>Plain UTF-16 offsets for RichTextBlock TextHighlighter ranges.</summary>
public static class TranscriptTextRanges
{
    public static int[] Starts(IReadOnlyList<string> wordRuns, IReadOnlyList<string?> pauseRunsAfter,
        IReadOnlyList<int>? inlineBefore = null, IReadOnlyList<int>? inlineAfter = null)
    {
        if (wordRuns.Count != pauseRunsAfter.Count) throw new ArgumentException("Word and pause counts must match.", nameof(pauseRunsAfter));
        if (inlineBefore is not null && inlineBefore.Count != wordRuns.Count || inlineAfter is not null && inlineAfter.Count != wordRuns.Count)
            throw new ArgumentException("Inline and word counts must match.");
        var starts = new int[wordRuns.Count];
        var offset = 0;
        for (var index = 0; index < starts.Length; index++)
        {
            starts[index] = checked(offset + (inlineBefore?[index] ?? 0));
            offset = checked(starts[index] + wordRuns[index].Length + (pauseRunsAfter[index]?.Length ?? 0) + (inlineAfter?[index] ?? 0));
        }
        return starts;
    }
}
