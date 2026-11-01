using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
#pragma warning disable CS1591

namespace VoxClip.Core.Domain.VoiceLab;

/// <summary>Pure scope proposal review hunks, matching Swift and scope-rewrite-diff-cases.json.</summary>
public static class ScopeRewriteDiff
{
    public sealed record Hunk(VoiceLabDiffHunk Diff, string? InsertionAfterItemId, IReadOnlyList<string> Lines,
        IReadOnlyList<string> Reasons, bool CheckThis);
    public const int MergeWords = 2;
    public const double MergeSeconds = 0.35;
    sealed record Part(VoiceLabDiffHunk Hunk, IReadOnlyList<string> Lines, IReadOnlyList<string> Reasons, bool CheckThis,
        bool FirstVoice, bool Wordless, int? InsertItem, string? After);
    sealed record Token(int Item, double Start, double End);
    sealed class Stretch
    {
        public List<TimedWord> Items { get; } = [];
        public List<string> NewTokens { get; } = [];
        public List<int> EditIndices { get; } = [];
        public TimedWord? Before { get; init; }
        public TimedWord? After { get; set; }
    }
    public static IReadOnlyList<Hunk> Hunks(ScopeRewritePlan plan, PatchRewriteProposal proposal)
    {
        var labels = plan.Lines.Select(line => line.Label).ToHashSet(StringComparer.Ordinal);
        var edits = new Dictionary<string, PatchRewriteEdit>(StringComparer.Ordinal);
        foreach (var edit in proposal.Edits)
            if (!labels.Contains(edit.Line) || !edits.TryAdd(edit.Line, edit)) throw Invalid();
        var sources = new PatchRewriteValidator.Sources(plan.Request.Entries.Select(entry => entry.Text).Append(plan.Request.Instruction));
        List<string> ids = [];
        List<WordKind> kinds = [];
        List<bool> revoiced = [];
        List<Token> tokens = [];
        List<string> surfaces = [];
        List<Part> parts = [];
        foreach (var line in plan.Lines)
        {
            if (line.Items.Count != line.Entries.Count || line.RevoicedBefore.Count != line.Items.Count) throw Invalid();
            int firstItem = ids.Count, firstToken = tokens.Count;
            for (int index = 0; index < line.Items.Count; index++)
            {
                var item = line.Items[index];
                ids.Add(item.Id); kinds.Add(item.Kind); revoiced.Add(line.RevoicedBefore[index]);
                if (item.Kind != WordKind.Word) continue;
                foreach (var surface in EditingAlgorithms.SplitWords(item.Text))
                { tokens.Add(new(firstItem + index, item.Start, item.End)); surfaces.Add(surface); }
            }
            if (!edits.TryGetValue(line.Label, out var edit)) continue;
            var read = line.Items.Select((item, index) => item with { Text = line.Entries[index].Text, Kind = WordKind.Word }).ToArray();
            var pairing = VoiceLabWordDiff.Diff(read, edit.Text).Ops;
            HashSet<string> echoed = new(StringComparer.Ordinal);
            foreach (var item in line.Items.Where(item => item.Kind != WordKind.Word))
            {
                var at = Enumerable.Range(0, pairing.Count).Where(index => pairing[index].SourceWordId == item.Id).ToArray();
                if (at.Length > 0 && at[^1] - at[0] + 1 == at.Length && at.All(index => pairing[index].Kind == VoiceLabDiffOpKind.Equal)) echoed.Add(item.Id);
            }
            List<Stretch> stretches = [new()];
            Dictionary<string, int> stretchOf = new(StringComparer.Ordinal), position = new(StringComparer.Ordinal);
            for (int index = 0; index < line.Items.Count; index++)
            {
                var item = line.Items[index];
                position[item.Id] = firstItem + index;
                if (index > 0 && line.RevoicedBefore[index]) stretches.Add(new());
                if (echoed.Contains(item.Id)) { stretches[^1].After = item; stretches.Add(new() { Before = item }); }
                else stretches[^1].Items.Add(item);
                stretchOf[item.Id] = stretches.Count - 1;
            }
            int current = 0, newIndex = 0;
            foreach (var op in pairing)
            {
                if (op.SourceWordId is { } sourceId && stretchOf.TryGetValue(sourceId, out var stretch)) current = stretch;
                if (op.NewToken is not { } token) continue;
                if (op.SourceWordId is not { } echoId || !echoed.Contains(echoId))
                { stretches[current].NewTokens.Add(token); stretches[current].EditIndices.Add(newIndex); }
                newIndex++;
            }
            var flags = sources.FlaggedTokens(edit.Text);
            int offset = firstToken;
            foreach (var stretch in stretches)
            {
                int count = stretch.Items.Sum(item => item.Kind == WordKind.Word ? EditingAlgorithms.SplitWords(item.Text).Count : 0);
                int startToken = offset;
                offset += count;
                if (stretch.Items.Count == 0 && stretch.NewTokens.Count == 0) continue;
                var diff = VoiceLabWordDiff.Diff(stretch.Items, string.Join(" ", stretch.NewTokens));
                int walked = 0;
                foreach (var op in diff.Ops)
                {
                    if (op.Kind == VoiceLabDiffOpKind.Equal && op.NewToken is { } token) surfaces[startToken + walked] = token;
                    if (op.Kind != VoiceLabDiffOpKind.Insert) walked++;
                }
                bool firstVoice = true;
                foreach (var found in diff.Hunks)
                {
                    double? anchor = found.AnchorSeconds;
                    int? insertItem = null;
                    string? after = null;
                    if (found.SourceStartIndex == found.SourceEndIndex)
                    {
                        int previous;
                        if (count == 0)
                        {
                            if (stretch.Items.FirstOrDefault() is { } item) { anchor = item.Start; previous = position[item.Id] - 1; }
                            else if (stretch.After is { } next) { anchor = next.Start; previous = position[next.Id] - 1; }
                            else if (stretch.Before is { } before) { anchor = before.End; previous = position[before.Id]; }
                            else throw Invalid();
                        }
                        else
                        {
                            int item = tokens[startToken + Math.Min(found.SourceStartIndex, count - 1)].Item;
                            insertItem = item;
                            previous = found.SourceStartIndex < count ? item - 1 : item;
                        }
                        after = previous >= 0 ? ids[previous] : null;
                    }
                    int begin = NewStart(diff.Ops, found.SourceStartIndex);
                    bool flagged = Enumerable.Range(0, found.NewTokens.Count).Any(index =>
                    {
                        int at = begin + index;
                        if (at >= stretch.EditIndices.Count) return false;
                        int token = stretch.EditIndices[at];
                        return token < flags.Count ? flags[token] : edit.CheckThis;
                    });
                    parts.Add(new(found with { SourceStartIndex = startToken + found.SourceStartIndex,
                        SourceEndIndex = startToken + found.SourceEndIndex, AnchorSeconds = anchor }, [line.Label], [edit.Reason],
                        flagged, found.Kind == VoiceLabDiffHunkKind.Voice && firstVoice, count == 0, insertItem, after));
                    if (found.Kind == VoiceLabDiffHunkKind.Voice) firstVoice = false;
                }
            }
        }
        double StartTime(Part part) => part.Hunk.SourceStartIndex < part.Hunk.SourceEndIndex ? tokens[part.Hunk.SourceStartIndex].Start : part.Hunk.AnchorSeconds ?? 0;
        double EndTime(Part part) => part.Hunk.SourceStartIndex < part.Hunk.SourceEndIndex ? tokens[part.Hunk.SourceEndIndex - 1].End : part.Hunk.AnchorSeconds ?? 0;
        int FirstPosition(Part part) => part.Hunk.SourceStartIndex < part.Hunk.SourceEndIndex ? tokens[part.Hunk.SourceStartIndex].Item : part.InsertItem ?? 0;
        int LastPosition(Part part) => part.Hunk.SourceStartIndex < part.Hunk.SourceEndIndex ? tokens[part.Hunk.SourceEndIndex - 1].Item : part.InsertItem ?? 0;
        List<Part> merged = [];
        foreach (var part in parts)
        {
            int earlierIndex = merged.FindLastIndex(piece => piece.Hunk.Kind == VoiceLabDiffHunkKind.Voice);
            if (part.FirstVoice && !part.Wordless && earlierIndex >= 0 && !merged[earlierIndex].Wordless &&
                merged[earlierIndex].Hunk.SourceEndIndex <= part.Hunk.SourceStartIndex &&
                !merged.Skip(earlierIndex + 1).Any(piece => piece.Hunk.Kind == VoiceLabDiffHunkKind.Cut))
            {
                var earlier = merged[earlierIndex];
                var between = Enumerable.Range(earlier.Hunk.SourceEndIndex, part.Hunk.SourceStartIndex - earlier.Hunk.SourceEndIndex).ToArray();
                var bridges = Unique(between.Select(index => ids[tokens[index].Item]));
                double gap = StartTime(part) - EndTime(earlier);
                int left = LastPosition(earlier), right = FirstPosition(part);
                bool barrier = right > left + 1 && Enumerable.Range(left + 1, right - left - 1).Any(index => kinds[index] != WordKind.Word);
                bool run = right > left && Enumerable.Range(left + 1, right - left).Any(index => revoiced[index]);
                if (!barrier && !run && (bridges.Length <= MergeWords || gap <= MergeSeconds))
                {
                    var pieces = merged.Skip(earlierIndex).Append(part).ToArray();
                    List<string> lines = [], reasons = [];
                    foreach (var piece in pieces)
                        for (int index = 0; index < piece.Lines.Count; index++)
                            if (!lines.Contains(piece.Lines[index], StringComparer.Ordinal)) { lines.Add(piece.Lines[index]); reasons.Add(piece.Reasons[index]); }
                    int start = earlier.Hunk.SourceStartIndex, end = part.Hunk.SourceEndIndex;
                    var hunk = new VoiceLabDiffHunk(VoiceLabDiffHunkKind.Voice,
                        Unique(earlier.Hunk.SourceWordIds.Concat(bridges).Concat(part.Hunk.SourceWordIds)),
                        earlier.Hunk.NewTokens.Concat(between.Select(index => surfaces[index])).Concat(part.Hunk.NewTokens).ToArray(), [],
                        earlier.Hunk.AbsorbedItemIds.Concat(part.Hunk.AbsorbedItemIds).ToArray(),
                        Unique(earlier.Hunk.BridgeWordIds.Concat(bridges).Concat(part.Hunk.BridgeWordIds)), start, end, start == end ? earlier.Hunk.AnchorSeconds : null);
                    merged.RemoveRange(earlierIndex, merged.Count - earlierIndex);
                    merged.Add(new(hunk, lines, reasons, pieces.Any(piece => piece.CheckThis), false, false, part.InsertItem, start == end ? earlier.After : null));
                    continue;
                }
            }
            merged.Add(part);
        }
        return merged.Select(part => new Hunk(part.Hunk, part.After, part.Lines, part.Reasons, part.CheckThis)).ToArray();
    }
    static int NewStart(IReadOnlyList<VoiceLabDiffOp> ops, int source)
    {
        int count = 0, position = 0;
        foreach (var op in ops)
        {
            if (position >= source) break;
            if (op.Kind != VoiceLabDiffOpKind.Delete) count++;
            if (op.Kind != VoiceLabDiffOpKind.Insert) position++;
        }
        return count;
    }
    static string[] Unique(IEnumerable<string> values) => values.Distinct(StringComparer.Ordinal).ToArray();
    static VoiceLabWordDiffException Invalid() => new(VoiceLabWordDiffErrorCode.InvalidInput);
}
