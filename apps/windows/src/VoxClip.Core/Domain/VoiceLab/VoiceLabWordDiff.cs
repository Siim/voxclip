using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;

namespace VoxClip.Core.Domain.VoiceLab;

/// <summary>The token limit applies independently to each side.</summary>
public enum VoiceLabDiffSide
{
    /// <summary>Source word tokens.</summary>
    Source,
    /// <summary>New text tokens.</summary>
    NewText
}
/// <summary>Typed diff refusals before allocating the DP.</summary>
public enum VoiceLabWordDiffErrorCode
{
    /// <summary>More than 2,000 tokens on either side.</summary>
    TokenLimit,
    /// <summary>Invalid source IDs, text or timing.</summary>
    InvalidInput
}
/// <summary>A typed refusal, including the offending side and count for a token limit.</summary>
public sealed class VoiceLabWordDiffException(VoiceLabWordDiffErrorCode code, VoiceLabDiffSide? side = null, int? count = null)
    : Exception(code.ToString())
{
    /// <summary>The refusal code.</summary>
    public VoiceLabWordDiffErrorCode Code { get; } = code;
    /// <summary>The side that exceeded the limit, otherwise null.</summary>
    public VoiceLabDiffSide? Side { get; } = side;
    /// <summary>The token count, otherwise null.</summary>
    public int? Count { get; } = count;
    /// <summary>The inclusive token limit.</summary>
    public int Limit => VoiceLabWordDiff.MaximumTokens;
}
/// <summary>The normalized LCS operation.</summary>
public enum VoiceLabDiffOpKind
{
    /// <summary>A normalized match, possibly a surface correction.</summary>
    Equal,
    /// <summary>A source token removed.</summary>
    Delete,
    /// <summary>A new token added.</summary>
    Insert
}
/// <summary>The editing action for a diff hunk.</summary>
public enum VoiceLabDiffHunkKind
{
    /// <summary>Only source cuts, no TTS.</summary>
    Cut,
    /// <summary>Only case, punctuation or NFC surface corrections, no TTS.</summary>
    TextOnly,
    /// <summary>A spoken replacement or insertion.</summary>
    Voice
}
/// <summary>Surface-preserving operation; source fields are null for inserts and NewToken is null for deletes.</summary>
public sealed record VoiceLabDiffOp(VoiceLabDiffOpKind Kind, string? SourceWordId, string? SourceToken, string? NewToken);
/// <summary>A merged hunk with ordered distinct IDs, spoken surface tokens and bridge IDs. Indices address source word tokens,
/// end exclusive. Insertions anchor at the next source token's start, or the last token's end, or zero for an empty source.</summary>
public sealed record VoiceLabDiffHunk(VoiceLabDiffHunkKind Kind, IReadOnlyList<string> SourceWordIds,
    IReadOnlyList<string> NewTokens, IReadOnlyList<string> CorrectedTexts, IReadOnlyList<string> AbsorbedItemIds, IReadOnlyList<string> BridgeWordIds,
    int SourceStartIndex, int SourceEndIndex, double? AnchorSeconds);
/// <summary>Ordered raw operations and classified, merged hunks.</summary>
public sealed record VoiceLabWordDiffResult(IReadOnlyList<VoiceLabDiffOp> Ops, IReadOnlyList<VoiceLabDiffHunk> Hunks);

/// <summary>Pure deterministic word diff, Voice Lab §8.2.</summary>
public static class VoiceLabWordDiff
{
    /// <summary>Inclusive DP limit on either token array.</summary>
    public const int MaximumTokens = 2_000;
    sealed record Token(TimedWord Word, int ItemIndex, string Surface, string Normalized);
    sealed record Region(int Start, int End, int SourceStart, int SourceEnd, VoiceLabDiffHunkKind Kind, IReadOnlyList<string> Bridges);

    /// <summary>Compare word items only with existing tokenization/NFC/matching rules. Forward suffix-DP backtracking deletes
    /// on ties; each non-equal run is stably partitioned so all deletes precede inserts. Nonwords block voice merges;
    /// a voice hunk explicitly reports strictly interior nonwords that acceptance replaces.</summary>
    public static VoiceLabWordDiffResult Diff(IReadOnlyList<TimedWord> source, string newText)
    {
        List<Token> tokens = [];
        HashSet<string> ids = [];
        double previousStart = 0;
        for (int itemIndex = 0; itemIndex < source.Count; itemIndex++)
        {
            var word = source[itemIndex];
            if (string.IsNullOrEmpty(word.Id) || !ids.Add(word.Id) || !double.IsFinite(word.Start) || !double.IsFinite(word.End)
                || word.Start < previousStart || word.End < word.Start)
                throw new VoiceLabWordDiffException(VoiceLabWordDiffErrorCode.InvalidInput);
            previousStart = word.Start;
            if (word.Kind != WordKind.Word) continue;
            var surfaces = EditingAlgorithms.SplitWords(word.Text);
            if (surfaces.Count == 0) throw new VoiceLabWordDiffException(VoiceLabWordDiffErrorCode.InvalidInput);
            tokens.AddRange(surfaces.Select(surface => new Token(word, itemIndex, surface, Normalize(surface))));
        }
        var fresh = EditingAlgorithms.SplitWords(newText);
        if (tokens.Count > MaximumTokens) throw new VoiceLabWordDiffException(VoiceLabWordDiffErrorCode.TokenLimit, VoiceLabDiffSide.Source, tokens.Count);
        if (fresh.Count > MaximumTokens) throw new VoiceLabWordDiffException(VoiceLabWordDiffErrorCode.TokenLimit, VoiceLabDiffSide.NewText, fresh.Count);
        var normalized = fresh.Select(Normalize).ToArray();
        int width = fresh.Count + 1;
        int[] lengths = new int[(tokens.Count + 1) * width];
        for (int sourceIndex = tokens.Count - 1; sourceIndex >= 0; sourceIndex--)
            for (int newIndex = fresh.Count - 1; newIndex >= 0; newIndex--)
            {
                int cell = sourceIndex * width + newIndex;
                int down = cell + width;
                lengths[cell] = tokens[sourceIndex].Normalized == normalized[newIndex]
                    ? lengths[down + 1] + 1 : Math.Max(lengths[down], lengths[cell + 1]);
            }
        List<VoiceLabDiffOp> ops = [];
        int sourceCursor = 0;
        int newCursor = 0;
        while (sourceCursor < tokens.Count || newCursor < fresh.Count)
        {
            if (sourceCursor < tokens.Count && newCursor < fresh.Count && tokens[sourceCursor].Normalized == normalized[newCursor])
            {
                var token = tokens[sourceCursor++];
                ops.Add(new(VoiceLabDiffOpKind.Equal, token.Word.Id, token.Surface, fresh[newCursor++]));
            }
            else if (sourceCursor < tokens.Count && (newCursor == fresh.Count
                || lengths[(sourceCursor + 1) * width + newCursor] >= lengths[sourceCursor * width + newCursor + 1]))
            {
                var token = tokens[sourceCursor++];
                ops.Add(new(VoiceLabDiffOpKind.Delete, token.Word.Id, token.Surface, null));
            }
            else ops.Add(new(VoiceLabDiffOpKind.Insert, null, null, fresh[newCursor++]));
        }
        List<VoiceLabDiffOp> ordered = [];
        int cursor = 0;
        while (cursor < ops.Count)
        {
            if (ops[cursor].Kind == VoiceLabDiffOpKind.Equal) ordered.Add(ops[cursor++]);
            else
            {
                int start = cursor;
                while (cursor < ops.Count && ops[cursor].Kind != VoiceLabDiffOpKind.Equal) cursor++;
                var run = ops.GetRange(start, cursor - start);
                ordered.AddRange(run.Where(op => op.Kind == VoiceLabDiffOpKind.Delete));
                ordered.AddRange(run.Where(op => op.Kind == VoiceLabDiffOpKind.Insert));
            }
        }
        return new(ordered, Hunks(ordered, tokens, source));
    }

    static string Normalize(string text) => EditingAlgorithms.NormalizeForMatch(EditingAlgorithms.Nfc(text));

    static IReadOnlyList<VoiceLabDiffHunk> Hunks(List<VoiceLabDiffOp> ops, List<Token> tokens, IReadOnlyList<TimedWord> source)
    {
        List<Region> regions = [];
        int cursor = 0;
        int sourceIndex = 0;
        while (cursor < ops.Count)
        {
            int start = cursor;
            int sourceStart = sourceIndex;
            if (ops[cursor].Kind == VoiceLabDiffOpKind.Equal)
            {
                if (ops[cursor].SourceToken == ops[cursor].NewToken) { cursor++; sourceIndex++; continue; }
                while (cursor < ops.Count && ops[cursor].Kind == VoiceLabDiffOpKind.Equal && ops[cursor].SourceToken != ops[cursor].NewToken)
                { cursor++; sourceIndex++; }
                regions.Add(new(start, cursor, sourceStart, sourceIndex, VoiceLabDiffHunkKind.TextOnly, []));
            }
            else
            {
                bool inserted = false;
                while (cursor < ops.Count && ops[cursor].Kind != VoiceLabDiffOpKind.Equal)
                {
                    if (ops[cursor].Kind == VoiceLabDiffOpKind.Delete) sourceIndex++; else inserted = true;
                    cursor++;
                }
                regions.Add(new(start, cursor, sourceStart, sourceIndex, inserted ? VoiceLabDiffHunkKind.Voice : VoiceLabDiffHunkKind.Cut, []));
            }
        }
        List<int> sourcePositions = [0];
        List<int> sourceOps = [];
        for (int index = 0; index < ops.Count; index++)
        {
            if (ops[index].Kind != VoiceLabDiffOpKind.Insert) sourceOps.Add(index);
            sourcePositions.Add(sourcePositions[^1] + (ops[index].Kind == VoiceLabDiffOpKind.Insert ? 0 : 1));
        }
        List<Region> widened = [];
        foreach (var original in regions)
        {
            var region = original;
            int first = region.SourceStart;
            int last = region.SourceEnd;
            if (first == last && first > 0 && first < tokens.Count && tokens[first - 1].Word.Id == tokens[first].Word.Id)
            { first--; last++; }
            if (first < last)
            {
                while (first > 0 && tokens[first - 1].Word.Id == tokens[first].Word.Id) first--;
                while (last < tokens.Count && tokens[last - 1].Word.Id == tokens[last].Word.Id) last++;
                region = region with { Start = Math.Min(region.Start, sourceOps[first]), End = Math.Max(region.End, sourceOps[last - 1] + 1) };
            }
            if (widened.Count > 0 && region.Start <= widened[^1].End)
            {
                region = region with { Start = widened[^1].Start, End = Math.Max(region.End, widened[^1].End) };
                widened.RemoveAt(widened.Count - 1);
            }
            widened.Add(region with { SourceStart = sourcePositions[region.Start], SourceEnd = sourcePositions[region.End] });
        }
        widened = widened.Select(region =>
        {
            var run = ops.GetRange(region.Start, region.End - region.Start);
            var before = run.Where(op => op.SourceToken is not null).Select(op => Normalize(op.SourceToken!));
            var after = run.Where(op => op.NewToken is not null).Select(op => Normalize(op.NewToken!)).ToArray();
            return region with { Kind = after.Length == 0 ? VoiceLabDiffHunkKind.Cut
                : before.SequenceEqual(after) ? VoiceLabDiffHunkKind.TextOnly : VoiceLabDiffHunkKind.Voice };
        }).ToList();
        List<Region> merged = [];
        foreach (var region in widened)
        {
            int earlierIndex = merged.FindLastIndex(value => value.Kind == VoiceLabDiffHunkKind.Voice);
            if (region.Kind == VoiceLabDiffHunkKind.Voice && earlierIndex >= 0)
            {
                var earlier = merged[earlierIndex];
                var between = ops.GetRange(earlier.End, region.Start - earlier.End);
                bool equalOnly = between.All(op => op.Kind == VoiceLabDiffOpKind.Equal);
                double gap = StartTime(region, tokens) - EndTime(earlier, tokens);
                int equalItems = between.Select(op => op.SourceWordId).Distinct().Count();
                int left = earlier.SourceStart < earlier.SourceEnd ? tokens[earlier.SourceEnd - 1].ItemIndex : ItemPosition(earlier.SourceStart, tokens);
                int right = ItemPosition(region.SourceStart, tokens);
                bool barrier = source.Where((word, index) => index > left && index < right).Any(word => word.Kind != WordKind.Word);
                if (equalOnly && !barrier && (equalItems <= 2 || gap <= 0.35))
                {
                    var bridges = earlier.Bridges.Concat(between.Select(op => op.SourceWordId!)).ToArray();
                    merged.RemoveRange(earlierIndex, merged.Count - earlierIndex);
                    merged.Add(new(earlier.Start, region.End, earlier.SourceStart, region.SourceEnd, VoiceLabDiffHunkKind.Voice, bridges));
                    continue;
                }
            }
            merged.Add(region);
        }
        return merged.Select(region =>
        {
            var run = ops.GetRange(region.Start, region.End - region.Start);
            var sourceIds = run.Where(op => op.SourceWordId is not null).Select(op => op.SourceWordId!).Distinct().ToArray();
            var newTokens = run.Where(op => op.NewToken is not null).Select(op => op.NewToken!).ToArray();
            string[] absorbed = [];
            if (region.Kind == VoiceLabDiffHunkKind.Voice && region.SourceStart < region.SourceEnd)
            {
                int first = tokens[region.SourceStart].ItemIndex;
                int last = tokens[region.SourceEnd - 1].ItemIndex;
                absorbed = source.Where((word, index) => index > first && index < last && word.Kind != WordKind.Word)
                    .Select(word => word.Id).ToArray();
            }
            List<string> corrected = [];
            if (region.Kind == VoiceLabDiffHunkKind.TextOnly)
            {
                int offset = 0;
                foreach (string id in sourceIds)
                {
                    int count = run.Count(op => op.SourceWordId == id);
                    corrected.Add(string.Join(" ", newTokens.Skip(offset).Take(count)));
                    offset += count;
                }
            }
            return new VoiceLabDiffHunk(region.Kind, sourceIds, newTokens, corrected, absorbed, region.Bridges.Distinct().ToArray(),
                region.SourceStart, region.SourceEnd, region.SourceStart == region.SourceEnd ? Anchor(region.SourceStart, tokens) : null);
        }).ToArray();
    }

    static double Anchor(int index, List<Token> tokens) => index < tokens.Count ? tokens[index].Word.Start : tokens.LastOrDefault()?.Word.End ?? 0;
    static int ItemPosition(int index, List<Token> tokens) => index < tokens.Count ? tokens[index].ItemIndex : tokens.LastOrDefault()?.ItemIndex ?? 0;
    static double StartTime(Region region, List<Token> tokens) => region.SourceStart < region.SourceEnd
        ? tokens[region.SourceStart].Word.Start : Anchor(region.SourceStart, tokens);
    static double EndTime(Region region, List<Token> tokens) => region.SourceStart < region.SourceEnd
        ? tokens[region.SourceEnd - 1].Word.End : Anchor(region.SourceStart, tokens);
}
